import ArgumentParser
import AVFoundation
import BinaryResources
import CoreGraphics
import Crypto
import DataModels
import Diffusion
import ImageIO
import NNC
import SQLite3
import Foundation
import GRPC
import GRPCImageServiceModels
import Logging
import ModelZoo
import NIO
import NIOSSL

final class Advertiser: NSObject, NetServiceDelegate {
  private var service: NetService?

  func start(name: String, port: Int32, TLS: Bool) {
    let service = NetService(
      domain: "local.", type: "_dt-grpc._tcp.", name: "\(name)_\(TLS ? "tls" : "notls")",
      port: port)
    service.delegate = self
    self.service = service
    service.publish()
  }

  func netServiceDidPublish(_ sender: NetService) {
    print("Service published: type=\(sender.type) name=\(sender.name) port=\(sender.port)")
  }

  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    print("Failed to publish service: \(errorDict)")
  }
}

@main
struct ProxyCommand: ParsableCommand {
  static var configuration = CommandConfiguration(
    commandName: "gRPCServerProxy",
    abstract:
      "A proxy in front of gRPCServerCLI that releases the client right after a request is accepted and keeps rendering in the background."
  )

  @Argument(help: "The directory path to load models. Accepted for compatibility with gRPCServerCLI.")
  var modelsDirectory: String

  @Option(name: .shortAndLong, help: "The name you expose in the local network. \" (proxy)\" is appended.")
  var name: String = Host.current().localizedName ?? "Unknown Computer"

  @Option(name: .shortAndLong, help: "The address in your local network that you want to expose.")
  var address: String = "0.0.0.0"

  @Option(name: .shortAndLong, help: "The port of the proxy.")
  var port: Int = 7861

  @Option(name: .long, help: "The address of the gRPCServerCLI behind the proxy.")
  var upstreamAddress: String = "127.0.0.1"

  @Option(name: .long, help: "The port of the gRPCServerCLI behind the proxy.")
  var upstreamPort: Int = 7859

  @Option(name: .shortAndLong, help: "The shared secret of the server. Used on both sides.")
  var sharedSecret: String = ""

  @Flag(help: "Disable TLS on both sides.")
  var noTLS = false

  @Flag(help: "Forward GenerateImage 1:1 instead of releasing the client early.")
  var relay = false

  @Option(
    help:
      "What a status request gets when it follows another one within --burst-window: status (another status image), error (gRPC error status) or empty (success without an image)."
  )
  var followUpMode: String = "empty"

  @Option(
    help:
      "A file whose content (status, error or empty) overrides --follow-up-mode on every request."
  )
  var followUpModeFile: String = "/tmp/grpc-proxy-follow-up-mode"

  @Option(
    help:
      "A file read on every request that switches measuring modes (words start=empty, start=error, closing=none, see the plan); without the file everything is as usual."
  )
  var replyModeFile: String =
    ""

  @Option(
    help:
      "The most images handed out with one answer. The rest stays undelivered until the next request. 0 means no limit."
  )
  var maxDeliveryImages: Int = 0

  @Option(
    help:
      "Width of the status image in pixels. 0 (default) uses the canvas size of the job instead."
  )
  var statusWidth: Int = 0

  @Option(help: "Height divided by width of the status image when --status-width is given.")
  var statusAspect: Double = 1.25

  @Option(
    help:
      "Directory with the Draw Things projects (*.sqlite3). The proxy finds out which project a request belongs to by looking at the write times and history nodes in it, without changing anything there. \"none\" switches this off."
  )
  var projectsDirectory: String =
    NSHomeDirectory() + "/Library/Containers/com.liuliu.draw-things/Data/Documents"

  @Flag(
    help:
      "Reads the newest history nodes of the most recently written project once, compares the file times of the project before and after, and exits. Does not start the proxy."
  )
  var probeProjects = false

  @Option(
    help:
      "Deletes the node 1/3 from a copy of the given project (made inside a temporary folder), checks the rows, puts it back with the undo journal and checks again. Exits without starting the proxy."
  )
  var probeDeleteNode: String?

  @Option(
    help:
      "Builds the history node of a made-up request in the given project copy (monitor mode: no receipt) and checks the node. Writes nothing. Exits without starting the proxy."
  )
  var probeMonitorHistory: String?

  @Flag(
    help:
      "Starts the monitor socket in a temporary place, connects to it, and checks state, event and command lines and the end of monitor mode. Exits without starting the proxy."
  )
  var probeMonitor = false

  @Flag(
    help:
      "Renders status images in several sizes, with and without preview, and checks that the watermark is found, also after a PNG round trip, and not found in other pictures. Exits without starting the proxy."
  )
  var probeWatermark = false

  @Option(
    help:
      "Reads the stored results of the state directory given here (a directory with `results/`) and prints, per request, the key of the same order and the configuration fields that differ from the first request with the same prompt. Exits without starting the proxy."
  )
  var probeCompareConfigs: String?

  @Option(
    help: ArgumentHelp(
      "Decodes a preview latent that the proxy wrote (environment DT_PROXY_DUMP_LATENTS=<directory>) with the decoder of the proxy and writes the pictures as <file>-N.png. Needs the file and the model name: --probe-decode-latent <file>:<model>. Exits without starting the proxy.",
      valueName: "file:model"))
  var probeDecodeLatent: String?

  @Flag(
    help:
      "Saves a made-up image, a made-up image batch and a made-up clip with sound with the code of \"Save as…\" into a temporary directory and checks the files. Exits without starting the proxy."
  )
  var probeSave = false

  @Flag(
    help:
      "Starts a made-up server, the proxy in front of it and a client that marks its calls like a plugin, and checks that the client gets the same frames and status as from the server directly, that the monitor shows the call, that a cancel works from both sides, and that nothing of the app is touched. Exits without starting the proxy."
  )
  var probeTrackedRelay = false

  @Flag(
    help:
      "Checks the store of uncollected results in a temporary directory: save, restore, erase on delivery, erase when old. Exits without starting the proxy."
  )
  var probeResults = false

  @Option(
    help:
      "Reads the history nodes of a project database (a copy), checks that each survives being written and read again, corrects the result nodes named by --history-results with the receipts named by --history-receipts (both lists of positions by wall clock, starting at 0) in the copy given by --history-out, and compares. Exits without starting the proxy."
  )
  var probeHistory: String?
  @Flag(
    inversion: .prefixedNo,
    help:
      "Rebuilds the history nodes of delivered images in the project from the receipts of their jobs: the app makes them from the request that fetched the images, so prompt, model, seed, size, steps and LoRAs are those of the query. Every change is journaled and undoable. Needs the state directory."
  )
  var syncHistory = true

  @Flag(
    inversion: .prefixedNo,
    help:
      "Monitor mode: a new order gets a receipt (a status image that is the handle for the pickup, deleted from the project when the order is picked up completely). Off: nothing is put into the history but the delivered images, and every new order is announced with a sound."
  )
  var issueReceipts = false

  @Option(help: "With --probe-history: positions of the receipts, for example 0,1,2.")
  var historyReceipts: String = ""
  @Option(help: "With --probe-history: positions of the delivered results, in the same order as the receipts.")
  var historyResults: String = ""
  @Option(help: "With --probe-history: where the corrected copy is written.")
  var historyOut: String = "/tmp/history-corrected.sqlite3"

  @Option(
    help:
      "Where the proxy keeps the hashes of its status images and their projects between runs, so that a request that brings only a hash is still recognised after a restart. 'none' keeps nothing."
  )
  var stateDirectory: String =
    NSHomeDirectory() + "/Library/Application Support/gRPC Server Manager/proxy"

  @Option(
    help:
      "A Unix socket for the queue monitor of the manager. While a monitor is connected, requests of laptops get no status images; the monitor shows the queue. Empty: no socket."
  )
  var monitorSocket: String = ""

  @Option(help: "Language of the texts in status images and in the queue monitor: en or de.")
  var language: String = "en"

  @Option(help: "With --debug, where canvas and status images are written as PNG.")
  var debugDumpDirectory: String = "/tmp/grpc-proxy-debug"

  @Option(help: "Seconds within which a status request counts as a follow-up of the previous one.")
  var burstWindow: Double = 3

  @Option(
    name: .customLong("third-party-user"),
    help: "Name (`user`) of a Swift client that is not the Draw Things app; it passes through unchanged and only shows in the monitor. `draw-things-cli` and `MediaGenerationKit` are always known. Can be given several times."
  )
  var thirdPartyUsers: [String] = []

  @Option(
    name: .customLong("app-user"),
    help: "Name (`user`) that the Draw Things app on this computer goes by besides the name of this Mac (the app calls itself by that). Any other laptop client on this computer passes through unchanged and only shows in the monitor. Can be given several times."
  )
  var appUsers: [String] = []

  @Flag(help: "Force TLS towards the server even when --no-tls is given (for testing).")
  var forceUpstreamTLS = false

  @Flag(help: "Verbose logging.")
  var debug = false

  @Option(name: .shortAndLong, help: .hidden) var gpu: Int = 0
  @Option(name: .shortAndLong, help: .hidden) var datadogAPIKey: String = ""
  @Flag(help: .hidden) var noResponseCompression = false
  @Flag(help: .hidden) var modelBrowser = false
  @Flag(help: .hidden) var noFlashAttention = false
  @Option(name: .shortAndLong, help: .hidden) var weightsCache: Int = 0
  @Option(name: .long, help: .hidden) var secondaryModelsDirectory: String?
  @Option(name: .long, help: .hidden) var blobStoreAccessKey: String?
  @Option(name: .long, help: .hidden) var blobStoreSecret: String?
  @Option(name: .long, help: .hidden) var blobStoreEndpoint: String?
  @Option(name: .long, help: .hidden) var blobStoreBucket: String?
  @Flag(help: .hidden) var cpuOffload = false
  @Flag(help: .hidden) var freadPreferred = false
  @Option(name: .long, help: .hidden) var cacheUri: String?
  @Option(name: .long, help: .hidden) var cancellationWarningTimeout: Double?
  @Option(name: .long, help: .hidden) var cancellationCrashTimeout: Double?
  @Flag(help: .hidden) var echoOnQueue = false

