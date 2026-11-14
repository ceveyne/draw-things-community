import DataModels
import Foundation
import GRPC
import GRPCImageServiceModels

enum JobState {
  case queued
  case running
  case done
  case failed(String)
  case cancelled

  var label: String {
    switch self {
    case .queued: return "Pending"
    case .running: return "Running"
    case .done: return "Generated"
    case .failed: return "Failed"
    case .cancelled: return "Cancelled"
    }
  }

  var isRunning: Bool {
    if case .running = self { return true }
    return false
  }

  var isFinished: Bool {
    switch self {
    case .queued, .running: return false
    case .done, .failed, .cancelled: return true
    }
  }
}

final class Group {
  let id: UUID
  let code: String

  let key: String

  let expected: Int
  let createdAt: Date

  struct Origin: Codable, Equatable {

    var user: String

    var device: String
    var address: String?

    var label: String { user.isEmpty ? device : user }

    var key: String { "\(device)\u{0}\(user)" }
  }
  var origin: Origin? = nil

  var shelved = false

  struct ToolInfo: Codable, Equatable {
    var source: String
    var client: String?
    var requestId: String?
    var background: Bool
    var workdir: String?
  }

  var toolInfo: ToolInfo? {
    source.map {
      ToolInfo(source: $0, client: sourceClient, requestId: sourceRequestId, background: sourceBackground, workdir: sourceWorkdir)
    }
  }

  func apply(_ info: ToolInfo) {
    source = info.source
    sourceClient = info.client
    sourceRequestId = info.requestId
    sourceBackground = info.background
    sourceWorkdir = info.workdir
  }

  var source: String? = nil
  var sourceClient: String? = nil
  var sourceRequestId: String? = nil
  var sourceBackground = false

  var sourceWorkdir: String? = nil
  private let lock = NSLock()
  private var _jobs: [Job] = []
  private var _lastMemberAt: Date
  private var _closed = false

  init(
    id: UUID = UUID(), code: String, key: String, expected: Int, createdAt: Date = Date()
  ) {
    self.id = id
    self.code = code
    self.key = key
    self.expected = expected
    self.createdAt = createdAt
    _lastMemberAt = createdAt
  }

  var jobs: [Job] { lock.withLock { _jobs } }

  func add(_ job: Job, at time: Date) {
    lock.withLock {
      job.runIndex = _jobs.count + 1
      _jobs.append(job)
      _lastMemberAt = time
    }
  }

  func canTake(key: String, at time: Date, window: TimeInterval) -> Bool {
    lock.withLock {
      !_closed && self.key == key && _jobs.count < expected && time.timeIntervalSince(_lastMemberAt) < window
    }
  }

  func total(now: Date, window: TimeInterval) -> Int {
    lock.withLock {
      let open = !_closed && _jobs.count < expected && now.timeIntervalSince(_lastMemberAt) < window
      return open ? expected : _jobs.count
    }
  }

  var isListed: Bool { jobs.contains { $0.isListed } }

  func close() { lock.withLock { _closed = true } }
}

final class Job {
  let id: UUID
  let group: Group
  var code: String { group.code }

  var runIndex = 0
  let createdAt: Date
  let width: Int
  let height: Int
  let batchSize: Int
  let totalSteps: Int
  let model: String
  let prompt: String
  let seed: UInt32

  let requestConfiguration: Data?
  let negativePrompt: String?

  let mode: String?

  private let lock = NSLock()
  private var _state: JobState = .queued
  private var _phase = "Pending"
  private var _stage: Stage = .processing
  private var _step: Int? = nil
  private var _stepTimes: [Date] = []
  private var _startedAt: Date? = nil
  private var _finishedAt: Date? = nil
  private var _lastPreview: Data? = nil

  private var _payload = Payload(directory: nil)
  private var _delivered = false
  private var _failureShown = false
  private var _statusRenderCount = 0
  private var _downloadProgress: String? = nil
  var call: ServerStreamingCall<ImageGenerationRequest, ImageGenerationResponse>?

