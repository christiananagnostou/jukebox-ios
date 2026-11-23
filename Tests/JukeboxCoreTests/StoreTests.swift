import Observation
import Synchronization
import XCTest

@testable import JukeboxCore

@MainActor final class StoreTests: XCTestCase {
  func testGlobalLayoutAndAccountPreferencesRestoreWithoutPlayingOrQueueRevisionConflict()
    async throws
  {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    let api = FixtureCatalog(source: URL(string: "https://invented.invalid/audio")!)
    await store.enterFixture(service: api)
    let browser = try XCTUnwrap(store.browser)
    await browser.start()
    store.toggleCatalogLayout()
    store.setCatalogSelectionFeedback(false)
    var options = browser.options
    options.favoritesOnly = true
    browser.selectOptions(options)
    let account = try XCTUnwrap(store.active?.id)
    try await wait {
      let layout = try? await storage.catalogDevicePreferences().layout
      let preferences = try? await storage.catalogPreferences(account: account)
      let feedback = try? await storage.catalogDevicePreferences().selectionFeedback
      return layout == .list && feedback == false && preferences?.favoritesOnly == true
    }
    XCTAssertFalse(store.playbackRequested)
    XCTAssertEqual(store.phase, .paused)
    await store.enterFixture(service: api)
    XCTAssertEqual(store.catalogLayout, .list)
    XCTAssertFalse(store.catalogSelectionFeedback)
    XCTAssertTrue(try XCTUnwrap(store.browser).options.favoritesOnly)
    XCTAssertFalse(store.playbackRequested)
    XCTAssertTrue(store.queue.entries.isEmpty)
  }
  func testRecentAlbumsRequireAcceptedPlayingAndKeepQueueRootAcrossBrowsing() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(
      service: FixtureCatalog(source: URL(string: "https://invented.invalid/audio")!))
    let browser = try XCTUnwrap(store.browser)
    await browser.start()
    let album = CatalogFixtures.album(0)
    driver.startError = PlaybackProblem.nativeStart
    store.playItems(CatalogFixtures.tracks(album), library: "fixture-music")
    try await wait { store.phase == .failed }
    await store.loadRecentAlbums()
    XCTAssertTrue(browser.recentAlbums.isEmpty)
    browser.selectLibrary("fixture-concerts")
    driver.startError = nil
    store.play()
    try await wait { store.playing }
    let account = try XCTUnwrap(store.active?.id)
    try await wait {
      (try? await storage.recentAlbums(account: account, library: "fixture-music")) == [album.id]
    }
    await store.loadRecentAlbums()
    XCTAssertTrue(browser.recentAlbums.isEmpty)
    browser.selectLibrary("fixture-music")
    await store.loadRecentAlbums()
    XCTAssertEqual(browser.recentAlbums.map(\.id), [album.id])
    browser.selectLibrary("fixture-concerts")
    let secondAlbum = CatalogFixtures.album(3)
    store.enqueue(
      CatalogFixtures.tracks(secondAlbum)[0], next: true,
      origin: try XCTUnwrap(store.playbackOrigin(library: "fixture-concerts")))
    store.next()
    try await wait { store.playing && store.current?.track.albumID == secondAlbum.id }
    try await wait {
      (try? await storage.recentAlbums(account: account, library: "fixture-concerts")) == [
        secondAlbum.id
      ]
    }
    let originalRoot = try await storage.recentAlbums(account: account, library: "fixture-music")
    XCTAssertEqual(originalRoot, [album.id])
    let phase = store.phase
    driver.onEvent?(.state(UUID(), .waiting))
    driver.onEvent?(
      .failureDetails(UUID(), .init(step: .playbackAudio, error: PlaybackProblem.stalled)))
    XCTAssertEqual(store.phase, phase)
    await store.logout()
    XCTAssertTrue(browser.recentAlbums.isEmpty)
  }
  func testLatestPlaybackFailureSurvivesRetrySuccessQueueChangesAndDismissButRetires() async throws
  {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    driver.startError = ConnectionStepError(
      step: .audioSession, error: PlaybackProblem.audioSessionPolicy)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { store.phase == .failed }
    let failure = try XCTUnwrap(store.lastPlaybackFailure)
    XCTAssertEqual(failure.detail.step, .audioSession)
    let occurrence = store.current?.id
    store.dismissError()
    XCTAssertNotNil(store.lastPlaybackFailure)
    driver.startError = nil
    store.play()
    try await wait { store.playing }
    XCTAssertEqual(store.current?.id, occurrence)
    store.pause()
    store.enqueue(MusicItem.fixtureTracks[1], next: false)
    XCTAssertEqual(store.lastPlaybackFailure?.time, failure.time)
    await store.logout()
    XCTAssertNil(store.lastPlaybackFailure)
    driver.onEvent?(.failure)
    XCTAssertNil(store.lastPlaybackFailure)
  }
  func testAlbumContextObservationIgnoresClocksButTracksExactDuplicateMembership() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    let source = try await acceptedAlbumSelection(store)
    let selection = PlaybackSelection(
      items: (0..<2_000).map { source.items[$0 % source.items.count] }, origin: source.origin)
    store.playSelection(selection)
    try await wait { store.playing }
    let occurrence = try XCTUnwrap(store.current?.id)
    let invalidations = Mutex(0)
    withObservationTracking {
      XCTAssertTrue(store.selectionIsCurrent(selection))
    } onChange: {
      invalidations.withLock { $0 += 1 }
    }
    for tick in 1...100 {
      driver.onEvent?(.position(occurrence, Double(tick) / 4))
      driver.onEvent?(.timeline(occurrence, duration: 30, seekableEnd: 30))
    }
    XCTAssertEqual(
      invalidations.withLock { $0 }, 0,
      "Clock/timeline changes must not invalidate the complete album-context reader")
    let reordered = PlaybackSelection(
      items: Array(selection.items.reversed()), origin: selection.origin)
    XCTAssertTrue(
      store.selectionIsCurrent(reordered), "Shuffle order retains exact album membership")
    var wrongDuplicates = selection.items
    wrongDuplicates[0] = source.items[1]
    XCTAssertFalse(
      store.selectionIsCurrent(
        PlaybackSelection(
          items: wrongDuplicates, origin: selection.origin)))
    store.enqueueSelection(
      PlaybackSelection(items: [source.items[0]], origin: source.origin), next: false)
    XCTAssertEqual(invalidations.withLock { $0 }, 1)
    XCTAssertFalse(store.selectionIsCurrent(selection))
    let inserted = try XCTUnwrap(store.queue.entries.last?.id)
    store.remove([inserted])
    XCTAssertTrue(store.selectionIsCurrent(selection))
    store.move(from: 0, to: store.queue.entries.count)
    XCTAssertTrue(store.selectionIsCurrent(selection))
  }
  func testAlbumContextKeepsLiveRootAndAccountAuthorityAcrossRetainedMembership() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    await api.respondWithArtwork(nil)
    await store.enterFixture(service: api)
    let selection = try await acceptedAlbumSelection(store)
    store.playSelection(selection)
    try await wait { store.playing }
    let invalidations = Mutex(0)
    withObservationTracking {
      XCTAssertTrue(store.selectionIsCurrent(selection))
    } onChange: {
      invalidations.withLock { $0 += 1 }
    }
    let browser = try XCTUnwrap(store.browser)
    await api.setLibraries(["fixture-concerts"])
    await browser.loadLibraries()
    XCTAssertGreaterThan(invalidations.withLock { $0 }, 0)
    XCTAssertFalse(store.selectionIsCurrent(selection))
    await api.setLibraries(["fixture-concerts", "fixture-music"])
    await browser.loadLibraries()
    XCTAssertFalse(
      store.selectionIsCurrent(selection), "A retired origin must not be revived by ID counts")
    let fresh = try XCTUnwrap(store.playbackSelection(selection.items, library: "fixture-music"))
    XCTAssertNotEqual(fresh.origin, selection.origin)
    XCTAssertTrue(store.queue.entries.isEmpty)
    XCTAssertFalse(store.selectionIsCurrent(fresh))
    XCTAssertFalse(store.playbackRequested, "Matching counts do not acquire playback intent")
    await store.logout()
    XCTAssertFalse(store.selectionIsCurrent(selection))
    await store.enterFixture(service: ControlledCatalog())
    XCTAssertFalse(store.selectionIsCurrent(selection))
  }
  func testRetiredRootDriverCannotRepopulateLatestFailure() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(
      service: FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    let browser = try XCTUnwrap(store.browser)
    await browser.start()
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { store.playing }
    let occurrence = try XCTUnwrap(store.current?.id)
    driver.onEvent?(
      .failureDetails(
        occurrence, ConnectionStepError(step: .playbackAudio, error: PlaybackProblem.stalled)))
    let failure = try XCTUnwrap(store.lastPlaybackFailure)
    XCTAssertNotNil(store.playbackFailureReport(id: failure.id, appVersion: "1(1)"))
    browser.selectLibrary("fixture-concerts")
    XCTAssertNil(store.lastPlaybackFailure)
    XCTAssertNil(store.playbackFailureReport(id: failure.id, appVersion: "1(1)"))
    driver.onEvent?(
      .failureDetails(
        occurrence, ConnectionStepError(step: .playbackAudio, error: PlaybackProblem.stalled)))
    XCTAssertNil(
      store.lastPlaybackFailure, "Retired-root native failure must not repopulate diagnostics")
    driver.onEvent?(.failure)
    XCTAssertNil(
      store.lastPlaybackFailure, "Legacy native failure must retain the same diagnostic fence")
    XCTAssertEqual(store.current?.id, occurrence)
    XCTAssertEqual(store.phase, .failed)
  }
  func testPlaybackFailureCopyRejectsReplacedAndRetiredSnapshot() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    driver.startError = PlaybackProblem.audioSessionPolicy
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { store.phase == .failed }
    let first = try XCTUnwrap(store.lastPlaybackFailure)
    XCTAssertNotNil(store.playbackFailureReport(id: first.id, appVersion: "1(1)"))
    store.dismissError()
    XCTAssertNotNil(store.playbackFailureReport(id: first.id, appVersion: "1(1)"))
    driver.startError = PlaybackProblem.seek
    store.play()
    try await wait { store.lastPlaybackFailure?.id != first.id }
    let replacement = try XCTUnwrap(store.lastPlaybackFailure)
    XCTAssertNil(store.playbackFailureReport(id: first.id, appVersion: "1(1)"))
    XCTAssertNotNil(store.playbackFailureReport(id: replacement.id, appVersion: "1(1)"))
    await store.logout()
    XCTAssertNil(store.playbackFailureReport(id: replacement.id, appVersion: "1(1)"))
  }
  func testRetiredBrowserCallbackCannotClearReplacementFailure() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    let fixture = FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!)
    await store.enterFixture(service: fixture)
    let retired = try XCTUnwrap(store.browser?.libraryRetired)
    store.addConnection()
    await store.enterFixture(service: fixture)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    driver.startError = PlaybackProblem.audioSessionPolicy
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { store.phase == .failed }
    let failure = try XCTUnwrap(store.lastPlaybackFailure)
    retired()
    XCTAssertEqual(store.lastPlaybackFailure?.id, failure.id)
    XCTAssertNotNil(store.playbackFailureReport(id: failure.id, appVersion: "1(1)"))
  }
  func context() throws -> (URL, LibraryStorage, MemoryVault, DriverSpy) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (directory, try LibraryStorage(directory: directory), MemoryVault(), DriverSpy())
  }
  func wait(_ condition: () async -> Bool) async throws {
    for _ in 0..<300 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("condition timed out")
  }
  func testTransportActivationReceiptCannotAdoptReplacementAfterHeldActivation() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let held = ControlledCatalog()
    await held.blockIdentity()
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test", factory: { _, _ in held })
    let connection = Connection(
      server: try ServerAddress("https://invented.invalid"), userID: "invented",
      username: "Invented")
    try await vault.write("invented-token", account: connection.id)
    let activation = Task { await store.activateTransportAcceptance(connection) }
    try await wait { await held.identityEntered }
    store.addConnection()
    let replacementAPI = ControlledCatalog()
    await store.enterFixture(service: replacementAPI)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { store.playing }
    let occurrence = store.current?.id
    let stops = driver.stops
    await held.releaseIdentity()
    let accepted = await activation.value
    XCTAssertNil(accepted, "Suspended activation adopted replacement lease")
    if let accepted { _ = store.retireTransportAcceptance(owned: accepted) }
    XCTAssertEqual(driver.stops, stops, "Old activation cleanup stopped replacement")
    XCTAssertEqual(store.current?.id, occurrence)
    XCTAssertNotNil(store.active)
    XCTAssertTrue(store.playbackRequested)
    await store.logout()
  }
  func testTransportAcceptanceCleanupRejectsReplacementAndCleansOwnCancelledExpiredRun()
    async throws
  {
    var loadedAlbum: PlaybackSelection?
    for replaceAccount in [false, true] {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let api = ControlledCatalog()
      let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
      await store.enterFixture(service: api)
      loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
      let initial = try XCTUnwrap(store.transportAcceptanceLease())
      let old = try store.performTransportAcceptance(
        .play(try XCTUnwrap(loadedAlbum)), owned: initial)
      try await wait { store.playing }
      if replaceAccount {
        await store.enterFixture(service: api)
        loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
        store.playSelection(try XCTUnwrap(loadedAlbum))
      } else {
        store.playSelection(try XCTUnwrap(loadedAlbum))
      }
      try await wait { store.playing }
      let replacement = try XCTUnwrap(store.transportAcceptanceLease())
      let occurrence = store.current?.id
      let stops = driver.stops
      let retiredReplacement = store.retireTransportAcceptance(owned: old)
      XCTAssertFalse(retiredReplacement)
      XCTAssertEqual(driver.stops, stops, "Old cleanup stopped replacement native owner")
      XCTAssertEqual(store.current?.id, occurrence)
      XCTAssertNotNil(store.active)
      XCTAssertTrue(store.playbackRequested)
      let capture = TransportCapture()
      let start = ContinuousClock.now
      capture.start(policyBits: 7, now: start)
      XCTAssertEqual(capture.currentState(now: start.advanced(by: .seconds(91))), .expired)
      let cleanup = Task { store.retireTransportAcceptance(owned: replacement) }
      cleanup.cancel()
      let retiredOwn = await cleanup.value
      XCTAssertTrue(retiredOwn, "Own cancelled/expired run was not cleaned")
      XCTAssertNil(store.active)
      XCTAssertNil(store.current)
      XCTAssertGreaterThan(driver.stops, stops)
    }
  }
  func testPreparationTransportStageRetainsOccurrenceAndDoesNotExposePrivateErrorDetails()
    async throws
  {
    var loadedAlbum: PlaybackSelection?
    for failSource in [true, false] {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let api = ControlledCatalog()
      let failure = URLError(
        .appTransportSecurityRequiresSecureConnection,
        userInfo: [
          NSURLErrorFailingURLStringErrorKey: "http://private.invalid/audio/secret?api_key=secret"
        ])
      if failSource { await api.failMedia(failure) } else { driver.startError = failure }
      let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
      await store.enterFixture(service: api)
      loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
      store.playSelection(try XCTUnwrap(loadedAlbum))
      let occurrence = store.current?.id
      try await wait { store.phase == .failed }
      XCTAssertEqual(store.current?.id, occurrence)
      XCTAssertEqual(store.queue.position, 0)
      XCTAssertFalse(store.playbackRequested)
      XCTAssertTrue(
        store.error?.hasPrefix(failSource ? "Preparing track:" : "Loading audio:") == true)
      XCTAssertTrue(store.error?.contains("iOS blocked") == true)
      XCTAssertFalse(store.error?.contains("private.invalid") == true)
      XCTAssertFalse(store.error?.contains("secret") == true)
      await store.logout()
    }
  }
  func testFreshSourceDurationReplacesCatalogHintWithoutInventingEOF() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
    try await wait { driver.prepared.count == 2 }
    let id = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.sourceDuration(id, 42))
    driver.onEvent?(.timeline(id, duration: nil, seekableEnd: nil))
    XCTAssertEqual(store.playbackDuration, 42)
    XCTAssertEqual(store.seekUpperBound, 42)
    XCTAssertFalse(store.durationIsEstimated)
    XCTAssertEqual(store.durationAccessibilityLabel, "Track duration reported by Jellyfin")
    driver.onEvent?(.position(id, 45))
    XCTAssertEqual(store.queue.position, 45)
    XCTAssertEqual(store.playbackDuration, 42)
    XCTAssertTrue(store.playbackRequested, "A metadata duration cannot manufacture EOF")
    driver.onEvent?(.timeline(id, duration: nil, seekableEnd: 60))
    XCTAssertEqual(store.seekUpperBound, 60)
    store.seek(55)
    XCTAssertEqual(driver.lastSeek, 55)
    driver.onEvent?(.timeline(id, duration: 50, seekableEnd: 50))
    XCTAssertEqual(store.playbackDuration, 50)
    driver.advance()
    XCTAssertNil(store.sourceDuration)
    driver.onEvent?(.sourceDuration(id, 999))
    XCTAssertNil(store.sourceDuration, "Departed-source metadata cannot label the successor")
    let next = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.sourceDuration(next, .infinity))
    XCTAssertNil(store.sourceDuration)
    await store.logout()
  }
  func testNativeDurationOwnsScrubbingWithoutMetadataCompletionAndRetiresOnOccurrenceChange()
    async throws
  {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ControlledCatalog()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { driver.prepared.count == 2 }
    let first = try XCTUnwrap(store.current)
    XCTAssertTrue(store.durationIsEstimated)
    driver.onEvent?(.timeline(first.id, duration: 42, seekableEnd: 42))
    driver.onEvent?(.position(first.id, 22))
    XCTAssertEqual(store.playbackDuration, 42)
    XCTAssertFalse(store.durationIsEstimated)
    XCTAssertEqual(store.queue.index, 0)
    XCTAssertTrue(store.playbackRequested)
    store.seek(30)
    XCTAssertEqual(driver.lastSeek, 30)
    XCTAssertEqual(
      store.queue.position, 22, "Unconfirmed seek intent is not an accepted native clock")
    driver.onEvent?(.position(first.id, 30))
    XCTAssertEqual(store.queue.position, 30)
    store.pause()
    try await store.saveNow()
    let restored = try await storage.restore(account: try XCTUnwrap(store.active?.id))
    XCTAssertEqual(restored?.position, 30)
    store.play()
    XCTAssertEqual(store.queue.position, 30)
    driver.advance()
    XCTAssertNil(store.nativeDuration)
    XCTAssertEqual(store.queue.position, 0)
    driver.onEvent?(.timeline(first.id, duration: 100, seekableEnd: 100))
    driver.onEvent?(.position(first.id, 55))
    XCTAssertNil(store.nativeDuration)
    XCTAssertEqual(store.queue.position, 0)
    await store.logout()
  }
  func testIndefiniteTimelineIsEstimatedThenUnknownWithoutHidingClockOrCompletingAudio()
    async throws
  {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ControlledCatalog()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { driver.starts == 1 }
    let id = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.timeline(id, duration: nil, seekableEnd: 40))
    XCTAssertEqual(store.playbackDuration, 18)
    XCTAssertTrue(store.durationIsEstimated)
    driver.onEvent?(.position(id, 25))
    XCTAssertNil(store.playbackDuration)
    XCTAssertEqual(store.queue.position, 25)
    XCTAssertTrue(store.playbackRequested)
    XCTAssertEqual(store.seekUpperBound, 40)
    store.seek(30)
    XCTAssertEqual(driver.lastSeek, 30)
    driver.onEvent?(.timeline(id, duration: 12, seekableEnd: 12))
    XCTAssertEqual(store.playbackDuration, 12)
    XCTAssertFalse(store.durationIsEstimated)
    store.seek(20)
    XCTAssertEqual(driver.lastSeek, 11.95)
    driver.onEvent?(.timeline(id, duration: .nan, seekableEnd: .infinity))
    XCTAssertNil(store.nativeDuration)
    await store.logout()
    driver.onEvent?(.timeline(id, duration: 99, seekableEnd: 99))
    XCTAssertNil(store.playbackDuration)
  }
  func testFiniteNativeOverrunAndWaitingDoNotInventCompletionOrHideAcceptedClock() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    let selection = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(
      PlaybackSelection(items: Array(selection.items.prefix(2)), origin: selection.origin))
    XCTAssertEqual(store.queue.entries.count, 2)
    try await wait { driver.prepared.count == 2 }
    let first = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.timeline(first, duration: 12, seekableEnd: 12))
    driver.onEvent?(.position(first, 16))
    driver.onEvent?(.state(first, .waiting))
    XCTAssertEqual(
      store.queue.position, 16, "Expose the actual clock rather than clamping evidence")
    XCTAssertEqual(store.playbackDuration, 12)
    XCTAssertFalse(store.durationIsEstimated)
    XCTAssertEqual(store.phase, .waiting)
    XCTAssertTrue(store.playbackRequested)
    XCTAssertEqual(store.queue.index, 0, "Duration alone is never an EOF signal")
    driver.advance()
    let second = try XCTUnwrap(store.current?.id)
    XCTAssertNotEqual(second, first)
    XCTAssertEqual(store.queue.position, 0)
    XCTAssertNil(store.nativeDuration)
    driver.onEvent?(.finished(first))
    XCTAssertEqual(store.current?.id, second, "Late first-item EOF cannot finish its successor")
    XCTAssertTrue(store.playbackRequested)
    driver.finishCurrent()
    XCTAssertFalse(store.playbackRequested)
    XCTAssertEqual(store.phase, .paused)
    await store.logout()
  }
  func testDuplicateTrackTimelineAndFailedRetryCannotLeakOldOccurrenceTiming() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ControlledCatalog()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { driver.starts == 1 }
    let first = try XCTUnwrap(store.current)
    store.enqueue(first.track, next: true)
    XCTAssertEqual(driver.starts, 1)
    XCTAssertEqual(driver.current, first.id)
    let duplicate = store.queue.entries[1]
    store.select(duplicate.id)
    try await wait { driver.starts == 2 }
    driver.onEvent?(.timeline(duplicate.id, duration: 50, seekableEnd: 50))
    driver.onEvent?(.position(duplicate.id, 25))
    driver.onEvent?(.timeline(first.id, duration: 9, seekableEnd: 9))
    XCTAssertEqual(store.playbackDuration, 50)
    store.seek(10, occurrence: first.id)
    XCTAssertEqual(store.queue.position, 25)
    driver.onEvent?(.failure)
    driver.current = nil
    XCTAssertEqual(store.phase, .failed)
    store.play()
    try await wait { driver.starts == 3 }
    XCTAssertEqual(driver.startedPositions.last, 25)
    XCTAssertEqual(store.current?.id, duplicate.id)
    await store.logout()
    await store.enterFixture(service: api)
    driver.onEvent?(.timeline(duplicate.id, duration: 50, seekableEnd: 50))
    XCTAssertNil(store.nativeDuration)
  }
  private func deferredCommandContext(onlyPair: Bool = false, shuffled: Bool = false) async throws
    -> (
      URL, LibraryStorage, MemoryVault, DriverSpy, PlayerStore, LookaheadCatalog, [QueueEntry]
    )
  {
    let (directory, storage, vault, driver) = try context()
    let api = LookaheadCatalog()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    do {
      await store.enterFixture(service: api)
      let selection = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
      store.playSelection(
        PlaybackSelection(
          items: onlyPair ? Array(selection.items.prefix(2)) : selection.items,
          origin: selection.origin))
      try await wait { driver.prepared.count == 2 }
      if shuffled {
        store.toggleShuffle()
        try await wait { driver.prepared.count == 2 }
        XCTAssertTrue(store.shuffleEnabled)
      }
      let entries = store.queue.entries
      driver.onEvent?(.position(entries[0].id, 1))
      driver.prepared.removeFirst()
      driver.current = entries[1].id
      driver.sampledPausePosition = 2.5
      XCTAssertEqual(store.current?.id, entries[0].id)
      XCTAssertEqual(driver.current, entries[1].id)
      XCTAssertEqual(store.queue.position, 1)
      return (directory, storage, vault, driver, store, api, entries)
    } catch {
      await store.logout()
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
  private func deliverDeferredAndOldEvents(_ driver: DriverSpy, entries: [QueueEntry]) {
    driver.onEvent?(.advanced(entries[1].id))
    driver.onEvent?(.position(entries[0].id, 99))
    driver.onEvent?(.advanced(entries[0].id))
  }
  func testDeferredCommandPauseKeepsActualOccurrenceAndAcceptedCheckpoint() async throws {
    let (directory, storage, _, driver, store, _, entries) = try await deferredCommandContext()
    defer { try? FileManager.default.removeItem(at: directory) }
    defer { store.pause() }
    store.pause()
    XCTAssertEqual(store.current?.id, entries[1].id)
    XCTAssertEqual(store.queue.position, 2.5)
    XCTAssertFalse(store.playbackRequested)
    deliverDeferredAndOldEvents(driver, entries: entries)
    XCTAssertEqual(store.current?.id, entries[1].id)
    XCTAssertEqual(store.queue.position, 2.5)
    try await store.saveNow()
    let saved = try await storage.restore(account: try XCTUnwrap(store.active?.id))
    XCTAssertEqual(saved?.current?.id, entries[1].id)
    XCTAssertEqual(saved?.position, 2.5)
    await store.logout()
  }
  func testDeferredCommandSeekSeparatesCurrentIntentFromStaleOccurrenceReceipt() async throws {
    for captured in [false, true] {
      let (directory, storage, _, driver, store, api, entries) = try await deferredCommandContext(
        onlyPair: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      defer { store.pause() }
      let mediaBefore = await api.requests.count
      store.seek(8, occurrence: captured ? entries[0].id : nil)
      XCTAssertEqual(store.current?.id, entries[1].id)
      XCTAssertEqual(store.queue.position, 2.5, "A requested target is not an accepted clock")
      if captured {
        XCTAssertEqual(store.playbackPosition, 2.5)
        let mediaAfter = await api.requests.count
        XCTAssertEqual(mediaAfter, mediaBefore)
        XCTAssertNil(driver.lastSeek, "A retired occurrence must not seek current native B")
      } else {
        XCTAssertEqual(driver.lastSeek, 8)
        XCTAssertEqual(driver.seekOccurrences.last ?? nil, entries[1].id)
      }
      deliverDeferredAndOldEvents(driver, entries: entries)
      if !captured, let request = driver.seekRequests.last {
        driver.onEvent?(.seekCompleted(entries[1].id, 8, request: request))
      }
      XCTAssertEqual(store.current?.id, entries[1].id)
      XCTAssertEqual(store.queue.position, captured ? 2.5 : 8)
      try await store.saveNow()
      let saved = try await storage.restore(account: try XCTUnwrap(store.active?.id))
      XCTAssertEqual(saved?.current?.id, entries[1].id)
      XCTAssertEqual(saved?.position, captured ? 2.5 : 8)
      await store.logout()
    }
  }
  func testDeferredCommandQualityHoldsAcceptedBClockDuringNegotiation() async throws {
    let (directory, storage, _, driver, store, api, entries) = try await deferredCommandContext()
    defer { try? FileManager.default.removeItem(at: directory) }
    await api.block(3)
    await api.block(4)
    store.quality(.high)
    let settled = store.deferredPlaybackSettlementForCheck()
    let startsBeforeRelease = driver.starts
    do {
      try await wait { await api.requests.contains { $0.1 == .high } }
      let requests = await api.requests
      XCTAssertEqual(requests.first { $0.1 == .high }?.0, entries[1].track.id)
      XCTAssertEqual(store.current?.id, entries[1].id)
      XCTAssertEqual(store.queue.position, 2.5)
      XCTAssertEqual(store.queue.quality, .high)
      try await store.saveNow()
      let saved = try await storage.restore(account: try XCTUnwrap(store.active?.id))
      XCTAssertEqual(saved?.current?.id, entries[1].id)
      XCTAssertEqual(saved?.position, 2.5)
      deliverDeferredAndOldEvents(driver, entries: entries)
      XCTAssertEqual(store.current?.id, entries[1].id)
      XCTAssertEqual(store.queue.position, 2.5)
    } catch {
      store.pause()
      await api.release(3)
      await api.release(4)
      await settled()
      await store.logout()
      throw error
    }
    store.pause()
    await api.release(3)
    await api.release(4)
    await settled()
    XCTAssertEqual(
      driver.starts, startsBeforeRelease, "Released canceled work cannot start after Pause")
    XCTAssertFalse(store.playbackRequested)
    await store.logout()
  }
  func testDeferredCommandRemovalUsesActualCurrentBeforeChoosingSuccessor() async throws {
    for kind in ["departed", "future", "current", "departed-and-current", "all"] {
      let (directory, storage, _, driver, store, _, entries) = try await deferredCommandContext()
      defer { try? FileManager.default.removeItem(at: directory) }
      defer { store.pause() }
      let removing: Set<UUID> =
        switch kind {
        case "departed": [entries[0].id]
        case "future": [entries[2].id]
        case "current": [entries[1].id]
        case "departed-and-current": [entries[0].id, entries[1].id]
        default: Set(entries.map(\.id))
        }
      let startsBeforeEdit = driver.starts
      store.remove(removing)
      let removedCurrent = removing.contains(entries[1].id)
      let expected = kind == "all" ? nil : entries[removedCurrent ? 2 : 1].id
      let position = removedCurrent ? 0.0 : 2.5
      XCTAssertEqual(store.current?.id, expected, kind)
      XCTAssertEqual(store.queue.position, position, kind)
      try await wait { driver.current != nil || !store.playbackRequested }
      XCTAssertEqual(driver.current, expected, kind)
      XCTAssertEqual(
        store.queue.entries.map(\.id), entries.filter { !removing.contains($0.id) }.map(\.id), kind)
      if driver.starts > startsBeforeEdit {
        XCTAssertEqual(driver.startedPositions.last, position, kind)
      }
      deliverDeferredAndOldEvents(driver, entries: entries)
      XCTAssertEqual(store.current?.id, expected, kind)
      XCTAssertEqual(store.queue.position, position, kind)
      try await store.saveNow()
      let saved = try await storage.restore(account: try XCTUnwrap(store.active?.id))
      XCTAssertEqual(saved?.current?.id, expected, kind)
      XCTAssertEqual(saved?.position, position, kind)
      await store.logout()
    }
  }
  func testDeferredCommandMoveKeepsActualCurrentUUIDAndClock() async throws {
    for movingCurrent in [false, true] {
      let (directory, storage, _, driver, store, _, entries) = try await deferredCommandContext(
        shuffled: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      defer { store.pause() }
      let startsBeforeEdit = driver.starts
      store.move(from: movingCurrent ? 1 : 2, to: 4)
      XCTAssertEqual(store.current?.id, entries[1].id)
      XCTAssertEqual(store.queue.position, 2.5)
      try await wait { driver.current != nil }
      XCTAssertEqual(driver.current, entries[1].id)
      let order =
        movingCurrent
        ? [entries[0].id, entries[2].id, entries[3].id, entries[1].id]
        : [entries[0].id, entries[1].id, entries[3].id, entries[2].id]
      XCTAssertEqual(store.queue.entries.map(\.id), order)
      XCTAssertEqual(Set(store.queue.entries.map(\.id)), Set(entries.map(\.id)))
      XCTAssertFalse(store.shuffleEnabled)
      if driver.starts > startsBeforeEdit { XCTAssertEqual(driver.startedPositions.last, 2.5) }
      deliverDeferredAndOldEvents(driver, entries: entries)
      XCTAssertEqual(store.current?.id, entries[1].id)
      XCTAssertEqual(store.queue.position, 2.5)
      try await store.saveNow()
      let saved = try await storage.restore(account: try XCTUnwrap(store.active?.id))
      XCTAssertEqual(saved?.current?.id, entries[1].id)
      XCTAssertEqual(saved?.position, 2.5)
      await store.logout()
    }
  }
  func testDeferredCommandPauseWinsObservedOneItemRepeatRollover() async throws {
    for mode in [PlayerStore.RepeatMode.one, .all] {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
      await store.enterFixture(service: ControlledCatalog())
      let selection = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
      store.playSelection(PlaybackSelection(items: [selection.items[0]], origin: selection.origin))
      try await wait { driver.starts == 1 }
      store.setRepeatMode(mode)
      let occurrence = try XCTUnwrap(store.current?.id)
      driver.beforeObserve = {
        driver.beforeObserve = nil
        driver.current = nil
        driver.prepared = []
        driver.onEvent?(.finished(occurrence))
      }
      store.pause()
      await store.deferredPlaybackSettlementForCheck()()
      XCTAssertFalse(store.playbackRequested, mode.rawValue)
      XCTAssertEqual(store.phase, .paused, mode.rawValue)
      XCTAssertEqual(
        driver.starts, 1, "Observation's automatic repeat must not drop explicit Pause")
      store.pause()
      await store.logout()
    }
  }
  func testDeferredCommandObservationCannotOverrideNewExplicitRepeatReplacement() async throws {
    for sameOccurrence in [false, true] {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
      await store.enterFixture(service: ControlledCatalog())
      let selection = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
      store.playSelection(PlaybackSelection(items: [selection.items[0]], origin: selection.origin))
      try await wait { driver.starts == 1 }
      store.setRepeatMode(.one)
      let occurrence = try XCTUnwrap(store.current?.id)
      driver.beforeObserve = {
        driver.beforeObserve = nil
        driver.current = nil
        driver.prepared = []
        driver.onEvent?(.finished(occurrence))
        if sameOccurrence {
          store.select(occurrence)
        } else {
          store.playSelection(
            PlaybackSelection(items: [selection.items[1]], origin: selection.origin))
        }
      }
      store.pause()
      await store.deferredPlaybackSettlementForCheck()()
      XCTAssertTrue(store.playbackRequested, "A newer explicit replacement retires the older Pause")
      XCTAssertEqual(store.current?.track.id, selection.items[sameOccurrence ? 0 : 1].id)
      XCTAssertEqual(store.phase, .playing)
      XCTAssertEqual(driver.starts, 2)
      store.pause()
      await store.logout()
    }
  }
  func testDeferredCommandKnownFailureStillAllowsPausedPreferenceSeekAndQueueEdits() async throws {
    for command in ["quality", "seek", "clear", "move"] {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
      await store.enterFixture(service: ControlledCatalog())
      store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
      try await wait { driver.prepared.count == 2 }
      let occurrence = try XCTUnwrap(store.current?.id)
      driver.onEvent?(.position(occurrence, 2.5))
      driver.current = nil
      driver.prepared = []
      driver.observationAccepted = false
      driver.onEvent?(.failure)
      XCTAssertEqual(store.phase, .failed)
      switch command {
      case "quality":
        store.quality(.high)
        XCTAssertEqual(store.queue.quality, .high)
        XCTAssertEqual(store.queue.position, 2.5)
      case "seek":
        store.seek(8)
        XCTAssertEqual(
          store.queue.position, 8, "Known-failed/paused source keeps an explicit resume target")
        XCTAssertEqual(store.playbackPosition, 8)
      case "clear":
        store.remove(Set(store.queue.entries.map(\.id)))
        XCTAssertTrue(store.queue.entries.isEmpty)
        XCTAssertEqual(store.queue.position, 0)
      default:
        let entries = store.queue.entries
        store.move(from: 2, to: 4)
        XCTAssertEqual(store.current?.id, occurrence)
        XCTAssertEqual(store.queue.position, 2.5)
        XCTAssertEqual(
          store.queue.entries.map(\.id),
          [entries[0].id, entries[1].id, entries[3].id, entries[2].id])
      }
      XCTAssertFalse(store.playbackRequested, command)
      XCTAssertEqual(driver.starts, 1, command)
      try await store.saveNow()
      let saved = try await storage.restore(account: try XCTUnwrap(store.active?.id))
      XCTAssertEqual(saved, store.queue, command)
      await store.logout()
    }
  }
  func testDeferredCommandObservationFailureCannotBeOverwrittenByPauseSeekOrQuality() async throws {
    for command in ["pause", "seek", "quality"] {
      let (directory, _, _, driver, store, _, _) = try await deferredCommandContext()
      defer { try? FileManager.default.removeItem(at: directory) }
      let pauses = driver.pauses
      driver.beforeObserve = {
        driver.beforeObserve = nil
        driver.current = nil
        driver.prepared = []
        driver.observationAccepted = false
        driver.onEvent?(.failure)
      }
      switch command {
      case "pause": store.pause()
      case "seek": store.seek(8)
      default: store.quality(.high)
      }
      XCTAssertEqual(store.phase, .failed)
      XCTAssertFalse(store.playbackRequested)
      XCTAssertNotNil(store.error)
      XCTAssertEqual(driver.pauses, pauses)
      XCTAssertNil(driver.lastSeek)
      await store.logout()
    }
  }
  func testQueueReplacementStopCannotOverrideNewPause() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    do {
      await store.enterFixture(service: ControlledCatalog())
      store.playSelection(try await acceptedAlbumSelection(store))
      try await wait { store.playing && driver.prepared.count == 2 }
      let account = try XCTUnwrap(store.active?.id)
      let current = try XCTUnwrap(store.current?.id)
      let target = store.queue.entries[store.queue.index + 1].id
      driver.onEvent?(.position(current, 3.25))
      try await store.saveNow()
      let starts = driver.starts
      var callbackQueue: QueueState?
      var callbackRan = false
      driver.afterStop = {
        store.pause()
        callbackQueue = store.queue
        callbackRan = true
        XCTAssertFalse(store.playbackRequested)
        XCTAssertEqual(store.phase, .paused)
      }
      store.select(target)
      await store.deferredPlaybackSettlementForCheck()()
      XCTAssertTrue(callbackRan)
      let acceptedPause = try XCTUnwrap(callbackQueue)
      XCTAssertEqual(acceptedPause.current?.id, current)
      XCTAssertEqual(acceptedPause.position, 3.25)
      XCTAssertEqual(store.active?.id, account)
      XCTAssertEqual(store.queue, acceptedPause, "The newer Pause owns the logical checkpoint")
      XCTAssertEqual(store.queue.position, 3.25)
      XCTAssertFalse(store.playbackRequested)
      XCTAssertEqual(store.phase, .paused)
      XCTAssertEqual(
        driver.starts, starts, "Stale selection cannot restart after the callback Pause")
      XCTAssertNil(driver.current)
      try await store.saveNow()
      let disk = try await storage.restore(account: account)
      XCTAssertEqual(
        disk, acceptedPause, "An unaccepted replacement cannot overwrite the disk clock")
    } catch {
      let settled = store.deferredPlaybackSettlementForCheck()
      store.pause()
      await settled()
      await store.logout()
      throw error
    }
    let settled = store.deferredPlaybackSettlementForCheck()
    store.pause()
    await settled()
    await store.logout()
  }
  func testQueueReplacementStopCannotRestoreRetiredAccountQueue() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    do {
      await store.enterFixture(service: ControlledCatalog())
      store.playSelection(try await acceptedAlbumSelection(store))
      try await wait { store.playing && driver.prepared.count == 2 }
      let account = try XCTUnwrap(store.active?.id)
      let current = try XCTUnwrap(store.current?.id)
      let target = store.queue.entries[store.queue.index + 1].id
      driver.onEvent?(.position(current, 3.25))
      try await store.saveNow()
      let savedBeforeRetirement = try await storage.restore(account: account)
      let starts = driver.starts
      var retiredQueue: QueueState?
      var callbackRan = false
      driver.afterStop = {
        guard let lease = store.transportAcceptanceLease() else {
          XCTFail("The in-flight replacement must still expose its actual fixture owner")
          return
        }
        XCTAssertTrue(store.retireTransportAcceptance(owned: lease))
        retiredQueue = store.queue
        callbackRan = true
        XCTAssertNil(store.active)
      }
      store.select(target)
      await store.deferredPlaybackSettlementForCheck()()
      XCTAssertTrue(callbackRan)
      let acceptedRetirement = try XCTUnwrap(retiredQueue)
      XCTAssertTrue(acceptedRetirement.entries.isEmpty)
      XCTAssertEqual(acceptedRetirement.position, 0)
      XCTAssertNil(store.active)
      XCTAssertNil(store.browser)
      XCTAssertEqual(
        store.queue, acceptedRetirement, "Stale selection cannot repopulate a retired account")
      XCTAssertFalse(store.playbackRequested)
      XCTAssertEqual(store.phase, .paused)
      XCTAssertEqual(driver.starts, starts)
      XCTAssertNil(driver.current)
      let disk = try await storage.restore(account: account)
      XCTAssertEqual(
        disk, savedBeforeRetirement, "Fixture retirement cannot write another account clock")
    } catch {
      let settled = store.deferredPlaybackSettlementForCheck()
      store.pause()
      await settled()
      await store.logout()
      throw error
    }
    let settled = store.deferredPlaybackSettlementForCheck()
    store.pause()
    await settled()
    await store.logout()
  }
  func testQueueReplacementPreparedAndFallbackOwnershipMatrix() async throws {
    for outcome in ["prepared", "fallback", "failure", "pause"] {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
      do {
        await store.enterFixture(service: ControlledCatalog())
        store.playSelection(try await acceptedAlbumSelection(store))
        try await wait { store.playing && driver.prepared.count == 2 }
        let current = try XCTUnwrap(store.current?.id)
        let target = store.queue.entries[store.queue.index + 1].id
        let expectedOrder = store.queue.entries.map(\.id)
        let account = try XCTUnwrap(store.active?.id)
        driver.onEvent?(.position(current, 3.25))
        let starts = driver.starts
        let stops = driver.stops
        driver.allowsPreparedAdvance = outcome != "fallback"
        var callbackRan = false
        var terminalFailure: UUID?
        if outcome == "failure" || outcome == "pause" {
          driver.afterPreparedAdvance = {
            callbackRan = true
            XCTAssertEqual(
              store.current?.id, target, "Native adoption precedes its reentrant effect")
            driver.onEvent?(.position(target, 2.5))
            if outcome == "failure" {
              driver.current = nil
              driver.prepared = []
              driver.observationAccepted = false
              driver.onEvent?(
                .failureDetails(
                  target,
                  ConnectionStepError(
                    step: .playbackAudio, error: URLError(.networkConnectionLost))))
              terminalFailure = store.lastPlaybackFailure?.id
            } else {
              store.pause()
            }
          }
        }
        store.select(target)
        await store.deferredPlaybackSettlementForCheck()()
        XCTAssertEqual(store.queue.entries.map(\.id), expectedOrder)
        XCTAssertEqual(store.current?.id, target)
        if outcome == "failure" || outcome == "pause" {
          XCTAssertTrue(callbackRan)
          XCTAssertEqual(store.queue.position, 2.5)
          XCTAssertFalse(store.playbackRequested)
          XCTAssertEqual(driver.starts, starts)
          XCTAssertEqual(driver.stops, stops)
          if outcome == "failure" {
            let failure = try XCTUnwrap(store.lastPlaybackFailure)
            XCTAssertNotNil(terminalFailure)
            XCTAssertEqual(failure.id, terminalFailure)
            XCTAssertEqual(failure.detail.code, URLError.Code.networkConnectionLost.rawValue)
            XCTAssertEqual(store.phase, .failed)
            XCTAssertNil(driver.current)
          } else {
            XCTAssertEqual(store.phase, .paused)
            XCTAssertEqual(driver.current, target)
            XCTAssertNil(store.lastPlaybackFailure)
          }
        } else {
          XCTAssertFalse(callbackRan)
          XCTAssertTrue(store.playbackRequested)
          XCTAssertEqual(driver.current, target)
          XCTAssertEqual(store.queue.position, 0)
          XCTAssertEqual(driver.starts, starts + (outcome == "fallback" ? 1 : 0))
          XCTAssertEqual(driver.stops, stops + (outcome == "fallback" ? 1 : 0))
          XCTAssertEqual(store.phase, .playing)
        }
        try await store.saveNow()
        let disk = try await storage.restore(account: account)
        XCTAssertEqual(disk, store.queue)
      } catch {
        let settled = store.deferredPlaybackSettlementForCheck()
        store.pause()
        await settled()
        await store.logout()
        throw error
      }
      let settled = store.deferredPlaybackSettlementForCheck()
      store.pause()
      await settled()
      await store.logout()
    }
  }
  func testQueueReplacementAbortedAlbumIntentPreservesShuffleRestoration() async throws {
    for action in ["play", "shuffle"] {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
      do {
        await store.enterFixture(service: ControlledCatalog())
        let selection = try await acceptedAlbumSelection(store)
        store.playSelection(selection)
        try await wait { store.playing && driver.prepared.count == 2 }
        let canonical = store.queue.entries.map(\.id)
        let wasShuffled = action == "play"
        if wasShuffled {
          store.toggleShuffle()
          await store.deferredPlaybackSettlementForCheck()()
        }
        XCTAssertEqual(store.shuffleEnabled, wasShuffled)
        let sampledOrder = store.queue.entries.map(\.id)
        let occurrence = try XCTUnwrap(store.current?.id)
        driver.onEvent?(.position(occurrence, 3.25))
        let starts = driver.starts
        var callbackRan = false
        driver.afterStop = {
          store.pause()
          callbackRan = true
        }
        let newTracks = Array(CatalogFixtures.tracks(CatalogFixtures.album(7)).prefix(3))
        XCTAssertTrue(Set(newTracks.map(\.id)).isDisjoint(with: selection.items.map(\.id)))
        let replacement = PlaybackSelection(items: newTracks, origin: selection.origin)
        if action == "play" {
          store.playSelection(replacement)
        } else {
          store.shuffleSelection(replacement)
        }
        await store.deferredPlaybackSettlementForCheck()()
        XCTAssertTrue(callbackRan)
        XCTAssertEqual(store.queue.entries.map(\.id), sampledOrder)
        XCTAssertEqual(store.current?.id, occurrence)
        XCTAssertEqual(store.queue.position, 3.25)
        XCTAssertEqual(store.shuffleEnabled, wasShuffled)
        XCTAssertFalse(store.playbackRequested)
        XCTAssertEqual(store.phase, .paused)
        XCTAssertEqual(driver.starts, starts)
        let extra = CatalogFixtures.tracks(CatalogFixtures.album(8))[0]
        store.enqueue(extra, next: false, origin: selection.origin)
        let extraOccurrence = try XCTUnwrap(store.queue.entries.last)
        XCTAssertEqual(extraOccurrence.track.id, extra.id)
        if wasShuffled { store.toggleShuffle() }
        XCTAssertFalse(store.shuffleEnabled)
        XCTAssertEqual(store.queue.entries.map(\.id), canonical + [extraOccurrence.id])
        XCTAssertEqual(store.current?.id, occurrence)
        XCTAssertEqual(store.queue.position, 3.25)
        XCTAssertFalse(store.playbackRequested)
        XCTAssertEqual(driver.starts, starts)
        try await store.saveNow()
        let disk = try await storage.restore(account: try XCTUnwrap(store.active?.id))
        XCTAssertEqual(disk, store.queue)
      } catch {
        let settled = store.deferredPlaybackSettlementForCheck()
        store.pause()
        await settled()
        await store.logout()
        throw error
      }
      let settled = store.deferredPlaybackSettlementForCheck()
      store.pause()
      await settled()
      await store.logout()
    }
  }
  func testDeferredCommandStopCannotOverrideNewPauseOrAccountRetirement() async throws {
    for retirement in [false, true] {
      let (directory, _, _, driver, store, _, _) = try await deferredCommandContext()
      defer { try? FileManager.default.removeItem(at: directory) }
      let starts = driver.starts
      driver.afterStop = {
        if retirement {
          guard let lease = store.transportAcceptanceLease() else {
            XCTFail("missing callback owner")
            return
          }
          XCTAssertTrue(store.retireTransportAcceptance(owned: lease))
        } else {
          store.pause()
        }
      }
      store.quality(.high)
      let settled = store.deferredPlaybackSettlementForCheck()
      await settled()
      XCTAssertFalse(store.playbackRequested)
      XCTAssertEqual(store.phase, .paused)
      XCTAssertEqual(driver.starts, starts)
      if retirement { XCTAssertNil(store.active) }
      await store.logout()
    }
  }
  private func deferredAuthorizationContext() async throws -> (
    URL, LibraryStorage, MemoryVault, PlayerStore, Connection, Connection, DriverSpy
  ) {
    let (directory, storage, vault, driver) = try context()
    do {
      let old = Connection(
        server: try ServerAddress("https://fixture.invalid"), userID: "old", username: "Old fixture"
      )
      let target = Connection(
        server: try ServerAddress("https://fixture.invalid"), userID: "target",
        username: "Target fixture")
      for connection in [old, target] {
        await vault.write("invented-" + connection.userID, account: connection.id)
        try await storage.save(
          QueueState(
            entries: MusicItem.fixtureTracks.map { QueueEntry($0, libraryID: "fixture-music") },
            position: 7.25), account: connection.id)
      }
      let store = PlayerStore(
        storage: storage, vault: vault, driver: driver, deviceID: "test",
        factory: { _, _ in ImmediateCatalog() })
      await store.activate(old)
      return (directory, storage, vault, store, old, target, driver)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
  func testSignOutErasesTheCredentialWhenDiskCleanupFailsAndCanRetry() async throws {
    let (directory, storage, vault, store, old, _, _) = try await deferredAuthorizationContext()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lease = await storage.lease(account: old.id)
    try await storage.acceptRecentAlbum(
      account: old.id, lease: lease, library: "music", album: "album")
    let parent = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try FileManager.default.moveItem(at: directory, to: parent)
    defer { try? FileManager.default.removeItem(at: parent) }
    try Data([0]).write(to: directory)
    await store.logout()
    let token = await vault.read(account: old.id)
    XCTAssertNil(token)
    XCTAssertTrue(store.connections.isEmpty)
    XCTAssertEqual(store.pendingSignOut, old.id)
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.moveItem(at: parent, to: directory)
    await store.finishSignOut()
    XCTAssertNil(store.pendingSignOut)
    let reopened = try LibraryStorage(directory: directory)
    let recent = try await reopened.recentAlbums(account: old.id, library: "music")
    let accounts = try await reopened.connections()
    XCTAssertTrue(recent.isEmpty)
    XCTAssertTrue(accounts.isEmpty)
  }
  func testDeferredAuthorizationCannotEraseReplacementAccountQueueOrToken() async throws {
    let (directory, storage, vault, store, _, target, _) = try await deferredAuthorizationContext()
    defer { try? FileManager.default.removeItem(at: directory) }
    let operation = store.deferredAuthorizationLogoutForCheck()
    await store.activate(target)
    let expected = store.queue
    XCTAssertEqual(store.active?.id, target.id)
    await operation()
    XCTAssertEqual(store.active?.id, target.id)
    XCTAssertEqual(store.queue, expected)
    let token = await vault.read(account: target.id)
    let saved = try await storage.restore(account: target.id)
    XCTAssertEqual(token, "invented-target")
    XCTAssertEqual(saved, expected)
    await store.logout()
  }
  func testDeferredAuthorizationCannotEraseReactivatedSameAccountEpoch() async throws {
    let (directory, storage, vault, store, old, _, _) = try await deferredAuthorizationContext()
    defer { try? FileManager.default.removeItem(at: directory) }
    let operation = store.deferredAuthorizationLogoutForCheck()
    await store.activate(old)
    let expected = store.queue
    XCTAssertEqual(store.active?.id, old.id)
    await operation()
    XCTAssertEqual(store.active?.id, old.id)
    XCTAssertEqual(store.queue, expected)
    let token = await vault.read(account: old.id)
    let saved = try await storage.restore(account: old.id)
    XCTAssertEqual(token, "invented-old")
    XCTAssertEqual(saved, expected)
    await store.logout()
  }
  func testDeferredAuthorizationCurrentRevocationStillLogsOutAndErasesOnlyItsAccount() async throws
  {
    let (directory, storage, vault, store, old, target, _) =
      try await deferredAuthorizationContext()
    defer { try? FileManager.default.removeItem(at: directory) }
    await store.deferredAuthorizationLogoutForCheck()()
    XCTAssertNil(store.active)
    let oldToken = await vault.read(account: old.id)
    let oldQueue = try await storage.restore(account: old.id)
    let otherToken = await vault.read(account: target.id)
    let otherQueue = try await storage.restore(account: target.id)
    XCTAssertNil(oldToken)
    XCTAssertNil(oldQueue)
    XCTAssertEqual(otherToken, "invented-target")
    XCTAssertNotNil(otherQueue)
  }
  func testDeferredCommandPausedUnboundEditsKeepIntentWithoutStartingNative() async throws {
    let (directory, storage, _, store, old, _, driver) = try await deferredAuthorizationContext()
    defer { try? FileManager.default.removeItem(at: directory) }
    let occurrence = try XCTUnwrap(store.current?.id)
    store.seek(8)
    store.quality(.high)
    store.move(from: 2, to: 4)
    store.remove([store.queue.entries[3].id])
    XCTAssertEqual(store.current?.id, occurrence)
    XCTAssertEqual(store.queue.position, 8)
    XCTAssertFalse(store.playbackRequested)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertEqual(driver.starts, 0)
    try await store.saveNow()
    let saved = try await storage.restore(account: old.id)
    XCTAssertEqual(saved?.position, 8)
    await store.logout()
  }
  func testQueueEditDuringDeferredNativeTurnoverKeepsLogicalAndNativeCurrentAligned()
    async throws
  {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    let selection = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(selection)
    try await wait { driver.prepared.count == 2 }
    let successor = store.queue.entries[1].id
    driver.prepared.removeFirst()
    driver.current = successor
    store.enqueueSelection(
      PlaybackSelection(items: [selection.items[2]], origin: selection.origin), next: true)
    driver.onEvent?(.advanced(successor))
    driver.onEvent?(.position(successor, 2.5))
    XCTAssertEqual(store.current?.id, successor)
    XCTAssertEqual(store.queue.position, 2.5)
    XCTAssertEqual(store.current?.id, driver.current)
    await store.logout()
  }
  func testRepeatModeDuringDeferredNativeTurnoverDoesNotStrandPreviousOccurrence() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
    try await wait { driver.prepared.count == 2 }
    let successor = store.queue.entries[1].id
    driver.prepared.removeFirst()
    driver.current = successor
    store.setRepeatMode(.one)
    driver.onEvent?(.advanced(successor))
    driver.onEvent?(.position(successor, 2.5))
    XCTAssertEqual(store.current?.id, successor)
    XCTAssertEqual(store.queue.position, 2.5)
    await store.logout()
  }
  func testShuffleDuringDeferredNativeTurnoverPreservesActualCurrentAndFutureMembership()
    async throws
  {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
    try await wait { driver.prepared.count == 2 }
    let membership = Set(store.queue.entries.map(\.id))
    let successor = store.queue.entries[1].id
    driver.prepared.removeFirst()
    driver.current = successor
    store.toggleShuffle()
    driver.onEvent?(.advanced(successor))
    driver.onEvent?(.position(successor, 2.5))
    XCTAssertTrue(store.shuffleEnabled)
    XCTAssertEqual(store.current?.id, successor)
    XCTAssertEqual(store.queue.position, 2.5)
    XCTAssertEqual(Set(store.queue.entries.map(\.id)), membership)
    await store.logout()
  }
  func testUnboundFutureEditsCannotAppendSuccessorBeforeInitialNativeInsertion() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ControlledCatalog()
    let insertion = ControlledSleep()
    defer { Task { await insertion.releaseAll() } }
    driver.beforeStart = { await insertion.wait(until: .distantFuture) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    defer { store.pause() }
    await store.enterFixture(service: api)
    let selection = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(selection)
    try await wait { await insertion.calls == 1 }
    let occurrence = store.current?.id
    store.enqueueSelection(selection, next: true)
    store.setRepeatMode(.all)
    store.toggleShuffle()
    XCTAssertEqual(store.current?.id, occurrence)
    XCTAssertFalse(store.nextRequiresRetry)
    XCTAssertTrue(driver.appended.isEmpty)
    XCTAssertTrue(driver.prepared.isEmpty)
    let beforeAdmissionCalls = await api.mediaCalls
    XCTAssertEqual(beforeAdmissionCalls, 1)
    await insertion.release(1)
    try await wait { driver.prepared.count == 2 }
    XCTAssertEqual(driver.current, occurrence)
    XCTAssertEqual(driver.starts, 1)
    await store.logout()
  }
  func testRejectedCurrentProofLeavesQueueRepeatShuffleAndPreparedFutureUntouched() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    let selection = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(selection)
    try await wait { driver.prepared.count == 2 }
    let occurrence = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.position(occurrence, 2))
    let entries = store.queue.entries
    let prepared = driver.prepared
    driver.deniesCurrentRetention = true
    store.enqueueSelection(selection, next: true)
    store.setRepeatMode(.one)
    store.toggleShuffle()
    XCTAssertEqual(store.queue.entries, entries)
    XCTAssertEqual(driver.prepared, prepared)
    XCTAssertEqual(store.current?.id, occurrence)
    XCTAssertEqual(store.queue.position, 2)
    XCTAssertEqual(store.repeatMode, .off)
    XCTAssertFalse(store.shuffleEnabled)
    XCTAssertTrue(store.playing)
    XCTAssertNotNil(store.error)
    await store.logout()
  }
  func testWarmReducedSeekKeepsAcceptedCheckpointUntilSourceAndNativeAcknowledgment()
    async throws
  {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    defer { Task { await api.release(3) } }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    defer { store.pause() }
    await store.enterFixture(service: api)
    store.quality(.high)
    store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
    try await wait { driver.prepared.count == 2 }
    let occurrence = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.timeline(occurrence, duration: 60, seekableEnd: 60))
    driver.onEvent?(.position(occurrence, 2))
    await api.block(3)
    await api.fail(3, .unavailable)
    store.seek(30)
    try await wait { await api.requests.count == 3 }
    XCTAssertEqual(store.playbackPosition, 30, "Pending display retains the requested target")
    XCTAssertEqual(store.queue.position, 2, "Unconfirmed source seek is not an accepted clock")
    try await store.saveNow()
    let account = try XCTUnwrap(store.active?.id)
    let persisted = try await storage.restore(account: account)
    XCTAssertEqual(persisted?.position, 2)
    await api.release(3)
    try await wait { store.phase == .failed }
    XCTAssertEqual(
      store.queue.position, 2, "Failed preparation must retain the playable checkpoint")
    await store.logout()
  }
  func testCompletedHighSuccessorSeeksWithinItsFileAndWaitsForTheNativeClock() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    store.quality(.high)
    store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
    try await wait { driver.prepared.count == 2 }
    driver.advance()
    try await wait { driver.appended.count == 2 }
    let current = try XCTUnwrap(store.current?.id)
    driver.completeLocalOccurrence = current
    driver.onEvent?(.timeline(current, duration: 72, seekableEnd: 72))
    driver.onEvent?(.position(current, 2))
    let requests = await api.requests.count
    store.seek(54, occurrence: current)
    XCTAssertEqual(driver.lastSeek, 54)
    XCTAssertEqual(store.playbackPosition, 54)
    XCTAssertEqual(store.queue.position, 2)
    let seek = try XCTUnwrap(driver.seekRequests.last)
    driver.onEvent?(.seekCompleted(current, 54, request: seek))
    XCTAssertEqual(store.queue.position, 54)
    let after = await api.requests.count
    XCTAssertEqual(after, requests)
    await store.logout()
  }

  func testUnpreparedProgressiveSuccessorStreamsAsCurrentAtItsNaturalTurn() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: LookaheadCatalog())
    driver.deferAppend = true
    store.quality(.compact)
    store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
    try await wait { driver.deferredEntries.count == 1 }
    let next = try XCTUnwrap(store.queue.successor?.id)
    XCTAssertEqual(driver.deferredEntries, [next])
    XCTAssertFalse(store.nextRequiresRetry)
    driver.finishCurrent()
    try await wait { driver.starts == 2 }
    XCTAssertEqual(driver.current, next)
    XCTAssertEqual(driver.startedPositions, [0, 0])
    XCTAssertEqual(store.phase, .playing)
    XCTAssertNil(store.error)
    await store.logout()
  }

  func testCurrentFailureRetainsAcceptedRetryClockAndRejectsDeferredSuccessorAdoption()
    async throws
  {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
    try await wait { driver.prepared.count == 2 }
    let first = try XCTUnwrap(store.current?.id)
    let next = store.queue.entries[1].id
    driver.onEvent?(.position(first, 7.25))
    driver.onEvent?(
      .failureDetails(
        first, ConnectionStepError(step: .playbackAudio, error: URLError(.networkConnectionLost))))
    XCTAssertEqual(store.phase, .failed)
    XCTAssertFalse(store.playbackRequested)
    driver.onEvent?(.advanced(next))
    XCTAssertEqual(store.current?.id, first)
    XCTAssertEqual(store.queue.position, 7.25)
    XCTAssertEqual(store.phase, .failed)
    driver.current = nil
    store.play()
    try await wait { driver.starts == 2 }
    XCTAssertEqual(driver.startedPositions.last, 7.25)
    XCTAssertEqual(store.current?.id, first)
    await store.logout()
  }
  func testConfirmedHealthyHandoffRejectsDepartedFailureEndAndTimelineEvents() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
    try await wait { driver.prepared.count == 2 }
    let first = try XCTUnwrap(store.current?.id)
    driver.advance()
    let next = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.position(next, 2.5))
    driver.onEvent?(.state(next, .playing))
    driver.onEvent?(
      .failureDetails(
        first, ConnectionStepError(step: .playbackAudio, error: URLError(.networkConnectionLost))))
    driver.onEvent?(.finished(first))
    driver.onEvent?(.timeline(first, duration: 1, seekableEnd: 1))
    driver.onEvent?(.position(first, 99))
    XCTAssertEqual(store.current?.id, next)
    XCTAssertEqual(store.queue.position, 2.5)
    XCTAssertTrue(store.playing)
    XCTAssertTrue(store.playbackRequested)
    XCTAssertNil(store.lastPlaybackFailure)
    XCTAssertNil(store.nativeDuration)
    await store.logout()
  }
  func testSuccessorFailureKeepsFirstPlayableAndRetainsRetryWithoutDroppingOccurrence() async throws
  {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    await api.fail(2, .unavailable)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { store.nextRequiresRetry }
    XCTAssertEqual(driver.starts, 1)
    XCTAssertEqual(store.phase, .playing)
    XCTAssertEqual(store.queue.index, 0)
    XCTAssertEqual(store.queue.entries.count, 4)
    XCTAssertNil(store.error)
    store.retryNext()
    try await wait {
      store.queue.entries.dropFirst(store.queue.index + 1).first.map { driver.hasPrepared($0.id) }
        == true
    }
    XCTAssertEqual(driver.appended, [store.queue.entries[1].id])
    XCTAssertEqual(driver.starts, 1)
    await store.logout()
  }
  func testNativeSuccessorInsertionFailureRetainsCurrentAndExactRetryOccurrence() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    driver.appendError = ClientError.unavailable
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { store.nextRequiresRetry }
    let current = store.current?.id
    let next = store.queue.entries[1].id
    XCTAssertEqual(driver.starts, 1)
    XCTAssertEqual(store.phase, .playing)
    XCTAssertTrue(driver.appended.isEmpty)
    XCTAssertEqual(store.queue.index, 0)
    XCTAssertNil(store.error)
    driver.appendError = nil
    store.retryNext()
    try await wait {
      store.queue.entries.dropFirst(store.queue.index + 1).first.map { driver.hasPrepared($0.id) }
        == true
    }
    XCTAssertEqual(store.current?.id, current)
    XCTAssertEqual(driver.appended, [next])
    XCTAssertEqual(driver.starts, 1)
    await store.logout()
  }
  func testPauseResumeReplenishesCanceledSuccessorOnceAndRetiresLateReceipts() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    await api.block(2)
    await api.block(3)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { await api.requests.count == 2 }
    let occurrences = store.queue.entries.map(\.id)
    store.pause()
    store.play()
    try await wait { await api.requests.count == 3 }
    await api.release(2)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertTrue(driver.appended.isEmpty)
    await api.release(3)
    try await wait {
      store.queue.entries.dropFirst(store.queue.index + 1).first.map { driver.hasPrepared($0.id) }
        == true
    }
    store.pause()
    store.play()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(driver.appended, [occurrences[1]])
    let count = await api.requests.count
    XCTAssertEqual(count, 3)
    driver.advance()
    try await wait { driver.appended.count == 2 }
    XCTAssertEqual(store.current?.id, occurrences[1])
    XCTAssertEqual(driver.appended, [occurrences[1], occurrences[2]])
    await store.logout()
  }
  func testPauseWinsWhilePendingSuccessorBecomesCurrentAfterNaturalEnd() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    await api.block(2)
    await api.block(3)
    defer {
      Task {
        await api.release(2)
        await api.release(3)
      }
    }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
    try await wait { await api.requests.count == 2 }
    let second = store.queue.entries[1].id
    driver.finishCurrent()
    try await wait { await api.requests.count == 3 }
    XCTAssertEqual(store.current?.id, second)
    XCTAssertEqual(store.phase, .preparing)
    store.pause()
    await api.release(2)
    await api.release(3)
    await store.deferredPlaybackSettlementForCheck()()
    XCTAssertFalse(store.playbackRequested)
    XCTAssertTrue(driver.appended.isEmpty)
    XCTAssertEqual(driver.starts, 1)
    XCTAssertEqual(store.queue.entries.count, 4)
    store.play()
    try await wait { driver.starts == 2 }
    XCTAssertEqual(driver.current, second)
    await store.logout()
  }
  func testSuccessorUnauthorizedRetiresAccountButStaleFailureCannotRetireNewPlayback() async throws
  {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    await api.block(2)
    await api.fail(2, .unauthorized)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { await api.requests.count == 2 }
    store.next()
    try await wait { driver.starts == 2 }
    await api.release(2)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertNotNil(store.active)
    XCTAssertEqual(store.queue.index, 1)
    await store.logout()
    let revoked = LookaheadCatalog()
    await revoked.fail(2, .unauthorized)
    await store.enterFixture(service: revoked)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { store.active == nil }
    XCTAssertNil(driver.current)
    XCTAssertTrue(store.queue.entries.isEmpty)
  }
  func testPauseRetiresPendingPreparationWithoutLatePlayback() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ControlledCatalog()
    await api.blockMedia()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { await api.mediaCalls == 1 }
    store.pause()
    await api.releaseMedia()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(driver.starts, 0)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertEqual(store.queue.entries.count, 4)
  }
  func testLogoutRejectsLateAlbumAndStaleStorageWrites() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ControlledCatalog()
    await api.blockTracks()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    let browser = try XCTUnwrap(store.browser)
    await browser.start()
    let account = try XCTUnwrap(store.active?.id)
    let content = try XCTUnwrap(browser.detail(.fixtureAlbum))
    let loading = Task { await content.load() }
    try await wait { await api.trackCalls == 1 }
    await store.logout()
    await api.releaseTracks()
    await loading.value
    XCTAssertNil(store.active)
    XCTAssertNil(store.browser)
    XCTAssertNil(content.authorizedLibrary)
    XCTAssertTrue(content.tracks.isEmpty, "Retired rooted detail cannot accept its late reply")
    let lease = await storage.lease(account: account)
    try await storage.retire(account: account, erase: true)
    try await storage.saveIfCurrent(
      QueueState(entries: [QueueEntry(MusicItem.fixtureTracks[0])]), account: account, lease: lease)
    let stale = try await storage.restore(account: account)
    XCTAssertNil(stale)
  }
  func testImmediateAccountReactivationFlushesLatestPausedQueueBeforeRestore() async throws {
    let (directory, storage, _, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let account = Connection(
      server: try ServerAddress("https://fixture.invalid"), userID: "invented-listener",
      username: "Fixture")
    let initial = QueueState(
      entries: [QueueEntry(MusicItem.fixtureTracks[0]), QueueEntry(MusicItem.fixtureTracks[0])],
      index: 1, position: 1.25, quality: .compact)
    try await storage.save(initial, account: account.id)
    let store = PlayerStore(
      storage: storage, vault: ImmediateVault(), driver: driver, deviceID: "test",
      factory: { _, _ in ImmediateCatalog() })
    await store.activate(account)
    XCTAssertEqual(store.queue, initial)
    store.seek(7.25)
    store.quality(.high)
    let expected = store.queue
    let priorStops = driver.stops
    await store.activate(account)
    XCTAssertGreaterThan(driver.stops, priorStops, "The accepted target must actually be restored")
    XCTAssertEqual(store.queue, expected, "Reactivation must not restore ahead of queued saves")
    XCTAssertEqual(store.queue.position, 7.25, accuracy: 0.05)
    XCTAssertEqual(store.current?.id, initial.current?.id)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertFalse(store.playbackRequested)
    XCTAssertEqual(driver.starts, 0)
  }
  private func activationContext() async throws -> (
    URL, LibraryStorage, DriverSpy, PlayerStore, Connection, Connection
  ) {
    let (directory, storage, _, driver) = try context()
    let old = Connection(
      server: try ServerAddress("https://fixture.invalid"), userID: "old", username: "Old fixture")
    let target = Connection(
      server: try ServerAddress("https://fixture.invalid"), userID: "target",
      username: "Target fixture")
    try await storage.save(
      QueueState(
        entries: MusicItem.fixtureTracks.map { QueueEntry($0, libraryID: "fixture-music") },
        position: 3.25),
      account: old.id)
    let store = PlayerStore(
      storage: storage, vault: ImmediateVault(), driver: driver, deviceID: "test",
      factory: { _, _ in ImmediateCatalog() })
    await store.activate(old)
    return (directory, storage, driver, store, old, target)
  }
  func testPendingActivationSaveRejectsNewIntentCancellationAndAccountReplacement() async throws {
    for action in ["intent", "play", "cancel", "replace"] {
      let (directory, storage, driver, store, old, target) = try await activationContext()
      defer { try? FileManager.default.removeItem(at: directory) }
      store.seek(7.25)
      if action == "play" {
        store.play()
        try await wait { driver.starts == 1 }
      }
      let gate = StorageWriteGate()
      let blocked = Task.detached { await storage.holdWritesForTest(gate) }
      try await wait { gate.entered }
      let activation = Task { await store.activate(target) }
      try await wait { store.busy }
      switch action {
      case "intent": store.seek(9.5)
      case "play": store.play()
      case "cancel": activation.cancel()
      default: store.addConnection()
      }
      gate.release()
      await blocked.value
      await activation.value
      XCTAssertNotEqual(store.active?.id, target.id)
      XCTAssertEqual(store.playbackRequested, action == "play")
      if action != "play" { XCTAssertEqual(store.phase, .paused) }
      XCTAssertFalse(store.busy)
      if action == "replace" {
        XCTAssertNil(store.active)
        XCTAssertTrue(store.queue.entries.isEmpty)
      } else {
        XCTAssertEqual(store.active?.id, old.id)
        XCTAssertEqual(store.queue.position, action == "intent" ? 9.5 : 7.25, accuracy: 0.05)
      }
      await store.activate(old)
      XCTAssertEqual(store.queue.position, action == "intent" ? 9.5 : 7.25, accuracy: 0.05)
    }
  }
  func testLogoutWhileActivationSaveIsPendingCannotRestoreOrResurrectRetiredQueue() async throws {
    let (directory, storage, _, store, old, target) = try await activationContext()
    defer { try? FileManager.default.removeItem(at: directory) }
    store.seek(7.25)
    let gate = StorageWriteGate()
    let blocked = Task.detached { await storage.holdWritesForTest(gate) }
    try await wait { gate.entered }
    let activation = Task { await store.activate(target) }
    try await wait { store.busy }
    let logout = Task { await store.logout() }
    try await wait { store.active == nil }
    gate.release()
    await blocked.value
    await activation.value
    await logout.value
    XCTAssertNil(store.active)
    XCTAssertTrue(store.queue.entries.isEmpty)
    XCTAssertFalse(store.playbackRequested)
    let retained = try await storage.restore(account: old.id)
    XCTAssertNil(retained)
  }
  func testOutgoingSaveFailureRetainsSampledPausedQueueAndExplicitRetry() async throws {
    let (directory, storage, driver, store, old, _) = try await activationContext()
    defer { try? FileManager.default.removeItem(at: directory) }
    store.play()
    try await wait { driver.starts == 1 }
    driver.sampledPausePosition = 9.125
    let occurrence = store.current?.id
    try FileManager.default.removeItem(at: directory)
    try Data([0]).write(to: directory)
    await store.activate(old)
    XCTAssertEqual(store.active?.id, old.id)
    XCTAssertEqual(store.current?.id, occurrence)
    XCTAssertEqual(store.queue.position, 9.125, accuracy: 0.05)
    XCTAssertFalse(store.playbackRequested)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertTrue(store.error?.hasPrefix("Saving queue:") == true)
    XCTAssertFalse(store.error?.contains(directory.path) == true)
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    await store.activate(old)
    XCTAssertEqual(store.current?.id, occurrence)
    XCTAssertEqual(store.queue.position, 9.125, accuracy: 0.05)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertNil(store.error)
    let saved = try await storage.restore(account: old.id)
    XCTAssertEqual(saved?.position, 9.125)
  }
  func testRestorationIsPausedAndQualityChangeDoesNotStartPlayback() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ControlledCatalog()
    let account = Connection(
      server: try ServerAddress("https://fixture.invalid"), userID: "invented-listener",
      username: "Demo listener")
    let state = QueueState(
      entries: MusicItem.fixtureTracks.map { QueueEntry($0) }, index: 2, position: 7.25,
      quality: .compact)
    try await storage.save(state, account: account.id)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    XCTAssertEqual(store.queue, state)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertEqual(driver.starts, 0)
    store.quality(.high)
    XCTAssertEqual(store.queue.position, 7.25)
    XCTAssertEqual(driver.starts, 0)
  }
  func testQualityPreservesSampledPositionOccurrenceAndPausedIntent() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { driver.starts == 1 }
    let id = store.current?.id
    driver.sampledPausePosition = 4.125
    store.quality(.high)
    try await wait { driver.starts == 2 }
    XCTAssertEqual(store.current?.id, id)
    XCTAssertEqual(driver.startedPositions.last, 4.125)
    XCTAssertTrue(store.playbackRequested)
    store.pause()
    store.quality(.compact)
    XCTAssertEqual(driver.starts, 2)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertEqual(store.queue.position, 4.125)
    XCTAssertEqual(store.current?.id, id)
  }
  func testSelectedSeekRetiresLatePreparationAndPreservesNewestPausedTarget() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.quality(.high)
    await api.block(1)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { await api.requests.count == 1 }
    let id = store.current?.id
    store.seek(5)
    try await wait { driver.starts == 1 }
    XCTAssertEqual(driver.startedPositions.last, 5)
    store.pause()
    store.seek(2)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertEqual(store.queue.position, 2)
    XCTAssertEqual(store.current?.id, id)
    await api.release(1)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(driver.starts, 1)
    XCTAssertFalse(store.playbackRequested)
    store.play()
    try await wait { driver.starts == 2 }
    XCTAssertEqual(driver.startedPositions.last, 2)
    await store.logout()
    XCTAssertNil(store.current)
  }
  func testPreparationDeadlineRetainsRetryAndRejectsLateNegotiation() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ControlledCatalog()
    await api.blockMedia()
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test",
      preparationTimeout: .milliseconds(80))
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.quality(.high)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    store.seek(5)
    let id = store.current?.id
    try await wait { store.phase == .failed }
    XCTAssertEqual(store.current?.id, id)
    XCTAssertEqual(store.queue.position, 5)
    XCTAssertFalse(store.playbackRequested)
    await api.releaseMedia()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(driver.starts, 0)
    store.play()
    try await wait { driver.starts == 1 }
    XCTAssertEqual(driver.startedPositions.last, 5)
  }
  func testNativePreparationOwnsExpiryAfterMetadataHandoffAndRejectsLateCompletion()
    async throws
  {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ControlledCatalog()
    await api.usePreciseTiming()
    let deadline = ControlledSleep()
    let native = ControlledSleep()
    defer {
      Task {
        await deadline.releaseAll()
        await native.releaseAll()
      }
    }
    driver.beforeStart = { await native.wait(until: .distantFuture) }
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test",
      preparationSleep: { await deadline.wait(for: $0) })
    await store.enterFixture(service: api)
    store.quality(.original)
    store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
    try await wait {
      let waiting = await native.calls == 1
      return await deadline.calls == 1 && waiting
    }
    let durations = await deadline.durations
    XCTAssertEqual(durations, [.seconds(15)])
    let occurrence = store.current?.id
    await deadline.release(1)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(store.phase, .preparing)
    XCTAssertTrue(store.playbackRequested)
    driver.onEvent?(
      .failureDetails(
        try XCTUnwrap(occurrence),
        ConnectionStepError(step: .playbackAudio, error: PlaybackProblem.stalled)))
    XCTAssertEqual(store.lastPlaybackFailure?.detail.step, .playbackAudio)
    try await wait { store.phase == .failed }
    XCTAssertEqual(store.current?.id, occurrence)
    XCTAssertFalse(store.playbackRequested)
    await native.release(1)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(driver.starts, 0)
    XCTAssertEqual(store.phase, .failed)
  }
  func testMetadataDeadlineStopsAtNativeHandoffForStandardAndPreciseSources() async throws {
    for metadata in [true, false] {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let api = ControlledCatalog()
      await api.usePreciseTiming()
      if metadata { await api.blockMedia() }
      let deadline = ControlledSleep()
      let native = ControlledSleep()
      defer {
        Task {
          await deadline.releaseAll()
          await native.releaseAll()
        }
      }
      driver.beforeStart = { await native.wait(until: .distantFuture) }
      let store = PlayerStore(
        storage: storage, vault: vault, driver: driver, deviceID: "test",
        preparationSleep: { await deadline.wait(for: $0) })
      await store.enterFixture(service: api)
      store.quality(metadata ? .original : .high)
      store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
      try await wait { await deadline.calls == 1 }
      if !metadata { try await wait { await native.calls == 1 } }
      let durations = await deadline.durations
      XCTAssertEqual(durations, [.seconds(15)])
      await deadline.release(1)
      if !metadata {
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.phase, .preparing)
        XCTAssertTrue(store.playbackRequested)
        driver.onEvent?(
          .failureDetails(
            try XCTUnwrap(store.current?.id),
            ConnectionStepError(step: .playbackAudio, error: PlaybackProblem.stalled)))
      }
      try await wait { store.phase == .failed }
      XCTAssertEqual(
        store.lastPlaybackFailure?.detail.step, metadata ? .preparationDeadline : .playbackAudio)
      await api.releaseMedia()
      await native.releaseAll()
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertEqual(driver.starts, 0)
      XCTAssertFalse(store.playbackRequested)
      let finalDurations = await deadline.durations
      XCTAssertEqual(finalDurations, [.seconds(15)])
    }
  }
  func testPreciseNonzeroResumeAndQualitySwitchKeepPositionBeyondOldDeadline() async throws {
    for resume in [true, false] {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let api = ControlledCatalog()
      await api.usePreciseTiming()
      let deadline = ControlledSleep()
      let native = ControlledSleep()
      defer {
        Task {
          await deadline.releaseAll()
          await native.releaseAll()
        }
      }
      let store = PlayerStore(
        storage: storage, vault: vault, driver: driver, deviceID: "test",
        preparationSleep: { await deadline.wait(for: $0) })
      await store.enterFixture(service: api)
      store.quality(resume ? .original : .high)
      store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
      try await wait { driver.starts == 1 }
      let oldDeadlineCalls = await deadline.calls
      driver.beforeStart = { await native.wait(until: .distantFuture) }
      driver.resumeAllowed = false
      driver.sampledPausePosition = 30
      let occurrence = store.current?.id
      if resume {
        store.pause()
        store.play()
      } else {
        store.quality(.original)
      }
      try await wait {
        let waiting = await native.calls == 1
        return await deadline.calls == oldDeadlineCalls + 1 && waiting
      }
      await deadline.release(oldDeadlineCalls + 1)
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertTrue(store.playbackRequested)
      XCTAssertEqual(store.phase, .preparing)
      await native.release(1)
      try await wait { driver.starts == 2 }
      XCTAssertEqual(driver.startedPositions.last, 30)
      XCTAssertEqual(driver.startedSources.last?.preferPreciseTiming, true)
      XCTAssertEqual(store.current?.id, occurrence)
      let finalDeadlineCalls = await deadline.calls
      XCTAssertEqual(finalDeadlineCalls, oldDeadlineCalls + 1, "Native owns the remaining budget")
      XCTAssertTrue(store.playing)
      store.pause()
    }
  }
  func testPrecisePreparationExpiryCannotCrossPauseReplacementOrLogout() async throws {
    for retirement in 0..<3 {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let api = ControlledCatalog()
      await api.usePreciseTiming()
      let deadline = ControlledSleep()
      let native = ControlledSleep()
      defer {
        Task {
          await deadline.releaseAll()
          await native.releaseAll()
        }
      }
      driver.beforeStart = { await native.wait(until: .distantFuture) }
      let store = PlayerStore(
        storage: storage, vault: vault, driver: driver, deviceID: "test",
        preparationSleep: { await deadline.wait(for: $0) })
      await store.enterFixture(service: api)
      store.quality(.original)
      store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
      try await wait {
        let waiting = await native.calls == 1
        return await deadline.calls == 1 && waiting
      }
      let oldOccurrence = store.current?.id
      if retirement == 0 {
        store.pause()
      } else if retirement == 1 {
        store.next()
      } else {
        await store.logout()
      }
      if retirement == 1 {
        try await wait { await native.calls == 2 }
        XCTAssertNotEqual(store.current?.id, oldOccurrence)
      }
      let stops = driver.stops
      await deadline.release(1)
      await native.release(1)
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertEqual(driver.starts, 0)
      XCTAssertEqual(driver.stops, stops)
      if retirement == 0 {
        XCTAssertEqual(store.phase, .paused)
      } else if retirement == 1 {
        XCTAssertEqual(store.phase, .preparing)
      } else {
        XCTAssertNil(store.active)
      }
      store.pause()
    }
  }
  func testNativeFailureDuringPrecisePreparationRetiresPendingStartAndDeadline() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ControlledCatalog()
    await api.usePreciseTiming()
    let deadline = ControlledSleep()
    let native = ControlledSleep()
    defer {
      Task {
        await deadline.releaseAll()
        await native.releaseAll()
      }
    }
    driver.beforeStart = { await native.wait(until: .distantFuture) }
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test",
      preparationSleep: { await deadline.wait(for: $0) })
    await store.enterFixture(service: api)
    store.quality(.original)
    store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
    try await wait {
      let waiting = await native.calls == 1
      return await deadline.calls == 1 && waiting
    }
    driver.onEvent?(.failure)
    XCTAssertEqual(store.phase, .failed)
    XCTAssertFalse(store.playbackRequested)
    let stops = driver.stops
    await deadline.releaseAll()
    await native.releaseAll()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(driver.starts, 0)
    XCTAssertEqual(driver.stops, stops)
    XCTAssertEqual(store.phase, .failed)
  }
  func testExpiredTokenRetiresOnlyItsAccount() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = Connection(
      server: try ServerAddress("https://fixture.test"), userID: "alice", username: "Alice")
    let b = Connection(
      server: try ServerAddress("https://fixture.test"), userID: "bob", username: "Bob")
    try await storage.saveConnections([a, b])
    await vault.write("alice-token", account: a.id)
    await vault.write("bob-token", account: b.id)
    let api = ControlledCatalog()
    await api.failMedia(ClientError.unauthorized)
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test", factory: { _, _ in api })
    await store.bootstrap()
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { store.active == nil }
    let aToken = await vault.read(account: a.id)
    let bToken = await vault.read(account: b.id)
    XCTAssertNil(aToken)
    XCTAssertEqual(bToken, "bob-token")
    XCTAssertEqual(store.connections.map(\.id), [b.id])
    XCTAssertEqual(driver.starts, 0)
  }
  func testExpiredSavedCredentialIsRetiredBeforeQueuePublication() async throws {
    let storage = LibraryStorage()
    let vault = MemoryVault()
    let driver = DriverSpy()
    let account = Connection(
      server: try ServerAddress("https://fixture.test"), userID: "expired", username: "Expired")
    try await storage.saveConnections([account])
    await vault.write("expired-token", account: account.id)
    try await storage.save(
      QueueState(entries: [QueueEntry(MusicItem.fixtureTracks[0])]), account: account.id)
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test",
      factory: { _, _ in throw ClientError.unauthorized })
    await store.bootstrap()
    let token = await vault.read(account: account.id)
    let queue = try await storage.restore(account: account.id)
    XCTAssertNil(store.active)
    XCTAssertTrue(store.queue.entries.isEmpty)
    XCTAssertTrue(store.connections.isEmpty)
    XCTAssertNil(token)
    XCTAssertNil(queue)
    XCTAssertEqual(driver.starts, 0)
  }

  func testConnectionEntryPreservesSavedAccountsWithoutAuthenticatingOrOpeningLibrary() async throws
  {
    let storage = LibraryStorage()
    let vault = MemoryVault()
    let driver = DriverSpy()
    let account = Connection(
      server: try ServerAddress("https://fixture.test"), userID: "saved", username: "Saved")
    try await storage.saveConnections([account])
    await vault.write("invented-token", account: account.id)
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test",
      factory: { _, _ in throw ClientError.unauthorized })
    await store.bootstrap(autoConnect: false)
    XCTAssertEqual(store.connections, [account])
    XCTAssertNil(store.active)
    XCTAssertNil(store.error)
    XCTAssertNil(store.browser)
    XCTAssertTrue(store.queue.entries.isEmpty)
    XCTAssertEqual(driver.starts, 0)
    let token = await vault.read(account: account.id)
    XCTAssertEqual(token, "invented-token")
  }

}

