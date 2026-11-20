import Crypto
import DataModels
import Diffusion
import CoreGraphics
import Foundation
import ImageIO
import GRPC
import GRPCImageServiceModels
import LocalImageGenerator
import Logging
import ModelZoo
import NIO
import NIOHPACK
import NNC

func hex(_ data: Data) -> String {
  data.prefix(8).map { String(format: "%02x", $0) }.joined()
}

final class StatusRegistry {
  struct Entry {

    var key: UUID

    var label: String
    var hash: Data

    var signature: [Float]
    var width: Int
    var height: Int

    var groups: Set<UUID> = []
  }

  static let signatureSize = 32

  static func signature(of tensor: Tensor<FloatType>) -> (values: [Float], width: Int, height: Int)? {
    let shape = tensor.shape
    guard shape.count >= 3 else { return nil }
    let h = shape[shape.count - 3]
    let w = shape[shape.count - 2]
    let c = shape[shape.count - 1]
    guard h >= signatureSize, w >= signatureSize, c >= 3 else { return nil }
    let n = signatureSize
    var sums = [Float](repeating: 0, count: n * n * 3)
    var counts = [Float](repeating: 0, count: n * n)
    tensor.withUnsafeBytes { raw in
      guard let p = raw.baseAddress?.assumingMemoryBound(to: FloatType.self) else { return }
      for y in 0..<h {
        let by = y * n / h
        for x in 0..<w {
          let cell = by * n + x * n / w
          counts[cell] += 1
          for k in 0..<3 {
            sums[cell * 3 + k] += Float(p[(y * w + x) * c + k])
          }
        }
      }
    }
    for cell in 0..<(n * n) where counts[cell] > 0 {
      for k in 0..<3 { sums[cell * 3 + k] /= counts[cell] }
    }
    return (sums, w, h)
  }

  private let lock = NSLock()
  private var entries: [Entry] = []
  private let capacity = StateStore.maxImages

  func add(_ entry: Entry) {
    lock.lock()
    defer { lock.unlock() }
    entries.append(entry)
    if entries.count > capacity {
      entries.removeFirst(entries.count - capacity)
    }
  }

  func retain(only hash: Data?) {
    lock.lock()
    defer { lock.unlock() }
    entries = entries.filter { hash != nil && $0.hash == hash }
  }

  func entry(forHash hash: Data) -> Entry? {
    lock.lock()
    defer { lock.unlock() }
    return entries.last { $0.hash == hash }
  }

  func restore(_ restored: [Entry]) {
    lock.lock()
    defer { lock.unlock() }
    entries = restored + entries
  }

  var all: [Entry] {
    lock.lock()
    defer { lock.unlock() }
    return entries
  }
}

final class ProxyService: ImageGenerationServiceProvider {
  var interceptors: ImageGenerationServiceServerInterceptorFactoryProtocol? = nil

  private let upstream: Upstream
  private let sharedSecret: String
  private let background: Bool
  private let logger: Logger
  private let registry = StatusRegistry()
  private let lock = NSLock()
  private var groups: [Group] = []

  private var tracked: [Group] = []

  enum FollowUpMode: String {
    case status, error, empty
  }
  private let followUpModeFile: String
  private let replyModeFile: String
  private let defaultFollowUpMode: FollowUpMode
  private let burstWindow: TimeInterval
  private let maxDeliveryImages: Int
  private let statusWidth: Int
  private let statusAspect: Double
  private let locator: ProjectLocator?
  private var lastStatusRequestAt: Date? = nil
  private var monitor: MonitorHub? = nil
  private let receiptQueue = DispatchQueue(label: "Receipts")

  var deliveryPollInterval: TimeInterval = 2

  fileprivate let deliveryQueue = DispatchQueue(label: "ToolDelivery", qos: .utility)
  fileprivate var deliveryWatch: DispatchSourceTimer? = nil

  private let monitorMediaQueue = DispatchQueue(label: "MonitorMedia", qos: .userInitiated)

  var stateDirectoryPath: String? = nil

  var issueReceipts = false

  var queueDrawThings = true
  private var seenClients = Set<String>()

  var localAppNames: Set<String>? = nil

  var thirdPartyUsers = Set<String>()
  var undoFile: URL? {
    stateDirectoryPath.map { URL(fileURLWithPath: $0).appendingPathComponent("deleted-receipts.sql") }
  }

  private var monitorHiddenJobs = Set<UUID>()

  private var monitorPickup: (key: String, remaining: Int, at: Date)? = nil

  private var monitorThumbs: [UUID: (key: Int, png: String)] = [:]

  private var monitorPreviewSets: [UUID: (key: Int, pngs: [String])] = [:]
  private var lastRequestAt: Date? = nil
  private var lastPeerWasLocal: Bool? = nil

  private var oldPickup: (key: String, partition: String?, remaining: Int, at: Date)? = nil

  private var clientLastRequestAt: [String: Date] = [:]
  private var lastResultDeliveryAt: [String: Date] = [:]
  private var lastClosedAt: Date? = nil
  private var requestCount = 0
  private var previousSummary: RequestSummary? = nil
  private let dumpDirectory: String?
  private let state: StateStore?
  private let results: ResultStore?
  private let historyFixer: HistoryFixer?

  init(
    upstream: Upstream, sharedSecret: String, background: Bool, followUpMode: FollowUpMode,
    followUpModeFile: String, replyModeFile: String = "", burstWindow: TimeInterval, maxDeliveryImages: Int,
    statusWidth: Int, statusAspect: Double, locator: ProjectLocator?,
    state: StateStore? = nil, results: ResultStore? = nil, historyFixer: HistoryFixer? = nil,
    dumpDirectory: String?, logger: Logger
  ) {
    self.state = state
    self.results = results
    self.historyFixer = historyFixer
    self.dumpDirectory = dumpDirectory
    self.maxDeliveryImages = maxDeliveryImages
    self.statusWidth = statusWidth
    self.statusAspect = statusAspect
    self.locator = locator
    self.upstream = upstream
    self.sharedSecret = sharedSecret
    self.background = background
    self.defaultFollowUpMode = followUpMode
    self.followUpModeFile = followUpModeFile
    self.replyModeFile = replyModeFile
    results?.projectProvider = { [weak locator] id in locator?.assignment(of: id)?.project }
    self.burstWindow = burstWindow
    self.logger = logger
    restoreResults()

    var referenced = Set<UUID>()
    if let state = state {
      let restored = state.load()
      for image in restored.images {
        referenced.insert(image.key)
        image.groups.forEach { referenced.insert($0) }
      }

      if groups.contains(where: { $0.isListed }) {
        registry.restore(
          restored.images.map {
            StatusRegistry.Entry(
              key: $0.key, label: $0.label, hash: $0.hash, signature: [], width: 0, height: 0,
              groups: Set($0.groups))
          })
        for project in restored.projects {
          locator?.restore(
            .init(
            project: project.project, quality: project.confirmed ? .confirmed : .guessed,
            receipt: project.receipt),
            for: project.key)
        }
      } else {
        state.clear(keeping: nil, project: nil)
      }
      locator?.onAssignment = { key, assignment in
        state.record(
          StateStore.Project(
            key: key, project: assignment.project, confirmed: assignment.quality == .confirmed,
            receipt: assignment.receipt, at: Date()))
      }
    }
    dropUnknownRestored(referenced: referenced)
  }

  private func dropUnknownRestored(referenced: Set<UUID>) {
    guard let locator = locator, locator.canRead else { return }

    let unknown = groups.filter {
      $0.origin == nil && locator.assignment(of: $0.id) == nil && !referenced.contains($0.id)
    }
    for group in unknown {
      group.shelved = true
      logger.info("Request \(group.code) of an earlier start is kept for the monitor only: its project is not known")
    }
  }

  static func currentKey(of record: ResultStore.Record) -> String {
    let remake =
      record.groupKey.hasSuffix("|text") || record.groupKey.hasSuffix("|image")
      || record.groupKey.hasSuffix("|nomask|")
    guard remake, let configuration = record.configuration, !configuration.isEmpty
    else { return record.groupKey }
    return orderKey(
      prompt: record.prompt, negativePrompt: record.negativePrompt ?? "", configuration: configuration,
      hasMask: false, hintTypes: []
    ).key
  }

  private func restoreResults() {
    guard let results = results else { return }
    var restoredGroups = [UUID: Group]()
    var waitingTools = false
    for entry in results.loadEntries() {
      let record = entry.record

      let payload = Payload(
        restoring: entry.directory, imageCount: record.imageCount, completeImages: record.completeImages ?? 0,
        hasAudio: record.hasAudio ?? false)
      let group: Group
      if let tool = record.tool {

        group = Group(
          id: record.groupId, code: record.groupCode, key: record.groupKey, expected: record.expected,
          createdAt: record.groupCreatedAt)
        group.apply(tool)
        tracked.append(group)
        if tool.background, record.delivered != true { waitingTools = true }
      } else if let existing = restoredGroups[record.groupId] {
        group = existing
      } else {
        group = Group(
          id: record.groupId, code: record.groupCode, key: Self.currentKey(of: record), expected: record.expected,
          createdAt: record.groupCreatedAt)
        group.origin = record.origin
        restoredGroups[record.groupId] = group
        groups.append(group)
      }
      let job = Job(group: group, restoring: record, payload: payload, delivered: record.delivered == true)
      group.add(job, at: record.createdAt)
      job.runIndex = record.runIndex
      if record.tool != nil {
        if let png = results.thumbnail(for: record.id) { monitorThumbs[record.id] = (-1, png) }
      } else if let project = record.project, locator?.assignment(of: group.id) == nil {
        locator?.restore(.init(project: project, quality: .guessed, receipt: nil), for: group.id)
      }
    }
    if waitingTools { watchDeliveryOfTools() }

    let finished = Set(groups.flatMap { $0.jobs.map { $0.id } })
    for record in results.loadOpen(excluding: finished) {
      let group: Group
      if let existing = restoredGroups[record.groupId] {
        group = existing
      } else {
        group = Group(
          id: record.groupId, code: record.groupCode, key: record.groupKey, expected: record.expected,
          createdAt: record.groupCreatedAt)
        group.origin = record.origin
        restoredGroups[record.groupId] = group
        groups.append(group)
      }
      let job = Job(
        group: group, restoringFailed: record,
        message: "The proxy was restarted while this was running")
      group.add(job, at: record.createdAt)
      job.runIndex = record.runIndex
      if let project = record.project, locator?.assignment(of: group.id) == nil {
        locator?.restore(.init(project: project, quality: .guessed, receipt: nil), for: group.id)
      }
      logger.info("Run \(record.groupCode) \(record.runIndex) was lost with the last stop of the proxy")
    }
  }