  enum Stage {
    case processing, sampling, finishing
  }

  struct Snapshot {
    var state: JobState
    var stage: Stage
    var phase: String
    var step: Int?
    var startedAt: Date?
    var finishedAt: Date?
    var etaSeconds: Double?
    var hasPreview: Bool
    var delivered: Bool
  }

  init(group: Group, request: ImageGenerationRequest) {
    id = UUID()
    createdAt = Date()
    self.group = group
    let configuration = GenerationConfiguration.from(data: request.configuration)
    width = max(Int(configuration.startWidth) * 64, 64)
    height = max(Int(configuration.startHeight) * 64, 64)
    batchSize = max(Int(configuration.batchSize), 1)
    totalSteps = Int(configuration.steps)
    model = configuration.model ?? ""
    prompt = request.prompt
    seed = configuration.seed
    requestConfiguration = request.configuration
    negativePrompt = request.negativePrompt
    mode = request.hasImage ? "edit" : "text2image"
  }

  func attachSpool(_ directory: URL?) {
    lock.withLock {
      guard !_payload.hasImages else { return }
      _payload = Payload(directory: directory)
    }
  }

  var payload: Payload { lock.withLock { _payload } }

  init(group: Group, restoring record: ResultStore.Record, payload: Payload, delivered: Bool = false) {
    id = record.id
    createdAt = record.createdAt
    self.group = group
    width = record.width
    height = record.height
    batchSize = record.batchSize
    totalSteps = record.totalSteps
    model = record.model
    prompt = record.prompt
    seed = record.seed
    requestConfiguration = record.configuration
    negativePrompt = record.negativePrompt
    mode = nil
    _state = .done
    _phase = "Done"
    _startedAt = record.startedAt
    _finishedAt = record.finishedAt
    _payload = payload
    _delivered = delivered
  }

  init(group: Group, restoring record: ResultStore.Record, responses: [ImageGenerationResponse]) {
    id = record.id
    createdAt = record.createdAt
    self.group = group
    width = record.width
    height = record.height
    batchSize = record.batchSize
    totalSteps = record.totalSteps
    model = record.model
    prompt = record.prompt
    seed = record.seed
    requestConfiguration = record.configuration
    negativePrompt = record.negativePrompt
    mode = nil
    _state = .done
    _phase = "Done"
    _startedAt = record.startedAt
    _finishedAt = record.finishedAt
    _payload = Payload(memory: responses)
  }

  init(group: Group, restoringFailed record: ResultStore.Record, message: String) {
    id = record.id
    createdAt = record.createdAt
    self.group = group
    width = record.width
    height = record.height
    batchSize = record.batchSize
    totalSteps = record.totalSteps
    model = record.model
    prompt = record.prompt
    seed = record.seed
    requestConfiguration = record.configuration
    negativePrompt = record.negativePrompt
    mode = nil
    _state = .failed(message)
    _phase = "Failed"
    _startedAt = record.startedAt
    _finishedAt = Date()
  }

  var state: JobState { lock.withLock { _state } }

  func takeResultsForDelivery(keepFiles: Bool = false) -> [ImageGenerationResponse]? {
    lock.withLock {
      guard case .done = _state, !_delivered else { return nil }
      _delivered = true
      let responses = _payload.responses()
      if !keepFiles { _payload.markGone() }
      return responses
    }
  }

  @discardableResult
  func discardUndelivered() -> Bool {
    lock.withLock {
      guard case .done = _state, !_delivered else { return false }
      _delivered = true
      _payload.markGone()
      return true
    }
  }

  @discardableResult
  func markDelivered() -> Bool {
    lock.withLock {
      guard case .done = _state, !_delivered else { return false }
      _delivered = true
      return true
    }
  }

  var isListed: Bool {
    lock.withLock {
      switch _state {
      case .queued, .running: return true
      case .done: return !_delivered
      case .failed, .cancelled: return !_failureShown
      }
    }
  }

  @discardableResult
  func markFailureShown() -> Bool {
    lock.withLock {
      switch _state {
      case .failed, .cancelled:
        defer { _failureShown = true }
        return !_failureShown
      default: return false
      }
    }
  }

