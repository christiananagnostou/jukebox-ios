import XCTest

@testable import JukeboxCore

private actor StartupQueueCatalog: MusicCatalogServing {
  private var continuation: CheckedContinuation<Void, Error>?
  private var holdValidation = true
  private(set) var rootRequests = 0
  var waiting: Bool { continuation != nil }

  func release(_ failure: ClientError? = nil) {
    holdValidation = false
    if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume() }
    continuation = nil
  }

  func verifyIdentity() {}
  func musicLibraries(refresh: Bool) -> [MusicLibrary] {
    rootRequests += 1
    return [.init(id: "fixture-music", title: "Music")]
  }
  func validate(ids: [String]) async throws -> [MusicItem] {
    if holdValidation { try await withCheckedThrowingContinuation { continuation = $0 } }
    return MusicItem.fixtureTracks.filter { ids.contains($0.id) }
  }
  func catalog(_ query: CatalogQuery) -> [MusicItem] { [] }
  func albumTracks(library: String, album: String) -> [MusicItem] { MusicItem.fixtureTracks }
  func artwork(item: MusicItem) -> Data? { nil }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    guard await isCurrent() else { throw CancellationError() }
    return MediaSource(url: URL(string: "https://fixture.invalid/song")!, quality: quality)
  }
}

private actor LockedVault: TokenVault {
  private var locked = true
  func unlock() { locked = false }
  func read(account: String) throws -> String? {
    if locked { throw ClientError.secureStorage }
    return "fixture-token"
  }
  func write(_ token: String, account: String) { XCTFail("Unexpected credential write") }
  func erase(account: String) { XCTFail("Unexpected credential removal") }
}

@MainActor final class AccountStartupTests: XCTestCase {
  private var account: Connection {
    get throws {
      Connection(
        server: try ServerAddress("https://fixture.invalid"), userID: "one", username: "Listener")
    }
  }

  private func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { throw WaitError.elapsed }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
  private enum WaitError: Error { case elapsed }

  private func savedStore(_ wire: ScriptedHTTP) async throws -> (
    PlayerStore, MemoryVault, LibraryStorage
  ) {
    let connection = try account
    let storage = LibraryStorage()
    try await storage.saveConnections([connection])
    let vault = MemoryVault()
    await vault.write("fixture-token", account: connection.id)
    let store = PlayerStore(
      storage: storage, vault: vault, driver: DriverSpy(), deviceID: "test",
      factory: {
        try JellyfinClient(connection: $0, token: $1, deviceID: "test", transport: wire)
      })
    return (store, vault, storage)
  }

  func testReturningAccountNeverEntersSignInWhileIdentityIsPending() async throws {
    let connection = try account
    let wire = ScriptedHTTP([(200, ["Id": connection.userID])])
    await wire.holdNext("Me")
    let (store, _, _) = try await savedStore(wire)
    guard case .opening = store.session else { return XCTFail("Expected startup") }
    let launch = Task { await store.bootstrap() }
    try await waitUntil { await wire.waiting }
    guard case .reconnecting(let saved) = store.session else {
      return XCTFail("Expected reconnecting")
    }
    XCTAssertEqual(saved, connection)
    XCTAssertNil(store.browser)
    await store.bootstrap()
    await wire.release()
    await launch.value
    guard case .signedIn(let active, _) = store.session else { return XCTFail("Expected Home") }
    XCTAssertEqual(active, connection)
    let paths = await wire.paths
    XCTAssertEqual(paths.count, 1)
  }

  func testFirstLaunchAndExplicitSignOutShowSignIn() async throws {
    let empty = PlayerStore(
      storage: LibraryStorage(), vault: MemoryVault(), driver: DriverSpy(), deviceID: "test")
    await empty.bootstrap()
    guard case .signedOut(nil) = empty.session else { return XCTFail("Expected new account entry") }
    let connection = try account
    let wire = ScriptedHTTP([(200, ["Id": connection.userID]), (204, [:])])
    let (store, _, storage) = try await savedStore(wire)
    await store.bootstrap()
    await store.logout()
    guard case .signedOut(nil) = store.session else { return XCTFail("Expected signed out") }
    let saved = try await storage.connections()
    XCTAssertEqual(saved, [])
  }

