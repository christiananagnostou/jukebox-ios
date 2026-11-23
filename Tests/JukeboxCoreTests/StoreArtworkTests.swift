import XCTest

@testable import JukeboxCore

extension StoreTests {
  func testAlbumPlayRequiresAcceptedInitialRootBeforeAnyDetailRequest() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    await api.respondWithArtwork(nil)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    let browser = try XCTUnwrap(store.browser)
    XCTAssertNil(browser.authorizedLibrary)
    let unaccepted = store.playbackOrigin(library: browser.authorizedLibrary)
    store.playAlbum(.fixtureAlbum, origin: unaccepted)
    await browser.start()
    XCTAssertEqual(browser.authorizedLibrary, "fixture-music")
    try await Task.sleep(for: .milliseconds(20))
    let oldCalls = await api.detailCalls
    XCTAssertEqual(oldCalls, 0, "A captured nil root cannot gain authority after suspension")
    XCTAssertFalse(store.playbackRequested)
    XCTAssertNil(driver.current)
    store.playAlbum(.fixtureAlbum, origin: store.playbackOrigin(library: browser.authorizedLibrary))
    try await wait { driver.current != nil }
    XCTAssertTrue(store.playbackRequested)
    XCTAssertEqual(store.current?.libraryID, "fixture-music")
    await store.logout()
  }
  func testScopedSearchCoversUseCapturedRootInsteadOfMainTabAndRetireExactly() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "invented")
    do {
      await store.enterFixture(service: api)
      let main = try XCTUnwrap(store.browser)
      await main.start()
      let search = try XCTUnwrap(main.searchBrowser())
      search.selectLibrary("fixture-concerts")
      let a = try XCTUnwrap(store.playbackOrigin(library: main.authorizedLibrary))
      let b = try XCTUnwrap(store.playbackOrigin(library: search.authorizedLibrary))
      let album = CatalogFixtures.album(0)
      await api.respondWithArtwork(Data([2]))
      await store.loadCover(album, origin: b)
      XCTAssertEqual(store.cover(album, origin: b), Data([2]))
      XCTAssertNil(store.cover(album, origin: a), "Search B must never insert under main tab A")
      await api.respondWithArtwork(Data([1]))
      await store.loadCover(album, origin: a)
      XCTAssertEqual(store.cover(album, origin: a), Data([1]))
      XCTAssertEqual(store.cover(album, origin: b), Data([2]))
      XCTAssertEqual(main.libraryID, "fixture-music")
      await api.setLibraries(["fixture-music"])
      await main.loadLibraries()
      XCTAssertNil(store.cover(album, origin: b))
      let calls = await api.coverCalls
      await api.setLibraries(["fixture-music", "fixture-concerts"])
      await main.loadLibraries()
      await store.loadCover(album, origin: b)
      let afterRetiredEntry = await api.coverCalls
      XCTAssertEqual(afterRetiredEntry, calls)
      XCTAssertEqual(store.cover(album, origin: a), Data([1]))
      let fresh = try XCTUnwrap(store.playbackOrigin(library: "fixture-concerts"))
      XCTAssertNotEqual(b, fresh)
      search.retire()
      let cancelled = Task { await store.loadCover(album, origin: fresh) }
      cancelled.cancel()
      await cancelled.value
      let afterCancelledEntry = await api.coverCalls
      XCTAssertEqual(afterCancelledEntry, calls)
      await store.enterFixture(service: api)
      await store.browser?.start()
      await store.loadCover(album, origin: a)
      await store.loadCover(album, origin: fresh)
      let afterAccountEntry = await api.coverCalls
      XCTAssertEqual(afterAccountEntry, calls)
      XCTAssertNil(store.cover(album, origin: a))
      XCTAssertNil(store.cover(album, origin: fresh))
      await store.logout()
    } catch {
      await api.releaseArtwork(nil)
      await store.logout()
      throw error
    }
  }
  func testLoadingAndEmptyCanonicalAlbumRetainDisplayOriginAndCachedCoverWithoutPlayableSelection()
    async throws
  {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "invented")
    var loading: Task<Void, Never>?
    do {
      await store.enterFixture(service: api)
      let browser = try XCTUnwrap(store.browser)
      await browser.start()
      let album = CatalogFixtures.album(0)
      let origin = try XCTUnwrap(store.playbackOrigin(library: browser.authorizedLibrary))
      let image = Data([1, 2, 3])
      await api.respondWithArtwork(image)
      await store.loadCover(album, origin: origin)
      await api.respondWithDetailTracks([])
      await api.holdDetails()
      let content = try XCTUnwrap(browser.detail(album))
      loading = Task { await content.load() }
      try await wait { await api.detailCalls == 1 }
      XCTAssertTrue(content.loading)
      XCTAssertTrue(content.tracks.isEmpty)
      XCTAssertNil(store.playbackSelection(content.tracks, library: content.authorizedLibrary))
      let loadingDisplay = try XCTUnwrap(store.playbackOrigin(library: content.authorizedLibrary))
      XCTAssertEqual(
        store.cover(album, origin: loadingDisplay), image,
        "Loading cover is independent of Play readiness")
      await api.releaseDetail(1)
      await loading?.value
      XCTAssertFalse(content.loading)
      XCTAssertNil(content.error)
      XCTAssertTrue(content.tracks.isEmpty)
      XCTAssertNil(store.playbackSelection(content.tracks, library: content.authorizedLibrary))
      let emptyDisplay = try XCTUnwrap(store.playbackOrigin(library: content.authorizedLibrary))
      XCTAssertEqual(emptyDisplay, origin)
      XCTAssertEqual(
        store.cover(album, origin: emptyDisplay), image,
        "A genuinely empty album keeps its accepted cover")
      XCTAssertEqual(driver.starts, 0)
      await store.logout()
      XCTAssertNil(content.authorizedLibrary)
      XCTAssertNil(store.cover(album, origin: emptyDisplay))
      await api.releaseAllDetails()
    } catch {
      loading?.cancel()
      await api.releaseAllDetails()
      await loading?.value
      await store.logout()
      throw error
    }
  }
  func testConcurrentTracksSharingArtworkMakeOneScopedRequest() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    await store.browser?.start()
    let tracks = CatalogFixtures.tracks(CatalogFixtures.album(0))
    await api.holdArtwork()
    let first = Task { await store.loadCover(tracks[0]) }
    let second = Task { await store.loadCover(tracks[1]) }
    do {
      try await wait { await api.coverCalls > 0 }
      for _ in 0..<20 { await Task.yield() }
      let calls = await api.coverCalls
      XCTAssertEqual(calls, 1, "One account/root/image/tag request serves both track consumers")
      await api.releaseArtwork(Data([1, 2, 3]))
      await first.value
      await second.value
      XCTAssertEqual(store.cover(tracks[0]), Data([1, 2, 3]))
      XCTAssertEqual(store.cover(tracks[1]), Data([1, 2, 3]))
      await store.logout()
    } catch {
      first.cancel()
      second.cancel()
      await api.releaseArtwork(nil)
      await first.value
      await second.value
      await store.logout()
      throw error
    }
  }
  private func withCoverStore(
    _ operation: (PlayerStore, HeldCatalog, DriverSpy) async throws -> Void
  ) async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    await store.browser?.start()
    do { try await operation(store, api, driver) } catch {
      await api.releaseArtwork(nil)
      await store.logout()
      throw error
    }
    await api.releaseArtwork(nil)
    await store.logout()
  }
  func testCoverConsumerCancellationKeepsOtherAndNowPlayingConsumersAlive() async throws {
    try await withCoverStore { store, api, driver in
      let tracks = CatalogFixtures.tracks(CatalogFixtures.album(0))
      await api.holdArtwork()
      let first = Task { await store.loadCover(tracks[0]) }
      let second = Task { await store.loadCover(tracks[1]) }
      try await wait { await api.coverCalls == 1 }
      store.playItems([tracks[0]], library: "fixture-music")
      try await wait { driver.current != nil }
      for _ in 0..<20 { await Task.yield() }
      first.cancel()
      await first.value
      let coverFact1 = await api.cancelledCovers.isEmpty
      XCTAssertTrue(coverFact1)
      let data = Data([3, 2, 1])
      await api.releaseArtwork(data)
      await second.value
      try await wait { driver.currentArtwork == data }
      let coverFact2 = await api.coverCalls
      XCTAssertEqual(coverFact2, 1)
      XCTAssertEqual(store.playbackArtwork, data)
    }
  }
  func testAllCoverConsumersCancelAndOldSameKeyCompletionCannotRemoveRetry() async throws {
    try await withCoverStore { store, api, _ in
      let item = CatalogFixtures.album(0)
      await api.holdArtwork()
      let first = Task { await store.loadCover(item) }
      try await wait { await api.coverCalls == 1 }
      first.cancel()
      await first.value
      try await wait { await api.cancelledCovers.contains(1) }
      let retry = Task { await store.loadCover(item) }
      try await wait { await api.coverCalls == 2 }
      await api.releaseCover(1, data: Data([9]))
      for _ in 0..<20 { await Task.yield() }
      XCTAssertNil(store.cover(item))
      await api.releaseCover(2, data: Data([2]))
      await retry.value
      XCTAssertEqual(store.cover(item), Data([2]))
    }
  }
  func testNilFailedAndOversizedCoversDoNotPoisonRetry() async throws {
    try await withCoverStore { store, api, _ in
      let item = CatalogFixtures.album(0)
      await api.holdArtwork()
      for call in 1...4 {
        let load = Task { await store.loadCover(item) }
        try await wait { await api.coverCalls == call }
        if call == 1 {
          await api.releaseCover(call)
        } else if call == 2 {
          await api.releaseCover(call, error: .unavailable)
        } else if call == 3 {
          await api.releaseCover(call, data: Data(repeating: 1, count: 3_000_001))
        } else {
          await api.releaseCover(call, data: Data([4]))
        }
        await load.value
        XCTAssertEqual(store.cover(item), call == 4 ? Data([4]) : nil)
      }
    }
  }
  func testCoverEpochAndRootRetirementFenceLateSameKeyRequests() async throws {
    for retireAccount in [false, true] {
      try await withCoverStore { store, api, _ in
        let item = CatalogFixtures.album(0)
        let browser = try XCTUnwrap(store.browser)
        let origin = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
        await api.holdArtwork()
        let old = Task { await store.loadCover(item, origin: origin) }
        try await wait { await api.coverCalls == 1 }
        if retireAccount {
          await store.enterFixture(service: api)
          await store.browser?.start()
        } else {
          browser.selectLibrary("fixture-concerts")
          let coverFact3 = await api.cancelledCovers.isEmpty
          XCTAssertTrue(coverFact3)
          await api.setLibraries(["fixture-concerts"])
          await browser.loadLibraries()
        }
        await old.value
        let coverFact4 = await api.cancelledCovers.contains(1)
        XCTAssertTrue(coverFact4)
        if !retireAccount {
          await api.setLibraries(["fixture-music", "fixture-concerts"])
          await browser.loadLibraries()
          browser.selectLibrary("fixture-music")
        }
        let newOrigin = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
        let replacement = Task { await store.loadCover(item, origin: newOrigin) }
        try await wait { await api.coverCalls == 2 }
        await api.releaseCover(1, data: Data([9]))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(store.cover(item, origin: newOrigin))
        await api.releaseCover(2, data: Data([2]))
        await replacement.value
        XCTAssertEqual(store.cover(item, origin: newOrigin), Data([2]))
        if retireAccount {
          await store.loadCover(item, origin: origin)
          let coverFact5 = await api.coverCalls
          XCTAssertEqual(coverFact5, 2, "Retired caller cannot inspect/request a successor cover")
        }
      }
    }
  }
  func testCoverRootKeysAndPlaybackAdoptionAreIndependentOfVisibleLibrary() async throws {
    try await withCoverStore { store, api, driver in
      let item = CatalogFixtures.album(0)
      let track = CatalogFixtures.tracks(item)[0]
      let firstOrigin = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
      let secondOrigin = try XCTUnwrap(store.playbackOrigin(library: "fixture-concerts"))
      await api.holdArtwork()
      let first = Task { await store.loadCover(item, origin: firstOrigin) }
      try await wait { await api.coverCalls == 1 }
      let second = Task { await store.loadCover(item, origin: secondOrigin) }
      try await wait { await api.coverCalls == 2 }
      store.playItems([track], origin: firstOrigin)
      try await wait { driver.current != nil }
      store.browser?.selectLibrary("fixture-concerts")
      await api.releaseCover(1, data: Data([1]))
      await api.releaseCover(2, data: Data([2]))
      await first.value
      await second.value
      try await wait { driver.currentArtwork == Data([1]) }
      XCTAssertEqual(store.cover(item, origin: firstOrigin), Data([1]))
      XCTAssertEqual(store.cover(item, origin: secondOrigin), Data([2]))
      XCTAssertEqual(store.playbackArtwork, Data([1]))
      let coverFact6 = await api.coverCalls
      XCTAssertEqual(coverFact6, 2)
    }
  }
  func testDeferredCoverConsumerRejectsRetiredAccountOrReauthorizedRootBeforeRequestEntry()
    async throws
  {
    for retireAccount in [false, true] {
      try await withCoverStore { store, api, _ in
        let item = CatalogFixtures.album(0)
        let origin = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
        let deferred = store.deferredCoverRequestForCheck(item, origin: origin)
        if retireAccount {
          await store.enterFixture(service: api)
          await store.browser?.start()
        } else {
          await api.setLibraries(["fixture-concerts"])
          await store.browser?.loadLibraries()
          await api.setLibraries(["fixture-concerts", "fixture-music"])
          await store.browser?.loadLibraries()
          store.browser?.selectLibrary("fixture-music")
        }
        let currentOrigin = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
        await api.respondWithArtwork(Data([2]))
        await deferred()
        let beforeCurrent = await api.coverCalls
        XCTAssertEqual(
          beforeCurrent, 0,
          "Retired scheduled entry must not inspect/join/request new-owner artwork")
        XCTAssertNil(store.cover(item, origin: currentOrigin))
        await store.loadCover(item, origin: currentOrigin)
        await deferred()
        let afterCurrent = await api.coverCalls
        XCTAssertEqual(afterCurrent, 1)
        XCTAssertEqual(store.cover(item, origin: currentOrigin), Data([2]))
      }
    }
  }
  func testSameImageWithDifferentAcceptedTagsNeverJoinsOrOverwrites() async throws {
    try await withCoverStore { store, api, _ in
      let first = CatalogFixtures.album(0)
      let second = MusicItem(
        id: first.id, title: first.title, artist: first.artist, album: first.album,
        duration: first.duration, number: first.number, kind: first.kind,
        imageID: first.imageID, imageTag: "updated-invented-tag")
      await api.holdArtwork()
      let old = Task { await store.loadCover(first) }
      try await wait { await api.coverCalls == 1 }
      let new = Task { await store.loadCover(second) }
      try await wait { await api.coverCalls == 2 }
      await api.releaseCover(2, data: Data([2]))
      await api.releaseCover(1, data: Data([1]))
      await old.value
      await new.value
      XCTAssertEqual(store.cover(first), Data([1]))
      XCTAssertEqual(store.cover(second), Data([2]))
    }
  }
  func testAllCoverWritersIncrementallyRespectCountAndByteBoundsKeepingCurrentArt() async throws {
    try await withCoverStore { store, api, driver in
      let items = Array(
        (0..<CatalogFixtures.albumCount).map(CatalogFixtures.album)
          .filter { $0.imageID != nil }.prefix(70))
      let data = Data([7])
      await api.respondWithArtwork(data)
      await store.loadCover(items[0])
      store.playItems([CatalogFixtures.tracks(items[0])[0]], library: "fixture-music")
      try await wait { driver.current != nil }
      for item in items[1..<65] { await store.loadCover(item) }
      XCTAssertNotNil(store.cover(items[0]))
      XCTAssertNil(store.cover(items[1]))
      XCTAssertNotNil(store.cover(items[64]))
      XCTAssertEqual(items.filter { store.cover($0) != nil }.count, 64)
      await store.loadCover(items[65])
      XCTAssertEqual(store.cover(items[65]), data)
      XCTAssertNil(store.cover(items[2]))
      XCTAssertEqual(items.filter { store.cover($0) != nil }.count, 64)
      store.playItems([CatalogFixtures.tracks(items[66])[0]], library: "fixture-music")
      try await wait {
        driver.currentArtwork == data && store.current?.track.albumID == items[66].id
      }
      XCTAssertNotNil(store.cover(items[66]))
      XCTAssertEqual(items.filter { store.cover($0) != nil }.count, 64)
      XCTAssertNotNil(store.cover(items[64]))
      await store.enterFixture(service: api)
      await store.browser?.start()
      let large = Data(repeating: 5, count: 2_000_000)
      await api.respondWithArtwork(large)
      await store.loadCover(items[0])
      store.playItems([CatalogFixtures.tracks(items[0])[0]], library: "fixture-music")
      try await wait { driver.current != nil }
      for item in items[1..<7] { await store.loadCover(item) }
      XCTAssertEqual(items.filter { store.cover($0) != nil }.count, 6)
      XCTAssertEqual(store.playbackArtwork, large)
      XCTAssertNil(store.cover(items[1]))
      XCTAssertEqual(store.cover(items[6]), large)
      let calls = await api.coverCalls
      await store.loadCover(items[6])
      let coverFact7 = await api.coverCalls
      XCTAssertEqual(coverFact7, calls)
      XCTAssertEqual(items.filter { store.cover($0) != nil }.count, 6)
    }
  }
  func testArtworkRejectsOldRequestAndDuplicateTrackOccurrence() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ArtworkCatalog()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { await api.artworkCalls == 1 }
    let original = try XCTUnwrap(store.current)
    let starts = driver.starts
    store.enqueue(original.track, next: true)
    XCTAssertEqual(driver.current, original.id)
    XCTAssertEqual(driver.starts, starts, "Queue insertion keeps the current native occurrence")
    let callsAfterInsert = await api.artworkCalls
    XCTAssertEqual(callsAfterInsert, 1, "Insertion does not replace current artwork ownership")
    let duplicate = store.queue.entries[1]
    XCTAssertEqual(duplicate.track.id, original.track.id)
    XCTAssertNotEqual(duplicate.id, original.id)
    store.select(duplicate.id)
    try await wait { await api.artworkCalls == 2 }
    let old = Data("old-request".utf8)
    let current = Data("current-occurrence".utf8)
    await api.release(1, data: old)
    await api.release(2, data: current)
    try await wait { driver.currentArtwork == current }
    XCTAssertFalse(driver.receivedArtworkData.contains(old))
    XCTAssertEqual(driver.artworkPublications.last?.0, duplicate.id)
    await store.logout()
    XCTAssertNil(driver.currentArtwork)
  }
  func testArtworkRetiresAcrossSameAccountReentryAndMissingOrOversizedImages() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = ArtworkCatalog()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { await api.artworkCalls == 1 }
    await store.logout()
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { await api.artworkCalls == 2 }
    let old = Data("previous-login".utf8)
    await api.release(1, data: old)
    await api.release(2, data: nil)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(driver.receivedArtworkData.contains(old))
    XCTAssertNil(driver.currentArtwork)
    XCTAssertEqual(store.phase, .playing)
    store.next()
    try await wait { await api.artworkCalls == 3 }
    await api.release(3, data: Data(repeating: 0, count: 3_000_001))
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(driver.receivedArtworkData.isEmpty)
    await store.logout()
    XCTAssertNil(driver.currentArtwork)
  }
  func testAcceptedAlbumArtworkIsInheritedAndReusedWithoutBlockingPlayback() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = Data("invented-accepted-album-art".utf8)
    let api = ArtworkCatalog(albumArt: image)
    let album = MusicItem(
      id: "album", title: "Invented", artist: "Invented", album: "Invented", duration: 72,
      number: 0, kind: "MusicAlbum", imageID: "album-art", imageTag: "v1")
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    loadedAlbum = try await acceptedAlbumSelection(store, album: album)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { driver.currentArtwork == image }
    XCTAssertEqual(store.current?.track.imageID, "album-art")
    XCTAssertEqual(store.current?.track.imageTag, "v1")
    let calls = await api.artworkCalls
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(store.phase, .playing)
    await store.logout()
    XCTAssertNil(driver.currentArtwork)
  }
}