extension StoreTests {
  func testActualAccountRetirementDisarmsTransportAndRejectsLateCopy() throws {
    let capture = TransportCapture.shared
    defer { capture.clear() }
    let store = PlayerStore(
      storage: LibraryStorage(), vault: MemoryVault(), driver: DriverSpy(), deviceID: "invented")
    capture.start(policyBits: 7)
    let ticket = try XCTUnwrap(capture.begin(context: capture.context()))
    let snapshot = try XCTUnwrap(capture.export())
    store.addConnection()
    XCTAssertEqual(capture.currentState(), .idle)
    capture.finish(ticket) {
      XCTFail("retired account getter read")
      return .init(stage: .other, http: 0, error: 0, bytes: 0)
    }
    XCTAssertFalse(
      capture.withCurrentExport(snapshot) { XCTFail("retired account clipboard write") })
  }
}

extension StoreTests {
  func testAlbumQueueEditKeepsCurrentClockSeekReceiptAndNaturalSuccessor() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FixtureCatalog(source: URL(string: "https://invented.invalid/tone")!)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    await store.browser?.start()
    let original = try XCTUnwrap(
      store.playbackSelection(Array(MusicItem.fixtureTracks.prefix(2)), library: "fixture-music"))
    store.playSelection(original)
    try await wait {
      store.queue.entries.dropFirst(store.queue.index + 1).first.map { driver.hasPrepared($0.id) }
        == true
    }
    let current = try XCTUnwrap(store.current)
    driver.onEvent?(.position(current.id, 2))
    store.seek(8)
    let seek = try XCTUnwrap(driver.seekRequests.last)
    let stops = driver.stops
    let starts = driver.starts
    let duplicate = try XCTUnwrap(
      store.playbackSelection(
        [MusicItem.fixtureTracks[2], MusicItem.fixtureTracks[2]], library: "fixture-music"))
    store.enqueueSelection(duplicate, next: true)
    XCTAssertEqual(store.current?.id, current.id)
    XCTAssertEqual(driver.current, current.id)
    XCTAssertEqual(store.queue.position, 2)
    XCTAssertEqual(store.playbackPosition, 8)
    XCTAssertEqual(store.phase, .playing)
    XCTAssertEqual(driver.stops, stops)
    XCTAssertEqual(driver.starts, starts)
    XCTAssertEqual(store.queue.entries.count, 4)
    XCTAssertEqual(Set(store.queue.entries.map(\.id)).count, 4)
    XCTAssertEqual(store.queue.entries[1].track.id, store.queue.entries[2].track.id)
    try await wait {
      store.queue.entries.dropFirst(store.queue.index + 1).first.map { driver.hasPrepared($0.id) }
        == true
    }
    driver.onEvent?(.seekCompleted(current.id, 8, request: seek))
    XCTAssertEqual(store.queue.position, 8)
    let next = store.queue.entries[1].id
    driver.advance()
    XCTAssertEqual(store.current?.id, next, "Natural handoff follows the newly bound successor")
    store.pause()
    let paused = store.current?.id
    let pausedStops = driver.stops
    store.enqueueSelection(duplicate, next: false)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertFalse(store.playbackRequested)
    XCTAssertEqual(store.current?.id, paused)
    XCTAssertEqual(driver.stops, pausedStops)
  }
  func testAlbumQueueEditPreservesColdIntentAndEmptyQueueStaysPaused() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ControlledCatalog()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    await store.browser?.start()
    let selection = try XCTUnwrap(
      store.playbackSelection([MusicItem.fixtureTracks[0]], library: "fixture-music"))
    store.enqueueSelection(selection, next: true)
    XCTAssertFalse(store.playbackRequested)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertEqual(driver.starts, 0)
    await api.blockMedia()
    store.playSelection(selection)
    try await wait { await api.mediaCalls == 1 }
    let occurrence = store.current?.id
    let pending = driver.pending
    store.enqueueSelection(selection, next: true)
    XCTAssertEqual(store.current?.id, occurrence)
    XCTAssertEqual(driver.pending, pending)
    await api.releaseMedia()
    try await wait { driver.starts == 1 }
    XCTAssertEqual(store.current?.id, occurrence)
    XCTAssertEqual(store.queue.entries.count, 2)
    XCTAssertTrue(store.playbackRequested)
  }
  func testShufflePreservesDuplicateOccurrencesAndRejectsRetiredSelection() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(
      service: FixtureCatalog(source: URL(string: "https://invented.invalid/tone")!))
    await store.browser?.start()
    let items = [
      MusicItem.fixtureTracks[0], MusicItem.fixtureTracks[0], MusicItem.fixtureTracks[1],
    ]
    let selection = try XCTUnwrap(store.playbackSelection(items, library: "fixture-music"))
    store.shuffleSelection(selection)
    XCTAssertEqual(store.queue.entries.map(\.track.id).sorted(), items.map(\.id).sorted())
    XCTAssertEqual(Set(store.queue.entries.map(\.id)).count, 3)
    XCTAssertTrue(store.selectionIsCurrent(selection))
    await store.logout()
    let starts = driver.starts
    store.enqueueSelection(selection, next: false)
    store.shuffleSelection(selection)
    store.toggleSelection(selection)
    XCTAssertTrue(store.queue.entries.isEmpty)
    XCTAssertEqual(driver.starts, starts)
  }
}

