import XCTest

@testable import JukeboxCore

private actor RecentCatalog: MusicCatalogServing {
  let fixture = FixtureCatalog(source: URL(string: "https://invented.invalid/audio")!)
  private var hold = false
  private var waiter: CheckedContinuation<[MusicItem], Never>?
  private var held: [MusicItem] = []
  private(set) var queries: [CatalogQuery] = []
  private(set) var artistIDs: [String] = []
  var waiting: Bool { waiter != nil }
  func holdNextIDs() { hold = true }
  func release() {
    waiter?.resume(returning: held)
    waiter = nil
  }
  func verifyIdentity() async throws {}
  func validate(ids: [String]) async throws -> [MusicItem] { try await fixture.validate(ids: ids) }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    try await fixture.media(
      library: library, trackID: trackID, quality: quality, isCurrent: isCurrent)
  }
  func artwork(item: MusicItem) async throws -> Data? { nil }
  func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
    try await fixture.musicLibraries(refresh: refresh)
  }
  func albumTracks(library: String, album: String) async throws -> [MusicItem] {
    try await fixture.albumTracks(library: library, album: album)
  }
  func artistDetail(library: String, artist: MusicItem) async throws -> MusicItem {
    artistIDs.append(artist.id)
    return try await fixture.artistDetail(library: library, artist: artist)
  }
  func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
    queries.append(query)
    let rows = try await fixture.catalog(query)
    if hold && !query.ids.isEmpty {
      hold = false
      held = rows
      return await withCheckedContinuation { waiter = $0 }
    }
    return rows
  }
}

