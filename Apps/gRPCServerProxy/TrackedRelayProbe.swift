import Crypto
import DataModels
import FlatBuffers
import Foundation
import ImageIO
import GRPC
import GRPCImageServiceModels
import Logging
import NIO
import NIOHPACK
import NNC
import Diffusion

private final class FakeServer: ImageGenerationServiceProvider {
  var interceptors: ImageGenerationServiceServerInterceptorFactoryProtocol? = nil
  let image: Data
  private let lock = NSLock()
  private var _prompts = [String]()
  private var _cancelled = 0
  var prompts: [String] { lock.withLock { _prompts } }
  var cancelled: Int { lock.withLock { _cancelled } }

  init(image: Data) { self.image = image }

  func generateImage(
    request: ImageGenerationRequest, context: StreamingResponseCallContext<ImageGenerationResponse>
  ) -> EventLoopFuture<GRPCStatus> {
    lock.withLock { _prompts.append(request.prompt) }
    if request.prompt == "fail" {
      return context.eventLoop.makeSucceededFuture(GRPCStatus(code: .failedPrecondition, message: "made up failure"))
    }
    context.sendResponse(
      ImageGenerationResponse.with { $0.currentSignpost = .with { $0.sampling = .with { $0.step = 1 } } }, promise: nil)
    context.sendResponse(ImageGenerationResponse.with { $0.previewImage = Data([1, 2, 3]) }, promise: nil)
    if request.prompt == "multi" {

      var latent = Tensor<FloatType>(.CPU, .NHWC(4, 8, 8, 32))
      for batch in 0..<4 { for y in 0..<8 { for x in 0..<8 { for c in 0..<32 { latent[batch, y, x, c] = FloatType(Float(batch) * 0.4 - 0.6 + Float(c) * 0.002) } } } }
      context.sendResponse(
        ImageGenerationResponse.with { $0.previewImage = latent.data(using: [.zip, .fpzip]) }, promise: nil)
      let promise = context.eventLoop.makePromise(of: GRPCStatus.self)
      context.closeFuture.whenComplete { _ in promise.succeed(.ok) }
      return promise.futureResult
    }
    if request.prompt == "two" {

      context.sendResponse(
        ImageGenerationResponse.with {
          $0.generatedImages = [image, image]
          $0.chunkState = .lastChunk
          $0.scaleFactor = 1
        }, promise: nil)
      return context.eventLoop.makeSucceededFuture(.ok)
    }
    if request.prompt == "clip" {
      context.sendResponse(
        ImageGenerationResponse.with {
          $0.generatedImages = [image, image]
          $0.generatedAudio = [Data([9, 9])]
          $0.chunkState = .lastChunk
          $0.scaleFactor = 1
        }, promise: nil)
      return context.eventLoop.makeSucceededFuture(.ok)
    }
    if request.prompt == "slow" {
      let promise = context.eventLoop.makePromise(of: GRPCStatus.self)
      context.closeFuture.whenComplete { [weak self] _ in
        self?.lock.withLock { self?._cancelled += 1 }
        promise.succeed(.ok)
      }
      return promise.futureResult
    }
    let half = image.count / 2
    context.sendResponse(
      ImageGenerationResponse.with {
        $0.generatedImages = [image.prefix(half)]
        $0.chunkState = .moreChunks
      }, promise: nil)
    context.sendResponse(
      ImageGenerationResponse.with {
        $0.generatedImages = [image.suffix(from: half)]
        $0.chunkState = .lastChunk
        $0.scaleFactor = 1
      }, promise: nil)
    return context.eventLoop.makeSucceededFuture(.ok)
  }

  func filesExist(request: FileListRequest, context: StatusOnlyCallContext) -> EventLoopFuture<FileExistenceResponse> {
    context.eventLoop.makeSucceededFuture(FileExistenceResponse())
  }
  func pubkey(request: PubkeyRequest, context: StatusOnlyCallContext) -> EventLoopFuture<PubkeyResponse> {
    context.eventLoop.makeSucceededFuture(PubkeyResponse())
  }
  func hours(request: HoursRequest, context: StatusOnlyCallContext) -> EventLoopFuture<HoursResponse> {
    context.eventLoop.makeSucceededFuture(HoursResponse())
  }
  func echo(request: EchoRequest, context: StatusOnlyCallContext) -> EventLoopFuture<EchoReply> {
    context.eventLoop.makeSucceededFuture(EchoReply())
  }
  func uploadFile(context: StreamingResponseCallContext<UploadResponse>) -> EventLoopFuture<(StreamEvent<FileUploadRequest>) -> Void> {
    context.eventLoop.makeSucceededFuture { _ in }
  }
}