  func testTransientOrMalformedIdentityRetainsAccountAndRetries() async throws {
    let connection = try account
    for first in [(503, [String: String]()), (200, ["Name": "Listener"]), (200, ["Id": " "])] {
      let wire = ScriptedHTTP([first, (200, ["Id": connection.userID])])
      let (store, vault, storage) = try await savedStore(wire)
      await store.bootstrap()
      guard case .recovery(.reconnect(let saved, let problem)) = store.session else {
        return XCTFail("Expected retry")
      }
      XCTAssertEqual(saved, connection)
      XCTAssertEqual(problem.step, .identity)
      let token = await vault.read(account: connection.id)
      let accounts = try await storage.connections()
      XCTAssertNotNil(token)
      XCTAssertEqual(accounts, [connection])
      XCTAssertNil(store.browser)
      await store.retryAccountStartup()
      XCTAssertEqual(store.active, connection)
    }
  }

  func testExpiredOrMismatchedIdentityRequiresUserSignIn() async throws {
    let connection = try account
    for first in [(401, [String: String]()), (200, ["Id": "another-user"])] {
      let (store, vault, _) = try await savedStore(ScriptedHTTP([first]))
      await store.bootstrap()
      guard case .recovery(.expired(let expired)) = store.session else {
        return XCTFail("Expected expired session")
      }
      XCTAssertEqual(expired, connection)
      let token = await vault.read(account: connection.id)
      XCTAssertNil(token)
      await store.retryAccountStartup()
      guard case .signedOut(let suggestion) = store.session else {
        return XCTFail("Expected sign-in")
      }
      XCTAssertEqual(suggestion, connection)
    }
  }

  func testAbandonedReconnectCannotRemoveSavedAccountOnLateUnauthorizedReply() async throws {
    let connection = try account
    let wire = ScriptedHTTP([(401, [:])])
    await wire.holdNext("Me")
    let (store, vault, storage) = try await savedStore(wire)
    let launch = Task { await store.bootstrap() }
    try await waitUntil { await wire.waiting }
    store.addConnection()
    await wire.release()
    await launch.value
    guard case .signedOut(nil) = store.session else { return XCTFail("Expected requested sign-in") }
    let token = await vault.read(account: connection.id)
    let accounts = try await storage.connections()
    XCTAssertNotNil(token)
    XCTAssertEqual(accounts, [connection])
  }

  func testUnreadableSavedAccountsRetryInPlaceWithoutOverwriting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let disk = try LibraryStorage(directory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("connections.json")
    let invalid = Data("broken".utf8)
    try invalid.write(to: url)
    let store = PlayerStore(
      storage: disk, vault: ImmediateVault(), driver: DriverSpy(), deviceID: "test",
      factory: { _, _ in ImmediateCatalog() })
    await store.bootstrap()
    guard case .recovery(.savedAccounts) = store.session else {
      return XCTFail("Expected storage recovery")
    }
    XCTAssertEqual(try Data(contentsOf: url), invalid)
    let account = try account
    try await disk.saveConnections([account])
    await store.retryAccountStartup()
    XCTAssertEqual(store.active, account)
  }

  func testLockedKeychainWaitsForRetryWithoutRemovingTheAccount() async throws {
    let account = try account
    let storage = LibraryStorage()
    try await storage.saveConnections([account])
    let vault = LockedVault()
    let store = PlayerStore(
      storage: storage, vault: vault, driver: DriverSpy(), deviceID: "test",
      factory: { _, _ in ImmediateCatalog() })
    await store.bootstrap()
    guard case .recovery(.reconnect(let saved, let failure)) = store.session else {
      return XCTFail("Expected Keychain retry")
    }
    XCTAssertEqual(saved, account)
    XCTAssertEqual(failure.step, .secureStorage)
    let accounts = try await storage.connections()
    XCTAssertEqual(accounts, [account])
    await vault.unlock()
    await store.retryAccountStartup()
    XCTAssertEqual(store.active, account)
  }

