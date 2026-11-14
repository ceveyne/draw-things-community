import Foundation
import SQLite3

indirect enum NodeValue: Equatable {
  case scalar(UInt64, Int)
  case bytes(Data)
  case strings([Data])
  case tables([NodeTable])
}

typealias NodeTable = [Int: NodeValue]

enum HistoryCorrector {
  enum Failure: Error, CustomStringConvertible {
    case malformed(String)
    case unknownFields(slots: Int, known: Int)

    var description: String {
      switch self {
      case .malformed(let what): return "malformed node: \(what)"
      case .unknownFields(let slots, let known):
        return "the node has \(slots) fields, this proxy knows \(known): the schema is newer, run generate-node-layout.py"
      }
    }
  }

  static let kept: Set<String> = [
    "lineage", "logical_time", "wall_clock", "reason",
    "tensor_id", "mask_id", "depth_map_id", "scribble_id", "pose_id", "color_palette_id", "custom_id",
    "preview_id", "data_stored", "shuffle_data_stored",
    "clip_id", "index_in_a_clip", "num_frames",
    "profile_data", "generation_time",
  ]

  static func layout(_ type: NodeTableType) -> [NodeField] {
    switch type {
    case .node: return NodeLayout.node
    case .control: return NodeLayout.control
    case .lora: return NodeLayout.lora
    case .configuration: return NodeLayout.configuration
    }
  }

  static func slot(_ name: String) -> Int {
    guard let index = NodeLayout.node.firstIndex(where: { $0.name == name }) else {
      fatalError("the node has no field \(name)")
    }
    return index
  }

  private struct Reader {
    let data: Data

    func bytes(_ position: Int, _ count: Int) throws -> Data {
      guard position >= 0, count >= 0, position + count <= data.count else {
        throw Failure.malformed("read of \(count) bytes at \(position) of \(data.count)")
      }
      return data.subdata(in: (data.startIndex + position)..<(data.startIndex + position + count))
    }

    func uint(_ position: Int, size: Int) throws -> UInt64 {
      var value: UInt64 = 0
      for (index, byte) in try bytes(position, size).enumerated() { value |= UInt64(byte) << UInt64(8 * index) }
      return value
    }

    func int32(_ position: Int) throws -> Int { Int(Int32(truncatingIfNeeded: try uint(position, size: 4))) }
    func uint32(_ position: Int) throws -> Int { Int(try uint(position, size: 4)) }
    func uint16(_ position: Int) throws -> Int { Int(try uint(position, size: 2)) }

    func blob(at field: Int, element: Int) throws -> Data {
      let start = field + (try uint32(field))
      let count = try uint32(start)
      return try bytes(start + 4, count * element)
    }
  }

  static func decode(_ blob: Data) throws -> NodeTable {
    let reader = Reader(data: blob)
    return try decodeTable(reader, at: try reader.uint32(0), type: .node)
  }

  static func decodeConfiguration(_ blob: Data) throws -> NodeTable {
    let reader = Reader(data: blob)
    return try decodeTable(reader, at: try reader.uint32(0), type: .configuration)
  }

  private static func decodeTable(_ reader: Reader, at table: Int, type: NodeTableType) throws -> NodeTable {
    let fields = layout(type)
    let vtable = table - (try reader.int32(table))
    let size = try reader.uint16(vtable)
    guard size >= 4, size % 2 == 0 else { throw Failure.malformed("vtable of \(size) bytes") }
    let slots = (size - 4) / 2
    guard slots <= fields.count else { throw Failure.unknownFields(slots: slots, known: fields.count) }
    var result = NodeTable()
    for slot in 0..<slots {
      let offset = try reader.uint16(vtable + 4 + 2 * slot)
      if offset == 0 { continue }
      let position = table + offset
      switch fields[slot].kind {
      case .scalar(let width):
        result[slot] = .scalar(try reader.uint(position, size: width), width)
      case .string, .bytes:
        result[slot] = .bytes(try reader.blob(at: position, element: 1))
      case .strings:
        let vector = position + (try reader.uint32(position))
        let count = try reader.uint32(vector)
        var items = [Data]()
        for index in 0..<count { items.append(try reader.blob(at: vector + 4 + 4 * index, element: 1)) }
        result[slot] = .strings(items)
      case .tables(let kind):
        let vector = position + (try reader.uint32(position))
        let count = try reader.uint32(vector)
        var items = [NodeTable]()
        for index in 0..<count {
          let entry = vector + 4 + 4 * index
          items.append(try decodeTable(reader, at: entry + (try reader.uint32(entry)), type: kind))
        }
        result[slot] = .tables(items)
      }
    }
    return result
  }

  static func encode(_ node: NodeTable) -> Data {
    var buffer = [UInt8](repeating: 0, count: 8)
    let table = writeTable(&buffer, node, type: .node)
    put(&buffer, at: 0, UInt64(table), size: 4)
    return Data(buffer)
  }