extension StoreTests {
  func testAlbumQueueEditRejectsLateRetiredSuccessorNegotiation() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    await api.block(2)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    let selection = try await acceptedAlbumSelection(store)
    store.playSelection(selection)
    try await wait { await api.requests.count == 2 }
    let incumbent = try XCTUnwrap(store.current?.id)
    let retiredFuture = store.queue.entries[1].id
    let added = try XCTUnwrap(
      store.playbackSelection([selection.items[2], selection.items[2]], library: "fixture-music"))
    store.enqueueSelection(added, next: true)
    let next = store.queue.entries[1].id
    try await wait {
      store.queue.entries.dropFirst(store.queue.index + 1).first.map { driver.hasPrepared($0.id) }
        == true
    }
    await api.release(2)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(driver.appended, [next])
    XCTAssertFalse(driver.prepared.contains(retiredFuture))
    XCTAssertEqual(store.current?.id, incumbent)
    XCTAssertEqual(driver.starts, 1)
    driver.advance()
    XCTAssertEqual(store.current?.id, next)
    await store.logout()
  }
}

extension StoreTests {
  func testPlayerOptionalDetailLifetimeRejectsReselectionAndKeepsQueueRootAcrossBrowsing()
    async throws
  {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(
      service: FixtureCatalog(source: URL(string: "https://invented.invalid/audio")!))
    let browser = try XCTUnwrap(store.browser)
    await browser.start()
    let selection = try await acceptedAlbumSelection(store)
    store.playSelection(selection)
    try await wait { store.playing }
    let first = try XCTUnwrap(store.current?.id)
    let old = try XCTUnwrap(store.playerContent(occurrence: first))
    let revision = store.playerContentRevision
    driver.onEvent?(.position(first, 2))
    driver.onEvent?(.position(first, 3))
    XCTAssertEqual(
      store.playerContentRevision, revision, "Clock ticks must not retire or refetch metadata")
    browser.selectLibrary("fixture-concerts")
    XCTAssertEqual(old.authorizedLibrary, selection.origin.library, "Player follows its queue root")
    store.select(store.queue.entries[1].id)
    XCTAssertNil(old.authorizedLibrary)
    store.select(first)
    XCTAssertNil(old.authorizedLibrary, "A to B to A must not revive old callbacks")
    XCTAssertNotEqual(store.playerContentRevision, revision)
    let fresh = try XCTUnwrap(store.playerContent(occurrence: first))
    XCTAssertEqual(fresh.authorizedLibrary, selection.origin.library)
    await store.logout()
    XCTAssertNil(fresh.authorizedLibrary)
  }
}

