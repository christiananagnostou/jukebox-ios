import Foundation
import XCTest

@testable import JukeboxCore

@MainActor final class DiagnosticOwnerTests: XCTestCase {
  func testFailureCopyKeepsNativeEvidenceAfterContextRetirementAndAddsAcceptedClock() async throws {
    let recorder = DiagnosticRecorder()
    let context = try XCTUnwrap(
      DiagnosticSession(sink: recorder.append).begin(.play, quality: .high))
    let (directory, storage, vault, driver) = try StoreTests().context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "invented")
    await store.enterFixture(service: ControlledCatalog())
    store.playSelection(try await acceptedAlbumSelection(store))
    try await StoreTests().wait { store.playing }
    let occurrence = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.position(occurrence, 12))
    var detail = ConnectionStepError(step: .playbackAudio, error: PlaybackProblem.stalled)
    var evidence = PlaybackEvidence()
    evidence.nativeClock = 12
    evidence.noProgressSeconds = 15
    detail.playbackEvidence = evidence
    detail.nativeDiagnostic = context.event(.playback, .failure(detail, stage: .native))
    context.retire(.sourceRetired)
    driver.onEvent?(.failureDetails(occurrence, detail))
    let failure = try XCTUnwrap(store.lastPlaybackFailure)
    XCTAssertEqual(failure.detail.playbackEvidence?.acceptedClock, 12)
    XCTAssertEqual(failure.diagnostic?.sequence, detail.nativeDiagnostic?.sequence)
    let report = try XCTUnwrap(store.playbackFailureReport(id: failure.id, appVersion: "0.1(40)"))
    XCTAssertTrue(report.contains("JBX v=1"))
    XCTAssertTrue(report.contains("accepted_s=12.000"))
    XCTAssertTrue(report.contains("no_progress_s=15.000"))
    await store.logout()
    XCTAssertNil(store.playbackFailureReport(id: failure.id, appVersion: "0.1(40)"))
  }
  func testActualStoreRetrySuccessCopyAndClockPublicationsShareOnlyAnonymousFacts() async throws {
    let recorder = DiagnosticRecorder()
    let (directory, storage, vault, driver) = try StoreTests().context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "invented-private-installation",
      diagnostics: DiagnosticSession(sink: recorder.append))
    await store.enterFixture(service: ControlledCatalog())
    let selection = try await acceptedAlbumSelection(store)
    driver.startError = URLError(
      .networkConnectionLost,
      userInfo: [
        NSURLErrorFailingURLStringErrorKey: "https://private.invalid/?token=secret",
        NSLocalizedDescriptionKey: "private-title-account-root",
      ])
    store.playSelection(selection)
    try await StoreTests().wait { store.phase == .failed }
    let failure = try XCTUnwrap(store.lastPlaybackFailure)
    let report = try XCTUnwrap(store.playbackFailureReport(id: failure.id, appVersion: "0.1(10)"))
    XCTAssertTrue(report.contains("JBX v=1"))
    XCTAssertTrue(report.contains("domain=url code=-1005"))
    let failedAction = try XCTUnwrap(recorder.records.first?.action)
    driver.startError = nil
    store.play()
    try await StoreTests().wait { store.playing }
    let retry = try XCTUnwrap(
      recorder.records.last { $0.actionKind == .retry && $0.facts.outcome == .accepted })
    XCTAssertNotEqual(retry.action, failedAction)
    XCTAssertEqual(retry.actionKind, .retry)
    let occurrence = try XCTUnwrap(store.current?.id)
    let count = recorder.records.count
    for index in 0..<100 {
      driver.onEvent?(.position(occurrence, Double(index) / 10))
      driver.onEvent?(.timeline(occurrence, duration: 100, seekableEnd: 100))
      driver.onEvent?(.state(occurrence, .playing))
    }
    XCTAssertEqual(recorder.records.count, count)
    let output = recorder.records.map(\.line).joined(separator: "\n") + report
    for privateValue in [
      "private.invalid", "secret", "private-title", selection.origin.library,
      selection.items[0].id, "invented-private-installation",
    ] {
      XCTAssertFalse(output.contains(privateValue))
    }
    store.pause()
    XCTAssertTrue(recorder.records.contains { $0.facts.reason == .userPause })
    await store.logout()
    XCTAssertNil(store.playbackFailureReport(id: failure.id, appVersion: "0.1(10)"))
  }
  func testBoundSeekAcknowledgementHasOwnActionAndSupersessionCancelsOnlyPriorSeek() async throws {
    let recorder = DiagnosticRecorder()
    let (directory, storage, vault, driver) = try StoreTests().context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "invented",
      diagnostics: DiagnosticSession(sink: recorder.append))
    await store.enterFixture(service: ControlledCatalog())
    store.playSelection(try await acceptedAlbumSelection(store))
    try await StoreTests().wait { store.playing }
    store.seek(4)
    store.seek(2)
    let latest = try XCTUnwrap(recorder.records.last?.action)
    let occurrence = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.seekCompleted(occurrence, 2, request: driver.seekRequests.last))
    XCTAssertEqual(recorder.records.last?.action, latest)
    XCTAssertEqual(recorder.records.last?.facts.stage, .seek)
    XCTAssertEqual(recorder.records.last?.facts.outcome, .succeeded)
    XCTAssertTrue(
      recorder.records.contains {
        $0.actionKind == .seek && $0.action != latest && $0.facts.reason == .superseded
      })
    XCTAssertEqual(store.queue.position, 2)
    store.pause()
  }
  func testChunkedCatalogBodyEnforcesTheLimitAsBytesArrive() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DiagnosticHTTPProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let url = URLRequest(url: URL(string: "https://fixture.invalid/Items")!)
    let fitting = try await LiveHTTP(captureTestSession: session, maximumBytes: 3).send(url)
    XCTAssertEqual(fitting.data.count, 3)
    do {
      _ = try await LiveHTTP(captureTestSession: session, maximumBytes: 2).send(url)
      XCTFail("An oversized catalog body was accepted")
    } catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
  }
  func testLiveHTTPPreservesResponseAndBodyFailureWithoutRawErrorFields() async throws {
    for failing in [false, true] {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [DiagnosticHTTPProtocol.self]
      let session = URLSession(configuration: configuration)
      defer { session.invalidateAndCancel() }
      let transport = LiveHTTP(captureTestSession: session)
      let request = URLRequest(
        url: URL(string: "https://private.invalid/Items?token=secret&failure=\(failing ? 1 : 0)")!)
      do {
        let reply = try await transport.send(request)
        XCTAssertFalse(failing)
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.data, Data([1, 2, 3]))
      } catch {
        XCTAssertTrue(failing)
        let detail = ConnectionStepError(step: .playbackSource, error: error)
        XCTAssertEqual(detail.code, -1005)
        let report = PlaybackFailure(detail: detail, time: Date(timeIntervalSince1970: 0)).report(
          appVersion: "test")
        XCTAssertFalse(report.contains("private.invalid"))
        XCTAssertFalse(report.contains("token"))
      }
    }
  }

}
private final class DiagnosticHTTPProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": "application/json",
          "Content-Length": request.url?.query?.contains("failure=1") == true ? "12" : "3",
        ])!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
    if request.url?.query?.contains("failure=1") == true {
      DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
        self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
      }
    } else {
      client?.urlProtocolDidFinishLoading(self)
    }
  }
}
