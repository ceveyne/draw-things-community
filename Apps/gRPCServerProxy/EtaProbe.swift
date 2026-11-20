import DataModels
import FlatBuffers
import Foundation
import GRPCImageServiceModels

extension ProxyCommand {

  func runEtaProbe() {
    var failures = 0
    func check(_ what: String, _ ok: Bool, _ detail: String = "") {
      print("\(ok ? "ok  " : "FAIL") \(what) \(detail)")
      if !ok { failures += 1 }
    }
    func request(steps: UInt32) -> ImageGenerationRequest {
      var fbb = FlatBufferBuilder()
      let model = fbb.create(string: "m.ckpt")
      let root = zzz_DflatGen_GenerationConfiguration.createGenerationConfiguration(
        &fbb, startWidth: 8, startHeight: 8, seed: 1, steps: steps, modelOffset: model)
      fbb.finish(offset: root)
      return ImageGenerationRequest.with { $0.configuration = Data(fbb.sizedByteArray) }
    }
    func signpost(_ build: (inout ImageGenerationSignpostProto) -> Void) -> ImageGenerationSignpostProto {
      var proto = ImageGenerationSignpostProto()
      build(&proto)
      return proto
    }
    func sampling(_ step: Int32) -> ImageGenerationSignpostProto {
      signpost { $0.sampling = .with { $0.step = step } }
    }
    func secondPass(_ step: Int32) -> ImageGenerationSignpostProto {
      signpost { $0.secondPassSampling = .with { $0.step = step } }
    }
    func message(_ current: ImageGenerationSignpostProto, announced: [ImageGenerationSignpostProto]) -> ImageGenerationResponse {
      ImageGenerationResponse.with {
        $0.currentSignpost = current
        $0.signposts = announced
      }
    }

    SessionTimings.shared.reset()
    let group = Group(code: "eta", key: "k", expected: 1)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    let announced = [signpost { $0.textEncoded = .init() }, signpost { $0.imageDecoded = .init() }, sampling(12)]
    let first = Job(group: group, request: request(steps: 20))
    first.consume(message(signpost { $0.textEncoded = .init() }, announced: announced), at: at(0))
    check("no steps and no time while loading", first.snapshot(now: at(1)).etaSeconds == nil)
    first.consume(message(sampling(0), announced: announced), at: at(5))
    first.consume(message(sampling(1), announced: announced), at: at(25))
    check("no time after the first step", first.snapshot(now: at(25)).etaSeconds == nil)
    first.consume(message(sampling(2), announced: announced), at: at(35))
    var snapshot = first.snapshot(now: at(35))
    check("the step count is the announced one", snapshot.totalSteps == 12, "\(snapshot.totalSteps)")
    check("the first step (warm-up) is not in the average: 10 s * 10 steps + half a step", snapshot.etaSeconds == 105, "\(String(describing: snapshot.etaSeconds))")
    first.consume(message(sampling(11), announced: announced), at: at(125))
    first.consume(message(sampling(12), announced: announced), at: at(135))
    snapshot = first.snapshot(now: at(140))
    check("the last step stays Step 12/12 while it decodes", snapshot.stage == .sampling && snapshot.step == 12)
    check("with no decoding measured yet, half a step stands for it (as in the plugin)", snapshot.etaSeconds == 5, "\(String(describing: snapshot.etaSeconds))")
    first.consume(message(signpost { $0.imageDecoded = .init() }, announced: announced), at: at(147))
    check("after the image is decoded: Finishing, no time (the tail is not known yet)", first.snapshot(now: at(148)).stage == .finishing && first.snapshot(now: at(148)).etaSeconds == nil)
    first.consume(ImageGenerationResponse.with { $0.generatedImages = [Data([1])]; $0.chunkState = .lastChunk }, at: at(150))
    first.finish(.success(.ok), at: at(160))
    check("the run is done", { if case .done = first.state { return true } else { return false } }())
    check("the tail (last step to end of the stream) is remembered: 25 s", SessionTimings.shared.tailSeconds(for: first.timingKey) == 25, "\(String(describing: SessionTimings.shared.tailSeconds(for: first.timingKey)))")
    check("the log line tells where the time went", first.timingReport.contains("last step to decoded 12.0s") && first.timingReport.contains("last step to end 25.0s"), first.timingReport)

    let second = Job(group: group, request: request(steps: 20))
    second.consume(message(sampling(1), announced: announced), at: at(200))
    second.consume(message(sampling(2), announced: announced), at: at(210))
    check("time left of a later run counts the learned tail: 10 * 10 + 25", second.snapshot(now: at(210)).etaSeconds == 125, "\(String(describing: second.snapshot(now: at(210)).etaSeconds))")
    second.consume(message(sampling(12), announced: announced), at: at(310))
    check("Step 12/12 shows the learned tail and counts it down", second.snapshot(now: at(311)).etaSeconds == 24 && second.snapshot(now: at(320)).etaSeconds == 15, "\(String(describing: second.snapshot(now: at(311)).etaSeconds))")
    second.consume(message(signpost { $0.imageDecoded = .init() }, announced: announced), at: at(315))
    check("Finishing goes on counting the tail down", second.snapshot(now: at(316)).stage == .finishing && second.snapshot(now: at(316)).etaSeconds == 19)
    check("and shows no time once it is used up", second.snapshot(now: at(340)).etaSeconds == nil)
    check("runs of the same kind share the key", first.timingKey == second.timingKey && !first.timingKey.isEmpty, first.timingKey)

    SessionTimings.shared.reset()
    let hires = [sampling(10), secondPass(4), signpost { $0.imageDecoded = .init() }]
    let job = Job(group: group, request: request(steps: 10))
    job.consume(message(sampling(1), announced: hires), at: at(0))
    job.consume(message(sampling(2), announced: hires), at: at(2))
    job.consume(message(sampling(10), announced: hires), at: at(18))
    job.consume(message(signpost { $0.imageDecoded = .init() }, announced: hires), at: at(19))
    job.consume(message(signpost { $0.secondPassImageEncoded = .init() }, announced: hires), at: at(20))
    job.consume(message(secondPass(0), announced: hires), at: at(21))
    job.consume(message(secondPass(1), announced: hires), at: at(31))
    job.consume(message(secondPass(2), announced: hires), at: at(41))
    snapshot = job.snapshot(now: at(41))
    check("second pass: own count, flagged, sampling", snapshot.secondPass && snapshot.totalSteps == 4 && snapshot.stage == .sampling && snapshot.step == 2)
    check("second pass: time from its own step time (10 s * 2 + half a step)", snapshot.etaSeconds == 25, "\(String(describing: snapshot.etaSeconds))")
    job.consume(message(secondPass(4), announced: hires), at: at(61))
    check("second pass: the last step stays a step until it is decoded", job.snapshot(now: at(62)).stage == .sampling && job.snapshot(now: at(62)).step == 4)
    job.consume(message(signpost { $0.secondPassImageDecoded = .init() }, announced: hires), at: at(70))
    check("second pass: Finishing after it is decoded", job.snapshot(now: at(71)).stage == .finishing)

    SessionTimings.shared.reset()
    print(failures == 0 ? "ETA PROBE OK" : "ETA PROBE FAILED: \(failures)")
    if failures > 0 { Foundation.exit(1) }
  }
}
