import DataModels
import Foundation

enum PNGMetadata {

  static let generatedBy = "gRPCServerProxy"

  struct Info {
    var prompt: String
    var negativePrompt: String
    var configuration: GenerationConfiguration

    var seed: UInt32
    var width: Int
    var height: Int
    var createdAt: Date
  }

  private static func samplerName(_ sampler: SamplerType) -> String {
    switch sampler {
    case .dPMPP2MKarras: return "DPM++ 2M Karras"
    case .eulerA: return "Euler A"
    case .DDIM: return "DDIM"
    case .PLMS: return "PLMS"
    case .dPMPPSDEKarras: return "DPM++ SDE Karras"
    case .uniPC: return "UniPC"
    case .LCM: return "LCM"
    case .eulerASubstep: return "Euler A Substep"
    case .dPMPPSDESubstep: return "DPM++ SDE Substep"
    case .TCD: return "TCD"
    case .eulerATrailing: return "Euler A Trailing"
    case .dPMPPSDETrailing: return "DPM++ SDE Trailing"
    case .DPMPP2MAYS: return "DPM++ 2M AYS"
    case .eulerAAYS: return "Euler A AYS"
    case .DPMPPSDEAYS: return "DPM++ SDE AYS"
    case .dPMPP2MTrailing: return "DPM++ 2M Trailing"
    case .dDIMTrailing: return "DDIM Trailing"
    case .uniPCTrailing: return "UniPC Trailing"
    case .uniPCAYS: return "UniPC AYS"
    case .tCDTrailing: return "TCD Trailing"
    }
  }

  private static func seedModeName(_ mode: SeedMode) -> String {
    switch mode {
    case .legacy: return "Legacy"
    case .torchCpuCompatible: return "Torch CPU Compatible"
    case .scaleAlike: return "Scale Alike"
    case .nvidiaGpuCompatible: return "NVIDIA GPU Compatible"
    }
  }

  private static func f32(_ value: Float32) -> Any {
    guard value.isFinite else { return 0 }
    return Double(String(value)) ?? Double(value)
  }