  func run() throws {
    Loc.german = language.lowercased().hasPrefix("de")
    if probeProjects {
      runProjectProbe()
      return
    }
    if probeWatermark {
      runWatermarkProbe()
      return
    }
    if probeSave {
      runSaveProbe()
      return
    }
    if let spec = probeDecodeLatent {
      let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2, let data = FileManager.default.contents(atPath: parts[0]),
        let latent = Tensor<FloatType>(data: data, using: [.zip, .fpzip])
      else { print("cannot read \(spec)"); return }
      print("latent \(latent.shape), model \(parts[1]), version \(ModelZoo.versionForModel(parts[1]))")

      let linear = latent.shape.last == 64 ? PreviewDecoder.libraryImages(fromLatent: latent, version: .qwenImage2_1) : []
      for (index, image) in linear.enumerated() + PreviewDecoder.images(fromLatent: latent, model: parts[1]).enumerated().map({ ($0.offset + 1000, $0.element) }) {
        let out = URL(fileURLWithPath: parts[0] + "-\(index >= 1000 ? "proxy" : "linear")\(index % 1000).png")
        if let destination = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) {
          CGImageDestinationAddImage(destination, image, nil)
          print(CGImageDestinationFinalize(destination) ? "wrote \(out.path)" : "failed \(out.path)")
        }
      }
      return
    }
    if let directory = probeCompareConfigs {
      runCompareConfigs(directory)
      return
    }
    if probeTrackedRelay {
      runTrackedRelayProbe()
      return
    }
    if probeMonitor {
      runMonitorProbe()
      return
    }
    if let database = probeDeleteNode {
      runDeleteNodeProbe(database)
      return
    }
    if let database = probeMonitorHistory {
      runMonitorHistoryProbe(database)
      return
    }
    if probeResults {
      runResultsProbe()
      return
    }
    if let database = probeHistory {
      runHistoryProbe(database)
      return
    }
    LoggingSystem.bootstrap { label in
      var handler = StreamLogHandler.standardOutput(label: label)
      handler.logLevel = debug ? .debug : .info
      return handler
    }
    let logger = Logger(label: "com.draw-things.grpc-server-proxy")
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

    var modelUrls = [URL(fileURLWithPath: modelsDirectory)]
    if let secondary = secondaryModelsDirectory {
      modelUrls.append(URL(fileURLWithPath: secondary))
    }
    ModelZoo.externalUrls = modelUrls