private actor RecentArtistHTTP: HTTPTransport {
  private(set) var albumArtistCalls = 0
  private(set) var trackArtistCalls = 0
  private(set) var proofs: [String] = []
  private(set) var ownReads: [String] = []
  func send(_ request: URLRequest) throws -> HTTPReply {
    let url = try XCTUnwrap(request.url)
    let query = Dictionary(
      (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    let object: [String: Any]
    switch url.lastPathComponent {
    case "UserViews":
      object = [
        "Items": [
          [
            "Id": "music", "Name": "Invented", "Type": "CollectionFolder",
            "CollectionType": "music",
          ]
        ]
      ]
    case "Artists":
      guard query["ParentId"] == "music", query["IncludeItemTypes"] == "Audio" else {
        throw ClientError.invalidResponse
      }
      trackArtistCalls += 1
      object = ["Items": []]
    case "AlbumArtists":
      albumArtistCalls += 1
      object = [
        "Items": (0..<40).map {
          ["Id": "artist-\($0)", "Name": "First forty", "Type": "MusicArtist"]
        }
      ]
    case "Items":
      if let artist = query["ArtistIds"] {
        guard query["ParentId"] == "music", query["IncludeItemTypes"] == "Audio",
          query["Limit"] == "1"
        else { throw ClientError.invalidResponse }
        proofs.append(artist)
        object = [
          "Items": artist == "artist-99"
            ? [
              [
                "Id": "authorized-song", "Type": "Audio",
                "ArtistItems": [["Id": artist, "Name": "Beyond first forty"]],
              ]
            ] : []
        ]
      } else {
        object = ["Items": []]
      }
    case "artist-99":
      guard proofs.contains("artist-99") else { throw ClientError.invalidResponse }
      ownReads.append("artist-99")
      object = [
        "Id": "artist-99", "Name": "Beyond first forty", "Type": "MusicArtist",
        "ImageTags": ["Primary": "own-portrait"],
      ]
    default: throw ClientError.invalidResponse
    }
    return HTTPReply(data: try JSONSerialization.data(withJSONObject: object), status: 200)
  }
}

@MainActor final class SearchRecentTests: XCTestCase {
  private func settle(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { throw ClientError.unavailable }
      try await Task.sleep(for: .milliseconds(2))
    }
  }
  func testDiskHistoryIsBoundedScopedOrderedPrivateAndLeaseOwned() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let account = String(repeating: "a", count: 64)
    let other = String(repeating: "b", count: 64)
    let storage = try LibraryStorage(directory: directory)
    let lease = await storage.lease(account: account)
    for index in 0..<24 {
      let value = try XCTUnwrap(
        RecentSearchIdentity(library: "music", category: .albums, id: "a-\(index)"))
      try await storage.changeSearchRecent(
        value, removing: false, account: account, lease: lease,
        revision: UInt64(index + 1))
    }
    let selected = try XCTUnwrap(
      RecentSearchIdentity(library: "music", category: .albums, id: "a-9"))
    try await storage.changeSearchRecent(
      selected, removing: false, account: account, lease: lease, revision: 25)
    let live = try XCTUnwrap(RecentSearchIdentity(library: "live", category: .artists, id: "a-9"))
    try await storage.changeSearchRecent(
      live, removing: false, account: account, lease: lease, revision: 26)
    let path = directory.appendingPathComponent(account + ".search-recents.json")
    let data = try Data(contentsOf: path)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: String]])
    XCTAssertEqual(object.count, 20)
    XCTAssertTrue(object.allSatisfy { Set($0.keys) == ["library", "category", "id"] })
    let reopened = try LibraryStorage(directory: directory)
    let newLease = await reopened.lease(account: account)
    let rows = try await reopened.searchRecents(account: account, lease: newLease, library: "music")
    XCTAssertEqual(rows.first, selected)
    XCTAssertEqual(rows.count, 19)
    let liveRows = try await reopened.searchRecents(
      account: account, lease: newLease, library: "live")
    XCTAssertEqual(liveRows, [live])
    let otherLease = await reopened.lease(account: other)
    let isolated = try await reopened.searchRecents(
      account: other, lease: otherLease, library: "music")
    XCTAssertTrue(isolated.isEmpty)
    try await reopened.changeSearchRecent(
      selected, removing: true, account: account, lease: newLease, revision: 2)
    try await reopened.changeSearchRecent(
      selected, removing: false, account: account, lease: newLease, revision: 1)
    let deleted = try await reopened.searchRecents(
      account: account, lease: newLease, library: "music")
    XCTAssertFalse(deleted.contains(selected), "A stale save cannot undo removal")
    try await reopened.retire(account: account, erase: true)
    try await reopened.changeSearchRecent(
      selected, removing: false, account: account, lease: newLease, revision: 3)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    XCTAssertNil(
      RecentSearchIdentity(
        library: "music", category: .songs, id: "https://private.invalid?token=secret"))
    XCTAssertNil(RecentSearchIdentity(library: "../private", category: .songs, id: "audio"))
  }
  func testHistoryRejectsMalformedOversizedAndLinkedPayloads() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try LibraryStorage(directory: directory)
    let account = String(repeating: "c", count: 64)
    let lease = await storage.lease(account: account)
    let path = directory.appendingPathComponent(account + ".search-recents.json")
    for bytes in [
      Data(repeating: 32, count: 8193),
      Data(#"[{"library":"music","category":"Books","id":"private"}]"#.utf8),
      Data(#"[{"library":"music","category":"Albums","id":"../private"}]"#.utf8),
    ] {
      try bytes.write(to: path)
      let rows = try await storage.searchRecents(account: account, lease: lease, library: "music")
      XCTAssertTrue(rows.isEmpty)
    }
    try FileManager.default.removeItem(at: path)
    let sentinel = directory.appendingPathComponent("invented-sentinel")
    let bytes = Data(#"[{"library":"music","category":"Albums","id":"sentinel"}]"#.utf8)
    try bytes.write(to: sentinel)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: sentinel)
    let linked = try await storage.searchRecents(account: account, lease: lease, library: "music")
    XCTAssertTrue(linked.isEmpty)
    XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
  }
  func testStoreRecordsOnlyAcceptedSearchSelectionsAndRestoresTypedRecentsWithoutPlayback()
    async throws
  {
    let context = try StoreTests().context()
    defer { try? FileManager.default.removeItem(at: context.0) }
    let store = PlayerStore(
      storage: context.1, vault: context.2, driver: context.3, deviceID: "invented")
    let api = RecentCatalog()
    await store.enterFixture(service: api)
    let parent = try XCTUnwrap(store.browser)
    await parent.start()
    let search = try XCTUnwrap(parent.searchBrowser())
    search.updateSearchText("North Window")
    try await settle { search.searchCategories.allSatisfy { search.searchWindow($0).loaded } }
    let album = try XCTUnwrap(search.searchWindow(.albums).items.first)
    let artist = try XCTUnwrap(search.searchWindow(.artists).items.first)
    let song = try XCTUnwrap(search.searchWindow(.songs).items.first)
    var actions = 0
    XCTAssertFalse(
      parent.performSearchAction(
        scope: parent.scope, library: parent.authorizedLibrary,
        query: "", item: album
      ) { actions += 1 })
    search.updateSearchText("")
    try await settle { !search.searchRecentsLoading }
    XCTAssertTrue(
      search.searchRecents.isEmpty, "Typing and ordinary browse do not record selections")
    search.updateSearchText("North Window")
    try await settle { search.searchCategories.allSatisfy { search.searchWindow($0).loaded } }
    for item in [artist, album, song, album] {
      XCTAssertTrue(
        search.performSearchAction(
          scope: search.scope, library: search.authorizedLibrary,
          query: search.normalizedSearch, item: item
        ) { actions += 1 })
    }
    XCTAssertEqual(actions, 4)
    search.updateSearchText("")
    try await settle { !search.searchRecentsLoading && search.searchRecents.count == 3 }
    XCTAssertEqual(search.searchRecents.map(\.id), [album.id, song.id, artist.id])
    search.selectSearchCategory(.artists)
    XCTAssertEqual(search.searchRecents.map(\.id), [artist.id])
    search.selectSearchCategory(nil)
    let before = await api.queries.count
    search.loadSearchRecents()
    let after = await api.queries.count
    XCTAssertEqual(before, after, "Warm entry does not hydrate again")
    search.removeSearchRecent(song, scope: search.scope, library: search.authorizedLibrary)
    XCTAssertFalse(search.searchRecents.contains(song), "Removal is immediate")
    try await settle { !search.searchRecentsLoading }
    await store.enterFixture(service: api)
    let nextParent = try XCTUnwrap(store.browser)
    await nextParent.start()
    let restored = try XCTUnwrap(nextParent.searchBrowser())
    restored.loadSearchRecents()
    try await settle { !restored.searchRecentsLoading }
    XCTAssertEqual(restored.searchRecents.map(\.id), [album.id, artist.id])
    XCTAssertFalse(store.playbackRequested)
    XCTAssertTrue(store.queue.entries.isEmpty)
    XCTAssertEqual(context.3.starts, 0)
    let queries = await api.queries.filter { !$0.ids.isEmpty }
    XCTAssertTrue(queries.allSatisfy { $0.search.isEmpty && $0.ids.count <= 20 })
    XCTAssertFalse(queries.contains { $0.category == .artists })
    let validatedArtists = await api.artistIDs
    XCTAssertEqual(validatedArtists, [artist.id])
    await store.logout()
  }
  func testArtistBeyondFirstFortyUsesExactRootProofAndOwnIDNotIgnoredListIds() async throws {
    let transport = RecentArtistHTTP()
    let api = try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://invented.invalid/base"), userID: "listener",
        username: "Invented"),
      token: "invented-token", deviceID: "test", transport: transport)
    let ignored = try await api.catalog(
      CatalogQuery(library: "music", category: .artists, ids: ["artist-99"]))
    XCTAssertEqual(ignored.count, 40)
    XCTAssertFalse(ignored.contains { $0.id == "artist-99" }, "This provider ignores Artists Ids")
    let parent = MusicBrowser(service: api)
    await parent.start()
    parent.readSearchHistory = { _ in
      [
        RecentSearchIdentity(library: "music", category: .artists, id: "artist-99")!,
        RecentSearchIdentity(library: "music", category: .artists, id: "artist-deleted")!,
      ]
    }
    let search = try XCTUnwrap(parent.searchBrowser())
    let task = try XCTUnwrap(search.loadSearchRecents())
    await task.value
    XCTAssertFalse(search.searchRecentsLoading)
    XCTAssertEqual(search.searchRecents.map(\.id), ["artist-99"])
    XCTAssertEqual(search.searchRecents.first?.title, "Beyond first forty")
    XCTAssertEqual(search.searchRecents.first?.imageID, "artist-99")
    XCTAssertEqual(search.searchRecents.first?.imageTag, "own-portrait")
    XCTAssertTrue(
      search.metadataIsCurrent, "A deleted optional recent must not retire a healthy root")
    let listCalls = await transport.albumArtistCalls
    let trackListCalls = await transport.trackArtistCalls
    let proofs = await transport.proofs
    let ownReads = await transport.ownReads
    XCTAssertEqual(listCalls, 1, "Hydration never uses the unsupported list Ids lookup")
    XCTAssertEqual(trackListCalls, 1)
    XCTAssertEqual(proofs, ["artist-99", "artist-deleted"])
    XCTAssertEqual(ownReads, ["artist-99"])
    parent.retire()
  }
  func testRetiredBeforeScheduledHydrationNeverInvokesHistoryReader() async throws {
    let parent = MusicBrowser(service: RecentCatalog())
    await parent.start()
    var reads = 0
    parent.readSearchHistory = { _ in
      reads += 1
      return []
    }
    let search = try XCTUnwrap(parent.searchBrowser())
    let task = try XCTUnwrap(search.loadSearchRecents())
    parent.retire()
    await task.value
    XCTAssertEqual(reads, 0)
    XCTAssertTrue(search.searchRecents.isEmpty)
  }
  func testHeldHydrationCannotResurrectDeletionOrCrossRootAndRejectsBeforeItemGetter() async throws
  {
    let api = RecentCatalog()
    let parent = MusicBrowser(service: api)
    await parent.start()
    let album = CatalogFixtures.album(0)
    let identity = try XCTUnwrap(
      RecentSearchIdentity(library: "fixture-music", category: .albums, id: album.id))
    var ids = [identity]
    var reads = 0
    parent.readSearchHistory = { library in
      reads += 1
      return ids.filter { $0.library == library }
    }
    parent.changeSearchHistory = { value, removing in
      ids.removeAll { $0 == value }
      if !removing { ids.insert(value, at: 0) }
    }
    let search = try XCTUnwrap(parent.searchBrowser())
    await api.holdNextIDs()
    let task = try XCTUnwrap(search.loadSearchRecents())
    do {
      try await settle { await api.waiting }
      search.removeSearchRecent(album, scope: search.scope, library: search.authorizedLibrary)
      XCTAssertTrue(search.searchRecents.isEmpty)
      try await settle { !search.searchRecentsLoading }
      await api.release()
      await task.value
      XCTAssertTrue(search.searchRecents.isEmpty)
      XCTAssertTrue(ids.isEmpty)
    } catch {
      search.retire()
      await api.release()
      await task.value
      throw error
    }
    let oldScope = search.scope
    search.selectLibrary("fixture-concerts")
    func trap() -> MusicItem {
      XCTFail("Retired action extracted a protected item")
      return album
    }
    XCTAssertFalse(
      search.performSearchAction(
        scope: oldScope, library: "fixture-music",
        query: "", item: trap()
      ) { XCTFail("Retired action ran") })
    search.loadSearchRecents()
    try await settle { !search.searchRecentsLoading }
    XCTAssertTrue(search.searchRecents.isEmpty)
    parent.retire()
    let count = reads
    search.loadSearchRecents()
    XCTAssertEqual(reads, count, "Retired owner cannot read persisted identifiers")
    XCTAssertFalse(
      search.performSearchAction(
        scope: search.scope, library: "fixture-concerts",
        query: "", item: trap()
      ) { XCTFail("Retired account action ran") })
  }
}