  func testInsecureSavedAddressPromptsForHTTPSBeforeReadingCredential() async throws {
    let legacy = Connection(
      server: try ServerAddress("http://fixture.invalid/music"), userID: "old", username: "Listener"
    )
    let storage = LibraryStorage()
    try await storage.saveConnections([legacy])
    let store = PlayerStore(
      storage: storage, vault: MemoryVault(), driver: DriverSpy(), deviceID: "test",
      factory: { _, _ in
        XCTFail("Unexpected request")
        return ImmediateCatalog()
      })
    await store.bootstrap()
    guard case .recovery(.requiresHTTPS(let saved)) = store.session else {
      return XCTFail("Expected HTTPS recovery")
    }
    XCTAssertEqual(saved, legacy)
    await store.retryAccountStartup()
    guard case .signedOut(let suggested) = store.session else {
      return XCTFail("Expected address entry")
    }
    XCTAssertEqual(suggested, legacy)
  }

  func testHomeOpensWhileQueueIsHeldAndPreservesOrSupersedesItsCheckpoint() async throws {
    let account = try account
    for replace in [false, true] {
      let storage = LibraryStorage()
      let catalog = StartupQueueCatalog()
      let entries = [1, 0, 1].map {
        QueueEntry(MusicItem.fixtureTracks[$0], libraryID: "fixture-music")
      }
      let saved = QueueState(entries: entries, index: 2, position: 18.5, quality: .high)
      try await storage.saveConnections([account])
      try await storage.save(saved, account: account.id)
      let store = PlayerStore(
        storage: storage, vault: ImmediateVault(), driver: DriverSpy(), deviceID: "test",
        factory: { _, _ in catalog })
      let launch = Task { await store.bootstrap() }
      try await waitUntil { await catalog.waiting }
      let browser = try XCTUnwrap(store.browser)
      await browser.start()
      XCTAssertEqual(browser.authorizedLibrary, "fixture-music")
      XCTAssertNil(store.current)
      XCTAssertTrue(store.hasRemainingQueue)
      try await store.saveNow()
      let checkpoint = try await storage.restore(account: account.id)
      XCTAssertEqual(checkpoint, saved)
      if replace {
        let selection = try XCTUnwrap(
          store.playbackSelection([MusicItem.fixtureTracks[2]], library: "fixture-music"))
        store.toggleSelection(selection)
      }
      await catalog.release()
      await launch.value
      if replace {
        XCTAssertEqual(store.queue.entries.map(\.track.id), [MusicItem.fixtureTracks[2].id])
      } else {
        XCTAssertEqual(store.queue, saved)
      }
      let rootRequests = await catalog.rootRequests
      XCTAssertEqual(rootRequests, 1)
    }
  }

  func testSavedQueueFailureLeavesHomeUsableAndRetryRestoresPosition() async throws {
    let account = try account
    let storage = LibraryStorage()
    let catalog = StartupQueueCatalog()
    let saved = QueueState(entries: [QueueEntry(MusicItem.fixtureTracks[0])], position: 8)
    try await storage.saveConnections([account])
    try await storage.save(saved, account: account.id)
    let store = PlayerStore(
      storage: storage, vault: ImmediateVault(), driver: DriverSpy(), deviceID: "test",
      factory: { _, _ in catalog })
    let launch = Task { await store.bootstrap() }
    try await waitUntil { await catalog.waiting }
    await catalog.release(.unavailable)
    await launch.value
    XCTAssertEqual(store.active, account)
    XCTAssertTrue(store.queueRestoreFailed)
    XCTAssertNil(store.current)
    store.retryQueueRestoration()
    try await waitUntil { !store.hasRemainingQueue }
    XCTAssertEqual(store.queue, saved)
  }
}
