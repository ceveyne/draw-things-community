import Foundation
import Logging

final class FileLog {
  static let shared = FileLog()
  private let lock = NSLock()
  private var handle: FileHandle?
  private let stamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
  }()

  func open(directory: String) {
    lock.lock()
    defer { lock.unlock() }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let path = directory + "/monitor.log"

    if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int, size > 2_000_000 {
      try? FileManager.default.removeItem(atPath: path)
    }
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
    _ = try? handle?.seekToEnd()
  }

  func append(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    guard let handle = handle, let data = "\(stamp.string(from: Date())) \(line)\n".data(using: .utf8) else { return }
    try? handle.write(contentsOf: data)
  }
}

final class ActiveProjectTracker {
  private let locator: ProjectLocator
  private let logger: Logger
  private let lock = NSLock()
  private var fds: [String: Set<Int32>] = [:]
  private var touched: [String: Date] = [:]
  private var lastSet: Set<String>? = nil
  private var current: String? = nil

  private let settle: TimeInterval = 0.4
  private var running = false

  init(locator: ProjectLocator, logger: Logger) {
    self.locator = locator
    self.logger = logger
  }

  func start() {
    lock.lock()
    guard !running else {
      lock.unlock()
      return
    }
    running = true
    lock.unlock()
    sample()
    Thread.detachNewThread { [weak self] in
      while let self = self {
        Thread.sleep(forTimeInterval: 0.15)
        self.sample()
      }
    }
  }

  var active: String? {
    sample()
    return lock.withLock { current }
  }

  private func record(_ line: String) {
    logger.info("\(line)")
    FileLog.shared.append(line)
  }

  func sample() {
    let seen = locator.openProjectFDs()
    let now = Date()
    lock.lock()
    defer { lock.unlock() }
    let before = current
    guard let seen = seen else {

      current = nil
      fds = [:]
      touched = [:]
      if lastSet != nil || before != nil {
        record("PROJECT Draw Things cannot be seen: active unknown")
        lastSet = nil
      }
      return
    }
    let first = lastSet == nil
    let set = Set(seen.keys)
    for (name, numbers) in seen {
      let had = fds[name] ?? []
      let added = numbers.subtracting(had)
      if !added.isEmpty && !first {
        touched[name] = now
        record("PROJECT touched \(name): new file descriptors \(added.sorted()) (had \(had.count), has \(numbers.count))")
      }
    }
    for name in Array(touched.keys) where !set.contains(name) { touched.removeValue(forKey: name) }
    fds = seen
    if set.count == 1 {
      current = set.first
    } else if set.isEmpty {
      current = nil
    } else {
      if let present = current, !set.contains(present) { current = nil }
      let settled = set.filter { (touched[$0] ?? .distantFuture) <= now.addingTimeInterval(-settle) }
      if let best = settled.max(by: { (touched[$0] ?? .distantPast) < (touched[$1] ?? .distantPast) }),
        best != current,
        (touched[best] ?? .distantPast) > (current.flatMap { touched[$0] } ?? .distantPast)
      {
        current = best
      }
    }
    if lastSet != set || before != current {
      record("PROJECT open files \(set.sorted()) (before \(lastSet.map { "\($0.sorted())" } ?? "none")): active \(current ?? "unknown")")
      lastSet = set
    }
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
