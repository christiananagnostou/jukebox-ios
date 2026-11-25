import ImageIO
import XCTest

@testable import JukeboxCore

final class CoreTests: XCTestCase {
  func testRemoteReceiptAdmissionSeparatesSessionPauseFromSourceActions() {
    let intent = UUID()
    let occurrence = UUID()
    let source = UUID()
    let authority = PlaybackAuthority(
      account: UUID(), replacement: UUID(), library: "fixture-music")
    let producer = PlaybackRemoteReceipt(
      intent: intent, occurrence: occurrence, authority: authority,
      revision: source)
    XCTAssertTrue(producer.admits(producer, for: .pause))
    XCTAssertTrue(producer.admits(producer, for: .seek(30)))
    for live in [
      PlaybackRemoteReceipt(
        intent: intent, occurrence: UUID(), authority: authority, revision: source),
      PlaybackRemoteReceipt(
        intent: intent, occurrence: occurrence, authority: authority, revision: UUID()),
      PlaybackRemoteReceipt(
        intent: intent, occurrence: UUID(), authority: authority, revision: UUID()),
    ] {
      XCTAssertTrue(
        live.admits(producer, for: .pause),
        "Queued session Pause survives natural item/loop/binding changes")
      for action in [RemoteAction.play, .toggle, .next, .previous, .seek(30)] {
        XCTAssertFalse(live.admits(producer, for: action))
      }
    }
    for live in [
      PlaybackRemoteReceipt(
        intent: UUID(), occurrence: occurrence, authority: authority, revision: source),
      PlaybackRemoteReceipt(
        intent: intent, occurrence: occurrence,
        authority: PlaybackAuthority(
          account: UUID(), replacement: authority.replacement, library: authority.library),
        revision: source),
      PlaybackRemoteReceipt(
        intent: intent, occurrence: occurrence,
        authority: PlaybackAuthority(
          account: authority.account, replacement: UUID(), library: authority.library),
        revision: source),
      PlaybackRemoteReceipt(
        intent: intent, occurrence: occurrence, authority: nil, revision: source),
    ] {
      XCTAssertFalse(
        live.admits(producer, for: .pause),
        "Explicit intent/account/replacement retirement denies even Pause")
      XCTAssertFalse(live.admits(producer, for: .seek(30)))
    }
    let duringActivation = PlaybackRemoteReceipt(
      intent: intent, occurrence: occurrence,
      authority: authority, revision: UUID())
    XCTAssertFalse(duringActivation.admits(producer, for: .seek(30)))
    XCTAssertTrue(duringActivation.admits(producer, for: .pause))
  }
  func testCatalogLayoutAndSharedPreferencesPersistWithIndependentLeaseRevisions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try LibraryStorage(directory: directory)
    let first = String(repeating: "a", count: 64)
    let other = String(repeating: "b", count: 64)
    let lease = await storage.lease(account: first)
    var preferences = CatalogBrowsePreferences()
    preferences.favoritesOnly = true
    preferences.years = try XCTUnwrap(CatalogYearRange(lower: 1951, upper: 2025))
    preferences.sorts[.albums] = .year
    try await storage.saveCatalogPreferencesIfCurrent(
      preferences, account: first, lease: lease, revision: 900)
    try await storage.saveIfCurrent(
      QueueState(entries: [QueueEntry(MusicItem.fixtureTracks[0])], position: 2),
      account: first, lease: lease, revision: 1)
    try await storage.saveCatalogDevicePreferences(.init(layout: .list), revision: 10)
    try await storage.saveCatalogDevicePreferences(.init(layout: .grid), revision: 9)
    let reopened = try LibraryStorage(directory: directory)
    let layout = try await reopened.catalogDevicePreferences().layout
    let restored = try await reopened.catalogPreferences(account: first)
    let unrelated = try await reopened.catalogPreferences(account: other)
    let queue = try await reopened.restore(account: first)
    XCTAssertEqual(layout, .list)
    XCTAssertEqual(restored, preferences)
    XCTAssertEqual(unrelated, CatalogBrowsePreferences())
    XCTAssertEqual(queue?.position, 2)
    XCTAssertEqual(restored.options(for: .artists).sort, .title)
    XCTAssertTrue(restored.options(for: .artists).favoritesOnly)
    XCTAssertEqual(restored.options(for: .songs).years, preferences.years)
    try await storage.retire(account: first, erase: false)
    try await storage.saveCatalogPreferencesIfCurrent(
      CatalogBrowsePreferences(), account: first, lease: lease, revision: 901)
    let afterRetirement = try await storage.catalogPreferences(account: first)
    XCTAssertEqual(afterRetirement, preferences)
    XCTAssertFalse(preferences.years.isAll)
    XCTAssertFalse(preferences.years.contains(nil))
    XCTAssertTrue(CatalogYearRange.all.contains(nil))
    XCTAssertNil(CatalogYearRange(lower: 2025, upper: 1951))
  }
  func testPausedSourceClockSurvivesStaleMetadataAcrossReopenAndRevalidation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let account = Connection(
      server: try ServerAddress("https://fixture.test"), userID: "clock", username: "Fixture"
    ).id
    let storage = try LibraryStorage(directory: directory)
    let state = QueueState(entries: [QueueEntry(MusicItem.fixtureTracks[0])], position: 25)
    try await storage.save(state, account: account)
    let reopened = try LibraryStorage(directory: directory)
    let saved = try await reopened.restore(account: account)
    var restored = try XCTUnwrap(saved)
    restored.reconcile(MusicItem.fixtureTracks)
    XCTAssertEqual(restored.current?.id, state.current?.id)
    XCTAssertEqual(restored.position, 25)
    restored.remove([try XCTUnwrap(restored.current?.id)])
    XCTAssertEqual(restored.position, 0)
  }
  func testPlaybackDeadlineUsesForwardClockAndExplicitResetRatherThanWallTimerOrBackwardSamples() {
    var deadline = PlaybackProgressDeadline(timeout: 15)
    deadline.reset(at: 100, position: 4)
    XCTAssertEqual(deadline.stallStep, .playbackAudio)
    XCTAssertFalse(deadline.expired(at: 114.9, position: 4))
    XCTAssertTrue(deadline.expired(at: 115, position: 4))
    XCTAssertEqual(deadline.stallStep, .playbackAudio)
    deadline.reset(at: 200, position: 4)
    XCTAssertFalse(deadline.expired(at: 214, position: 4.5))
    XCTAssertFalse(deadline.expired(at: 228, position: 4.4))
    XCTAssertTrue(deadline.expired(at: 229, position: 4.4))
    XCTAssertEqual(deadline.stallStep, .playbackProgress)
    deadline.reset(at: 300, position: 0)
    XCTAssertFalse(deadline.expired(at: 314, position: .nan))
    XCTAssertTrue(deadline.expired(at: 315, position: .nan))
    deadline.reset(at: 400, position: 100)
    XCTAssertEqual(deadline.stallStep, .playbackAudio)
    XCTAssertFalse(deadline.expired(at: 401, position: 100.1))
    XCTAssertTrue(deadline.expired(at: 416, position: 0))
    deadline.reset(at: 416, position: 0)
    XCTAssertFalse(deadline.expired(at: 417, position: 0.5))
  }

  func testPrecisePreparationUsesOriginalAnchorAndReturnsOnceToNormalStallDeadline() {
    var deadline = PlaybackProgressDeadline()
    deadline.reset(at: 149, position: 30, preparationStartedAt: 100)
    XCTAssertFalse(deadline.expired(at: 159.999, position: 30))
    XCTAssertTrue(deadline.expired(at: 160, position: 30))
    deadline.reset(at: 100, preparationStartedAt: 100)
    XCTAssertFalse(deadline.expired(at: 142.672, position: 0, ready: true))
    XCTAssertFalse(deadline.expired(at: 157.671, position: 0, ready: true))
    XCTAssertTrue(deadline.expired(at: 157.672, position: -1, ready: true))
    deadline.reset(at: 200, preparationStartedAt: 200)
    XCTAssertFalse(deadline.expired(at: 242.672, position: 0.5))
    XCTAssertFalse(deadline.expired(at: 257.671, position: 0.5))
    XCTAssertTrue(deadline.expired(at: 257.672, position: .nan))
    deadline.reset(at: 300, position: 30)
    XCTAssertFalse(deadline.expired(at: 314.999, position: 30, ready: true))
    XCTAssertTrue(deadline.expired(at: 315, position: 30, ready: true))
    deadline.reset(at: 400, preparationStartedAt: 400)
    XCTAssertFalse(deadline.expired(at: 459.999, position: .nan))
    deadline.reset(at: 460)
    XCTAssertTrue(deadline.expired(at: 475, position: 0))
  }

  func testReadyDuringAwaitedInitialSeekKeepsOrdinaryDeadlineAcrossStartCompletion() {
    var deadline = PlaybackProgressDeadline()
    deadline.reset(at: 0, position: 30, preparationStartedAt: 0)
    XCTAssertFalse(deadline.expired(at: 4.999, position: 0))
    deadline.markReady(at: 5)
    XCTAssertFalse(deadline.expired(at: 15, position: 0, ready: true))
    deadline.markReady(at: 18)
    XCTAssertFalse(deadline.expired(at: 19.999, position: 30, ready: true))
    XCTAssertTrue(deadline.expired(at: 20, position: 30, ready: true))
    deadline.reset(at: 100, preparationStartedAt: 100)
    XCTAssertFalse(deadline.expired(at: 159.999, position: 0))
    XCTAssertTrue(deadline.expired(at: 160, position: 0))
  }

  func testPresentationDurationKeepsCatalogHintUntilNativeTimingArrivesOrClockOutgrowsIt() {
    let entry = QueueEntry(MusicItem.fixtureTracks[0])
    for native in [nil, Double.nan, .infinity, -.infinity, 0, -1] {
      XCTAssertEqual(entry.playbackDuration(nativeDuration: native, position: 3.25), 18)
    }
    XCTAssertEqual(entry.playbackDuration(nativeDuration: nil, position: 18.25), 18)
    XCTAssertNil(entry.playbackDuration(nativeDuration: nil, position: 18.250_001))
    XCTAssertNil(entry.playbackDuration(nativeDuration: nil, position: .nan))
    XCTAssertNil(entry.playbackDuration(nativeDuration: nil, position: .infinity))
    XCTAssertNil(entry.playbackDuration(nativeDuration: nil, position: -.infinity))
    XCTAssertEqual(entry.playbackDuration(nativeDuration: 37.137, position: 22), 37.137)
    XCTAssertEqual(entry.playbackDuration(nativeDuration: 12, position: 22), 12)
    XCTAssertEqual(entry.playbackDuration(nativeDuration: 52.137, position: 44.25), 52.137)
  }
  func testPresentationDurationRejectsUnknownHintsAndPreservesAbsoluteTailTotals() {
    for hint in [0.0, -1, .nan, .infinity, -.infinity] {
      let entry = QueueEntry(
        MusicItem(
          id: "invented-timeline", title: "Authored", artist: "Fixture", album: "Timing",
          duration: hint, number: 1, kind: "Audio", imageID: nil, imageTag: nil))
      XCTAssertNil(entry.playbackDuration(nativeDuration: nil, position: 4))
      XCTAssertEqual(entry.playbackDuration(nativeDuration: 52.137, position: 44.25), 52.137)
    }
    let entry = QueueEntry(
      MusicItem(
        id: "invented-tail", title: "Authored tail", artist: "Fixture", album: "Timing",
        duration: 120, number: 1, kind: "Audio", imageID: nil, imageTag: nil))
    XCTAssertEqual(entry.playbackDuration(nativeDuration: nil, position: 44.25), 120)
    XCTAssertEqual(entry.playbackDuration(nativeDuration: 52.137, position: 44.25), 52.137)
  }

  func testDeferredOriginalPrecisionKeepsAuthorizedStaticURLAndOrigin() throws {
    let url = URL(string: "https://fixture.invalid/base/audio.flac?MediaSourceId=invented")!
    let source = MediaSource(
      url: url, quality: .original, preciseSeekingRequired: true, serverDuration: 90.56)
    for position in [0.0, 0.000_000_1, 7.25, 90.56] {
      let selected = try source.starting(at: position)
      let repeated = try selected.starting(at: position)
      XCTAssertEqual(selected.preferPreciseTiming, position > 0)
      XCTAssertTrue(selected.preciseSeekingRequired)
      XCTAssertEqual(repeated.url, url)
      XCTAssertEqual(repeated.timeOrigin, 0)
      XCTAssertEqual(repeated.serverDuration, 90.56)
      XCTAssertEqual(repeated.preferPreciseTiming, selected.preferPreciseTiming)
      XCTAssertFalse(try selected.starting(at: 0).preferPreciseTiming)
    }
    for position in [-1.0, .nan, .infinity, -.infinity] {
      XCTAssertThrowsError(try source.starting(at: position))
    }
    let fixture = MediaSource(url: url, quality: .original, preferPreciseTiming: true)
    XCTAssertFalse(fixture.preciseSeekingRequired)
    XCTAssertTrue(try fixture.starting(at: 0).preferPreciseTiming)
    XCTAssertTrue(try fixture.starting(at: 7.25).preferPreciseTiming)
  }

  func testTranscodeOriginsUseDotNetTicksWithoutAccumulatingSeekBases() throws {
    let source = MediaSource(
      url: URL(string: "https://fixture.invalid/base/audio.mp3?MediaSourceId=invented")!,
      quality: .high,
      serverTimeSeek: true, maximumTimeOrigin: 85.56, serverDuration: 90.56)
    for (position, ticks) in [
      (0.0, Int64(0)), (0.000_000_1, 1), (20.125, 201_250_000),
      (90.56, 855_600_000),
    ] {
      let tail = try source.starting(at: position)
      let repeated = try tail.starting(at: position)
      let query = URLComponents(url: repeated.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      XCTAssertEqual(query.filter { $0.name == "StartTimeTicks" }.map(\.value), [String(ticks)])
      XCTAssertEqual(repeated.timeOrigin, Double(ticks) / 10_000_000)
      XCTAssertEqual(repeated.serverDuration, 90.56)
      XCTAssertEqual(repeated.maximumTimeOrigin, 85.56)
      XCTAssertEqual(query.first { $0.name == "CopyTimestamps" }?.value, "false")
      XCTAssertEqual(query.first { $0.name == "MediaSourceId" }?.value, "invented")
      XCTAssertEqual(repeated.timeOrigin, tail.timeOrigin, "Replacement does not compound origin")
    }
    for position in [-1.0, .nan, .infinity, -.infinity, Double(Int64.max)] {
      XCTAssertThrowsError(try source.starting(at: position))
    }
  }

  func testTranscodeTailRejectsLegacyOffsetAndSessionOverrides() throws {
    var fields = Array(repeating: "", count: 21)
    fields[14] = "0"
    fields[20] = "invented-reused-session"
    let legacy = fields.joined(separator: ";")
    for quality in [StreamQuality.high, .compact] {
      for key in ["Params", "params", "pArAmS", "P%61rams"] {
        for value in [legacy, legacy.replacingOccurrences(of: ";", with: "%3B")] {
          let url = try XCTUnwrap(
            URL(string: "https://fixture.test/base/audio/item/stream.mp3?\(key)=\(value)"))
          let source = MediaSource(
            url: url, quality: quality, serverTimeSeek: true, maximumTimeOrigin: 90)
          for position in [0.0, 7.5, 79.062] {
            XCTAssertThrowsError(try source.starting(at: position)) { error in
              XCTAssertEqual(error as? ClientError, .invalidResponse)
            }
          }
          XCTAssertEqual(source.url, url)
          XCTAssertEqual(source.timeOrigin, 0, "Rejected preparation cannot accept another clock")
        }
      }
    }
    let duplicate = try XCTUnwrap(
      URL(string: "https://fixture.test/audio/item?Params=&params=\(legacy)"))
    XCTAssertThrowsError(
      try MediaSource(url: duplicate, quality: .high, serverTimeSeek: true).starting(at: 0))
  }
  func testNamedTranscodeTailsPreserveBenignParametersAndUseFreshSessions() throws {
    for value in [String?.none, "", " \t\n"] {
      var parts = URLComponents(string: "https://fixture.test/base/audio/item/stream.mp3")!
      parts.queryItems = [
        .init(name: "AudioBitrate", value: "192000"),
        .init(name: "MediaSourceId", value: "invented"),
        .init(name: "StartTimeTicks", value: "0"),
        .init(name: "PlaySessionId", value: "invented-old-session"),
      ]
      if let value { parts.queryItems!.append(.init(name: "Params", value: value)) }
      let source = MediaSource(
        url: try XCTUnwrap(parts.url), quality: .high, serverTimeSeek: true,
        maximumTimeOrigin: 90)
      let first = try source.starting(at: 79.062)
      let second = try source.starting(at: 79.062)
      let firstFields = try XCTUnwrap(
        URLComponents(url: first.url, resolvingAgainstBaseURL: false)?.queryItems)
      let secondFields = try XCTUnwrap(
        URLComponents(url: second.url, resolvingAgainstBaseURL: false)?.queryItems)
      XCTAssertEqual(first.timeOrigin, 79.062, accuracy: 0.000001)
      XCTAssertEqual(firstFields.filter { $0.name == "StartTimeTicks" }.map(\.value), ["790620000"])
      XCTAssertEqual(firstFields.filter { $0.name == "CopyTimestamps" }.map(\.value), ["false"])
      XCTAssertEqual(firstFields.first { $0.name == "MediaSourceId" }?.value, "invented")
      XCTAssertEqual(firstFields.first { $0.name == "Params" }?.value, value)
      let session = firstFields.filter { $0.name == "PlaySessionId" }
      XCTAssertEqual(session.count, 1)
      XCTAssertNotEqual(session.first?.value, "invented-old-session")
      XCTAssertNotEqual(
        session.first?.value, secondFields.first { $0.name == "PlaySessionId" }?.value)
    }
  }
  func testDirectOriginalSourceDoesNotApplyTranscodeTailParameterPolicy() throws {
    let url = try XCTUnwrap(URL(string: "https://fixture.test/base/audio/item?Params=direct"))
    let source = MediaSource(url: url, quality: .original)
    XCTAssertEqual(try source.starting(at: 79.062).url, url)
    XCTAssertEqual(try source.starting(at: 79.062).timeOrigin, 0)
  }

  func testNegotiatedTranscodeOriginPreservesSecurityAndUsesDotNetTicks() throws {
    let url = URL(
      string:
        "https://fixture.test/base/audio/item/stream.mp3?AudioBitrate=192000&MediaSourceId=invented&startTimeTicks=1&CopyTimestamps=true"
    )!
    let source = MediaSource(
      url: url, quality: .high, serverTimeSeek: true, maximumTimeOrigin: 86.56)
    let tail = try source.starting(at: 76.125)
    let parts = URLComponents(url: tail.url, resolvingAgainstBaseURL: false)!
    XCTAssertEqual(parts.host, "fixture.test")
    XCTAssertEqual(parts.path, "/base/audio/item/stream.mp3")
    XCTAssertEqual(
      parts.queryItems?.filter { $0.name.lowercased() == "starttimeticks" }.map(\.value),
      ["761250000"])
    XCTAssertEqual(
      parts.queryItems?.filter { $0.name.lowercased() == "copytimestamps" }.map(\.value), ["false"])
    XCTAssertEqual(parts.queryItems?.first { $0.name == "MediaSourceId" }?.value, "invented")
    XCTAssertEqual(tail.timeOrigin, 76.125)
    let next = try tail.starting(at: 2)
    XCTAssertEqual(next.timeOrigin, 2)
    XCTAssertEqual(try source.starting(at: 90.56).timeOrigin, 86.56, accuracy: 0.000001)
    let unknown = MediaSource(url: url, quality: .high, serverTimeSeek: true)
    XCTAssertNoThrow(try unknown.starting(at: 0))
    XCTAssertThrowsError(try unknown.starting(at: 10))
    let session = parts.queryItems?.first { $0.name.lowercased() == "playsessionid" }?.value
    let nextSession = URLComponents(url: next.url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name.lowercased() == "playsessionid" }?.value
    XCTAssertEqual(session?.count, 32)
    XCTAssertNotEqual(session, nextSession)
    for bad in [Double.nan, .infinity, -1, 1e18] {
      XCTAssertThrowsError(try source.starting(at: bad))
    }
    let original = MediaSource(url: url, quality: .original, preferPreciseTiming: true)
    XCTAssertEqual(try original.starting(at: 76).url, url)
    XCTAssertEqual(try original.starting(at: 76).timeOrigin, 0)
  }

  func testStableNumericVersionFamilies() {
    let families = ServerCompatibility.verifiedFamilies
    XCTAssertEqual(families, ["12.1", "12.2", "12.4"])
    for version in ["12.1", "12.1.0", "12.2", "12.2.5", "12.4", "12.4.0", "12.4.12"] {
      XCTAssertTrue(ServerCompatibility.accepts(version, families: families))
    }
    for version in [
      "12.0.9", "12.3", "12.4.0-rc.1", "12.40.0", "12.10", "12.20.0", "13.0", "12.2.0-beta",
      "12.2.", "12.2.0.1", "12.2-rc", " 12.2",
    ] { XCTAssertFalse(ServerCompatibility.accepts(version, families: families)) }
  }
  func testOlderQueuedSaveCannotOverwriteNewerPausedSnapshot() async throws {
    let storage = LibraryStorage()
    let account = Connection(
      server: try ServerAddress("https://fixture.test"), userID: "a", username: "A"
    ).id
    let lease = await storage.lease(account: account)
    var state = QueueState(entries: [QueueEntry(MusicItem.fixtureTracks[0])], position: 9)
    try await storage.saveIfCurrent(state, account: account, lease: lease, revision: 2)
    state.position = 3
    try await storage.saveIfCurrent(state, account: account, lease: lease, revision: 1)
    let restored = try await storage.restore(account: account)
    XCTAssertEqual(restored?.position, 9)
    try await storage.retire(account: account, erase: true)
    try await storage.saveIfCurrent(state, account: account, lease: lease, revision: 3)
    let absent = try await storage.restore(account: account)
    XCTAssertNil(absent)
  }
  func testRemoteCoverThumbnailRejectsInvalidDataAndKeepsSmallSingleFramePNG() throws {
    let png = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WLjRZ8AAAAASUVORK5CYII="
      ))
    XCTAssertEqual(MusicCoverThumbnail.make(png), png)
    XCTAssertNil(MusicCoverThumbnail.make(Data([0, 1, 2])))
    XCTAssertNil(MusicCoverThumbnail.make(Data(repeating: 0, count: 3_000_001)))
  }
  func testRemoteCoverIsDownsampledBeforeReachingCatalogViews() throws {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 1_200, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let data = NSMutableData()
    let writer = try XCTUnwrap(
      CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(writer))
    let result = try XCTUnwrap(MusicCoverThumbnail.make(data as Data))
    let source = try XCTUnwrap(CGImageSourceCreateWithData(result as CFData, nil))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 600)
    XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 2)
  }
  func testServerAndMediaBoundaries() throws {
    for bad in [
      "file:///tmp/a", "https://u:p@host", "https://host?api_key=x", "https://host/#x", "//host",
    ] { XCTAssertThrowsError(try ServerAddress(bad)) }
    let server = try ServerAddress("HTTPS://Example.test/jellyfin/")
    XCTAssertEqual(server.url.absoluteString, "https://example.test/jellyfin")
    XCTAssertEqual(try server.endpoint("Users/Me").path, "/jellyfin/Users/Me")
    for path in [
      "https://evil.test/Audio/id/stream", "//evil.test/Audio/id/stream",
      "https://example.test/Audio/id/stream", "/jellyfin/Images/a", "/jellyfin/Audio/../x",
    ] { XCTAssertThrowsError(try server.acceptMediaPath(path)) }
    XCTAssertNoThrow(
      try server.acceptMediaPath("/jellyfin/audio/id/stream.mp3?AudioBitRate=192000"))
    XCTAssertThrowsError(
      try server.acceptMediaPath("https://example.test/jellyfin/Audio/../Images/a"))
    let url = try server.acceptMediaPath(
      "/jellyfin/Audio/id/stream.mp3?api_key=old&AudioBitRate=96000")
    XCTAssertEqual(
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter {
        $0.name == "api_key"
      }.map(\.value), [])
  }
  func testMalformedMediaURLFailsClosedWithoutChangingValidSourcePolicy() throws {
    let server = try ServerAddress("https://example.test/jellyfin")
    let base = try XCTUnwrap(URL(string: "https://example.test/jellyfin/"))
    for malformed in ["https://[", "http://[::1"] {
      XCTAssertNil(URL(string: malformed))
      XCTAssertNil(URL(string: malformed, relativeTo: base), "Exercise actual parser rejection")
      XCTAssertThrowsError(try server.acceptMediaPath(malformed)) {
        XCTAssertEqual($0 as? ClientError, .invalidResponse)
      }
    }
    for valid in [
      "Audio/id/stream.mp3?AudioBitRate=96000&token=old",
      "/jellyfin/Audio/id/stream.mp3?Access_Token=old&api_key=old&X-Emby-Token=old&ApiKey=old",
      "https://example.test/jellyfin/Audio/id/stream.mp3?Token=old",
    ] {
      let accepted = try server.acceptMediaPath(valid)
      let parts = try XCTUnwrap(URLComponents(url: accepted, resolvingAgainstBaseURL: false))
      XCTAssertEqual(parts.scheme, "https")
      XCTAssertEqual(parts.host, "example.test")
      XCTAssertEqual(parts.path, "/jellyfin/Audio/id/stream.mp3")
      let credentials = parts.queryItems?.filter {
        ["api_key", "token", "access_token", "x-emby-token", "apikey"].contains(
          $0.name.lowercased())
      }
      XCTAssertTrue(credentials?.isEmpty ?? true)
    }
    for rejected in [
      "http://example.test/jellyfin/Audio/id/stream.mp3",
      "https://u:p@example.test/jellyfin/Audio/id/stream.mp3",
      "https://example.test/jellyfin/Audio/id/stream.mp3#fragment",
      "https://example.test:8443/jellyfin/Audio/id/stream.mp3",
    ] {
      XCTAssertThrowsError(try server.acceptMediaPath(rejected)) {
        XCTAssertEqual($0 as? ClientError, .invalidResponse)
      }
    }
  }
  func testQueueMembershipIdentitySurvivesClocksButSeparatesForksAndDecodedValues() throws {
    let first = QueueEntry(MusicItem.fixtureTracks[0], libraryID: "fixture-music")
    let second = QueueEntry(MusicItem.fixtureTracks[1], libraryID: "fixture-music")
    let original = QueueState(entries: [first], position: 2)
    var left = original
    var right = original
    left.position = 7
    left.index = 0
    left.quality = .high
    XCTAssertEqual(left.membershipRevision, original.membershipRevision)
    left.entries.append(second)
    right.entries.append(first)
    XCTAssertNotEqual(left.membershipRevision, original.membershipRevision)
    XCTAssertNotEqual(right.membershipRevision, original.membershipRevision)
    XCTAssertNotEqual(
      left.membershipRevision, right.membershipRevision,
      "Independent copies with one edit each cannot share an invalidation revision")
    let encoded = try JSONEncoder().encode(left)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["entries", "index", "position", "quality"])
    let decoded = try JSONDecoder().decode(QueueState.self, from: encoded)
    XCTAssertEqual(decoded, left, "Queue value equality must not depend on ephemeral identity")
    XCTAssertNotEqual(decoded.membershipRevision, left.membershipRevision)
    let separatelyCreated = QueueState(
      entries: left.entries, index: left.index, position: left.position, quality: left.quality)
    XCTAssertEqual(separatelyCreated, left)
    XCTAssertNotEqual(separatelyCreated.membershipRevision, left.membershipRevision)
  }
  func testMusicTimeTextIsTotalAtNumericBoundaries() {
    for (seconds, text) in [
      (0.0, "0:00"), (0.99, "0:00"), (59.99, "0:59"), (60, "1:00"), (3600, "60:00"),
    ] {
      XCTAssertEqual(musicTimeText(seconds), text)
    }
    for value in [
      -1.0, -Double.greatestFiniteMagnitude, Double.nan, Double.infinity, -Double.infinity,
      Double.greatestFiniteMagnitude, Double(Int.max),
    ] {
      XCTAssertNil(musicTimeText(value))
    }
    XCTAssertEqual(musicTimeText(-0.0), "0:00")
    if Int.bitWidth == 64 {
      XCTAssertEqual(musicTimeText(Double(Int.max).nextDown), "153722867280912913:04")
    }
  }
  func testPausedReconcileRetainsDuplicateOccurrencesRootAndAcceptedClock() throws {
    let tracks = MusicItem.fixtureTracks
    let entries = [
      QueueEntry(tracks[1], libraryID: "r2"), QueueEntry(tracks[0], libraryID: "r1"),
      QueueEntry(tracks[0]), QueueEntry(tracks[2], libraryID: "r2"),
    ]
    let saved = QueueState(entries: entries, index: 2, position: 17.25, quality: .high)
    var restored = try JSONDecoder().decode(QueueState.self, from: JSONEncoder().encode(saved))
    restored.reconcile([tracks[0], tracks[2], tracks[0]])
    XCTAssertEqual(restored.entries.map(\.id), Array(entries.dropFirst()).map(\.id))
    XCTAssertEqual(restored.entries.map(\.track.id), [tracks[0].id, tracks[0].id, tracks[2].id])
    XCTAssertEqual(restored.entries.map(\.libraryID), ["r1", nil, "r2"])
    XCTAssertEqual(restored.current?.id, entries[2].id)
    XCTAssertNil(restored.current?.libraryID, "Legacy paused snapshots keep nil provenance")
    XCTAssertEqual(restored.index, 1)
    XCTAssertEqual(restored.position, 17.25)
    XCTAssertEqual(restored.quality, .high)
    restored.reconcile([tracks[2]])
    XCTAssertEqual(restored.entries.map(\.id), [entries[3].id])
    XCTAssertEqual(restored.current?.id, entries[3].id)
    XCTAssertEqual(restored.position, 0)
  }
  func testQueueOccurrencesReorderRemovalAndRevocation() {
    let tracks = MusicItem.fixtureTracks
    var queue = QueueState(
      entries: [QueueEntry(tracks[0]), QueueEntry(tracks[0]), QueueEntry(tracks[1])], index: 1,
      position: 5)
    let currentID = queue.current!.id
    queue.move(from: 1, to: 3)
    XCTAssertEqual(queue.current?.id, currentID)
    queue.remove([queue.entries[0].id])
    XCTAssertEqual(queue.current?.id, currentID)
    queue.reconcile([tracks[1]])
    XCTAssertEqual(queue.entries.count, 1)
    XCTAssertEqual(queue.position, 0)
    queue.position = .infinity
    queue.normalize()
    XCTAssertEqual(queue.position, 0)
  }
  func testPersistentReopenAccountIsolationAndLogout() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = Connection(
      server: try ServerAddress("https://a.test"), userID: "alice", username: "Alice")
    let b = Connection(server: a.server, userID: "bob", username: "Bob")
    let c = Connection(
      server: try ServerAddress("https://b.test"), userID: "alice", username: "Alice")
    let store = try LibraryStorage(directory: directory)
    let state = QueueState(
      entries: MusicItem.fixtureTracks.map { QueueEntry($0) }, index: 2, position: 7.25,
      quality: .compact)
    try await store.save(state, account: a.id)
    try await store.save(state, account: b.id)
    let reopened = try LibraryStorage(directory: directory)
    let saved = try await reopened.restore(account: a.id)
    let absent = try await reopened.restore(account: c.id)
    XCTAssertEqual(saved, state)
    XCTAssertNil(absent)
    try await reopened.erase(account: a.id)
    let erased = try await reopened.restore(account: a.id)
    let retained = try await reopened.restore(account: b.id)
    XCTAssertNil(erased)
    XCTAssertEqual(retained, state)
    XCTAssertThrowsError(try ServerAddress("https://a.test?token=secret"))
    let disk = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    XCTAssertFalse(disk.isEmpty)
  }
}