extension StoreTests {
  func testPlayerModesPreserveCurrentSeekClockDuplicatesAndCanonicalFutureOrder() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ImmediateCatalog())
    await store.browser?.start()
    let items = [MusicItem.fixtureTracks[0]] + MusicItem.fixtureTracks + MusicItem.fixtureTracks
    let selection = try XCTUnwrap(store.playbackSelection(items, library: "fixture-music"))
    store.playSelection(selection)
    try await wait {
      store.queue.entries.dropFirst(store.queue.index + 1).first.map { driver.hasPrepared($0.id) }
        == true
    }
    let original = store.queue.entries
    let current = try XCTUnwrap(store.current)
    driver.onEvent?(.position(current.id, 2))
    store.seek(8)
    let seek = try XCTUnwrap(driver.seekRequests.last)
    let starts = driver.starts
    let stops = driver.stops
    store.toggleShuffle()
    XCTAssertTrue(store.shuffleEnabled)
    XCTAssertEqual(store.current, current)
    XCTAssertEqual(store.queue.position, 2)
    XCTAssertEqual(store.playbackPosition, 8)
    XCTAssertEqual(Set(store.queue.entries.map(\.id)), Set(original.map(\.id)))
    XCTAssertEqual(store.queue.entries.count, original.count)
    XCTAssertEqual(store.phase, .playing)
    XCTAssertEqual(driver.current, current.id)
    XCTAssertEqual(driver.starts, starts)
    XCTAssertEqual(driver.stops, stops)
    let added = try XCTUnwrap(
      store.playbackSelection([items[0], items[0]], library: "fixture-music"))
    store.enqueueSelection(added, next: true)
    let additions = Array(store.queue.entries[1...2])
    store.toggleShuffle()
    XCTAssertFalse(store.shuffleEnabled)
    XCTAssertEqual(store.queue.entries, [original[0]] + additions + Array(original.dropFirst()))
    driver.onEvent?(.seekCompleted(current.id, 8, request: seek))
    XCTAssertEqual(store.queue.position, 8)
    store.setRepeatMode(.one)
    XCTAssertEqual(
      driver.prepared, [current.id], "Repeat One retires the unrelated native successor")
    XCTAssertFalse(store.nextRequiresRetry)
    driver.onEvent?(.advanced(original[1].id))
    XCTAssertEqual(
      store.current?.id, current.id, "A retired successor cannot steal current ownership")
    store.setRepeatMode(.off)
    try await wait {
      store.queue.entries.dropFirst(store.queue.index + 1).first.map { driver.hasPrepared($0.id) }
        == true
    }
    XCTAssertEqual(driver.starts, starts)
    driver.advance()
    XCTAssertEqual(store.current?.id, additions[0].id)
    store.pause()
    let pausedStarts = driver.starts
    store.toggleShuffle()
    store.setRepeatMode(.all)
    XCTAssertFalse(store.playbackRequested)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertEqual(driver.starts, pausedStarts)
    store.move(from: store.queue.entries.count - 1, to: 1)
    XCTAssertFalse(store.shuffleEnabled, "Explicit manual order supersedes shuffle order")
    await store.logout()
  }
  func testPlayerModesKeepColdPreparationAndRetireHeldLookahead() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    await api.block(1)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    let selection = try await acceptedAlbumSelection(store)
    store.playSelection(selection)
    try await wait { await api.requests.count == 1 }
    let current = store.current
    let pending = driver.replacements.last
    let replacementCount = driver.replacements.count
    store.toggleShuffle()
    store.setRepeatMode(.one)
    XCTAssertEqual(store.current, current)
    XCTAssertEqual(driver.replacements.count, replacementCount)
    XCTAssertEqual(driver.replacements.last?.target, pending?.target)
    XCTAssertEqual(driver.replacements.last?.authority, pending?.authority)
    XCTAssertEqual(driver.replacements.last?.position, pending?.position)
    await api.release(1)
    try await wait { store.playing }
    XCTAssertEqual(driver.starts, 1)
    XCTAssertEqual(driver.prepared, [try XCTUnwrap(current?.id)])
    await api.block(2)
    store.setRepeatMode(.off)
    try await wait { await api.requests.count == 2 }
    let retiredLookahead = store.setRepeatMode(.one)
    await api.release(2)
    await retiredLookahead?.value
    store.setRepeatMode(.off)
    try await wait {
      store.queue.entries.dropFirst(store.queue.index + 1).first.map { driver.hasPrepared($0.id) }
        == true
    }
    XCTAssertEqual(driver.prepared.count, 2)
    XCTAssertEqual(driver.appended.count, 1, "Canceled lookahead cannot append after a mode change")
    XCTAssertEqual(store.current, current)
    await store.logout()
  }
  func testRepeatUsesExactEndAndRespectsPauseExplicitSkipAndNewAlbumIntent() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ControlledCatalog()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    await store.browser?.start()
    store.setRepeatMode(.all)
    store.next()
    XCTAssertEqual(driver.starts, 0, "Empty mode controls never start audio")
    store.playItems(MusicItem.fixtureTracks, library: "fixture-music")
    try await wait {
      store.queue.entries.dropFirst(store.queue.index + 1).first.map { driver.hasPrepared($0.id) }
        == true
    }
    store.setRepeatMode(.one)
    let first = try XCTUnwrap(store.current?.id)
    let starts = driver.starts
    driver.onEvent?(.timeline(first, duration: 1, seekableEnd: 1))
    driver.onEvent?(.position(first, 25))
    driver.onEvent?(.state(first, .waiting))
    XCTAssertEqual(driver.starts, starts, "Duration and waiting are never EOF")
    driver.finishCurrent()
    try await wait { driver.starts == starts + 1 }
    XCTAssertEqual(store.current?.id, first)
    XCTAssertEqual(store.queue.position, 0)
    store.next()
    try await wait { driver.starts == starts + 2 }
    XCTAssertNotEqual(store.current?.id, first, "Explicit Next overrides Repeat One")
    let second = try XCTUnwrap(store.current?.id)
    store.pause()
    driver.finishCurrent()
    XCTAssertEqual(store.current?.id, second)
    XCTAssertFalse(store.playbackRequested)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertEqual(driver.starts, starts + 2)
    store.play()
    try await wait { store.playing }
    store.setRepeatMode(.all)
    store.select(try XCTUnwrap(store.queue.entries.last?.id))
    try await wait { store.playing }
    let beforeWrap = driver.starts
    driver.finishCurrent()
    try await wait { driver.starts == beforeWrap + 1 }
    XCTAssertEqual(store.queue.index, 0)
    XCTAssertTrue(store.playbackRequested)
    store.previous()
    try await wait { store.playing }
    XCTAssertEqual(store.queue.index, store.queue.entries.count - 1)
    store.next()
    try await wait { store.playing }
    XCTAssertEqual(store.queue.index, 0)
    await api.blockTracks()
    let origin = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
    store.playAlbum(.fixtureAlbum, origin: origin)
    try await wait { await api.trackCalls == 1 }
    let duringAlbum = driver.starts
    driver.finishCurrent()
    XCTAssertEqual(driver.starts, duringAlbum, "Old EOF cannot loop over a newer album intent")
    await api.releaseTracks()
    try await wait { driver.starts == duringAlbum + 1 }
    await store.logout()
  }
  func testRepeatSingleItemAndFailedSuccessorRequireExplicitRetry() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    await api.fail(2, .unavailable)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    let selection = try await acceptedAlbumSelection(store)
    store.setRepeatMode(.all)
    store.playSelection(selection)
    try await wait { store.nextRequiresRetry }
    driver.finishCurrent()
    XCTAssertEqual(store.queue.index, 1)
    XCTAssertEqual(store.phase, .failed)
    XCTAssertFalse(store.playbackRequested)
    let starts = driver.starts
    store.play()
    try await wait { driver.starts == starts + 1 }
    XCTAssertEqual(store.queue.index, 1, "Retry never skips the failed successor")
    store.playItems([selection.items[0]], library: selection.origin.library)
    try await wait { store.playing }
    let occurrence = try XCTUnwrap(store.current?.id)
    let singleStarts = driver.starts
    driver.finishCurrent()
    try await wait { driver.starts == singleStarts + 1 }
    XCTAssertEqual(store.current?.id, occurrence)
    store.setRepeatMode(.off)
    driver.finishCurrent()
    XCTAssertEqual(store.phase, .paused)
    XCTAssertEqual(driver.starts, singleStarts + 1)
    await store.logout()
  }
  func testSessionSleepDeadlineSurvivesEditsPauseAndAlbumChangeThenPausesOnce() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Mutex(Date(timeIntervalSince1970: 1000))
    let sleeper = ControlledSleep()
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test",
      now: { clock.withLock { $0 } }, sleepUntil: { await sleeper.wait(until: $0) })
    await store.enterFixture(service: ImmediateCatalog())
    await store.browser?.start()
    let selection = try await acceptedAlbumSelection(store)
    store.playSelection(selection)
    try await wait { store.playing }
    let expiry = try XCTUnwrap(store.setSleepTimer(minutes: 15))
    try await wait { await sleeper.calls == 1 }
    let deadline = try XCTUnwrap(store.sleepTimerDeadline)
    store.next()
    store.toggleShuffle()
    store.enqueueSelection(selection, next: false)
    store.pause()
    XCTAssertEqual(store.sleepTimerDeadline, deadline)
    store.playSelection(selection)
    try await wait { store.playing }
    XCTAssertEqual(store.sleepTimerDeadline, deadline, "Same-account albums retain the deadline")
    clock.withLock { $0 = deadline }
    await sleeper.release(1)
    await expiry.value
    XCTAssertNil(store.sleepTimerDeadline)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertFalse(store.playbackRequested)
    let starts = driver.starts
    store.play()
    XCTAssertTrue(store.playbackRequested)
    XCTAssertEqual(store.phase, .waiting)
    driver.onEvent?(.state(try XCTUnwrap(store.current?.id), .playing))
    XCTAssertTrue(store.playing)
    XCTAssertEqual(driver.starts, starts, "Explicit Play after expiry resumes the same native item")
    await store.logout()
  }
  func testRetiredSleepExpiryCannotPauseReplacementTimerOrNewAccount() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Mutex(Date(timeIntervalSince1970: 1000))
    let sleeper = ControlledSleep()
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test",
      now: { clock.withLock { $0 } }, sleepUntil: { await sleeper.wait(until: $0) })
    await store.enterFixture(service: ImmediateCatalog())
    await store.browser?.start()
    let selection = try await acceptedAlbumSelection(store)
    store.playSelection(selection)
    try await wait { store.playing }
    let old = try XCTUnwrap(store.setSleepTimer(minutes: 15))
    try await wait { await sleeper.calls == 1 }
    let replacement = try XCTUnwrap(store.setSleepTimer(minutes: 30))
    try await wait { await sleeper.calls == 2 }
    clock.withLock { $0 = Date(timeIntervalSince1970: 10_000) }
    await sleeper.release(1)
    await old.value
    XCTAssertTrue(store.playbackRequested)
    XCTAssertNotNil(store.sleepTimerDeadline)
    store.setSleepTimer(minutes: nil)
    await sleeper.release(2)
    await replacement.value
    XCTAssertTrue(store.playbackRequested)
    XCTAssertNil(store.sleepTimerDeadline)
    let retired = try XCTUnwrap(store.setSleepTimer(minutes: 15))
    try await wait { await sleeper.calls == 3 }
    await store.enterFixture(service: ImmediateCatalog())
    await store.browser?.start()
    let fresh = try await acceptedAlbumSelection(store)
    store.playSelection(fresh)
    try await wait { store.playing }
    await sleeper.release(3)
    await retired.value
    XCTAssertTrue(store.playbackRequested)
    XCTAssertNil(store.sleepTimerDeadline)
    XCTAssertEqual(store.repeatMode, .off)
    XCTAssertFalse(store.shuffleEnabled)
    await store.logout()
    await sleeper.releaseAll()
  }
}