  private func currentFollowUpMode() -> FollowUpMode {
    guard
      let content = try? String(contentsOfFile: followUpModeFile, encoding: .utf8),
      let mode = FollowUpMode(
        rawValue: content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    else { return defaultFollowUpMode }
    return mode
  }

  private func replyMode(_ key: String) -> String? {
    guard !replyModeFile.isEmpty, let content = try? String(contentsOfFile: replyModeFile, encoding: .utf8)
    else { return nil }
    for word in content.lowercased().split(whereSeparator: { $0.isWhitespace }) {
      let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
      if parts.count == 2, parts[0] == key { return parts[1] }
    }
    return nil
  }

  private func bridge<R>(_ future: EventLoopFuture<R>, on loop: EventLoop) -> EventLoopFuture<R> {
    let promise = loop.makePromise(of: R.self)
    future.cascade(to: promise)
    return promise.futureResult
  }

  func echo(request: EchoRequest, context: StatusOnlyCallContext) -> EventLoopFuture<EchoReply> {
    bridge(upstream.client.echo(request).response, on: context.eventLoop)
  }

  func filesExist(request: FileListRequest, context: StatusOnlyCallContext) -> EventLoopFuture<
    FileExistenceResponse
  > {
    bridge(upstream.client.filesExist(request).response, on: context.eventLoop)
  }

  func pubkey(request: PubkeyRequest, context: StatusOnlyCallContext) -> EventLoopFuture<
    PubkeyResponse
  > {
    bridge(upstream.client.pubkey(request).response, on: context.eventLoop)
  }

  func hours(request: HoursRequest, context: StatusOnlyCallContext) -> EventLoopFuture<
    HoursResponse
  > {
    bridge(upstream.client.hours(request).response, on: context.eventLoop)
  }

  func uploadFile(context: StreamingResponseCallContext<UploadResponse>) -> EventLoopFuture<
    (StreamEvent<FileUploadRequest>) -> Void
  > {
    let call = upstream.client.uploadFile { response in
      context.sendResponse(response, promise: nil)
    }
    call.status.whenComplete { result in
      switch result {
      case .success(let status): context.statusPromise.succeed(status)
      case .failure(let error): context.statusPromise.fail(error)
      }
    }
    context.statusPromise.futureResult.whenComplete { _ in
      call.cancel(promise: nil)
    }
    return context.eventLoop.makeSucceededFuture { (event: StreamEvent<FileUploadRequest>) in
      switch event {
      case .message(let message): call.sendMessage(message, promise: nil)
      case .end: call.sendEnd(promise: nil)
      }
    }
  }

  func generateImage(
    request: ImageGenerationRequest, context: StreamingResponseCallContext<ImageGenerationResponse>
  ) -> EventLoopFuture<GRPCStatus> {
    let received = Date()
    let summary = RequestSummary(request)
    let number = lock.withLockCompat { () -> Int in
      requestCount += 1
      return requestCount
    }
    logMeasurement(number: number, summary: summary, received: received)

    let headers = context.headers.compactMap { header -> String? in
      let name = header.name.lowercased()
      guard name != "authorization" else { return nil }
      return "\(name)=\(header.value.prefix(60))"
    }
    logger.info("REQ \(number) call headers: \(headers.joined(separator: "; "))")

    do {
      let kind = "\(context.headers["user-agent"].first ?? "-") | \(request.user.isEmpty ? "-" : request.user) | \(request.device)"
      if Self.trackedClient(
        headers: context.headers, request: request, extraThirdPartyUsers: thirdPartyUsers,
        peerIsLocal: Self.peerIsThisComputer(context), localAppNames: localAppNames) != nil,
        lock.withLockCompat({ seenClients.insert("passed: " + kind).inserted })
      {
        FileLog.shared.append("CLIENT passed through: user agent | user | device: \(kind)")
        FileLog.shared.append("CLIENT headers: \(headers.joined(separator: "; "))")
        FileLog.shared.append("CLIENT request: scaleFactor \(request.scaleFactor), chunked \(request.chunked), secret \(request.sharedSecret.isEmpty ? "no" : "yes"), override \(request.override.models.count) bytes of models")
      }
    }
    let peerIsLocal = Self.peerIsThisComputer(context)
    let trackedName = Self.trackedClient(
      headers: context.headers, request: request, extraThirdPartyUsers: thirdPartyUsers,
      peerIsLocal: peerIsLocal, localAppNames: localAppNames)
    if trackedName != nil || !queueDrawThings {
      let isApp = trackedName == nil
      return trackedRelay(
        number: number, request: request, context: context,
        client: trackedName ?? (request.user.isEmpty ? "Draw Things" : request.user),
        tool: isApp ? "Draw Things" : context.headers["x-dt-tool"].first.flatMap { $0.isEmpty ? nil : $0 },
        isApp: isApp,
        requestId: context.headers["x-dt-request-id"].first,
        workdir: context.headers["x-dt-workdir"].first.flatMap { $0.removingPercentEncoding }.flatMap { $0.isEmpty ? nil : $0 },
        background: context.headers["x-dt-background"].first?.lowercased() == "true")
    }
    let canvasFromApp = resultsWentOutSincePreviousRequest(
      client: Self.origin(of: request, context: context)?.key ?? "local", at: received)

    let clientKind = "\(context.headers["user-agent"].first ?? "-") | \(request.user.isEmpty ? "-" : request.user) | \(request.device)"
    if lock.withLockCompat({ seenClients.insert(clientKind).inserted }) {
      FileLog.shared.append("CLIENT served as the app: user agent | user | device: \(clientKind)")
      FileLog.shared.append("CLIENT headers: \(headers.joined(separator: "; "))")
      FileLog.shared.append("CLIENT request: scaleFactor \(request.scaleFactor), chunked \(request.chunked), secret \(request.sharedSecret.isEmpty ? "no" : "yes"), override \(request.override.models.count) bytes of models")
    }
    context.closeFuture.whenComplete { [weak self, logger] _ in
      let closed = Date()
      self?.lock.withLockCompat { self?.lastClosedAt = closed }
      logger.info(
        "REQ \(number) stream closed after \(String(format: "%.2f", closed.timeIntervalSince(received))) s"
      )
    }
    var (match, isStatus, reason) = recognise(request)
    if !isStatus, Self.isStatusQuery(request.prompt) {
      isStatus = true
      reason = "the prompt is `\(request.prompt.trimmingCharacters(in: .whitespacesAndNewlines))`: a question for the overview, no recognised status image needed"
    }
    logger.info("DECISION \(number): \(isStatus ? "STATUS REQUEST" : "NEW JOB") - \(reason)")

    FileLog.shared.append(
      "REQ \(number) \(request.device) \(request.user.isEmpty ? "-" : request.user) order \(Self.shortHash(Self.monitorGroupKey(of: request).key)) batchCount \(Self.monitorGroupKey(of: request).expected) seed \(GenerationConfiguration.from(data: request.configuration).seed) image \(request.hasImage ? hex(request.image).prefix(8).description : "-") pixels \(request.contents.isEmpty ? "no" : "yes"), inputs [\(Self.inputsSummary(of: request))]: \(isStatus ? "STATUS" : "NEW") - \(reason)")
    guard background else {
      return relay(number: number, request: request, context: context)
    }
    if !sharedSecret.isEmpty, request.sharedSecret != sharedSecret {
      return context.eventLoop.makeFailedFuture(
        GRPCStatus(code: .permissionDenied, message: "Shared secret mismatch"))
    }

    let local = Self.peerIsThisComputer(context)
    let origin = Self.origin(of: request, context: context)
    logger.info("DECISION \(number): device \(request.device), client \(local ? "on this computer" : "elsewhere"), monitor \(monitor?.isActive == true ? "on" : "off")")
    lock.withLockCompat { lastPeerWasLocal = local }

    if request.device == .laptop, local, monitor?.isActive == true, !issueReceipts {
      return monitorRequest(
        number: number, request: request, received: received, pickupOnly: isStatus, receipt: match,
        canvasFromApp: canvasFromApp, context: context)
    }

    if !isStatus, let pickup = sameOrderInQueue(request: request, origin: origin, at: received, canvasFromApp: canvasFromApp) {
      isStatus = true
      match = pickup.entry
      reason = pickup.reason
      logger.info("DECISION \(number): STATUS REQUEST - \(pickup.reason)")
      FileLog.shared.append("REQ \(number) -> PICKUP - \(pickup.reason)")
    }
    if isStatus {
      let followUp: Bool = lock.withLockCompat {
        defer { lastStatusRequestAt = received }
        guard let last = lastStatusRequestAt else { return false }
        return received.timeIntervalSince(last) < burstWindow
      }
      if followUp {
        let mode = currentFollowUpMode()
        logger.info(
          "FOLLOW-UP status request within \(burstWindow) s of the previous one, mode: \(mode.rawValue)"
        )
        switch mode {
        case .status:
          break
        case .error:
          return context.eventLoop.makeFailedFuture(
            GRPCStatus(
              code: .failedPrecondition,
              message: "The result was already delivered with the previous request."))
        case .empty:
          return context.eventLoop.makeSucceededFuture(.ok)
        }
      }
      return answerStatus(entry: match, request: request, context: context)
    }

    let (job, isNew) = startJob(request, at: received, origin: origin)

    if isNew, origin == nil, monitor?.isActive == true {
      let batches = Self.monitorGroupKey(of: request).expected
      monitor?.broadcast(["type": "event", "kind": "accepted", "code": job.code, "sound": batches > 1])
    }
    if !isNew {
      let mode = currentFollowUpMode()
      logger.info(
        "Run \(job.runIndex) of group \(job.code) started in the background (a further batch of the same order), reply mode: \(mode.rawValue)"
      )
      switch mode {
      case .status:
        break
      case .error:
        return context.eventLoop.makeFailedFuture(
          GRPCStatus(
            code: .failedPrecondition,
            message: "Group \(job.code) was already answered with the first request."))
      case .empty:
        return context.eventLoop.makeSucceededFuture(.ok)
      }
    } else {
      logger.info("Group \(job.code) created, run 1 started in the background, answering with a status image")

      if let forgotten = replyMode("start") {
        logger.warning("The reply-mode file says start=\(forgotten): ignored, an order is always answered with its receipt")
      }
    }
    let group = job.group
    let subject = jobSubject(group, request: request)
    return respondWithStatusImage(subject: subject, context: context)
  }

  private func relay(
    number: Int, request: ImageGenerationRequest,
    context: StreamingResponseCallContext<ImageGenerationResponse>
  ) -> EventLoopFuture<GRPCStatus> {
    let logger = logger
    let started = Date()
    var lastPreviewShape: String? = nil
    var imageResponses = 0
    var imagesTotal = 0
    var previews = 0
    let call = upstream.client.generateImage(request) { response in
      if response.hasPreviewImage {
        previews += 1
        let shape = Tensor<FloatType>(data: response.previewImage, using: [.zip, .fpzip]).map {
          "\($0.shape)"
        } ?? "undecodable"
        if shape != lastPreviewShape {
          lastPreviewShape = shape
          logger.info("REQ \(number) server preview tensor shape: \(shape) (previews so far: \(previews))")
        }
      }
      if !response.generatedImages.isEmpty {
        imageResponses += 1
        imagesTotal += response.generatedImages.count
        let shapes = response.generatedImages.map { data in
          Tensor<FloatType>(data: data, using: [.zip, .fpzip]).map { "\($0.shape)" } ?? "chunk \(data.count)B"
        }
        logger.info(
          "REQ \(number) server sent \(response.generatedImages.count) image(s) \(shapes), chunkState \(response.chunkState)"
        )
      }
      context.sendResponse(response, promise: nil)
    }
    let promise = context.eventLoop.makePromise(of: GRPCStatus.self)
    call.status.whenComplete { result in
      logger.info(
        "REQ \(number) server finished after \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(imagesTotal) image(s) in \(imageResponses) response(s), \(previews) preview(s), status \(result)"
      )
    }
    call.status.cascade(to: promise)
    context.closeFuture.whenComplete { _ in
      call.cancel(promise: nil)
    }
    return promise.futureResult
  }

  static let requestIDAlphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

  private func makeUniqueCode() -> String {
    let alphabet = Self.requestIDAlphabet

    var attempts = 0
    while true {
      attempts += 1
      let length = attempts <= 200 ? 2 : 3
      let code = String((0..<length).map { _ in alphabet.randomElement()! })
      if !groups.contains(where: { $0.code == code }), !tracked.contains(where: { $0.code == code }) { return code }
    }
  }

  private static func monitorGroupKey(of request: ImageGenerationRequest) -> (key: String, expected: Int) {
    orderKey(
      prompt: request.prompt, negativePrompt: request.negativePrompt, configuration: request.configuration,
      hasMask: request.hasMask, hintTypes: request.hints.map { $0.hintType })
  }

  struct Inputs: Equatable {
    var canvas: Data?
    var mask: Data?
    var hints: [String]
  }

  static func inputs(of request: ImageGenerationRequest) -> Inputs {
    let hints = request.hints.map { hint -> String in
      let tensors = hint.tensors.map { "\(hex($0.tensor))@\($0.weight)" }.sorted().joined(separator: ",")
      return "\(hint.hintType)[\(tensors)]"
    }.sorted()
    return Inputs(canvas: canvasInput(of: request), mask: request.hasMask ? request.mask : nil, hints: hints)
  }

  static func inputsSummary(of request: ImageGenerationRequest) -> String {
    let inputs = Self.inputs(of: request)
    let contents = request.contents.map { hex(Data(SHA256.hash(data: $0))).prefix(8).description }.joined(separator: ",")
    return "canvas \(inputs.canvas.map { hex($0).prefix(8).description } ?? "-"), contents \(contents.isEmpty ? "-" : contents), mask \(inputs.mask.map { hex($0).prefix(8).description } ?? "-"), hints \(inputs.hints.isEmpty ? "-" : inputs.hints.map { Self.shortHint($0) }.joined(separator: ";"))"
  }

  private static func shortHint(_ hint: String) -> String {
    guard let open = hint.firstIndex(of: "["), hint.hasSuffix("]") else { return hint }
    let tensors = hint[hint.index(after: open)..<hint.index(before: hint.endIndex)].split(separator: ",").map { entry -> String in
      let parts = entry.split(separator: "@", maxSplits: 1)
      return (parts.first.map { String($0.prefix(8)) } ?? "") + (parts.count > 1 ? "@" + parts[1] : "")
    }
    return "\(hint[..<open])[\(tensors.joined(separator: ","))]"
  }

  static func canvasInput(of request: ImageGenerationRequest) -> Data? {
    guard request.hasImage, !request.contents.isEmpty else { return nil }
    return request.contents.contains { Data(SHA256.hash(data: $0)) == request.image } ? request.image : nil
  }

  static func canvasPixels(of request: ImageGenerationRequest) -> Data? {
    guard request.hasImage else { return nil }
    return request.contents.first { Data(SHA256.hash(data: $0)) == request.image }
  }

  static func inputsChanged(of group: Group, in request: ImageGenerationRequest, byApp: Bool) -> Bool {
    guard let theirs = group.inputs else { return false }
    let mine = inputs(of: request)

    if let a = theirs.mask, let b = mine.mask, a != b { return true }
    if theirs.hints.filter(isUserHint) != mine.hints.filter(isUserHint) { return true }

    guard !byApp else { return false }
    if let a = theirs.canvas, let b = mine.canvas, a != b { return true }
    return theirs.hints != mine.hints
  }

  static func seedChanged(of group: Group, in request: ImageGenerationRequest) -> Bool {
    guard !request.hasImage else { return false }
    let seed = GenerationConfiguration.from(data: request.configuration).seed
    return !group.jobs.contains { job in
      var own = job.seed
      for _ in 0..<job.batchSize {
        if own == seed { return true }
        own = HistoryFixer.nextSeed(after: own)
      }
      return false
    }
  }

  static func orderChanged(of group: Group, in request: ImageGenerationRequest, byApp: Bool) -> Bool {
    seedChanged(of: group, in: request) || inputsChanged(of: group, in: request, byApp: byApp)
  }

  private static func isUserHint(_ hint: String) -> Bool { hint.hasPrefix("shuffle[") }

  private func resultsWentOutSincePreviousRequest(client: String, at time: Date) -> Bool {
    lock.withLockCompat {
      let previous = clientLastRequestAt[client]
      clientLastRequestAt[client] = time
      guard let previous = previous, let delivered = lastResultDeliveryAt[client] else { return false }
      return delivered > previous
    }
  }

  private func noteResultDelivery(client: String, at time: Date) {
    lock.withLockCompat { lastResultDeliveryAt[client] = time }
  }

  static func orderKey(
    prompt: String, negativePrompt: String, configuration data: Data, hasMask: Bool, hintTypes: [String]
  ) -> (key: String, expected: Int) {
    let configuration = GenerationConfiguration.from(data: data)
    let expected = max(Int(configuration.batchCount), 1)

    var parameters: String
    if let table = try? HistoryCorrector.decodeConfiguration(data) {
      parameters = shortHash(
        HistoryCorrector.fingerprint(
          table, layout: NodeLayout.configuration, excluding: ["seed", "id", "name", "batch_count"]))
    } else {
      parameters = [
        configuration.model ?? "", "\(configuration.startWidth)x\(configuration.startHeight)",
        "\(configuration.batchSize)", "\(configuration.steps)", "\(configuration.guidanceScale)",
        "\(configuration.strength)",
      ].joined(separator: ",")
    }
    let key = [
      prompt, negativePrompt, parameters, hasMask ? "mask" : "nomask",
      hintTypes.joined(separator: ","),
    ].joined(separator: "|")
    return (key, expected)
  }

  private static func shortHash(_ text: String) -> String {
    hex(Data(SHA256.hash(data: Data(text.utf8)))).prefix(6).description
  }

  private func startJob(_ request: ImageGenerationRequest, at time: Date, project: String? = nil, monitorMode: Bool = false, origin: Group.Origin? = nil) -> (Job, Bool) {

    let (key, expected) = Self.monitorGroupKey(of: request)
    let (job, isNew): (Job, Bool) = lock.withLockCompat {
      let existing = groups.last { $0.canTake(key: key, at: time, window: burstWindow) }
      let group = existing ?? Group(code: makeUniqueCode(), key: key, expected: expected)
      if existing == nil {
        group.origin = origin
        group.inputs = Self.inputs(of: request)
        group.canvasData = Self.canvasPixels(of: request)
        groups.append(group)
      }
      let job = Job(group: group, request: request)
      job.attachSpool(results?.spoolDirectory(for: job.id))
      group.add(job, at: time)
      return (job, existing == nil)
    }
    let logger = logger

    if isNew, let project = project { locator?.assignGuess(project: project, for: job.group.id) }
    results?.saveOpen(job)
    let call = upstream.client.generateImage(request) { response in
      job.consume(response)
    }
    job.call = call
    call.status.whenComplete { [weak self] result in
      guard let self = self else { return }
      job.finish(result)
      if self.monitor != nil {
        FileLog.shared.append("RUN \(job.code) run \(job.runIndex) finished: \(job.snapshot().state.label), \(job.undeliveredImageCount) images; \(job.timingReport)")
      }
      logger.info(
        "Group \(job.code) run \(job.runIndex) finished: \(job.snapshot().state.label); \(job.timingReport)")
      if case .done = job.state {
        self.results?.save(job, keepDelivered: self.monitor?.isActive == true)
        self.keepWithinLimits()

        if self.monitor?.isActive != true { self.cleanDelivered() }
      }
      self.results?.removeOpen(job.id)
    }
    return (job, isNew)
  }

  private struct StatusSubject {
    var key: UUID
    var seeds: Set<UInt32>
    var model: String
    var steps: Int
    var width: Int
    var height: Int

    var project: String?

    var delivered: [Group] = []

    var backdrop: CGImage? = nil

    var info: String? = nil

    var detail: Group? = nil

    var compact = false

    var observe = true

    var partition: Group.Origin? = nil
  }

  private enum Command {
    case cancel(String)
    case status(String)
  }

  static func isStatusQuery(_ prompt: String) -> Bool {
    let words = prompt.lowercased().split(whereSeparator: { $0.isWhitespace })
    if words.count == 1 { return words[0] == "status" }
    guard words.count == 2, words[0] == "status" else { return false }
    return words[1].count == 2 && words[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
  }

  private static func command(in prompt: String) -> Command? {
    let words = prompt.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard words.count == 2 else { return nil }
    switch words[0] {
    case "cancel": return .cancel(words[1])
    case "status": return .status(words[1])
    default: return nil
    }
  }

  private func applyCancel(_ target: String, shown: [Group]) -> String? {
    let all = lock.withLockCompat { groups + tracked }
    let targets: [Group]
    if target == "all" {
      targets = shown
    } else if let group = all.first(where: { $0.code.lowercased() == target }) {
      targets = [group]
    } else {
      return Loc.t("cancel \(target): no request with this ID", "cancel \(target): keine Anfrage mit dieser ID")
    }
    var cancelled = 0
    var codes = [String]()
    for group in targets {
      var own = 0
      for job in group.jobs where job.cancel() { own += 1 }
      if own > 0 {
        group.close()
        cancelled += own
        codes.append(group.code)
      }
    }
    guard cancelled > 0 else {
      return target == "all"
        ? Loc.t("cancel all: nothing is waiting or running", "cancel all: nichts wartet oder läuft")
        : Loc.t("cancel \(target): nothing is waiting or running", "cancel \(target): nichts wartet oder läuft")
    }
    logger.info("CANCEL \(target): \(cancelled) batches of \(codes.joined(separator: ", ")) cancelled")

    return nil
  }

  private func jobSubject(_ group: Group, request: ImageGenerationRequest) -> StatusSubject {
    let first = group.jobs[0]
    var seeds = Set(group.jobs.map { $0.seed })
    seeds.insert(GenerationConfiguration.from(data: request.configuration).seed)
    let size = statusSize(for: first.width, first.height)
    return StatusSubject(
      key: group.id, seeds: seeds, model: first.model, steps: first.totalSteps, width: size.width,
      height: size.height, project: group.origin == nil ? locator?.assignment(of: group.id)?.project : nil,
      compact: request.device == .phone, observe: group.origin == nil, partition: group.origin)
  }

  private func querySubject(
    _ request: ImageGenerationRequest, entry: StatusRegistry.Entry?, origin: Group.Origin? = nil
  ) -> StatusSubject {
    let configuration = GenerationConfiguration.from(data: request.configuration)
    let size = statusSize(for: Int(configuration.startWidth) * 64, Int(configuration.startHeight) * 64)
    return StatusSubject(
      key: UUID(), seeds: [configuration.seed], model: configuration.model ?? "",
      steps: Int(configuration.steps), width: size.width, height: size.height,
      project: origin == nil ? entry.flatMap { locator?.assignment(of: $0.key)?.project } : nil,
      compact: request.device == .phone, observe: origin == nil, partition: origin)
  }

  private func answerStatus(
    entry: StatusRegistry.Entry?, request: ImageGenerationRequest,
    context: StreamingResponseCallContext<ImageGenerationResponse>
  ) -> EventLoopFuture<GRPCStatus> {
    let allGroups = lock.withLockCompat { groups }
    let now = Date()
    let running = allGroups.reduce(0) { $0 + summarize($1, now: now).running }
    let pending = allGroups.reduce(0) { $0 + summarize($1, now: now).pending }
    logger.info(
      "STATUS request (\(entry.map { "status image of \($0.label)" } ?? "no known status image")), \(running) runs running, \(pending) pending, \(allGroups.count) requests known"
    )

    let askedKey = entry?.key

    let askerOrigin = Self.origin(of: request, context: context)
    let asked = askerOrigin == nil ? askedKey.flatMap { locator?.assignment(of: $0) } : nil

    let named = entry?.groups ?? []
    func mayDeliver(_ other: Group) -> Bool {
      if other.shelved { return false }
      if other.id == askedKey || named.contains(other.id) { return true }

      if askerOrigin != nil || other.origin != nil { return false }

      guard let locator = locator else { return true }

      guard locator.canRead else { return false }
      guard let asked = asked, asked.quality == .confirmed,
        let theirs = locator.assignment(of: other.id), theirs.quality == .confirmed
      else { return false }
      return theirs.project == asked.project
    }

    let candidates = allGroups.filter(mayDeliver).flatMap { $0.jobs }.sorted { $0.createdAt < $1.createdAt }
    var delivered = [(job: Job, responses: [ImageGenerationResponse])]()
    var imageCount = 0
    var videoDelivered = false
    for candidate in candidates {
      let waiting = candidate.undeliveredImageCount
      guard waiting > 0 else { continue }
      if maxDeliveryImages > 0, imageCount > 0, imageCount + waiting > maxDeliveryImages {
        break
      }
      // The app builds ONE clip from a stream, so a video goes out alone, one per query.
      let video = candidate.producesVideo
      if video, imageCount > 0 {
        logger.info("\(candidate.code) run \(candidate.runIndex) is a video and waits for the next query (a video is delivered alone)")
        break
      }

      videoDelivered = videoDelivered || video
      let keep = monitor?.isActive == true
      if keep { _ = monitorFinalThumbnail(of: candidate) }

      guard let responses = candidate.takeResultsForDelivery(keepFiles: keep) else { continue }
      if keep { results?.update(candidate) } else { results?.remove(candidate) }
      delivered.append((candidate, responses))
      imageCount += waiting
      if video { break }
    }
    if !delivered.isEmpty { noteResultDelivery(client: askerOrigin?.key ?? "local", at: Date()) }

    if !delivered.isEmpty, monitor?.isActive != true { cleanDelivered() }
    let heldBack = allGroups.filter { !mayDeliver($0) }.reduce(0) { $0 + $1.jobs.filter { $0.undeliveredImageCount > 0 }.count }
    if heldBack > 0 {
      logger.info(
        "\(heldBack) finished runs wait: their project is not confirmed or is another one than the project of this query (\(asked.map { "\($0.project) \($0.quality == .confirmed ? "confirmed" : "guessed")" } ?? "unknown"))"
      )
    }
    var subject = querySubject(request, entry: entry, origin: askerOrigin)
    switch Self.command(in: request.prompt) {
    case .cancel(let target):
      subject.info = applyCancel(
        target, shown: displayScope(askedProject: subject.project, partition: subject.partition).shown)
    case .status(let target):
      if let group = allGroups.first(where: { $0.code.lowercased() == target }) {
        subject.detail = group
      } else {

        logger.info("status \(target): no request with this ID, answering with the overview")
      }
    case nil:
      break
    }
    if !delivered.isEmpty {
      logger.info(
        "Delivering \(imageCount) images (\(delivered.map { "\($0.job.code) run \($0.job.runIndex)" }.joined(separator: ", "))), once, never again; project of the query: \(asked.map { "\($0.project) \($0.quality == .confirmed ? "confirmed" : "guessed")" } ?? "unknown")"
      )
      let sentAt = Date()

      let historyItems = delivered.map { entry -> HistoryFixer.Item in
        let snapshot = entry.job.snapshot()
        var seconds: Double? = nil
        if let started = snapshot.startedAt, let finished = snapshot.finishedAt {
          seconds = finished.timeIntervalSince(started)
        }
        let assignment = locator?.assignment(of: entry.job.group.id)
        return HistoryFixer.Item(
          code: entry.job.code, runIndex: entry.job.runIndex,
          images: Self.completeImagePayloads(of: entry.responses).count, seed: entry.job.seed,
          seconds: seconds, receipt: assignment?.receipt, receiptProject: assignment?.project)
      }

      let filedInto = askerOrigin == nil ? (asked?.project ?? locator?.bestGuess()) : nil
      for entry in delivered {
        for response in entry.responses {
          context.sendResponse(response, promise: nil)
        }
      }

      if let askedKey = askedKey, askerOrigin == nil {
        let own = delivered.filter { $0.job.group.id == askedKey }
        if let first = own.first?.job {
          locator?.observe(
            ProjectLocator.Probe(
              groupId: askedKey, sentAt: Date(), seeds: Set(own.map { $0.job.seed }), model: first.model,
              steps: first.totalSteps))
        }
      }

      var seen = Set<UUID>()
      subject.delivered = delivered.map { $0.job.group }.filter { seen.insert($0.id).inserted }
      subject.backdrop = Self.lastDeliveredImage(delivered.flatMap { $0.responses })

      logger.info(
        "Delivered \(imageCount) \(imageCount == 1 ? "image" : "images") of \(subject.delivered.map { $0.code }.joined(separator: ", ")) to \(asked.map { Self.projectLabel($0.project) } ?? askerOrigin?.label ?? "the open project")"
      )
      var statusSent = false
      if replyMode("closing") == "none" {
        logger.info("MEASURE closing=none: delivery without a status image")
      } else if videoDelivered {
        logger.info("A video was delivered: no closing status image, the app would bake it into the clip as a frame")
      } else {
        statusSent = respondWith(subject: subject, context: context)
      }

      if let fixer = historyFixer, let project = filedInto {
        fixer.expect(items: historyItems, project: project, sentAt: sentAt, closing: statusSent ? 1 : 0)
      }
      return context.eventLoop.makeSucceededFuture(.ok)
    }
    return respondWithStatusImage(subject: subject, context: context)
  }

  static func lastDeliveredImage(_ responses: [ImageGenerationResponse]) -> CGImage? {
    var decoded = [CGImage]()
    for payload in completeImagePayloads(of: responses) {
      if let tensor = Tensor<FloatType>(data: payload, using: [.zip, .fpzip]),
        let image = StatusImage.cgImage(from: tensor)
      {
        decoded.append(image)
      }
    }
    return decoded.last
  }

  static func completeImagePayloads(of responses: [ImageGenerationResponse]) -> [Data] {
    var payloads = [Data]()
    var pending = Data()
    for response in responses where !response.generatedImages.isEmpty {
      switch response.chunkState {
      case .moreChunks:
        if let first = response.generatedImages.first { pending += first }
      case .lastChunk:
        for (index, data) in response.generatedImages.enumerated() {
          payloads.append(index == 0 && !pending.isEmpty ? pending + data : data)
        }
        pending = Data()
      default:
        pending = Data()
      }
    }
    return payloads
  }

  private func respondWithStatusImage(
    subject: StatusSubject, context: StreamingResponseCallContext<ImageGenerationResponse>
  ) -> EventLoopFuture<GRPCStatus> {
    guard respondWith(subject: subject, context: context) else {
      return context.eventLoop.makeFailedFuture(
        GRPCStatus(code: .internalError, message: "Could not render the status image"))
    }
    return context.eventLoop.makeSucceededFuture(.ok)
  }

  @discardableResult
  private func respondWith(
    subject: StatusSubject, context: StreamingResponseCallContext<ImageGenerationResponse>
  ) -> Bool {
    guard let response = makeStatusResponse(subject: subject) else { return false }
    context.sendResponse(response, promise: nil)
    return true
  }

  private func eraseDelivered(keeping entry: StatusRegistry.Entry?) {
    registry.retain(only: entry?.hash)
    let image = entry.map {
      StateStore.Image(hash: $0.hash, key: $0.key, label: $0.label, at: Date(), groups: Array($0.groups))
    }
    let project = entry.flatMap { entry in
      locator?.assignment(of: entry.key).map {
        StateStore.Project(
          key: entry.key, project: $0.project, confirmed: $0.quality == .confirmed, at: Date())
      }
    }
    state?.clear(keeping: image, project: project)
  }

  private func inQueryPartition(_ group: Group, askedName: String?, partition: Group.Origin?, bestGuess: String?) -> Bool {
    if let partition = partition { return group.origin?.key == partition.key }
    if group.origin != nil { return false }
    return locator == nil || askedName == nil || displayProject(of: group, bestGuess: bestGuess) == askedName
  }

  private func displayProject(of group: Group, bestGuess: String?) -> String? {
    locator?.assignment(of: group.id).map { Self.projectLabel($0.project) } ?? bestGuess
  }

  private func displayScope(
    askedProject: String?, partition: Group.Origin? = nil, delivered: [Group] = []
  ) -> (shown: [Group], focus: Group?) {
    let all = lock.withLockCompat { groups }.filter { !$0.shelved }

    let deliveredIDs = Set(delivered.map { $0.id })
    let listed = all.filter { $0.isListed || deliveredIDs.contains($0.id) }
    let bestGuess = locator?.bestGuess().map { Self.projectLabel($0) }
    let askedName = askedProject.map(Self.projectLabel) ?? bestGuess
    func inQueryProject(_ group: Group) -> Bool {
      inQueryPartition(group, askedName: askedName, partition: partition, bestGuess: bestGuess)
    }

    func isBusy(_ group: Group) -> Bool {
      let s = summarize(group, now: Date())
      return s.running > 0 || s.pending > 0
    }
    let mine = listed.filter(inQueryProject)
    var shown = listed
    if shown.isEmpty {
      let recent = all.filter(inQueryProject)
      shown = Array((recent.isEmpty ? all : recent).suffix(5))
    }
    let justDelivered = delivered.first { deliveredIDs.contains($0.id) }
    let focus = focusGroup(of: mine.filter(isBusy)) ?? justDelivered
    return (shown, focus)
  }

  private func focusGroup(of listed: [Group]) -> Group? {
    let now = Date()
    return listed.first { summarize($0, now: now).running > 0 }
      ?? listed.first { summarize($0, now: now).pending > 0 }
      ?? listed.first
  }

  private func previewImage(of group: Group) -> CGImage? {
    guard
      let job = group.jobs.last(where: { $0.snapshot().state.isRunning }),
      let data = job.lastPreview,
      let latent = Tensor<FloatType>(data: data, using: [.zip, .fpzip])
    else { return nil }
    let images = PreviewDecoder.shown(fromLatent: latent, model: job.model, limit: Self.previewsShown)
    guard !images.isEmpty else { return nil }
    return images[job.nextStatusRenderIndex() % images.count]
  }

  // The canvas of an image2image or image2video order; a receipt that came back as canvas is never used.
  private func canvasImage(of group: Group) -> CGImage? {
    guard let data = group.canvasData,
      let tensor = Tensor<FloatType>(data: data, using: [.zip, .fpzip]),
      !StatusImage.hasWatermark(tensor)
    else { return nil }
    return StatusImage.cgImage(from: tensor)
  }

  private func statusSize(for width: Int, _ height: Int) -> (width: Int, height: Int) {
    guard statusWidth > 0 else { return (width, height) }
    let fixedHeight = max(Int((Double(statusWidth) * statusAspect / 64).rounded()), 1) * 64
    return (statusWidth, fixedHeight)
  }

  private func makeStatusResponse(subject: StatusSubject) -> ImageGenerationResponse? {
    let all = lock.withLockCompat { groups }
    let scope = displayScope(askedProject: subject.project, partition: subject.partition, delivered: subject.delivered)
    let focus = subject.detail ?? scope.focus
    var model = statusModel(
      focus: focus, shown: scope.shown, askedProject: subject.project, partition: subject.partition,
      info: subject.info, detail: subject.detail)
    model.compact = subject.compact
    guard
      let tensor = StatusImage.render(
        model: model,

        preview: (subject.detail == nil ? subject.backdrop : nil) ?? focus.flatMap { previewImage(of: $0) }
          ?? focus.flatMap { canvasImage(of: $0) },
        width: subject.width,
        height: subject.height)
    else { return nil }

    all.forEach { group in
      group.jobs.forEach { job in
        if job.markFailureShown() { results?.removeOpen(job.id) }
      }
    }
    let data = tensor.data(using: [.zip, .fpzip])
    let hash = Data(SHA256.hash(data: data))
    var sent: StatusRegistry.Entry? = nil
    if let signature = StatusRegistry.signature(of: tensor) {

      let bestGuess = locator?.bestGuess().map { Self.projectLabel($0) }
      let askedName = subject.project.map(Self.projectLabel) ?? bestGuess
      var named = Set(
        scope.shown.filter {
          inQueryPartition($0, askedName: askedName, partition: subject.partition, bestGuess: bestGuess)
        }.map { $0.id })
      named.insert(subject.key)
      let entry = StatusRegistry.Entry(
        key: subject.key, label: focus?.code ?? "none", hash: hash, signature: signature.values,
        width: signature.width, height: signature.height, groups: named)
      sent = entry
      registry.add(entry)
      state?.record(
        StateStore.Image(
          hash: hash, key: subject.key, label: focus?.code ?? "none", at: Date(),
          groups: Array(named)))
    }

    if !all.contains(where: { $0.isListed }) { eraseDelivered(keeping: sent) }

    if subject.observe {
      locator?.observe(
        ProjectLocator.Probe(
          groupId: subject.key, sentAt: Date(), seeds: subject.seeds, model: subject.model,
          steps: subject.steps))
    }
    logger.info(
      "Status image (focus \(focus?.code ?? "none")): \(subject.width)x\(subject.height), \(data.count) bytes, sha256 \(hex(hash))"
    )
    dump("status-\(focus?.code ?? "none")-\(hex(hash))", tensor: tensor)

    return ImageGenerationResponse.with {
      $0.generatedImages = [data]
      $0.chunkState = .lastChunk
    }
  }

  struct GroupSummary {
    var total: Int
    var done = 0
    var running = 0
    var pending = 0
    var failed = 0
    var cancelled = 0
    var deliveredRuns = 0
    var label = ""
    var runningJob: Job? = nil
    var firstStartedAt: Date? = nil
    var lastFinishedAt: Date? = nil
    var finishedDurations = [TimeInterval]()
    var errorMessage: String? = nil
  }

  private func summarize(_ group: Group, now: Date) -> GroupSummary {
    let jobs = group.jobs
    var summary = GroupSummary(total: max(group.total(now: now, window: burstWindow), jobs.count))
    for job in jobs {
      let snapshot = job.snapshot(now: now)
      if let started = snapshot.startedAt {
        summary.firstStartedAt = min(summary.firstStartedAt ?? started, started)
      }
      switch snapshot.state {
      case .queued: break
      case .running:
        summary.running += 1
        summary.runningJob = job
      case .done:
        summary.done += 1
        if snapshot.delivered { summary.deliveredRuns += 1 }
        if let started = snapshot.startedAt, let finished = snapshot.finishedAt {
          summary.finishedDurations.append(finished.timeIntervalSince(started))
          summary.lastFinishedAt = max(summary.lastFinishedAt ?? finished, finished)
        }
      case .failed(let message):
        summary.failed += 1
        summary.errorMessage = summary.errorMessage ?? message
        if let finished = snapshot.finishedAt {
          summary.lastFinishedAt = max(summary.lastFinishedAt ?? finished, finished)
        }
      case .cancelled:
        summary.cancelled += 1
      }
    }
    summary.pending = max(summary.total - summary.done - summary.running - summary.failed - summary.cancelled, 0)
    if summary.running > 0 {
      summary.label = Loc.t("Running", "Läuft")
    } else if summary.pending > 0 {
      summary.label = Loc.t("Pending", "Wartet")
    } else if summary.failed > 0 {
      summary.label = Loc.t("Failed", "Fehlgeschlagen")
    } else if summary.cancelled > 0 {
      summary.label = Loc.t("Cancelled", "Abgebrochen")
    } else if summary.done > 0, summary.deliveredRuns == summary.done {
      summary.label = Loc.t("Delivered", "Ausgeliefert")
    } else {
      summary.label = Loc.t("Generated", "Generiert")
    }
    return summary
  }

  private func runETAs(now: Date) -> [UUID: TimeInterval] {
    let allGroups = lock.withLockCompat { groups + tracked }
    let jobs = allGroups.flatMap { $0.jobs }.sorted { $0.createdAt < $1.createdAt }
    var perRun = [UUID: TimeInterval]()
    for group in allGroups {
      let summary = summarize(group, now: now)
      if !summary.finishedDurations.isEmpty {
        perRun[group.id] = summary.finishedDurations.reduce(0, +) / Double(summary.finishedDurations.count)
      }
    }
    var etas = [UUID: TimeInterval]()
    var cursor: TimeInterval? = 0
    for job in jobs {
      let snapshot = job.snapshot(now: now)
      switch snapshot.state {
      case .running:
        if let eta = snapshot.etaSeconds, let start = cursor {
          cursor = start + eta
          if perRun[job.group.id] == nil {
            perRun[job.group.id] = now.timeIntervalSince(snapshot.startedAt ?? now) + eta
          }
        } else {
          cursor = nil
        }
        if let cursor = cursor { etas[job.id] = cursor }
      case .queued:
        if let start = cursor, let duration = perRun[job.group.id] {
          cursor = start + duration
          etas[job.id] = start + duration
        } else {
          cursor = nil
        }
      default:
        break
      }
    }
    return etas
  }

  private func statusModel(
    focus: Group?, shown: [Group], askedProject: String?, partition: Group.Origin? = nil, info: String?, detail: Group?
  ) -> StatusModel {
    let now = Date()
    let etas = runETAs(now: now)

    let unknownProject = Loc.t("Project unknown", "Projekt unbekannt")
    let bestGuess = locator?.bestGuess().map { Self.projectLabel($0) }
    let queryProject = partition?.label ?? askedProject.map(Self.projectLabel) ?? bestGuess ?? unknownProject
    func projectName(of other: Group) -> String {

      if let origin = other.origin { return origin.label }
      return locator?.assignment(of: other.id).map { Self.projectLabel($0.project) } ?? bestGuess ?? unknownProject
    }
    func block(for other: Group) -> StatusModel.GroupBlock {
      let s = summarize(other, now: now)
      let otherJobs = other.jobs
      var batches = [StatusModel.Batch]()
      for index in 0..<max(s.total, otherJobs.count) {
        guard index < otherJobs.count else {
          batches.append(StatusModel.Batch(state: .pending, step: nil, eta: nil))
          continue
        }
        let job = otherJobs[index]
        let snapshot = job.snapshot(now: now)
        let eta = etas[job.id]
        switch snapshot.state {
        case .queued: batches.append(.init(state: .pending, step: nil, eta: eta))
        case .running:
          let phase: StatusModel.Phase
          switch snapshot.stage {
          case .processing: phase = .processing
          case .sampling: phase = .sampling
          case .finishing: phase = .finishing
          }
          batches.append(
            .init(
              state: .running, step: snapshot.step, eta: eta, phase: phase, totalSteps: snapshot.totalSteps,
              secondPass: snapshot.secondPass))
        case .done: batches.append(.init(state: snapshot.delivered ? .delivered : .done, step: nil, eta: nil))
        case .failed: batches.append(.init(state: .failed, step: nil, eta: nil))
        case .cancelled: batches.append(.init(state: .cancelled, step: nil, eta: nil))
        }
      }
      return StatusModel.GroupBlock(
        code: other.code, batchSize: otherJobs[0].batchSize, steps: otherJobs[0].totalSteps,
        isCurrent: other.id == focus?.id, batches: batches, project: projectName(of: other))
    }

    var byProject = [String: [StatusModel.GroupBlock]]()
    for other in shown { byProject[projectName(of: other), default: []].append(block(for: other)) }
    let otherNames = byProject.keys.filter { $0 != queryProject }.sorted()
    let tables = ([queryProject] + otherNames).map {
      StatusModel.Table(project: $0, groups: byProject[$0] ?? [])
    }

    let accessNote: String? =
      locator.flatMap { $0.canRead ? nil : Loc.t("No access to the Draw Things projects: only the request whose status image was used gets its results.", "Kein Zugriff auf die Draw-Things-Projekte: Um die Ergebnisse zu erhalten, muss das Statusbild der entsprechenden Anfrage verwendet werden.") }

    guard let group = focus else {
      return StatusModel(
        info: info, note: accessNote, tables: tables, progress: 1, barLabel: Loc.t("No running jobs", "Keine laufenden Jobs"),
        barTime: "")
    }
    let summary = summarize(group, now: now)
    let total = summary.total
    let running = summary.runningJob?.snapshot(now: now)

    var fraction = Double(summary.done) / Double(max(total, 1))
    if let running = running, let step = running.step, running.totalSteps > 0 {
      fraction += min(Double(step) / Double(running.totalSteps), 1) / Double(max(total, 1))
    }
    let unfinished = summary.running + summary.pending > 0

    let groupElapsed = now.timeIntervalSince(summary.firstStartedAt ?? group.createdAt)
    var barLabel: String
    if summary.running > 0 {

      switch running?.stage {
      case .finishing:
        barLabel = Loc.t("Finishing…", "Abschluss…")
      case .sampling where (running?.step ?? 0) >= 1 && (running?.totalSteps ?? 0) > 0:
        barLabel = (running?.secondPass == true ? Loc.secondPass : "") + "Sampling… \(running?.step ?? 0) / \(running?.totalSteps ?? 0)"
      default:
        barLabel = Loc.t("Processing…", "Verarbeitung…")
      }
      if total > 1 { barLabel = "Batch \(summary.done + 1)/\(total) \u{00B7} " + barLabel }
    } else {
      barLabel = summary.label
    }
    let barTime: String
    if summary.running > 0 {
      var estimate = "--:--"
      if let last = group.jobs.compactMap({ etas[$0.id] }).max() {
        estimate = Self.clock(groupElapsed + last)
      }
      barTime = "\(Self.clock(groupElapsed)) / \(estimate) \(Loc.t("est.", "geschätzt"))"
    } else if summary.pending > 0 {
      barTime = Self.clock(now.timeIntervalSince(group.createdAt))
    } else {
      let end = summary.lastFinishedAt ?? now
      barTime = Self.clock(end.timeIntervalSince(summary.firstStartedAt ?? group.createdAt))
    }

    var note: String? = accessNote
    if summary.failed > 0, !unfinished {
      note = Loc.t("Failed: ", "Fehlgeschlagen: ") + (summary.errorMessage ?? Loc.t("the server could not make the images", "der Server konnte die Bilder nicht erzeugen"))
    }
    return StatusModel(
      info: info, detail: detail.map { detailModel($0, now: now, etas: etas) }, note: note,
      tables: tables, progress: unfinished ? fraction : 1, barLabel: barLabel, barTime: barTime)
  }

  private func detailModel(_ group: Group, now: Date, etas: [UUID: TimeInterval]) -> StatusModel.Detail {
    let first = group.jobs[0]
    let summary = summarize(group, now: now)
    var fields = [(label: String, value: String)]()
    fields.append(("Prompt", first.prompt))
    fields.append((Loc.t("Size", "Größe"), "\(first.width)\u{00D7}\(first.height)"))
    fields.append((Loc.t("Model", "Modell"), first.model))
    if let mode = first.mode { fields.append((Loc.t("Mode", "Modus"), mode)) }
    fields.append((Loc.t("Steps", "Schritte"), "\(first.totalSteps)"))
    fields.append((Loc.t("Batch Size", "Batchgröße"), "\(first.batchSize)"))
    var counts = [String]()
    let generated = summary.done - summary.deliveredRuns
    if generated > 0 { counts.append("\(generated) \(Loc.t("generated", "generiert"))") }
    if summary.deliveredRuns > 0 { counts.append("\(summary.deliveredRuns) \(Loc.t("delivered", "ausgeliefert"))") }
    if summary.running > 0 { counts.append("\(summary.running) \(Loc.t("running", "laufend"))") }
    if summary.pending > 0 { counts.append("\(summary.pending) \(Loc.t("pending", "wartend"))") }
    if summary.failed > 0 { counts.append("\(summary.failed) \(Loc.t("failed", "fehlgeschlagen"))") }
    if summary.cancelled > 0 { counts.append("\(summary.cancelled) \(Loc.t("cancelled", "abgebrochen"))") }
    fields.append(("Batches", "\(summary.total) (\(counts.joined(separator: ", ")))"))
    fields.append(("Seed", "\(first.seed)"))
    let unfinished = summary.running + summary.pending > 0
    let start = summary.firstStartedAt ?? group.createdAt
    if unfinished {
      fields.append((Loc.t("Elapsed", "Verstrichen"), Self.clock(now.timeIntervalSince(start))))
      if let last = group.jobs.compactMap({ etas[$0.id] }).max() {
        fields.append(("ETA", Self.clock(last)))
      }
    } else if let end = summary.lastFinishedAt {
      fields.append((Loc.t("Render time", "Renderzeit"), String(format: "%.1fs", end.timeIntervalSince(start))))
    }
    if group.source != nil {

      if let workdir = group.sourceWorkdir { fields.append((Loc.t("Project", "Projekt"), workdir)) }
    } else if group.origin == nil {
      let bestGuess = locator?.bestGuess().map { Self.projectLabel($0) }
      if let project = displayProject(of: group, bestGuess: bestGuess) {
        fields.append((Loc.t("Project", "Projekt"), project))
      }
    }
    return StatusModel.Detail(code: group.code, fields: fields)
  }

  private static func projectLabel(_ file: String) -> String {
    file.hasSuffix(".sqlite3") ? String(file.dropLast(".sqlite3".count)) : file
  }

  private static func clock(_ seconds: TimeInterval) -> String {
    let total = max(Int(seconds.rounded()), 0)
    if total >= 3600 {
      return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%02d:%02d", total / 60, total % 60)
  }

  private static func duration(_ seconds: TimeInterval) -> String {
    let total = max(Int(seconds.rounded()), 0)
    if total < 60 { return "\(total) s" }
    return "\(total / 60) min \(total % 60) s"
  }

  private static let matchThreshold = 0.03

  struct RequestSummary {
    var fields: [String: String]

    init(_ request: ImageGenerationRequest) {
      let configuration = GenerationConfiguration.from(data: request.configuration)
      var configFields = [String: String]()
      if let data = jsonRepresentation(configuration: configuration).data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
      {
        configFields = object
      }
      var f = [String: String]()
      f["prompt"] = request.prompt
      f["negativePrompt"] = request.negativePrompt
      f["user"] = request.user
      f["device"] = "\(request.device)"
      f["keywords"] = request.keywords.joined(separator: ",")
      f["scaleFactor"] = "\(request.scaleFactor)"
      f["chunked"] = "\(request.chunked)"
      f["override"] = "\(Data(SHA256.hash(data: ((try? request.override.serializedData()) ?? Data()))).prefix(4).map { String(format: "%02x", $0) }.joined())"
      f["hints"] = request.hints.map { hint in
        "\(hint.hintType)[" + hint.tensors.map { "\(hex($0.tensor).prefix(8))@\($0.weight)" }.joined(separator: ",") + "]"
      }.joined(separator: ";")
      f["image"] = request.hasImage ? hex(request.image) : "-"
      f["mask"] = request.hasMask ? hex(request.mask) : "-"
      f["contents"] = "\(request.contents.count)"
      f["configuration"] = "\(Data(SHA256.hash(data: request.configuration)).prefix(4).map { String(format: "%02x", $0) }.joined())"
      f["seed"] = configFields["seed"] ?? "?"
      f["configName"] = configuration.name
      for (key, value) in configFields where key != "seed" {
        f["config." + key] = value
      }
      fields = f
    }

    func differences(from other: RequestSummary) -> [String] {
      Set(fields.keys).union(other.fields.keys).sorted().compactMap { key in
        guard fields[key] != other.fields[key] else { return nil }
        return "\(key): \(other.fields[key] ?? "-") -> \(fields[key] ?? "-")"
      }
    }
  }

  private func logMeasurement(number: Int, summary: RequestSummary, received: Date) {
    let (gapStart, gapClose, previous) = lock.withLockCompat { () -> (TimeInterval?, TimeInterval?, RequestSummary?) in
      let gapStart = lastRequestAt.map { received.timeIntervalSince($0) }
      let gapClose = lastClosedAt.map { received.timeIntervalSince($0) }
      lastRequestAt = received
      let previous = previousSummary
      previousSummary = summary
      return (gapStart, gapClose, previous)
    }
    func seconds(_ value: TimeInterval?) -> String {
      value.map { String(format: "%.2f s", $0) } ?? "-"
    }
    let f = summary.fields
    let user = f["user"] ?? "?"
    let device = f["device"] ?? "?"
    let configName = f["configName"] ?? ""
    let keywords = f["keywords"] ?? ""
    logger.info(
      "REQ \(number) received. since previous request start: \(seconds(gapStart)), since previous stream closed: \(seconds(gapClose)). batchSize=\(f["config.batchSize"] ?? "?") batchCount=\(f["config.batchCount"] ?? "?") seed=\(f["seed"] ?? "?") steps=\(f["config.steps"] ?? "?") strength=\(f["config.strength"] ?? "?") image=\(f["image"] ?? "-") mask=\(f["mask"] ?? "-") contents=\(f["contents"] ?? "?") model=\(f["config.model"] ?? "?") user=[\(user)] device=\(device) configName=[\(configName)] keywords=[\(keywords)]"
    )
    if let previous = previous {
      let differences = summary.differences(from: previous)
      logger.info(
        "REQ \(number) differs from the previous request in: \(differences.isEmpty ? "nothing" : differences.joined(separator: "; "))"
      )
    }
  }

  private func dump(_ name: String, tensor: Tensor<FloatType>) {
    guard let directory = dumpDirectory, let png = StatusImage.pngData(from: tensor) else { return }
    try? FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    let stamp = String(format: "%.0f", Date().timeIntervalSince1970)
    try? png.write(to: URL(fileURLWithPath: "\(directory)/\(stamp)-\(name).png"))
  }

  private func recognise(_ request: ImageGenerationRequest) -> (entry: StatusRegistry.Entry?, isStatus: Bool, reason: String) {
    let configuration = GenerationConfiguration.from(data: request.configuration)
    var contentSizes = [String]()
    var imageTensor: Tensor<FloatType>? = nil
    for content in request.contents {
      let hash = Data(SHA256.hash(data: content))
      let isImage = request.hasImage && hash == request.image
      contentSizes.append("\(content.count)B\(isImage ? " (image)" : "")")
      if isImage {
        imageTensor = Tensor<FloatType>(data: content, using: [.zip, .fpzip])
      }
    }
    logger.info(
      "GenerateImage: model=\(configuration.model ?? "-") size=\(Int(configuration.startWidth) * 64)x\(Int(configuration.startHeight) * 64) steps=\(configuration.steps) strength=\(configuration.strength) seed=\(configuration.seed) batchSize=\(configuration.batchSize) batchCount=\(configuration.batchCount) hasImage=\(request.hasImage) imageHash=\(request.hasImage ? hex(request.image) : "-") hasMask=\(request.hasMask) hints=\(request.hints.count) contents=[\(contentSizes.joined(separator: ", "))] chunked=\(request.chunked) prompt=\"\(request.prompt.prefix(60))\""
    )

    for content in request.contents {
      if let entry = registry.entry(forHash: Data(SHA256.hash(data: content))) {
        return (entry, true, "the request carries the status image of \(entry.label)")
      }
    }
    guard request.hasImage else { return (nil, false, "the request has no canvas image") }
    if let tensor = imageTensor { dump("canvas-\(hex(request.image))", tensor: tensor) }
    if request.hasMask {
      for content in request.contents {
        let hash = Data(SHA256.hash(data: content))
        if hash == request.mask {
          let mask = Tensor<UInt8>(data: content, using: [.zip, .fpzip])
          let values = mask.map { tensor -> String in
            var histogram = [UInt8: Int]()
            tensor.withUnsafeBytes { raw in
              for byte in raw { histogram[byte, default: 0] += 1 }
            }
            let top = histogram.sorted { $0.value > $1.value }.prefix(4)
              .map { "\($0.key):\($0.value)" }.joined(separator: " ")
            return "shape \(tensor.shape), most frequent values \(top)"
          }
          logger.info("Mask: \(values ?? "could not be decoded")")
        }
      }
    }
    if let entry = registry.entry(forHash: request.image) {
      logger.info(
        "Canvas image hash \(hex(request.image)) is identical to the status image of \(entry.label)")
      return (entry, true, "exact hash match with a status image of \(entry.label)")
    }
    logger.info(
      "Canvas image hash \(hex(request.image)) is not in the registry of \(registry.all.count) status images"
    )
    guard let tensor = imageTensor else {
      logger.info("Canvas image was sent as a hash only, the pixels are not in the request")
      return (nil, false, "the canvas image came as a hash only and the hash is unknown (\(registry.all.count) status images known)")
    }
    logger.info("Canvas image tensor shape: \(tensor.shape)")
    let watermarked = StatusImage.hasWatermark(tensor)
    logger.info("Watermark of a status image in the canvas image: \(watermarked)")

    var best: (entry: StatusRegistry.Entry, difference: Double)? = nil
    if let signature = StatusRegistry.signature(of: tensor) {
      for entry in registry.all where entry.width == signature.width && entry.height == signature.height {
        var sum: Float = 0
        for i in 0..<signature.values.count {
          sum += abs(entry.signature[i] - signature.values[i])
        }
        let difference = Double(sum) / Double(signature.values.count)
        if best == nil || difference < best!.difference {
          best = (entry, difference)
        }
      }
    }
    if let best = best {
      logger.info("Closest status image: \(best.entry.label), mean abs diff \(best.difference)")
      if best.difference < Self.matchThreshold {
        return (best.entry, true, "pixel match with \(best.entry.label), mean abs diff \(best.difference)\(watermarked ? ", watermark found" : "")")
      }
    }
    if watermarked {
      return (nil, true, "watermark of a status image, the picture itself is not in the registry")
    }
    return (nil, false, "no watermark, and the pixels are not those of a known status image")
  }
}

extension NSLock {
  fileprivate func withLockCompat<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}

extension ProxyService {

  func attachMonitor(_ hub: MonitorHub) {
    monitor = hub
    hub.snapshotProvider = { [weak self] in self?.monitorSnapshot() ?? [:] }
    hub.onCommand = { [weak self] command in self?.monitorCommand(command) }

    hub.onChange = { [weak self] _ in self?.cleanDelivered() }
  }

  func cleanDelivered() {
    let jobs = lock.withLockCompat { groups + tracked }.flatMap { $0.jobs }.filter { job in
      guard case .done = job.snapshot().state else { return false }
      return job.snapshot().delivered
    }
    monitorRemove(jobs)
    monitor?.pushNow()
  }

  private func monitorCommand(_ command: [String: Any]) {
    switch command["cmd"] as? String {
    case "cancel":
      guard let code = (command["code"] as? String)?.lowercased() else { return }
      let all = lock.withLockCompat { groups + tracked }
      monitorLog("MONITOR cancel \(code): \(applyCancel(code, shown: all) ?? "nothing")")
    case "cancelAll":
      let all = lock.withLockCompat { groups + tracked }
      monitorLog("MONITOR cancel all: \(applyCancel("all", shown: all) ?? "nothing")")
    case "preview":
      monitorPreview(command)
      return
    case "save":
      monitorSave(command)
      return
    case "remove":
      guard let job = monitorJob(command) else { return }
      monitorRemove([job])
    default:
      return
    }
    monitor?.pushNow()
  }

  private func inProject(_ group: Group, _ project: String?) -> Bool {
    guard let project = project else { return false }
    return locator?.assignment(of: group.id)?.project == project
  }

  private func inQueue(_ group: Group) -> Bool {
    if summarize(group, now: Date()).pending > 0 { return true }
    return group.jobs.contains {
      switch $0.snapshot().state {
      case .queued, .running: return true
      case .done: return $0.undeliveredImageCount > 0
      default: return false
      }
    }
  }

  private func isRemovable(_ job: Job) -> Bool {
    switch job.snapshot().state {
    case .queued, .running: return false
    case .failed, .cancelled, .done: return true
    }
  }

  private func monitorRemove(_ jobs: [Job]) {
    var removed = [Job]()
    lock.withLockCompat {
      for job in jobs where isRemovable(job) && !monitorHiddenJobs.contains(job.id) {
        monitorHiddenJobs.insert(job.id)
        removed.append(job)
      }
      let tools = Set(removed.filter { $0.group.source != nil }.map { $0.id })
      if !tools.isEmpty {
        tracked.removeAll { $0.jobs.allSatisfy { tools.contains($0.id) || monitorHiddenJobs.contains($0.id) } }
      }
      for job in removed {
        monitorThumbs[job.id] = nil
        monitorPreviewSets[job.id] = nil
      }
    }
    for job in removed {
      if job.group.source != nil {
        job.payload.evict()
        results?.erase(job.id)
      } else {

        job.discardUndelivered()
        job.payload.evict()
        results?.erase(job.id)
      }
    }
    if !removed.isEmpty { monitorLog("MONITOR removed \(removed.count) \(removed.count == 1 ? "row" : "rows"): \(Set(removed.map { $0.code }).sorted().joined(separator: ", "))") }
  }

  private func keepWithinLimits() {
    guard let results = results else { return }
    let expired = Set(results.prune())
    let freed = Set(results.enforceBudget())
    guard !expired.isEmpty || !freed.isEmpty else { return }
    lock.withLockCompat {
      for job in (groups + tracked).flatMap({ $0.jobs }) {
        if freed.contains(job.id) || expired.contains(job.id) { job.payload.evict() }
      }
      if !expired.isEmpty {
        tracked.removeAll { $0.jobs.allSatisfy { expired.contains($0.id) } }
        for id in expired {
          monitorThumbs[id] = nil
          monitorPreviewSets[id] = nil
        }
      }
    }
    monitor?.pushNow()
  }

  private func monitorLog(_ text: String) {
    logger.info("\(text)")
    FileLog.shared.append(text)
  }

  private func monitorRequest(
    number: Int, request: ImageGenerationRequest, received: Date, pickupOnly: Bool = false,
    receipt: StatusRegistry.Entry? = nil, canvasFromApp: Bool = false,
    context: StreamingResponseCallContext<ImageGenerationResponse>
  ) -> EventLoopFuture<GRPCStatus> {
    let open = locator?.openProjectNames()
    let project = locator?.activeProject()
    let (key, expected) = Self.monitorGroupKey(of: request)
    let overview = lock.withLockCompat { groups }.map { group -> String in
      let name = locator?.assignment(of: group.id)?.project ?? "unknown"
      let runs = group.jobs.sorted { $0.runIndex < $1.runIndex }.map { job -> String in
        let snapshot = job.snapshot()
        switch snapshot.state {
        case .queued: return "queued"
        case .running: return "running"
        case .done: return snapshot.delivered ? "delivered" : "finished(\(job.undeliveredImageCount) images)"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
      }
      return "\(group.code)[\(name), \(inQueue(group) ? "in queue" : "over"), order \(Self.shortHash(group.key)), runs \(runs.joined(separator: "/"))]"
    }.joined(separator: " ")
    let decision =
      "MONITOR \(number): open in Draw Things \(open.map { "\($0)" } ?? "unknown"), project taken as \(project ?? "unknown"); this order \(Self.shortHash(key)), canvas pixels \(request.contents.isEmpty ? "no" : "yes"), inputs [\(Self.inputsSummary(of: request))], results delivered since the previous request \(canvasFromApp ? "yes" : "no"), image \(request.hasImage ? hex(request.image) : "-"); requests: \(overview.isEmpty ? "none" : overview)"
    logger.info("\(decision)")
    FileLog.shared.append(decision)

    let receiptGroup = receipt.flatMap { entry in lock.withLockCompat { groups }.first { $0.id == entry.key } }
    if locator != nil, project == nil, receiptGroup == nil {
      monitorLog("MONITOR \(number): the project is not known, nothing started and nothing delivered")
      var subject = querySubject(request, entry: nil)
      subject.info = Loc.t("Project unknown: nothing was started.", "Projekt unbekannt: Es wurde nichts gestartet.")
      return respondWithStatusImage(subject: subject, context: context)
    }
    var anotherCanvas: Group? = nil
    let (followUp, sameOrder, restOfPickup): (Bool, Group?, Bool) = lock.withLockCompat {
      if pickupOnly { return (false, nil, false) }
      if let pickup = monitorPickup, pickup.key == key, pickup.remaining > 0,
        received.timeIntervalSince(pickup.at) < burstWindow
      {
        monitorPickup = (key, pickup.remaining - 1, received)
        return (false, nil, true)
      }
      if groups.contains(where: { $0.canTake(key: key, at: received, window: burstWindow) }) {
        return (true, nil, false)
      }
      let candidates = groups.filter { $0.key == key && inProject($0, project) && inQueue($0) }
      let same = candidates.first { !Self.orderChanged(of: $0, in: request, byApp: canvasFromApp) }
      if same == nil { anotherCanvas = candidates.first }
      if same != nil { monitorPickup = (key, expected - 1, received) }
      return (false, same, false)
    }
    var newGroup: Group? = nil
    if pickupOnly {
      monitorLog("MONITOR \(number): \(receipt != nil ? "a receipt" : "the prompt `status` or an unknown status image") is presented\(receiptGroup.map { " (order \($0.code))" } ?? ""): a pickup, nothing started")
    } else if restOfPickup {
      monitorLog("MONITOR \(number): a further request of the pickup that was just made, nothing started")
    } else if let same = sameOrder {
      monitorLog("MONITOR \(number): the same order as \(same.code) in \(project.map { Self.projectLabel($0) } ?? "the open project"), nothing started")
    } else {
      if let other = anotherCanvas {
        monitorLog("MONITOR \(number): the same data as \(other.code), but other images (canvas, mask or hints) and nothing was delivered since the last request: a new order")
      }
      let (job, isNew) = startJob(request, at: received, project: project, monitorMode: true)
      monitorLog("MONITOR \(number): \(followUp ? "run \(job.runIndex) of" : "order") \(job.code) started in \(project.map { Self.projectLabel($0) } ?? "an unknown project")")

      if isNew {
        newGroup = job.group
        monitor?.broadcast(["type": "event", "kind": "accepted", "code": job.code, "sound": !issueReceipts || expected > 1])
      }
    }

    let candidates = lock.withLockCompat { groups }
      .filter { inProject($0, project) || $0.id == receiptGroup?.id }.flatMap { $0.jobs }.sorted { $0.createdAt < $1.createdAt }
    var delivered = [(job: Job, responses: [ImageGenerationResponse])]()
    var imageCount = 0
    let receiptDue = issueReceipts && newGroup != nil
    for candidate in candidates {
      let waiting = candidate.undeliveredImageCount
      guard waiting > 0 else { continue }
      if maxDeliveryImages > 0, imageCount > 0, imageCount + waiting > maxDeliveryImages { break }
      // The app builds ONE clip from a stream, so a video goes out alone, one per query, and without a receipt after it.
      let video = candidate.producesVideo
      if video, receiptDue {
        monitorLog("MONITOR \(number): \(candidate.code) run \(candidate.runIndex) is a video and waits: this response carries the receipt of the new order, and the app would bake it into the clip")
        break
      }
      if video, imageCount > 0 {
        monitorLog("MONITOR \(number): \(candidate.code) run \(candidate.runIndex) is a video and waits for the next query (a video is delivered alone)")
        break
      }

      _ = monitorFinalThumbnail(of: candidate)
      guard let responses = candidate.takeResultsForDelivery(keepFiles: true) else { continue }
      results?.update(candidate)
      delivered.append((candidate, responses))
      imageCount += waiting
      if video { break }
    }
    let held = lock.withLockCompat { groups }.filter { !inProject($0, project) }
      .flatMap { $0.jobs }.filter { $0.undeliveredImageCount > 0 }
    if !held.isEmpty {
      monitorLog("MONITOR \(number): \(held.count) finished runs wait for their own project: \(Set(held.map { $0.code }).sorted().joined(separator: ", "))")
    }
    var fixerItems = [HistoryFixer.Item]()
    let sentAt = Date()
    let codes = Array(Set(delivered.map { $0.job.code })).sorted()
    if !delivered.isEmpty {
      noteResultDelivery(client: "local", at: Date())
      monitorLog("MONITOR \(number): delivering \(imageCount) \(imageCount == 1 ? "image" : "images") of \(codes.joined(separator: ", ")); history nodes \(historyFixer != nil ? "are rebuilt from the requests of the jobs" : "are left as the app makes them (Fix History is off)")")

      fixerItems = delivered.map { entry -> HistoryFixer.Item in
        let snapshot = entry.job.snapshot()
        var seconds: Double? = nil
        if let started = snapshot.startedAt, let finished = snapshot.finishedAt {
          seconds = finished.timeIntervalSince(started)
        }
        var item = HistoryFixer.Item(
          code: entry.job.code, runIndex: entry.job.runIndex,
          images: Self.completeImagePayloads(of: entry.responses).count, seed: entry.job.seed,
          seconds: seconds, receipt: nil, receiptProject: nil)
        if let configuration = entry.job.requestConfiguration {
          item.request = HistoryFixer.RequestData(
            configuration: configuration, prompt: entry.job.prompt, negativePrompt: entry.job.negativePrompt ?? "")
        }
        return item
      }
      for entry in delivered {
        for response in entry.responses { context.sendResponse(response, promise: nil) }
      }
      monitor?.broadcast(["type": "event", "kind": "delivered", "codes": codes])
    }

    var receiptSent = false
    if issueReceipts, let group = newGroup, !group.jobs.isEmpty {
      var subject = jobSubject(group, request: request)
      subject.observe = false
      receiptSent = respondWith(subject: subject, context: context)
      monitorLog("MONITOR \(number): receipt of \(group.code) \(receiptSent ? "sent" : "could not be made")")
    }
    if let fixer = historyFixer, let project = project, !fixerItems.isEmpty || receiptSent {
      let groupID = newGroup?.id
      fixer.expect(
        items: fixerItems, project: project, sentAt: sentAt, closing: receiptSent ? 1 : 0,
        onClosing: receiptSent
          ? { [weak self] node, table in
            guard let self = self, let id = groupID else { return }

            let first = self.lock.withLockCompat { self.groups }.first { $0.id == id }?.jobs.first
            var matches = false
            if let job = first,
              case .bytes(let model)? = table[HistoryCorrector.slot("model")],
              case .scalar(let steps, _)? = table[HistoryCorrector.slot("steps")],
              case .scalar(let seed, _)? = table[HistoryCorrector.slot("seed")]
            {
              matches = String(decoding: model, as: UTF8.self) == job.model && Int(steps) == job.totalSteps && UInt32(truncatingIfNeeded: seed) == job.seed
            }
            guard matches else {
              self.monitorLog("RECEIPT of \(id.uuidString.prefix(8)): the node \(node.lineage)/\(node.logicalTime) is not what the app files for this request, it is left alone")
              return
            }
            self.locator?.confirmReceipt(project: project, node: node, for: id)
            self.monitorLog("RECEIPT of \(id.uuidString.prefix(8)) is the node \(node.lineage)/\(node.logicalTime) of \(project)")
          } : nil)
    }
    sweepReceipts(project: project)
    monitor?.pushNow()
    return context.eventLoop.makeSucceededFuture(.ok)
  }

  private func monitorSnapshot() -> [String: Any] {
    let now = Date()
    let etas = runETAs(now: now)
    let all = lock.withLockCompat { groups + tracked }.sorted { $0.createdAt < $1.createdAt }
    let hidden = lock.withLockCompat { monitorHiddenJobs }
    let open = locator?.activeProject()
    func left(_ seconds: TimeInterval) -> String {
      let total = max(Int(seconds.rounded(.up)), 1)
      return Loc.left(total)
    }
    var rows = [[String: Any]]()
    for group in all where !group.jobs.isEmpty {

      let project = locator?.assignment(of: group.id)?.project
      let s = summarize(group, now: now)
      let detail = monitorDetail(group, now: now, etas: etas)
      let jobs = group.jobs.sorted { $0.runIndex < $1.runIndex }
      let lastRun = jobs.last?.runIndex ?? 0
      let total = max(s.total, lastRun)
      var first = true
      func add(_ state: String, _ line1: String, _ parts: [String], _ thumb: String?, job: Job? = nil, removable: Bool = false) {
        var row: [String: Any] = [
          "code": group.code, "first": first, "state": state, "line1": line1,

          "open": group.source == nil && project != nil && project == open,
          "tool": group.source != nil,
          "app": group.sourceIsApp,
          "cancellable": state == "running" || state == "pending",
          "detail": detail,

          "project": group.source ?? project.map { Self.projectLabel($0) } ?? group.origin?.label ?? "unknown",
        ]
        if !parts.isEmpty { row["line2"] = parts.joined(separator: " \u{00B7} ") }
        if let thumb = thumb { row["thumb"] = thumb }
        if let job = job {
          row["run"] = job.runIndex

          if state == "generated" || state == "delivered" {
            let payload = job.payload
            if payload.isPresent, payload.completeImages > 0 {
              row["saveable"] = true
              row["filename"] = Self.saveName(of: job)
              row["video"] = MediaSaver.isVideo(
                completeImages: payload.completeImages, hasAudio: payload.hasAudio,
                configuration: job.requestConfiguration, model: job.model)
            }
          }
          if removable { row["removable"] = true }
        }
        rows.append(row)
        first = false
      }
      for job in jobs where !hidden.contains(job.id) {
        var parts = [String]()
        if total > 1 { parts.append("Batch \(job.runIndex)/\(total)") }
        let snapshot = job.snapshot(now: now)
        let removable = isRemovable(job)
        switch snapshot.state {
        case .queued:
          if let eta = etas[job.id] { parts.append(left(eta)) }
          add("pending", Loc.t("Pending", "Wartet"), parts, nil)
        case .running:
          var line = Loc.t("Processing...", "Verarbeitung…")
          switch snapshot.stage {
          case .finishing: line = Loc.t("Finishing...", "Abschluss…")
          case .sampling where (snapshot.step ?? 0) >= 1 && snapshot.totalSteps > 0:
            let step = snapshot.step ?? 0
            line =
              (snapshot.secondPass ? Loc.secondPass : "")
              + Loc.stepLine(step, snapshot.totalSteps, Int((Double(step) / Double(snapshot.totalSteps + 1) * 100).rounded()))
          default: break
          }
          if let eta = etas[job.id] { parts.append(left(eta)) }
          add("running", line, parts, monitorPreviewThumbnail(of: job), job: job)
        case .done:
          if snapshot.delivered {
            add("delivered", Loc.t("Delivered", "Ausgeliefert"), parts, monitorFinalThumbnail(of: job), job: job, removable: removable)
          } else if job.undeliveredImageCount > 0 {
            add("generated", Loc.t("Generated", "Generiert"), parts, monitorFinalThumbnail(of: job), job: job, removable: removable)
          }
        case .failed(let message):
          add("failed", Loc.t("Failed", "Fehlgeschlagen"), parts + [message], nil, job: job, removable: removable)
        case .cancelled:
          add("cancelled", Loc.t("Cancelled", "Abgebrochen"), parts, nil, job: job, removable: removable)
        }
      }

      if s.total > lastRun {
        for index in (lastRun + 1)...s.total {
          add("pending", Loc.t("Pending", "Wartet"), ["Batch \(index)/\(total)"], nil)
        }
      }
    }
    var snapshot: [String: Any] = ["jobs": rows]
    if let open = open { snapshot["project"] = Self.projectLabel(open) }
    return snapshot
  }

  private func monitorDetail(_ group: Group, now: Date, etas: [UUID: TimeInterval]) -> String {
    var lines = ["Request-ID: \(group.code)"]
    if let origin = group.origin {
      lines.append("\(Loc.t("From", "Von")): \(origin.label)")
      lines.append("\(Loc.t("Device", "Gerät")): \(origin.device)")
      if let address = origin.address { lines.append("\(Loc.t("Address", "Adresse")): \(address)") }
    }
    if let source = group.source {
      lines.append("\(Loc.t("Tool", "Werkzeug")): \(source)")
      if let client = group.sourceClient { lines.append("\(Loc.t("Called by", "Aufgerufen von")): \(client)") }
      if let id = group.sourceRequestId { lines.append("\(Loc.t("Request of the caller", "Anfrage des Aufrufers")): \(id)") }
      if !group.sourceIsApp {
        lines.append("\(Loc.t("Background call", "Hintergrundaufruf")): \(group.sourceBackground ? Loc.t("yes", "ja") : Loc.t("no", "nein"))")
      }
    }
    lines += detailModel(group, now: now, etas: etas).fields
      .map { "\($0.label): \($0.label == "Prompt" ? String($0.value.prefix(400)) : $0.value)" }
    return lines.joined(separator: "\n")
  }

  static let previewsShown = 4

  private func monitorPreviewThumbnail(of job: Job) -> String? {
    guard let data = job.lastPreview else { return nil }
    Self.dumpLatentIfAsked(data, model: job.model)
    let key = data.hashValue
    var pngs = lock.withLockCompat { monitorPreviewSets[job.id] }.flatMap { $0.key == key ? $0.pngs : nil }
    if pngs == nil {
      guard let latent = Tensor<FloatType>(data: data, using: [.zip, .fpzip]) else { return nil }
      let images = PreviewDecoder.shown(fromLatent: latent, model: job.model, limit: Self.previewsShown)
      pngs = images.compactMap { Self.thumbnailPNG($0) }
      lock.withLockCompat { monitorPreviewSets[job.id] = (key, pngs ?? []) }
    }
    guard let list = pngs, !list.isEmpty else { return nil }
    return list[Self.turn(of: list.count)]
  }

  private static var lastDump = Date.distantPast
  static func dumpLatentIfAsked(_ data: Data, model: String) {
    guard let directory = ProcessInfo.processInfo.environment["DT_PROXY_DUMP_LATENTS"], !directory.isEmpty,
      Date().timeIntervalSince(lastDump) >= 1
    else { return }
    lastDump = Date()
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: directory + "/" + model + ".latent"))
  }

  static func turn(of count: Int, at time: Date = Date()) -> Int {
    count <= 1 ? 0 : Int(time.timeIntervalSince1970) % count
  }

  static func cgImage(ofTensorData data: Data) -> CGImage? {
    guard let tensor = Tensor<FloatType>(data: data, using: [.zip, .fpzip]) else { return nil }
    return StatusImage.cgImage(from: tensor)
  }

  private func monitorFinalThumbnail(of job: Job) -> String? {
    if let cached = lock.withLockCompat({ monitorThumbs[job.id] }), cached.key == -1 { return cached.png }
    var made = results?.thumbnail(for: job.id)
    if made == nil {
      guard let data = job.payload.lastCompleteImage(), let image = Self.cgImage(ofTensorData: data),
        let png = Self.thumbnailPNG(image)
      else { return nil }
      made = png
      if job.group.source != nil { results?.saveThumbnail(png, for: job.id) }
    }
    guard let png = made else { return nil }
    lock.withLockCompat {
      monitorThumbs[job.id] = (-1, png)

      monitorPreviewSets[job.id] = nil
    }
    return png
  }

  static func thumbnailPNG(_ image: CGImage, maxSide: Int = 160) -> String? {
    let scale = min(Double(maxSide) / Double(max(image.width, image.height)), 1)
    let width = max(Int(Double(image.width) * scale), 1)
    let height = max(Int(Double(image.height) * scale), 1)
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, scaled, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return (data as Data).base64EncodedString()
  }
}

extension ProxyService {

  func sweepReceipts(project: String?) {
    receiptQueue.asyncAfter(deadline: .now() + 6) { [weak self] in
      guard let self = self, let locator = self.locator else { return }
      let groups = self.lock.withLockCompat { self.groups }
      for group in groups where !self.inQueue(group) {
        guard let assignment = locator.assignment(of: group.id), let node = assignment.receipt else { continue }

        guard assignment.project == project else { continue }
        let undo = self.undoFile
        let outcome = NodeDeleter.delete(
          project: locator.path(of: assignment.project), lineage: node.lineage, logicalTime: node.logicalTime,
          newerBy: 2, undoFile: undo)
        switch outcome {
        case .deleted(let rows):
          locator.clearReceipt(for: group.id)
          self.monitorLog("RECEIPT \(group.code) \(node.lineage)/\(node.logicalTime) deleted from \(assignment.project) (\(rows) rows, undo journal written)")
        case .skipped(let why):
          self.monitorLog("RECEIPT \(group.code) \(node.lineage)/\(node.logicalTime) not deleted yet: \(why)")

          if why.contains("is not there") { locator.clearReceipt(for: group.id) }
        }
      }
    }
  }
}

extension ProxyService {
  private func monitorJob(_ command: [String: Any]) -> Job? {
    guard let code = (command["code"] as? String)?.lowercased(), let run = command["run"] as? Int else {
      return nil
    }
    return lock.withLockCompat { groups + tracked }.first { $0.code.lowercased() == code }?
      .jobs.first { $0.runIndex == run }
  }

  func monitorPreview(_ command: [String: Any]) {
    guard let job = monitorJob(command), let out = command["out"] as? String else { return }
    let code = command["code"] as? String ?? ""
    let run = command["run"] as? Int ?? 0
    monitorMediaQueue.async { [weak self] in
      var image: CGImage? = job.payload.lastCompleteImage().flatMap { Self.cgImage(ofTensorData: $0) }
      if image == nil, let data = job.lastPreview,
        let latent = Tensor<FloatType>(data: data, using: [.zip, .fpzip])
      {
        let images = PreviewDecoder.shown(fromLatent: latent, model: job.model, limit: Self.previewsShown)
        image = images.isEmpty ? nil : images[Self.turn(of: images.count)]
      }
      var ok = false
      if let image = image,
        let destination = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)
      {
        CGImageDestinationAddImage(destination, image, nil)
        ok = CGImageDestinationFinalize(destination)
      }
      self?.monitor?.broadcast(["type": "preview", "code": code, "run": run, "path": out, "ok": ok])
    }
  }

  func monitorSave(_ command: [String: Any]) {
    guard let job = monitorJob(command), let directory = command["dir"] as? String,
      let name = command["name"] as? String
    else { return }
    let code = command["code"] as? String ?? ""
    let run = command["run"] as? Int ?? 0
    monitorMediaQueue.async { [weak self] in
      var reply: [String: Any] = ["type": "saved", "code": code, "run": run]
      let payload = job.payload
      do {
        let video = MediaSaver.isVideo(
          completeImages: payload.completeImages, hasAudio: payload.hasAudio,
          configuration: job.requestConfiguration, model: job.model)
        let files = try MediaSaver.save(
          payload: payload, model: job.model, video: video, name: name,
          directory: URL(fileURLWithPath: directory), xmp: Self.metadata(of: job))
        reply["ok"] = true
        reply["files"] = files.map { $0.path }
      } catch {
        reply["ok"] = false
        reply["message"] = "\(error)"
      }
      self?.monitorLog("MONITOR save \(code) batch \(run): \(reply["ok"] as? Bool == true ? "written" : "failed: \(reply["message"] ?? "")")")
      self?.monitor?.broadcast(reply)
    }
  }
}

extension ProxyService {