extension StoreTests {
  func testArtworkToneSharesCoverBudgetAndRejectsLateRetiredExtraction() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://invented.invalid/tone")!))
    await api.respondWithArtwork(Data([1, 2, 3]))
    let gate = ArtworkToneGate()
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test",
      artworkTone: { await gate.tone($0) })
    await store.enterFixture(service: api)
    await store.browser?.start()
    let origin = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
    let albums = (0..<66).map { index in
      MusicItem(
        id: "tone-\(index)", title: "Invented", artist: "Invented", album: "Invented",
        duration: 18, number: 0, kind: "MusicAlbum", imageID: "tone-\(index)", imageTag: "one")
    }
    for item in albums.prefix(65) { await store.loadCover(item, origin: origin) }
    XCTAssertNil(store.cover(albums[0], origin: origin))
    XCTAssertNil(store.coverTone(albums[0], origin: origin))
    XCTAssertNotNil(store.coverTone(albums[64], origin: origin))
    await store.loadCover(albums[64], origin: origin)
    let calls = await gate.calls
    XCTAssertEqual(calls, 65, "Accepted art identity is extracted once, not once per view or clock")
    await gate.hold()
    let late = Task { await store.loadCover(albums[65], origin: origin) }
    try await wait { await gate.waiting }
    await store.logout()
    await gate.release()
    await late.value
    XCTAssertNil(store.cover(albums[65], origin: origin))
    XCTAssertNil(store.coverTone(albums[65], origin: origin))
  }
}
