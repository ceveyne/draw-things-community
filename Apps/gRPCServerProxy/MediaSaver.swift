import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import CoreVideo
import DataModels
import Diffusion
import Foundation
import GRPCImageServiceModels
import ModelZoo
import NNC
import PNG

enum MediaSaver {
  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  private static let videoVersions: Set<ModelVersion> = [
    .hunyuanVideo, .wan21_1_3b, .wan21_14b, .wan22_5b, .longcatVideoAvatar1_5, .ltx2, .ltx2_3,
    .minimaxH3, .svdI2v,
  ]

  static func frames(of responses: [ImageGenerationResponse]) -> [Tensor<FloatType>] {
    ProxyService.completeImagePayloads(of: responses).compactMap {
      Tensor<FloatType>(data: $0, using: [.zip, .fpzip])
    }
  }

  static func audio(of responses: [ImageGenerationResponse]) -> [Tensor<Float>] {
    var tensors = [Tensor<Float>]()
    var pending = Data()
    for response in responses where !response.generatedAudio.isEmpty {
      switch response.chunkState {
      case .moreChunks:
        if let first = response.generatedAudio.first { pending += first }
      case .lastChunk:
        for (index, data) in response.generatedAudio.enumerated() {
          let complete = index == 0 && !pending.isEmpty ? pending + data : data
          if let audio = Tensor<Float>(data: complete, using: [.zip, .fpzip]) { tensors.append(audio) }
        }
        pending = Data()
      default:
        pending = Data()
      }
    }
    return tensors
  }

  static func imageCount(of responses: [ImageGenerationResponse]) -> Int {
    responses.filter { $0.chunkState == .lastChunk }.reduce(0) { $0 + $1.generatedImages.count }
  }

  static func isVideo(completeImages: Int, hasAudio: Bool, configuration: Data?, model: String) -> Bool {
    if hasAudio { return true }
    guard completeImages > 1, let configuration = configuration else { return false }
    return videoVersions.contains(ModelZoo.versionForModel(model))
      && GenerationConfiguration.from(data: configuration).numFrames > 1
  }

  static func isVideo(responses: [ImageGenerationResponse], configuration: Data?, model: String) -> Bool {
    isVideo(
      completeImages: imageCount(of: responses), hasAudio: responses.contains { !$0.generatedAudio.isEmpty },
      configuration: configuration, model: model)
  }

  static func save(
    responses: [ImageGenerationResponse], model: String, video: Bool, name: String, directory: URL,
    xmp: ((Int, Int, Int) -> String?)? = nil
  ) throws -> [URL] {
    try save(
      payload: Payload(memory: responses), model: model, video: video, name: name, directory: directory, xmp: xmp)
  }