  static func saveName(of job: Job) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
    let stamp = formatter.string(from: job.snapshot().finishedAt ?? job.createdAt)

    let first = max(job.batchSize, 1) * (job.runIndex - 1) + 1
    return "image-\(stamp)-\(job.code)\(first)"
  }

  static func metadata(of job: Job) -> ((Int, Int, Int) -> String?)? {
    guard let data = job.requestConfiguration, !data.isEmpty else { return nil }
    let configuration = GenerationConfiguration.from(data: data)
    let finished = job.snapshot().finishedAt ?? Date()
    return { index, width, height in
      var seed = job.seed
      for _ in 0..<index { seed = HistoryFixer.nextSeed(after: seed) }
      return PNGMetadata.xmp(
        PNGMetadata.Info(
          prompt: job.prompt, negativePrompt: job.negativePrompt ?? "", configuration: configuration,
          seed: seed, width: width, height: height, createdAt: finished))
    }
  }

  static let knownThirdPartyUsers: Set<String> = ["draw-things-cli", "MediaGenerationKit"]

  static func trackedClient(
    headers: HPACKHeaders, request: ImageGenerationRequest, extraThirdPartyUsers: Set<String> = [],
    peerIsLocal: Bool = false, localAppNames: Set<String>? = nil
  ) -> String? {
    if let client = headers["x-dt-client"].first, !client.isEmpty { return client }
    if let agent = headers["user-agent"].first?.lowercased(), agent.hasPrefix("grpc-"),
      !agent.hasPrefix("grpc-swift")
    {
      if !request.user.isEmpty { return request.user }
      return agent.hasPrefix("grpc-node") ? "node client" : String(agent.split(separator: "/").first ?? "client")
    }
    if !request.user.isEmpty,
      knownThirdPartyUsers.contains(request.user) || extraThirdPartyUsers.contains(request.user)
    {
      return request.user
    }
    if peerIsLocal, request.device == .laptop, !request.user.isEmpty, let names = localAppNames,
      !names.contains(request.user.lowercased())
    {
      return request.user
    }
    return nil
  }

