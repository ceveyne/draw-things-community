import Foundation
import SQLite3

enum TextStream {
  struct State {
    let lineage: Int64
    let edits: Int64
    let positive: String
    let negative: String
  }

  private struct Reader {
    let bytes: [UInt8]

    func u8(_ at: Int) -> Int { at >= 0 && at < bytes.count ? Int(bytes[at]) : 0 }
    func u16(_ at: Int) -> Int { u8(at) | (u8(at + 1) << 8) }
    func u32(_ at: Int) -> Int { u16(at) | (u16(at + 2) << 16) }
    func i32(_ at: Int) -> Int { Int(Int32(truncatingIfNeeded: u32(at))) }
    func i64(_ at: Int) -> Int64 {
      var value: UInt64 = 0
      for index in 0..<8 { value |= UInt64(u8(at + index)) << UInt64(8 * index) }
      return Int64(bitPattern: value)
    }

    func slot(_ table: Int, _ index: Int) -> Int? {
      let vtable = table - i32(table)
      let size = u16(vtable)
      let entry = 4 + 2 * index
      guard entry + 2 <= size else { return nil }
      let offset = u16(vtable + entry)
      return offset == 0 ? nil : table + offset
    }

    func string(at position: Int) -> String {
      let start = position + u32(position)
      let count = u32(start)
      guard start + 4 + count <= bytes.count else { return "" }
      return String(decoding: bytes[(start + 4)..<(start + 4 + count)], as: UTF8.self)
    }
  }

  static func states(in database: OpaquePointer) -> [State] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT __pk0, __pk1, p FROM texthistorynode", -1, &statement, nil) == SQLITE_OK
    else { return [] }
    defer { sqlite3_finalize(statement) }
    var result = [State]()
    while sqlite3_step(statement) == SQLITE_ROW {
      let length = Int(sqlite3_column_bytes(statement, 2))
      guard length > 8, let raw = sqlite3_column_blob(statement, 2) else { continue }
      let reader = Reader(bytes: [UInt8](UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: length)))
      let table = reader.u32(0)
      let lineage = reader.slot(table, 0).map { reader.i64($0) } ?? sqlite3_column_int64(statement, 0)
      let start = reader.slot(table, 2).map { reader.i64($0) } ?? 0
      var positive = Array((reader.slot(table, 3).map { reader.string(at: $0) } ?? "").utf16)
      var negative = Array((reader.slot(table, 4).map { reader.string(at: $0) } ?? "").utf16)
      result.append(State(lineage: lineage, edits: start, positive: String(decoding: positive, as: UTF16.self), negative: String(decoding: negative, as: UTF16.self)))
      guard let vectorField = reader.slot(table, 5) else { continue }
      let vector = vectorField + reader.u32(vectorField)
      let count = reader.u32(vector)
      for index in 0..<count {
        let entry = vector + 4 + 4 * index
        let modification = entry + reader.u32(entry)
        let type = reader.slot(modification, 0).map { reader.u8($0) } ?? 0
        var location = 0
        var span = 0
        if let range = reader.slot(modification, 1) {
          location = reader.i32(range)
          span = reader.i32(range + 4)
        }
        let text = Array((reader.slot(modification, 2).map { reader.string(at: $0) } ?? "").utf16)

        func apply(_ target: inout [UInt16]) {
          let from = min(max(location, 0), target.count)
          let to = min(max(location + span, from), target.count)
          target.replaceSubrange(from..<to, with: text)
        }
        if type == 0 { apply(&positive) } else { apply(&negative) }
        result.append(
          State(
            lineage: lineage, edits: start + Int64(index) + 1,
            positive: String(decoding: positive, as: UTF16.self), negative: String(decoding: negative, as: UTF16.self)))
      }
    }
    return result
  }

  static func pointer(
    in database: OpaquePointer, prompt: String, negativePrompt: String, current: (lineage: Int64, edits: Int64)?
  ) -> (lineage: Int64, edits: Int64)? {
    let fitting = states(in: database).filter { $0.positive == prompt && $0.negative == negativePrompt }
    if let current = current, fitting.contains(where: { $0.lineage == current.lineage && $0.edits == current.edits }) {
      return current
    }
    guard let best = fitting.max(by: { ($0.lineage, $0.edits) < ($1.lineage, $1.edits) }) else { return nil }
    return (best.lineage, best.edits)
  }
}
