import Foundation
import Logging

final class MonitorHub {
  private final class Client {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }
  }

  private let path: String
  private let logger: Logger
  private let lock = NSLock()
  private var clients: [Client] = []
  private var listener: Int32 = -1
  private var timer: DispatchSourceTimer?
  private let queue = DispatchQueue(label: "MonitorHub")

  var snapshotProvider: (() -> [String: Any])?

  var onCommand: (([String: Any]) -> Void)?

  var onChange: ((Bool) -> Void)?

  init(path: String, logger: Logger) {
    self.path = path
    self.logger = logger
  }

  var isActive: Bool { lock.withLock { !clients.isEmpty } }

  func start() throws {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw MonitorError.socket(String(cString: strerror(errno))) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else {
      close(fd)
      throw MonitorError.socket("the path is too long: \(path)")
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        _ = path.withCString { strncpy(destination, $0, capacity - 1) }
      }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else {
      let message = String(cString: strerror(errno))
      close(fd)
      throw MonitorError.socket("bind \(path): \(message)")
    }
    chmod(path, 0o600)
    guard listen(fd, 4) == 0 else {
      let message = String(cString: strerror(errno))
      close(fd)
      throw MonitorError.socket("listen: \(message)")
    }
    listener = fd
    Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    logger.info("Monitor socket: \(path)")
  }

  private func acceptLoop(_ fd: Int32) {
    while true {
      let client = accept(fd, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        return
      }
      var on: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

      var timeout = timeval(tv_sec: 2, tv_usec: 0)
      setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      let entry = Client(fd: client)

      let first = lock.withLock { () -> Bool in
        let wasEmpty = clients.isEmpty
        clients.append(entry)
        return wasEmpty
      }
      logger.info(first ? "Monitor connected: monitor mode is on" : "A further monitor connected")
      if first { onChange?(true) }
      startTimer()
      send(["type": "hello", "version": 1], to: entry)
      queue.async { [weak self] in self?.push(force: true) }
      Thread.detachNewThread { [weak self] in self?.readLoop(entry) }
    }
  }

  private func readLoop(_ client: Client) {
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = read(client.fd, &buffer, buffer.count)
      if n < 0 && errno == EINTR { continue }
      if n <= 0 { break }
      pending.append(buffer, count: n)
      while let newline = pending.firstIndex(of: 0x0A) {
        let line = pending.prefix(upTo: newline)
        pending.removeSubrange(...newline)
        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
          onCommand?(object)
        }
      }
    }
    drop(client)
  }

  private func drop(_ client: Client) {
    let remaining: Int = lock.withLock {
      guard clients.contains(where: { $0 === client }) else { return -1 }
      clients.removeAll { $0 === client }
      return clients.count
    }
    guard remaining >= 0 else { return }
    close(client.fd)
    if remaining == 0 {
      stopTimer()
      logger.info("Monitor gone: monitor mode is off")
      onChange?(false)
    }
  }

  private func startTimer() {
    lock.lock()
    defer { lock.unlock() }
    guard timer == nil else { return }
    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(deadline: .now() + 0.5, repeating: 0.5)
    source.setEventHandler { [weak self] in self?.push() }
    source.resume()
    timer = source
  }

  private func stopTimer() {
    lock.lock()
    defer { lock.unlock() }
    timer?.cancel()
    timer = nil
  }

  func pushNow() {
    queue.async { [weak self] in self?.push() }
  }

  private var lastState: Data?

  private func push(force: Bool = false) {
    guard isActive, let provider = snapshotProvider else { return }
    var state = provider()
    state["type"] = "state"
    guard var data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
    if !force, data == lastState { return }
    lastState = data
    data.append(0x0A)
    for client in lock.withLock({ clients }) { write(data, to: client) }
  }

  func broadcast(_ object: [String: Any]) {
    queue.async { [weak self] in self?.send(object) }
  }

  private func send(_ object: [String: Any]) {
    let targets = lock.withLock { clients }
    for client in targets { send(object, to: client) }
  }

  private func send(_ object: [String: Any], to client: Client) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(0x0A)
    write(data, to: client)
  }

  private func write(_ data: Data, to client: Client) {
    let ok = data.withUnsafeBytes { raw -> Bool in
      var offset = 0
      while offset < raw.count {
        let n = Darwin.write(client.fd, raw.baseAddress! + offset, raw.count - offset)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }
        offset += n
      }
      return true
    }
    if !ok { drop(client) }
  }

  func stop() {
    if listener >= 0 { close(listener) }
    unlink(path)
    let all = lock.withLock { () -> [Client] in
      defer { clients = [] }
      return clients
    }
    for client in all { close(client.fd) }
    stopTimer()
  }
}

enum MonitorError: Error {
  case socket(String)
}
