import Foundation
import XCTest

@testable import JukeboxCore

final class TransportCaptureTests: XCTestCase {
  func testLocalPhysicalInputRejectsMissingMixedUnknownAndCrossRunIntent() throws {
    let id = UUID()
    let nonce = UUID()
    let valid = [
      "run_id": id.uuidString, "scenario": "session", "version": "1", "nonce": nonce.uuidString,
    ]
    XCTAssertEqual(try TransportLocalInput(valid, runID: id).nonce, nonce)
    var artwork = valid
    artwork["scenario"] = "artwork"
    XCTAssertEqual(try TransportLocalInput(artwork, runID: id).scenario, "artwork")
    for field in valid.keys {
      var missing = valid
      missing[field] = nil
      XCTAssertThrowsError(try TransportLocalInput(missing, runID: id))
    }
    for (key, value) in [
      ("scenario", "network"), ("version", "2"), ("nonce", "invalid"),
      ("run_id", UUID().uuidString), ("server", "https://invented.invalid"),
    ] {
      var rejected = valid
      rejected[key] = value
      XCTAssertThrowsError(try TransportLocalInput(rejected, runID: id))
    }
  }
  func testPhysicalTailScopePreservesNormalSiblingAndRejectsUnknownOrLinkedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let normal = root.appendingPathComponent("JukeboxPlaybackTails")
    try FileManager.default.createDirectory(at: normal, withIntermediateDirectories: false)
    let untouched = normal.appendingPathComponent("normal-sentinel")
    try Data([1]).write(to: untouched)
    let id = UUID()
    let siblingID = UUID()
    let folder = try TransportControlFiles.prepareTails(in: root, runID: id)
    let sibling = try TransportControlFiles.prepareTails(in: root, runID: siblingID)
    let unknown = folder.appendingPathComponent("unexpected")
    try Data([2]).write(to: unknown)
    XCTAssertThrowsError(try TransportControlFiles.prepareTails(in: root, runID: id))
    XCTAssertThrowsError(try TransportControlFiles.cleanupTails(in: root, runID: id))
    try FileManager.default.removeItem(at: unknown)
    let tail = folder.appendingPathComponent("tail-" + UUID().uuidString + ".mp3")
    try FileManager.default.createSymbolicLink(at: tail, withDestinationURL: untouched)
    XCTAssertThrowsError(try TransportControlFiles.prepareTails(in: root, runID: id))
    XCTAssertThrowsError(try TransportControlFiles.cleanupTails(in: root, runID: id))
    try FileManager.default.removeItem(at: tail)
    try Data([3]).write(to: tail)
    try TransportControlFiles.cleanupTails(in: root, runID: id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    XCTAssertEqual(try Data(contentsOf: untouched), Data([1]))
    let linked = TransportControlFiles.tailDirectory(in: root, runID: id)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: normal)
    XCTAssertThrowsError(try TransportControlFiles.prepareTails(in: root, runID: id))
    XCTAssertThrowsError(try TransportControlFiles.cleanupTails(in: root, runID: id))
    XCTAssertEqual(try Data(contentsOf: untouched), Data([1]))
  }
  @MainActor func testActualAsyncBytesBodyFailureRetainsObservedHeadersAndConsumedPrefix()
    async throws
  {
    let capture = TransportCapture.shared
    defer { capture.clear() }
    for beforeResponse in [false, true] {
      capture.clear()
      capture.start(policyBits: 7)
      let request = URLRequest(
        url: URL(
          string: "https://capture-progress.invalid/" + (beforeResponse ? "before" : "body"))!)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [ProgressFailureProtocol.self]
      let session = URLSession(configuration: configuration)
      defer { session.invalidateAndCancel() }
      let transport = LiveHTTP(captureTestSession: session)
      var failure = 0
      await TransportCapture.$caller.withValue(capture.context()) {
        do {
          _ = try await transport.send(request)
          XCTFail("Injected stream unexpectedly succeeded")
        } catch { failure = (error as? URLError)?.errorCode ?? 0 }
      }
      XCTAssertEqual(failure, beforeResponse ? -1022 : -1005)
      let report = try object(XCTUnwrap(capture.export()))
      let events = try XCTUnwrap(report["events"] as? [[String: Any]])
      XCTAssertEqual(events.count, 1)
      let evidence = try XCTUnwrap(events.first?["evidence"] as? [String: Any])
      XCTAssertEqual(
        Set(evidence.keys), ["stage", "http", "error", "bytes", "httpResponseObserved"])
      XCTAssertEqual(report["marker"] as? String, "ATS-20261022-3")
      XCTAssertEqual(evidence["httpResponseObserved"] as? Bool, !beforeResponse)
      XCTAssertEqual(evidence["http"] as? Int, beforeResponse ? 0 : 200)
      XCTAssertEqual(evidence["bytes"] as? Int, beforeResponse ? 0 : 5)
      XCTAssertEqual(evidence["error"] as? Int, beforeResponse ? -1022 : -1005)
    }
  }

  private func object(_ snapshot: TransportCapture.Export) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshot.text.utf8)) as? [String: Any])
  }
  func testResponseFieldsRemainBehindExpiredRearmedAndCappedGetterFence() throws {
    for mode in 0..<3 {
      let capture = TransportCapture()
      let start = ContinuousClock.now
      capture.start(policyBits: 7, now: start)
      let ticket = try XCTUnwrap(capture.begin(context: capture.context(now: start), now: start))
      var now = start
      if mode == 0 {
        now = start.advanced(by: .seconds(90))
      } else if mode == 1 {
        capture.clear(retire: true)
        capture.start(policyBits: 7, now: start)
      } else {
        capture.finish(ticket) { .init(stage: .metadata, http: 200, error: 0, bytes: 5) }
        for _ in 0..<31 {
          let next = try XCTUnwrap(capture.begin(context: capture.context(now: start), now: start))
          capture.finish(next, now: start) {
            .init(stage: .metadata, http: 200, error: 0, bytes: 5)
          }
        }
      }
      var reads = 0
      capture.finish(ticket, now: now) {
        reads += 1
        return .init(
          stage: .metadata, http: 200, error: -1005, bytes: 5, httpResponseObserved: true)
      }
      XCTAssertEqual(reads, 0, "Retired response/error fields extracted")
    }
  }
  func testOffByDefaultAndStartHasNoEventsOrRequestWork() throws {
    let capture = TransportCapture()
    XCTAssertNil(capture.begin(context: capture.context()))
    XCTAssertNil(capture.export())
    capture.start(policyBits: 7)
    XCTAssertEqual(capture.currentState(), .recording)
    let report = try object(XCTUnwrap(capture.export()))
    XCTAssertEqual((report["events"] as? [Any])?.count, 0)
    XCTAssertEqual(report["policyBits"] as? Int, 7)
  }
  func testScalarReportNeverContainsRequestOrErrorSecrets() throws {
    let capture = TransportCapture()
    capture.start(policyBits: 7)
    let ticket = try XCTUnwrap(capture.begin(context: capture.context()))
    let request = URLRequest(
      url: URL(string: "https://secret-host.invalid/private-id/PlaybackInfo?api_key=secret-token")!)
    capture.finish(ticket) { .init(stage: .classify(request), http: 0, error: -1022, bytes: 0) }
    let snapshot = try XCTUnwrap(capture.export())
    XCTAssertTrue(snapshot.text.contains("playbackInfo"))
    XCTAssertTrue(snapshot.text.contains("-1022"))
    for privateValue in ["secret", "private-id", "https", "api_key", "Authorization"] {
      XCTAssertFalse(snapshot.text.contains(privateValue))
    }
    XCTAssertEqual(
      Set(try object(snapshot).keys),
      ["marker", "os", "policyBits", "state", "truncated", "discardedInFlight", "events"])
  }
  func testHardEventAndPendingCapsExposeTruncationAndRetireOutstandingTickets() throws {
    let capture = TransportCapture()
    capture.start(policyBits: 7)
    let tickets = try (0..<32).map { _ in try XCTUnwrap(capture.begin(context: capture.context())) }
    XCTAssertNil(capture.begin(context: capture.context()))
    for ticket in tickets {
      capture.finish(ticket) { .init(stage: .metadata, http: 200, error: 0, bytes: 20) }
    }
    XCTAssertEqual(capture.currentState(), .full)
    XCTAssertNil(capture.begin(context: capture.context()))
    capture.finish(tickets[0]) {
      XCTFail("reused/retired ticket extracted")
      return .init(stage: .other, http: 0, error: 0, bytes: 0)
    }
    let snapshot = try XCTUnwrap(capture.export())
    let report = try object(snapshot)
    XCTAssertEqual((report["events"] as? [Any])?.count, 32)
    XCTAssertEqual(report["truncated"] as? Bool, true)
    XCTAssertEqual(report["discardedInFlight"] as? Int, 1)
    XCTAssertLessThan(snapshot.text.utf8.count, 6000)
  }
  func testMonotonicExpiryClearsBeforeExtractionCopyAndForegroundInspection() throws {
    let capture = TransportCapture()
    let start = ContinuousClock.now
    capture.start(policyBits: 7, now: start)
    let ticket = try XCTUnwrap(capture.begin(context: capture.context(now: start), now: start))
    let snapshot = try XCTUnwrap(capture.export(now: start.advanced(by: .seconds(89))))
    capture.finish(ticket, now: start.advanced(by: .seconds(90))) {
      XCTFail("expired request/error getter read")
      return .init(stage: .other, http: 0, error: 0, bytes: 0)
    }
    XCTAssertNil(capture.export(now: start.advanced(by: .seconds(90))))
    XCTAssertFalse(
      capture.withCurrentExport(snapshot, now: start.advanced(by: .seconds(90))) {
        XCTFail("expired Copy continued")
      })
    XCTAssertEqual(capture.currentState(now: start.advanced(by: .seconds(91))), .expired)
    capture.start(policyBits: 7, now: start)
    XCTAssertEqual(capture.currentState(now: start.advanced(by: .seconds(91))), .expired)
  }
  func testStartClearAndOwnerRetirementRejectLateExtractionAndCopy() throws {
    let capture = TransportCapture()
    for retire in [false, true] {
      capture.start(policyBits: 7)
      let ticket = try XCTUnwrap(capture.begin(context: capture.context()))
      let snapshot = try XCTUnwrap(capture.export())
      capture.clear(retire: retire)
      capture.start(policyBits: 7)
      capture.finish(ticket) {
        XCTFail("old recording/owner getter read")
        return .init(stage: .other, http: 0, error: 0, bytes: 0)
      }
      XCTAssertFalse(
        capture.withCurrentExport(snapshot) { XCTFail("old recording/owner Copy continued") })
      XCTAssertEqual((try object(XCTUnwrap(capture.export()))["events"] as? [Any])?.count, 0)
    }
  }
  @MainActor func testActualMusicRootAndBrowserRetirementClearCapture() async throws {
    let capture = TransportCapture.shared
    defer { capture.clear() }
    let browser = MusicBrowser(
      service: FixtureCatalog(source: URL(fileURLWithPath: "/invented.wav")))
    await browser.start()
    capture.start(policyBits: 7)
    let old = try XCTUnwrap(capture.begin(context: capture.context()))
    let target = try XCTUnwrap(browser.libraries.first(where: { $0.id != browser.libraryID }))
    browser.selectLibrary(target.id)
    XCTAssertEqual(capture.currentState(), .idle)
    capture.finish(old) {
      XCTFail("retired root getter read")
      return .init(stage: .other, http: 0, error: 0, bytes: 0)
    }
    capture.start(policyBits: 7)
    browser.retire()
    XCTAssertEqual(capture.currentState(), .idle)
  }
  func testDelayedEntryCannotAcquireNewRecordingOrOwnerAfterRearm() throws {
    let capture = TransportCapture()
    capture.start(policyBits: 7)
    let queued = capture.context()
    capture.clear(retire: true)
    capture.start(policyBits: 7)
    var extracted = false
    if let ticket = capture.begin(context: queued) {
      capture.finish(ticket) {
        extracted = true
        return .init(stage: .metadata, http: 0, error: -1022, bytes: 0)
      }
    }
    XCTAssertFalse(extracted, "old queued request extracted under newly armed scope")
    XCTAssertEqual((try object(XCTUnwrap(capture.export()))["events"] as? [Any])?.count, 0)
    XCTAssertNil(capture.begin(context: nil), "unscoped request acquired current recording")
  }
  func testCancelledEntryCannotAcquireOrExtractScalarEvidence() async {
    let capture = TransportCapture()
    capture.start(policyBits: 7)
    let queued = capture.context()
    let task = Task {
      try? await Task.sleep(for: .seconds(2))
      var extracted = false
      if let ticket = capture.begin(context: queued) {
        capture.finish(ticket) {
          extracted = true
          return .init(stage: .metadata, http: 0, error: -1022, bytes: 0)
        }
      }
      return extracted
    }
    task.cancel()
    let extracted = await task.value
    XCTAssertFalse(extracted, "cancelled entry extracted retired request")
  }
  func testCancellationAfterTicketRejectsExtractionAtCompletion() async throws {
    let capture = TransportCapture()
    capture.start(policyBits: 7)
    let ticket = try XCTUnwrap(capture.begin(context: capture.context()))
    let task = Task {
      try? await Task.sleep(for: .seconds(2))
      var extracted = false
      capture.finish(ticket) {
        extracted = true
        return .init(stage: .metadata, http: 0, error: -1022, bytes: 0)
      }
      return extracted
    }
    task.cancel()
    let extracted = await task.value
    XCTAssertFalse(extracted, "cancelled completion extracted request/error")
  }

}