  func nextStatusRenderIndex() -> Int {
    lock.withLock {
      defer { _statusRenderCount += 1 }
      return _statusRenderCount
    }
  }

  var undeliveredImageCount: Int {
    lock.withLock {
      guard case .done = _state, !_delivered else { return 0 }
      return _payload.imageCount
    }
  }

  var lastPreview: Data? { lock.withLock { _lastPreview } }

  func snapshot(now: Date = Date()) -> Snapshot {
    lock.withLock {
      var eta: Double? = nil
      if let step = _step, _stepTimes.count >= 2, totalSteps > step {
        let elapsed = _stepTimes.last!.timeIntervalSince(_stepTimes.first!)
        let perStep = elapsed / Double(_stepTimes.count - 1)
        eta = perStep * Double(totalSteps - step)
      }
      return Snapshot(
        state: _state, stage: _stage,
        phase: _downloadProgress ?? _phase, step: _step, startedAt: _startedAt,
        finishedAt: _finishedAt, etaSeconds: eta, hasPreview: _lastPreview != nil,
        delivered: _delivered)
    }
  }

  func consume(_ response: ImageGenerationResponse) {
    lock.withLock {
      if case .queued = _state, response.hasCurrentSignpost || response.hasRemoteDownload {
        _state = .running
        _startedAt = Date()
      }
      if response.hasRemoteDownload {
        let download = response.remoteDownload
        _downloadProgress =
          "Downloading files \(download.item)/\(download.itemsExpected)"
      }
      if response.hasCurrentSignpost {
        _downloadProgress = nil
        switch response.currentSignpost.signpost {
        case .textEncoded:
          _phase = "Text encoded"
          _stage = .processing
        case .imageEncoded:
          _phase = "Image encoded"
          _stage = .processing
        case .sampling(let sampling):
          _phase = "Sampling"
          _stage = .sampling
          _step = Int(sampling.step)
          _stepTimes.append(Date())
        case .imageDecoded:
          _phase = "Image decoded"
          _stage = .finishing
        case .secondPassImageEncoded:
          _phase = "Second pass: image encoded"
          _stage = .processing
        case .secondPassSampling(let sampling):
          _phase = "Second pass: sampling"
          _stage = .sampling
          _step = Int(sampling.step)
          _stepTimes.append(Date())
        case .secondPassImageDecoded:
          _phase = "Second pass: image decoded"
          _stage = .finishing
        case .faceRestored:
          _phase = "Face restored"
          _stage = .finishing
        case .imageUpscaled:
          _phase = "Image upscaled"
          _stage = .finishing
        case .none: break
        }
      }
      if response.hasPreviewImage {
        _lastPreview = response.previewImage
      }
      if !response.generatedImages.isEmpty || !response.generatedAudio.isEmpty
        || response.hasScaleFactor || response.hasDownloadSize
      {
        var stored = response
        stored.clearPreviewImage()
        stored.clearCurrentSignpost()
        stored.signposts = []
        _payload.append(stored)
      }
    }
  }

  @discardableResult
  func cancel() -> Bool {
    let cancelled: Bool = lock.withLock {
      switch _state {
      case .queued, .running:
        _state = .cancelled
        _finishedAt = Date()
        _lastPreview = nil
        return true
      default:
        return false
      }
    }
    if cancelled { call?.cancel(promise: nil) }
    return cancelled
  }

  func finish(_ result: Result<GRPCStatus, Error>) {
    lock.withLock {
      if case .cancelled = _state { return }
      _finishedAt = Date()
      switch result {
      case .success(let status):
        if status.isOk {
          let hasImages = _payload.hasImages
          _state = hasImages ? .done : .failed("The server returned no images")
        } else if status.code == .cancelled {
          _state = .cancelled
        } else {
          _state = .failed(status.message ?? "\(status.code)")
        }
      case .failure(let error):
        _state = .failed("\(error)")
      }
      _lastPreview = nil
    }
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
