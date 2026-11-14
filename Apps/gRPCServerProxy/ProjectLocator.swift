import Darwin
import Foundation
import Logging
import SQLite3

struct ProjectNode {
  var rowid: Int64
  var lineage: Int64
  var logicalTime: Int64

  var wallClockMicros: Int64
  var seed: UInt32
  var steps: UInt32
  var model: String

  var startWidth: Int
  var startHeight: Int
  var batchSize: UInt32
  var previewId: Int64

  var wallClock: Date { Date(timeIntervalSince1970: Double(wallClockMicros) / 1_000_000) }
}

struct FlatTable {
  private let bytes: [UInt8]
  private let position: Int

  private static let slotLineage = 0
  private static let slotLogicalTime = 1
  private static let slotStartWidth = 2
  private static let slotStartHeight = 3
  private static let slotSeed = 4
  private static let slotSteps = 5
  private static let slotModel = 8
  private static let slotWallClock = 11
  private static let slotBatchSize = 14
  private static let slotPreviewId = 41

  private init(bytes: [UInt8], position: Int) {
    self.bytes = bytes
    self.position = position
  }

  private func u16(_ at: Int) -> Int? {
    guard at >= 0, at + 2 <= bytes.count else { return nil }
    return Int(bytes[at]) | Int(bytes[at + 1]) << 8
  }

  private func u32(_ at: Int) -> Int? {
    guard at >= 0, at + 4 <= bytes.count else { return nil }
    return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16
      | Int(bytes[at + 3]) << 24
  }

  private func i64(_ at: Int) -> Int64? {
    guard at >= 0, at + 8 <= bytes.count else { return nil }
    var value: UInt64 = 0
    for i in 0..<8 { value |= UInt64(bytes[at + i]) << UInt64(8 * i) }
    return Int64(bitPattern: value)
  }

  private func field(_ slot: Int) -> Int? {
    guard let soffset = u32(position) else { return nil }
    let signed = Int(Int32(truncatingIfNeeded: soffset))
    let vtable = position - signed
    guard let vtableSize = u16(vtable) else { return nil }
    let entry = 4 + 2 * slot
    guard entry + 2 <= vtableSize, let offset = u16(vtable + entry), offset != 0 else { return nil }
    return position + offset
  }

  private func int64(_ slot: Int) -> Int64? { field(slot).flatMap { i64($0) } }
  private func uint32(_ slot: Int) -> UInt32? { field(slot).flatMap { u32($0) }.map { UInt32($0) } }
  private func uint16(_ slot: Int) -> Int? { field(slot).flatMap { u16($0) } }

  private func string(_ slot: Int) -> String? {
    guard let at = field(slot), let relative = u32(at) else { return nil }
    let start = at + relative
    guard let length = u32(start), start + 4 + length <= bytes.count else { return nil }
    return String(decoding: bytes[(start + 4)..<(start + 4 + length)], as: UTF8.self)
  }

  static func decode(rowid: Int64, blob: [UInt8]) -> ProjectNode? {
    func attempt(_ rootAt: Int) -> ProjectNode? {
      guard rootAt + 4 <= blob.count else { return nil }
      let probe = FlatTable(bytes: blob, position: 0)
      guard let relative = probe.u32(rootAt), rootAt + relative < blob.count else { return nil }
      let table = FlatTable(bytes: blob, position: rootAt + relative)
      guard let wall = table.int64(slotWallClock), wall > 1_000_000_000_000_000,
        wall < 4_000_000_000_000_000
      else { return nil }
      return ProjectNode(
        rowid: rowid, lineage: table.int64(slotLineage) ?? 0,
        logicalTime: table.int64(slotLogicalTime) ?? 0, wallClockMicros: wall,
        seed: table.uint32(slotSeed) ?? 0, steps: table.uint32(slotSteps) ?? 0,
        model: table.string(slotModel) ?? "", startWidth: table.uint16(slotStartWidth) ?? 0,
        startHeight: table.uint16(slotStartHeight) ?? 0, batchSize: table.uint32(slotBatchSize) ?? 1,
        previewId: table.int64(slotPreviewId) ?? 0)
    }
    return attempt(0) ?? attempt(4)
  }
}

struct FileTimes: Equatable {
  var mtime: timespec
  var ctime: timespec
  var atime: timespec
  var size: Int64

  static func == (a: FileTimes, b: FileTimes) -> Bool {
    a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec
      && a.ctime.tv_sec == b.ctime.tv_sec && a.ctime.tv_nsec == b.ctime.tv_nsec
      && a.size == b.size
  }

  static func of(_ path: String) -> FileTimes? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return FileTimes(
      mtime: info.st_mtimespec, ctime: info.st_ctimespec, atime: info.st_atimespec,
      size: Int64(info.st_size))
  }

  var description: String {
    func format(_ t: timespec) -> String { "\(t.tv_sec).\(String(format: "%09d", Int(t.tv_nsec)))" }
    return "mtime \(format(mtime)) ctime \(format(ctime)) atime \(format(atime)) size \(size)"
  }
}

