import Foundation
import SQLite3

enum NodeDeleter {
  private static let nodeIndexes = ["f22", "f24", "f48", "f60", "f62", "f66", "f70", "f86"]
  private static let dataIndexes = ["f20", "f22", "f24", "f26", "f28", "f30", "f32"]

  enum Outcome {
    case deleted(rows: Int)
    case skipped(String)
  }

  static func delete(
    project path: String, lineage: Int64, logicalTime: Int64, newerBy: TimeInterval, undoFile: URL?
  ) -> Outcome {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
      let message = String(cString: sqlite3_errmsg(handle))
      sqlite3_close(handle)
      return .skipped("cannot be opened for writing: \(message)")
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5000)

    func prepare(_ sql: String, _ bind: [Int64] = []) -> OpaquePointer? {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
      for (index, value) in bind.enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), value) }
      return statement
    }
    func ints(_ sql: String, _ bind: [Int64] = []) -> [Int64] {
      guard let statement = prepare(sql, bind) else { return [] }
      defer { sqlite3_finalize(statement) }
      var result = [Int64]()
      while sqlite3_step(statement) == SQLITE_ROW { result.append(sqlite3_column_int64(statement, 0)) }
      return result
    }
    func run(_ sql: String, _ bind: [Int64] = []) -> Bool {
      guard let statement = prepare(sql, bind) else { return false }
      defer { sqlite3_finalize(statement) }
      return sqlite3_step(statement) == SQLITE_DONE
    }
    func text(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

    func snapshot(_ table: String, where clause: String, _ bind: [Int64]) -> [String] {
      guard let statement = prepare("SELECT * FROM \(table) WHERE \(clause)", bind) else { return [] }
      defer { sqlite3_finalize(statement) }
      var result = [String]()
      while sqlite3_step(statement) == SQLITE_ROW {
        var columns = [String]()
        var values = [String]()
        for index in 0..<sqlite3_column_count(statement) {
          columns.append(String(cString: sqlite3_column_name(statement, index)))
          switch sqlite3_column_type(statement, index) {
          case SQLITE_NULL: values.append("NULL")
          case SQLITE_INTEGER: values.append(String(sqlite3_column_int64(statement, index)))
          case SQLITE_FLOAT: values.append(String(sqlite3_column_double(statement, index)))
          case SQLITE_TEXT: values.append(text(String(cString: sqlite3_column_text(statement, index))))
          default:
            let count = Int(sqlite3_column_bytes(statement, index))
            let data = count > 0 ? Data(bytes: sqlite3_column_blob(statement, index), count: count) : Data()
            values.append("X'" + data.map { String(format: "%02x", $0) }.joined() + "'")
          }
        }
        result.append("INSERT INTO \(table) (\(columns.joined(separator: ","))) VALUES (\(values.joined(separator: ",")));")
      }
      return result
    }

    guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return .skipped("the project is busy") }
    var committed = false
    defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }

    guard let blob = HistoryCorrector.blob(in: db, lineage: lineage, logicalTime: logicalTime),
      let node = try? HistoryCorrector.decode(blob),
      let rowid = ints("SELECT rowid FROM tensorhistorynode WHERE __pk0 = ? AND __pk1 = ?", [lineage, logicalTime]).first
    else { return .skipped("the node \(lineage)/\(logicalTime) is not there") }

    var wallClock: Int64 = 0
    if case .scalar(let bits, _)? = node[HistoryCorrector.slot("wall_clock")] { wallClock = Int64(bitPattern: bits) }
    let wall = HistoryCorrector.slot("wall_clock")
    var newest: Int64 = 0
    for row in HistoryCorrector.rows(in: db, newest: 40) {
      if let table = try? HistoryCorrector.decode(row.blob), case .scalar(let bits, _)? = table[wall] {
        newest = max(newest, Int64(bitPattern: bits))
      }
    }
    guard newest - wallClock >= Int64(newerBy * 1_000_000) else {
      return .skipped("no node was written after it yet")
    }

    var preview: Int64 = 0
    if case .scalar(let bits, _)? = node[HistoryCorrector.slot("preview_id")] { preview = Int64(bitPattern: bits) }
    let dataRows = ints("SELECT rowid FROM tensordata WHERE __pk0 = ? AND __pk1 = ?", [lineage, logicalTime])
    var tensorIDs = Set<Int64>()
    for row in dataRows {
      for index in dataIndexes {
        tensorIDs.formUnion(ints("SELECT f\(index.dropFirst()) FROM tensordata__\(index) WHERE rowid = ?", [row]).filter { $0 != 0 })
      }
    }

    var stillUsed = Set<Int64>()
    for id in tensorIDs {
      for index in dataIndexes {
        let others = ints(
          "SELECT COUNT(*) FROM tensordata__\(index) d JOIN tensordata x ON x.rowid = d.rowid WHERE d.\(index) = ? AND NOT (x.__pk0 = ? AND x.__pk1 = ?)",
          [id, lineage, logicalTime]).first ?? 0
        if others > 0 { stillUsed.insert(id) }
      }
    }
    let previewShared = preview != 0 && (ints("SELECT COUNT(*) FROM tensorhistorynode__f86 WHERE f86 = ? AND rowid <> ?", [preview, rowid]).first ?? 0) > 0

    var undo = [String]()
    for row in dataRows {
      undo += snapshot("tensordata", where: "rowid = ?", [row])
      for index in dataIndexes { undo += snapshot("tensordata__\(index)", where: "rowid = ?", [row]) }
    }
    undo += snapshot("tensorhistorynode", where: "rowid = ?", [rowid])
    for index in nodeIndexes { undo += snapshot("tensorhistorynode__\(index)", where: "rowid = ?", [rowid]) }
    if preview != 0 && !previewShared {
      undo += snapshot("thumbnailhistorynode", where: "__pk0 = ?", [preview])
      undo += snapshot("thumbnailhistoryhalfnode", where: "__pk0 = ?", [preview])
    }
    for id in tensorIDs.subtracting(stillUsed) {
      var statement = prepare("SELECT rowid FROM tensors WHERE name = '\("tensor_history_\(id)")'")
      defer { sqlite3_finalize(statement) }
      while let s = statement, sqlite3_step(s) == SQLITE_ROW {
        undo += snapshot("tensors", where: "rowid = ?", [sqlite3_column_int64(s, 0)])
      }
      statement = statement.map { $0 }
    }
    if let undoFile = undoFile {
      let line = "-- receipt \(lineage)/\(logicalTime) of \(path) deleted at \(Date())\n" + undo.joined(separator: "\n") + "\n"
      if !FileManager.default.fileExists(atPath: undoFile.path) {
        try? FileManager.default.createDirectory(at: undoFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: undoFile.path, contents: nil)
      }
      guard let handle = try? FileHandle(forWritingTo: undoFile), let data = line.data(using: .utf8) else {
        return .skipped("the undo journal cannot be written")
      }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      do { try handle.write(contentsOf: data); try handle.synchronize() } catch { return .skipped("the undo journal cannot be written") }
    }

    var ok = true
    for row in dataRows {
      for index in dataIndexes { ok = ok && run("DELETE FROM tensordata__\(index) WHERE rowid = ?", [row]) }
      ok = ok && run("DELETE FROM tensordata WHERE rowid = ?", [row])
    }
    for index in nodeIndexes { ok = ok && run("DELETE FROM tensorhistorynode__\(index) WHERE rowid = ?", [rowid]) }
    ok = ok && run("DELETE FROM tensorhistorynode WHERE rowid = ?", [rowid])
    if preview != 0 && !previewShared {
      ok = ok && run("DELETE FROM thumbnailhistorynode WHERE __pk0 = ?", [preview])
      ok = ok && run("DELETE FROM thumbnailhistoryhalfnode WHERE __pk0 = ?", [preview])
    }
    for id in tensorIDs.subtracting(stillUsed) {
      ok = ok && sqlite3_exec(db, "DELETE FROM tensors WHERE name = 'tensor_history_\(id)'", nil, nil, nil) == SQLITE_OK
    }
    guard ok, sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { return .skipped("a statement failed, nothing changed") }
    committed = true
    return .deleted(rows: undo.count)
  }
}
