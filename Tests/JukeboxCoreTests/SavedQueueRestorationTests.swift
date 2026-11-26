import XCTest

@testable import JukeboxCore

private actor RestoringCatalog: MusicCatalogServing {
  let tracks: [String: MusicItem]
  private var blocked: Bool
  private var failure: ClientError?
  private var waiting: CheckedContinuation<Void, Never>?
  private(set) var batches: [[String]] = []

  init(_ entries: [QueueEntry], excluding: Set<String> = [], block: Bool = false) {
    tracks = Dictionary(
      entries.filter { !excluding.contains($0.track.id) }.map { ($0.track.id, $0.track) },
      uniquingKeysWith: { first, _ in first })
    blocked = block
  }
  var isWaiting: Bool { waiting != nil }
  func release(_ error: ClientError? = nil) {
    failure = error
    blocked = false
    waiting?.resume()
    waiting = nil
  }
  func verifyIdentity() {}
  func musicLibraries(refresh: Bool) -> [MusicLibrary] {
    [.init(id: "fixture-music", title: "Invented")]
  }
  func validate(ids: [String]) async throws -> [MusicItem] {
    batches.append(ids)
    if ids.count > 40 && blocked { await withCheckedContinuation { waiting = $0 } }
    if let error = failure {
      failure = nil
      throw error
    }
    return Set(ids).sorted().compactMap { tracks[$0] }
  }
  func catalog(_ query: CatalogQuery) -> [MusicItem] { [] }
  func albumTracks(library: String, album: String) -> [MusicItem] { [] }
  func artwork(item: MusicItem) -> Data? { nil }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    guard tracks[trackID] != nil, await isCurrent() else { throw ClientError.forbidden }
    return MediaSource(url: URL(string: "https://invented.invalid/audio")!, quality: quality)
  }
}