extension StoreTests {
  func testOverdueHeldSleepCannotPauseNewerExplicitPlay() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Mutex(Date(timeIntervalSince1970: 1000))
    let sleeper = ControlledSleep()
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test",
      now: { clock.withLock { $0 } }, sleepUntil: { await sleeper.wait(until: $0) })
    await store.enterFixture(service: ImmediateCatalog())
    let selection = try await acceptedAlbumSelection(store)
    store.playSelection(selection)
    try await wait { store.playing }
    let old = try XCTUnwrap(store.setSleepTimer(minutes: 15))
    try await wait { await sleeper.calls == 1 }
    let deadline = try XCTUnwrap(store.sleepTimerDeadline)
    store.pause()
    store.play()
    XCTAssertEqual(
      store.sleepTimerDeadline, deadline, "A nonoverdue deadline survives explicit Resume")
    clock.withLock { $0 = deadline.addingTimeInterval(1) }
    store.pause()
    store.play()
    XCTAssertNil(store.sleepTimerDeadline)
    let current = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.state(current, .playing))
    await sleeper.release(1)
    await old.value
    XCTAssertTrue(store.playbackRequested)
    XCTAssertEqual(store.phase, .playing, "Late expiry cannot undo the newer explicit Play")
    await store.logout()
  }
  func testQueueShuffleRejectsCurrentOriginWrongKindsBeforeMutationOrMediaAccess() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    let selection = try await acceptedAlbumSelection(store)
    store.playSelection(selection)
    try await wait {
      store.queue.entries.dropFirst(store.queue.index + 1).first.map { driver.hasPrepared($0.id) }
        == true
    }
    let queue = store.queue
    let requests = await api.requests.count
    let replacements = driver.replacements.count
    for kind in ["MusicAlbum", "Book"] {
      let sentinel = MusicItem(
        id: "authored-getter-trap", title: "Invented rejected sentinel",
        artist: "", album: "", duration: 0, number: 0, kind: kind, imageID: nil, imageTag: nil)
      store.shuffleSelection(
        PlaybackSelection(items: [selection.items[0], sentinel], origin: selection.origin))
      XCTAssertFalse(store.shuffleEnabled)
      XCTAssertEqual(store.queue, queue)
      XCTAssertEqual(driver.replacements.count, replacements)
    }
    let finalRequests = await api.requests.count
    XCTAssertEqual(finalRequests, requests, "Wrong-kind sentinel must not reach media negotiation")
    await store.logout()
    store.shuffleSelection(selection)
    XCTAssertFalse(store.shuffleEnabled)
    XCTAssertTrue(store.queue.entries.isEmpty)
  }
}