final class ProjectLocator {
  enum Quality { case guessed, confirmed }

  struct NodeRef: Equatable {
    var lineage: Int64
    var logicalTime: Int64
  }

  struct Assignment {
    var project: String
    var quality: Quality

    var receipt: NodeRef? = nil
  }

  func path(of project: String) -> String {
    (directory as NSString).appendingPathComponent(project)
  }

  struct Probe {
    var groupId: UUID
    var sentAt: Date
    var seeds: Set<UInt32>
    var model: String
    var steps: Int
  }

  let directory: String
  private let logger: Logger
  private let queue = DispatchQueue(label: "ProjectLocator")
  private let lock = NSLock()
  private var assignments: [UUID: Assignment] = [:]

  init(directory: String, logger: Logger) {
    self.directory = directory
    self.logger = logger
  }

  func assignment(of group: UUID) -> Assignment? {
    lock.lock()
    defer { lock.unlock() }
    return assignments[group]
  }

  func confirmReceipt(project: String, node: NodeRef, for group: UUID) {
    set(Assignment(project: project, quality: .confirmed, receipt: node), for: group)
  }

  func clearReceipt(for group: UUID) {
    guard let current = assignment(of: group) else { return }
    set(Assignment(project: current.project, quality: current.quality, receipt: nil), for: group)
  }

  var onAssignment: ((UUID, Assignment) -> Void)?

  func restore(_ assignment: Assignment, for key: UUID) {
    lock.lock()
    defer { lock.unlock() }
    assignments[key] = assignment
  }

  func assignGuess(project: String, for group: UUID) {
    set(Assignment(project: project, quality: .guessed), for: group)
  }

  private func set(_ assignment: Assignment, for group: UUID) {
    lock.lock()

    if let current = assignments[group], current.quality == .confirmed, assignment.quality == .guessed {
      lock.unlock()
      return
    }
    assignments[group] = assignment
    lock.unlock()
    onAssignment?(group, assignment)
  }

  struct Candidate {
    var name: String
    var path: String
    var activity: Date
  }

  func readability() -> (readable: Bool, projects: Int, error: String?) {
    do {
      let names = try FileManager.default.contentsOfDirectory(atPath: directory)
      return (true, names.filter { $0.hasSuffix(".sqlite3") }.count, nil)
    } catch {
      return (false, 0, "\(error)")
    }
  }

  var canRead: Bool { readability().readable }

  private var warnedUnreadable = false