    let upstream = try Upstream(
      host: upstreamAddress, port: upstreamPort, TLS: !noTLS || forceUpstreamTLS, group: group)
    var locator: ProjectLocator? = nil
    if projectsDirectory.lowercased() != "none" {
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: projectsDirectory, isDirectory: &isDirectory), isDirectory.boolValue {
        let candidate = ProjectLocator(directory: projectsDirectory, logger: logger)
        let access = candidate.readability()

        locator = candidate
        if access.readable {
          logger.info(
            "Projects are looked for in \(projectsDirectory) (read only, nothing there is changed), \(access.projects) projects found")
        } else {
          logger.warning(
            "The projects directory \(projectsDirectory) cannot be read (\(access.error ?? "unknown error")). No request can be assigned to a project, so a status request only delivers the results of the request whose status image it carries. If the proxy was started by the manager, allow the manager under System Settings > Privacy & Security > Full Disk Access and start again.")
        }
      } else {
        logger.info("No projects directory at \(projectsDirectory): results of all requests go out with any status request")
      }
    }
    var state: StateStore? = nil
    var results: ResultStore? = nil
    if stateDirectory.lowercased() != "none" {
      do {
        results = try ResultStore(directory: stateDirectory, logger: logger)
        state = try StateStore(directory: stateDirectory, logger: logger)
      } catch {
        logger.warning("The state directory \(stateDirectory) cannot be used, nothing is kept between runs: \(error)")
      }
    }
    var historyFixer: HistoryFixer? = nil

    if let locator = locator, state != nil, stateDirectory.lowercased() != "none" {
      historyFixer = HistoryFixer(locator: locator, journalDirectory: stateDirectory, logger: logger, correct: syncHistory)
    }
    if syncHistory, historyFixer != nil {
      logger.info("History nodes of delivered images are rebuilt from the receipts of their jobs (--no-sync-history turns it off), journal: \(stateDirectory)/history-journal.jsonl")
    } else {
      logger.info("History nodes of delivered images are left as the app made them")
    }
    let service = ProxyService(
      upstream: upstream, sharedSecret: sharedSecret, background: !relay,
      followUpMode: ProxyService.FollowUpMode(rawValue: followUpMode) ?? .status,
      followUpModeFile: followUpModeFile, replyModeFile: replyModeFile, burstWindow: burstWindow,
      maxDeliveryImages: maxDeliveryImages, statusWidth: statusWidth, statusAspect: statusAspect,
      locator: locator, state: state, results: results, historyFixer: historyFixer,
      dumpDirectory: debug ? debugDumpDirectory : nil, logger: logger)

    if stateDirectory.lowercased() != "none" { service.stateDirectoryPath = stateDirectory }
    service.issueReceipts = issueReceipts
    service.thirdPartyUsers = Set(thirdPartyUsers)
    service.localAppNames = ProxyService.ownNames().union(appUsers.map { $0.lowercased() })
    logger.info("The app on this computer is told by the names \(service.localAppNames?.sorted().joined(separator: ", ") ?? "-"); another laptop client on this computer passes through")
    if !monitorSocket.isEmpty {
      if stateDirectory.lowercased() != "none" { FileLog.shared.open(directory: stateDirectory) }
      locator?.startTracking()
      let hub = MonitorHub(path: monitorSocket, logger: logger)
      do {
        try hub.start()
        service.attachMonitor(hub)
      } catch {
        logger.warning("The monitor socket cannot be used: \(error)")
      }
    }

    let certificate = try? NIOSSLCertificate(
      bytes: [UInt8](BinaryResources.server_crt_crt), format: .pem)
    let privateKey = try? NIOSSLPrivateKey(
      bytes: [UInt8](BinaryResources.server_key_key), format: .pem)
    var TLS = !noTLS
    let serverFuture: EventLoopFuture<Server>
    if TLS, let certificate = certificate, let privateKey = privateKey {
      serverFuture = Server.usingTLS(
        with: GRPCTLSConfiguration.makeServerConfigurationBackedByNIOSSL(
          certificateChain: [.certificate(certificate)], privateKey: .privateKey(privateKey)),
        on: group
      )
      .withServiceProviders([service])
      .withLogger(ProxyService.serverLogger())
      .withMaximumReceiveMessageLength(1024 * 1024 * 1024)
      .bind(host: address, port: port)
    } else {
      serverFuture = Server.insecure(group: group)
        .withServiceProviders([service])
        .withLogger(ProxyService.serverLogger())
        .withMaximumReceiveMessageLength(1024 * 1024 * 1024)
        .bind(host: address, port: port)
      TLS = false
    }
    let server = try serverFuture.wait()
    logger.info(
      "Proxy listening on port \(port) (TLS: \(TLS)), upstream \(upstreamAddress):\(upstreamPort), mode: \(relay ? "relay" : "background")"
    )

    let advertiser = Advertiser()
    advertiser.start(name: "\(name) (proxy)", port: Int32(port), TLS: TLS)

    var signalSources = [DispatchSourceSignal]()
    for (name, number) in [("SIGTERM", SIGTERM), ("SIGINT", SIGINT), ("SIGHUP", SIGHUP)] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler {
        logger.info("Received \(name), shutting down")
        Foundation.exit(0)
      }
      source.resume()
      signalSources.append(source)
    }
    signal(SIGPIPE, SIG_IGN)
    logger.info("Proxy process \(ProcessInfo.processInfo.processIdentifier) is running")

    DispatchQueue.global().async {
      try? server.onClose.wait()
      logger.info("The server socket closed, shutting down")
      Foundation.exit(0)
    }
    RunLoop.main.run()
    _ = signalSources
  }

  func runHistoryProbe(_ path: String) {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
      if !ok { failures += 1 }
      print("\(ok ? "OK    " : "FAILED") \(name)")
    }

    var chain: [UInt32] = [175_308_301]
    while chain.count < 9 { chain.append(HistoryFixer.nextSeed(after: chain.last!)) }
    check("seed chain of the server", chain == [
      175_308_301, 3_822_972_500, 2_633_984_703, 1_153_367_819, 4_037_379_620, 1_279_648_916,
      3_929_309_983, 817_666_228, 3_605_226_817,
    ])
    var source: OpaquePointer?
    guard sqlite3_open_v2(path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database = source else {
      print("cannot open \(path)")
      return
    }
    defer { sqlite3_close(database) }
    let rows = HistoryCorrector.rows(in: database)
    let wallClock = HistoryCorrector.slot("wall_clock")
    var nodes = [(row: HistoryCorrector.Row, table: NodeTable)]()
    for row in rows {
      do {
        let table = try HistoryCorrector.decode(row.blob)
        nodes.append((row, table))
        let rebuilt = HistoryCorrector.encode(table)
        let again = try HistoryCorrector.decode(rebuilt)
        check(
          "node \(row.lineage)/\(row.logicalTime): \(table.count) fields, \(row.blob.count) -> \(rebuilt.count) bytes, round trip equal",
          again == table)
      } catch {
        check("node \(row.lineage)/\(row.logicalTime) could not be read: \(error)", false)
      }
    }
    func wall(_ table: NodeTable) -> UInt64 {
      if case .scalar(let bits, _)? = table[wallClock] { return bits }
      return 0
    }
    nodes.sort { wall($0.table) < wall($1.table) }
    let receipts = historyReceipts.split(separator: ",").compactMap { Int($0) }
    let results = historyResults.split(separator: ",").compactMap { Int($0) }
    guard !receipts.isEmpty, receipts.count == results.count,
      (receipts + results).allSatisfy({ $0 >= 0 && $0 < nodes.count })
    else {
      print(failures == 0 ? "HISTORY PROBE (round trips only) PASSED" : "HISTORY PROBE: \(failures) FAILURES")
      return
    }

    try? FileManager.default.removeItem(atPath: historyOut)
    do { try FileManager.default.copyItem(atPath: path, toPath: historyOut) } catch {
      print("cannot write \(historyOut): \(error)")
      return
    }
    var target: OpaquePointer?
    guard sqlite3_open_v2(historyOut, &target, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let copy = target else { return }
    defer { sqlite3_close(copy) }
    let names = NodeLayout.node.map { $0.name }
    for (receiptPosition, resultPosition) in zip(receipts, results) {
      let receipt = nodes[receiptPosition]
      let delivered = nodes[resultPosition]
      let fixed = HistoryCorrector.corrected(
        delivered: delivered.table, receipt: receipt.table, seed: nil, generationSeconds: 41.5)
      let before = HistoryCorrector.differences(delivered.table, receipt.table)
      check("node \(delivered.row.lineage)/\(delivered.row.logicalTime) intended node survives a round trip", HistoryCorrector.verify(fixed) == nil)
      let wrote = HistoryCorrector.replace(
        in: copy, lineage: delivered.row.lineage, logicalTime: delivered.row.logicalTime,
        expected: delivered.row.blob, with: HistoryCorrector.encode(fixed))
      check("node \(delivered.row.lineage)/\(delivered.row.logicalTime) written (compare and set)", wrote)
      let again = HistoryCorrector.replace(
        in: copy, lineage: delivered.row.lineage, logicalTime: delivered.row.logicalTime,
        expected: delivered.row.blob, with: HistoryCorrector.encode(fixed))
      check("a second write against the old bytes is refused", !again)
      let left = HistoryCorrector.differences(fixed, receipt.table)
      let leftOver = left.filter { !HistoryCorrector.kept.contains($0) && $0 != "generation_time" }
      check("only kept fields still differ from the receipt: \(left.joined(separator: ", "))", leftOver.isEmpty)
      print("        \(before.count) fields differed from the receipt before, \(left.count) now; before: \(before.filter { !HistoryCorrector.kept.contains($0) }.joined(separator: ", "))")
    }

    do {
      let sandbox = NSTemporaryDirectory() + "history-fixer-\(UUID().uuidString)"
      defer { try? FileManager.default.removeItem(atPath: sandbox) }
      let projects = sandbox + "/projects"
      let state = sandbox + "/state"
      try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
      let name = "Lab.sqlite3"
      let logger = Logger(label: "fixer")
      let locator = ProjectLocator(directory: projects, logger: logger)
      func makeItems() -> [HistoryFixer.Item] {
        zip(receipts, results).enumerated().map { index, pair in
          var seed: UInt32 = 0
          if case .scalar(let bits, _)? = nodes[pair.0].table[HistoryCorrector.slot("seed")] { seed = UInt32(bits) }
          return HistoryFixer.Item(
            code: "job\(index + 1)", runIndex: 1, images: 1, seed: seed, seconds: 41.5,
            receipt: ProjectLocator.NodeRef(lineage: nodes[pair.0].row.lineage, logicalTime: nodes[pair.0].row.logicalTime),
            receiptProject: name)
        }
      }
      let resultWall = Double(wall(nodes[results[0]].table)) / 1_000_000
      let sentAt = Date(timeIntervalSince1970: resultWall - 0.3)
      let closing = nodes.count - (results.max() ?? 0) - 1

      try FileManager.default.copyItem(atPath: path, toPath: projects + "/" + name)
      let careful = HistoryFixer(locator: locator, journalDirectory: state, logger: logger, delays: [0.2, 0.4])
      careful.expect(items: makeItems(), project: name, sentAt: sentAt, closing: closing + 2)
      Thread.sleep(forTimeInterval: 1.2)
      var db: OpaquePointer?
      sqlite3_open_v2(projects + "/" + name, &db, SQLITE_OPEN_READONLY, nil)
      let untouched = HistoryCorrector.rows(in: db!)
      sqlite3_close(db)
      check("a wrong number of nodes changes nothing", untouched.map { $0.blob } == rows.map { $0.blob })

      let fixer = HistoryFixer(locator: locator, journalDirectory: state, logger: logger, delays: [0.2, 0.4])
      fixer.expect(items: makeItems(), project: name, sentAt: sentAt, closing: closing)
      Thread.sleep(forTimeInterval: 1.2)
      sqlite3_open_v2(projects + "/" + name, &db, SQLITE_OPEN_READONLY, nil)
      let fixedRows = HistoryCorrector.rows(in: db!)
      sqlite3_close(db)
      let expectedRows = HistoryCorrector.rows(in: copy)
      check("the fixer's nodes equal those of the corrected copy, byte for byte", fixedRows.map { $0.blob } == expectedRows.map { $0.blob })

      let journal = (try? String(contentsOfFile: state + "/history-journal.jsonl", encoding: .utf8)) ?? ""
      let lines = journal.split(separator: "\n")
      check("the journal has one line per changed node: \(lines.count)", lines.count == results.count)
      var restored = 0
      sqlite3_open_v2(projects + "/" + name, &db, SQLITE_OPEN_READWRITE, nil)
      for line in lines {
        guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let old = object["old"] as? String, let new = object["new"] as? String,
          let lineage = (object["lineage"] as? NSNumber)?.int64Value, let logical = (object["logical"] as? NSNumber)?.int64Value,
          let oldData = Data(hexString: old), let newData = Data(hexString: new)
        else { continue }
        if HistoryCorrector.replace(in: db!, lineage: lineage, logicalTime: logical, expected: newData, with: oldData) { restored += 1 }
      }
      let undone = HistoryCorrector.rows(in: db!)
      sqlite3_close(db)
      check("the journal undoes the change: \(restored) nodes restored to the original bytes", undone.map { $0.blob } == rows.map { $0.blob })
    } catch {
      check("the fixer test could not run: \(error)", false)
    }

    check("every field name of the layout is unique", Set(names).count == names.count)
    let finalRows = HistoryCorrector.rows(in: copy)
    check("the copy still has \(rows.count) nodes: \(finalRows.count)", finalRows.count == rows.count)
    print("corrected copy: \(historyOut)")
    print(failures == 0 ? "HISTORY PROBE PASSED" : "HISTORY PROBE: \(failures) FAILURES")
  }

  func runResultsProbe() {
    LoggingSystem.bootstrap { label in
      var handler = StreamLogHandler.standardOutput(label: label)
      handler.logLevel = .info
      return handler
    }
    let logger = Logger(label: "probe")
    let base_dir = NSTemporaryDirectory() + "results-probe-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: base_dir) }
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
      if !ok { failures += 1 }
      print("\(ok ? "OK    " : "FAILED") \(name)")
    }
    func record(age: TimeInterval, group: Group) -> ResultStore.Record {
      let created = Date().addingTimeInterval(-age)
      return ResultStore.Record(
        id: UUID(), groupId: group.id, groupCode: group.code, groupKey: group.key, expected: 2,
        groupCreatedAt: group.createdAt, runIndex: 1, createdAt: created, startedAt: created,
        finishedAt: created, width: 512, height: 512, batchSize: 1, totalSteps: 4, model: "m",
        prompt: "p", seed: 7, imageCount: 1)
    }
    func response() -> ImageGenerationResponse {
      ImageGenerationResponse.with {
        $0.generatedImages = [Data([1, 2, 3, 4])]
        $0.chunkState = .lastChunk
      }
    }
    do {
      let store = try ResultStore(directory: base_dir, logger: logger)
      let group = Group(code: "TEST", key: "k", expected: 2)
      group.origin = Group.Origin(user: "Alex's iPhone", device: "phone", address: "192.0.2.77")
      let fresh = Job(group: group, restoring: record(age: 60, group: group), responses: [response()])
      let old = Job(group: group, restoring: record(age: 91 * 24 * 3600, group: group), responses: [response()])
      let gone = Job(group: group, restoring: record(age: 120, group: group), responses: [response()])
      group.add(fresh, at: Date())
      group.add(old, at: Date())
      group.add(gone, at: Date())
      store.save(fresh)
      store.save(old)
      store.save(gone)
      let listing = { (try? FileManager.default.contentsOfDirectory(atPath: base_dir + "/results")) ?? [] }
      check("three runs on disk, the old one is pruned when the next is saved: \(listing().count)", listing().count == 2 || listing().count == 3)
      store.remove(gone)
      check("a delivered run is erased at once: \(listing().count) left", !listing().contains(gone.id.uuidString))

      let marked = base_dir + "/results/" + fresh.id.uuidString
      FileManager.default.createFile(atPath: marked + "/delivered", contents: Data())
      let second = try ResultStore(directory: base_dir, logger: logger)
      let restored = second.load()
      check("a marked run is not restored, the old one is erased: \(restored.count) restored", restored.isEmpty)
      check("nothing is left on disk: \(listing().count)", listing().isEmpty)
      let again = Job(group: group, restoring: record(age: 30, group: group), responses: [response(), response()])
      second.save(again)
      let third = try ResultStore(directory: base_dir, logger: logger).load()
      check("a fresh run comes back with its responses", third.count == 1 && third[0].responses.count == 2 && third[0].responses[0].generatedImages == [Data([1, 2, 3, 4])] && third[0].record.seed == 7 && third[0].record.groupCode == "TEST")
      check("and with where it came from", third[0].record.origin == Group.Origin(user: "Alex's iPhone", device: "phone", address: "192.0.2.77"))
      check("the label is the name of the client, or the kind of device without one", Group.Origin(user: "Alex's iPhone", device: "phone", address: nil).label == "Alex's iPhone" && Group.Origin(user: "", device: "tablet", address: nil).label == "tablet")
    } catch {
      print("FAILED \(error)")
      failures += 1
    }

    do {
      let diskBase = base_dir + "-disk"
      defer { try? FileManager.default.removeItem(atPath: diskBase) }
      let store = try ResultStore(directory: diskBase, logger: logger)
      let appGroup = Group(code: "APP1", key: "k", expected: 1)
      let toolGroup = Group(code: "TOOL", key: "tracked-x", expected: 1)
      toolGroup.apply(Group.ToolInfo(source: "generate_image", client: "plugin", requestId: "r1", background: true, workdir: "/w"))
      func onDisk(_ group: Group, age: TimeInterval, parts: Int) -> Job {
        let rec = record(age: age, group: group)
        let payload = Payload(directory: store.spoolDirectory(for: rec.id))
        for _ in 0..<parts { payload.append(response()) }
        let job = Job(group: group, restoring: rec, payload: payload)
        group.add(job, at: Date())
        return job
      }
      let app = onDisk(appGroup, age: 10, parts: 3)
      let oldTool = onDisk(toolGroup, age: 50, parts: 4)
      let newTool = onDisk(toolGroup, age: 20, parts: 2)
      check("on disk: counted without reading", app.payload.isOnDisk && app.payload.completeImages == 3 && app.payload.imageCount == 3 && app.payload.isPresent)
      check("on disk: the last image is read from the last file", app.payload.lastCompleteImage() == Data([1, 2, 3, 4]))
      check("on disk: the images come one after the other", { () -> Bool in
        let sequence = app.payload.imageSequence()
        return (0..<3).allSatisfy { _ in sequence.nextImage() != nil } && sequence.nextImage() == nil
      }())
      for job in [app, oldTool, newTool] { store.save(job) }
      newTool.markDelivered()
      store.update(newTool)
      let entries = try ResultStore(directory: diskBase, logger: logger).loadEntries()
      check("restore: a call of a tool that the agent collected is erased with the start, the others come back with their counts, nothing read",
        entries.count == 2 && entries.first { $0.record.id == app.id }?.record.completeImages == 3 && !entries.contains { $0.record.id == newTool.id }
          && !FileManager.default.fileExists(atPath: diskBase + "/results/" + newTool.id.uuidString))
      check("restore: the tool that is not collected yet is a tool, and its state is kept", entries.first { $0.record.id == oldTool.id }.map { $0.record.tool?.source == "generate_image" && $0.record.delivered == false } == true)
      let freed = store.enforceBudget(10)
      check("budget: the oldest tool is freed first, the app result never", freed.first == oldTool.id && !freed.contains(app.id))
      let left = (try? FileManager.default.contentsOfDirectory(atPath: diskBase + "/results/" + oldTool.id.uuidString)) ?? []
      check("budget: its files are gone, its record stays: \(left.sorted())", left.contains("record.json") && !left.contains("0.pb"))
      let after = try ResultStore(directory: diskBase, logger: logger).loadEntries()
      check("budget: the freed row is restored as evicted", after.first { $0.record.id == oldTool.id }?.record.evicted == true && after.contains { $0.record.id == app.id })
      oldTool.payload.evict()
      check("budget: the freed payload is not there but counted", !oldTool.payload.isPresent && oldTool.payload.completeImages == 4)

      let kept = onDisk(Group(code: "APP2", key: "k2", expected: 1), age: 5, parts: 2)
      store.save(kept, keepDelivered: true)
      let handed = kept.takeResultsForDelivery(keepFiles: true)
      store.update(kept)
      check("delivery with the monitor open: the images are handed out and stay readable", handed?.count == 2 && kept.payload.isPresent && kept.payload.lastCompleteImage() != nil)
      check("delivery with the monitor open: never delivered twice", kept.takeResultsForDelivery(keepFiles: true) == nil && kept.undeliveredImageCount == 0)
      let restarted = try ResultStore(directory: diskBase, logger: logger).loadEntries()
      check("delivery with the monitor open: a start erases it, the undelivered result stays", !restarted.contains { $0.record.id == kept.id } && restarted.contains { $0.record.id == app.id })
      store.remove(app)
      check("delivery: an app result is erased", !FileManager.default.fileExists(atPath: diskBase + "/results/" + app.id.uuidString))
      store.erase(oldTool.id)
      check("remove: a tool row is erased with its files", !FileManager.default.fileExists(atPath: diskBase + "/results/" + oldTool.id.uuidString))
    } catch {
      print("FAILED results on disk: \(error)")
      failures += 1
    }

    do {
      let openBase = base_dir + "-open"
      defer { try? FileManager.default.removeItem(atPath: openBase) }
      let store = try ResultStore(directory: openBase, logger: logger)
      let group = Group(code: "k7f2", key: "k", expected: 1)
      let running = Job(group: group, restoring: record(age: 30, group: group), responses: [response()])
      let finished = Job(group: group, restoring: record(age: 20, group: group), responses: [response()])
      store.saveOpen(running)
      store.saveOpen(finished)
      let loaded = try ResultStore(directory: openBase, logger: logger).loadOpen(excluding: [finished.id])
      check("open runs: the lost one comes back, the one with a result on disk does not", loaded.count == 1 && loaded[0].id == running.id)
      let lost = Job(group: group, restoringFailed: loaded[0], message: "restarted")
      var failedText = ""
      if case .failed(let message) = lost.state { failedText = message }
      check("open runs: restored as failed and listed", failedText == "restarted" && lost.isListed && lost.undeliveredImageCount == 0)
      check("open runs: the failure counts as told once", lost.markFailureShown() && !lost.markFailureShown() && !lost.isListed)
      store.removeOpen(running.id)
      check("open runs: erased when told", (try? ResultStore(directory: openBase, logger: logger).loadOpen(excluding: []))?.contains { $0.id == running.id } == false)
    } catch {
      print("FAILED open runs: \(error)")
      failures += 1
    }

    do {
      var latent = Tensor<FloatType>(.CPU, .NHWC(1, 4, 4, 32))
      for index in 0..<(4 * 4 * 32) { latent[0, index / 128, (index / 32) % 4, index % 32] = FloatType(0) }
      let images = PreviewDecoder.images(fromLatent: latent, model: "qwen_image_2.1_q6p.ckpt")
      var expected = [UInt8]()
      for color in 0..<3 {
        let value = PreviewDecoder.flux2Projection[color][32]
        expected.append(UInt8(max(0, min(255, Int(value * 127.5 + 127.5)))))
      }
      var got = [UInt8](repeating: 0, count: 4)
      if let image = images.first, let data = image.dataProvider?.data {
        got = Array(CFDataGetBytePtr(data).map { UnsafeBufferPointer(start: $0, count: 4) } ?? UnsafeBufferPointer(start: nil, count: 0))
      }
      check("a 32-channel preview latent is decoded with the projection: \(got.prefix(3)) expected \(expected)", images.count == 1 && Array(got.prefix(3)) == expected && images[0].width == 4)
    }

    do {
      let model = "minimax_h3_fl2va_q6p.ckpt"
      var latent = Tensor<FloatType>(.CPU, .NHWC(12, 40, 16, 24))
      for frame in 0..<12 {
        for y in 0..<40 { for x in 0..<16 { for c in 0..<24 { latent[frame, y, x, c] = FloatType(0) } } }
        if frame < 6 { for y in 0..<40 { for x in 0..<16 { latent[frame, y, x, 9] = FloatType(-50) } } }
      }
      let all = PreviewDecoder.images(fromLatent: latent, model: model)
      let shown = PreviewDecoder.shown(fromLatent: latent, model: model, limit: 4)
      check("video preview: all 12 frames are decoded, the first six are black: \(all.count) frames, \(all.prefix(6).map { Int(PreviewDecoder.meanBrightness(of: $0)) })",
        all.count == 12 && all.prefix(6).allSatisfy { PreviewDecoder.meanBrightness(of: $0) < 2 })
      check("video preview: four frames are shown, none of them black: \(shown.map { Int(PreviewDecoder.meanBrightness(of: $0)) })",
        shown.count == 4 && shown.allSatisfy { PreviewDecoder.meanBrightness(of: $0) >= 2 })

      var argb = Tensor<FloatType>(.CPU, .NHWC(1, 2, 2, 4))
      for i in 0..<4 { argb[0, i / 2, i % 2, 0] = 1; argb[0, i / 2, i % 2, 1] = -1; argb[0, i / 2, i % 2, 2] = 1; argb[0, i / 2, i % 2, 3] = -1 }
      let argbImage = StatusImage.cgImage(from: argb)
      let argbBytes = argbImage?.dataProvider?.data.map { CFDataGetBytePtr($0) }.flatMap { $0 }
      check("a finished image of four channels (alpha, red, green, blue) keeps its colours: r g b = \(argbBytes.map { "\($0[0]) \($0[1]) \($0[2])" } ?? "-")",
        argbBytes.map { $0[0] == 0 && $0[1] == 255 && $0[2] == 0 } == true)
      var qwen = Tensor<FloatType>(.CPU, .NHWC(1, 6, 8, 64))
      for y in 0..<6 { for x in 0..<8 { for c in 0..<64 { qwen[0, y, x, c] = FloatType(Float(x) * 0.05 + Float(c) * 0.001) } } }
      let qwenImages = PreviewDecoder.images(fromLatent: qwen, model: "model_that_is_not_in_the_list.ckpt")
      func pixels(_ image: CGImage) -> Data { (image.dataProvider?.data as Data?) ?? Data() }
      let direct = PreviewDecoder.libraryImages(fromLatent: qwen, version: .qwenImage2_1)
      let asV1 = PreviewDecoder.libraryImages(fromLatent: qwen, version: .v1)
      check("qwen 2.1 preview (64 channels, unknown model name) is decoded as Qwen Image 2.1, not as SD 1",
        qwenImages.count == 1 && direct.count == 1 && asV1.count == 1

          && (qwenImages[0].width == 8 * 16 || pixels(qwenImages[0]) == pixels(direct[0]))
          && (qwenImages[0].width != 8 || pixels(qwenImages[0]) != pixels(asV1[0])))
      var batch = Tensor<FloatType>(.CPU, .NHWC(3, 8, 8, 16))
      for b in 0..<3 { for y in 0..<8 { for x in 0..<8 { for c in 0..<16 { batch[b, y, x, c] = FloatType(0) } } } }
      check("a batch is shown as it is, up to four", PreviewDecoder.shown(fromLatent: batch, model: "z_image_turbo_1.0_q6p.ckpt", limit: 4).count == 3)
    }

    for (prompt, expected) in [
      ("status", true), ("  Status \n", true), ("STATUS", true), ("status 9x", true), ("Status K7", true),
      ("status ab", true), ("status k7 please", false), ("statuses", false), ("a status", false),
      ("status all", false), ("status 9", false), ("status 9x3", false), ("status 9x39", false),
      ("status 9-", false), ("status ü1", false), ("cancel", false), ("cancel 9x", false),
      ("a girl in a red coat", false), ("", false),
    ] as [(String, Bool)] {
      check("status query \"\(prompt.trimmingCharacters(in: .whitespacesAndNewlines))\" -> \(ProxyService.isStatusQuery(prompt))", ProxyService.isStatusQuery(prompt) == expected)
    }

    do {
      let stateBase = base_dir + "-state"
      defer { try? FileManager.default.removeItem(atPath: stateBase) }
      let key = UUID()
      let lost = UUID()
      let first = try StateStore(directory: stateBase, logger: logger)
      _ = first.load()
      let named = [UUID(), UUID()]
      first.record(StateStore.Image(hash: Data([1, 2, 3, 4]), key: key, label: "ABCD", at: Date(), groups: named))
      first.record(StateStore.Project(key: key, project: "Untitled-1.sqlite3", confirmed: true, at: Date()))
      first.record(StateStore.Project(key: key, project: "Other.sqlite3", confirmed: false, at: Date()))
      first.record(StateStore.Project(key: lost, project: "Gone.sqlite3", confirmed: true, at: Date()))
      let second = try StateStore(directory: stateBase, logger: logger).load()
      check("state: image restored", second.images.count == 1 && second.images[0].hash == Data([1, 2, 3, 4]))
      check("state: the requests a status image names are restored", Set(second.images[0].groups) == Set(named))
      check("state: confirmed project kept, a guess does not replace it, project of an unknown image dropped", second.projects.count == 1 && second.projects[0].project == "Untitled-1.sqlite3" && second.projects[0].confirmed)

      let store = try StateStore(directory: stateBase, logger: logger)
      store.clear(keeping: StateStore.Image(hash: Data([7, 7]), key: key, label: "k7f2", at: Date(), groups: [named[0]]), project: nil)
      let after = try StateStore(directory: stateBase, logger: logger).load()
      check("state: erased but the latest status image, with its requests", after.images.count == 1 && after.images[0].hash == Data([7, 7]) && after.images[0].groups == [named[0]] && after.projects.isEmpty)
      store.clear(keeping: nil, project: nil)
      let empty = try StateStore(directory: stateBase, logger: logger).load()
      check("state: erased completely", empty.images.isEmpty && empty.projects.isEmpty)
    } catch {
      print("FAILED state: \(error)")
      failures += 1
    }
    print(failures == 0 ? "RESULTS PROBE PASSED" : "RESULTS PROBE: \(failures) FAILURES")
  }

  func runDeleteNodeProbe(_ source: String) {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
      if !ok { failures += 1 }
      print("\(ok ? "OK    " : "FAILED") \(name)")
    }
    let folder = NSTemporaryDirectory() + "delete-node-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: folder) }
    do { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) } catch { return }
    let path = folder + "/copy.sqlite3"
    guard (try? FileManager.default.copyItem(atPath: source, toPath: path)) != nil else {
      print("cannot copy \(source)")
      return
    }
    func count(_ table: String) -> Int {
      var handle: OpaquePointer?
      guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
      defer { sqlite3_close(handle) }
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else { return -1 }
      defer { sqlite3_finalize(statement) }
      return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : -1
    }
    let tables = ["tensorhistorynode", "tensorhistorynode__f86", "tensordata", "tensordata__f20", "thumbnailhistorynode", "thumbnailhistoryhalfnode", "tensors"]
    let before = tables.map(count)
    let undo = URL(fileURLWithPath: folder + "/undo.sql")
    let first = NodeDeleter.delete(project: path, lineage: 1, logicalTime: 3, newerBy: 0, undoFile: undo)
    var deleted = false
    if case .deleted = first { deleted = true }
    check("the node is deleted: \(first)", deleted)
    let after = tables.map(count)
    check("the node and its index row are gone", after[0] == before[0] - 1 && after[1] == before[1] - 1)
    check("its data, thumbnails and picture are gone: \(before) -> \(after)", after[2] < before[2] && after[4] == before[4] - 1 && after[5] == before[5] - 1 && after[6] < before[6])
    let again = NodeDeleter.delete(project: path, lineage: 1, logicalTime: 3, newerBy: 0, undoFile: undo)
    var skipped = false
    if case .skipped = again { skipped = true }
    check("a second deletion finds nothing", skipped)

    var handle: OpaquePointer?
    if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle,
      let sql = try? String(contentsOf: undo, encoding: .utf8)
    {
      let statements = sql.split(separator: "\n").filter { !$0.hasPrefix("--") }.joined(separator: "\n")
      check("the undo journal runs", sqlite3_exec(db, statements, nil, nil, nil) == SQLITE_OK)
      sqlite3_close(db)
    }
    check("the undo journal puts everything back: \(tables.map(count))", tables.map(count) == before)

    let strict = NodeDeleter.delete(project: path, lineage: 0, logicalTime: 109, newerBy: 100_000, undoFile: nil)
    var refused = false
    if case .skipped = strict { refused = true }
    check("a node is not deleted while the app may still show it: \(strict)", refused)
    print(failures == 0 ? "DELETE NODE PROBE PASSED" : "DELETE NODE PROBE: \(failures) FAILURES")
  }

  func runMonitorHistoryProbe(_ path: String) {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
      if !ok { failures += 1 }
      print("\(ok ? "OK    " : "FAILED") \(name)")
    }
    var source: OpaquePointer?
    guard sqlite3_open_v2(path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database = source else {
      print("cannot open \(path)")
      return
    }
    defer { sqlite3_close(database) }
    let states = TextStream.states(in: database)
    check("the prompt stream has points: \(states.count)", !states.isEmpty)
    guard let target = states.filter({ !$0.positive.isEmpty }).max(by: { ($0.lineage, $0.edits) < ($1.lineage, $1.edits) }) else {
      print("no prompt in the stream")
      return
    }
    print("        newest prompt: lineage \(target.lineage), edit \(target.edits): \"\(target.positive.prefix(60))\"")
    guard let node = HistoryCorrector.rows(in: database, newest: 1).first,
      let table = try? HistoryCorrector.decode(node.blob)
    else {
      print("no node")
      return
    }

    let configuration = GenerationConfiguration(
      id: 0, startWidth: 12, startHeight: 16, seed: 123_456_789, steps: 7, guidanceScale: 3.5,
      model: "probe_model_f16.ckpt", batchSize: 2, loras: [LoRA(file: "probe_lora.ckpt", weight: 0.4)])
    let blob = configuration.toData()
    do {
      let decoded = try HistoryCorrector.decodeConfiguration(blob)
      let pointer = TextStream.pointer(
        in: database, prompt: target.positive, negativePrompt: target.negative, current: nil)
      check("the point of the prompt is found: \(pointer.map { "\($0.lineage)/\($0.edits)" } ?? "none")", pointer != nil)
      let synthetic = HistoryCorrector.synthetic(
        delivered: table, configuration: decoded, prompt: target.positive, negativePrompt: target.negative, pointer: pointer)
      let fixed = HistoryCorrector.corrected(delivered: table, receipt: synthetic, seed: 987_654_321, generationSeconds: 12.5)
      check("the node survives a round trip", HistoryCorrector.verify(fixed) == nil)
      func scalar(_ name: String) -> UInt64? {
        if case .scalar(let bits, _)? = fixed[HistoryCorrector.slot(name)] { return bits }
        return nil
      }
      func text(_ name: String) -> String? {
        if case .bytes(let data)? = fixed[HistoryCorrector.slot(name)] { return String(decoding: data, as: UTF8.self) }
        return nil
      }
      check("seed is the one given", scalar("seed") == 987_654_321)
      check("steps are those of the request", scalar("steps") == 7)
      check("size is that of the request", scalar("start_width") == 12 && scalar("start_height") == 16)
      check("batch size is that of the request", scalar("batch_size") == 2)
      check("model is that of the request", text("model") == "probe_model_f16.ckpt")
      check("the prompt snapshot is the prompt", text("text_prompt") == target.positive)
      check("the stream point is the one found", pointer.map { scalar("text_lineage") == UInt64(bitPattern: $0.lineage) && scalar("text_edits") == UInt64(bitPattern: $0.edits) } ?? false)
      if case .tables(let loras)? = fixed[HistoryCorrector.slot("loras")] {
        check("one LoRA of the request", loras.count == 1)
      } else {
        check("one LoRA of the request", false)
      }
      check("the picture of the node is kept (tensor_id)", fixed[HistoryCorrector.slot("tensor_id")] == table[HistoryCorrector.slot("tensor_id")])
      let changed = HistoryCorrector.differences(table, fixed)
      print("        \(changed.count) fields differ from the node of the app: \(changed.joined(separator: ", "))")

      let none = TextStream.pointer(in: database, prompt: "a prompt that nobody typed \(UUID())", negativePrompt: "", current: nil)
      check("a prompt that is not in the stream has no point", none == nil)
    } catch {
      check("the probe could not run: \(error)", false)
    }
    print(failures == 0 ? "MONITOR HISTORY PROBE PASSED" : "MONITOR HISTORY PROBE: \(failures) FAILURES")
  }

  func runMonitorProbe() {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
      if !ok { failures += 1 }
      print("\(ok ? "OK    " : "FAILED") \(name)")
    }
    let path = NSTemporaryDirectory() + "monitor-probe-\(Int(Date().timeIntervalSince1970)).sock"
    defer { unlink(path) }
    let logger = Logger(label: "probe")
    let hub = MonitorHub(path: path, logger: logger)
    let received = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var commands = [[String: Any]]()
    var changes = [Bool]()
    hub.snapshotProvider = { ["jobs": [["code": "k7", "state": "running"]], "project": "Probe"] }
    hub.onCommand = { command in
      lock.withLock { commands.append(command) }
      received.signal()
    }
    hub.onChange = { active in lock.withLock { changes.append(active) } }
    do { try hub.start() } catch {
      print("FAILED start: \(error)")
      return
    }
    check("no monitor, no monitor mode", !hub.isActive)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        _ = path.withCString { strncpy(destination, $0, capacity - 1) }
      }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    check("monitor connects", connected == 0)
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    func lines(minimum: Int) -> [[String: Any]] {
      while buffer.filter({ $0 == 0x0A }).count < minimum {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer.append(chunk, count: n)
      }
      return buffer.split(separator: 0x0A).compactMap {
        try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
      }
    }
    let first = lines(minimum: 2)
    check("hello and state arrive", first.first?["type"] as? String == "hello" && first.contains { $0["type"] as? String == "state" })
    check("monitor mode is on", hub.isActive)
    let state = first.first { $0["type"] as? String == "state" }
    check("state carries the jobs and the project", (state?["jobs"] as? [[String: Any]])?.first?["code"] as? String == "k7" && state?["project"] as? String == "Probe")
    hub.broadcast(["type": "event", "kind": "accepted", "code": "k7"])
    let event = lines(minimum: 3).contains { $0["kind"] as? String == "accepted" }
    check("event arrives", event)
    let command = "{\"cmd\":\"cancel\",\"code\":\"k7\"}\n{\"cmd\":\"cancelAll\"}\n"
    _ = command.withCString { write(fd, $0, strlen($0)) }
    check("commands arrive", received.wait(timeout: .now() + 3) == .success && received.wait(timeout: .now() + 3) == .success)
    check("the commands are the ones sent", lock.withLock { commands.map { $0["cmd"] as? String } } == ["cancel", "cancelAll"])

    func stateCount() -> Int { buffer.split(separator: 0x0A).filter { $0.starts(with: Data("{\"jobs\"".utf8)) || String(decoding: $0, as: UTF8.self).contains("\"type\":\"state\"") }.count }
    var tv2 = timeval(tv_sec: 0, tv_usec: 300_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv2, socklen_t(MemoryLayout<timeval>.size))
    let statesBefore = stateCount()
    let end = Date().addingTimeInterval(1.6)
    while Date() < end {
      let n = read(fd, &chunk, chunk.count)
      if n > 0 { buffer.append(chunk, count: n) }
    }
    check("an unchanged state is not sent again: \(stateCount() - statesBefore) more", stateCount() == statesBefore)

    let fd2 = socket(AF_UNIX, SOCK_STREAM, 0)
    _ = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd2, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    var tv3 = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd2, SOL_SOCKET, SO_RCVTIMEO, &tv3, socklen_t(MemoryLayout<timeval>.size))
    var second = Data()
    var chunk2 = [UInt8](repeating: 0, count: 4096)
    while second.filter({ $0 == 0x0A }).count < 2 {
      let n = read(fd2, &chunk2, chunk2.count)
      if n <= 0 { break }
      second.append(chunk2, count: n)
    }
    check("a second monitor gets hello and the state", String(decoding: second, as: UTF8.self).contains("\"hello\"") && String(decoding: second, as: UTF8.self).contains("\"k7\""))
    check("a second monitor does not start the monitor mode again", lock.withLock { changes } == [true])
    close(fd2)
    Thread.sleep(forTimeInterval: 0.3)
    check("and does not end it when it goes", hub.isActive && lock.withLock { changes } == [true])
    close(fd)
    var off = false
    for _ in 0..<30 where !off {
      Thread.sleep(forTimeInterval: 0.1)
      off = !hub.isActive
    }
    check("monitor mode ends with the monitor", off)
    check("changes were reported: on, then off", lock.withLock { changes } == [true, false])
    hub.stop()
    print(failures == 0 ? "MONITOR PROBE PASSED" : "MONITOR PROBE FAILED (\(failures))")
  }

  func runWatermarkProbe() {
    func model(progress: Double, label: String) -> StatusModel {
      StatusModel(
        note: nil,
        tables: [
          .init(
            project: "Untitled-1",
            groups: [
              .init(
                code: "abcd", batchSize: 1, steps: 8, isCurrent: true,
                batches: [.init(state: .running, step: 3, eta: 12)], project: "Untitled-1")
            ]),
          .init(
            project: "high fashion photo",
            groups: [
              .init(
                code: "k7f2", batchSize: 4, steps: 16, isCurrent: false,
                batches: [
                  .init(state: .done, step: nil, eta: nil), .init(state: .running, step: 5, eta: 40),
                  .init(state: .pending, step: nil, eta: 95), .init(state: .pending, step: nil, eta: 150),
                ], project: "high fashion photo")
            ]),
        ], progress: progress, barLabel: label, barTime: "00:03 / 00:08 est.")
    }
    var failures = 0
    func check(_ name: String, _ value: Bool, expected: Bool) {
      let ok = value == expected
      if !ok { failures += 1 }
      print("\(ok ? "OK    " : "FAILED") \(name): detected=\(value) expected=\(expected)")
    }
    var preview: CGImage? = nil
    do {
      let space = CGColorSpaceCreateDeviceRGB()
      let ctx = CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
      preview = ctx.makeImage()
    }
    for (w, h) in [(768, 960), (1024, 1024), (640, 640), (1536, 1024), (512, 768), (320, 400)] {
      for progress in [0.0, 0.1, 0.5, 1.0] {
        for withPreview in [false, true] {
          guard
            let tensor = StatusImage.render(
              model: model(progress: progress, label: "Sampling… 3 / 8"),
              preview: withPreview ? preview : nil, width: w, height: h)
          else {
            print("FAILED render \(w)x\(h)")
            failures += 1
            continue
          }
          check(
            "\(w)x\(h) progress \(progress) preview \(withPreview)",
            StatusImage.hasWatermark(tensor), expected: true)
          if progress == 0.1, !withPreview, let png = StatusImage.pngData(from: tensor),
            let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
          {
            _ = image
            check("  after PNG: re-read", StatusImage.hasWatermarkInPNG(png), expected: true)
          }
        }
      }
    }

    var gradient: CGImage? = nil
    do {
      let ctx = CGContext(
        data: nil, width: 96, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      let colors = [CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)] as CFArray
      let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
      ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 96, y: 128), options: [])
      gradient = ctx.makeImage()
    }
    let detail = StatusModel.Detail(
      code: "k7f2",
      fields: [
        ("Prompt", "High fashion photo of a young woman in her early 20s, Mongolian, continental Central Asian phenotype, with an expression of total boredom and vacancy. Harsh warm summer sunlight from above."),
        ("Size", "960\u{00D7}1280"), ("Model", "qwen_image_2.1_turbo_q6p.ckpt"), ("Mode", "edit"), ("Steps", "8"),
        ("Batch Size", "1"), ("Batches", "4 (1 generated, 1 running, 2 pending)"), ("Seed", "175308301"),
        ("Elapsed", "26:59"), ("ETA", "1:47:06"), ("Project", "high fashion photo"),
      ])
    let detailModel = StatusModel(
      info: "Cancelled 2 batches of k7f2", detail: detail, note: nil, tables: [], progress: 0.25,
      barLabel: "Sampling… 3 / 16", barTime: "26:59 / 2:14:05 est.")
    for (w, h) in [(960, 1280), (768, 960), (640, 640)] {
      if let tensor = StatusImage.render(model: detailModel, preview: gradient, width: w, height: h) {
        check("detail view \(w)x\(h) with preview", StatusImage.hasWatermark(tensor), expected: true)
        if w == 960, let png = StatusImage.pngData(from: tensor) { try? png.write(to: URL(fileURLWithPath: "/tmp/wm-detail.png")) }
      }
    }
    var tableModel = model(progress: 0.3, label: "Processing…")
    tableModel.info = "Cancelled 1 batch of k7f2"
    if let tensor = StatusImage.render(model: tableModel, preview: nil, width: 960, height: 1280) {
      check("table with answer line", StatusImage.hasWatermark(tensor), expected: true)
      if let png = StatusImage.pngData(from: tensor) { try? png.write(to: URL(fileURLWithPath: "/tmp/wm-table.png")) }
    }

    func many(_ code: String, _ count: Int) -> StatusModel.GroupBlock {
      .init(
        code: code, batchSize: 2, steps: 8, isCurrent: false,
        batches: (0..<count).map { .init(state: $0 < 2 ? .done : .pending, step: nil, eta: Double($0) * 30) },
        project: nil)
    }
    var crowded = model(progress: 0.5, label: "Sampling… 4 / 8")
    crowded.tables = [
      .init(project: "Untitled-1", groups: [many("aaaa", 30), many("bbbb", 12), many("cccc", 3)]),
      .init(project: "high fashion photo", groups: [many("dddd", 25), many("eeee", 8)]),
      .init(project: "Untitled-22171", groups: [many("ffff", 6)]),
    ]
    if let tensor = StatusImage.render(model: crowded, preview: nil, width: 960, height: 1280) {
      check("crowded tables", StatusImage.hasWatermark(tensor), expected: true)
      if let png = StatusImage.pngData(from: tensor) { try? png.write(to: URL(fileURLWithPath: "/tmp/wm-many.png")) }
    }

    var phone = model(progress: 0.3, label: "Sampling… 7 / 20")
    phone.tables = [
      .init(
        project: "Untitled-1",
        groups: [
          .init(
            code: "k7", batchSize: 2, steps: 20, isCurrent: true,
            batches: [
              .init(state: .done, step: nil, eta: nil),
              .init(state: .running, step: 7, eta: 125, phase: .sampling),
              .init(state: .pending, step: nil, eta: 190),
            ], project: nil),
          .init(
            code: "9x", batchSize: 1, steps: 8, isCurrent: false,
            batches: [.init(state: .pending, step: nil, eta: 42)], project: nil),
          .init(
            code: "m3", batchSize: 1, steps: 8, isCurrent: false,
            batches: [.init(state: .done, step: nil, eta: nil)], project: nil),
          .init(
            code: "bd", batchSize: 1, steps: 8, isCurrent: false,
            batches: [.init(state: .running, step: nil, eta: nil, phase: .processing)], project: nil),
        ]),
      .init(project: "high fashion photo", groups: [many("ab", 4)]),
    ]
    phone.compact = true
    for (name, w, h) in [("phone", 768, 1024), ("phone-small", 512, 640)] {
      if let tensor = StatusImage.render(model: phone, preview: nil, width: w, height: h) {
        check("compact table \(w)x\(h)", StatusImage.hasWatermark(tensor), expected: true)
        if let png = StatusImage.pngData(from: tensor) { try? png.write(to: URL(fileURLWithPath: "/tmp/wm-\(name).png")) }
      }
    }

    do {
      var picture = Tensor<FloatType>(.CPU, .NHWC(1, 640, 480, 3))
      picture.withUnsafeMutableBytes { raw in
        let p = raw.baseAddress!.assumingMemoryBound(to: FloatType.self)
        for y in 0..<640 {
          for x in 0..<480 {
            let i = (y * 480 + x) * 3
            p[i] = FloatType(Float(x) / 240 - 1)
            p[i + 1] = FloatType(Float(y) / 320 - 1)
            p[i + 2] = FloatType(0.3)
          }
        }
      }
      let response = ImageGenerationResponse.with {
        $0.generatedImages = [picture.data(using: [.zip, .fpzip])]
        $0.chunkState = .lastChunk
      }

      let whole = picture.data(using: [.zip, .fpzip])
      let cut = [0, whole.count / 3, 2 * whole.count / 3, whole.count]
      let pieces = (0..<3).map { whole[cut[$0]..<cut[$0 + 1]] }
      let chunked = pieces.enumerated().map { index, piece in
        ImageGenerationResponse.with {
          $0.generatedImages = [Data(piece)]
          $0.chunkState = index == 2 ? .lastChunk : .moreChunks
        }
      }
      let joined = ProxyService.completeImagePayloads(of: chunked)
      check("chunked image: three pieces make one payload of the original size: \(joined.map { $0.count })", joined.count == 1 && joined[0] == whole, expected: true)
      let fromChunks = ProxyService.lastDeliveredImage(chunked)
      check("chunked image decodes to \(fromChunks.map { "\($0.width)x\($0.height)" } ?? "none")", fromChunks?.width == 480 && fromChunks?.height == 640, expected: true)
      let unfinished = ProxyService.lastDeliveredImage(Array(chunked.prefix(2)))
      check("pieces without the last one give no image (and no decode)", unfinished == nil, expected: true)
      let garbage = ProxyService.completeImagePayloads(of: [
        ImageGenerationResponse.with { $0.generatedImages = [Data([9, 9, 9])]; $0.chunkState = .moreChunks }
      ])
      check("an unfinished piece alone gives no payload", garbage.isEmpty, expected: true)
      let twoImages = ProxyService.completeImagePayloads(of: chunked + [
        ImageGenerationResponse.with { $0.generatedImages = [whole]; $0.chunkState = .lastChunk }
      ])
      check("a chunked image followed by a whole one: two payloads", twoImages.count == 2 && twoImages.allSatisfy { $0 == whole }, expected: true)
      let image = ProxyService.lastDeliveredImage([response])
      check("delivered image decoded from the response: \(image.map { "\($0.width)x\($0.height)" } ?? "none")", image?.width == 480 && image?.height == 640, expected: true)
      let delivered = StatusModel(
        info: nil, note: nil,
        tables: [
          .init(
            project: "Proxy-1",
            groups: [
              .init(
                code: "mcby", batchSize: 1, steps: 8, isCurrent: false,
                batches: [.init(state: .delivered, step: nil, eta: nil), .init(state: .delivered, step: nil, eta: nil)],
                project: "Proxy-1")
            ])
        ], progress: 1, barLabel: "Delivered", barTime: "00:41")
      if let tensor = StatusImage.render(model: delivered, preview: image, width: 960, height: 1280) {
        check("delivery with backdrop", StatusImage.hasWatermark(tensor), expected: true)
        if let png = StatusImage.pngData(from: tensor) { try? png.write(to: URL(fileURLWithPath: "/tmp/wm-delivered.png")) }
      }
    }

    let idle = StatusModel(note: nil, tables: [.init(project: "Untitled-1", groups: [])], progress: 1, barLabel: "No running jobs", barTime: "")
    if let tensor = StatusImage.render(model: idle, preview: nil, width: 768, height: 960) {
      check("idle status image", StatusImage.hasWatermark(tensor), expected: true)
      if let png = StatusImage.pngData(from: tensor) { try? png.write(to: URL(fileURLWithPath: "/tmp/wm-idle.png")) }
    }

    for (name, value) in [("white", Float(1)), ("black", Float(-1)), ("grey", Float(0))] {
      var t = Tensor<FloatType>(.CPU, .NHWC(1, 960, 768, 3))
      t.withUnsafeMutableBytes { raw in
        let p = raw.baseAddress!.assumingMemoryBound(to: FloatType.self)
        for i in 0..<(960 * 768 * 3) { p[i] = FloatType(value) }
      }
      check("negative \(name)", StatusImage.hasWatermark(t), expected: false)
    }
    var noise = Tensor<FloatType>(.CPU, .NHWC(1, 960, 768, 3))
    noise.withUnsafeMutableBytes { raw in
      let p = raw.baseAddress!.assumingMemoryBound(to: FloatType.self)
      for i in 0..<(960 * 768 * 3) { p[i] = FloatType(Float.random(in: -1...1)) }
    }
    check("negative noise", StatusImage.hasWatermark(noise), expected: false)
    print(failures == 0 ? "WATERMARK PROBE PASSED" : "WATERMARK PROBE: \(failures) FAILURES")
  }

  func runProjectProbe() {
    let logger = Logger(label: "probe")
    let locator = ProjectLocator(directory: projectsDirectory, logger: logger)
    let all = locator.candidates()
    print("open in Draw Things: \(locator.openProjectNames().map { $0.isEmpty ? "none" : $0.joined(separator: ", ") } ?? "cannot be told")")
    print("best guess now: \(locator.bestGuess() ?? "none")  (newest write: \(all.first?.name ?? "none"))")
    print("Directory: \(projectsDirectory), \(all.count) projects, newest first:")
    for candidate in all.prefix(4) {
      print("  \(candidate.name)  last write \(candidate.activity)")
    }
    guard let candidate = all.first else {
      print("No project found.")
      return
    }
    let files = [candidate.path, candidate.path + "-wal", candidate.path + "-shm"]
    func snapshot() -> [String: FileTimes] {
      var result = [String: FileTimes]()
      for file in files + [projectsDirectory] { if let t = FileTimes.of(file) { result[file] = t } }
      return result
    }
    let before = snapshot()
    for (file, times) in before.sorted(by: { $0.key < $1.key }) {
      print("before  \((file as NSString).lastPathComponent): \(times.description)")
    }
    let started = Date()
    let nodes = locator.newestNodes(of: candidate, limit: 5)
    print("read \(nodes.count) nodes in \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms")
    for node in nodes {
      print(
        "  node \(node.rowid): lineage \(node.lineage) logical \(node.logicalTime) wallClock \(node.wallClockMicros) (\(node.wallClock)) seed \(node.seed) steps \(node.steps) model \(node.model) size \(node.startWidth)x\(node.startHeight) batch \(node.batchSize) preview \(node.previewId)"
      )
    }

    if let newest = nodes.first {
      let probe = ProjectLocator.Probe(
        groupId: UUID(), sentAt: newest.wallClock.addingTimeInterval(-1), seeds: [newest.seed],
        model: newest.model, steps: Int(newest.steps))
      let started = Date()
      let (found, description) = locator.resolve(probe)
      print("matching test (probe 1 s before node \(newest.rowid)): \(description) [\(found?.quality == .confirmed ? "OK" : "NOT CONFIRMED")] in \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms")

      let wrong = ProjectLocator.Probe(
        groupId: UUID(), sentAt: newest.wallClock.addingTimeInterval(-1), seeds: [newest.seed &+ 1],
        model: newest.model, steps: Int(newest.steps))
      let (wrongFound, wrongDescription) = locator.resolve(wrong)
      print("negative test (other seed): \(wrongDescription) [\(wrongFound?.quality == .confirmed ? "WRONGLY CONFIRMED" : "OK")]")
    }
    let after = snapshot()
    var unchanged = true
    for (file, times) in before {
      guard let now = after[file] else { unchanged = false; continue }
      let same = (times == now)
      if !same { unchanged = false }
      print("after   \((file as NSString).lastPathComponent): \(now.description)  \(same ? "mtime/ctime/size unchanged" : "CHANGED")")
    }
    for file in after.keys where before[file] == nil {
      print("after   \((file as NSString).lastPathComponent): appeared")
      unchanged = false
    }
    print(unchanged ? "RESULT: mtime, ctime and size of the project files and of the directory are unchanged." : "RESULT: SOMETHING CHANGED.")
  }
}

