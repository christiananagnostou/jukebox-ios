#if MEASURE_ACCOUNT_STARTUP
  import XCTest

  @testable import JukeboxCore

  private actor LaunchTimingCatalog: MusicCatalogServing {
    func verifyIdentity() async throws { try await Task.sleep(for: .milliseconds(40)) }
    func validate(ids: [String]) async throws -> [MusicItem] {
      try await Task.sleep(for: .milliseconds(100))
      return MusicItem.fixtureTracks.filter { ids.contains($0.id) }
    }
    func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
      try await Task.sleep(for: .milliseconds(20))
      return [.init(id: "fixture-music", title: "Music")]
    }
    func catalog(_ query: CatalogQuery) async throws -> [MusicItem] { [] }
    func albumTracks(library: String, album: String) async throws -> [MusicItem] { [] }
    func artwork(item: MusicItem) async throws -> Data? { nil }
    func media(
      library: String, trackID: String, quality: StreamQuality,
      isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> MediaSource { throw ClientError.unavailable }
  }

  final class AccountStartupTimingTests: XCTestCase {
    @MainActor func testTimeToHomeWithAndWithoutASavedQueue() async throws {
      let account = Connection(
        server: try ServerAddress("https://invented.invalid"), userID: "listener",
        username: "Example")
      for index in 0..<48 {
        let storage = LibraryStorage()
        try await storage.saveConnections([account])
        let count = index.isMultiple(of: 2) ? 0 : 40
        let entries = (0..<count).map {
          QueueEntry(MusicItem.fixtureTracks[$0 % 4], libraryID: "fixture-music")
        }
        try await storage.save(QueueState(entries: entries), account: account.id)
        let store = PlayerStore(
          storage: storage, vault: ImmediateVault(), driver: DriverSpy(), deviceID: "sample",
          factory: { _, _ in LaunchTimingCatalog() })
        let start = ProcessInfo.processInfo.systemUptime
        let restoration = Task { await store.bootstrap() }
        while store.browser == nil && ProcessInfo.processInfo.systemUptime - start < 2 {
          try await Task.sleep(for: .milliseconds(1))
        }
        let browser = try XCTUnwrap(store.browser)
        let shell = ProcessInfo.processInfo.systemUptime - start
        await browser.start()
        let usable = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(browser.authorizedLibrary, "fixture-music")
        await restoration.value
        XCTAssertEqual(store.queue.entries.count, count)
        print("LAUNCH_SAMPLE \(index) \(count) \(shell*1000) \(usable*1000)")
      }
    }
  }
#endif