  static func ownNames() -> Set<String> {
    var names = Set<String>()
    let host = Host.current()
    if let name = host.localizedName { names.insert(name.lowercased()) }
    for name in host.names {
      names.insert(name.lowercased())
      if let first = name.split(separator: ".").first { names.insert(String(first).lowercased()) }
    }
    return names
  }

  static func serverLogger() -> Logger {
    var logger = Logger(label: "io.grpc.server")
    logger.logLevel = .critical
    return logger
  }

  private func sameOrderInQueue(
    request: ImageGenerationRequest, origin: Group.Origin?, at time: Date, canvasFromApp: Bool
  ) -> (entry: StatusRegistry.Entry?, reason: String)? {
    let (key, expected) = Self.monitorGroupKey(of: request)
    return lock.withLockCompat { () -> (StatusRegistry.Entry?, String)? in
      let mine = groups.filter { !$0.shelved && $0.origin?.key == origin?.key }
      if let burst = oldPickup, burst.key == key, burst.partition == origin?.key, burst.remaining > 0,
        time.timeIntervalSince(burst.at) < burstWindow
      {
        oldPickup = (key, burst.partition, burst.remaining - 1, time)
        return (nil, "the rest of a Batch Count burst of a pickup")
      }
      if mine.contains(where: { $0.canTake(key: key, at: time, window: burstWindow) }) { return nil }

      let matching = mine.filter {
        $0.key == key && inQueue($0) && !Self.orderChanged(of: $0, in: request, byApp: canvasFromApp)
      }
      guard let same = matching.last else { return nil }
      oldPickup = (key, origin?.key, expected - 1, time)
      var entry =
        registry.all.last { $0.key == same.id }
        ?? StatusRegistry.Entry(
          key: same.id, label: same.code, hash: Data(), signature: [], width: 0, height: 0, groups: [])

      entry.groups.formUnion(mine.filter { inQueue($0) }.map { $0.id })
      return (entry, "the same order as \(matching.map { $0.code }.joined(separator: ", ")) is in the queue (same seed and parameters; the picture does not count)")
    }
  }