extension ProxyCommand {
  func runSaveProbe() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("save-probe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    func frame(_ shade: Float) -> Tensor<FloatType> {
      var tensor = Tensor<FloatType>(.CPU, .NHWC(1, 64, 96, 3))
      for y in 0..<64 { for x in 0..<96 { for c in 0..<3 {
        tensor[0, y, x, c] = FloatType(max(-1, min(1, shade + Float(x) / 96 - Float(c) * 0.3)))
      } } }
      return tensor
    }
    func response(images: [Tensor<FloatType>], audio: [Tensor<Float>] = []) -> ImageGenerationResponse {
      ImageGenerationResponse.with {
        $0.generatedImages = images.map { $0.data(using: [.zip, .fpzip]) }
        $0.generatedAudio = audio.map { $0.data(using: [.zip, .fpzip]) }
        $0.chunkState = .lastChunk
      }
    }
    var failures = 0
    func check(_ what: String, _ ok: Bool, _ detail: String = "") {
      print("\(ok ? "ok  " : "FAIL") \(what) \(detail)")
      if !ok { failures += 1 }
    }
    do {
      let one = [response(images: [frame(-0.5)])]
      let files = try MediaSaver.save(responses: one, model: "", video: false, name: "one.png", directory: directory)
      check("one image", files.count == 1 && files[0].lastPathComponent == "one.png" && FileManager.default.fileExists(atPath: files[0].path))

      let configuration = GenerationConfiguration(
        id: 7, startWidth: 12, startHeight: 16, seed: 42, steps: 8, guidanceScale: 1.5, strength: 1,
        model: "flux_2_klein_9b_q6p.ckpt", sampler: .uniPCTrailing, seedMode: .scaleAlike,
        loras: [LoRA(file: "my_lora_f16.ckpt", weight: 0.8, mode: .all)], shift: 3)
      let info = PNGMetadata.Info(
        prompt: "a red <fox> & \"friends\"", negativePrompt: "blurry", configuration: configuration, seed: 42,
        width: 96, height: 64, createdAt: Date(timeIntervalSince1970: 1_793_000_000.123))
      let withMeta = try MediaSaver.save(
        responses: one, model: "", video: false, name: "meta.png", directory: directory,
        xmp: { _, _, _ in PNGMetadata.xmp(info) })
      let png = try Data(contentsOf: withMeta[0])
      let text = String(decoding: png, as: UTF8.self)
      check("the PNG still decodes", CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil)
      check("it carries the XMP chunk", text.contains("XML:com.adobe.xmp") && text.contains("xmp:CreatorTool>gRPCServerProxy<"))
      check("with the prompt escaped and the description", text.contains("a red &lt;fox&gt; &amp; &quot;friends&quot;") && text.contains("Negative prompt: blurry") && text.contains("Sampler: UniPC Trailing") && text.contains("Seed Mode: Scale Alike") && text.contains("LoRA 1 Model: my_lora_f16.ckpt, LoRA 1 Weight: 0.8"))
      if let comment = text.range(of: "<exif:UserComment>"),
        let start = text.range(of: "<rdf:li xml:lang=\"x-default\">", range: comment.upperBound..<text.endIndex),
        let end = text.range(of: "</rdf:li>", range: start.upperBound..<text.endIndex)
      {
        let json = String(text[start.upperBound..<end.lowerBound])
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let v2 = object?["v2"] as? [String: Any]
        check("the user comment holds the prompt, the seed and the whole configuration as v2",
          object?["c"] as? String == "a red <fox> & \"friends\"" && object?["seed"] as? Int == 42 && object?["generated_by"] as? String == "gRPCServerProxy"
            && v2?["width"] as? Int == 768 && v2?["height"] as? Int == 1024 && v2?["steps"] as? Int == 8 && v2?["model"] as? String == "flux_2_klein_9b_q6p.ckpt"
            && (v2?["loras"] as? [[String: Any]])?.first?["weight"] as? Double == 0.8 && v2?["guidanceScale"] as? Double == 1.5 && v2?["shift"] as? Double == 3,
          "\(v2?.count ?? 0) fields")
      } else {
        check("the user comment is there", false)
      }
      let batch = [response(images: [frame(-0.5), frame(0)])]
      let many = try MediaSaver.save(responses: batch, model: "", video: false, name: "two.png", directory: directory)
      check("image batch without a number in its name gets -1, -2", many.map { $0.lastPathComponent } == ["two-1.png", "two-2.png"], "\(many.map { $0.lastPathComponent })")
      let three = [response(images: [frame(-0.5), frame(0), frame(0.5)])]
      let counted = try MediaSaver.save(responses: three, model: "", video: false, name: "image-20261110T083540377Z-es1.png", directory: directory)
      check("a batch of three is counted on from the number of its name like the tools name their images",
        counted.map { $0.lastPathComponent } == ["image-20261110T083540377Z-es1.png", "image-20261110T083540377Z-es2.png", "image-20261110T083540377Z-es3.png"],
        "\(counted.map { $0.lastPathComponent })")

      let order = Group(code: "es", key: "k", expected: 2)
      func run(_ index: Int) -> Job {
        let record = ResultStore.Record(
          id: UUID(), groupId: order.id, groupCode: "es", groupKey: "k", expected: 2, groupCreatedAt: order.createdAt,
          runIndex: index, createdAt: Date(), startedAt: Date(), finishedAt: Date(), width: 64, height: 64, batchSize: 3,
          totalSteps: 4, model: "m", prompt: "p", seed: 7, imageCount: 3)
        let job = Job(group: order, restoring: record, responses: [])
        job.runIndex = index
        return job
      }
      check("Save as… suggests …-es1 for the first run and …-es4 for the second run of a Batch Size 3",
        ProxyService.saveName(of: run(1)).hasSuffix("-es1") && ProxyService.saveName(of: run(2)).hasSuffix("-es4"),
        "\(ProxyService.saveName(of: run(1))) \(ProxyService.saveName(of: run(2)))")
      check("the second run of a Batch Size 3 starts at 4 and numbers keep their zeros",
        MediaSaver.outputPaths(base: URL(fileURLWithPath: "/x/image-t-es4.png"), count: 3).map { ($0 as NSString).lastPathComponent } == ["image-t-es4.png", "image-t-es5.png", "image-t-es6.png"]
          && MediaSaver.numberedStem("shot007", index: 2) == "shot009" && MediaSaver.numberedStem("a9", index: 1) == "a10", "")
      var sound = Tensor<Float>(.CPU, .NC(2, 24_000))
      for i in 0..<24_000 { sound[0, i] = sin(Float(i) * 0.05) * 0.3; sound[1, i] = sin(Float(i) * 0.07) * 0.3 }
      let clip = [response(images: (0..<12).map { frame(Float($0) / 12 - 0.5) }), response(images: [], audio: [sound])]
      check("clip is a video", MediaSaver.isVideo(responses: clip, configuration: nil, model: ""))
      check("image is no video", !MediaSaver.isVideo(responses: one, configuration: nil, model: ""))
      for ext in ["mp4", "mov"] {
        let made = try MediaSaver.save(responses: clip, model: "ltx_2.3_22b_distilled_q6p.ckpt", video: true, name: "clip.\(ext)", directory: directory)
        let size = (try? FileManager.default.attributesOfItem(atPath: made[0].path)[.size] as? Int) ?? 0
        check("clip .\(ext)", size > 1000, "\(size) bytes")
        let codec = AVURLAsset(url: made[0]).tracks(withMediaType: .video).first
          .flatMap { $0.formatDescriptions.first }
          .map { CMFormatDescriptionGetMediaSubType($0 as! CMFormatDescription) }
        let expected = ext == "mov" ? kCMVideoCodecType_AppleProRes4444 : kCMVideoCodecType_H264
        check("clip .\(ext) is \(ext == "mov" ? "ProRes 4444" : "H.264")", codec == expected, "\(codec.map { String($0, radix: 16) } ?? "none")")
      }
      do {
        _ = try MediaSaver.save(responses: one, model: "", video: false, name: "x.mp4", directory: directory)
        check("image as video is refused", false)
      } catch { check("image as video is refused", true, "\(error)") }
    } catch {
      check("saving", false, "\(error)")
    }
    print(failures == 0 ? "all ok" : "\(failures) FAILED")
    Foundation.exit(failures == 0 ? 0 : 1)
  }
}