final class TransportControlEntryTests: XCTestCase {
  func testPlaylistCopyAndDisabledCodeScenariosUseIsolatedFixtureStartup() {
    let id = UUID()
    let base = ["--fixture", "--muted", "--transport-ui=" + id.uuidString]
    for options in [
      ["--read-only-mix"], ["--quick-connect-fixture", "--codes-disabled"],
      ["--quick-connect-fixture", "--example-saved-connections"],
      ["--quick-connect-fixture", "--example-saved-connections", "--offline-first-reconnect"],
    ] {
      let launch = TransportControlLaunch(arguments: base + options)
      XCTAssertTrue(launch.startup(normal: { false }, isolated: { true }))
      #if DEBUG
        guard case .interactive(let launchedID) = launch else {
          XCTFail("Expected the requested isolated UI scenario")
          continue
        }
        XCTAssertEqual(launchedID, id)
        XCTAssertNil(launch.runID)
      #else
        if case .rejected = launch {} else { XCTFail("Release admitted a test fixture") }
      #endif
    }
    for options in [
      ["--example-saved-connections"], ["--offline-first-reconnect"],
      ["--example-saved-connections", "--offline-first-reconnect"],
      ["--quick-connect-fixture", "--offline-first-reconnect"],
    ] {
      if case .rejected = TransportControlLaunch(arguments: base + options) { continue }
      XCTFail("A reconnect outage requires saved accounts and the isolated Quick Connect service")
    }
  }
  func testLiveAccountCheckStartsWithFreshStorageAndCannotBeCombinedWithFixtures() {
    let flag = "--transport-account-sign-in=" + UUID().uuidString
    let live = TransportControlLaunch(arguments: [flag, "--muted"])
    XCTAssertTrue(live.startup(normal: { false }, isolated: { true }))
    #if DEBUG
      guard case .accountSignIn = live else { return XCTFail("Expected isolated sign-in") }
      XCTAssertNil(live.runID)
    #else
      guard case .rejected = live else { return XCTFail("Release admitted a test launch") }
    #endif
    for flags in [
      [flag], [flag, "--muted", "--fixture"], [flag, "--muted", "--connect"],
      ["--transport-account-sign-in=invalid", "--muted"],
    ] {
      guard case .rejected = TransportControlLaunch(arguments: flags) else {
        return XCTFail("Malformed or mixed account-check arguments")
      }
    }
  }