  static func origin(of request: ImageGenerationRequest, context: StreamingResponseCallContext<ImageGenerationResponse>) -> Group.Origin? {
    if request.device == .laptop, peerIsThisComputer(context) { return nil }
    return Group.Origin(user: request.user, device: deviceName(request.device), address: peerAddress(context))
  }

  static func deviceName(_ device: DeviceType) -> String {
    switch device {
    case .phone: return "phone"
    case .tablet: return "tablet"
    case .laptop: return "laptop"
    case .UNRECOGNIZED(let value): return "device \(value)"
    }
  }

  static func peerAddress(_ context: StreamingResponseCallContext<ImageGenerationResponse>) -> String? {
    switch context.logger[metadataKey: "grpc.conn.addr_remote"] {
    case .string(let text)?: return text
    case .stringConvertible(let value)?: return value.description
    default: return nil
    }
  }

  static func peerIsThisComputer(_ context: StreamingResponseCallContext<ImageGenerationResponse>) -> Bool {
    func address(_ key: String) -> String? {
      switch context.logger[metadataKey: key] {
      case .string(let text)?: return text
      case .stringConvertible(let value)?: return value.description
      default: return nil
      }
    }
    return isThisComputer(remote: address("grpc.conn.addr_remote"), interfaces: ownAddresses())
  }

