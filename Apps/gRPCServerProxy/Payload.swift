import Foundation
import GRPCImageServiceModels

final class Payload {
  private let lock = NSLock()
  private var directory: URL?
  private var memory: [ImageGenerationResponse] = []
  private var parts = 0
  private var present = true
  private var _imageCount = 0
  private var _completeImages = 0
  private var _audioParts: [Int] = []
  private var _byteCount = 0

  init(directory: URL?) { self.directory = directory }

  init(restoring directory: URL, imageCount: Int, completeImages: Int, hasAudio: Bool) {
    self.directory = directory
    _imageCount = imageCount
    _completeImages = completeImages
    var index = 0
    while let size = Self.size(of: Self.file(directory, index)) {
      _byteCount += size
      index += 1
    }
    parts = index
    if hasAudio { _audioParts = Self.scanAudioParts(directory, parts: parts) }
  }

  init(memory responses: [ImageGenerationResponse]) {
    directory = nil
    for response in responses { appendLocked(response) }
  }

  var imageCount: Int { lock.withLock { _imageCount } }
  var hasImages: Bool { imageCount > 0 }

  var completeImages: Int { lock.withLock { _completeImages } }
  var hasAudio: Bool { lock.withLock { !_audioParts.isEmpty } }

  var byteCount: Int { lock.withLock { _byteCount } }

  var isPresent: Bool { lock.withLock { present && parts > 0 } }
  var isOnDisk: Bool { lock.withLock { directory != nil } }
  var directoryURL: URL? { lock.withLock { directory } }

  func append(_ response: ImageGenerationResponse) {
    lock.withLock { appendLocked(response) }
  }

  private func appendLocked(_ response: ImageGenerationResponse) {
    _imageCount += response.generatedImages.count
    if response.chunkState == .lastChunk { _completeImages += response.generatedImages.count }
    if !response.generatedAudio.isEmpty { _audioParts.append(parts) }
    if let directory = directory {
      do {
        if parts == 0 { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let data = try response.serializedData()
        try data.write(to: Self.file(directory, parts))
        _byteCount += data.count
      } catch {

        memory = readAllLocked()
        self.directory = nil
        memory.append(response)
        _byteCount += response.generatedImages.reduce(0) { $0 + $1.count }
      }
    } else {
      memory.append(response)
      _byteCount += response.generatedImages.reduce(0) { $0 + $1.count }
        + response.generatedAudio.reduce(0) { $0 + $1.count }
    }
    parts += 1
  }

  func responses() -> [ImageGenerationResponse] {
    lock.withLock { present ? readAllLocked() : [] }
  }

  private func readAllLocked() -> [ImageGenerationResponse] {
    guard let directory = directory else { return memory }
    var result = [ImageGenerationResponse]()
    for index in 0..<parts {
      guard let response = Self.read(directory, index) else { break }
      result.append(response)
    }
    return result
  }

  private func readLocked(_ index: Int) -> ImageGenerationResponse? {
    guard index >= 0, index < parts else { return nil }
    if let directory = directory { return Self.read(directory, index) }
    return memory[index]
  }

  func lastCompleteImage() -> Data? {
    lock.withLock {
      guard present else { return nil }
      var index = parts - 1
      while index >= 0 {
        guard let response = readLocked(index) else { return nil }
        if response.chunkState == .lastChunk, let last = response.generatedImages.last {
          if response.generatedImages.count > 1 { return last }
          var pieces = [Data]()
          var before = index - 1
          while before >= 0, let piece = readLocked(before), piece.chunkState == .moreChunks,
            let first = piece.generatedImages.first
          {
            pieces.insert(first, at: 0)
            before -= 1
          }
          return pieces.reduce(Data(), +) + last
        }
        index -= 1
      }
      return nil
    }
  }

  func imageSequence() -> ImageSequence {
    ImageSequence(payload: self)
  }

  func audioResponses() -> [ImageGenerationResponse] {
    lock.withLock {
      guard present else { return [] }
      return _audioParts.compactMap { readLocked($0) }
    }
  }

  fileprivate func part(_ index: Int) -> ImageGenerationResponse? {
    lock.withLock { present ? readLocked(index) : nil }
  }

  fileprivate var partCount: Int { lock.withLock { parts } }

  func markGone() {
    lock.withLock {
      present = false
      memory = []
    }
  }

  func evict() {
    lock.withLock {
      present = false
      memory = []
      if let directory = directory {
        for index in 0..<parts { try? FileManager.default.removeItem(at: Self.file(directory, index)) }
      }
      _byteCount = 0
    }
  }

  private static func file(_ directory: URL, _ index: Int) -> URL {
    directory.appendingPathComponent("\(index).pb")
  }

  private static func size(of url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
  }

  private static func read(_ directory: URL, _ index: Int) -> ImageGenerationResponse? {
    guard let bytes = try? Data(contentsOf: file(directory, index)) else { return nil }
    return try? ImageGenerationResponse(serializedBytes: bytes)
  }

  private static func scanAudioParts(_ directory: URL, parts: Int) -> [Int] {
    (0..<parts).filter { index in
      read(directory, index).map { !$0.generatedAudio.isEmpty } ?? false
    }
  }

  static func fileCount(in directory: URL) -> Int {
    var index = 0
    while FileManager.default.fileExists(atPath: file(directory, index).path) { index += 1 }
    return index
  }
}

final class ImageSequence {
  private let payload: Payload
  private var next = 0
  private var pending = Data()
  private var queue = [Data]()

  fileprivate init(payload: Payload) { self.payload = payload }

  func nextImage() -> Data? {
    while queue.isEmpty {
      guard next < payload.partCount, let response = payload.part(next) else { return nil }
      next += 1
      guard !response.generatedImages.isEmpty else { continue }
      switch response.chunkState {
      case .moreChunks:
        if let first = response.generatedImages.first { pending += first }
      case .lastChunk:
        for (index, data) in response.generatedImages.enumerated() {
          queue.append(index == 0 && !pending.isEmpty ? pending + data : data)
        }
        pending = Data()
      default:
        pending = Data()
      }
    }
    return queue.removeFirst()
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
