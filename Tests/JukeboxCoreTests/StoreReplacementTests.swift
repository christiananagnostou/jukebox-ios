import XCTest

@testable import JukeboxCore

extension StoreTests {
  func testEditingFutureQueueKeepsPlayingSourceClockAndUnchangedSuccessor() async throws {
    for quality in [StreamQuality.original, .high, .compact] {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
      let api = LookaheadCatalog()
      await store.enterFixture(service: api)
      store.quality(quality)
      store.playSelection(try await acceptedAlbumSelection(store))
      try await wait { driver.prepared.count == 2 }
      let entries = store.queue.entries
      let initialStops = driver.stops
      driver.onEvent?(.position(entries[0].id, 7.25))
      store.move(from: 3, to: 2)
      XCTAssertEqual(driver.prepared, [entries[0].id, entries[1].id])
      store.remove([entries[3].id])
      XCTAssertEqual(driver.prepared, [entries[0].id, entries[1].id])
      store.remove([entries[1].id])
      try await wait { driver.prepared.last == entries[2].id }
      XCTAssertEqual(driver.prepared, [entries[0].id, entries[2].id])
      XCTAssertEqual(driver.current, entries[0].id)
      XCTAssertEqual(driver.stops, initialStops)
      XCTAssertEqual(driver.starts, 1)
      XCTAssertEqual(store.queue.position, 7.25)
      let requests = await api.requests
      XCTAssertEqual(requests.map(\.0), [entries[0], entries[1], entries[2]].map { $0.track.id })
      await store.logout()
    }
  }