  func testInteractiveEntrySelectsOnlyIsolatedDependenciesAndOwnsNoTransportFiles() {
    let id = "00000000-0000-0000-0000-000000000001"
    let arguments = ["--fixture", "--muted", "--transport-ui=" + id]
    let accepted = TransportControlLaunch(arguments: arguments)
    let slow = TransportControlLaunch(arguments: arguments + ["--slow-fixture"])
    #if DEBUG
      for variant in [
        slow, TransportControlLaunch(arguments: arguments + ["--long-album"]),
        TransportControlLaunch(arguments: arguments + ["--quick-connect-fixture"]),
      ] {
        if case .interactive(let value) = variant {
          XCTAssertEqual(value, UUID(uuidString: id))
        } else {
          XCTFail("Interactive fixture variants must use the same isolated startup")
        }
        XCTAssertNil(variant.runID)
      }
      if case .interactive(let value) = accepted {
        XCTAssertEqual(value, UUID(uuidString: id))
      } else {
        XCTFail("The exact invented UI launch must be admitted")
      }
      XCTAssertNil(accepted.runID, "Interactive UI must not prepare inputs, reports or tails")
      if case .rejected = TransportControlLaunch(
        arguments: arguments + ["--quick-connect-fixture", "--saved-account-fixture"])
      {
      } else {
        XCTFail("Sign-in and saved-account fixtures need different starting states")
      }
    #else
      if case .rejected = accepted {} else { XCTFail("Release cannot admit interactive fixtures") }
    #endif
    var normalReads = 0
    let selected = accepted.startup(
      normal: {
        normalReads += 1
        XCTFail("Normal/demo disk, Keychain or persisted installation ID was read")
        return -1
      }, isolated: { 1 })
    XCTAssertEqual(selected, 1)
    XCTAssertEqual(normalReads, 0)
    XCTAssertTrue(slow.startup(normal: { false }, isolated: { true }))
    var nativeFactoryReads = 0
    XCTAssertFalse(
      accepted.startup(
        normal: {
          nativeFactoryReads += 1
          XCTFail("Interactive entry reached the normal NativePlayer/tail factory")
          return true
        }, isolated: { false }),
      "The isolated native constructor must receive tailsEnabled=false")
    let malformed = [
      ["--transport-ui=" + id],
      ["--fixture", "--transport-ui=" + id],
      ["--fixture", "--muted", "--transport-ui="],
      ["--fixture", "--muted", "--transport-ui=invalid"],
      ["--fixture", "--muted", "--transport-ui=" + id + "=extra"],
      arguments + ["--fixture"], arguments + ["--muted"],
      arguments + ["--transport-ui=" + id],
      arguments + ["--slow-fixture", "--slow-fixture"],
      arguments + ["--long-album", "--long-album"],
      arguments + ["--transport-cleanup=" + id],
      arguments + ["--transport-check=" + id],
      arguments + ["--integration"], arguments + ["--connect"],
      arguments + ["--profile-fixture=" + id],
      arguments + ["--catalog-scale=" + id + ":50000"],
      arguments + ["--session-check=" + id], arguments + ["--artwork-check=" + id],
      arguments + ["--window-fixture"], arguments + ["--fixture-rtl"],
      arguments + ["--unknown"], arguments + ["unexpected-payload"],
      arguments + ["--codes-disabled"], arguments + ["--read-only-mix", "--saved-account-fixture"],
      arguments + ["--codes-disabled", "--quick-connect-fixture", "--read-only-mix"],
    ]
    for values in malformed {
      let launch = TransportControlLaunch(arguments: values)
      if case .rejected = launch {} else { XCTFail("Invalid invented entry must be rejected") }
      #if DEBUG
        XCTAssertNil(launch.runID)
      #endif
      XCTAssertEqual(
        launch.startup(
          normal: {
            normalReads += 1
            XCTFail("Rejected entry reached normal/demo storage or Keychain")
            return -1
          }, isolated: { 1 }), 1)
      XCTAssertFalse(
        launch.startup(
          normal: {
            nativeFactoryReads += 1
            XCTFail("Rejected entry reached the normal NativePlayer/tail factory")
            return true
          }, isolated: { false }))
    }
    XCTAssertEqual(normalReads, 0)
    XCTAssertEqual(nativeFactoryReads, 0)
    XCTAssertTrue(
      TransportControlLaunch(arguments: []).startup(normal: { true }, isolated: { false }),
      "Ordinary native initialization retains its enabled-tail default")
    XCTAssertEqual(
      TransportControlLaunch(arguments: []).startup(normal: { 2 }, isolated: { -1 }), 2,
      "Ordinary startup remains under the existing normal owner")
  }
  func testAttemptedEntryNeverSelectsNormalStartup() {
    let id = UUID().uuidString
    let attempts = [
      ["--transport-check=" + id], ["--fixture", "--transport-check=invalid"],
      ["--fixture", "--transport-check=" + id, "--integration"],
      ["--fixture", "--transport-check=" + id, "--session-check=" + id],
      ["--fixture", "--transport-check=" + id, "--artwork-check=" + id],
      ["--fixture", "--transport-check=" + id, "--profile-fixture=" + id],
      ["--fixture", "--transport-check=" + id, "--catalog-scale=" + id + ":50000"],
      ["--fixture", "--transport-check=" + id, "--transport-cleanup=" + id],
      ["--fixture", "--transport-check=" + id], ["--fixture", "--transport-cleanup=" + id],
    ]
    for args in attempts {
      let input = TransportControlLaunch(arguments: args)
      XCTAssertTrue(input.isAttempted)
      XCTAssertEqual(
        input.startup(
          normal: {
            XCTFail("Normal vault/storage/ID accessed")
            return 0
          }, isolated: { 1 }), 1)
    }
    XCTAssertFalse(TransportControlLaunch(arguments: ["--connect"]).isAttempted)
    if case .run(let parsed) = TransportControlLaunch(arguments: [
      "--fixture", "--transport-check=" + id,
    ]) {
      XCTAssertEqual(parsed, UUID(uuidString: id))
    } else {
      XCTFail("Explicit valid run rejected")
    }
  }
  func testCleanupOnlyExactUUIDAndRejectsForeignContent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let other = UUID()
    let folder = TransportControlFiles.directory(in: root, runID: id)
    let sibling = TransportControlFiles.directory(in: root, runID: other)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: ["run_id": other.uuidString])
    try data.write(to: folder.appendingPathComponent("input.json"))
    XCTAssertThrowsError(try TransportControlFiles.cleanup(in: root, runID: id))
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    try JSONSerialization.data(withJSONObject: ["run_id": id.uuidString]).write(
      to: folder.appendingPathComponent("input.json"))
    try TransportControlFiles.cleanup(in: root, runID: id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
  }
  func testCleanupRejectsUnexpectedAndOversizedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = TransportControlFiles.directory(in: root, runID: id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let foreign = folder.appendingPathComponent("unrecognized")
    try Data().write(to: foreign)
    XCTAssertThrowsError(try TransportControlFiles.cleanup(in: root, runID: id))
    try FileManager.default.removeItem(at: foreign)
    try Data(repeating: 0, count: 65537).write(to: folder.appendingPathComponent("input.json"))
    XCTAssertThrowsError(try TransportControlFiles.cleanup(in: root, runID: id))
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
  }
}

