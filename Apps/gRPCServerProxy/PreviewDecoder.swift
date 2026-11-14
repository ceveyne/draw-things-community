import CoreGraphics
import Diffusion
import LocalImageGenerator
import Foundation
import ModelZoo
import NNC

enum PreviewDecoder {

  static let flux2Projection: [[Float]] = [
    [0.0058, 0.0495, -0.0099, 0.2144, 0.0166, 0.0157, -0.0398, -0.0052, -0.3527, -0.0301, -0.0107, 0.0746, 0.0156, -0.0034, 0.0032, -0.0939, 0.0018, 0.0284, -0.0024, 0.1207, 0.0128, 0.0137, 0.0095, 0, -0.0465, 0.0095, 0.029, 0.022, -0.0332, -0.0085, -0.0076, -0.0111, -0.0329],
    [0.0113, 0.0443, 0.0096, 0.3009, -0.0039, 0.0103, 0.0902, 0.0095, -0.2712, -0.0356, 0.0078, 0.009, 0.0169, -0.004, 0.0181, -0.0008, 0.0043, 0.0056, -0.0022, -0.0026, 0.0101, -0.0072, 0.0092, -0.0077, -0.0204, 0.0012, -0.0034, 0.0169, -0.0457, 0.0389, 0.0003, -0.046, -0.0718],
    [0.0073, 0.0836, 0.0644, 0.3652, -0.0054, -0.016, -0.0235, 0.0109, -0.1666, -0.018, 0.0013, -0.0941, 0.007, -0.0114, 0.008, 0.0186, 0.0104, -0.0127, -0.003, 0.0065, 0.0142, -0.0007, -0.0059, -0.0049, -0.0312, -0.0066, 0.0025, -0.0048, -0.0468, 0.0609, -0.0043, -0.0614, -0.0851],
  ]

  private static let seenLock = NSLock()
  private static var seen = Set<String>()

  static func images(fromLatent latent: Tensor<FloatType>, model: String) -> [CGImage] {
    let shape = latent.shape

    let note = "PREVIEW \(model): latent \(shape), decoded with \(shape.last == 32 ? "the 32-channel projection" : "the library")"
    seenLock.lock()
    let isNew = seen.insert(note).inserted
    seenLock.unlock()
    if isNew { FileLog.shared.append(note) }
    if shape.count >= 3, shape[shape.count - 1] == 32 {
      return projected(latent)
    }
    var version = ModelZoo.versionForModel(model)

    let isQwen21 = shape.last == 64
    if isQwen21, version != .qwenImage2_1 { version = .qwenImage2_1 }

    if isQwen21 { prepareQwen21Decoder() }
    return ImageConverter.cgImages(fromLatent: latent, canUseTAESD: isQwen21, version: version).0
  }

  private static let decoderLock = NSLock()
  private static var decoderPrepared = false

  static func prepareQwen21Decoder() {
    decoderLock.lock()
    defer { decoderLock.unlock() }
    guard !decoderPrepared else { return }
    decoderPrepared = true
    let fileManager = FileManager.default
    guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
    let coreML = caches.appendingPathComponent("coreml")
    let model = coreML.appendingPathComponent("qwen_image_2_1_tae")
    guard !fileManager.fileExists(atPath: model.path) else { return }
    let archive = "/Applications/Draw Things.app/Contents/Resources/qwen_image_2.1_tae.zip"
    guard fileManager.fileExists(atPath: archive) else {
      FileLog.shared.append("PREVIEW Qwen Image 2.1: the decoder archive of Draw Things was not found, the approximation is used")
      return
    }
    do {
      try fileManager.createDirectory(at: coreML, withIntermediateDirectories: true)
      let unzip = Process()
      unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
      unzip.arguments = ["-q", "-o", archive, "-d", coreML.path]
      try unzip.run()
      unzip.waitUntilExit()
      guard unzip.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
      for size in [768, 1024, 1280, 1536, 1792] {
        let target = model.appendingPathComponent("\(size).mlmodelc/weights/weight.bin")
        do { try fileManager.linkItem(at: model.appendingPathComponent("weight.bin"), to: target) }
        catch { try fileManager.copyItem(at: model.appendingPathComponent("weight.bin"), to: target) }
      }
      try fileManager.moveItem(
        at: model.appendingPathComponent("weight.bin"),
        to: model.appendingPathComponent("2048.mlmodelc/weights/weight.bin"))
      FileLog.shared.append("PREVIEW Qwen Image 2.1: decoder unpacked into \(model.path)")
    } catch {
      try? fileManager.removeItem(at: model)
      FileLog.shared.append("PREVIEW Qwen Image 2.1: the decoder could not be unpacked (\(error)), the approximation is used")
    }
  }