  func testNaturalEndStartsExactSuccessorWhileLookaheadIsStillLoading() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    let api = LookaheadCatalog()
    await api.block(2)
    defer { Task { await api.release(2) } }
    await store.enterFixture(service: api)
    let selection = try await acceptedAlbumSelection(store)
    store.playSelection(
      PlaybackSelection(items: Array(selection.items.prefix(2)), origin: selection.origin))
    try await wait { await api.requests.count == 2 }
    let successor = store.queue.entries[1]
    driver.finishCurrent()
    XCTAssertTrue(store.playbackRequested)
    XCTAssertNil(store.error)
    await api.release(2)
    try await wait { driver.current == successor.id }
    XCTAssertEqual(store.current, successor)
    XCTAssertEqual(driver.startedPositions, [0, 0])
    XCTAssertEqual(driver.prepared, [successor.id])
    await store.logout()
  }

  func testDeferredOriginalFirstPositiveSeekReplacesThenUsesPreciseNativeSeeks() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    await api.useDeferredPrecision()
    defer { Task { await api.releaseAll() } }
    driver.acceptsPlaybackReplacement = true
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    await store.browser?.start()
    let selection = try XCTUnwrap(
      store.playbackSelection(
        [CatalogFixtures.tracks(.fixtureAlbum)[0]], library: "fixture-music"))
    store.playSelection(selection)
    try await wait { driver.starts == 1 }
    let occurrence = try XCTUnwrap(store.current?.id)
    let original = try XCTUnwrap(driver.startedSources.last)
    XCTAssertFalse(original.preferPreciseTiming)
    XCTAssertTrue(original.preciseSeekingRequired)
    XCTAssertFalse(driver.requiresSourceReplacementForSeek(occurrence: UUID(), position: 8))
    XCTAssertFalse(driver.requiresSourceReplacementForSeek(occurrence: occurrence, position: 0))
    driver.onEvent?(.position(occurrence, 2))
    store.seek(0)
    XCTAssertEqual(driver.lastSeek, 0)
    XCTAssertEqual(driver.starts, 1)
    await api.hold()
    store.seek(8)
    try await wait { await api.pendingRequests.count == 1 }
    XCTAssertEqual(store.queue.position, 2)
    XCTAssertEqual(store.playbackPosition, 8)
    XCTAssertEqual(driver.lastSeek, 0, "A first positive FLAC seek cannot use the approximate item")
    try await store.saveNow()
    let account = try XCTUnwrap(store.active?.id)
    let checkpoint = try await storage.restore(account: account)
    XCTAssertEqual(checkpoint?.position, 2)
    let pendingRequests = await api.pendingRequests
    let request = try XCTUnwrap(pendingRequests.first)
    await api.release(request)
    try await wait { driver.starts == 2 }
    XCTAssertEqual(driver.startedPositions.last, 8)
    XCTAssertTrue(try XCTUnwrap(driver.startedSources.last).preferPreciseTiming)
    XCTAssertEqual(driver.startedSources.last?.url, original.url)
    XCTAssertEqual(driver.startedSources.last?.timeOrigin, 0)
    driver.onEvent?(.position(occurrence, 8.025))
    store.seek(4)
    XCTAssertEqual(driver.lastSeek, 4)
    XCTAssertEqual(driver.starts, 2, "The precise current source handles later seeks in place")
    XCTAssertEqual(store.queue.position, 8.025)
    driver.onEvent?(.seekCompleted(occurrence, 4.01, request: driver.seekRequests.last))
    XCTAssertEqual(store.queue.position, 4.01)
    await store.logout()
  }

  func testPausedDeferredOriginalSeekRetiresSourceAndWaitsForExplicitPlay() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    await api.useDeferredPrecision()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    await store.browser?.start()
    store.playSelection(
      try XCTUnwrap(
        store.playbackSelection(
          [CatalogFixtures.tracks(.fixtureAlbum)[0]], library: "fixture-music")))
    try await wait { driver.starts == 1 }
    let occurrence = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.position(occurrence, 2))
    store.pause()
    let stops = driver.stops
    store.seek(8)
    XCTAssertEqual(driver.stops, stops + 1)
    XCTAssertNil(driver.current)
    XCTAssertNil(driver.lastSeek)
    XCTAssertEqual(store.queue.position, 8)
    XCTAssertEqual(store.playbackPosition, 8)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertFalse(store.playbackRequested)
    try await store.saveNow()
    let account = try XCTUnwrap(store.active?.id)
    let checkpoint = try await storage.restore(account: account)
    XCTAssertEqual(checkpoint?.position, 8)
    store.seek(4)
    XCTAssertEqual(driver.starts, 1)
    XCTAssertEqual(store.queue.position, 4)
    store.play()
    try await wait { driver.starts == 2 }
    XCTAssertEqual(driver.startedPositions.last, 4)
    XCTAssertTrue(try XCTUnwrap(driver.startedSources.last).preferPreciseTiming)
    await store.logout()
  }

  func testPendingDeferredOriginalReversePauseAndExplicitPausedTargetRejectLateSources()
    async throws
  {
    for pausedTarget in [Double?.none, Double?.some(3)] {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
      await api.useDeferredPrecision()
      defer { Task { await api.releaseAll() } }
      driver.acceptsPlaybackReplacement = true
      let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
      await store.enterFixture(service: api)
      await store.browser?.start()
      store.playSelection(
        try XCTUnwrap(
          store.playbackSelection(
            [CatalogFixtures.tracks(.fixtureAlbum)[0]], library: "fixture-music")))
      try await wait { driver.starts == 1 }
      let occurrence = try XCTUnwrap(store.current?.id)
      driver.onEvent?(.position(occurrence, 2))
      await api.hold()
      store.seek(8)
      try await wait { await api.pendingRequests.count == 1 }
      store.seek(4)
      try await wait { await api.pendingRequests.count == 2 }
      let retired = await api.pendingRequests
      XCTAssertEqual(store.queue.position, 2)
      XCTAssertEqual(store.playbackPosition, 4)
      store.pause()
      XCTAssertEqual(store.queue.position, 2)
      XCTAssertEqual(store.playbackPosition, 2, "Pause cancels an unacknowledged source target")
      if let pausedTarget { store.seek(pausedTarget) }
      for request in retired.reversed() { await api.release(request) }
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertEqual(driver.starts, 1)
      XCTAssertFalse(store.playbackRequested)
      XCTAssertEqual(store.queue.position, pausedTarget ?? 2)
      store.play()
      try await wait { await api.pendingRequests.count == 1 }
      let latestRequests = await api.pendingRequests
      let latest = try XCTUnwrap(latestRequests.first)
      await api.release(latest)
      try await wait { driver.starts == 2 }
      XCTAssertEqual(driver.startedPositions.last, pausedTarget ?? 2)
      XCTAssertTrue(try XCTUnwrap(driver.startedSources.last).preferPreciseTiming)
      await store.logout()
    }
  }

  func testDeferredOriginalSeekCannotSurviveRootRemovalOrOverwriteNewerStopIntent()
    async throws
  {
    for replacement in ["root", "newPlay", "pausedSeek"] {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
      await api.useDeferredPrecision()
      defer { Task { await api.releaseAll() } }
      driver.acceptsPlaybackReplacement = true
      let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
      await store.enterFixture(service: api)
      let browser = try XCTUnwrap(store.browser)
      await browser.start()
      store.playSelection(
        try XCTUnwrap(
          store.playbackSelection(
            Array(CatalogFixtures.tracks(.fixtureAlbum).prefix(2)), library: "fixture-music")))
      try await wait { driver.starts == 1 }
      let first = try XCTUnwrap(store.current?.id)
      driver.onEvent?(.position(first, 2))
      if replacement == "root" {
        await api.hold()
        store.seek(8)
        try await wait { !(await api.pendingRequests).isEmpty }
        await api.setLibraries(["fixture-concerts"])
        await browser.loadLibraries()
        XCTAssertFalse(store.playbackRequested)
        for request in await api.pendingRequests { await api.release(request) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(driver.starts, 1)
        XCTAssertNil(driver.pending)
      } else if replacement == "newPlay" {
        store.pause()
        let next = store.queue.entries[1].id
        driver.afterStop = { store.select(next) }
        store.seek(8)
        try await wait { driver.starts == 2 }
        XCTAssertEqual(store.current?.id, next)
        XCTAssertEqual(driver.startedPositions.last, 0)
        XCTAssertEqual(store.queue.position, 0, "An old paused seek cannot commit after newer Play")
        XCTAssertTrue(store.playbackRequested)
      } else {
        store.pause()
        driver.afterStop = { store.seek(2) }
        store.seek(8)
        XCTAssertEqual(
          store.queue.position, 2, "An equal-clock newer paused target owns its stop lease")
        XCTAssertEqual(store.playbackPosition, 2)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertFalse(store.playbackRequested)
        store.play()
        try await wait { driver.starts == 2 }
        XCTAssertEqual(driver.startedPositions.last, 2)
      }
      await store.logout()
    }
  }

  func testAlbumCardDetailRepliesKeepLatestPlayAndPauseIntent() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    await api.respondWithArtwork(nil)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    let browser = try XCTUnwrap(store.browser)
    await browser.start()
    await api.holdDetails()
    let firstAlbum = CatalogFixtures.album(0)
    let latestAlbum = CatalogFixtures.album(1)
    let origin = try XCTUnwrap(store.playbackOrigin(library: browser.authorizedLibrary))
    do {
      store.playAlbum(firstAlbum, origin: origin)
      try await wait { await api.detailCalls == 1 }
      store.playAlbum(latestAlbum, origin: origin)
      try await wait { await api.detailCalls == 2 }
      await api.releaseDetail(2)
      try await wait { store.current?.track.albumID == latestAlbum.id }
      await api.releaseDetail(1)
      try await wait { !store.isPreparingAlbum(latestAlbum.id, origin: origin) }
      XCTAssertEqual(
        store.current?.track.albumID, latestAlbum.id, "Late A must not replace newer B")
      store.playAlbum(firstAlbum, origin: origin)
      try await wait { await api.detailCalls == 3 }
      store.pause()
      await api.releaseDetail(3)
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertFalse(
        store.playbackRequested, "A detail reply must not override newer explicit Pause")
      let calls = await api.detailCalls
      store.playAlbum(firstAlbum, origin: origin)
      store.pause()
      try await Task.sleep(for: .milliseconds(20))
      let afterImmediatePause = await api.detailCalls
      XCTAssertEqual(afterImmediatePause, calls)
      XCTAssertFalse(store.isPreparingAlbum(firstAlbum.id, origin: origin))
      XCTAssertFalse(store.playbackRequested)
      await api.releaseAllDetails()
      await store.logout()
    } catch {
      store.pause()
      await api.releaseAllDetails()
      await store.logout()
      throw error
    }
  }
  func testAlbumPlayKeepsNativeLeaseAndCapturedRootAcrossNaturalAdvanceAndBrowsing() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    await api.respondWithArtwork(nil)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    do {
      await store.enterFixture(service: api)
      let browser = try XCTUnwrap(store.browser)
      await browser.start()
      let origin = try XCTUnwrap(store.playbackOrigin(library: browser.authorizedLibrary))
      let old = CatalogFixtures.album(0)
      let target = CatalogFixtures.album(1)
      store.playSelection(PlaybackSelection(items: CatalogFixtures.tracks(old), origin: origin))
      try await wait { store.playing && driver.prepared.count > 1 }
      let native = driver.current
      let stops = driver.stops
      await api.holdDetails()
      store.playAlbum(target, origin: origin)
      XCTAssertEqual(driver.remoteIntentRenewals, 1, "Rebind command receipts synchronously")
      XCTAssertEqual(
        driver.current, native, "Accepting detail work must not retire old native controls")
      XCTAssertEqual(driver.stops, stops)
      XCTAssertTrue(store.playing)
      try await wait { await api.detailCalls == 1 }
      driver.advance()
      XCTAssertNotEqual(driver.current, native)
      XCTAssertTrue(
        store.isPreparingAlbum(target.id, origin: origin),
        "Natural advance is not a new user command")
      browser.selectCategory(.songs)
      browser.selectLibrary("fixture-concerts")
      await browser.loadLibraries()
      XCTAssertTrue(
        store.isPreparingAlbum(target.id, origin: origin),
        "Healthy browsing must not own explicit Play")
      await api.releaseDetail(1)
      try await wait { store.current?.track.albumID == target.id }
      XCTAssertEqual(
        store.current?.libraryID, "fixture-music", "Never infer the later selected root")
      XCTAssertTrue(store.playbackRequested)
      store.playSelection(
        PlaybackSelection(items: [CatalogFixtures.tracks(target)[0]], origin: origin))
      try await wait { driver.starts == 3 }
      let finalTarget = CatalogFixtures.album(2)
      store.playAlbum(finalTarget, origin: origin)
      try await wait { await api.detailCalls == 2 }
      driver.finishCurrent()
      XCTAssertNil(driver.current, "The completed old source clears truthfully")
      XCTAssertEqual(store.phase, .paused)
      XCTAssertTrue(
        store.isPreparingAlbum(finalTarget.id, origin: origin),
        "Terminal old completion must not cancel newer Play")
      await api.releaseDetail(2)
      try await wait { store.current?.track.albumID == finalTarget.id && store.playing }
      await api.releaseAllDetails()
      await store.logout()
    } catch {
      store.pause()
      await api.releaseAllDetails()
      await store.logout()
      throw error
    }
  }
  func testAlbumPlayIsSupersededByEveryExplicitBoundCommand() async throws {
    for command in ["pause", "play", "seek", "next", "select", "quality"] {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
      await api.respondWithArtwork(nil)
      let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
      do {
        await store.enterFixture(service: api)
        await store.browser?.start()
        let origin = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
        let old = CatalogFixtures.album(0)
        let target = CatalogFixtures.album(1)
        store.playSelection(PlaybackSelection(items: CatalogFixtures.tracks(old), origin: origin))
        try await wait { store.playing && driver.prepared.count > 1 }
        await api.holdDetails()
        store.playAlbum(target, origin: origin)
        try await wait { await api.detailCalls == 1 }
        switch command {
        case "pause": store.pause()
        case "play": store.play()
        case "seek": store.seek(1)
        case "next": store.next()
        case "select": store.select(try XCTUnwrap(store.current?.id))
        case "quality": store.quality(.high)
        default: XCTFail("Unknown invented command")
        }
        XCTAssertFalse(store.isPreparingAlbum(target.id, origin: origin), command)
        await api.releaseDetail(1)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.current?.track.albumID, old.id, command)
        XCTAssertEqual(store.playbackRequested, command != "pause", command)
        await api.releaseAllDetails()
        await store.logout()
      } catch {
        store.pause()
        await api.releaseAllDetails()
        await store.logout()
        throw error
      }
    }
  }
  func testAlbumPlayRetirementAndFailureCannotStealSuccessorOrPreventRetry() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    await api.respondWithArtwork(nil)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    do {
      await store.enterFixture(service: api)
      let browser = try XCTUnwrap(store.browser)
      await browser.start()
      let origin = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
      let target = CatalogFixtures.album(1)
      await api.holdDetails()
      store.playAlbum(target, origin: origin)
      try await wait { await api.detailCalls == 1 }
      await api.releaseDetail(1, error: .unavailable)
      try await wait { !store.isPreparingAlbum(target.id, origin: origin) }
      XCTAssertNotNil(store.error)
      XCTAssertEqual(driver.starts, 0)
      store.playAlbum(target, origin: origin)
      try await wait { await api.detailCalls == 2 }
      await api.setLibraries(["fixture-concerts"])
      await browser.loadLibraries()
      XCTAssertFalse(store.isPreparingAlbum(target.id, origin: origin))
      await api.setLibraries(["fixture-music", "fixture-concerts"])
      await browser.loadLibraries()
      let fresh = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
      store.playAlbum(target, origin: fresh)
      try await wait { await api.detailCalls == 3 }
      await api.releaseDetail(2)
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertTrue(
        store.isPreparingAlbum(target.id, origin: fresh),
        "Retired root reply must not clear a new owner")
      XCTAssertEqual(driver.starts, 0)
      await api.releaseDetail(3)
      try await wait { store.playing }
      XCTAssertEqual(driver.starts, 1)
      let validB = CatalogFixtures.album(2)
      store.playSelection(
        try XCTUnwrap(
          store.playbackSelection(CatalogFixtures.tracks(validB), library: "fixture-concerts")))
      try await wait { store.current?.track.albumID == validB.id && store.playing }
      let stops = driver.stops
      store.playAlbum(target, origin: origin)
      XCTAssertEqual(driver.stops, stops)
      XCTAssertEqual(store.current?.track.albumID, validB.id)
      XCTAssertFalse(store.isPreparingAlbum(target.id, origin: origin))
      let afterRetiredCallback = await api.detailCalls
      XCTAssertEqual(afterRetiredCallback, 3)
      store.playAlbum(target, origin: fresh)
      store.addConnection()
      try await Task.sleep(for: .milliseconds(20))
      let calls = await api.detailCalls
      XCTAssertEqual(calls, 3)
      await store.enterFixture(service: api)
      await store.browser?.start()
      let successor = CatalogFixtures.album(2)
      let selection = try XCTUnwrap(
        store.playbackSelection(CatalogFixtures.tracks(successor), library: "fixture-music"))
      store.playSelection(selection)
      try await wait { store.current?.track.albumID == successor.id && store.playing }
      store.playAlbum(target, origin: fresh)
      XCTAssertEqual(
        store.current?.track.albumID, successor.id, "A retired callback owns no successor")
      XCTAssertFalse(store.isPreparingAlbum(target.id, origin: fresh))
      let finalCalls = await api.detailCalls
      XCTAssertEqual(finalCalls, 3)
      await api.releaseAllDetails()
      await store.logout()
    } catch {
      store.pause()
      await api.releaseAllDetails()
      await store.logout()
      throw error
    }
  }
  func testForbiddenDetailRetiresCapturedRootBeforeRefreshAndOldCallbackCannotReplaceSuccessor()
    async throws
  {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    await api.respondWithArtwork(nil)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    do {
      await store.enterFixture(service: api)
      let browser = try XCTUnwrap(store.browser)
      await browser.start()
      let old = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
      store.playSelection(
        PlaybackSelection(items: CatalogFixtures.tracks(CatalogFixtures.album(0)), origin: old))
      try await wait { store.playing }
      await api.holdDetails()
      store.playAlbum(CatalogFixtures.album(1), origin: old)
      try await wait { await api.detailCalls == 1 }
      await api.releaseDetail(1, error: .forbidden)
      try await wait { browser.libraries.isEmpty }
      XCTAssertFalse(store.playbackRequested)
      XCTAssertNil(driver.current, "Actual authorization clearing retires the old native source")
      XCTAssertFalse(store.isPreparingAlbum(CatalogFixtures.album(1).id, origin: old))
      await browser.loadLibraries()
      let fresh = try XCTUnwrap(store.playbackOrigin(library: "fixture-music"))
      XCTAssertNotEqual(
        old, fresh, "Refresh cannot resurrect an authorization-retired root capability")
      let successor = CatalogFixtures.album(2)
      store.playSelection(
        PlaybackSelection(items: CatalogFixtures.tracks(successor), origin: fresh))
      try await wait { store.playing }
      let stops = driver.stops
      let occurrence = store.current?.id
      store.playAlbum(CatalogFixtures.album(1), origin: old)
      store.playSelection(PlaybackSelection(items: [CatalogFixtures.album(0)], origin: old))
      XCTAssertEqual(driver.stops, stops)
      XCTAssertEqual(store.current?.id, occurrence)
      XCTAssertTrue(store.playbackRequested)
      let calls = await api.detailCalls
      XCTAssertEqual(calls, 1, "Rejected callback cannot enter old detail work")
      await api.releaseAllDetails()
      await store.logout()
    } catch {
      store.pause()
      await api.releaseAllDetails()
      await store.logout()
      throw error
    }
  }
  func testColdAlbumReplacementEntersPendingOwnerBeforeFreshMedia() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(
      service: FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    await store.browser?.start()
    loadedAlbum = try await acceptedAlbumSelection(store, album: CatalogFixtures.album(0))
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { driver.starts == 1 }
    let stops = driver.stops
    loadedAlbum = try await acceptedAlbumSelection(store, album: CatalogFixtures.album(1))
    driver.acceptsPlaybackReplacement = true
    store.playSelection(try XCTUnwrap(loadedAlbum))
    XCTAssertEqual(driver.stops, stops, "Known cold replacement must not take the full Stop lane")
    XCTAssertEqual(driver.replacements.last?.target.id, store.current?.id)
    XCTAssertEqual(driver.replacements.last?.authority.library, store.current?.libraryID)
    XCTAssertEqual(store.phase, .preparing)
    XCTAssertEqual(store.queue.position, 0)
    store.pause()
    await store.logout()
  }
  func testColdPendingSeeksRenegotiateLatestOffsetWithoutAcceptingDiskClockForEveryQuality()
    async throws
  {
    for quality in StreamQuality.allCases {
      let (directory, storage, vault, driver) = try context()
      defer { try? FileManager.default.removeItem(at: directory) }
      let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
      let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
      do {
        await store.enterFixture(service: api)
        await store.browser?.start()
        driver.acceptsPlaybackReplacement = true
        store.quality(quality)
        let tracks = CatalogFixtures.tracks(CatalogFixtures.album(0))
        let selection = try XCTUnwrap(
          store.playbackSelection([tracks[0]], library: "fixture-music"))
        await api.hold()
        store.playSelection(selection)
        try await wait { await api.pendingRequests.count == 1 }
        store.seek(6)
        try await wait { await api.pendingRequests.count == 2 }
        store.seek(2)
        try await wait { await api.pendingRequests.count == 3 }
        XCTAssertEqual(store.queue.position, 0)
        XCTAssertEqual(
          store.playbackPosition, 2, "Cold source intent shares the presentation handoff")
        try await store.saveNow()
        let account = try XCTUnwrap(store.active?.id)
        let disk = try await storage.restore(account: account)
        XCTAssertEqual(disk?.position, 0)
        let requests = await api.pendingRequests
        await api.release(requests[2])
        try await wait { driver.starts == 1 }
        XCTAssertEqual(driver.startedPositions, [2])
        XCTAssertEqual(driver.startedSources.last?.quality, quality)
        XCTAssertEqual(driver.startedSources.last?.timeOrigin, 2)
        await api.release(requests[0], error: .unavailable)
        await api.release(requests[1])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(driver.starts, 1)
        XCTAssertTrue(store.playbackRequested)
        XCTAssertNotEqual(store.phase, .failed)
        let occurrence = try XCTUnwrap(store.current?.id)
        driver.onEvent?(.seekCompleted(occurrence, 2))
        try await wait { (try? await storage.restore(account: account))?.position == 2 }
        store.playSelection(selection)
        try await wait { await api.pendingRequests.count == 1 }
        store.seek(6)
        try await wait { await api.pendingRequests.count == 2 }
        store.seek(0)
        try await wait { await api.pendingRequests.count == 3 }
        let zeroRequests = await api.pendingRequests
        await api.release(zeroRequests[2])
        try await wait { driver.starts == 2 }
        XCTAssertEqual(driver.startedPositions.last, 0)
        XCTAssertEqual(driver.startedSources.last?.timeOrigin, 0)
        store.pause()
        await api.releaseAll()
        await store.logout()
      } catch {
        store.pause()
        await api.releaseAll()
        await store.logout()
        throw error
      }
    }
  }
  func testColdPendingRapidReplacementPauseFailureAndRetryRejectStaleReplies() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    do {
      await store.enterFixture(service: api)
      await store.browser?.start()
      driver.acceptsPlaybackReplacement = true
      let a = try XCTUnwrap(
        store.playbackSelection(
          [CatalogFixtures.tracks(CatalogFixtures.album(0))[0]], library: "fixture-music"))
      let b = try XCTUnwrap(
        store.playbackSelection(
          [CatalogFixtures.tracks(CatalogFixtures.album(1))[0]], library: "fixture-music"))
      await api.hold()
      store.playSelection(a)
      try await wait { await api.pendingRequests.count == 1 }
      store.playSelection(b)
      try await wait { await api.pendingRequests.count == 2 }
      store.playSelection(a)
      try await wait { await api.pendingRequests.count == 3 }
      let requests = await api.pendingRequests
      await api.release(requests[1], error: .forbidden)
      await api.release(requests[0])
      try await Task.sleep(for: .milliseconds(30))
      XCTAssertEqual(driver.starts, 0)
      XCTAssertEqual(store.current?.track.id, a.items[0].id)
      XCTAssertEqual(store.phase, .preparing)
      await api.release(requests[2])
      try await wait { driver.starts == 1 }
      store.playSelection(b)
      try await wait { await api.pendingRequests.count == 1 }
      store.pause()
      await api.releaseAll()
      try await Task.sleep(for: .milliseconds(30))
      XCTAssertEqual(driver.starts, 1)
      XCTAssertFalse(store.playbackRequested)
      XCTAssertNil(driver.pending)
      await api.hold()
      store.play()
      try await wait { await api.pendingRequests.count == 1 }
      let failedRequest = await api.pendingRequests.first
      await api.release(try XCTUnwrap(failedRequest), error: .unavailable)
      try await wait { store.phase == .failed }
      XCTAssertFalse(store.playbackRequested)
      XCTAssertNil(driver.pending)
      store.play()
      try await wait { await api.pendingRequests.count == 1 }
      await api.releaseAll()
      try await wait { driver.starts == 2 }
      XCTAssertEqual(store.current?.track.id, b.items[0].id)
      await store.logout()
    } catch {
      store.pause()
      await api.releaseAll()
      await store.logout()
      throw error
    }
  }
  func testCapturedPlaybackOriginSurvivesTabSwitchButRetiresWithItsActualRoot() async throws {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = HeldCatalog(FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    do {
      await store.enterFixture(service: api)
      let browser = try XCTUnwrap(store.browser)
      await browser.start()
      loadedAlbum = try await acceptedAlbumSelection(store, album: CatalogFixtures.album(0))
      let captured = try XCTUnwrap(loadedAlbum)
      driver.acceptsPlaybackReplacement = true
      browser.selectLibrary("fixture-concerts")
      store.playSelection(try XCTUnwrap(loadedAlbum))
      XCTAssertEqual(store.current?.libraryID, "fixture-music")
      store.pause()
      let live = try XCTUnwrap(store.playbackOrigin(library: "fixture-concerts"))
      store.playSelection(captured)
      store.enqueue(CatalogFixtures.tracks(CatalogFixtures.album(1))[0], next: true, origin: live)
      store.pause()
      XCTAssertEqual(store.queue.entries[1].libraryID, "fixture-concerts")
      await api.hold()
      store.playSelection(captured)
      try await wait { !(await api.pendingRequests).isEmpty }
      await browser.loadLibraries()
      XCTAssertTrue(store.playbackRequested, "Healthy refresh retains the source root")
      await api.setLibraries(["fixture-concerts"])
      await browser.loadLibraries()
      XCTAssertFalse(store.playbackRequested)
      XCTAssertNil(driver.pending)
      let starts = driver.starts
      await api.releaseAll()
      try await Task.sleep(for: .milliseconds(30))
      XCTAssertEqual(driver.starts, starts)
      store.playSelection(captured)
      XCTAssertFalse(
        store.playbackRequested, "Retired detail origin cannot be relabeled as the visible root")
      XCTAssertNil(store.current)
      XCTAssertTrue(store.queue.entries.isEmpty)
      store.playItems([CatalogFixtures.tracks(CatalogFixtures.album(1))[0]])
      XCTAssertNil(
        store.current?.libraryID, "Unknown legacy provenance takes the full-stop fallback")
      store.pause()
      await store.logout()
    } catch {
      store.pause()
      await api.releaseAll()
      await store.logout()
      throw error
    }
  }
  func testRetiredCapturedOriginRejectsAudioAndInvalidPayloadWithoutRetiringSuccessor() async throws
  {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    await store.browser?.start()
    let stale = try XCTUnwrap(
      store.playbackSelection(
        [CatalogFixtures.tracks(CatalogFixtures.album(0))[0]], library: "fixture-music"))
    await store.enterFixture(service: api)
    await store.browser?.start()
    loadedAlbum = try await acceptedAlbumSelection(store, album: CatalogFixtures.album(1))
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { store.playing }
    let successor = store.current
    let stops = driver.stops
    store.playSelection(stale)
    store.playSelection(PlaybackSelection(items: [CatalogFixtures.album(0)], origin: stale.origin))
    XCTAssertEqual(store.current, successor)
    XCTAssertEqual(driver.stops, stops)
    XCTAssertTrue(store.playbackRequested)
    XCTAssertTrue(store.playing)
    XCTAssertNil(store.playbackSelection([CatalogFixtures.album(0)], library: "retired-root"))
    await store.logout()
  }
  func testPreparedSelectionUsesNextReplacementAuthorityAndPauseCancelsPendingSource() async throws
  {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: fixture)
    await store.browser?.start()
    loadedAlbum = try await acceptedAlbumSelection(store, album: CatalogFixtures.album(0))
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { driver.starts == 1 && !driver.appended.isEmpty }
    let prepared = store.queue.entries[1]
    let stops = driver.stops
    driver.acceptsPlaybackReplacement = true
    store.select(prepared.id)
    XCTAssertEqual(driver.stops, stops)
    XCTAssertEqual(driver.replacements.last?.target, prepared)
    XCTAssertEqual(driver.replacements.last?.authority.library, prepared.libraryID)
    XCTAssertEqual(store.current?.id, prepared.id)
    store.pause()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(driver.starts, 1, "Pause cancels the replacement source before it can start")
    XCTAssertFalse(store.playbackRequested)
    let unprepared = store.queue.entries[2]
    store.select(unprepared.id)
    XCTAssertEqual(driver.stops, stops, "Authorized cold queue target shares the pending lane")
    store.pause()
    await store.logout()
    XCTAssertGreaterThan(driver.stops, stops, "Account retirement always stops the driver")
  }
  func testPendingOriginalSeekPersistsOnlyAcceptedNativeClockAndRejectsOldOccurrence() async throws
  {
    var loadedAlbum: PlaybackSelection?
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    loadedAlbum = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(try XCTUnwrap(loadedAlbum))
    try await wait { driver.starts == 1 }
    let current = try XCTUnwrap(store.current)
    driver.onEvent?(.position(current.id, 2))
    store.seek(4)
    XCTAssertEqual(driver.lastSeek, 4)
    XCTAssertEqual(store.queue.position, 2)
    try await store.saveNow()
    let account = try XCTUnwrap(store.active?.id)
    let restored = try await storage.restore(account: account)
    XCTAssertEqual(restored?.position, 2)
    store.pause()
    XCTAssertFalse(store.playbackRequested)
    driver.onEvent?(.seekCompleted(current.id, 4, request: driver.seekRequests.last))
    XCTAssertEqual(store.queue.position, 4)
    XCTAssertFalse(store.playbackRequested)
    try await wait { (try? await storage.restore(account: account))?.position == 4 }
    store.select(store.queue.entries[1].id)
    try await wait { driver.starts == 2 }
    driver.onEvent?(.position(current.id, 9))
    driver.onEvent?(.seekCompleted(current.id, 9))
    XCTAssertEqual(store.queue.position, 0)
    await store.logout()
  }
  func testHeldSeekPresentationDoesNotReturnToOldClockAcrossRapidReverseAndPausedCompletion()
    async throws
  {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    let selection = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(selection)
    try await wait { driver.starts == 1 }
    let occurrence = try XCTUnwrap(store.current?.id)
    let account = try XCTUnwrap(store.active?.id)
    driver.onEvent?(.position(occurrence, 2))
    store.seek(8, occurrence: occurrence)
    XCTAssertEqual(driver.lastSeek, 8)
    XCTAssertEqual(store.playbackPosition, 8, "Keep the released scrub target during native work")
    XCTAssertEqual(store.queue.position, 2, "A target is not an accepted native clock")
    await Task.yield()
    XCTAssertEqual(
      store.playbackPosition, 8, "An asynchronous handoff must not flash the old clock")
    let superseded = try XCTUnwrap(driver.seekRequests.last)
    store.seek(4, occurrence: occurrence)
    driver.onEvent?(.seekCompleted(occurrence, 8, request: superseded))
    driver.onEvent?(.seekCancelled(occurrence, request: superseded))
    XCTAssertEqual(store.queue.position, 2, "Retired request callbacks cannot accept an old target")
    XCTAssertEqual(store.playbackPosition, 4, "A reverse seek supersedes the pending target")
    try await store.saveNow()
    let checkpoint = try await storage.restore(account: account)
    XCTAssertEqual(checkpoint?.position, 2, "Pending UI intent never enters the saved clock")
    store.pause()
    XCTAssertEqual(store.playbackPosition, 4, "Pause does not cancel a valid native seek")
    driver.onEvent?(.seekCompleted(occurrence, 4.02, request: driver.seekRequests.last))
    XCTAssertEqual(store.playbackPosition, 4.02, accuracy: 0.0001)
    XCTAssertEqual(store.queue.position, 4.02, accuracy: 0.0001)
    XCTAssertFalse(store.playbackRequested)
    driver.onEvent?(.position(occurrence, 4.25))
    XCTAssertEqual(store.playbackPosition, 4.25, accuracy: 0.0001)
    driver.onEvent?(.seekCompleted(occurrence, 4.02, request: driver.seekRequests.last))
    XCTAssertEqual(
      store.playbackPosition, 4.25, "A duplicate acknowledgment cannot rewind progress")
    await store.logout()
  }
  func testFailedSeekAndReplacementRetirePresentationWithoutAcceptingTarget() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    let selection = try await acceptedAlbumSelection(store, album: .fixtureAlbum)
    store.playSelection(selection)
    try await wait { driver.starts == 1 }
    let occurrence = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.position(occurrence, 2))
    store.seek(8)
    XCTAssertEqual(store.playbackPosition, 8)
    driver.stop()
    driver.onEvent?(
      .failureDetails(
        occurrence,
        ConnectionStepError(step: .playbackAudio, error: PlaybackProblem.seek)))
    XCTAssertEqual(store.playbackPosition, 2, "Failed seek returns to the last accepted clock")
    XCTAssertEqual(store.queue.position, 2)
    store.play()
    try await wait { driver.starts == 2 }
    store.seek(6)
    let cancelled = try XCTUnwrap(driver.seekRequests.last)
    store.pause()
    driver.onEvent?(.seekCancelled(occurrence, request: cancelled))
    driver.onEvent?(.seekCompleted(occurrence, 6, request: cancelled))
    XCTAssertEqual(store.playbackPosition, 2, "Cancelled paused seek never accepts its target")
    store.play()
    store.seek(7)
    XCTAssertEqual(store.playbackPosition, 7)
    store.select(store.queue.entries[1].id)
    try await wait { driver.starts == 3 }
    XCTAssertEqual(store.playbackPosition, 0)
    driver.onEvent?(.seekCompleted(occurrence, 7))
    XCTAssertEqual(
      store.playbackPosition, 0, "Retired occurrence cannot restore pending presentation")
    await store.logout()
    driver.onEvent?(.seekCompleted(occurrence, 8))
    XCTAssertEqual(store.playbackPosition, store.queue.position)
  }

  func testPlayReplacingPausedPendingSeekRevokesItsPresentationAndAcknowledgments() async throws {
    let (directory, storage, vault, driver) = try context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: ControlledCatalog())
    store.playSelection(try await acceptedAlbumSelection(store, album: .fixtureAlbum))
    try await wait { driver.starts == 1 }
    let occurrence = try XCTUnwrap(store.current?.id)
    driver.onEvent?(.position(occurrence, 2))
    store.seek(8)
    let retired = try XCTUnwrap(driver.seekRequests.last)
    store.pause()
    driver.resumeAllowed = false
    driver.acceptsPlaybackReplacement = true
    store.play()
    XCTAssertEqual(driver.replacements.last?.position, 2)
    XCTAssertEqual(store.playbackPosition, 2, "New source intent supersedes the old native seek")
    try await wait { driver.starts == 2 }
    driver.onEvent?(.position(occurrence, 2.5))
    XCTAssertEqual(store.playbackPosition, 2.5)
    driver.onEvent?(.seekCompleted(occurrence, 8, request: retired))
    driver.onEvent?(.seekCancelled(occurrence, request: retired))
    XCTAssertEqual(store.playbackPosition, 2.5)
    XCTAssertEqual(
      store.queue.position, 2.5, "Same occurrence is insufficient authority for an old seek")
    await store.logout()
  }

}
