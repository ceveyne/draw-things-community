import Foundation
import Logging
import SQLite3

final class HistoryFixer {
  struct Item {
    let code: String
    let runIndex: Int
    let images: Int
    let seed: UInt32
    let seconds: Double?

    let receipt: ProjectLocator.NodeRef?
    let receiptProject: String?

    var request: RequestData? = nil
  }

  struct RequestData {
    let configuration: Data
    let prompt: String
    let negativePrompt: String
  }

  private let locator: ProjectLocator
  private let logger: Logger
  private let journal: URL?
  private let queue = DispatchQueue(label: "HistoryFixer")

  static let journalAge: TimeInterval = 14 * 24 * 3600

  static let burstMicros: Int64 = 5_000

  private let delays: [Double]

  private let correct: Bool

  init(
    locator: ProjectLocator, journalDirectory: String?, logger: Logger,
    delays: [Double] = [1.5, 3, 7, 15, 30], correct: Bool = true
  ) {
    self.locator = locator
    self.logger = logger
    self.delays = delays
    self.correct = correct
    journal = journalDirectory.map { URL(fileURLWithPath: $0).appendingPathComponent("history-journal.jsonl") }
    pruneJournal()
    if journal == nil {
      logger.warning("History nodes are not corrected: without a state directory there is no journal to undo a change with")
    }
  }

  var isActive: Bool { journal != nil }

