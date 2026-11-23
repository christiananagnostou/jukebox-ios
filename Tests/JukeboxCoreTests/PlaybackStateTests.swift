import AVFoundation
import XCTest

@testable import JukeboxCore

extension StoreTests {
  func testSupersededSourceCannotCancelTheNewAlbumsPreparationDeadline() async throws {
    let (directory, storage, vault, driver) = try context()
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    let clock = ControlledSleep()
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test",
      preparationSleep: { await clock.wait(for: $0) })
    addTeardownBlock { @MainActor in
      store.pause()
      await api.releaseAll()
      await api.releaseAllDetails()
      await clock.releaseAll()
      await store.logout()
      try FileManager.default.removeItem(at: directory)
    }
    await store.enterFixture(service: api)
    await store.browser?.start()
    let origin = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
    await api.hold()
    await api.holdDetails()
    store.playItems([CatalogFixtures.tracks(CatalogFixtures.album(0))[0]], origin: origin)
    try await wait { await api.pendingRequests == [1] }
    try await wait { await clock.calls == 1 }
    let retiredSource = store.deferredPlaybackSettlementForCheck()

    let album = CatalogFixtures.album(1)
    store.playAlbum(album, origin: origin)
    try await wait { await api.detailCalls == 1 }
    XCTAssertTrue(store.isPreparingAlbum(album.id, origin: origin))
    let albumDetail = store.deferredPlaybackSettlementForCheck()
    await api.releaseDetail(1)
    await albumDetail()
    try await wait { await api.pendingRequests == [1, 2] }
    try await wait { await clock.calls == 2 }
    let occurrence = try XCTUnwrap(store.current?.id)
    let newSource = store.deferredPlaybackSettlementForCheck()
    XCTAssertFalse(store.isPreparingAlbum(album.id, origin: origin))
    XCTAssertEqual(store.current?.track.albumID, album.id)