final class TransportControlFileGuardTests: XCTestCase {
  func testLiteralRejectsDroppedDNSAndEmptyComponents() {
    XCTAssertTrue(TransportControlFiles.acceptsLiteral("100.64.0.1"))
    for host in [
      "100.64.0.1.example", "100.64.0.1..", "100..64.0.1", "100.064.0.1", "100.128.0.1",
      "100.64.0.256",
    ] {
      XCTAssertFalse(TransportControlFiles.acceptsLiteral(host), host)
    }
  }
  func testLinkedFoldersRejectBeforeInputGetter() throws {
    for ancestor in [false, true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let id = UUID()
      let target = root.appendingPathComponent("invented-linked-target")
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      let namespace = root.appendingPathComponent("JukeboxTransport")
      if ancestor {
        try FileManager.default.createSymbolicLink(at: namespace, withDestinationURL: target)
        try FileManager.default.createDirectory(
          at: target.appendingPathComponent(id.uuidString), withIntermediateDirectories: true)
      } else {
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
          at: namespace.appendingPathComponent(id.uuidString), withDestinationURL: target)
      }
      var read = false
      XCTAssertThrowsError(
        try TransportControlFiles.consumeInput(
          in: root, runID: id,
          read: { _ in
            read = true
            return Data()
          }))
      XCTAssertFalse(read, "Linked target getter was touched")
    }
  }
  func testInputIsOneUseAndExistingReportIsNotReadOrOverwritten() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = TransportControlFiles.directory(in: root, runID: id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let input = folder.appendingPathComponent("input.json")
    let report = folder.appendingPathComponent("report.json")
    let data = try JSONSerialization.data(withJSONObject: ["run_id": id.uuidString])
    try data.write(to: input)
    XCTAssertEqual(try TransportControlFiles.consumeInput(in: root, runID: id), data)
    XCTAssertThrowsError(try TransportControlFiles.consumeInput(in: root, runID: id))
    try data.write(to: input)
    try data.write(to: report)
    var read = false
    XCTAssertThrowsError(
      try TransportControlFiles.consumeInput(
        in: root, runID: id,
        read: { _ in
          read = true
          return data
        }))
    XCTAssertFalse(read, "Existing report must reject before input read")
    XCTAssertThrowsError(try TransportControlFiles.publish(Data("new".utf8), in: root, runID: id))
    XCTAssertEqual(try Data(contentsOf: report), data)
  }
}