  static func libraryImages(fromLatent latent: Tensor<FloatType>, version: ModelVersion) -> [CGImage] {
    ImageConverter.cgImages(fromLatent: latent, canUseTAESD: false, version: version).0
  }

  static func shown(fromLatent latent: Tensor<FloatType>, model: String, limit: Int) -> [CGImage] {
    let all = images(fromLatent: latent, model: model)

    guard all.count > limit else { return all }
    let brightness = all.map { meanBrightness(of: $0) }
    let blank = brightness.map { $0 < 2 }
    let usable = all.indices.filter { !blank[$0] }
    let pool = usable.isEmpty ? Array(all.indices) : usable
    let picked = (0..<limit).map { pool[$0 * (pool.count - 1) / max(limit - 1, 1)] }
    let unique = picked.enumerated().filter { picked.firstIndex(of: $0.element) == $0.offset }.map { $0.element }
    let nonFinite = countNonFinite(latent)
    if nonFinite > 0 || blank.contains(true) {
      let note =
        "PREVIEW \(model): \(all.count) frames, \(blank.filter { $0 }.count) blank, \(nonFinite) latent values that are not numbers; blank frames "
        + "\(blank.enumerated().filter { $0.element }.map { String($0.offset) }.prefix(12).joined(separator: ",")) of \(all.count), shown \(unique)"
      seenLock.lock()
      let isNew = seen.insert(String(note.prefix(120))).inserted
      seenLock.unlock()
      if isNew { FileLog.shared.append(note) }
    }
    return unique.map { all[$0] }
  }

  static func meanBrightness(of image: CGImage) -> Double {
    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 255 }
    let perPixel = max(image.bitsPerPixel / 8, 3)
    let pixels = image.width * image.height
    guard pixels > 0 else { return 0 }
    let step = max(pixels / 2000, 1)
    var sum = 0.0
    var count = 0.0
    var pixel = 0
    while pixel < pixels {
      let base = pixel * perPixel
      sum += Double(bytes[base]) + Double(bytes[base + 1]) + Double(bytes[base + 2])
      count += 3
      pixel += step
    }
    return sum / count
  }

  static func countNonFinite(_ latent: Tensor<FloatType>) -> Int {
    var count = 0
    latent.withUnsafeBytes { raw in
      guard let values = raw.baseAddress?.assumingMemoryBound(to: FloatType.self) else { return }
      for index in 0..<latent.shape.reduce(1, *) where !Float(values[index]).isFinite { count += 1 }
    }
    return count
  }

  static func projected(_ latent: Tensor<FloatType>) -> [CGImage] {
    let shape = latent.shape
    let channels = shape[shape.count - 1]
    let width = shape[shape.count - 2]
    let height = shape[shape.count - 3]
    let batch = shape.count >= 4 ? shape[shape.count - 4] : 1
    var result = [CGImage]()
    latent.withUnsafeBytes { raw in
      guard let values = raw.baseAddress?.assumingMemoryBound(to: FloatType.self) else { return }
      for item in 0..<batch {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let offset = item * width * height * channels
        for pixel in 0..<(width * height) {
          let base = offset + pixel * channels
          for color in 0..<3 {
            let coefficients = flux2Projection[color]
            var value = coefficients[32]
            for index in 0..<32 { value += coefficients[index] * Float(values[base + index]) }
            pixels[pixel * 4 + color] = UInt8(max(0, min(255, Int(value * 127.5 + 127.5))))
          }
        }
        guard
          let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { continue }
        result.append(image)
      }
    }
    return result
  }
}