  static func v2(_ c: GenerationConfiguration, seed: UInt32) -> [String: Any] {
    var result = [String: Any]()
    func put(_ key: String, _ value: Any?) { if let value = value { result[key] = value } }
    var loras = [[String: Any]]()
    for lora in c.loras {
      var entry: [String: Any] = ["mode": String(describing: lora.mode), "weight": f32(lora.weight)]
      if let file = lora.file { entry["file"] = file }
      loras.append(entry)
    }
    var controls = [[String: Any]]()
    for control in c.controls {
      var entry: [String: Any] = [
        "weight": f32(control.weight), "guidanceStart": f32(control.guidanceStart),
        "guidanceEnd": f32(control.guidanceEnd), "noPrompt": control.noPrompt,
        "globalAveragePooling": control.globalAveragePooling,
        "downSamplingRate": f32(control.downSamplingRate),
        "controlImportance": String(describing: control.controlMode),
        "inputOverride": String(describing: control.inputOverride).lowercased(),
        "targetBlocks": control.targetBlocks,
      ]
      if let file = control.file { entry["file"] = file }
      controls.append(entry)
    }
    put("id", Int(c.id))
    put("width", Int(c.startWidth) * 64)
    put("height", Int(c.startHeight) * 64)
    put("seed", Int(seed))
    put("steps", Int(c.steps))
    put("guidanceScale", f32(c.guidanceScale))
    put("strength", f32(c.strength))
    put("model", c.model)
    put("sampler", Int(c.sampler.rawValue))
    put("hiresFix", c.hiresFix)
    put("hiresFixWidth", Int(c.hiresFixStartWidth) * 64)
    put("hiresFixHeight", Int(c.hiresFixStartHeight) * 64)
    put("hiresFixStrength", f32(c.hiresFixStrength))
    put("tiledDecoding", c.tiledDecoding)
    put("decodingTileWidth", Int(c.decodingTileWidth) * 64)
    put("decodingTileHeight", Int(c.decodingTileHeight) * 64)
    put("decodingTileOverlap", Int(c.decodingTileOverlap) * 64)
    put("tiledDiffusion", c.tiledDiffusion)
    put("diffusionTileWidth", Int(c.diffusionTileWidth) * 64)
    put("diffusionTileHeight", Int(c.diffusionTileHeight) * 64)
    put("diffusionTileOverlap", Int(c.diffusionTileOverlap) * 64)
    put("upscaler", c.upscaler)
    put("upscalerScaleFactor", Int(c.upscalerScaleFactor))
    put("imageGuidanceScale", f32(c.imageGuidanceScale))
    put("seedMode", Int(c.seedMode.rawValue))
    put("clipSkip", Int(c.clipSkip))
    put("controls", controls)
    put("loras", loras)
    put("maskBlur", f32(c.maskBlur))
    put("maskBlurOutset", Int(c.maskBlurOutset))
    put("sharpness", f32(c.sharpness))
    put("faceRestoration", c.faceRestoration)
    put("clipWeight", f32(c.clipWeight))
    put("negativePromptForImagePrior", c.negativePromptForImagePrior)
    put("imagePriorSteps", Int(c.imagePriorSteps))
    put("refinerModel", c.refinerModel)
    put("originalImageHeight", Int(c.originalImageHeight))
    put("originalImageWidth", Int(c.originalImageWidth))
    put("cropTop", Int(c.cropTop))
    put("cropLeft", Int(c.cropLeft))
    put("targetImageHeight", Int(c.targetImageHeight))
    put("targetImageWidth", Int(c.targetImageWidth))
    put("aestheticScore", f32(c.aestheticScore))
    put("negativeAestheticScore", f32(c.negativeAestheticScore))
    put("zeroNegativePrompt", c.zeroNegativePrompt)
    put("refinerStart", f32(c.refinerStart))
    put("negativeOriginalImageHeight", Int(c.negativeOriginalImageHeight))
    put("negativeOriginalImageWidth", Int(c.negativeOriginalImageWidth))
    put("batchCount", Int(c.batchCount))
    put("batchSize", Int(c.batchSize))
    put("numFrames", Int(c.numFrames))
    put("fps", Int(c.fpsId))
    put("motionScale", Int(c.motionBucketId))
    put("guidingFrameNoise", f32(c.condAug))
    put("startFrameGuidance", f32(c.startFrameCfg))
    put("shift", f32(c.shift))
    put("stage2Steps", Int(c.stage2Steps))
    put("stage2Guidance", f32(c.stage2Cfg))
    put("stage2Shift", f32(c.stage2Shift))
    put("stochasticSamplingGamma", f32(c.stochasticSamplingGamma))
    put("preserveOriginalAfterInpaint", c.preserveOriginalAfterInpaint)
    put("t5TextEncoder", c.t5TextEncoder)
    put("separateClipL", c.separateClipL)
    put("clipLText", c.clipLText)
    put("separateOpenClipG", c.separateOpenClipG)
    put("openClipGText", c.openClipGText)
    put("speedUpWithGuidanceEmbed", c.speedUpWithGuidanceEmbed)
    put("guidanceEmbed", f32(c.guidanceEmbed))
    put("resolutionDependentShift", c.resolutionDependentShift)
    put("teaCache", c.teaCache)
    put("teaCacheStart", Int(c.teaCacheStart))
    put("teaCacheEnd", Int(c.teaCacheEnd))
    put("teaCacheThreshold", f32(c.teaCacheThreshold))
    put("teaCacheMaxSkipSteps", Int(c.teaCacheMaxSkipSteps))
    put("separateT5", c.separateT5)
    put("t5Text", c.t5Text)
    put("causalInference", c.causalInferenceEnabled ? Int(c.causalInference) : 0)
    put("causalInferencePad", c.causalInferenceEnabled ? Int(c.causalInferencePad) : 0)
    put("cfgZeroStar", c.cfgZeroStar)
    put("cfgZeroInitSteps", Int(c.cfgZeroInitSteps))
    let compression: String
    switch c.compressionArtifacts {
    case .disabled: compression = "disabled"
    case .H264: compression = "h264"
    case .H265: compression = "h265"
    case .jpeg: compression = "jpeg"
    }
    put("compressionArtifacts", compression)
    put("compressionArtifactsQuality", f32(min(max(c.compressionArtifactsQuality, 0), 100)))
    put("colorCalibration", c.colorCalibration == .lab ? "lab" : "none")
    put("expandPromptToJson", c.expandPromptToJson)
    put("shiftForAudio", f32(c.shiftForAudio))
    put("usesSolAttention", c.usesSolAttention)
    put("solAttentionStart", Int(c.solAttentionStart))
    put("solAttentionTau", f32(c.solAttentionTau))
    return result
  }

  private static func escapeXml(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }

  private static func basename(_ path: String) -> String { (path as NSString).lastPathComponent }

  private static func number(_ value: Float32) -> String { String(value) }

  private static func description(_ info: Info) -> String {
    let c = info.configuration
    var lines = [String]()
    if !info.prompt.isEmpty { lines.append(info.prompt) }
    if !info.negativePrompt.isEmpty { lines.append("Negative prompt: \(info.negativePrompt)") }
    var facts = [
      "Steps: \(c.steps)", "Sampler: \(samplerName(c.sampler))", "Guidance Scale: \(number(c.guidanceScale))",
      "Seed: \(info.seed)", "Size: \(info.width)x\(info.height)",
    ]
    if let model = c.model, !model.isEmpty { facts.append("Model: \(basename(model))") }
    facts.append("Strength: \(number(c.strength))")
    facts.append("Seed Mode: \(seedModeName(c.seedMode))")
    facts.append("Shift: \(number(c.shift))")
    lines.append(facts.joined(separator: ", "))
    for (index, lora) in c.loras.enumerated() {
      var entry = "LoRA \(index + 1) Model: \(basename(lora.file ?? ""))"
      entry += ", LoRA \(index + 1) Weight: \(number(lora.weight))"
      lines.append(entry)
    }
    return lines.joined(separator: "\n")
  }

  private static func userComment(_ info: Info) -> String {
    let c = info.configuration
    var object: [String: Any] = [
      "c": info.prompt, "uc": info.negativePrompt, "sampler": samplerName(c.sampler),
      "scale": f32(c.guidanceScale), "seed": Int(info.seed), "seed_mode": seedModeName(c.seedMode),
      "shift": f32(c.shift), "size": "\(info.width)x\(info.height)", "steps": Int(c.steps),
      "strength": f32(c.strength), "v2": v2(c, seed: info.seed), "generated_by": generatedBy,
    ]
    if let model = c.model, !model.isEmpty { object["model"] = basename(model) }
    if !c.loras.isEmpty {
      object["lora"] = c.loras.map { lora -> [String: Any] in
        ["model": basename(lora.file ?? ""), "weight": f32(lora.weight)]
      }
    }
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  static func xmp(_ info: Info) -> String {
    let created = ISO8601DateFormatter.withFractionalSeconds.string(from: info.createdAt)
    return [
      "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"XMP Core 6.0.0\">",
      "   <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">",
      "      <rdf:Description rdf:about=\"\"",
      "            xmlns:dc=\"http://purl.org/dc/elements/1.1/\"",
      "            xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"",
      "            xmlns:exif=\"http://ns.adobe.com/exif/1.0/\">",
      "         <dc:description>",
      "            <rdf:Alt>",
      "               <rdf:li xml:lang=\"x-default\">\(escapeXml(description(info)))</rdf:li>",
      "            </rdf:Alt>",
      "         </dc:description>",
      "         <xmp:CreatorTool>\(escapeXml(generatedBy))</xmp:CreatorTool>",
      "         <xmp:CreateDate>\(escapeXml(created))</xmp:CreateDate>",
      "         <exif:UserComment>",
      "            <rdf:Alt>",
      "               <rdf:li xml:lang=\"x-default\">\(userComment(info))</rdf:li>",
      "            </rdf:Alt>",
      "         </exif:UserComment>",
      "      </rdf:Description>",
      "   </rdf:RDF>",
      "</x:xmpmeta>",
    ].joined(separator: "\n")
  }

  private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
  }

  private static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
  }

  static func inject(xmp: String, intoPNGAt url: URL) throws {
    var png = try Data(contentsOf: url)
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    let headerEnd = signature.count + 25
    guard png.count > headerEnd, Array(png.prefix(signature.count)) == signature else { return }

    var chunkData = [UInt8]("XML:com.adobe.xmp".utf8)
    chunkData += [0, 0, 0, 0, 0]
    chunkData += [UInt8](xmp.utf8)
    var typeAndData = [UInt8]("iTXt".utf8)
    typeAndData += chunkData
    var chunk = Data()
    var length = UInt32(chunkData.count).bigEndian
    chunk.append(Data(bytes: &length, count: 4))
    chunk.append(contentsOf: typeAndData)
    var crc = crc32(typeAndData).bigEndian
    chunk.append(Data(bytes: &crc, count: 4))
    png.insert(contentsOf: chunk, at: headerEnd)
    try png.write(to: url)
  }
}

extension ISO8601DateFormatter {

  static let withFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}
