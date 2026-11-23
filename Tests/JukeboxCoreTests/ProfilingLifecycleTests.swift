import XCTest

@testable import JukeboxCore

final class ProfilingCleanupTests: XCTestCase {
  func testProfileAudioIsExactBoundedSilenceUnderOneFreshUUIDAndRetiresWithIt() throws {
    let (root, support, documents, id, folder) = try context()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: folder)
    let audio = try ProfilingFixtureFiles.prepareAudio(support: support, runID: id)
    XCTAssertEqual(audio.deletingLastPathComponent().path, folder.path)
    let bytes = try Data(contentsOf: audio)
    XCTAssertEqual(bytes.count, 17_280_044)
    XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "RIFF")
    XCTAssertEqual(String(decoding: bytes[8..<16], as: UTF8.self), "WAVEfmt ")
    XCTAssertEqual(Array(bytes[20..<36]), [1, 0, 1, 0, 128, 187, 0, 0, 0, 119, 1, 0, 2, 0, 16, 0])
    XCTAssertEqual(String(decoding: bytes[36..<40], as: UTF8.self), "data")
    XCTAssertTrue(bytes.dropFirst(44).allSatisfy { $0 == 0 })
    XCTAssertThrowsError(try ProfilingFixtureFiles.prepareAudio(support: support, runID: id))
    let sibling = support.appendingPathComponent("JukeboxProfiling/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    try ProfilingFixtureFiles.cleanup(support: support, documents: documents, runID: id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
  }
  func testProfileAudioRejectsLinkedOrExistingRunWithoutFollowingOrOverwriting() throws {
    for mode in 0..<4 {
      let (root, support, documents, id, folder) = try context()
      defer { try? FileManager.default.removeItem(at: root) }
      let target = root.appendingPathComponent("invented-target")
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      let sentinel = target.appendingPathComponent("preserved")
      try Data("keep".utf8).write(to: sentinel)
      if mode < 2 {
        let link = mode == 0 ? folder.deletingLastPathComponent() : folder
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      } else if mode == 2 {
        try FileManager.default.createSymbolicLink(
          at: folder.appendingPathComponent(ProfilingFixtureFiles.audioName),
          withDestinationURL: sentinel)
      } else {
        try Data(repeating: 0, count: 10).write(
          to: folder.appendingPathComponent(ProfilingFixtureFiles.audioName))
      }
      XCTAssertThrowsError(try ProfilingFixtureFiles.prepareAudio(support: support, runID: id))
      XCTAssertThrowsError(
        try ProfilingFixtureFiles.cleanup(support: support, documents: documents, runID: id))
      XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
      if mode < 2 {
        let link = mode == 0 ? folder.deletingLastPathComponent() : folder
        XCTAssertEqual(
          try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
      } else {
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
      }
    }
  }
  func testIdleTimerLeasePreservesPriorValueAndRestoresOnlyOnce() {
    for prior in [false, true] {
      var state = ProfilingIdleTimerState()
      XCTAssertNil(state.restore(), "Ordinary startup must not acquire an override")
      XCTAssertTrue(state.begin(current: prior))
      XCTAssertFalse(state.begin(current: !prior), "Repeated setup cannot adopt its own override")
      XCTAssertEqual(state.restore(), prior)
      XCTAssertNil(state.restore(), "Finish/cancel/retire cannot overwrite a later owner")
      XCTAssertTrue(state.begin(current: !prior))
      XCTAssertEqual(state.restore(), !prior)
    }
  }

  func testOwnSettingsModifierRequiresAValidNonCleanupProfileRun() {
    let id = UUID().uuidString
    let modifier = "--profile-background-settings"
    let accepted = ProfilingLaunch(arguments: ["--fixture", "--profile-fixture=" + id, modifier])
    XCTAssertEqual(accepted.runID?.uuidString, id)
    for args in [
      [modifier], ["--fixture", modifier],
      ["--fixture", "--profile-fixture=" + id, modifier, modifier],
      ["--fixture", "--profile-fixture=" + id, modifier, "--profile-cleanup"],
      ["--fixture", "--profile-inspect-report=" + id, modifier],
      ["--fixture", "--profile-fixture=" + id, modifier, "--integration"],
    ] {
      let input = ProfilingLaunch(arguments: args)
      XCTAssertTrue(input.isRejected)
      XCTAssertEqual(
        input.startup(
          normal: {
            XCTFail("Normal startup")
            return 0
          },
          fixture: { _ in
            XCTFail("Invalid profile run")
            return 2
          }, isolated: { 1 }), 1)
    }
    XCTAssertFalse(ProfilingLaunch(arguments: ["--connect"]).isAttempted)
  }

  func testCleanupAndInspectionUseIsolatedFactoriesInAllBuilds() {
    let id = UUID().uuidString
    for flags in [
      ["--fixture", "--profile-fixture=" + id, "--profile-cleanup"],
      ["--fixture", "--profile-inspect-report=" + id],
      ["--fixture", "--profile-inspect-cleanup=" + id],
    ] {
      let input = ProfilingLaunch(arguments: flags)
      XCTAssertFalse(input.isRejected)
      XCTAssertEqual(
        input.startup(
          normal: {
            XCTFail("Normal Release bootstrap")
            return 0
          },
          fixture: { _ in
            XCTFail("Cleanup created a run")
            return 2
          }, isolated: { 1 }), 1)
    }
  }
  func testDanglingExactPathsRejectWithoutCreationOrDeletion() throws {
    for mode in 0..<3 {
      let (root, support, documents, id, folder) = try context()
      defer { try? FileManager.default.removeItem(at: root) }
      let target = root.appendingPathComponent("absent-invented-target")
      let link =
        mode == 0
        ? folder.deletingLastPathComponent()
        : mode == 1 ? folder : documents.appendingPathComponent("profiling-report.json")
      if mode != 2 { try FileManager.default.removeItem(at: link) }
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      XCTAssertThrowsError(
        try ProfilingFixtureFiles.cleanup(support: support, documents: documents, runID: id))
      if mode != 2 {
        XCTAssertThrowsError(try ProfilingFixtureFiles.freshDirectory(support: support, runID: id))
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }
  }
  func testInspectionExportsOnlyOpaqueIdentityAndClearsOnlyOwnReceipt() throws {
    let (root, _, documents, id, _) = try context()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = documents.appendingPathComponent("profiling-report.json")
    let reportBytes = try JSONSerialization.data(withJSONObject: [
      "marker": "JUKEBOX-PROFILE-1", "runID": id.uuidString,
      "samples": ["invented-payload-never-export"],
    ])
    try reportBytes.write(to: report)
    let request = UUID()
    let other = UUID()
    try ProfilingFixtureFiles.inspectReport(documents: documents, requestID: other)
    try ProfilingFixtureFiles.inspectReport(documents: documents, requestID: request)
    let receipt = ProfilingFixtureFiles.inspectionURL(documents: documents, requestID: request)
    let data = try Data(contentsOf: receipt)
    let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(value.keys), Set(["marker", "requestID", "result", "reportID"]))
    XCTAssertEqual(value["reportID"] as? String, id.uuidString)
    XCTAssertEqual(value["requestID"] as? String, request.uuidString)
    XCTAssertEqual(value["result"] as? String, "valid")
    XCTAssertLessThanOrEqual(data.count, 512)
    XCTAssertThrowsError(
      try ProfilingFixtureFiles.inspectReport(documents: documents, requestID: request))
    XCTAssertEqual(try Data(contentsOf: report), reportBytes)
    try ProfilingFixtureFiles.clearInspection(documents: documents, requestID: request)
    XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: ProfilingFixtureFiles.inspectionURL(documents: documents, requestID: other).path))
  }
  func testInspectionRejectsUnsafeLegacyReportAndExportsNoPayload() throws {
    for mode in 0..<5 {
      let (root, _, documents, _, _) = try context()
      defer { try? FileManager.default.removeItem(at: root) }
      let report = documents.appendingPathComponent("profiling-report.json")
      let target = root.appendingPathComponent("invented-target")
      if mode == 0 || mode == 1 {
        if mode == 0 { try Data("never read linked target".utf8).write(to: target) }
        try FileManager.default.createSymbolicLink(at: report, withDestinationURL: target)
      } else if mode == 2 {
        try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
      } else {
        try Data(repeating: 0, count: mode == 3 ? 300_001 : 3).write(to: report)
      }
      let request = UUID()
      try ProfilingFixtureFiles.inspectReport(documents: documents, requestID: request)
      let receipt = ProfilingFixtureFiles.inspectionURL(documents: documents, requestID: request)
      let value = try JSONDecoder().decode(
        ProfilingFixtureFiles.IdentityReceipt.self, from: Data(contentsOf: receipt))
      XCTAssertEqual(value.result, "rejected")
      XCTAssertNil(value.reportID)
      try ProfilingFixtureFiles.clearInspection(documents: documents, requestID: request)
      if mode == 0 {
        XCTAssertEqual(try Data(contentsOf: target), Data("never read linked target".utf8))
      }
    }
  }
  func testReceiptFreshnessAndRetirementRejectLinkedMalformedOrWrongOwner() throws {
    for mode in 0..<4 {
      let (root, _, documents, _, _) = try context()
      defer { try? FileManager.default.removeItem(at: root) }
      let request = UUID()
      let receipt = ProfilingFixtureFiles.inspectionURL(documents: documents, requestID: request)
      if mode < 2 {
        let target = root.appendingPathComponent("invented-target")
        if mode == 0 { try Data("preserve".utf8).write(to: target) }
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: target)
      } else if mode == 2 {
        try Data("malformed".utf8).write(to: receipt)
      } else {
        try JSONEncoder().encode(
          ProfilingFixtureFiles.IdentityReceipt(
            marker: "JUKEBOX-PROFILE-IDENTITY-1", requestID: UUID(), result: "absent", reportID: nil
          )
        ).write(to: receipt)
      }
      XCTAssertThrowsError(
        try ProfilingFixtureFiles.inspectReport(documents: documents, requestID: request))
      XCTAssertThrowsError(
        try ProfilingFixtureFiles.clearInspection(documents: documents, requestID: request))
      XCTAssertNotNil(try FileManager.default.attributesOfItem(atPath: receipt.path)[.type])
    }
  }

  func testAttemptedInvalidProfileNeverReachesNormalStorageVaultOrID() {
    let id = UUID().uuidString
    let cases = [
      ["--profile-fixture=" + id], ["--profile-cleanup"], ["--fixture", "--profile-fixture=bad"],
      ["--fixture", "--profile-fixture=" + id, "--profile-fixture=" + id],
      ["--fixture", "--profile-fixture=" + id, "--integration"],
      ["--fixture", "--profile-fixture=" + id, "--connect"],
      ["--fixture", "--profile-fixture=" + id, "--catalog-scale=" + id + ":50000"],
      ["--fixture", "--profile-fixture=" + id, "--transport-check=" + id],
      ["--fixture", "--profile-fixture=" + id, "--profile-cleanup", "--profile-albums"],
      ["--fixture", "--profile-unknown"], ["--profile"],
      ["--fixture", "--profile-inspect-report=" + id, "--integration"],
      ["--fixture", "--profile-inspect-cleanup=" + id, "--profile-fixture=" + id],
    ]
    for args in cases {
      let input = ProfilingLaunch(arguments: args)
      XCTAssertTrue(input.isAttempted)
      XCTAssertTrue(input.isRejected)
      XCTAssertEqual(
        input.startup(
          normal: {
            XCTFail("Normal storage/vault/ID accessed")
            return 0
          },
          fixture: { _ in
            XCTFail("Rejected UUID directory created")
            return 2
          }, isolated: { 1 }), 1)
    }
    XCTAssertFalse(ProfilingLaunch(arguments: ["--connect"]).isAttempted)
    for flags in [
      ["--fixture", "--profile-fixture=" + id],
      ["--fixture", "--profile-fixture=" + id, "--profile-cleanup"],
    ] {
      XCTAssertFalse(ProfilingLaunch(arguments: flags).isRejected)
    }
  }
  func testFreshDirectoryDoesNotCreateAndRejectsReusedOrLinkedNamespace() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = try ProfilingFixtureFiles.freshDirectory(support: root, runID: id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    XCTAssertThrowsError(try ProfilingFixtureFiles.freshDirectory(support: root, runID: id))
    try FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    let target = root.appendingPathComponent("invented-target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: folder.deletingLastPathComponent(), withDestinationURL: target)
    XCTAssertThrowsError(try ProfilingFixtureFiles.freshDirectory(support: root, runID: id))
  }
  private func context() throws -> (URL, URL, URL, UUID, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let support = root.appendingPathComponent("Support")
    let documents = root.appendingPathComponent("Documents")
    let id = UUID()
    let folder = support.appendingPathComponent("JukeboxProfiling/" + id.uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    return (root, support, documents, id, folder)
  }
  func testOnlyExactUUIDAndMatchingNumericReportAreRemoved() throws {
    let (root, support, documents, id, folder) = try context()
    defer { try? FileManager.default.removeItem(at: root) }
    let sibling = folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    try Data("invented".utf8).write(to: folder.appendingPathComponent("installation-id"))
    let normal = support.appendingPathComponent("normal-sentinel")
    try Data("preserve".utf8).write(to: normal)
    let report = documents.appendingPathComponent("profiling-report.json")
    try JSONSerialization.data(withJSONObject: [
      "marker": "JUKEBOX-PROFILE-1", "runID": id.uuidString,
    ])
    .write(to: report)
    try ProfilingFixtureFiles.cleanup(support: support, documents: documents, runID: id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    XCTAssertEqual(try Data(contentsOf: normal), Data("preserve".utf8))
  }
  func testOtherRunReportIsPreservedAndMissingRunIsNotCreated() throws {
    let (root, support, documents, id, folder) = try context()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = documents.appendingPathComponent("profiling-report.json")
    let bytes = try JSONSerialization.data(withJSONObject: [
      "marker": "JUKEBOX-PROFILE-1", "runID": UUID().uuidString,
    ])
    try bytes.write(to: report)
    try ProfilingFixtureFiles.cleanup(support: support, documents: documents, runID: id)
    XCTAssertEqual(try Data(contentsOf: report), bytes)
    try ProfilingFixtureFiles.cleanup(support: support, documents: documents, runID: id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertEqual(try Data(contentsOf: report), bytes)
  }
  func testLinkedOwnedAncestorRunAndFileAreRejected() throws {
    for mode in 0..<3 {
      let (root, support, documents, id, folder) = try context()
      defer { try? FileManager.default.removeItem(at: root) }
      let target = root.appendingPathComponent("invented-target")
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      let link =
        mode == 0
        ? folder.deletingLastPathComponent()
        : mode == 1 ? folder : folder.appendingPathComponent("installation-id")
      if mode != 2 { try FileManager.default.removeItem(at: link) }
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      XCTAssertThrowsError(
        try ProfilingFixtureFiles.cleanup(support: support, documents: documents, runID: id))
      XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
  }
  func testMalformedOversizedAndLinkedReportsRejectBeforeDeletion() throws {
    for mode in 0..<3 {
      let (root, support, documents, id, folder) = try context()
      defer { try? FileManager.default.removeItem(at: root) }
      let report = documents.appendingPathComponent("profiling-report.json")
      if mode == 2 {
        let target = root.appendingPathComponent("invented-target")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: report, withDestinationURL: target)
      } else {
        try Data(repeating: 0, count: mode == 0 ? 3 : 300_001).write(to: report)
      }
      XCTAssertThrowsError(
        try ProfilingFixtureFiles.cleanup(support: support, documents: documents, runID: id))
      XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
  }
}