  private static func put(_ buffer: inout [UInt8], at position: Int, _ value: UInt64, size: Int) {
    for index in 0..<size { buffer[position + index] = UInt8((value >> UInt64(8 * index)) & 0xFF) }
  }

  private static func align(_ buffer: inout [UInt8], to alignment: Int) {
    while buffer.count % alignment != 0 { buffer.append(0) }
  }

  private static func writeBlob(_ buffer: inout [UInt8], _ bytes: Data, terminated: Bool) -> Int {
    align(&buffer, to: 4)
    let position = buffer.count
    buffer += [UInt8](repeating: 0, count: 4)
    put(&buffer, at: position, UInt64(bytes.count), size: 4)
    buffer += bytes
    if terminated { buffer.append(0) }
    return position
  }

  private static func writeTable(_ buffer: inout [UInt8], _ values: NodeTable, type: NodeTableType) -> Int {
    let fields = layout(type)
    let slots = (values.keys.max() ?? -1) + 1

    var offsets = [Int: Int]()
    var cursor = 4
    let widths = values.mapValues { value -> Int in
      if case .scalar(_, let width) = value { return width }
      return 4
    }
    for slot in values.keys.sorted(by: { (widths[$0]!, -$0) > (widths[$1]!, -$1) }) {
      let width = widths[slot]!
      cursor = (cursor + width - 1) / width * width
      offsets[slot] = cursor
      cursor += width
    }
    let tableSize = cursor

    align(&buffer, to: 4)
    let vtable = buffer.count
    buffer += [UInt8](repeating: 0, count: 4 + 2 * slots)
    put(&buffer, at: vtable, UInt64(4 + 2 * slots), size: 2)
    put(&buffer, at: vtable + 2, UInt64(tableSize), size: 2)
    for slot in 0..<slots { put(&buffer, at: vtable + 4 + 2 * slot, UInt64(offsets[slot] ?? 0), size: 2) }
    align(&buffer, to: 8)
    let table = buffer.count
    buffer += [UInt8](repeating: 0, count: tableSize)
    put(&buffer, at: table, UInt64(UInt32(truncatingIfNeeded: table - vtable)), size: 4)
    for (slot, value) in values {
      if case .scalar(let bits, let width) = value { put(&buffer, at: table + offsets[slot]!, bits, size: width) }
    }

    for slot in values.keys.sorted() {
      let field = table + offsets[slot]!
      switch values[slot]! {
      case .scalar:
        break
      case .bytes(let bytes):
        var terminated = false
        if case .string = fields[slot].kind { terminated = true }
        let child = writeBlob(&buffer, bytes, terminated: terminated)
        put(&buffer, at: field, UInt64(child - field), size: 4)
      case .strings(let items):
        align(&buffer, to: 4)
        let vector = buffer.count
        buffer += [UInt8](repeating: 0, count: 4 + 4 * items.count)
        put(&buffer, at: vector, UInt64(items.count), size: 4)
        put(&buffer, at: field, UInt64(vector - field), size: 4)
        for (index, item) in items.enumerated() {
          let child = writeBlob(&buffer, item, terminated: true)
          put(&buffer, at: vector + 4 + 4 * index, UInt64(child - (vector + 4 + 4 * index)), size: 4)
        }
      case .tables(let items):
        guard case .tables(let kind) = fields[slot].kind else { fatalError("not a table list") }
        align(&buffer, to: 4)
        let vector = buffer.count
        buffer += [UInt8](repeating: 0, count: 4 + 4 * items.count)
        put(&buffer, at: vector, UInt64(items.count), size: 4)
        put(&buffer, at: field, UInt64(vector - field), size: 4)
        for (index, item) in items.enumerated() {
          let child = writeTable(&buffer, item, type: kind)
          put(&buffer, at: vector + 4 + 4 * index, UInt64(child - (vector + 4 + 4 * index)), size: 4)
        }
      }
    }
    return table
  }

  static func corrected(
    delivered: NodeTable, receipt: NodeTable, seed: UInt32?, generationSeconds: Double?
  ) -> NodeTable {
    var result = NodeTable()
    let keptSlots = Set(kept.map { slot($0) })
    for (index, _) in NodeLayout.node.enumerated() {
      let source = keptSlots.contains(index) ? delivered : receipt
      if let value = source[index] { result[index] = value }
    }
    if let seed = seed { result[slot("seed")] = .scalar(UInt64(seed), 4) }
    if let seconds = generationSeconds {
      result[slot("generation_time")] = .scalar(seconds.bitPattern, 8)
    }
    return result
  }