  func candidates() -> [Candidate] {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory)
    } catch {
      if !warnedUnreadable {
        warnedUnreadable = true
        logger.warning("The projects directory cannot be read, so no project can be assigned: \(error)")
      }
      return []
    }
    var result = [Candidate]()
    for name in names where name.hasSuffix(".sqlite3") {
      let path = (directory as NSString).appendingPathComponent(name)
      guard let main = FileTimes.of(path) else { continue }
      var latest = main.mtime
      if let wal = FileTimes.of(path + "-wal"), wal.size > 0 {
        latest = wal.mtime
      }
      let date = Date(timeIntervalSince1970: Double(latest.tv_sec) + Double(latest.tv_nsec) / 1e9)
      result.append(Candidate(name: name, path: path, activity: date))
    }
    return result.sorted { $0.activity > $1.activity }
  }

  private var drawThingsPID: pid_t = 0

  private static func processPath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
  }

  private func findDrawThings() -> pid_t? {
    if drawThingsPID > 0, let path = Self.processPath(drawThingsPID), path.contains("/Draw Things.app/") {
      return drawThingsPID
    }
    let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard size > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 64)
    let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    for pid in pids.prefix(Int(max(written, 0)) / MemoryLayout<pid_t>.size) where pid > 0 {
      if let path = Self.processPath(pid), path.contains("/Draw Things.app/") {
        drawThingsPID = pid
        return pid
      }
    }
    return nil
  }

  func openProjectNames() -> [String]? {
    guard let pid = findDrawThings() else { return nil }
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return nil }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
    guard got > 0 else { return nil }
    let root = (directory as NSString).standardizingPath
    var names = [String]()
    for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size)
    where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
      var info = vnode_fdinfowithpath()
      let n = proc_pidfdinfo(
        pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
      guard n > 0 else { continue }
      let file = withUnsafePointer(to: &info.pvip.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
      }
      guard file.hasSuffix(".sqlite3"), (file as NSString).deletingLastPathComponent == root else { continue }
      let name = (file as NSString).lastPathComponent
      if !names.contains(name) { names.append(name) }
    }
    return names
  }

  func openProjectFDs() -> [String: Set<Int32>]? {
    guard let pid = findDrawThings() else { return nil }
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return nil }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
    guard got > 0 else { return nil }
    let root = (directory as NSString).standardizingPath
    var result = [String: Set<Int32>]()
    for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size)
    where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
      var info = vnode_fdinfowithpath()
      let n = proc_pidfdinfo(
        pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
      guard n > 0 else { continue }
      let file = withUnsafePointer(to: &info.pvip.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
      }
      guard (file as NSString).deletingLastPathComponent == root else { continue }
      var name = (file as NSString).lastPathComponent
      for suffix in ["-wal", "-shm"] where name.hasSuffix(".sqlite3" + suffix) {
        name = String(name.dropLast(suffix.count))
      }
      guard name.hasSuffix(".sqlite3") else { continue }
      result[name, default: []].insert(fd.proc_fd)
    }
    return result
  }

  private var tracker: ActiveProjectTracker?

  func startTracking() {
    if tracker == nil { tracker = ActiveProjectTracker(locator: self, logger: logger) }
    tracker?.start()
  }

  func activeProject() -> String? {
    tracker?.active
  }

  func bestGuess() -> String? {

    if let tracker = tracker { return tracker.active }
    guard let open = openProjectNames() else { return candidates().first?.name }
    return candidates().first { open.contains($0.name) }?.name ?? open.first
  }

  private func makeCopy(of candidate: Candidate) -> (directory: String, database: String)? {
    let base = NSTemporaryDirectory() + "dt-project-\(UUID().uuidString)"
    do { try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true) }
    catch { return nil }
    let database = base + "/project.sqlite3"
    func clone(_ from: String, _ to: String) -> Bool {
      if clonefile(from, to, 0) == 0 { return true }
      return (try? FileManager.default.copyItem(atPath: from, toPath: to)) != nil
    }
    let wal = candidate.path + "-wal"
    if FileManager.default.fileExists(atPath: wal) {
      guard clone(wal, database + "-wal") else {
        try? FileManager.default.removeItem(atPath: base)
        return nil
      }
    }
    guard clone(candidate.path, database) else {
      try? FileManager.default.removeItem(atPath: base)
      return nil
    }
    return (base, database)
  }

  func newestNodes(of candidate: Candidate, limit: Int) -> [ProjectNode] {
    guard let copy = makeCopy(of: candidate) else { return [] }
    defer { try? FileManager.default.removeItem(atPath: copy.directory) }
    var db: OpaquePointer?
    guard sqlite3_open_v2(copy.database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      sqlite3_close(db)
      return []
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    let sql = "SELECT rowid, p FROM tensorhistorynode ORDER BY rowid DESC LIMIT \(limit)"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    var nodes = [ProjectNode]()
    while sqlite3_step(statement) == SQLITE_ROW {
      let rowid = sqlite3_column_int64(statement, 0)
      guard let pointer = sqlite3_column_blob(statement, 1) else { continue }
      let count = Int(sqlite3_column_bytes(statement, 1))
      let blob = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: count))
      if let node = FlatTable.decode(rowid: rowid, blob: blob) { nodes.append(node) }
    }
    return nodes
  }

  func observe(_ probe: Probe) {

    if assignment(of: probe.groupId) == nil, let open = bestGuess() {
      set(Assignment(project: open, quality: .guessed), for: probe.groupId)
    }
    for delay in [1.3, 3.0, 7.0, 15.0, 30.0] {
      queue.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.check(probe, delay: delay)
      }
    }
  }

  func resolve(_ probe: Probe, now: Date = Date()) -> (Assignment?, String) {

    let all = candidates()
    var recent = all.filter { $0.activity >= probe.sentAt.addingTimeInterval(-0.5) }

    let openName = openProjectNames()?.first { name in all.contains { $0.name == name } }
    if let openName = openName, let open = all.first(where: { $0.name == openName }) {
      recent.removeAll { $0.name == openName }
      recent.insert(open, at: 0)
    }
    var best: Assignment? = nil
    if let first = recent.first { best = Assignment(project: first.name, quality: .guessed) }

    for candidate in recent {
      let nodes = newestNodes(of: candidate, limit: 40)
      let match = nodes.filter {
        abs($0.wallClock.timeIntervalSince(probe.sentAt)) <= 6 && probe.seeds.contains($0.seed)
          && Int($0.steps) == probe.steps && $0.model == probe.model
      }.min { abs($0.wallClock.timeIntervalSince(probe.sentAt)) < abs($1.wallClock.timeIntervalSince(probe.sentAt)) }
      if let match = match {
        return (
          Assignment(
            project: candidate.name, quality: .confirmed,
            receipt: NodeRef(lineage: match.lineage, logicalTime: match.logicalTime)),
          "confirmed: \(candidate.name), node \(match.rowid), \(String(format: "%.1f", match.wallClock.timeIntervalSince(probe.sentAt))) s after the answer"
        )
      }
    }
    if let best = best {
      return (best, "guessed: \(best.project) (\(openName == nil ? "no project known to be open" : "open in Draw Things"), \(recent.count) candidate(s), no matching node yet)")
    }
    return (nil, "unknown: no project was written to since the answer")
  }

  private func check(_ probe: Probe, delay: Double) {
    if assignment(of: probe.groupId)?.quality == .confirmed { return }
    let (found, description) = resolve(probe)
    if let found = found { set(found, for: probe.groupId) }
    logger.info("PROJECT of request \(description) (check after \(delay) s)")
  }
}