extension ProxyCommand {
  func runCompareConfigs(_ directory: String) {
    let logger = Logger(label: "compare")
    guard let store = try? ResultStore(directory: directory, logger: logger) else {
      print("cannot open \(directory)")
      return
    }
    let items = store.load().map { $0.record }.sorted { $0.createdAt < $1.createdAt }
    var tables = [(code: String, table: NodeTable)]()
    for record in items {
      guard let blob = record.configuration, let table = try? HistoryCorrector.decodeConfiguration(blob) else {
        print("\(record.groupCode): configuration cannot be read")
        continue
      }
      tables.append((record.groupCode + "/\(record.runIndex)", table))
      let key = ProxyService.orderKey(
        prompt: record.prompt, negativePrompt: record.negativePrompt ?? "", configuration: blob, hasMask: false, hintTypes: [])
      print("\(record.groupCode) run \(record.runIndex) \(record.origin?.user ?? "app") key \(key.key.suffix(60)) fields \(table.count)")
    }
    func describe(_ table: NodeTable, _ slot: Int) -> String {
      guard let value = table[slot] else { return "(absent)" }
      switch value {
      case .scalar(let bits, let size): return "s\(size):\(bits)"
      case .bytes(let data): return "bytes(\(data.count))"
      case .strings(let items): return "strings(\(items.count))"
      case .tables(let items): return "tables(\(items.count))"
      }
    }
    guard let first = tables.first else { return }
    for other in tables.dropFirst() {
      var diffs = [String]()
      let slots = Set(first.table.keys).union(other.table.keys).sorted()
      for slot in slots where slot < NodeLayout.configuration.count {
        let a = describe(first.table, slot), b = describe(other.table, slot)
        if a != b { diffs.append("\(NodeLayout.configuration[slot].name): \(a) -> \(b)") }
      }
      print("\(first.code) vs \(other.code): \(diffs.isEmpty ? "same" : diffs.joined(separator: "; "))")
    }
  }
}