  static func save(
    payload: Payload, model: String, video: Bool, name: String, directory: URL,
    xmp: ((Int, Int, Int) -> String?)? = nil
  ) throws -> [URL] {
    guard payload.isPresent, payload.completeImages > 0 else {
      throw Failure("The images are not there any more.")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var url = directory.appendingPathComponent(name)
    if url.pathExtension.isEmpty { url = url.appendingPathExtension(video ? "mov" : "png") }
    let sequence = payload.imageSequence()
    func nextTensor() throws -> Tensor<FloatType>? {
      guard let data = sequence.nextImage() else { return nil }
      guard let tensor = Tensor<FloatType>(data: data, using: [.zip, .fpzip]) else {
        throw Failure("An image could not be decoded.")
      }
      return tensor
    }
    switch url.pathExtension.lowercased() {
    case "png":
      let paths = outputPaths(base: url, count: payload.completeImages)
      var written = [String]()
      for (index, path) in paths.enumerated() {
        guard let tensor = try nextTensor() else { break }
        try writePNG(tensor: tensor, to: path)
        written.append(path)
        if let xmp = xmp, let size = try? shape(of: tensor),
          let packet = xmp(index, size.width, size.height)
        {
          try PNGMetadata.inject(xmp: packet, intoPNGAt: URL(fileURLWithPath: path))
        }
      }
      guard !written.isEmpty else { throw Failure("There are no images to save.") }
      return written.map { URL(fileURLWithPath: $0) }
    case let ext where ext == "mp4" || ext == "mov":
      guard video else { throw Failure("This run has no video.") }
      let audioTracks = audio(of: payload.audioResponses())
      let sampleRate = Double(ModelZoo.audioSampleRateForModel(model))
      try writeVideo(
        frameCount: payload.completeImages, nextFrame: nextTensor, to: url, containerExtension: ext,
        framesPerSecond: ModelZoo.framesPerSecondForModel(model), audio: audioTracks.first,
        audioSampleRate: audioTracks.isEmpty ? nil : sampleRate)
      return [url]
    default:
      throw Failure("The format .\(url.pathExtension) is not supported: use .png, .mov or .mp4.")
    }
  }

  private struct Shape {
    let width: Int
    let height: Int
    let channels: Int
  }

  static func outputPaths(base: URL, count: Int) -> [String] {
    if count == 1 { return [base.path] }
    let directory = base.deletingLastPathComponent()
    let ext = base.pathExtension
    let stem = base.deletingPathExtension().lastPathComponent
    return (0..<count).map { index in
      directory.appendingPathComponent(numberedStem(stem, index: index)).appendingPathExtension(ext).path
    }
  }

  static func numberedStem(_ stem: String, index: Int) -> String {
    var digits = ""
    for character in stem.reversed() {
      guard character.isASCII, character.isNumber else { break }
      digits.insert(character, at: digits.startIndex)
    }
    guard !digits.isEmpty, let number = Int(digits) else { return "\(stem)-\(index + 1)" }
    let prefix = stem.dropLast(digits.count)
    let counted = String(number + index)

    let padded = digits.hasPrefix("0") && counted.count < digits.count
      ? String(repeating: "0", count: digits.count - counted.count) + counted : counted
    return prefix + padded
  }

  private static func shape(of tensor: Tensor<FloatType>) throws -> Shape {
    let shape = tensor.shape
    switch shape.count {
    case 4: return Shape(width: shape[2], height: shape[1], channels: shape[3])
    case 3: return Shape(width: shape[1], height: shape[0], channels: shape[2])
    default: throw Failure("Unsupported image shape \(shape).")
    }
  }

  private static func pixelByte(_ value: FloatType) -> UInt8 {
    UInt8(min(max(Int((value + 1) * 127.5), 0), 255))
  }

  private static func writePNG(tensor: Tensor<FloatType>, to path: String) throws {
    let shape = try shape(of: tensor)
    guard shape.channels >= 3 else { throw Failure("Unsupported image shape \(tensor.shape).") }
    let pixelCount = shape.width * shape.height
    var rgba = [PNG.RGBA<UInt8>](repeating: .init(0), count: pixelCount)
    tensor.withUnsafeBytes {
      guard let fp16 = $0.baseAddress?.assumingMemoryBound(to: FloatType.self) else { return }
      for i in 0..<pixelCount {
        let base = i * shape.channels
        let rgb = base + (shape.channels == 4 ? 1 : 0)
        rgba[i].r = pixelByte(fp16[rgb])
        rgba[i].g = pixelByte(fp16[rgb + 1])
        rgba[i].b = pixelByte(fp16[rgb + 2])
        rgba[i].a = shape.channels == 4 ? UInt8(min(max(Int(fp16[base] * 255), 0), 255)) : 255
      }
    }
    let image = PNG.Data.Rectangular(
      packing: rgba, size: (x: shape.width, y: shape.height),
      layout: PNG.Layout(
        format: shape.channels == 4
          ? .rgba8(palette: [], fill: nil) : .rgb8(palette: [], fill: nil, key: nil)))
    do {
      try PNGFile.write(image, path: path)
    } catch {
      throw Failure("The PNG file \(path) could not be written.")
    }
  }

  private struct PNGFile: PNG.Bytestream.Destination {
    let file: UnsafeMutablePointer<FILE>

    func write(_ bytes: [UInt8]) -> Void? {
      guard fwrite(bytes, 1, bytes.count, file) == bytes.count else { return nil }
      return ()
    }

    static func write(_ image: PNG.Data.Rectangular, path: String) throws {
      guard let file = fopen(path, "wb") else { throw Failure("Cannot open \(path).") }
      defer { fclose(file) }
      var stream = PNGFile(file: file)
      try image.compress(stream: &stream, level: 4)
      guard fflush(file) == 0 else { throw Failure("Cannot write \(path).") }
    }
  }

  private static func writeVideo(
    frameCount: Int, nextFrame: @escaping () throws -> Tensor<FloatType>?, to outputURL: URL, containerExtension: String,
    framesPerSecond: Double, audio: Tensor<Float>?, audioSampleRate: Double?
  ) throws {

    guard let first = try nextFrame() else { throw Failure("There are no frames to save.") }
    let firstShape = try shape(of: first)
    guard firstShape.channels >= 3 else { throw Failure("Unsupported image shape \(first.shape).") }
    var pendingFirst: Tensor<FloatType>? = first
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try? FileManager.default.removeItem(at: outputURL)
    }
    let failed = Failure("The video \(outputURL.lastPathComponent) could not be written.")
    let writer = try AVAssetWriter(
      outputURL: outputURL, fileType: containerExtension == "mp4" ? .mp4 : .mov)
    let writerInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: videoSettings(
        width: firstShape.width, height: firstShape.height, prores: containerExtension == "mov"))
    writerInput.expectsMediaDataInRealTime = false
    var audioWriterInput: AVAssetWriterInput?
    var totalSampleCount = 0
    if let audio = audio, let rate = audioSampleRate {
      let audioShape = audio.shape
      guard audioShape.count == 2, audioShape[0] == 2, audioShape[1] > 0 else {
        throw Failure("Unsupported audio shape \(audioShape).")
      }
      totalSampleCount = audioShape[1]
      let input = AVAssetWriterInput(
        mediaType: .audio, outputSettings: audioSettings(for: containerExtension, sampleRate: rate))
      input.expectsMediaDataInRealTime = false
      audioWriterInput = input
    }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: writerInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: firstShape.width,
        kCVPixelBufferHeightKey as String: firstShape.height,
      ])
    guard writer.canAdd(writerInput) else { throw failed }
    if let audioWriterInput = audioWriterInput, !writer.canAdd(audioWriterInput) { throw failed }
    writer.add(writerInput)
    if let audioWriterInput = audioWriterInput { writer.add(audioWriterInput) }
    guard writer.startWriting() else { throw writer.error ?? failed }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { throw failed }

    let frameDuration = frameDuration(frameRate: framesPerSecond)
    let queue = DispatchQueue(label: "gRPCServerProxy.video-export")
    let semaphore = DispatchSemaphore(value: 0)
    var finishError: Error?
    var completionCalled = false
    var videoInputFinished = false
    var audioInputFinished = audioWriterInput == nil
    var frameIndex = 0
    var sampleOffset = 0
    var presentationTime = CMTime.zero

    func cancelAndComplete(_ error: Error) {
      guard !completionCalled else { return }
      completionCalled = true
      finishError = error
      writer.cancelWriting()
      semaphore.signal()
    }
    func finishWritingIfReady() {
      guard !completionCalled, videoInputFinished, audioInputFinished else { return }
      completionCalled = true
      writer.finishWriting {
        if writer.status != .completed { finishError = writer.error ?? failed }
        semaphore.signal()
      }
    }

    writerInput.requestMediaDataWhenReady(on: queue) {
      while writerInput.isReadyForMoreMediaData {
        guard !completionCalled else { return }
        if frameIndex < frameCount {
          var pixelBuffer: CVPixelBuffer?
          guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
            let pixelBuffer = pixelBuffer
          else {
            cancelAndComplete(failed)
            return
          }
          do {
            guard let frame = try pendingFirst ?? nextFrame() else {
              cancelAndComplete(Failure("A frame is missing."))
              return
            }
            pendingFirst = nil
            try populate(pixelBuffer: pixelBuffer, with: frame, expected: firstShape)
          } catch {
            cancelAndComplete(error)
            return
          }
          guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            cancelAndComplete(writer.error ?? failed)
            return
          }
          presentationTime = CMTimeAdd(presentationTime, frameDuration)
          frameIndex += 1
        } else {
          if !videoInputFinished {
            writerInput.markAsFinished()
            videoInputFinished = true
          }
          finishWritingIfReady()
          break
        }
      }
    }
    if let audioWriterInput = audioWriterInput, let audio = audio, let rate = audioSampleRate {
      audioWriterInput.requestMediaDataWhenReady(on: queue) {
        while audioWriterInput.isReadyForMoreMediaData {
          guard !completionCalled else { return }
          if sampleOffset < totalSampleCount {
            let count = min(1024, totalSampleCount - sampleOffset)
            guard
              let buffer = newAudioSampleBuffer(
                from: audio, offset: sampleOffset, sampleCount: count, sampleRate: rate)
            else {
              cancelAndComplete(failed)
              return
            }
            guard audioWriterInput.append(buffer) else {
              cancelAndComplete(writer.error ?? failed)
              return
            }
            sampleOffset += count
          } else {
            if !audioInputFinished {
              audioWriterInput.markAsFinished()
              audioInputFinished = true
            }
            finishWritingIfReady()
            break
          }
        }
      }
    }
    semaphore.wait()
    if let finishError = finishError { throw finishError }
  }

  private static func audioSettings(for containerExtension: String, sampleRate source: Double)
    -> [String: Any]
  {

    let standardRates: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
    let sampleRate = standardRates.first { $0 >= source } ?? 48_000
    if containerExtension == "mp4" {
      return [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: min(192_000, Int(sampleRate) * 6),
      ]
    }
    return [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }

  private static func videoSettings(width: Int, height: Int, prores: Bool) -> [String: Any] {
    if prores {
      return [
        AVVideoCodecKey: AVVideoCodecType.proRes4444.rawValue,
        AVVideoWidthKey: NSNumber(value: width),
        AVVideoHeightKey: NSNumber(value: height),
      ]
    }
    return [
      AVVideoCodecKey: AVVideoCodecType.h264.rawValue,
      AVVideoWidthKey: NSNumber(value: width),
      AVVideoHeightKey: NSNumber(value: height),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: max(9_500_000, Int((Double(width * height) * 5).rounded())),
        AVVideoProfileLevelKey: AVVideoProfileLevelH264High41,
        AVVideoMaxKeyFrameIntervalKey: 30,
        AVVideoAllowFrameReorderingKey: true,
      ],
    ]
  }

  private static func frameDuration(frameRate: Double) -> CMTime {
    guard frameRate > 0 else { return CMTime(value: 1, timescale: 30) }
    if abs(frameRate - frameRate.rounded()) < 1e-12 {
      return CMTime(value: 1, timescale: Int32(frameRate.rounded()))
    }
    let timescale: Int32 = 60_000
    return CMTime(value: max(1, Int64((Double(timescale) / frameRate).rounded())), timescale: timescale)
  }

  private static func populate(
    pixelBuffer: CVPixelBuffer, with tensor: Tensor<FloatType>, expected: Shape
  ) throws {
    let shape = try shape(of: tensor)
    guard shape.width == expected.width, shape.height == expected.height, shape.channels >= 3 else {
      throw Failure("Unsupported image shape \(tensor.shape).")
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      throw Failure("No pixel buffer.")
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let destination = baseAddress.assumingMemoryBound(to: UInt8.self)
    tensor.withUnsafeBytes {
      guard let fp16 = $0.baseAddress?.assumingMemoryBound(to: FloatType.self) else { return }
      for y in 0..<shape.height {
        let row = destination.advanced(by: y * bytesPerRow)
        for x in 0..<shape.width {
          let source = (y * shape.width + x) * shape.channels
          let index = x * 4
          row[index] = pixelByte(fp16[source + 2])
          row[index + 1] = pixelByte(fp16[source + 1])
          row[index + 2] = pixelByte(fp16[source])
          row[index + 3] = 255
        }
      }
    }
  }

  private static func newAudioSampleBuffer(
    from audioTensor: Tensor<Float>, offset: Int, sampleCount: Int, sampleRate: Double
  ) -> CMSampleBuffer? {
    guard sampleCount > 0 else { return nil }
    let channelCount = 2
    let byteCount = sampleCount * channelCount * MemoryLayout<Float32>.size
    var interleaved = [Float32](repeating: 0, count: sampleCount * channelCount)
    for i in 0..<sampleCount {
      interleaved[i * 2] = max(-1, min(1, audioTensor[0, offset + i]))
      interleaved[i * 2 + 1] = max(-1, min(1, audioTensor[1, offset + i]))
    }
    var blockBuffer: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
      let blockBuffer = blockBuffer
    else { return nil }
    let replaced = interleaved.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
    }
    guard replaced == kCMBlockBufferNoErr else { return nil }
    let bytesPerFrame = UInt32(channelCount * MemoryLayout<Float32>.size)
    var asbd = AudioStreamBasicDescription(
      mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: bytesPerFrame,
      mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: 2, mBitsPerChannel: 32,
      mReserved: 0)
    var format: CMAudioFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
        magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
      let format = format
    else { return nil }
    let time = CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(max(1, Int(sampleRate.rounded()))))
    var sampleBuffer: CMSampleBuffer?
    guard
      CMAudioSampleBufferCreateWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: sampleCount,
        presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sampleBuffer) == noErr
    else { return nil }
    return sampleBuffer
  }
}