  func expect(
    items: [Item], project: String, sentAt: Date, closing: Int,
    onClosing: ((ProjectLocator.NodeRef, NodeTable) -> Void)? = nil
  ) {
    guard journal != nil, !items.isEmpty || closing > 0 else { return }

    guard correct || onClosing != nil else { return }
    let images = items.reduce(0) { $0 + $1.images }
    note("HISTORY waiting for \(images + closing) nodes in \(project) (\(images) images, \(closing) status image) of the delivery")
    for (index, delay) in delays.enumerated() {
      queue.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self = self else { return }
        if self.state(for: sentAt) == .done { return }
        let last = index == delays.count - 1
        if self.attempt(items: items, project: project, sentAt: sentAt, closing: closing, last: last, onClosing: onClosing) {
          self.finish(sentAt)
        }
      }
    }
  }

  private enum Progress { case open, done }
  private var finished = Set<Date>()
  private func state(for key: Date) -> Progress { finished.contains(key) ? .done : .open }
  private func finish(_ key: Date) { finished.insert(key) }

  private func attempt(
    items: [Item], project: String, sentAt: Date, closing: Int, last: Bool,
    onClosing: ((ProjectLocator.NodeRef, NodeTable) -> Void)?
  ) -> Bool {
    let path = locator.path(of: project)
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database = handle else {
      warn("HISTORY \(project) cannot be opened for writing: \(String(cString: sqlite3_errmsg(handle)))")
      sqlite3_close(handle)
      return true
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 5000)

    let expected = items.reduce(0) { $0 + $1.images } + closing
    let wallClock = HistoryCorrector.slot("wall_clock")
    let since = Int64(sentAt.timeIntervalSince1970 * 1_000_000) - 1_000_000
    var recent = [(row: HistoryCorrector.Row, table: NodeTable, wall: Int64)]()
    for row in HistoryCorrector.rows(in: database, newest: 80) {
      guard let table = try? HistoryCorrector.decode(row.blob), case .scalar(let bits, _)? = table[wallClock] else { continue }
      let wall = Int64(bitPattern: bits)
      if wall >= since { recent.append((row, table, wall)) }
    }
    recent.sort { ($0.wall, $0.row.logicalTime) < ($1.wall, $1.row.logicalTime) }

    var bursts = [[(row: HistoryCorrector.Row, table: NodeTable, wall: Int64)]]()
    for node in recent {
      if let first = bursts.last?.first, node.wall - first.wall <= Self.burstMicros {
        bursts[bursts.count - 1].append(node)
      } else {
        bursts.append([node])
      }
    }
    let fitting = bursts.filter { $0.count == expected }
    if fitting.count > 1 {
      warn("HISTORY \(fitting.count) bursts of \(expected) nodes in \(project), which one is ambiguous: nothing changed")
      return true
    }
    guard let burst = fitting.first else {
      if last {
        warn("HISTORY no burst of \(expected) nodes found in \(project) (bursts: \(bursts.map { $0.count })): nothing changed")
        return true
      }
      return false
    }

    let consecutive = zip(burst, burst.dropFirst()).allSatisfy {
      $0.row.lineage == $1.row.lineage && $1.row.logicalTime == $0.row.logicalTime + 1
    }
    guard consecutive else {
      warn("HISTORY the nodes of the burst in \(project) are not consecutive: nothing changed")
      return true
    }

    if closing > 0, let node = burst.last {
      onClosing?(ProjectLocator.NodeRef(lineage: node.row.lineage, logicalTime: node.row.logicalTime), node.table)
    }
    guard correct else { return true }
    var position = 0
    for item in items {
      var seed = item.seed
      for _ in 0..<item.images {
        let node = burst[position]
        position += 1
        fix(node: node.row, table: node.table, item: item, seed: seed, project: project, in: database)
        seed = Self.nextSeed(after: seed)
      }
    }
    return true
  }

  static func nextSeed(after seed: UInt32) -> UInt32 {
    var x = seed == 0 ? 0xbad5eed : seed
    x ^= x << 13
    x ^= x >> 17
    x ^= x << 5
    return x
  }

  private func fix(node row: HistoryCorrector.Row, table: NodeTable, item: Item, seed: UInt32, project: String, in database: OpaquePointer) {
    let name = "\(item.code) run \(item.runIndex)"
    var origin = ""
    let receipt: NodeTable
    do {
      if let request = item.request {
        let configuration = try HistoryCorrector.decodeConfiguration(request.configuration)
        let slotLineage = HistoryCorrector.slot("text_lineage")
        let slotEdits = HistoryCorrector.slot("text_edits")
        var current: (lineage: Int64, edits: Int64)? = nil
        if case .scalar(let l, _)? = table[slotLineage], case .scalar(let e, _)? = table[slotEdits] {
          current = (Int64(bitPattern: l), Int64(bitPattern: e))
        }
        let pointer = TextStream.pointer(
          in: database, prompt: request.prompt, negativePrompt: request.negativePrompt, current: current)
        if pointer == nil {
          warn("HISTORY node \(row.lineage)/\(row.logicalTime) of \(name): the prompt of the request is not in the prompt stream of \(project), the prompt of the node stays")
        }
        receipt = HistoryCorrector.synthetic(
          delivered: table, configuration: configuration, prompt: request.prompt,
          negativePrompt: request.negativePrompt, pointer: pointer)
        origin = "its request (prompt stream point \(pointer.map { "\($0.lineage)/\($0.edits)" } ?? "unchanged"))"
      } else {
        guard let reference = item.receipt, item.receiptProject == project else {
          warn("HISTORY node \(row.lineage)/\(row.logicalTime) of \(name) left as it is: its receipt is not known in \(project)")
          return
        }
        guard let receiptBlob = HistoryCorrector.blob(in: database, lineage: reference.lineage, logicalTime: reference.logicalTime)
        else {
          warn("HISTORY node \(row.lineage)/\(row.logicalTime) of \(name) left as it is: the receipt \(reference.lineage)/\(reference.logicalTime) is gone")
          return
        }
        receipt = try HistoryCorrector.decode(receiptBlob)
        origin = "the receipt \(reference.lineage)/\(reference.logicalTime)"
      }
      let fixed = HistoryCorrector.corrected(
        delivered: table, receipt: receipt, seed: seed, generationSeconds: item.seconds)
      if let problem = HistoryCorrector.verify(fixed) {
        warn("HISTORY node \(row.lineage)/\(row.logicalTime) of \(name) left as it is: \(problem)")
        return
      }
      let changed = HistoryCorrector.differences(table, fixed)
      if changed.isEmpty { return }
      let blob = HistoryCorrector.encode(fixed)
      guard record(project: project, row: row, new: blob) else {
        warn("HISTORY node \(row.lineage)/\(row.logicalTime) of \(name) left as it is: the journal could not be written")
        return
      }
      if HistoryCorrector.replace(
        in: database, lineage: row.lineage, logicalTime: row.logicalTime, expected: row.blob, with: blob)
      {
        note("HISTORY node \(row.lineage)/\(row.logicalTime) of \(name) in \(project) rebuilt from \(origin): \(changed.count) fields (\(changed.prefix(12).joined(separator: ", "))\(changed.count > 12 ? ", …" : ""))"
        )
      } else {
        warn("HISTORY node \(row.lineage)/\(row.logicalTime) of \(name) was changed by someone else meanwhile: left as it is")
      }
    } catch {
      warn("HISTORY node \(row.lineage)/\(row.logicalTime) of \(name) left as it is: \(error)")
    }
  }

  private func note(_ text: String) {
    logger.info("\(text)")
    FileLog.shared.append(text)
  }

  private func warn(_ text: String) {
    logger.warning("\(text)")
    FileLog.shared.append("WARNING " + text)
  }

  private func record(project: String, row: HistoryCorrector.Row, new: Data) -> Bool {
    guard let journal = journal else { return false }
    let object: [String: Any] = [
      "at": Date().timeIntervalSince1970, "project": project, "lineage": row.lineage,
      "logical": row.logicalTime, "old": row.blob.map { String(format: "%02x", $0) }.joined(),
      "new": new.map { String(format: "%02x", $0) }.joined(),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return false }
    do {
      if !FileManager.default.fileExists(atPath: journal.path) {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: journal.path, contents: nil)
      }
      let handle = try FileHandle(forWritingTo: journal)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data + Data("\n".utf8))
      try handle.synchronize()
      return true
    } catch {
      return false
    }
  }

  private func pruneJournal() {
    guard let journal = journal, let text = try? String(contentsOf: journal, encoding: .utf8) else { return }
    let oldest = Date().addingTimeInterval(-Self.journalAge).timeIntervalSince1970
    let kept = text.split(separator: "\n").filter { line in
      guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let at = object["at"] as? Double
      else { return false }
      return at >= oldest
    }
    try? (kept.map(String.init).joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).write(to: journal, atomically: true, encoding: .utf8)
  }
}