  static func synthetic(
    delivered: NodeTable, configuration: NodeTable, prompt: String, negativePrompt: String,
    pointer: (lineage: Int64, edits: Int64)?
  ) -> NodeTable {
    var result = delivered
    var nodeSlots = [String: Int]()
    for (index, field) in NodeLayout.node.enumerated() { nodeSlots[field.name] = index }

    let configurationDefaults: [String: Float] = ["aesthetic_score": 6, "negative_aesthetic_score": 2.5, "refiner_start": 0.7]
    for (cslot, field) in NodeLayout.configuration.enumerated() {
      guard let nslot = nodeSlots[field.name] else { continue }
      if let value = configuration[cslot] {
        result[nslot] = value
      } else if let value = configurationDefaults[field.name] {
        result[nslot] = .scalar(UInt64(value.bitPattern), 4)
      } else {
        result[nslot] = nil
      }
    }
    result[slot("text_prompt")] = prompt.isEmpty ? nil : .bytes(Data(prompt.utf8))
    result[slot("negative_text_prompt")] = negativePrompt.isEmpty ? nil : .bytes(Data(negativePrompt.utf8))
    if let pointer = pointer {
      result[slot("text_lineage")] = .scalar(UInt64(bitPattern: pointer.lineage), 8)
      result[slot("text_edits")] = .scalar(UInt64(bitPattern: pointer.edits), 8)
    }
    return result
  }

  static func fingerprint(_ table: NodeTable, layout: [NodeField], excluding names: Set<String>) -> String {
    func describe(_ value: NodeValue) -> String {
      switch value {
      case .scalar(let bits, let size): return "s\(size):\(bits)"
      case .bytes(let data): return "b:" + data.map { String(format: "%02x", $0) }.joined()
      case .strings(let items): return "[" + items.map { $0.map { String(format: "%02x", $0) }.joined() }.joined(separator: ",") + "]"
      case .tables(let items):
        return "{" + items.map { entry in entry.keys.sorted().map { "\($0)=\(describe(entry[$0]!))" }.joined(separator: ";") }.joined(separator: "|") + "}"
      }
    }
    return table.keys.sorted().compactMap { slot -> String? in
      guard slot < layout.count, !names.contains(layout[slot].name), let value = table[slot] else { return nil }
      return "\(layout[slot].name)=\(describe(value))"
    }.joined(separator: ";")
  }

  static func differences(_ a: NodeTable, _ b: NodeTable) -> [String] {
    NodeLayout.node.enumerated().compactMap { index, field in a[index] == b[index] ? nil : field.name }
  }

  static func verify(_ intended: NodeTable) -> String? {
    do {
      let again = try decode(encode(intended))
      let wrong = differences(intended, again)
      return wrong.isEmpty ? nil : "differs after a round trip: \(wrong.joined(separator: ", "))"
    } catch {
      return "\(error)"
    }
  }

  struct Row {
    let lineage: Int64
    let logicalTime: Int64
    let blob: Data
  }

  static func rows(in database: OpaquePointer, newest limit: Int? = nil) -> [Row] {
    var statement: OpaquePointer?
    let sql =
      limit.map { "SELECT __pk0, __pk1, p FROM tensorhistorynode ORDER BY rowid DESC LIMIT \($0)" }
      ?? "SELECT __pk0, __pk1, p FROM tensorhistorynode ORDER BY __pk0, __pk1"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    var result = [Row]()
    while sqlite3_step(statement) == SQLITE_ROW {
      let size = Int(sqlite3_column_bytes(statement, 2))
      let blob = sqlite3_column_blob(statement, 2).map { Data(bytes: $0, count: size) } ?? Data()
      result.append(Row(lineage: sqlite3_column_int64(statement, 0), logicalTime: sqlite3_column_int64(statement, 1), blob: blob))
    }
    return limit == nil ? result : result.reversed()
  }

  static func blob(in database: OpaquePointer, lineage: Int64, logicalTime: Int64) -> Data? {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT p FROM tensorhistorynode WHERE __pk0 = ?1 AND __pk1 = ?2", -1, &statement, nil)
        == SQLITE_OK
    else { return nil }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, lineage)
    sqlite3_bind_int64(statement, 2, logicalTime)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    let size = Int(sqlite3_column_bytes(statement, 0))
    return sqlite3_column_blob(statement, 0).map { Data(bytes: $0, count: size) }
  }

  static func replace(
    in database: OpaquePointer, lineage: Int64, logicalTime: Int64, expected: Data, with new: Data
  ) -> Bool {
    var statement: OpaquePointer?
    let sql = "UPDATE tensorhistorynode SET p = ?1 WHERE __pk0 = ?2 AND __pk1 = ?3 AND p = ?4"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    new.withUnsafeBytes { _ = sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(new.count), transient) }
    sqlite3_bind_int64(statement, 2, lineage)
    sqlite3_bind_int64(statement, 3, logicalTime)
    expected.withUnsafeBytes { _ = sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(expected.count), transient) }
    guard sqlite3_step(statement) == SQLITE_DONE else { return false }
    return sqlite3_changes(database) == 1
  }
}