private actor HeldTransportControlReply: HTTPTransport {
  private var entered = false
  private var entry: CheckedContinuation<Void, Never>?
  private var reply: CheckedContinuation<Void, Never>?
  func send(_ request: URLRequest) async throws -> HTTPReply {
    entered = true
    entry?.resume()
    entry = nil
    await withCheckedContinuation { reply = $0 }
    return HTTPReply(data: Data("invented".utf8), status: 200)
  }
  func waitForEntry() async { if !entered { await withCheckedContinuation { entry = $0 } } }
  func release() {
    reply?.resume()
    reply = nil
  }
}

@MainActor final class TransportControlPhaseTests: XCTestCase {
  func testFullCaptureKeepsItsPhaseLeaseAndOwnedRetirement() throws {
    let capture = TransportCapture()
    let phase = try TransportControlPhase(capture: capture, policyBits: 7)
    for _ in 0..<32 {
      let ticket = try XCTUnwrap(capture.begin(context: phase.context))
      capture.finish(ticket) { .init(stage: .metadata, http: 200, error: 0, bytes: 1) }
    }
    XCTAssertTrue(phase.current())
    XCTAssertNotNil(phase.snapshot())
    capture.start(policyBits: 7)
    phase.retire()
    XCTAssertEqual(capture.currentState(), .recording, "Retiring old phase erased new capture")
  }
  func testHeldExpiryCancellationAndRearmRejectGetterAndReport() async throws {
    for mode in 0..<3 {
      let capture = TransportCapture()
      let start = ContinuousClock.now
      let phase = try TransportControlPhase(capture: capture, policyBits: 7, now: start)
      let base = HeldTransportControlReply()
      let transport = TransportControlHTTP(phase: phase, base: base)
      let task = Task { @MainActor in
        var extracted = false
        do {
          _ = try await transport.send(URLRequest(url: URL(string: "https://invented.invalid")!))
          extracted = try phase.perform { true }
        } catch {}
        let published = (try? phase.perform { true }) ?? false
        return (extracted, published, phase.snapshot() != nil)
      }
      await base.waitForEntry()
      if mode == 0 { _ = capture.currentState(now: start.advanced(by: .seconds(91))) }
      if mode == 1 { task.cancel() }
      if mode == 2 { capture.start(policyBits: 7) }
      await base.release()
      let (extracted, published, exported) = await task.value
      XCTAssertFalse(extracted, "Held late getter extracted")
      XCTAssertFalse(published, "Expired/cancelled/replaced task published report")
      XCTAssertFalse(exported, "Expired/cancelled/replaced task exported capture")
      if mode != 1 {
        XCTAssertThrowsError(try phase.perform { XCTFail("Stale report published") })
        XCTAssertNil(phase.snapshot())
      }
      phase.retire()
      if mode == 2 { XCTAssertEqual(capture.currentState(), .recording) }
    }
  }
}

private final class ProgressFailureProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "capture-progress.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    if request.url?.lastPathComponent == "before" {
      client?.urlProtocol(
        self, didFailWithError: URLError(.appTransportSecurityRequiresSecureConnection))
      return
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json", "Content-Length": "12"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("hello".utf8))
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
      guard let self else { return }
      self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }
  }
  override func stopLoading() {}
}