extension StoreTests {
  func testOverdueHeldSleepStillPausesAcceptedAlbumAndInternalResumes() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Mutex(Date(timeIntervalSince1970: 1000))
    let sleeper = ControlledSleep()
    let api = ControlledCatalog()
    defer {
      Task {
        await api.releaseTracks()
        await sleeper.releaseAll()
      }
    }
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test",
      now: { clock.withLock { $0 } }, sleepUntil: { await sleeper.wait(until: $0) })
    await store.enterFixture(service: api)
    await store.browser?.start()
    store.playItems(MusicItem.fixtureTracks, library: "fixture-music")
    try await wait { store.playing }
    let expiry = try XCTUnwrap(store.setSleepTimer(minutes: 15))
    try await wait { await sleeper.calls == 1 }
    let deadline = try XCTUnwrap(store.sleepTimerDeadline)
    await api.blockTracks()
    let origin = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
    store.playAlbum(.fixtureAlbum, origin: origin)
    try await wait { await api.trackCalls == 1 }
    let starts = driver.starts
    clock.withLock { $0 = deadline.addingTimeInterval(1) }
    await api.releaseTracks()
    try await wait { driver.starts == starts + 1 && store.playing }
    XCTAssertEqual(
      store.sleepTimerDeadline, deadline, "An accepted detail handoff is not a new Play")
    store.quality(.high)
    try await wait { store.playing }
    XCTAssertEqual(store.sleepTimerDeadline, deadline, "Quality replacement retains the deadline")
    store.seek(4)
    try await wait { store.playing }
    XCTAssertEqual(store.sleepTimerDeadline, deadline, "Compatibility seek retains the deadline")
    XCTAssertEqual(driver.startedPositions.last, 4)
    store.remove([try XCTUnwrap(store.queue.entries.last?.id)])
    try await wait { store.playing }
    XCTAssertEqual(store.sleepTimerDeadline, deadline, "Manual queue rebuild is not explicit Play")
    await sleeper.release(1)
    await expiry.value
    XCTAssertNil(store.sleepTimerDeadline)
    XCTAssertFalse(store.playbackRequested)
    XCTAssertEqual(store.phase, .paused)
    await store.logout()
  }
}