extension ProxyCommand {
  func runTrackedRelayProbe() {
    setvbuf(stdout, nil, _IONBF, 0)
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
      if !ok { failures += 1 }
      print("\(ok ? "OK    " : "FAILED") \(name) \(detail)")
    }
    do {
      try trackedRelayProbe(check)
    } catch {
      print("FAILED probe: \(error)")
      failures += 1
    }
    print(failures == 0 ? "all ok" : "\(failures) FAILED")
    Foundation.exit(failures == 0 ? 0 : 1)
  }

  private func trackedRelayProbe(_ check: (String, Bool, String) -> Void) throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let logger = Logger(label: "probe")
    var picture = Tensor<FloatType>(.CPU, .NHWC(1, 64, 96, 3))
    for y in 0..<64 { for x in 0..<96 { for c in 0..<3 { picture[0, y, x, c] = FloatType(Float(x) / 96 - 0.5) } } }
    let fake = FakeServer(image: picture.data(using: [.zip, .fpzip]))
    let fakeServer = try Server.insecure(group: group).withServiceProviders([fake]).bind(host: "127.0.0.1", port: 0).wait()
    let fakePort = fakeServer.channel.localAddress!.port!

    let upstream = try Upstream(host: "127.0.0.1", port: fakePort, TLS: false, group: group)

    let replyModeFile = NSTemporaryDirectory() + "reply-mode-probe-\(Int(Date().timeIntervalSince1970))"
    try "start=empty".write(toFile: replyModeFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: replyModeFile) }

    let probeStateDirectory = NSTemporaryDirectory() + "tracked-probe-state-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: probeStateDirectory) }
    let service = ProxyService(
      upstream: upstream, sharedSecret: "", background: true, followUpMode: .status, followUpModeFile: "/dev/null",
      replyModeFile: replyModeFile,
      burstWindow: 1.5, maxDeliveryImages: 0, statusWidth: 0, statusAspect: 1.25, locator: nil,
      results: try ResultStore(directory: probeStateDirectory, logger: logger), dumpDirectory: nil,
      logger: logger)
    let socketPath = NSTemporaryDirectory() + "tracked-probe-\(Int(Date().timeIntervalSince1970)).sock"
    defer { unlink(socketPath) }
    let hub = MonitorHub(path: socketPath, logger: logger)
    try hub.start()
    service.attachMonitor(hub)
    let proxyServer = try Server.insecure(group: group).withServiceProviders([service]).withLogger(ProxyService.serverLogger()).bind(host: "127.0.0.1", port: 0).wait()
    let proxyPort = proxyServer.channel.localAddress!.port!

    let monitorFd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        _ = socketPath.withCString { strncpy(destination, $0, capacity - 1) }
      }
    }
    _ = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(monitorFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }

    let answersLock = NSLock()
    var answers = [[String: Any]]()
    Thread.detachNewThread {
      var buffer = [UInt8](repeating: 0, count: 65536)
      var pending = Data()
      while true {
        let n = read(monitorFd, &buffer, buffer.count)
        if n <= 0 { break }
        pending.append(buffer, count: n)
        while let newline = pending.firstIndex(of: 0x0A) {
          let line = pending.prefix(upTo: newline)
          pending.removeSubrange(...newline)
          if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["type"] as? String, type == "preview" || type == "saved"
          {
            answersLock.lock(); answers.append(object); answersLock.unlock()
          }
        }
      }
    }
    func answer(_ type: String, timeout: TimeInterval = 5) -> [String: Any]? {
      let end = Date().addingTimeInterval(timeout)
      while Date() < end {
        answersLock.lock()
        let found = answers.first { $0["type"] as? String == type }
        if found != nil { answers.removeAll { $0["type"] as? String == type } }
        answersLock.unlock()
        if let found = found { return found }
        Thread.sleep(forTimeInterval: 0.1)
      }
      return nil
    }
    func command(_ object: [String: Any]) {
      guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
      let line = data + Data([0x0A])
      _ = line.withUnsafeBytes { write(monitorFd, $0.baseAddress, $0.count) }
    }
    Thread.sleep(forTimeInterval: 0.3)
    check("monitor mode is on", hub.isActive, "")

    func channel(_ port: Int) throws -> GRPCChannel {
      try GRPCChannelPool.with(
        target: .host("127.0.0.1", port: port), transportSecurity: .plaintext, eventLoopGroup: group)
    }
    let direct = ImageGenerationServiceNIOClient(channel: try channel(fakePort))
    let proxied = ImageGenerationServiceNIOClient(channel: try channel(proxyPort))

    let workdir = NSTemporaryDirectory() + "Scratch pad/Bilder \u{00FC}berall-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: workdir) }
    func writeState(delivered: Bool, id: String = "chat-abc123") {
      let content = "{\"requests\":{\"\(id)\":{\"requestId\":\"\(id)\",\"status\":\"completed\",\"delivered\":\(delivered)}}}"
      try? content.write(toFile: workdir + "/chat_requests_state.json", atomically: true, encoding: .utf8)
    }
    writeState(delivered: false)
    service.deliveryPollInterval = 0.2
    let encodedWorkdir = workdir.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "/").union(.alphanumerics)) ?? workdir
    let marks = CallOptions(customMetadata: HPACKHeaders([
      ("x-dt-client", "generate-image"), ("x-dt-tool", "generate_image"), ("x-dt-request-id", "chat-abc123"),
      ("x-dt-background", "true"), ("x-dt-workdir", encodedWorkdir),
    ]))
    let foregroundMarks = CallOptions(customMetadata: HPACKHeaders([
      ("x-dt-client", "generate-image"), ("x-dt-tool", "upscale"), ("x-dt-request-id", "chat-fg-1"),
      ("x-dt-background", "false"), ("x-dt-workdir", encodedWorkdir),
    ]))

    func request(_ prompt: String, device: DeviceType = .laptop, user: String = "generate-image") -> ImageGenerationRequest {
      ImageGenerationRequest.with {
        $0.prompt = prompt
        $0.negativePrompt = "neg"
        $0.user = user
        $0.device = device
        $0.chunked = true
      }
    }
    func run(_ client: ImageGenerationServiceNIOClient, _ prompt: String, options: CallOptions = CallOptions(), device: DeviceType = .laptop, user: String = "generate-image", base: ImageGenerationRequest? = nil)
      -> (frames: [Data], status: GRPCStatus)
    {
      let lock = NSLock()
      var frames = [Data]()
      let call = client.generateImage(base ?? request(prompt, device: device, user: user), callOptions: options) { response in
        lock.withLock { frames.append((try? response.serializedData()) ?? Data()) }
      }
      let status = (try? call.status.wait()) ?? GRPCStatus(code: .unknown, message: "no status")
      return (lock.withLock { frames }, status)
    }

    let expected = run(direct, "ok")
    let through = run(proxied, "ok", options: marks)
    check("same frames in the same order", through.frames == expected.frames, "(\(through.frames.count) of \(expected.frames.count))")
    check("same status", through.status.code == expected.status.code && through.status.message == expected.status.message, "")
    let failExpected = run(direct, "fail")
    let failThrough = run(proxied, "fail", options: marks)
    check("same failure", failThrough.status.code == failExpected.status.code && failThrough.status.message == failExpected.status.message, "\(failThrough.status.code)")
    check("the real server got the request as sent", fake.prompts.filter { $0 == "ok" }.count == 2, "")

    Thread.sleep(forTimeInterval: 0.3)
    let snapshot = service.probeSnapshot()
    let rows = snapshot["jobs"] as? [[String: Any]] ?? []

    let okRow = rows.first { ($0["detail"] as? String)?.contains("chat-abc123") == true && $0["state"] as? String == "generated" }
    check("the monitor shows the finished background call as Generated, not Delivered", okRow != nil && okRow?["line1"] as? String == "Generated", "\(rows.map { "\($0["state"] ?? "") \($0["project"] ?? "")" })")
    check("named by the tool, exactly", (okRow?["project"] as? String) == "generate_image" && okRow?["tool"] as? Bool == true && okRow?["open"] as? Bool == false, "\(okRow?["project"] ?? "-")")
    let hover = okRow?["detail"] as? String ?? ""
    check("the hover names tool, caller, request and background", hover.contains("Tool: generate_image") && hover.contains("Called by: generate-image") && hover.contains("Request of the caller: chat-abc123") && hover.contains("Background call: yes"), "")
    check("Project in the hover is the working directory, not a project of the app", hover.contains("Project: \(workdir)") && hover.components(separatedBy: "Project:").count == 2, "")
    let suggested = okRow?["filename"] as? String ?? ""
    check("the suggested file name is image-<time>-<ID><number>", suggested.range(of: #"^image-\d{8}T\d{9}Z-[a-z0-9]{2,3}1$"#, options: .regularExpression) != nil, suggested)
    check("images can be saved", okRow?["saveable"] as? Bool == true && okRow?["thumb"] != nil, "")

    writeState(delivered: true)
    var becameDelivered = false
    for _ in 0..<30 where !becameDelivered {
      Thread.sleep(forTimeInterval: 0.1)
      becameDelivered = (service.probeSnapshot()["jobs"] as? [[String: Any]] ?? []).contains {
        ($0["detail"] as? String)?.contains("chat-abc123") == true && $0["state"] as? String == "delivered" && $0["saveable"] as? Bool == true
      }
    }
    check("when the plugin's state file says delivered, the row becomes Delivered and keeps its images", becameDelivered, "")

    _ = run(proxied, "ok", options: foregroundMarks)
    Thread.sleep(forTimeInterval: 0.3)
    let foregroundRow = (service.probeSnapshot()["jobs"] as? [[String: Any]] ?? []).first {
      ($0["detail"] as? String)?.contains("chat-fg-1") == true
    }
    check("a foreground call is Delivered at once", foregroundRow?["state"] as? String == "delivered" && foregroundRow?["project"] as? String == "upscale", "\(String(describing: foregroundRow?["state"]))")

    _ = run(proxied, "two", options: foregroundMarks)
    Thread.sleep(forTimeInterval: 0.4)
    let twoRow = (service.probeSnapshot()["jobs"] as? [[String: Any]] ?? []).first {
      ($0["detail"] as? String)?.contains("chat-fg-1") == true && $0["state"] as? String == "delivered" && $0["thumb"] != nil
        && ($0["detail"] as? String)?.contains("Prompt: two") == true
    }
    check("a foreground call is Delivered, with its picture, and can be saved", twoRow?["saveable"] as? Bool == true && twoRow?["thumb"] != nil, "\(String(describing: twoRow?["state"]))")
    if let code = twoRow?["code"] as? String, let run = twoRow?["run"] as? Int {
      let out = NSTemporaryDirectory() + "fg-preview-\(UUID().uuidString).png"
      command(["cmd": "preview", "code": code, "run": run, "out": out])
      let big = answer("preview")
      check("a foreground call: the big picture works", big?["ok"] as? Bool == true && CGImageSourceCreateWithURL(URL(fileURLWithPath: out) as CFURL, nil) != nil, "\(String(describing: big?["ok"]))")
      try? FileManager.default.removeItem(atPath: out)
      let dir = NSTemporaryDirectory() + "fg-save-\(UUID().uuidString)"
      command(["cmd": "save", "code": code, "run": run, "dir": dir, "name": "image-fg-two1"])
      let saved = answer("saved")
      let files = (saved?["files"] as? [String] ?? []).map { ($0 as NSString).lastPathComponent }.sorted()
      check("a foreground call: Save as… writes both images", saved?["ok"] as? Bool == true && files == ["image-fg-two1.png", "image-fg-two2.png"], "\(files) \(String(describing: saved?["message"]))")
      try? FileManager.default.removeItem(atPath: dir)
    } else {
      check("a foreground call of two images shows in the monitor", false, "")
    }

    if let code = okRow?["code"] as? String, let run = okRow?["run"] as? Int {
      let out = NSTemporaryDirectory() + "preview-probe-\(UUID().uuidString).png"
      command(["cmd": "preview", "code": code, "run": run, "out": out])
      let big = answer("preview")
      check("a click on the small picture is answered with the big one", big?["ok"] as? Bool == true && big?["path"] as? String == out && CGImageSourceCreateWithURL(URL(fileURLWithPath: out) as CFURL, nil) != nil, "\(String(describing: big))")
      try? FileManager.default.removeItem(atPath: out)
      let dir = NSTemporaryDirectory() + "save-cmd-probe-\(UUID().uuidString)"
      command(["cmd": "save", "code": code, "run": run, "dir": dir, "name": suggested])
      let saved = answer("saved")
      let files = saved?["files"] as? [String] ?? []
      check("Save as… is answered with the files", saved?["ok"] as? Bool == true && files.count == 1 && files[0].hasSuffix("\(suggested).png") && FileManager.default.fileExists(atPath: files[0]), "\(String(describing: saved))")
      try? FileManager.default.removeItem(atPath: dir)
    } else {
      check("the finished call has code and run", false, "\(String(describing: okRow))")
    }
    check("the failure shows", rows.contains { $0["state"] as? String == "failed" }, "")
    check("nothing of the app is touched", service.probeAppGroupCount() == 0, "")

    let multiCall = proxied.generateImage(request("multi"), callOptions: marks) { _ in }
    var seen = Set<String>()

    for _ in 0..<12 {
      Thread.sleep(forTimeInterval: 0.52)
      let rowsNow = service.probeSnapshot()["jobs"] as? [[String: Any]] ?? []
      if let thumb = rowsNow.first(where: { $0["state"] as? String == "running" })?["thumb"] as? String { seen.insert(thumb) }
    }
    check("the previews of a Batch Size 4 are shown in turn: four different pictures", seen.count == 4, "\(seen.count) different")
    check("the turn changes every whole second and stays within the count",
      ProxyService.turn(of: 4, at: Date(timeIntervalSince1970: 100)) == 0 && ProxyService.turn(of: 4, at: Date(timeIntervalSince1970: 101)) == 1
        && ProxyService.turn(of: 4, at: Date(timeIntervalSince1970: 103)) == 3 && ProxyService.turn(of: 4, at: Date(timeIntervalSince1970: 104)) == 0
        && ProxyService.turn(of: 1, at: Date(timeIntervalSince1970: 105)) == 0, "")
    multiCall.cancel(promise: nil)
    _ = try? multiCall.status.wait()
    Thread.sleep(forTimeInterval: 0.5)

    var slowCall = proxied.generateImage(request("slow"), callOptions: marks) { _ in }
    Thread.sleep(forTimeInterval: 0.5)
    slowCall.cancel(promise: nil)
    _ = try? slowCall.status.wait()
    for _ in 0..<10 where fake.cancelled == 0 { Thread.sleep(forTimeInterval: 0.3) }
    check("a cancel of the client reaches the real server", fake.cancelled == 1, "\(fake.cancelled)")

    let second = proxied.generateImage(request("slow"), callOptions: marks) { _ in }
    for _ in 0..<10 where !(service.probeSnapshot()["jobs"] as? [[String: Any]] ?? []).contains(where: { $0["state"] as? String == "running" }) {
      Thread.sleep(forTimeInterval: 0.3)
    }
    let runningRows = service.probeSnapshot()["jobs"] as? [[String: Any]] ?? []
    let running = runningRows.first { $0["state"] as? String == "running" }
    check("the running call shows", running != nil, "\(runningRows.map { "\($0["state"] ?? "")" })")

    second.eventLoop.scheduleTask(in: .seconds(6)) { second.cancel(promise: nil) }
    if let code = running?["code"] as? String {
      let line = (try JSONSerialization.data(withJSONObject: ["cmd": "cancel", "code": code])) + Data([0x0A])
      _ = line.withUnsafeBytes { write(monitorFd, $0.baseAddress, $0.count) }
    }
    let status = (try? second.status.wait()) ?? GRPCStatus(code: .unknown, message: "no status")
    check("a cancel in the monitor ends the call as cancelled", status.code == .cancelled && status.message == "Cancelled in the queue monitor", "\(status.code) \(status.message ?? "")")
    Thread.sleep(forTimeInterval: 0.5)
    check("and reaches the real server", fake.cancelled == 2, "\(fake.cancelled)")

    func imageFrames(_ frames: [Data]) -> Int {
      frames.filter { ((try? ImageGenerationResponse(serializedBytes: $0))?.generatedImages.isEmpty) == false }.count
    }
    let phoneA = run(proxied, "ok", device: .phone, user: "Phone A")
    let tabletB = run(proxied, "ok", device: .tablet, user: "Tablet B")
    Thread.sleep(forTimeInterval: 1.0)
    if let receiptA = (try? ImageGenerationResponse(serializedBytes: phoneA.frames.first ?? Data()))?.generatedImages.first {
      var present = request("again", device: .phone, user: "Phone A")
      present.image = Data(SHA256.hash(data: receiptA))
      present.contents = [receiptA]
      let pickup = run(proxied, "again", device: .phone, user: "Phone A", base: present)

      let deliveredRow = (service.probeSnapshot()["jobs"] as? [[String: Any]] ?? []).first {
        $0["project"] as? String == "Phone A" && $0["state"] as? String == "delivered"
      }
      if let code = deliveredRow?["code"] as? String, let run = deliveredRow?["run"] as? Int {

        let out = NSTemporaryDirectory() + "delivered-preview-\(UUID().uuidString).png"
        command(["cmd": "preview", "code": code, "run": run, "out": out])
        let big = answer("preview")
        check("a delivered phone job shows the real image big, can be saved and removed (monitor open)",
          big?["ok"] as? Bool == true && deliveredRow?["saveable"] as? Bool == true && deliveredRow?["removable"] as? Bool == true
            && deliveredRow?["thumb"] != nil,
          "preview \(String(describing: big?["ok"])) saveable \(String(describing: deliveredRow?["saveable"])) removable \(String(describing: deliveredRow?["removable"]))")
        try? FileManager.default.removeItem(atPath: out)
      } else {
        check("the delivered phone job shows in the monitor", false, "")
      }
      check("a phone that presents its receipt gets its own result and not the result of another device",
        pickup.status.code == .ok && imageFrames(pickup.frames) == 2, "\(imageFrames(pickup.frames)) frames with images of \(pickup.frames.count)")
    } else {
      check("the phone got a receipt", false, "")
    }
    _ = tabletB

    service.issueReceipts = true
    func images(_ frames: [Data]) -> Int { imageFrames(frames) }

    func local(_ prompt: String, seed: UInt32) -> ImageGenerationRequest {
      var made = request(prompt, device: .laptop, user: "")
      made.configuration = configuration(seed: seed, batchCount: 1)
      return made
    }
    func describe(_ frames: [Data]) -> String {
      frames.map { frame -> String in
        let r = try? ImageGenerationResponse(serializedBytes: frame)
        return "images=\(r?.generatedImages.map { $0.count } ?? []) chunk=\(r.map { "\($0.chunkState)" } ?? "?")"
      }.joined(separator: " | ")
    }
    let startedBefore = fake.prompts.filter { $0 == "slow-receipt" }.count
    let receiptFrames = run(proxied, "slow-receipt", device: .laptop, user: "", base: local("slow-receipt", seed: 1)).frames
    check("receipts on: a new order of the local laptop gets its receipt, a status image", images(receiptFrames) == 1, describe(receiptFrames))
    for _ in 0..<20 where !(service.probeSnapshot()["jobs"] as? [[String: Any]] ?? []).contains(where: { $0["state"] as? String == "running" }) {
      Thread.sleep(forTimeInterval: 0.1)
    }
    let updateFrames = run(proxied, "slow-receipt", device: .laptop, user: "", base: local("slow-receipt", seed: 1)).frames
    Thread.sleep(forTimeInterval: 0.5)
    check("receipts on: a repeat while it runs starts no job", fake.prompts.filter { $0 == "slow-receipt" }.count == startedBefore + 1, "")

    func lastIsStatusImage(_ frames: [Data]) -> Bool {
      guard let last = frames.last, let r = try? ImageGenerationResponse(serializedBytes: last) else { return false }
      return (r.generatedImages.first?.count ?? 0) > 10_000
    }
    check("receipts on: and is answered with the current status report, not with nothing", lastIsStatusImage(updateFrames), describe(updateFrames))
    command(["cmd": "cancelAll"])
    Thread.sleep(forTimeInterval: 0.5)
    _ = run(proxied, "finished-receipt", device: .laptop, user: "", base: local("finished-receipt", seed: 3))
    Thread.sleep(forTimeInterval: 1.0)
    let noteFrames = run(proxied, "finished-receipt", device: .laptop, user: "", base: local("finished-receipt", seed: 3)).frames

    check("receipts on: a pickup of a finished order delivers the image and a delivery note after it",
      images(noteFrames) == 3, describe(noteFrames))
    service.issueReceipts = false

    func rowsNow() -> [[String: Any]] { service.probeSnapshot()["jobs"] as? [[String: Any]] ?? [] }
    func isFinished(_ row: [String: Any]) -> Bool { !["pending", "running"].contains(row["state"] as? String ?? "") }
    let toolsBefore = rowsNow().filter { $0["tool"] as? Bool == true }
    check("calls of tools stay in the monitor, every finished one removable",
      !toolsBefore.isEmpty && toolsBefore.filter(isFinished).allSatisfy { $0["removable"] as? Bool == true }, "\(toolsBefore.count) rows")
    check("every finished row is removable, none that waits or runs",
      rowsNow().allSatisfy { ($0["removable"] as? Bool == true) == isFinished($0) }, "")
    if let one = toolsBefore.first(where: isFinished), let code = one["code"] as? String, let run = one["run"] as? Int {
      command(["cmd": "remove", "code": code, "run": run])
      Thread.sleep(forTimeInterval: 0.4)
      check("Remove takes exactly that row away", rowsNow().filter { $0["tool"] as? Bool == true }.count == toolsBefore.count - 1, "")
    } else {
      check("a finished call of a tool to remove", false, "")
    }

    if let waiting = rowsNow().first(where: { $0["tool"] as? Bool != true && $0["state"] as? String == "generated" }),
      let code = waiting["code"] as? String, let run = waiting["run"] as? Int
    {
      let before = rowsNow().count
      command(["cmd": "remove", "code": code, "run": run])
      Thread.sleep(forTimeInterval: 0.4)
      check("Remove on a result that waits takes the row away", rowsNow().count == before - 1, "\(rowsNow().count) of \(before)")
    }

    let cliCall = run(proxied, "ok", device: .laptop, user: "draw-things-cli")
    check("a third-party client gets the server's frames and status unchanged", cliCall.frames == expected.frames && cliCall.status.code == .ok, "(\(cliCall.frames.count) frames)")
    Thread.sleep(forTimeInterval: 0.3)
    let cliRow = rowsNow().first { $0["project"] as? String == "draw-things-cli" }
    check("and shows in the monitor under its own name, like our tools", cliRow != nil && cliRow?["tool"] as? Bool == true, "\(String(describing: cliRow?["project"]))")

    func started(_ prompt: String, expecting: Int) -> Int {
      let end = Date().addingTimeInterval(3)
      while fake.prompts.filter({ $0 == prompt }).count < expecting, Date() < end { Thread.sleep(forTimeInterval: 0.05) }
      Thread.sleep(forTimeInterval: 0.5)
      return fake.prompts.filter { $0 == prompt }.count
    }
    func canvasConfiguration(seed: UInt32) -> Data {
      var fbb = FlatBufferBuilder()
      let model = fbb.create(string: "canvas.ckpt")
      let root = zzz_DflatGen_GenerationConfiguration.createGenerationConfiguration(
        &fbb, startWidth: 8, startHeight: 8, seed: seed, steps: 4, modelOffset: model, batchCount: 1)
      fbb.finish(offset: root)
      return Data(fbb.sizedByteArray)
    }
    func canvasPixels(_ shade: Float) -> (data: Data, hash: Data) {
      var tensor = Tensor<FloatType>(.CPU, .NHWC(1, 64, 96, 3))
      for y in 0..<64 { for x in 0..<96 { for c in 0..<3 { tensor[0, y, x, c] = FloatType(Float(x) / 96 * shade - 0.5) } } }
      let data = tensor.data(using: [.zip, .fpzip])
      return (data, Data(SHA256.hash(data: data)))
    }
    func withCanvas(_ prompt: String, _ shade: Float, device: DeviceType, user: String, seed: UInt32) -> ImageGenerationRequest {
      var canvasRequest = request(prompt, device: device, user: user)
      canvasRequest.configuration = canvasConfiguration(seed: seed)
      let pixels = canvasPixels(shade)
      canvasRequest.image = pixels.hash
      canvasRequest.contents = [pixels.data]
      return canvasRequest
    }

    let sameCanvasPrompt = "canvas-same"
    _ = run(proxied, sameCanvasPrompt, device: .phone, user: "Phone C", base: withCanvas(sameCanvasPrompt, 0.4, device: .phone, user: "Phone C", seed: 1))
    _ = run(proxied, sameCanvasPrompt, device: .phone, user: "Phone C", base: withCanvas(sameCanvasPrompt, 0.4, device: .phone, user: "Phone C", seed: 1))
    check("canvas: the same data and the same canvas image (same seed) starts no job", started(sameCanvasPrompt, expecting: 2) == 1, "\(fake.prompts.filter { $0 == sameCanvasPrompt }.count) started")
    let otherCanvasPrompt = "canvas-other"
    _ = run(proxied, otherCanvasPrompt, device: .phone, user: "Phone C", base: withCanvas(otherCanvasPrompt, 0.4, device: .phone, user: "Phone C", seed: 1))
    _ = run(proxied, otherCanvasPrompt, device: .phone, user: "Phone C", base: withCanvas(otherCanvasPrompt, 0.9, device: .phone, user: "Phone C", seed: 1))
    check("canvas: only the canvas image is another one: a new job", started(otherCanvasPrompt, expecting: 2) == 2, "\(fake.prompts.filter { $0 == otherCanvasPrompt }.count) started")

    func receiptMean(_ frames: [Data]) -> Float? {
      guard let first = try? ImageGenerationResponse(serializedBytes: frames.first ?? Data()), let data = first.generatedImages.first,
        let tensor = Tensor<FloatType>(data: data, using: [.zip, .fpzip])
      else { return nil }
      var sum: Float = 0
      var count = 0
      let shape = tensor.shape
      let stride = max(shape[shape.count - 3] * shape[shape.count - 2] * shape[shape.count - 1] / 4000, 1)
      tensor.withUnsafeBytes { raw in
        guard let p = raw.baseAddress?.assumingMemoryBound(to: FloatType.self) else { return }
        var i = 0
        while i < tensor.shape.reduce(1, *) { sum += Float(p[i]); count += 1; i += stride }
      }
      return count > 0 ? sum / Float(count) : nil
    }
    let plainReceipt = run(proxied, "canvas-back", device: .phone, user: "Phone C", base: { () -> ImageGenerationRequest in
      var plain = request("canvas-back", device: .phone, user: "Phone C")
      plain.configuration = canvasConfiguration(seed: 71)
      return plain
    }())
    let canvasReceipt = run(proxied, "canvas-back2", device: .phone, user: "Phone C", base: withCanvas("canvas-back2", 0.9, device: .phone, user: "Phone C", seed: 72))
    let plainMean = receiptMean(plainReceipt.frames)
    let canvasMean = receiptMean(canvasReceipt.frames)
    check("the receipt of an image2image order shows its canvas image behind it", plainMean != nil && canvasMean != nil && abs(plainMean! - canvasMean!) > 0.02, "\(plainMean ?? -9) vs \(canvasMean ?? -9)")

    func withHint(_ prompt: String, images: [String], weight: Float = 1, mask: String? = nil, seed: UInt32) -> ImageGenerationRequest {
      var hinted = request(prompt, device: .phone, user: "Phone C")
      hinted.configuration = canvasConfiguration(seed: seed)
      hinted.hints = [HintProto.with {
        $0.hintType = "shuffle"
        $0.tensors = images.map { name in TensorAndWeight.with { $0.tensor = Data(SHA256.hash(data: Data(name.utf8))); $0.weight = weight } }
      }]
      if let mask = mask { hinted.mask = Data(SHA256.hash(data: Data(mask.utf8))) }
      return hinted
    }
    let sameHintPrompt = "hint-same"
    _ = run(proxied, sameHintPrompt, device: .phone, user: "Phone C", base: withHint(sameHintPrompt, images: ["a", "b"], seed: 1))
    _ = run(proxied, sameHintPrompt, device: .phone, user: "Phone C", base: withHint(sameHintPrompt, images: ["b", "a"], seed: 1))
    check("moodboard: the same images (in another order, same seed) start no job", started(sameHintPrompt, expecting: 2) == 1, "\(fake.prompts.filter { $0 == sameHintPrompt }.count) started")
    let otherHintPrompt = "hint-other"
    _ = run(proxied, otherHintPrompt, device: .phone, user: "Phone C", base: withHint(otherHintPrompt, images: ["a", "b"], seed: 1))
    _ = run(proxied, otherHintPrompt, device: .phone, user: "Phone C", base: withHint(otherHintPrompt, images: ["a", "c"], seed: 1))
    check("moodboard: only an image of it is another one: a new job", started(otherHintPrompt, expecting: 2) == 2, "\(fake.prompts.filter { $0 == otherHintPrompt }.count) started")
    _ = run(proxied, otherHintPrompt, device: .phone, user: "Phone C", base: withHint(otherHintPrompt, images: ["a", "c"], seed: 1))
    check("moodboard: the changed moodboard sent again is a repeat of that new job", started(otherHintPrompt, expecting: 3) == 2, "\(fake.prompts.filter { $0 == otherHintPrompt }.count) started")
    let weightPrompt = "hint-weight"
    _ = run(proxied, weightPrompt, device: .phone, user: "Phone C", base: withHint(weightPrompt, images: ["a"], weight: 1, seed: 1))
    _ = run(proxied, weightPrompt, device: .phone, user: "Phone C", base: withHint(weightPrompt, images: ["a"], weight: 0.5, seed: 1))
    check("moodboard: only the weight of an image is another one: a new job", started(weightPrompt, expecting: 2) == 2, "\(fake.prompts.filter { $0 == weightPrompt }.count) started")
    let maskPrompt = "mask-other"
    _ = run(proxied, maskPrompt, device: .phone, user: "Phone C", base: withHint(maskPrompt, images: ["a"], mask: "m1", seed: 1))
    _ = run(proxied, maskPrompt, device: .phone, user: "Phone C", base: withHint(maskPrompt, images: ["a"], mask: "m2", seed: 1))
    check("mask: only the mask is another one: a new job", started(maskPrompt, expecting: 2) == 2, "\(fake.prompts.filter { $0 == maskPrompt }.count) started")

    let seedPrompt = "seed-other"
    _ = run(proxied, seedPrompt, device: .phone, user: "Phone C", base: withHint(seedPrompt, images: [], seed: 1))
    _ = run(proxied, seedPrompt, device: .phone, user: "Phone C", base: withHint(seedPrompt, images: [], seed: 1))
    check("seed: the same seed sent again (no picture, in doubt a pickup) starts no job", started(seedPrompt, expecting: 2) == 1, "\(fake.prompts.filter { $0 == seedPrompt }.count) started")
    _ = run(proxied, seedPrompt, device: .phone, user: "Phone C", base: withHint(seedPrompt, images: [], seed: 2))
    check("seed: another seed with nothing else changed is a new job", started(seedPrompt, expecting: 3) == 2, "\(fake.prompts.filter { $0 == seedPrompt }.count) started")

    let seedGroup = Group(code: "uu", key: "k", expected: 1)
    let seedRequest = withHint("p", images: [], seed: 7)
    seedGroup.add(Job(group: seedGroup, request: seedRequest), at: Date())
    var withPicture = withHint("p", images: [], seed: 8)
    withPicture.image = Data(SHA256.hash(data: Data("receipt".utf8)))
    check("seed: the seed of the job is no change, any other seed is, unless the request names a picture (a receipt clicked)",
      !ProxyService.seedChanged(of: seedGroup, in: seedRequest) && ProxyService.seedChanged(of: seedGroup, in: withHint("p", images: [], seed: 8))
        && !ProxyService.seedChanged(of: seedGroup, in: withPicture), "")

    let queuedGroup = Group(code: "zz", key: "k", expected: 1)
    let sameCanvas = withCanvas("p", 0.4, device: .laptop, user: "", seed: 1)
    let otherCanvas = withCanvas("p", 0.9, device: .laptop, user: "", seed: 1)
    queuedGroup.inputs = ProxyService.inputs(of: sameCanvas)
    var noPixels = otherCanvas
    noPixels.contents = []
    check("inputs: another image is a change, the same image is not", ProxyService.inputsChanged(of: queuedGroup, in: otherCanvas, byApp: false)
      && !ProxyService.inputsChanged(of: queuedGroup, in: sameCanvas, byApp: false), "")
    check("inputs: after a delivery the image on the canvas is the one the app put there, not a change", !ProxyService.inputsChanged(of: queuedGroup, in: otherCanvas, byApp: true), "")
    check("inputs: Text2Image names an image but sends no pixels, it never counts", !ProxyService.inputsChanged(of: queuedGroup, in: noPixels, byApp: false)
      && ProxyService.canvasInput(of: noPixels) == nil, "")
    let textOnly = Group(code: "yy", key: "k", expected: 1)
    check("inputs: an order that has no inputs recorded is never told apart", !ProxyService.inputsChanged(of: textOnly, in: otherCanvas, byApp: false), "")
    let hintedGroup = Group(code: "xx", key: "k", expected: 1)
    hintedGroup.inputs = ProxyService.inputs(of: withHint("p", images: ["a"], seed: 1))
    check("inputs: a moodboard that changed is a change, the same moodboard is not",
      ProxyService.inputsChanged(of: hintedGroup, in: withHint("p", images: ["z"], seed: 1), byApp: false)
        && !ProxyService.inputsChanged(of: hintedGroup, in: withHint("p", images: ["a"], seed: 9), byApp: false), "")

    check("inputs: after a delivery a changed moodboard still is a change, a changed canvas is not",
      ProxyService.inputsChanged(of: hintedGroup, in: withHint("p", images: ["z"], seed: 1), byApp: true)
        && !ProxyService.inputsChanged(of: hintedGroup, in: withHint("p", images: ["a"], seed: 9), byApp: true)
        && !ProxyService.inputsChanged(of: queuedGroup, in: otherCanvas, byApp: true), "")
    let maskedGroup = Group(code: "ww", key: "k", expected: 1)
    maskedGroup.inputs = ProxyService.inputs(of: withHint("p", images: ["a"], mask: "m1", seed: 1))
    check("inputs: after a delivery a changed mask still is a change", ProxyService.inputsChanged(of: maskedGroup, in: withHint("p", images: ["a"], mask: "m2", seed: 1), byApp: true), "")
    var depthRequest = withHint("p", images: ["a"], seed: 1)
    depthRequest.hints[0].hintType = "depth"
    let depthGroup = Group(code: "vv", key: "k", expected: 1)
    depthGroup.inputs = ProxyService.inputs(of: depthRequest)
    var otherDepth = withHint("p", images: ["q"], seed: 1)
    otherDepth.hints[0].hintType = "depth"
    check("inputs: a control the app may make from the canvas does not count after a delivery, and does without one",
      !ProxyService.inputsChanged(of: depthGroup, in: otherDepth, byApp: true) && ProxyService.inputsChanged(of: depthGroup, in: otherDepth, byApp: false), "")

    service.queueDrawThings = false
    let appCalled = run(proxied, "ok", user: "")
    check("Queue Draw Things off: the app gets the frames of the real server and nothing else", appCalled.frames == expected.frames, "(\(appCalled.frames.count) of \(expected.frames.count))")
    check("Queue Draw Things off: the same status as from the real server", appCalled.status.code == expected.status.code, "\(appCalled.status.code)")
    Thread.sleep(forTimeInterval: 0.3)
    let queueOffRows = rowsNow()
    let queueOffRow = queueOffRows.first { $0["app"] as? Bool == true }
    check("Queue Draw Things off: the call shows in the monitor as the app, not as a project", queueOffRow?["tool"] as? Bool == true && queueOffRow?["project"] as? String == "Draw Things", "\(queueOffRows.count) rows")
    check("Queue Draw Things off: the call is finished and delivered", queueOffRow?["state"] as? String == "delivered", "\(queueOffRow?["state"] ?? "-")")
    let appFailed = run(proxied, "fail", user: "")
    check("Queue Draw Things off: a failure comes as from the real server", appFailed.status.code == failExpected.status.code && appFailed.status.message == failExpected.status.message, "\(appFailed.status.code)")
    service.queueDrawThings = true
    let appQueued = run(proxied, "ok", user: "")
    check("Queue Draw Things on again: the app is queued as before (a receipt, not the frames of the server)", appQueued.frames != expected.frames, "(\(appQueued.frames.count) frames)")
    let generatedBeforeClose = rowsNow().filter { $0["state"] as? String == "generated" }.count
    let deliveredBeforeClose = rowsNow().filter { $0["state"] as? String == "delivered" }.count
    close(monitorFd)
    Thread.sleep(forTimeInterval: 0.5)

    check("closing the monitor cleans up what is Delivered and keeps what is Generated",
      deliveredBeforeClose > 0 && !rowsNow().contains { $0["state"] as? String == "delivered" }
        && rowsNow().filter { $0["state"] as? String == "generated" }.count == generatedBeforeClose,
      "delivered \(deliveredBeforeClose) -> \(rowsNow().filter { $0["state"] as? String == "delivered" }.count), generated \(generatedBeforeClose) -> \(rowsNow().filter { $0["state"] as? String == "generated" }.count)")

    for device in [DeviceType.laptop, .tablet, .phone] {
      let result = run(proxied, "ok", options: marks, device: device)
      check("no monitor, device \(device): the client gets the server's frames, no status image", result.frames == expected.frames && result.status.code == .ok, "(\(result.frames.count) frames)")
    }
    Thread.sleep(forTimeInterval: 0.3)
    check("no monitor: a call of a tool that waited for its result is Delivered and gone at once",
      !rowsNow().contains { $0["state"] as? String == "delivered" }, "\(rowsNow().filter { $0["state"] as? String == "delivered" }.count) delivered rows")

    let clientLogDirectory = NSTemporaryDirectory() + "client-log-\(UUID().uuidString)"
    FileLog.shared.open(directory: clientLogDirectory)
    defer { try? FileManager.default.removeItem(atPath: clientLogDirectory) }
    for device in [DeviceType.phone, .tablet] {
      let appCall = run(proxied, "app-\(device)", device: device)
      let first = try? ImageGenerationResponse(serializedBytes: appCall.frames.first ?? Data())
      check("device \(device) gets a status image as its receipt, whatever the lab file says",
        appCall.status.code == .ok && first?.generatedImages.isEmpty == false && appCall.frames != expected.frames, "(\(appCall.frames.count) frames)")
    }
    let clientLog = (try? String(contentsOfFile: clientLogDirectory + "/monitor.log", encoding: .utf8)) ?? ""
    check("every kind of client that is served as the app is noted once, with its headers",
      clientLog.components(separatedBy: "CLIENT served as the app").count == 3 && clientLog.contains("CLIENT headers:")
        && clientLog.contains("| phone") && clientLog.contains("| tablet"), "\(clientLog.components(separatedBy: "\n").filter { $0.contains("CLIENT") }.count) lines")
    let appRows = service.probeSnapshot()["jobs"] as? [[String: Any]] ?? []
    let phoneRow = appRows.first { ($0["detail"] as? String)?.contains("Device: phone") == true && ($0["detail"] as? String)?.contains("From: generate-image") == true }
    check("a job of a phone shows where it comes from, not unknown", phoneRow?["project"] as? String == "generate-image" && (phoneRow?["detail"] as? String)?.contains("From: generate-image") == true && (phoneRow?["detail"] as? String)?.contains("Address: 127.0.0.1") == true, "\(String(describing: phoneRow?["project"]))")

    func asked(_ prompt: String, expecting: Int) -> Int {
      let end = Date().addingTimeInterval(3)
      while fake.prompts.filter({ $0 == prompt }).count < expecting, Date() < end { Thread.sleep(forTimeInterval: 0.05) }
      Thread.sleep(forTimeInterval: 0.5)
      return fake.prompts.filter { $0 == prompt }.count
    }
    _ = run(proxied, "same-order", device: .phone, user: "Phone A")
    check("the first request of an order starts a job", asked("same-order", expecting: 1) == 1, "")
    _ = run(proxied, "same-order", device: .tablet, user: "Tablet B")
    check("the same data from another device is an order of its own", asked("same-order", expecting: 2) == 2, "")
    Thread.sleep(forTimeInterval: 1.0)
    let repeated = run(proxied, "same-order", device: .phone, user: "Phone A")
    check("a repeat without a receipt starts no job while the order is in the queue", asked("same-order", expecting: 2) == 2, "")
    check("and picks the finished result up", imageFrames(repeated.frames) == 2 && repeated.status.code == .ok, "\(imageFrames(repeated.frames)) frames with images")
    _ = run(proxied, "same-order", device: .phone, user: "Phone A")
    check("once it is delivered, the same data is a new order", asked("same-order", expecting: 3) == 3, "")

    func configuration(seed: UInt32, batchCount: UInt32 = 3) -> Data {
      var fbb = FlatBufferBuilder()
      let model = fbb.create(string: "burst.ckpt")
      let root = zzz_DflatGen_GenerationConfiguration.createGenerationConfiguration(
        &fbb, startWidth: 8, startHeight: 8, seed: seed, steps: 4, modelOffset: model, batchCount: batchCount)
      fbb.finish(offset: root)
      return Data(fbb.sizedByteArray)
    }
    func burst(_ seeds: [UInt32]) {
      for seed in seeds {
        var burstRequest = request("burst", device: .phone, user: "Phone A")
        burstRequest.configuration = configuration(seed: seed)
        _ = run(proxied, "burst", device: .phone, user: "Phone A", base: burstRequest)
      }
    }
    burst([11, 12, 13])
    check("a Batch Count 3 order is three runs", asked("burst", expecting: 3) == 3, "")
    Thread.sleep(forTimeInterval: 1.5)
    burst([21, 22, 23])
    check("the same data with other seeds and no picture is a new order: three more runs", asked("burst", expecting: 6) == 6, "")
    Thread.sleep(forTimeInterval: 1.5)
    burst([21, 22, 23])
    check("the same seeds again (no picture) start nothing: one pickup and the rest of its burst", asked("burst", expecting: 7) == 6, "")
    burst([31])
    check("after the pickup the same data with a new seed is a new order again", asked("burst", expecting: 7) == 7, "")

    func clip(_ seed: UInt32) -> [Data] {
      var clipRequest = request("clip", device: .phone, user: "Phone C")
      clipRequest.configuration = configuration(seed: seed, batchCount: 1)
      return run(proxied, "clip", device: .phone, user: "Phone C", base: clipRequest).frames
    }
    _ = clip(301)
    Thread.sleep(forTimeInterval: 1.5)
    _ = clip(302)
    Thread.sleep(forTimeInterval: 1.5)
    _ = clip(303)
    check("three video orders with other seeds are three jobs", asked("clip", expecting: 3) == 3, "\(fake.prompts.filter { $0 == "clip" }.count)")
    Thread.sleep(forTimeInterval: 1.5)
    var clipSeen = [Int]()
    for _ in 0..<2 { clipSeen.append(imageFrames(clip(301))) }
    check("a video goes out alone (the app glues a stream into one clip): 3 clips waiting, the pickup brings one clip and no receipt behind it", clipSeen.last == 1 && fake.prompts.filter { $0 == "clip" }.count == 3, "\(clipSeen), started \(fake.prompts.filter { $0 == "clip" }.count)")

    @discardableResult
    func send(_ prompt: String, user: String, batchCount: UInt32, seed: UInt32) -> [Data] {
      var jamRequest = request(prompt, device: .laptop, user: user)
      jamRequest.configuration = configuration(seed: seed, batchCount: batchCount)
      jamRequest.image = Data(SHA256.hash(data: Data([UInt8(truncatingIfNeeded: seed)])))
      return run(proxied, prompt, device: .laptop, user: user, base: jamRequest).frames
    }
    send("witch", user: "guest", batchCount: 2, seed: 101)
    send("witch", user: "guest", batchCount: 2, seed: 102)
    send("library", user: "guest", batchCount: 1, seed: 103)
    check("jam: an order with Batch Count 2 is two runs and another order one", asked("witch", expecting: 2) == 2 && asked("library", expecting: 1) == 1, "")
    Thread.sleep(forTimeInterval: 1.5)
    let jamStarted = fake.prompts.count
    let pickupFrames = send("witch", user: "guest", batchCount: 1, seed: 104)
    Thread.sleep(forTimeInterval: 0.6)
    check("jam: the same order sent again with Batch Count 1 and another seed starts no job", fake.prompts.count == jamStarted, "\(fake.prompts.count - jamStarted) started")

    check("jam: everything of jam that was finished is delivered with that one pickup, not only the same order",
      imageFrames(pickupFrames) >= 6, "\(imageFrames(pickupFrames)) frames with images")
    let nothingLeft = send("witch", user: "guest", batchCount: 1, seed: 105)
    _ = nothingLeft
    check("jam: after that the same data is a new order", asked("witch", expecting: 3) == 3, "")
    check("the address of the caller is known and is this computer", service.probeLastPeerWasLocal() == true, "\(String(describing: service.probeLastPeerWasLocal()))")
    check("this computer: loopback and own addresses", ProxyService.isThisComputer(remote: "127.0.0.1", interfaces: []) && ProxyService.isThisComputer(remote: "::1", interfaces: []) && ProxyService.isThisComputer(remote: "::ffff:127.0.0.1", interfaces: []) && ProxyService.isThisComputer(remote: "192.0.2.5", interfaces: ["192.0.2.5"]), "")
    check("elsewhere: another address, and an unknown one", !ProxyService.isThisComputer(remote: "192.0.2.77", interfaces: ["192.0.2.5"]) && !ProxyService.isThisComputer(remote: nil, interfaces: ["192.0.2.5"]) && !ProxyService.isThisComputer(remote: "", interfaces: []), "")
    check("own addresses can be read", !ProxyService.ownAddresses().isEmpty, "\(ProxyService.ownAddresses().count)")
    let agentNode = ImageGenerationRequest.with { $0.user = "generate-image" }
    check("a Node client without marks is one of ours",
      ProxyService.trackedClient(headers: HPACKHeaders([("user-agent", "grpc-node-js/1.14.4")]), request: agentNode) == "generate-image", "")
    check("the app is not", ProxyService.trackedClient(headers: HPACKHeaders([("user-agent", "grpc-swift-nio/1.27.0")]), request: agentNode) == nil, "")
    check("a mark wins", ProxyService.trackedClient(headers: HPACKHeaders([("x-dt-client", "process-image")]), request: agentNode) == "process-image", "")

    let swiftHeaders = HPACKHeaders([("user-agent", "grpc-swift-nio/1.16.0")])
    func asked(user: String) -> ImageGenerationRequest { ImageGenerationRequest.with { $0.user = user; $0.device = .laptop } }
    check("the CLI is a third party by its name", ProxyService.trackedClient(headers: swiftHeaders, request: asked(user: "draw-things-cli")) == "draw-things-cli", "")
    check("so is MediaGenerationKit", ProxyService.trackedClient(headers: swiftHeaders, request: asked(user: "MediaGenerationKit")) == "MediaGenerationKit", "")
    check("a Swift client with any other name is taken for the app (also a phone, also without a name)",
      ["Alex's iPhone", "workstation", ""].allSatisfy { ProxyService.trackedClient(headers: swiftHeaders, request: asked(user: $0)) == nil }, "")
    check("a call without a user agent is taken for the app", ProxyService.trackedClient(headers: HPACKHeaders(), request: asked(user: "workstation")) == nil, "")
    check("python, go and java clients are third parties, named by their user or their stack",
      ProxyService.trackedClient(headers: HPACKHeaders([("user-agent", "grpc-python/1.62.0 grpc-c/39.0.0 (osx; chttp2)")]), request: asked(user: "")) == "grpc-python"
        && ProxyService.trackedClient(headers: HPACKHeaders([("user-agent", "grpc-go/1.60.1")]), request: asked(user: "my tool")) == "my tool", "")

    let mine: Set<String> = ["workstation"]
    func local(_ user: String, _ device: DeviceType = .laptop) -> String? {
      ProxyService.trackedClient(headers: swiftHeaders, request: ImageGenerationRequest.with { $0.user = user; $0.device = device },
        peerIsLocal: true, localAppNames: mine)
    }
    check("this computer: the name of the Mac is the app (whatever the case), no name is the app", local("workstation") == nil && local("Workstation") == nil && local("") == nil, "")
    check("this computer: a laptop client with another name is a third party", local("my-script") == "my-script", "")
    check("this computer: a phone is the app whatever its name", local("Alex's iPhone", .phone) == nil, "")
    check("elsewhere: another name is still the app (a Mac in the network)",
      ProxyService.trackedClient(headers: swiftHeaders, request: ImageGenerationRequest.with { $0.user = "guest"; $0.device = .laptop }, peerIsLocal: false, localAppNames: mine) == nil, "")
    check("the rule is off without names", ProxyService.trackedClient(headers: swiftHeaders, request: ImageGenerationRequest.with { $0.user = "my-script"; $0.device = .laptop }, peerIsLocal: true, localAppNames: nil) == nil, "")
    check("this Mac has names", !ProxyService.ownNames().isEmpty, "\(ProxyService.ownNames().sorted())")
    check("a name from --third-party-user is a third party", ProxyService.trackedClient(headers: swiftHeaders, request: asked(user: "Foo"), extraThirdPartyUsers: ["Foo"]) == "Foo", "")

    do {
      let stateDir = NSTemporaryDirectory() + "restore-probe-\(UUID().uuidString)"
      let projectsDir = stateDir + "/projects"
      try FileManager.default.createDirectory(atPath: projectsDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(atPath: stateDir) }
      let store = try ResultStore(directory: stateDir, logger: logger)
      let earlier = Group(code: "zz", key: "k", expected: 1)
      earlier.origin = Group.Origin(user: "Alex's iPhone", device: "phone", address: "192.0.2.77")
      let record = ResultStore.Record(
        id: UUID(), groupId: earlier.id, groupCode: "zz", groupKey: "k", expected: 1, groupCreatedAt: earlier.createdAt,
        runIndex: 1, createdAt: Date(), startedAt: Date(), finishedAt: Date(), width: 96, height: 64, batchSize: 1,
        totalSteps: 4, model: "m", prompt: "p", seed: 7, imageCount: 1, origin: earlier.origin)
      let job = Job(group: earlier, restoring: record, responses: [ImageGenerationResponse.with {
        $0.generatedImages = [picture.data(using: [.zip, .fpzip])]
        $0.chunkState = .lastChunk
      }])
      earlier.add(job, at: Date())
      store.save(job)

      let deviceGroup = Group(code: "jj", key: "k-jj", expected: 1)
      deviceGroup.origin = Group.Origin(user: "guest", device: "laptop", address: "192.0.2.9")
      let deviceRecord = ResultStore.Record(
        id: UUID(), groupId: deviceGroup.id, groupCode: "jj", groupKey: "k-jj", expected: 1, groupCreatedAt: deviceGroup.createdAt,
        runIndex: 1, createdAt: Date(), startedAt: Date(), finishedAt: Date(), width: 96, height: 64, batchSize: 1,
        totalSteps: 4, model: "m", prompt: "jam's prompt", seed: 9, imageCount: 1, origin: deviceGroup.origin)
      let deviceJob = Job(group: deviceGroup, restoring: deviceRecord, responses: [ImageGenerationResponse.with {
        $0.generatedImages = [picture.data(using: [.zip, .fpzip])]
        $0.chunkState = .lastChunk
      }])
      deviceGroup.add(deviceJob, at: Date())
      store.save(deviceJob)
      let restarted = ProxyService(
        upstream: upstream, sharedSecret: "", background: true, followUpMode: .status, followUpModeFile: "/dev/null",
        burstWindow: 1.5, maxDeliveryImages: 0, statusWidth: 0, statusAspect: 1.25,
        locator: ProjectLocator(directory: projectsDir, logger: logger), state: nil,
        results: try ResultStore(directory: stateDir, logger: logger), dumpDirectory: nil, logger: logger)
      func finishedRun(_ code: String, origin: Group.Origin?) -> Group {
        let group = Group(code: code, key: "k-\(code)", expected: 1)
        group.origin = origin
        let record = ResultStore.Record(
          id: UUID(), groupId: group.id, groupCode: code, groupKey: group.key, expected: 1, groupCreatedAt: group.createdAt,
          runIndex: 1, createdAt: Date(), startedAt: Date(), finishedAt: Date(), width: 96, height: 64, batchSize: 1,
          totalSteps: 4, model: "m", prompt: "p", seed: 7, imageCount: 1)
        let job = Job(group: group, restoring: record, responses: [ImageGenerationResponse.with {
          $0.generatedImages = [picture.data(using: [.zip, .fpzip])]
          $0.chunkState = .lastChunk
        }])
        group.add(job, at: Date())
        return group
      }
      let desktopRun = finishedRun("dd", origin: nil)
      let phoneRun = finishedRun("pp", origin: Group.Origin(user: "Alex's iPhone", device: "phone", address: "192.0.2.77"))
      restarted.probeAdd(desktopRun)
      restarted.probeAdd(phoneRun)
      let seenFromDesktop = restarted.probeTables(partition: nil)
      let seenFromPhone = restarted.probeTables(partition: phoneRun.origin)

      func codes(_ tables: [(name: String, codes: [String])], where keep: (String) -> Bool) -> [String] {
        tables.filter { keep($0.name) }.flatMap { $0.codes }
      }
      let devices: Set<String> = ["Alex's iPhone", "guest"]
      check("for the desktop, no run of another device is in a table of a project of this computer",
        codes(seenFromDesktop, where: { !devices.contains($0) }) == ["dd"], "\(seenFromDesktop)")
      check("the phone's runs have a table of their own under the name of the device",
        Set(seenFromDesktop.first { $0.name == "Alex's iPhone" }?.codes ?? []) == ["pp", "zz"], "\(seenFromDesktop)")
      check("for the phone, its own table comes first and holds only its own runs",
        seenFromPhone.first?.name == "Alex's iPhone" && Set(seenFromPhone.first?.codes ?? []) == ["pp", "zz"]
          && codes(seenFromPhone, where: { !devices.contains($0) }) == ["dd"], "\(seenFromPhone)")

      var fbb = FlatBufferBuilder()
      let modelName = fbb.create(string: "old.ckpt")
      let configRoot = zzz_DflatGen_GenerationConfiguration.createGenerationConfiguration(
        &fbb, startWidth: 8, startHeight: 8, seed: 5, steps: 4, modelOffset: modelName, batchCount: 1)
      fbb.finish(offset: configRoot)
      let blob = Data(fbb.sizedByteArray)
      let oldRecord = ResultStore.Record(
        id: UUID(), groupId: UUID(), groupCode: "oo", groupKey: "an old prompt|neg|old.ckpt|512x512|1|4|1|text", expected: 1,
        groupCreatedAt: Date(), runIndex: 1, createdAt: Date(), startedAt: Date(), finishedAt: Date(), width: 64, height: 64,
        batchSize: 1, totalSteps: 4, model: "old.ckpt", prompt: "an old prompt", seed: 5, imageCount: 1,
        configuration: blob, negativePrompt: "neg")
      let wanted = ProxyService.orderKey(prompt: "an old prompt", negativePrompt: "neg", configuration: blob, hasMask: false, hintTypes: []).key
      var counted = oldRecord
      counted.groupKey = "an old prompt|neg|abcdef|2|nomask|"
      check("a run saved with the Batch Count in its key gets the key without it", ProxyService.currentKey(of: counted) == wanted, "")
      check("a run saved with the old key is found again by its order after a restart",
        ProxyService.currentKey(of: oldRecord) == wanted && ProxyService.currentKey(of: oldRecord) != oldRecord.groupKey, "")
      var newRecord = oldRecord
      newRecord.groupKey = wanted
      check("a run saved with the current key keeps it", ProxyService.currentKey(of: newRecord) == wanted, "")
      let restoredRows = restarted.probeSnapshot()["jobs"] as? [[String: Any]] ?? []
      let row = restoredRows.first
      let restoredDevice = restoredRows.first { $0["code"] as? String == "jj" }
      check("a run of another device, named by no receipt, is still there after the restart and not shelved",
        restoredDevice?["project"] as? String == "guest" && restarted.probeShelvedCodes().contains("zz") == false && !restarted.probeShelvedCodes().contains("jj"),
        "\(restarted.probeShelvedCodes())")
      let restoredPhone = restoredRows.first { $0["code"] as? String == "zz" }
      check("after a restart the run of the phone is still in the monitor, with where it came from",
        restoredPhone?["project"] as? String == "Alex's iPhone" && restoredPhone?["state"] as? String == "generated" && restoredPhone?["saveable"] as? Bool == true,
        "\(restoredRows.map { "\($0["state"] ?? "") \($0["project"] ?? "")" })")
      _ = row
    } catch {
      check("restart probe", false, "\(error)")
    }
    try proxyServer.close().wait()
    try fakeServer.close().wait()
    try group.syncShutdownGracefully()
  }
}