    await clock.release(1)
    await api.release(1, error: .forbidden)
    await retiredSource()
    XCTAssertEqual(store.phase, .preparing)
    XCTAssertNil(store.lastPlaybackFailure)
    await clock.release(2)
    try await wait { store.phase == .failed }
    await api.release(2)
    await newSource()
    XCTAssertEqual(store.lastPlaybackFailure?.detail.step, .preparationDeadline)
    XCTAssertEqual(store.current?.id, occurrence)
    XCTAssertEqual(driver.starts, 0)
  }

  func testNextAtTheLastSongPreservesThePausePositionAndNaturalEndClearsIt() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: LookaheadCatalog())
    let album = try await acceptedAlbumSelection(store)
    let song = try XCTUnwrap(album.items.first)

    for mode in [QueueState.RepeatMode.off, .one] {
      store.setRepeatMode(mode)
      store.playItems([song], origin: album.origin)
      try await wait { store.playing }
      let occurrence = try XCTUnwrap(store.current?.id)
      driver.onEvent?(.position(occurrence, 7.25))
      store.next()
      XCTAssertEqual(store.phase, .paused)
      XCTAssertEqual(store.current?.id, occurrence)
      XCTAssertEqual(store.queue.position, 7.25)
    }

    store.setRepeatMode(.off)
    store.play()
    let last = try XCTUnwrap(store.current?.id)
    driver.finishCurrent()
    XCTAssertEqual(store.phase, .paused)
    XCTAssertEqual(store.current?.id, last)
    XCTAssertEqual(store.queue.position, 0)
    XCTAssertEqual(driver.starts, 2)
    await store.logout()
  }

  func testNativeHandoffAcceptsOnlyTheAdjacentOccurrenceOfARepeatedSong() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: LookaheadCatalog())
    let album = try await acceptedAlbumSelection(store)
    let song = try XCTUnwrap(album.items.first)
    store.playItems([song, song, song], origin: album.origin)
    try await wait { driver.prepared.count == 2 }
    let ids = store.queue.entries.map(\.id)
    driver.onEvent?(.position(ids[0], 12))
    driver.onEvent?(.advanced(ids[2]))
    driver.onEvent?(.advanced(ids[0]))
    XCTAssertEqual(store.current?.id, ids[0])
    XCTAssertEqual(store.queue.position, 12)

    driver.advance()
    XCTAssertEqual(store.current?.id, ids[1])
    XCTAssertEqual(store.queue.position, 0)
    driver.onEvent?(.position(ids[1], 3))
    driver.onEvent?(.finished(ids[0]))
    driver.onEvent?(.advanced(ids[0]))
    store.setRepeatMode(.one)
    driver.onEvent?(.advanced(ids[2]))
    XCTAssertEqual(store.current?.id, ids[1])
    XCTAssertEqual(store.queue.position, 3)
    XCTAssertEqual(driver.starts, 1)
    await store.logout()
  }

  func testSessionInterruptionDuringActivationRequiresANewActivation() async throws {
    let first = UUID()
    let second = UUID()
    let session = PlaybackAudioSessionState()
    do {
      try await session.activate(first) {
        XCTAssertTrue(session.interrupt())
        XCTAssertFalse(session.interrupt())
      } replacingExpiredPlayer: {
        XCTFail("An interruption cannot authorize recovery")
      }
      XCTFail("An interrupted activation cannot play")
    } catch is CancellationError {}
    XCTAssertFalse(session.isActive)
    XCTAssertEqual(session.retire(), first)
    try await session.activate(second) {
    } replacingExpiredPlayer: {
      XCTFail("Healthy activation")
    }
    XCTAssertTrue(session.isActive)
    XCTAssertTrue(session.interrupt())
    XCTAssertFalse(session.isActive)
    XCTAssertNil(session.retire(), "iOS already released the active session")
    XCTAssertFalse(session.interrupt())
  }

  func testExpiredAudioSessionReplacesThePlayerBeforeReactivation() async throws {
    let session = PlaybackAudioSessionState()
    let request = UUID()
    var events: [String] = []
    try await session.activate(request) {
      events.append("activate")
      if events.count == 1 { throw NSError(domain: NSOSStatusErrorDomain, code: 561_210_739) }
    } replacingExpiredPlayer: {
      XCTAssertFalse(session.isActive)
      events.append("replace")
    }
    XCTAssertEqual(events, ["activate", "replace", "activate"])
    XCTAssertTrue(session.isActive)
    XCTAssertEqual(session.retire(), request)
  }

  func testSessionRecoveryIsBoundedAndOnlyForSystemExpiration() async {
    for (domain, code, attempts) in [
      (NSOSStatusErrorDomain, 561_210_739, 2), (NSOSStatusErrorDomain, 560_557_684, 1),
      (NSOSStatusErrorDomain, 561_017_449, 1), (AVFoundationErrorDomain, 561_210_739, 1),
    ] {
      let session = PlaybackAudioSessionState()
      var calls = 0
      var replacements = 0
      do {
        try await session.activate(UUID()) {
          calls += 1
          throw NSError(domain: domain, code: code)
        } replacingExpiredPlayer: {
          replacements += 1
        }
        XCTFail("Persistent activation failure must be surfaced")
      } catch {
        XCTAssertEqual((error as NSError).domain, domain)
        XCTAssertEqual((error as NSError).code, code)
      }
      XCTAssertEqual(calls, attempts)
      XCTAssertEqual(replacements, attempts - 1)
      XCTAssertFalse(session.isActive)
    }
  }

  func testExpiredActivationCannotRetakePlaybackAfterPauseOrReplacement() async throws {
    for superseded in [false, true] {
      let session = PlaybackAudioSessionState()
      let next = UUID()
      do {
        try await session.activate(UUID()) {
          if superseded {
            try await session.activate(next) {
            } replacingExpiredPlayer: {
              XCTFail("Healthy Play")
            }
          } else {
            _ = session.retire()
          }
          throw NSError(domain: NSOSStatusErrorDomain, code: 561_210_739)
        } replacingExpiredPlayer: {
          XCTFail("The old request must leave the player alone")
        }
        XCTFail("The old request must be cancelled")
      } catch is CancellationError {}
      XCTAssertEqual(session.isActive, superseded)
      XCTAssertEqual(session.retire(), superseded ? next : nil)
    }
  }

  func testPersistentAudioSessionExpirationKeepsPausedSongAndRetryPosition() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: LookaheadCatalog())
    store.playSelection(try await acceptedAlbumSelection(store))
    try await wait { store.playing }
    let occurrence = try XCTUnwrap(store.current?.id)
    driver.sampledPausePosition = 122.725
    store.pause()
    driver.resumeAllowed = false
    driver.startError = ConnectionStepError(
      step: .audioSession, error: NSError(domain: NSOSStatusErrorDomain, code: 561_210_739))
    store.play()
    try await wait { store.phase == .failed }
    let failure = try XCTUnwrap(store.lastPlaybackFailure)
    XCTAssertEqual(failure.detail.category, .expiredAudioSession)
    XCTAssertEqual(failure.detail.code, 561_210_739)
    XCTAssertTrue(failure.report(appVersion: "0.1(45)").contains("Kind: expiredAudioSession"))
    XCTAssertEqual(store.error, failure.detail.localizedDescription)
    XCTAssertEqual(store.current?.id, occurrence)
    XCTAssertEqual(store.queue.position, 122.725)
    driver.startError = nil
    store.play()
    try await wait { store.playing }
    XCTAssertEqual(driver.startedPositions.last, 122.725)
    XCTAssertEqual(store.current?.id, occurrence)
    await store.logout()
  }

  func testInterruptionDuringSecondActivationNeverStartsMusic() async throws {
    let session = PlaybackAudioSessionState()
    let request = UUID()
    var attempts = 0
    do {
      try await session.activate(request) {
        attempts += 1
        if attempts == 1 { throw NSError(domain: NSOSStatusErrorDomain, code: 561_210_739) }
        XCTAssertTrue(session.interrupt())
      } replacingExpiredPlayer: {
      }
      XCTFail("A newer interruption owns the transport")
    } catch is CancellationError {}
    XCTAssertEqual(attempts, 2)
    XCTAssertFalse(session.isActive)
    XCTAssertEqual(session.retire(), request)
  }

  func testNativeQueueEditKeepsThePlayingAndNextItemsThroughNaturalHandoff() async throws {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "bridge", withExtension: "mp3", subdirectory: "Fixtures"))
    let first = AVPlayerItem(url: url)
    let next = AVPlayerItem(url: url)
    let obsolete = AVPlayerItem(url: url)
    let player = AVQueuePlayer(items: [first, next, obsolete])
    player.isMuted = true
    defer {
      player.pause()
      player.removeAllItems()
    }
    player.play()
    let clock = ContinuousClock()
    let limit = clock.now.advanced(by: .seconds(24))
    while !(first.currentTime().seconds >= 0.2) && clock.now < limit {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(player.currentItem === first)
    XCTAssertGreaterThanOrEqual(first.currentTime().seconds, 0.2)
    var removed: [AVPlayerItem] = []
    XCTAssertTrue(
      player.retainFuture(after: first, keeping: { $0 === next }, didRemove: { removed.append($0) })
    )
    XCTAssertEqual(removed, [obsolete])
    XCTAssertEqual(player.items(), [first, next])
    while player.currentItem === first && clock.now < limit {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(player.currentItem === next)
    while player.currentItem === next && clock.now < limit {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertNil(player.currentItem)
  }

  func testNativeQueueEditStopsIfRetirementAdvancesTheCurrentItem() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "bridge", withExtension: "mp3", subdirectory: "Fixtures"))
    let items = (0..<3).map { _ in AVPlayerItem(url: url) }
    let player = AVQueuePlayer(items: items)
    player.isMuted = true
    defer { player.removeAllItems() }
    let retained = player.retainFuture(after: items[0]) { _ in
      false
    } didRemove: { removed in
      XCTAssertTrue(removed === items[2])
      player.advanceToNextItem()
    }
    XCTAssertFalse(retained)
    XCTAssertTrue(player.currentItem === items[1])
    XCTAssertEqual(player.items(), [items[1]])
  }

  func testLosingOnlyTheSuccessorLibraryRetiresItsPreparedItem() async throws {
    try await checkSuccessorLibraryRemoval(afterNativeAdvance: false)
  }

  func testLosingOnlyTheSuccessorLibraryDuringHandoffStopsTheRetiredTrack() async throws {
    try await checkSuccessorLibraryRemoval(afterNativeAdvance: true)
  }

  private func checkSuccessorLibraryRemoval(afterNativeAdvance: Bool) async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    await api.respondWithArtwork(nil)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    let browser = try XCTUnwrap(store.browser)
    await browser.start()
    let track = CatalogFixtures.tracks(CatalogFixtures.album(0))[0]
    store.playItems([track], library: "fixture-music")
    try await wait { store.playing }
    let current = try XCTUnwrap(store.current?.id)
    let future = CatalogFixtures.tracks(CatalogFixtures.album(3))[0]
    store.enqueue(
      future, next: true, origin: try XCTUnwrap(store.playbackOrigin(library: "fixture-concerts")))
    let next = try XCTUnwrap(store.queue.successor?.id)
    try await wait { driver.hasPrepared(next) }
    driver.onEvent?(.position(current, 6))
    if afterNativeAdvance { driver.current = next }
    await api.setLibraries(["fixture-music"])
    await browser.loadLibraries()
    await store.deferredPlaybackSettlementForCheck()()
    if afterNativeAdvance {
      XCTAssertNil(driver.current)
      XCTAssertTrue(driver.prepared.isEmpty)
      XCTAssertEqual(store.phase, .paused)
    } else {
      XCTAssertEqual(driver.prepared, [current])
      XCTAssertEqual(store.queue.position, 6)
      XCTAssertEqual(store.phase, .playing)
      XCTAssertFalse(store.nextRequiresRetry)
      driver.finishCurrent()
      XCTAssertEqual(store.phase, .paused)
    }
    XCTAssertEqual(store.current?.id, current)
    XCTAssertFalse(store.queue.entries.contains { $0.id == next })
    XCTAssertEqual(driver.starts, 1)
    await store.logout()
  }

  func testSliderCommitsDirectAdjustmentsAndOnlyTheFinalDragPosition() {
    var scrub = PlaybackScrub()
    XCTAssertEqual(scrub.change(to: 4), 4)
    XCTAssertNil(scrub.preview)
    scrub.begin(at: 4)
    XCTAssertNil(scrub.change(to: 16))
    scrub.begin(at: 5)
    XCTAssertEqual(scrub.preview, 16)
    XCTAssertNil(scrub.change(to: 7))
    XCTAssertEqual(scrub.end(), 7)
    XCTAssertNil(scrub.end())
    scrub.begin(at: 7)
    XCTAssertNil(scrub.end())
    XCTAssertEqual(scrub.change(to: 10), 10)
  }

  func testSystemTogglePausesBufferingAndResumesTheSameSong() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: LookaheadCatalog())
    store.playSelection(try await acceptedAlbumSelection(store))
    try await wait { store.playing }
    let current = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.position(current, 5))
    driver.onEvent?(.state(current, .waiting))
    XCTAssertEqual(store.phase, .waiting)
    store.handleRemote(.toggle)
    driver.onEvent?(.state(current, .playing))
    XCTAssertEqual(store.phase, .paused)
    store.handleRemote(.toggle)
    XCTAssertEqual(store.phase, .waiting)
    XCTAssertEqual(store.current?.id, current)
    XCTAssertEqual(store.playbackPosition, 5)
    XCTAssertEqual(driver.starts, 1)
    await store.logout()
  }

  func testUnchangedSuccessorKeepsItsInFlightRequestAndPreparedItem() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    await api.block(2)
    defer { Task { await api.release(2) } }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    let album = try await acceptedAlbumSelection(store)
    store.playSelection(album)
    try await wait { await api.requests.count == 2 }
    let current = try XCTUnwrap(store.current?.id)
    let next = try XCTUnwrap(store.queue.successor?.id)
    driver.onEvent?(.advanced(current))
    store.enqueueSelection(album, next: false)
    store.setRepeatMode(.all)
    await api.release(2)
    await store.deferredPlaybackSettlementForCheck()()
    XCTAssertEqual(driver.appended, [next])
    store.enqueueSelection(album, next: false)
    store.setRepeatMode(.off)
    XCTAssertTrue(driver.hasPrepared(next), "Appending at the end must keep the next track ready")
    await store.deferredPlaybackSettlementForCheck()()
    let requests = await api.requests.count
    XCTAssertEqual(requests, 2)
    XCTAssertEqual(driver.appended, [next])
    await store.logout()
  }

  func testFailedSuccessorWaitsForExplicitRetryAcrossUnrelatedQueueEdits() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = LookaheadCatalog()
    await api.fail(2, .unavailable)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    let album = try await acceptedAlbumSelection(store)
    store.playSelection(album)
    try await wait { store.nextRequiresRetry }
    let current = try XCTUnwrap(store.current?.id)
    let next = try XCTUnwrap(store.queue.successor?.id)
    driver.onEvent?(.advanced(current))
    store.enqueueSelection(album, next: false)
    store.setRepeatMode(.all)
    await store.deferredPlaybackSettlementForCheck()()
    let beforeRetry = await api.requests.count
    XCTAssertEqual(beforeRetry, 2)
    XCTAssertTrue(store.nextRequiresRetry)
    XCTAssertEqual(driver.prepared, [current])
    store.retryNext()
    await store.deferredPlaybackSettlementForCheck()()
    XCTAssertEqual(driver.appended, [next])
    XCTAssertFalse(store.nextRequiresRetry)
    await store.logout()
  }

  func testLateNativeStateClockAndEndPreserveFailureUntilExplicitPlay() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: LookaheadCatalog())
    store.playSelection(try await acceptedAlbumSelection(store))
    try await wait { store.playing }
    let current = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.position(current, 7))
    driver.onEvent?(
      .failureDetails(current, .init(step: .playbackAudio, error: PlaybackProblem.stalled)))
    let failure = try XCTUnwrap(store.lastPlaybackFailure)
    driver.onEvent?(.state(current, .waiting))
    driver.onEvent?(.position(current, 0))
    driver.onEvent?(.finished(current))
    XCTAssertEqual(store.phase, .failed)
    XCTAssertEqual(store.current?.id, current)
    XCTAssertEqual(store.queue.position, 7)
    XCTAssertEqual(store.lastPlaybackFailure?.id, failure.id)
    driver.resumeAllowed = false
    store.play()
    try await wait { driver.starts == 2 }
    XCTAssertEqual(driver.startedPositions.last, 7)
    await store.logout()
  }
}