extension StoreTests {
  func testDiskQueueProgressSurvivesUnpreparedNextTicksSeekAndFreshStore() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try LibraryStorage(directory: directory)
    let connection = Connection(
      server: try ServerAddress("https://invented.invalid"), userID: "one", username: "One")
    let saved = savedQueue(count: 7_790, cursor: 4_001)
    let catalog = RestoringCatalog(saved.entries)
    let file = directory.appendingPathComponent(connection.id + ".json")
    try await storage.saveConnections([connection])
    try await storage.save(saved, account: connection.id)
    let firstSnapshot = try Data(contentsOf: file)
    let driver = DriverSpy()
    let store = PlayerStore(
      storage: storage, vault: ImmediateVault(), driver: driver, deviceID: "fixture",
      factory: { _, _ in catalog })
    await store.bootstrap()
    try await wait { store.current != nil && !store.hasRemainingQueue }
    store.next()
    let repeatID = try XCTUnwrap(saved.successor?.id)
    try await wait { store.playing && driver.current == repeatID }
    XCTAssertNotEqual(repeatID, saved.current?.id)
    driver.onEvent?(.position(repeatID, 15.5))
    driver.sampledPausePosition = 16.25
    store.pause()
    store.seek(47.25)
    try await store.saveNow()
    XCTAssertEqual(try Data(contentsOf: file), firstSnapshot)
    let freshDriver = DriverSpy()
    let reopened = PlayerStore(
      storage: try LibraryStorage(directory: directory), vault: ImmediateVault(),
      driver: freshDriver, deviceID: "fixture", factory: { _, _ in catalog })
    await reopened.bootstrap()
    try await wait { reopened.current != nil && !reopened.hasRemainingQueue }
    XCTAssertEqual(reopened.queue.entries, saved.entries)
    XCTAssertEqual(reopened.queue.index, saved.index + 1)
    XCTAssertEqual(reopened.current?.id, repeatID)
    XCTAssertEqual(reopened.queue.position, 47.25)
    XCTAssertEqual(reopened.phase, .paused)
    reopened.play()
    try await wait { reopened.playing }
    XCTAssertEqual(freshDriver.current, repeatID)
    XCTAssertEqual(freshDriver.startedPositions, [47.25])
  }

  private func savedQueue(count: Int = 140, cursor: Int = 68) -> QueueState {
    var entries = (0..<count).map { index in
      QueueEntry(
        MusicItem(
          id: "saved-\(index)", title: "Song \(index)", artist: "Fixture", album: "Fixture",
          duration: 90, number: index + 1, kind: "Audio", imageID: nil, imageTag: nil),
        libraryID: "fixture-music")
    }
    entries[cursor + 1] = QueueEntry(entries[cursor].track, libraryID: "fixture-music")
    var state = QueueState(entries: entries, index: cursor, position: 12.25, quality: .high)
    state.playlistID = "fixture-playlist"
    return state
  }

  private func restoredStore(_ state: QueueState, catalog: RestoringCatalog) async throws
    -> (PlayerStore, DriverSpy, LibraryStorage, Connection)
  {
    let storage = LibraryStorage()
    let connection = Connection(
      server: try ServerAddress("https://invented.invalid"), userID: "one", username: "One")
    try await storage.saveConnections([connection])
    try await storage.save(state, account: connection.id)
    let driver = DriverSpy()
    let store = PlayerStore(
      storage: storage, vault: ImmediateVault(), driver: driver, deviceID: "fixture",
      factory: { _, _ in catalog })
    await store.bootstrap()
    return (store, driver, storage, connection)
  }

  func testSavedQueuePlaysAndAdvancesToRepeatedOccurrenceBeforeFullValidation() async throws {
    let saved = savedQueue(count: 7_790, cursor: 4_001)
    let catalog = RestoringCatalog(saved.entries, block: true)
    let (store, driver, storage, account) = try await restoredStore(saved, catalog: catalog)
    try await wait { await catalog.isWaiting }
    XCTAssertTrue(store.hasRemainingQueue)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertEqual(driver.starts, 0)
    XCTAssertEqual(store.current?.id, saved.current?.id)
    XCTAssertEqual(store.queue.position, 12.25)
    XCTAssertLessThanOrEqual(store.queue.entries.count, 40)
    let calls = await catalog.batches
    XCTAssertEqual(calls.count, 2)
    XCTAssertLessThanOrEqual(calls[0].count, 40)
    XCTAssertTrue(Set(calls[0]).isDisjoint(with: calls[1]))
    store.play()
    try await wait { store.playing }
    XCTAssertEqual(driver.startedPositions, [12.25])
    store.next()
    try await wait { store.playing && driver.current == saved.successor?.id }
    XCTAssertEqual(store.current?.track.id, saved.current?.track.id)
    XCTAssertNotEqual(store.current?.id, saved.current?.id)
    driver.sampledPausePosition = 3.5
    store.pause()
    try await store.saveNow()
    var expected = saved
    expected.index += 1
    expected.position = 3.5
    let persisted = try await storage.restore(account: account.id)
    XCTAssertEqual(persisted, expected)
    let starts = driver.starts
    await catalog.release()
    try await wait { !store.hasRemainingQueue }
    XCTAssertEqual(store.queue, expected)
    XCTAssertEqual(driver.starts, starts)
    XCTAssertEqual(store.phase, .paused)
  }

  func testSavedQueueMissingCurrentAndDeniedRepeatsUseFirstSurvivingEntry() async throws {
    let saved = savedQueue()
    let missing = try XCTUnwrap(saved.current?.track.id)
    let banned: Set = [missing, saved.entries[0].track.id]
    let catalog = RestoringCatalog(saved.entries, excluding: banned)
    let (store, driver, _, _) = try await restoredStore(saved, catalog: catalog)
    XCTAssertFalse(store.hasRemainingQueue)
    XCTAssertEqual(store.queue.entries, saved.entries.filter { !banned.contains($0.track.id) })
    XCTAssertEqual(store.current?.id, saved.entries[1].id)
    XCTAssertEqual(store.queue.position, 0)
    XCTAssertEqual(driver.starts, 0)
  }

  func testSavedQueueOfOnlyRepeatsRestoresAllOccurrencesInOneRequest() async throws {
    let entries = (0..<100).map { _ in
      QueueEntry(MusicItem.fixtureTracks[0], libraryID: "fixture-music")
    }
    let saved = QueueState(entries: entries, index: 72, position: 2.5)
    let catalog = RestoringCatalog(entries)
    let result = try await saved.restoredForPlayback(using: catalog)
    XCTAssertEqual(result.ready, saved)
    XCTAssertNil(result.remainder)
    let calls = await catalog.batches
    XCTAssertEqual(calls.count, 1)
  }

  func testSavedQueueRetriesTailFailureWithoutLosingPausedPositionOrQueuedEdit() async throws {
    let saved = savedQueue()
    let deleted = saved.entries[5]
    let catalog = RestoringCatalog(saved.entries, excluding: [deleted.track.id], block: true)
    let (store, driver, storage, account) = try await restoredStore(saved, catalog: catalog)
    try await wait { await catalog.isWaiting }
    let removed = saved.entries[saved.index + 1].id
    store.remove([removed])
    await catalog.release(.unavailable)
    try await wait { store.queueRestoreFailed }
    XCTAssertEqual(store.current?.id, saved.current?.id)
    try await store.saveNow()
    let persisted = try await storage.restore(account: account.id)
    XCTAssertEqual(persisted, saved)
    store.retryQueueRestoration()
    try await wait { !store.hasRemainingQueue }
    XCTAssertEqual(
      store.queue.entries, saved.entries.filter { $0.id != removed && $0.id != deleted.id })
    XCTAssertEqual(store.current?.id, saved.current?.id)
    XCTAssertEqual(store.queue.position, 12.25)
    XCTAssertEqual(driver.starts, 0)
  }

  func testSavedQueueLateResponseCannotOverwriteAnotherAccountOrReplacementQueue() async throws {
    for switchAccount in [true, false] {
      let saved = savedQueue()
      let catalog = RestoringCatalog(saved.entries, block: true)
      let (store, _, storage, account) = try await restoredStore(saved, catalog: catalog)
      try await wait { await catalog.isWaiting }
      if switchAccount {
        let other = Connection(server: account.server, userID: "two", username: "Two")
        await store.activate(other)
        XCTAssertEqual(store.active, other)
        let persisted = try await storage.restore(account: account.id)
        XCTAssertEqual(persisted, saved)
      } else {
        await store.browser?.start()
        store.playItems([saved.entries[0].track], library: "fixture-music")
        try await wait { store.playing }
      }
      XCTAssertFalse(store.hasRemainingQueue)
      await catalog.release()
      await Task.yield()
      XCTAssertEqual(
        store.queue.entries.map(\.track.id), switchAccount ? [] : [saved.entries[0].track.id])
    }
  }

  func testSavedQueueNaturalEndAtReadyBoundaryHonorsPauseAndContinuesOnlyOnce() async throws {
    for pause in [false, true] {
      let saved = savedQueue()
      let catalog = RestoringCatalog(saved.entries, block: true)
      let (store, driver, _, _) = try await restoredStore(saved, catalog: catalog)
      try await wait { await catalog.isWaiting }
      let edge = try XCTUnwrap(store.queue.entries.last)
      let index = try XCTUnwrap(saved.entries.firstIndex { $0.id == edge.id })
      store.select(edge.id)
      try await wait { store.playing }
      driver.finishCurrent()
      XCTAssertEqual(store.phase, .paused)
      if pause { store.pause() }
      await catalog.release()
      try await wait { !store.hasRemainingQueue && (pause || store.playing) }
      XCTAssertEqual(store.current?.id, pause ? edge.id : saved.entries[index + 1].id)
      XCTAssertEqual(driver.starts, pause ? 1 : 2)
    }
  }

  func testSavedQueueTailCannotRestoreRevokedLibraryOccurrences() async throws {
    var saved = savedQueue()
    for index in [2, saved.index + 2, saved.entries.count - 1] {
      let entry = saved.entries[index]
      saved.entries[index] = QueueEntry(entry.track, id: entry.id, libraryID: "removed-root")
    }
    let catalog = RestoringCatalog(saved.entries, block: true)
    let (store, _, storage, account) = try await restoredStore(saved, catalog: catalog)
    try await wait { await catalog.isWaiting }
    store.browser?.librariesRevoked?(["removed-root"])
    await catalog.release()
    try await wait { !store.hasRemainingQueue }
    XCTAssertEqual(store.queue.entries, saved.entries.filter { $0.libraryID != "removed-root" })
    XCTAssertEqual(store.current?.id, saved.current?.id)
    XCTAssertEqual(store.queue.position, saved.position)
    try await store.saveNow()
    let persisted = try await storage.restore(account: account.id)
    XCTAssertEqual(persisted, store.queue)
  }
}