  static func isThisComputer(remote: String?, interfaces: Set<String>) -> Bool {
    guard var remote = remote?.lowercased(), !remote.isEmpty else { return false }
    if remote.hasPrefix("::ffff:") { remote.removeFirst("::ffff:".count) }
    if remote == "::1" || remote.hasPrefix("127.") { return true }
    return interfaces.contains(remote)
  }

  static func ownAddresses() -> Set<String> {
    var result = Set<String>()
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return result }
    defer { freeifaddrs(list) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
      if let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {

          result.insert(String(cString: host).lowercased().split(separator: "%").first.map(String.init) ?? "")
        }
      }
      cursor = entry.pointee.ifa_next
    }
    return result
  }

  func probeLastPeerWasLocal() -> Bool? { lock.withLockCompat { lastPeerWasLocal } }

  func probeAdd(_ group: Group) { lock.withLockCompat { groups.append(group) } }
  func probeShelvedCodes() -> [String] { lock.withLockCompat { groups.filter { $0.shelved }.map { $0.code } } }

  func probeTables(partition: Group.Origin?) -> [(name: String, codes: [String])] {
    let scope = displayScope(askedProject: nil, partition: partition)
    let model = statusModel(
      focus: scope.focus, shown: scope.shown, askedProject: nil, partition: partition, info: nil, detail: nil)
    return model.tables.map { ($0.project, $0.groups.map { $0.code }) }
  }

  func probeSnapshot() -> [String: Any] { monitorSnapshot() }
  func probeAppGroupCount() -> Int { lock.withLockCompat { groups.count } }

  fileprivate func trackedRelay(
    number: Int, request: ImageGenerationRequest,
    context: StreamingResponseCallContext<ImageGenerationResponse>, client: String, tool: String?,
    isApp: Bool = false, requestId: String?, workdir: String?, background: Bool
  ) -> EventLoopFuture<GRPCStatus> {
    let job: Job = lock.withLockCompat {
      let group = Group(code: makeUniqueCode(), key: "tracked-\(UUID().uuidString)", expected: 1)

      group.source = tool ?? client
      group.sourceClient = client
      group.sourceRequestId = requestId
      group.sourceWorkdir = workdir
      group.sourceBackground = background
      group.sourceIsApp = isApp
      tracked.append(group)
      let job = Job(group: group, request: request)
      job.attachSpool(results?.spoolDirectory(for: job.id))
      group.add(job, at: Date())
      return job
    }
    logger.info(
      "REQ \(number) TRACKED \(job.code): tool \(tool ?? "-"), client \(client), request \(requestId ?? "-"), \(background ? "background call" : "foreground call"), passes through unchanged"
    )
    let clientGone = ClientGone()
    let call = upstream.client.generateImage(request) { response in
      job.consume(response)
      context.sendResponse(response, promise: nil)
    }
    job.call = call
    let promise = context.eventLoop.makePromise(of: GRPCStatus.self)
    call.status.whenComplete { [weak self] result in
      guard let self = self else {
        promise.completeWith(result)
        return
      }
      job.finish(result)
      if case .done = job.state {

        if !background { job.markDelivered() }
        let kept = self.monitor?.isActive == true || !job.snapshot().delivered
        if kept, let results = self.results, job.payload.hasImages {
          let thumbnail = self.monitorFinalThumbnail(of: job)
          results.save(job)
          if let thumbnail = thumbnail { results.saveThumbnail(thumbnail, for: job.id) }
          self.keepWithinLimits()
        }
        if background { self.watchDeliveryOfTools() }
        if self.monitor?.isActive != true { self.cleanDelivered() }
      }
      FileLog.shared.append("TRACKED \(job.code) \(tool ?? client) finished: \(job.snapshot().state.label)")
      self.logger.info("REQ \(number) TRACKED \(job.code) finished: \(job.snapshot().state.label)")
      self.monitor?.pushNow()
      switch result {
      case .success(let status):

        if !clientGone.value, case .cancelled = job.state {
          promise.succeed(GRPCStatus(code: .cancelled, message: "Cancelled in the queue monitor"))
        } else {
          promise.succeed(status)
        }
      case .failure(let error):
        promise.fail(error)
      }
    }
    context.closeFuture.whenComplete { _ in
      clientGone.set()
      job.cancel()
    }
    monitor?.pushNow()
    return promise.futureResult
  }

  fileprivate func watchDeliveryOfTools() {
    let start: Bool = lock.withLockCompat {
      guard deliveryWatch == nil else { return false }
      let timer = DispatchSource.makeTimerSource(queue: deliveryQueue)
      timer.schedule(deadline: .now() + deliveryPollInterval, repeating: deliveryPollInterval)
      timer.setEventHandler { [weak self] in self?.pollDeliveryOfTools() }
      deliveryWatch = timer
      timer.resume()
      return true
    }
    if start { logger.info("Watching the state files of the plugins for collected results") }
  }

  private func pollDeliveryOfTools() {
    let waiting = lock.withLockCompat { tracked }.filter { group in
      group.sourceBackground
        && group.jobs.contains { job in
          if case .done = job.state { return job.undeliveredImageCount > 0 }
          return false
        }
    }
    if waiting.isEmpty {
      lock.withLockCompat {
        deliveryWatch?.cancel()
        deliveryWatch = nil
      }
      return
    }
    var changed = false
    for group in waiting where Self.collectedByAgent(group) {
      for job in group.jobs where job.markDelivered() {
        results?.update(job)
        changed = true
      }
      monitorLog("TRACKED \(group.code) \(group.source ?? "-"): the agent collected the result")
    }
    if changed {
      if monitor?.isActive != true { cleanDelivered() }
      monitor?.pushNow()
    }
  }

  static func collectedByAgent(_ group: Group) -> Bool {
    guard let directory = group.sourceWorkdir, let id = group.sourceRequestId,
      let data = FileManager.default.contents(atPath: directory + "/chat_requests_state.json"),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let requests = object["requests"] as? [String: Any], let record = requests[id] as? [String: Any]
    else { return false }
    return record["delivered"] as? Bool == true
  }
}

private final class ClientGone {
  private let lock = NSLock()
  private var flag = false
  var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
  func set() { lock.lock(); flag = true; lock.unlock() }
}
