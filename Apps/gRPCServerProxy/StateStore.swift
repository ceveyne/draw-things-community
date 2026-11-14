import Foundation
import Logging

final class StateStore {
  struct Image {
    var hash: Data
    var key: UUID
    var label: String
    var at: Date

    var groups: [UUID] = []
  }

  struct Project {
    var key: UUID
    var project: String
    var confirmed: Bool

    var receipt: ProjectLocator.NodeRef? = nil
    var at: Date
  }

  static let maxAge: TimeInterval = 90 * 24 * 3600
  static let maxImages = 5000

  private let url: URL
  private let logger: Logger
  private let lock = NSLock()
  private var handle: FileHandle?

  init(directory: String, logger: Logger) throws {
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    url = URL(fileURLWithPath: directory).appendingPathComponent("status-images.jsonl")
    self.logger = logger
  }

  func load() -> (images: [Image], projects: [Project]) {
    var images = [Image]()
    var projects = [UUID: Project]()
    var lines = 0
    if let text = try? String(contentsOf: url, encoding: .utf8) {
      for line in text.split(separator: "\n") {
        lines += 1
        guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = object["t"] as? String,
          let keyText = object["key"] as? String, let key = UUID(uuidString: keyText),
          let at = object["at"] as? Double
        else { continue }
        let date = Date(timeIntervalSince1970: at)
        switch type {
        case "image":
          guard let hashText = object["hash"] as? String, let hash = Data(hexString: hashText) else { continue }
          let groups = (object["g"] as? [String] ?? []).compactMap { UUID(uuidString: $0) }
          images.append(
            Image(hash: hash, key: key, label: object["label"] as? String ?? "?", at: date, groups: groups))
        case "project":
          guard let name = object["project"] as? String else { continue }
          let confirmed = (object["quality"] as? String) == "confirmed"

          if let current = projects[key], current.confirmed, !confirmed { continue }
          var receipt: ProjectLocator.NodeRef? = nil
          if let lineage = (object["rl"] as? NSNumber)?.int64Value, let logical = (object["rt"] as? NSNumber)?.int64Value {
            receipt = ProjectLocator.NodeRef(lineage: lineage, logicalTime: logical)
          }
          projects[key] = Project(key: key, project: name, confirmed: confirmed, receipt: receipt, at: date)
        default:
          continue
        }
      }
    }
    let oldest = Date().addingTimeInterval(-Self.maxAge)
    images = images.filter { $0.at >= oldest }
    if images.count > Self.maxImages { images.removeFirst(images.count - Self.maxImages) }
    let keys = Set(images.map { $0.key })
    let kept = projects.values.filter { keys.contains($0.key) }.sorted { $0.at < $1.at }
    rewrite(images: images, projects: kept)
    logger.info(
      "State: \(images.count) status images and \(kept.count) project assignments restored from \(url.path) (\(lines) records read)"
    )
    return (images, kept)
  }

  private func rewrite(images: [Image], projects: [Project]) {
    var text = ""
    for image in images { text += Self.line(image) }
    for project in projects { text += Self.line(project) }
    let temporary = url.appendingPathExtension("tmp")
    do {
      try text.write(to: temporary, atomically: false, encoding: .utf8)
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } catch {
      logger.warning("State: could not rewrite \(url.path): \(error)")
    }
    lock.lock()
    defer { lock.unlock() }
    try? handle?.close()
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
  }

  private static func line(_ image: Image) -> String {
    var object: [String: Any] = ["t": "image", "hash": image.hash.map { String(format: "%02x", $0) }.joined(), "key": image.key.uuidString, "label": image.label, "at": image.at.timeIntervalSince1970]
    if !image.groups.isEmpty { object["g"] = image.groups.map { $0.uuidString }.sorted() }
    return encode(object)
  }

  private static func line(_ project: Project) -> String {
    var object: [String: Any] = ["t": "project", "key": project.key.uuidString, "project": project.project, "quality": project.confirmed ? "confirmed" : "guessed", "at": project.at.timeIntervalSince1970]
    if let receipt = project.receipt {
      object["rl"] = receipt.lineage
      object["rt"] = receipt.logicalTime
    }
    return encode(object)
  }

  private static func encode(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return "" }
    return text + "\n"
  }

  private func append(_ text: String) {
    guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
    lock.lock()
    defer { lock.unlock() }
    do { try handle?.write(contentsOf: data) } catch { logger.warning("State: could not write: \(error)") }
  }

  func clear(keeping image: Image?, project: Project?) {
    rewrite(images: image.map { [$0] } ?? [], projects: project.map { [$0] } ?? [])
    logger.info("State: everything delivered erased\(image == nil ? "" : ", the latest status image kept")")
  }

  func record(_ image: Image) { append(Self.line(image)) }
  func record(_ project: Project) { append(Self.line(project)) }
}

extension Data {
  init?(hexString: String) {
    guard hexString.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    var index = hexString.startIndex
    while index < hexString.endIndex {
      let next = hexString.index(index, offsetBy: 2)
      guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self.init(bytes)
  }
}
