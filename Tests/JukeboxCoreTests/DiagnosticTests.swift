import Foundation
import XCTest

@testable import JukeboxCore

final class DiagnosticRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [DiagnosticRecord] = []
  func append(_ value: DiagnosticRecord) { lock.withLock { values.append(value) } }
  var records: [DiagnosticRecord] { lock.withLock { values } }
}
private final class DiagnosticClock: @unchecked Sendable {
  private let lock = NSLock()
  private var uptime: Double = 10
  func advance(_ seconds: Double) { lock.withLock { uptime += seconds } }
  func read() -> DiagnosticSession.Time {
    lock.withLock {
      .init(utc: Date(timeIntervalSince1970: 1_700_000_000 + uptime), uptime: uptime)
    }
  }
}
final class DiagnosticTests: XCTestCase {
  func testPlaybackReportSeparatesMissingCodesAndKeepsBoundedFiniteEvidence() {
    var detail = ConnectionStepError(step: .playbackAudio, error: PlaybackProblem.stalled)
    var evidence = PlaybackEvidence()
    evidence.transport = .active
    evidence.nativeClock = 23.5
    evidence.origin = 100
    evidence.absoluteClock = 123.5
    evidence.nativeDuration = .infinity
    evidence.sourceDuration = .nan
    evidence.noProgressSeconds = 15
    var transfer = PlaybackTransferEvidence()
    transfer.ordinal = 2
    transfer.rangeStart = 16_384
    transfer.status = 200
    transfer.code = DiagnosticCode(domain: .url, value: -1005)
    transfer.received = 32_768
    transfer.state = .failed
    evidence.transfers = Array(repeating: transfer, count: 20)
    detail.playbackEvidence = evidence
    let report = PlaybackFailure(detail: detail, time: .distantPast).report(appVersion: "0.1(40)")
    XCTAssertTrue(report.contains("PB-3"))
    XCTAssertTrue(report.contains("Code: unavailable"))
    XCTAssertTrue(report.contains("HTTP: unavailable"))
    XCTAssertTrue(report.contains("Native log code: unavailable (not collected)"))
    XCTAssertTrue(report.contains("native_s=23.500"))
    XCTAssertTrue(report.contains("absolute_s=123.500"))
    XCTAssertTrue(report.contains("native_duration_s=unavailable"))
    XCTAssertTrue(report.contains("source_duration_s=unavailable"))
    XCTAssertTrue(report.contains("range_start=16384"))
    XCTAssertTrue(report.contains("error_domain=url error_code=-1005"))
    XCTAssertTrue(report.contains("transfer3={"))
    XCTAssertFalse(report.contains("transfer4={"))
    XCTAssertLessThan(report.count, 3_000)
    XCTAssertEqual(PlaybackEvidence.number(1e20), "unavailable")
    XCTAssertEqual(PlaybackEvidence.number(0), "0.000")
  }
  func testProgressEvidenceDoesNotExtendPreparationOrStallDeadline() {
    var deadline = PlaybackProgressDeadline()
    deadline.reset(at: 100, preparationStartedAt: 100)
    XCTAssertEqual(deadline.evidence(at: 115).preparing, 15)
    XCTAssertFalse(deadline.expired(at: 159, position: 0))
    XCTAssertTrue(deadline.expired(at: 160, position: 0))
    deadline.markReady(at: 160)
    XCTAssertNil(deadline.evidence(at: 170).preparing)
    XCTAssertEqual(deadline.evidence(at: 170).noProgress, 10)
    XCTAssertTrue(deadline.expired(at: 175, position: 0))
  }
  func testLaunchModeUsesParsedProfileDispositionInEveryBuildConfiguration() {
    let id = "10000000-0000-0000-0000-000000000001"
    for arguments in [
      ["--fixture", "--profile-fixture=" + id],
      ["--fixture", "--profile-fixture=" + id, "--profile-cleanup"],
      ["--fixture", "--profile-inspect-report=" + id],
    ] {
      let profile = ProfilingLaunch(arguments: arguments)
      XCTAssertFalse(profile.isRejected)
      XCTAssertEqual(
        DiagnosticLaunchMode(profiling: profile, fixture: true, integration: false), .acceptance)
      XCTAssertEqual(
        profile.startup(normal: { 1 }, fixture: { _ in 2 }, isolated: { 3 }),
        profile.runID == nil ? 3 : 2)
    }
    for arguments in [
      ["--profile-fixture=" + id], ["--fixture", "--profile-fixture=invalid"],
      ["--fixture", "--profile-fixture=" + id, "--catalog-scale=invalid"],
    ] {
      let profile = ProfilingLaunch(arguments: arguments)
      XCTAssertTrue(profile.isRejected)
      XCTAssertEqual(
        DiagnosticLaunchMode(profiling: profile, fixture: true, integration: false), .rejected)
      XCTAssertEqual(profile.startup(normal: { 1 }, fixture: { _ in 2 }, isolated: { 3 }), 3)
    }
    let absent = ProfilingLaunch(arguments: [])
    XCTAssertEqual(
      DiagnosticLaunchMode(profiling: absent, fixture: false, integration: false), .normal)
    XCTAssertEqual(
      DiagnosticLaunchMode(profiling: absent, fixture: true, integration: false), .invented)
    XCTAssertEqual(
      DiagnosticLaunchMode(profiling: absent, fixture: false, integration: true), .acceptance)
    for rejected in [true, false] {
      XCTAssertEqual(
        DiagnosticLaunchMode(
          profiling: absent, transport: rejected ? .rejected : .acceptance,
          fixture: true, integration: false), rejected ? .rejected : .acceptance)
      XCTAssertEqual(
        DiagnosticLaunchMode(
          profiling: absent, scale: rejected ? .rejected : .invented,
          fixture: true, integration: false), rejected ? .rejected : .invented)
    }
  }
  func testStartupAttributionDistinguishesHeaderAndCopiedScopeRetirement() throws {
    let recorder = DiagnosticRecorder()
    let session = DiagnosticSession(
      build: .init(version: "0.1", build: "11", marker: "Startup-Attribution-1", os: [27, 2, 0]),
      sink: recorder.append)
    let action = try XCTUnwrap(session.begin(.play, quality: .original))
    let source = try XCTUnwrap(action.handoff())
    source.retire(.sourceRetired)
    XCTAssertTrue(recorder.records[0].line.contains("mode=normal"))
    XCTAssertTrue(recorder.records[1].line.contains("role=current scope=intent"))
    XCTAssertEqual(recorder.records.last?.facts.stage.rawValue, "scope")
    XCTAssertEqual(recorder.records.last?.facts.reason, .sourceRetired)
    XCTAssertEqual(recorder.records.last?.action, recorder.records[1].action)
  }
  func testSourceRolesAreImmutableAcrossIndependentHandoffs() throws {
    let recorder = DiagnosticRecorder()
    let session = DiagnosticSession(sink: recorder.append)
    let action = try XCTUnwrap(session.begin(.play))
    let current = try XCTUnwrap(action.handoff(scope: .nativeItem))
    let future = try XCTUnwrap(action.handoff(role: .successor))
    let job = try XCTUnwrap(future.handoff(scope: .nativeItem))
    job.retire(.taskCancelled)
    current.event(.playback, .init(.native, .playing))
    future.event(.playback, .init(.source, .succeeded))
    XCTAssertEqual(Set(recorder.records.compactMap(\.action)), [1])
    XCTAssertEqual(recorder.records[1].role, .successor)
    XCTAssertEqual(recorder.records[1].scope, .nativeItem)
    XCTAssertEqual(recorder.records[1].facts.stage, .scope)
    XCTAssertEqual(recorder.records[2].role, .current)
    XCTAssertEqual(recorder.records[2].scope, .nativeItem)
    XCTAssertEqual(recorder.records[3].role, .successor)
    XCTAssertEqual(recorder.records[3].scope, .preparation)
  }
  func testDeferredExtractionIsGatedWhileSinkRunsOutsideIncumbentLock() throws {
    let domainLock = NSLock()
    let recorder = DiagnosticRecorder()
    let session = DiagnosticSession(sink: { record in
      let unlocked = domainLock.try()
      XCTAssertTrue(unlocked, "Sink entered under the source authority lock")
      if unlocked { domainLock.unlock() }
      recorder.append(record)
    })
    let context = try XCTUnwrap(session.begin(.play))
    domainLock.lock()
    var getters = 0
    let finish = context.prepareEvent(.network) {
      getters += 1
      return .init(.bridge, .failed, http: 502)
    }
    domainLock.unlock()
    context.retire(.sourceRetired)
    finish?.publish()
    XCTAssertEqual(getters, 1)
    XCTAssertEqual(recorder.records.last?.facts.http, 502)
    XCTAssertLessThan(try XCTUnwrap(finish?.record.sequence), recorder.records[1].sequence)
    context.prepareEvent(.network) {
      getters += 1
      return .init(.bridge, .failed)
    }?.publish()
    XCTAssertEqual(getters, 1)
  }
  func testFailureDomainsAndStagesRemainTruthfulWithoutRawErrorRetention() {
    for (domain, expected) in [
      ("AVFoundationErrorDomain", DiagnosticCode.Domain.avFoundation),
      (NSOSStatusErrorDomain, .osStatus),
    ] {
      let detail = ConnectionStepError(
        step: .audioSession,
        error: NSError(domain: domain, code: -50, userInfo: ["secret": "never-log"]))
      let facts = DiagnosticFacts.failure(detail, stage: .native)
      XCTAssertEqual(facts.stage, .audioSession)
      XCTAssertEqual(facts.code?.domain, expected)
      XCTAssertEqual(facts.code?.value, -50)
      XCTAssertEqual(facts.failure, .nativeCode)
      XCTAssertFalse(facts.fields.contains("secret"))
    }
  }
  func testSinkMayReenterWithoutHoldingObserverLocks() throws {
    final class Reentrant: @unchecked Sendable {
      private let lock = NSLock()
      private var value: DiagnosticContext?
      var context: DiagnosticContext? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
      }
    }
    let box = Reentrant()
    let recorder = DiagnosticRecorder()
    let session = DiagnosticSession(sink: { record in
      recorder.append(record)
      if record.facts.stage == .native {
        box.context?.event(.lifecycle, .init(.other, .succeeded))
      }
    })
    let context = try XCTUnwrap(session.begin(.play))
    box.context = context
    context.event(.playback, .init(.native, .playing))
    XCTAssertEqual(recorder.records.map(\.facts.stage), [.command, .native, .other])
  }
  func testCancelledProducerCannotExtractOrAcquireHandoffButExplicitRetirementWorks() async throws {
    let recorder = DiagnosticRecorder()
    let context = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.play))
    let result = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      var getters = 0
      context.event(.playback) {
        getters += 1
        return .init(.native, .failed)
      }
      context.prepareEvent(.network) {
        getters += 1
        return .init(.source, .failed)
      }?.publish()
      let handoff = context.handoff()
      context.retire(.taskCancelled)
      return (getters, handoff == nil)
    }.value
    XCTAssertEqual(result.0, 0)
    XCTAssertTrue(result.1)
    XCTAssertEqual(recorder.records.filter { $0.facts.outcome == .cancelled }.count, 1)
  }
  func testHeaderSchemaCorrelationAndMonotonicActionDuration() throws {
    let recorder = DiagnosticRecorder()
    let clock = DiagnosticClock()
    let launch = UUID()
    let session = DiagnosticSession(
      build: .init(version: "0.1", build: "10", marker: "Structured-Logging-1", os: [27, 2, 0]),
      launch: launch, clock: clock.read, sink: recorder.append)
    let action = try XCTUnwrap(session.begin(.play, quality: .high))
    clock.advance(0.125)
    action.event(.playback, .init(.source, .succeeded))
    clock.advance(0.5)
    action.event(.playback, .init(.native, .playing))
    let records = recorder.records
    XCTAssertEqual(records.map(\.sequence), [1, 2, 3, 4])
    XCTAssertEqual(Set(records.map(\.launch)), [launch])
    XCTAssertTrue(records[0].line.contains("app=Jukebox version=0.1 build=10"))
    XCTAssertTrue(records[0].line.contains("utc=2023-11-14T"))
    XCTAssertNil(records[0].action)
    XCTAssertEqual(Set(records.dropFirst().compactMap(\.action)), [1])
    XCTAssertEqual(records[2].facts.stage, .source)
    XCTAssertEqual(records[2].facts.durationMS, 125)
    XCTAssertEqual(records[3].facts.durationMS, 625)
    XCTAssertEqual(records[3].elapsedMS, 625)
    XCTAssertTrue(records[3].line.contains("quality=high"))
  }
  func testRetirementRejectsExtractorsBeforePrivateGetters() throws {
    let recorder = DiagnosticRecorder()
    let action = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.selection))
    action.retire(.accountRetired)
    var getters = 0
    action.prepareEvent(.network) {
      getters += 1
      return .init(.metadata, .failed)
    }?.publish()
    action.event(.playback) {
      getters += 1
      return .init(.native, .failed)
    }
    XCTAssertNil(action.handoff())
    action.retire(.rootRetired)
    XCTAssertEqual(getters, 0)
    XCTAssertEqual(recorder.records.filter { $0.facts.outcome == .cancelled }.count, 1)
  }
  func testHandoffsShareStateBoundWithoutSuppressingDistinctTerminals() throws {
    let recorder = DiagnosticRecorder()
    let context = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.play))
    for _ in 0..<100 {
      let child = try XCTUnwrap(context.handoff())
      child.event(.playback, .init(.native, .waiting))
      child.event(.playback, .init(.source, .succeeded))
    }
    context.event(.playback, .init(.native, .failed))
    XCTAssertEqual(recorder.records.filter { $0.facts.outcome == .waiting }.count, 64)
    XCTAssertEqual(recorder.records.filter { $0.facts.outcome == .succeeded }.count, 100)
    XCTAssertEqual(recorder.records.reduce(0) { $0 + $1.dropped }, 36)
    XCTAssertEqual(recorder.records.last?.facts.outcome, .failed)
  }
  func testBridgeFailureBudgetPrecedesGettersAndCannotSuppressPrimaryNativeFailure() throws {
    let recorder = DiagnosticRecorder()
    let action = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.play))
    var reads = 0
    for _ in 0..<50 {
      let source = try XCTUnwrap(action.handoff(scope: .nativeItem))
      source.prepareEvent(.network) {
        reads += 1
        return .init(.bridge, .failed, http: 502)
      }?.publish()
    }
    XCTAssertEqual(reads, 32, "Copied contexts cannot reset the shared observation bound")
    XCTAssertEqual(recorder.records.filter { $0.facts.stage == .bridge }.count, 32)
    action.event(.playback) {
      .init(.native, .failed, code: .init(domain: .avFoundation, value: -11819))
    }
    XCTAssertEqual(recorder.records.last?.facts.stage, .native)
    XCTAssertEqual(recorder.records.last?.facts.code?.value, -11819)
    XCTAssertEqual(recorder.records.reduce(0) { $0 + $1.dropped }, 18)
    action.retire(.sourceRetired)
    action.prepareEvent(.network) {
      XCTFail("Retired context read a bridge error")
      return .init(.bridge, .failed)
    }?.publish()
    XCTAssertEqual(reads, 32)
  }
  func testRepeatedStatesAreBoundedButRetryAndDistinctTerminalResultsRemainVisible() throws {
    let recorder = DiagnosticRecorder()
    let session = DiagnosticSession(sink: recorder.append)
    let failed = try XCTUnwrap(session.begin(.play))
    for _ in 0..<200 { failed.event(.playback, .init(.native, .waiting)) }
    failed.event(.playback, .init(.native, .failed))
    failed.retire(.sourceRetired)
    let retry = try XCTUnwrap(session.begin(.retry))
    retry.event(.playback, .init(.native, .playing))
    XCTAssertEqual(recorder.records.filter { $0.facts.outcome == .waiting }.count, 1)
    XCTAssertEqual(recorder.records.reduce(0) { $0 + $1.dropped }, 199)
    XCTAssertEqual(recorder.records.filter { $0.facts.outcome == .failed }.count, 1)
    XCTAssertEqual(recorder.records.filter { $0.facts.outcome == .playing }.count, 1)
    XCTAssertNotEqual(recorder.records.first?.action, recorder.records.last?.action)
    for index in 0..<200 {
      retry.event(.playback, .init(.native, index.isMultiple(of: 2) ? .waiting : .playing))
    }
    retry.event(.playback, .init(.native, .failed))
    XCTAssertEqual(recorder.records.last?.facts.outcome, .failed)
    XCTAssertLessThan(recorder.records.count, 75)
  }
  func testAcceptedOldSourceAndNewPendingIntentHaveIndependentAnonymousLifetimes() throws {
    let recorder = DiagnosticRecorder()
    let session = DiagnosticSession(sink: recorder.append)
    let old = try XCTUnwrap(session.begin(.play))
    let native = try XCTUnwrap(old.handoff())
    let cancelledJob = try XCTUnwrap(native.handoff())
    let survivingJob = try XCTUnwrap(native.handoff())
    cancelledJob.retire(.taskCancelled)
    survivingJob.event(.network, .init(.bridge, .failed, http: 502))
    XCTAssertEqual(recorder.records.last?.facts.outcome, .failed)
    let pending = try XCTUnwrap(session.begin(.selection))
    pending.retire(.userPause)
    native.event(.playback, .init(.native, .paused))
    XCTAssertEqual(recorder.records.last?.action, recorder.records.first?.action)
    old.retire(.superseded)
    native.event(.playback, .init(.native, .waiting))
    native.retire(.sourceRetired)
    var staleGetter = false
    native.event(.playback) {
      staleGetter = true
      return .init(.native, .failed)
    }
    XCTAssertFalse(staleGetter)
  }
  func testConcurrentStampingHasUniqueSequenceAndActionCorrelation() async {
    let recorder = DiagnosticRecorder()
    let session = DiagnosticSession(sink: recorder.append)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<100 {
        group.addTask {
          guard let context = session.begin(.play) else {
            return XCTFail("Enabled diagnostics unexpectedly dropped an action")
          }
          context.event(.playback, .init(.source, .failed))
        }
      }
    }
    let records = recorder.records
    XCTAssertEqual(records.count, 200)
    XCTAssertEqual(Set(records.map(\.sequence)), Set(1...UInt64(200)))
    XCTAssertEqual(Set(records.compactMap(\.action)).count, 100)
    for action in Set(records.compactMap(\.action)) {
      let pair = records.filter { $0.action == action }
      XCTAssertEqual(pair.count, 2)
      XCTAssertEqual(Set(pair.map(\.facts.outcome)), [.accepted, .failed])
    }
  }
  func testUnknownErrorPayloadAndHeaderControlsCannotEnterFormattedEvent() throws {
    let privateText = "private-title-secret-token-address.invalid"
    let error = NSError(
      domain: privateText, code: 987,
      userInfo: [
        NSDebugDescriptionErrorKey: privateText,
        NSURLErrorFailingURLErrorKey: URL(string: "https://secret.invalid")!,
      ])
    let recorder = DiagnosticRecorder()
    let session = DiagnosticSession(
      build: .init(
        version: "0.1\n", build: "10=\t", marker: "Build\nMarker", os: [-1, 27, 9999, 9]),
      sink: recorder.append)
    let context = try XCTUnwrap(session.begin(.seek))
    context.event(.playback) { .init(.seek, .failed, code: DiagnosticCode(error)) }
    let output = recorder.records.map(\.line).joined(separator: "\n")
    XCTAssertFalse(output.contains(privateText))
    XCTAssertFalse(output.contains("secret.invalid"))
    XCTAssertFalse(output.contains("code=987"))
    XCTAssertTrue(output.contains("domain=unknown code=0"))
    XCTAssertTrue(output.contains("os=0.27.999"))
    XCTAssertEqual(output.components(separatedBy: "\n").count, 3)
  }
}
