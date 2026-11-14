import Foundation
import GRPCImageServiceModels
import Logging

final class ResultStore {
  struct Record: Codable {
    var id: UUID
    var groupId: UUID
    var groupCode: String
    var groupKey: String
    var expected: Int
    var groupCreatedAt: Date
    var runIndex: Int
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var width: Int
    var height: Int
    var batchSize: Int
    var totalSteps: Int
    var model: String
    var prompt: String
    var seed: UInt32
    var imageCount: Int

    var project: String? = nil

    var configuration: Data? = nil
    var negativePrompt: String? = nil

    var origin: Group.Origin? = nil

    var tool: Group.ToolInfo? = nil

    var delivered: Bool? = nil

    var evicted: Bool? = nil

    var completeImages: Int? = nil
    var hasAudio: Bool? = nil
  }

  struct Entry {
    var record: Record
    var directory: URL
  }

  static let budgetBytes = 16 * 1024 * 1024 * 1024

  static let maxAge: TimeInterval = 90 * 24 * 3600

  private let root: URL

  private let openRoot: URL
  private let logger: Logger
  private let lock = NSLock()

  var projectProvider: ((UUID) -> String?)?

  init(directory: String, logger: Logger) throws {
    root = URL(fileURLWithPath: directory).appendingPathComponent("results")
    openRoot = URL(fileURLWithPath: directory).appendingPathComponent("open")
    self.logger = logger
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: openRoot, withIntermediateDirectories: true)
  }

  private func directory(of id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }

  func spoolDirectory(for id: UUID) -> URL { directory(of: id) }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }

  private func record(of job: Job, imageCount: Int) -> Record {
    let snapshot = job.snapshot()
    let group = job.group
    return Record(
      id: job.id, groupId: group.id, groupCode: group.code, groupKey: group.key,
      expected: group.expected, groupCreatedAt: group.createdAt, runIndex: job.runIndex,
      createdAt: job.createdAt, startedAt: snapshot.startedAt, finishedAt: snapshot.finishedAt,
      width: job.width, height: job.height, batchSize: job.batchSize, totalSteps: job.totalSteps,
      model: job.model, prompt: job.prompt, seed: job.seed, imageCount: imageCount,
      project: projectProvider?(group.id), configuration: job.requestConfiguration,
      negativePrompt: job.negativePrompt, origin: group.origin, tool: group.toolInfo,
      delivered: job.snapshot().delivered, evicted: nil,
      completeImages: job.payload.completeImages, hasAudio: job.payload.hasAudio)
  }

  func saveOpen(_ job: Job) {
    lock.lock()
    defer { lock.unlock() }
    let file = openRoot.appendingPathComponent("\(job.id.uuidString).json")
    do {
      try Self.encoder().encode(record(of: job, imageCount: 0)).write(to: file)
    } catch {
      logger.warning("Run \(job.code) \(job.runIndex) could not be noted on disk: \(error)")
    }
  }

  func removeOpen(_ id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    try? FileManager.default.removeItem(at: openRoot.appendingPathComponent("\(id.uuidString).json"))
  }

  func loadOpen(excluding finished: Set<UUID>) -> [Record] {
    lock.lock()
    defer { lock.unlock() }
    let oldest = Date().addingTimeInterval(-Self.maxAge)
    var records = [Record]()
    for name in (try? FileManager.default.contentsOfDirectory(atPath: openRoot.path)) ?? [] {
      let file = openRoot.appendingPathComponent(name)
      guard let data = try? Data(contentsOf: file),
        let record = try? Self.decoder().decode(Record.self, from: data),
        record.createdAt >= oldest, !finished.contains(record.id)
      else {
        try? FileManager.default.removeItem(at: file)
        continue
      }
      records.append(record)
    }
    return records.sorted { $0.createdAt < $1.createdAt }
  }

  func save(_ job: Job, keepDelivered: Bool = false) {
    let payload = job.payload
    guard payload.hasImages else { return }
    let group = job.group
    let entry = record(of: job, imageCount: payload.imageCount)
    lock.lock()
    defer { lock.unlock() }
    let target = directory(of: job.id)

    if !keepDelivered, group.source == nil, job.snapshot().delivered {
      try? FileManager.default.removeItem(at: target)
      return
    }
    do {
      if !payload.isOnDisk {
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for (index, response) in payload.responses().enumerated() {
          try response.serializedData().write(to: target.appendingPathComponent("\(index).pb"))
        }
      }
      try Self.encoder().encode(entry).write(to: target.appendingPathComponent("record.json"))

      if job.snapshot().delivered {
        if keepDelivered || group.source != nil {
          var marked = entry
          marked.delivered = true
          try Self.encoder().encode(marked).write(to: target.appendingPathComponent("record.json"))
        } else {
          try? FileManager.default.removeItem(at: target)
          return
        }
      }
      logger.info("Result of \(group.code) run \(job.runIndex) kept on disk (\(entry.imageCount) images)")
    } catch {
      logger.warning("Result of \(group.code) run \(job.runIndex) could not be kept on disk: \(error)")
      try? FileManager.default.removeItem(at: target)
    }
  }

  func update(_ job: Job) {
    lock.lock()
    defer { lock.unlock() }
    let target = directory(of: job.id).appendingPathComponent("record.json")
    guard FileManager.default.fileExists(atPath: target.path) else { return }
    var entry = record(of: job, imageCount: job.payload.imageCount)
    entry.evicted = job.payload.isPresent ? nil : true
    try? Self.encoder().encode(entry).write(to: target)
  }

  func saveThumbnail(_ base64: String, for id: UUID) {
    guard let data = Data(base64Encoded: base64) else { return }
    lock.lock()
    defer { lock.unlock() }
    let directory = directory(of: id)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try? data.write(to: directory.appendingPathComponent("thumb.png"))
  }

  func thumbnail(for id: UUID) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return (try? Data(contentsOf: directory(of: id).appendingPathComponent("thumb.png")))?.base64EncodedString()
  }

  func erase(_ id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    try? FileManager.default.removeItem(at: directory(of: id))
  }

  @discardableResult
  func enforceBudget(_ budget: Int = ResultStore.budgetBytes) -> [UUID] {
    lock.lock()
    defer { lock.unlock() }
    var entries = [(id: UUID, record: Record, bytes: Int)]()
    for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
      let dir = root.appendingPathComponent(name)
      guard let id = UUID(uuidString: name),
        let data = try? Data(contentsOf: dir.appendingPathComponent("record.json")),
        let record = try? Self.decoder().decode(Record.self, from: data)
      else { continue }
      var bytes = 0
      var index = 0
      while let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("\(index).pb").path)[.size]) as? Int {
        bytes += size
        index += 1
      }
      entries.append((id, record, bytes))
    }
    var total = entries.reduce(0) { $0 + $1.bytes }
    guard total > budget else { return [] }
    var freed = [UUID]()
    for entry in entries.filter({ ($0.record.tool != nil || $0.record.delivered == true) && $0.bytes > 0 }).sorted(by: { $0.record.createdAt < $1.record.createdAt }) {
      guard total > budget else { break }
      let dir = directory(of: entry.id)
      var index = 0
      while FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(index).pb").path) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(index).pb"))
        index += 1
      }
      var record = entry.record
      record.evicted = true
      try? Self.encoder().encode(record).write(to: dir.appendingPathComponent("record.json"))
      total -= entry.bytes
      freed.append(entry.id)
      logger.info("Images of \(record.groupCode) run \(record.runIndex) freed (the results take more than the budget of the disk), its row stays")
    }
    if total > budget { logger.warning("The results that wait for the app take \(total / 1_048_576) MB, more than the budget; they are not freed") }
    return freed
  }

  func remove(_ job: Job) {
    lock.lock()
    defer { lock.unlock() }
    let target = directory(of: job.id)
    guard FileManager.default.fileExists(atPath: target.path) else { return }
    FileManager.default.createFile(atPath: target.appendingPathComponent("delivered").path, contents: Data())
    do {
      try FileManager.default.removeItem(at: target)
    } catch {
      logger.warning("Result of \(job.code) run \(job.runIndex) is delivered but could not be erased: \(error)")
    }
  }

  func loadEntries() -> [Entry] {
    lock.lock()
    defer { lock.unlock() }
    var result = [Entry]()
    let oldest = Date().addingTimeInterval(-Self.maxAge)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    var erased = 0
    for name in names {
      let dir = root.appendingPathComponent(name)
      func erase() {
        try? FileManager.default.removeItem(at: dir)
        erased += 1
      }
      guard UUID(uuidString: name) != nil else { erase(); continue }
      if FileManager.default.fileExists(atPath: dir.appendingPathComponent("delivered").path) {
        erase()
        continue
      }
      guard let data = try? Data(contentsOf: dir.appendingPathComponent("record.json")),
        var record = try? Self.decoder().decode(Record.self, from: data), record.createdAt >= oldest
      else { erase(); continue }

      if record.delivered == true { erase(); continue }
      let parts = Payload.fileCount(in: dir)

      if parts == 0 && !(record.tool != nil && record.evicted == true) { erase(); continue }
      if record.completeImages == nil, parts > 0 {

        let payload = Payload(restoring: dir, imageCount: record.imageCount, completeImages: 0, hasAudio: false)
        var complete = 0
        var audio = false
        for response in payload.responses() {
          if response.chunkState == .lastChunk { complete += response.generatedImages.count }
          if !response.generatedAudio.isEmpty { audio = true }
        }
        record.completeImages = complete
        record.hasAudio = audio
      }
      result.append(Entry(record: record, directory: dir))
    }
    logger.info("Results: \(result.count) runs kept on disk restored, \(erased) old or delivered ones erased")
    return result.sorted { $0.record.createdAt < $1.record.createdAt }
  }

  func load() -> [(record: Record, responses: [ImageGenerationResponse])] {
    loadEntries().map { entry in
      let payload = Payload(
        restoring: entry.directory, imageCount: entry.record.imageCount,
        completeImages: entry.record.completeImages ?? 0, hasAudio: entry.record.hasAudio ?? false)
      return (entry.record, payload.responses())
    }.filter { !$0.responses.isEmpty }
  }

  @discardableResult
  func prune() -> [UUID] {
    lock.lock()
    defer { lock.unlock() }
    var gone = [UUID]()
    let oldest = Date().addingTimeInterval(-Self.maxAge)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
      let dir = root.appendingPathComponent(name)
      guard let id = UUID(uuidString: name), let data = try? Data(contentsOf: dir.appendingPathComponent("record.json")),
        let record = try? Self.decoder().decode(Record.self, from: data)
      else { continue }
      if record.createdAt < oldest {
        try? FileManager.default.removeItem(at: dir)
        gone.append(id)
      }
    }
    return gone
  }
}
