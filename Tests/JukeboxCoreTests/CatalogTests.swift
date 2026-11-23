import Observation
import XCTest

@testable import JukeboxCore

@MainActor private final class RenderLifetimeProbe { var live = true }

private actor CatalogHTTP: HTTPTransport {
  var replies: [HTTPReply]
  private var respond: (@Sendable (URLRequest) -> HTTPReply)?
  private(set) var requests: [URLRequest] = []
  private var holdLyrics = false
  private var lyricWaiter: CheckedContinuation<HTTPReply, Never>?
  private var lyricReply: HTTPReply?
  var lyricsWaiting: Bool { lyricWaiter != nil }
  func holdNextLyrics() { holdLyrics = true }
  func releaseLyrics() {
    if let lyricReply { lyricWaiter?.resume(returning: lyricReply) }
    lyricReply = nil
    lyricWaiter = nil
  }
  private var holdItems = false
  private var holdRoots = false
  private var rootWaiter: CheckedContinuation<HTTPReply, Never>?
  var rootsWaiting: Bool { rootWaiter != nil }
  func holdNextRoots() { holdRoots = true }
  func releaseRoots() {
    rootWaiter?.resume(
      returning: HTTPReply(
        data: Data(
          #"{"Items":[{"Id":"music","Name":"Invented","Type":"CollectionFolder","CollectionType":"music"}]}"#
            .utf8), status: 200))
    rootWaiter = nil
  }
  private var itemWaiter: CheckedContinuation<HTTPReply, Never>?
  var itemWaiting: Bool { itemWaiter != nil }
  func holdNextItems() { holdItems = true }
  func releaseItems() {
    let reply = HTTPReply(
      data: Data(#"{"Items":[{"Id":"fixture-album","Type":"MusicAlbum"}]}"#.utf8), status: 200)
    itemWaiter?.resume(returning: reply)
    itemWaiter = nil
  }
  init(respond: @escaping @Sendable (URLRequest) -> HTTPReply) {
    replies = []
    self.respond = respond
  }
  init(_ objects: [(Int, [String: Any])]) {
    replies = objects.map {
      HTTPReply(data: try! JSONSerialization.data(withJSONObject: $0.1), status: $0.0)
    }
  }
  func send(_ request: URLRequest) async throws -> HTTPReply {
    requests.append(request)
    if holdRoots && request.url?.lastPathComponent == "UserViews" {
      holdRoots = false
      return await withCheckedContinuation { rootWaiter = $0 }
    }
    if holdItems && request.url?.lastPathComponent == "Items" {
      holdItems = false
      return await withCheckedContinuation { itemWaiter = $0 }
    }
    if let respond { return respond(request) }
    guard !replies.isEmpty else { throw ClientError.invalidResponse }
    if holdLyrics && request.url?.lastPathComponent == "Lyrics" {
      holdLyrics = false
      lyricReply = replies.removeFirst()
      return await withCheckedContinuation { lyricWaiter = $0 }
    }
    return replies.removeFirst()
  }
}
private actor SparseCatalogHTTP: HTTPTransport {
  private(set) var offsets: [Int] = []
  private let emptyFirst: Bool
  private let fullPages: Int
  private var failNext = false
  init(emptyFirst: Bool = false, fullPages: Int = 1) {
    self.emptyFirst = emptyFirst
    self.fullPages = fullPages
  }
  func failNextPage() { failNext = true }
  func send(_ request: URLRequest) throws -> HTTPReply {
    let url = request.url!
    let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
    let query = Dictionary(
      fields.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
    let object: [String: Any]
    if url.lastPathComponent == "UserViews" {
      object = [
        "Items": [
          [
            "CollectionType": "music", "Type": "CollectionFolder", "Id": "music",
            "Name": "Invented",
          ]
        ]
      ]
    } else if query["Limit"] == "12" {
      object = ["Items": []]
    } else {
      let offset = Int(query["StartIndex"] ?? "0") ?? 0
      offsets.append(offset)
      let kind =
        query["IncludeItemTypes"] == "Audio"
        ? "Audio" : (url.lastPathComponent == "AlbumArtists" ? "MusicArtist" : "MusicAlbum")
      if offset < fullPages * 40 {
        let valid: [String: Any] = [
          "Type": kind, "Id": offset == 0 ? "accepted-first" : "accepted-" + String(offset),
          "Name": "Invented",
        ]
        let skipped: [String: Any] = ["Type": "Unknown", "Id": ["getter-trap": true], "Name": []]
        object = [
          "Items": emptyFirst
            ? Array(repeating: skipped, count: 40)
            : [valid, valid] + Array(repeating: skipped, count: 38)
        ]
      } else {
        if failNext {
          failNext = false
          throw ClientError.unavailable
        }
        object = ["Items": [["Type": kind, "Id": "accepted-later", "Name": "Later"]]]
      }
    }
    return HTTPReply(data: try JSONSerialization.data(withJSONObject: object), status: 200)
  }
}
private actor PagedCatalog: MusicCatalogServing {
  private let albumTrackGate: AsyncStream<Void>?
  init(albumTrackGate: AsyncStream<Void>? = nil) { self.albumTrackGate = albumTrackGate }
  private(set) var queries: [CatalogQuery] = []
  var failure: ClientError?
  private(set) var artworkCalls = 0
  private var heldSort: CatalogSort?
  private var optionWaiters: [CheckedContinuation<Void, Never>] = []
  func holdSort(_ value: CatalogSort) { heldSort = value }
  func heldOptionCount() -> Int { optionWaiters.count }
  func releaseSort() {
    heldSort = nil
    let waiters = optionWaiters
    optionWaiters = []
    for waiter in waiters { waiter.resume() }
  }
  private var heldSearch: [String: Set<MusicCategory>] = [:]
  private var emptySearchTypes: Set<MusicCategory> = []
  func emptySearchCategories(_ values: Set<MusicCategory>) { emptySearchTypes = values }
  private(set) var detailLibraries: [String] = []
  private var exactCategory: MusicCategory?
  func exactSearchCategory(_ value: MusicCategory) { exactCategory = value }
  private var searchWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  func holdSearch(_ query: String, categories: Set<MusicCategory> = Set(MusicCategory.allCases)) {
    heldSearch[query] = categories
  }
  func heldCount(_ query: String) -> Int { searchWaiters[query]?.count ?? 0 }
  func releaseSearches() {
    heldSearch = [:]
    let pending = searchWaiters.values.flatMap { $0 }
    searchWaiters = [:]
    for waiter in pending { waiter.resume() }
  }
  private(set) var artistCalls = 0
  private var artistFailure: ClientError?
  private var yearOnlyArtist = false
  func artistHasOnlyYear() { yearOnlyArtist = true }
  private var artistDelay = Duration.zero
  func configureArtist(_ failure: ClientError?, delay: Duration = .zero) {
    artistFailure = failure
    artistDelay = delay
  }
  func artistDetail(library: String, artist: MusicItem) async throws -> MusicItem {
    artistCalls += 1
    try? await Task.sleep(for: artistDelay)
    if let artistFailure { throw artistFailure }
    var result = CatalogFixtures.artist(0)
    result.details =
      yearOnlyArtist
      ? MusicDetails(year: 1947) : MusicDetails(overview: "Invented artist biography")
    return result
  }
  var artworkDelay = Duration.zero
  func delayArtwork(_ value: Duration) { artworkDelay = value }
  func fail(_ value: ClientError?) { failure = value }
  func verifyIdentity() async throws {}
  private var rootIDs = ["music", "live"]
  func setLibraries(_ ids: [String]) { rootIDs = ids }
  func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
    rootIDs.map { MusicLibrary(id: $0, title: $0) }
  }
  func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
    queries.append(query)
    if query.options.sort == heldSort {
      await withCheckedContinuation { optionWaiters.append($0) }
    }
    if heldSearch[query.search]?.contains(query.category) == true {
      await withCheckedContinuation { searchWaiters[query.search, default: []].append($0) }
    }
    if query.search == "old" { try? await Task.sleep(for: .milliseconds(80)) }
    if let failure { throw failure }
    if !query.search.isEmpty, emptySearchTypes.contains(query.category) { return [] }
    let optionLabel =
      query.options == CatalogBrowseOptions()
      ? "" : query.options.sort.rawValue + (query.options.favoritesOnly ? "favorite" : "")
    let prefix = query.library + query.search + query.category.rawValue + optionLabel
    return (query.offset..<min(100_000, query.offset + (query.shelf == nil ? 40 : 12))).map {
      MusicItem(
        id: "\(prefix)-\($0)",
        title: query.category == exactCategory && $0 == 0 ? query.search : "\(query.search) \($0)",
        artist: "Invented",
        album: "Invented", duration: 10, number: $0, kind: query.category.itemType, imageID: nil,
        imageTag: nil)
    }
  }
  private var albumTrackCount = 4
  func largeAlbum(_ count: Int) { albumTrackCount = count }
  func albumTracks(library: String, album: String) async throws -> [MusicItem] {
    detailLibraries.append(library)
    if let failure { throw failure }
    if let albumTrackGate {
      for await _ in albumTrackGate { break }
    } else {
      try? await Task.sleep(for: .milliseconds(40))
    }
    if albumTrackCount == 4 { return CatalogFixtures.tracks(CatalogFixtures.album(0)) }
    return (0..<albumTrackCount).map {
      MusicItem(
        id: "large-track-\($0)", title: "Invented track \($0)", artist: "Invented",
        album: "Large album", duration: 10, number: $0 + 1, kind: "Audio", imageID: nil,
        imageTag: nil, albumID: album)
    }
  }
  func validate(ids: [String]) async throws -> [MusicItem] { [] }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    throw ClientError.forbidden
  }
  func artwork(item: MusicItem) async throws -> Data? {
    artworkCalls += 1
    try await Task.sleep(for: artworkDelay)
    return nil
  }
}
private final class InvalidationCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() {
    lock.lock()
    defer { lock.unlock() }
    count += 1
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
final class CatalogTests: XCTestCase {
  func testHomeLayoutMigratesOrdersAndRoundTripsWithoutLosingLibraryFilters() throws {
    var preferences = CatalogBrowsePreferences()
    preferences.favoritesOnly = true
    preferences.sorts = [.songs: .recentlyAdded]
    let decoder = JSONDecoder()
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
    let old = try decoder.decode(
      CatalogBrowsePreferences.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(old.home)
    object["home"] = [
      "order": ["genres", "obsolete", "genres", "artists"], "hidden": ["discover", "obsolete"],
    ]
    var loaded = try decoder.decode(
      CatalogBrowsePreferences.self, from: JSONSerialization.data(withJSONObject: object))
    var layout = try XCTUnwrap(loaded.home)
    XCTAssertEqual(layout.visible, [.genres, .artists, .recent, .favorites, .playlists])
    layout.move(from: IndexSet([0, 2]), to: 5)
    XCTAssertEqual(layout.order, [.artists, .favorites, .playlists, .genres, .recent, .discover])
    layout.setVisible(true, section: .discover)
    loaded.home = layout
    XCTAssertEqual(
      try decoder.decode(CatalogBrowsePreferences.self, from: JSONEncoder().encode(loaded)), loaded)
    XCTAssertEqual(loaded.options(for: .songs), old.options(for: .songs))
  }

  @MainActor func testHiddenHomeShelfStaysColdAndStaleEditorCannotReorderNextLibrary() async throws
  {
    var preferences = CatalogBrowsePreferences()
    var layout = HomeLayout()
    layout.setVisible(false, section: .favorites)
    preferences.home = layout
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api, preferences: preferences)
    await browser.start()
    try await settle { browser.shelves[.discover]?.loaded == true }
    let before = await api.queries
    XCTAssertFalse(before.contains { $0.shelf == .artists || $0.shelf == .favorites })
    var writes: [CatalogBrowsePreferences] = []
    browser.preferencesChanged = { writes.append($0) }
    browser.setHomeLayout(HomeLayout(), scope: UUID())
    XCTAssertTrue(writes.isEmpty)
    browser.setHomeLayout(HomeLayout(), scope: browser.scope)
    XCTAssertEqual(writes.count, 1)
    XCTAssertNil(writes.first?.home)
    browser.retire()
    browser.setHomeLayout(layout, scope: browser.scope)
    XCTAssertEqual(writes.count, 1)
  }

  func testRankedArtistSongsReadOnlyTheSignedInMusicUsersPositiveCounts() async throws {
    let rows: [[String: Any]] = [
      ["Id": "played", "Type": "Audio", "UserData": ["PlayCount": 8]],
      ["Id": "zero", "Type": "Audio", "UserData": ["PlayCount": 0]],
      ["Id": "unknown", "Type": "Audio", "UserData": ["PlayCount": "unknown"]],
      ["Id": "missing", "Type": "Audio"],
      ["Type": "Other", "Id": 8, "Name": 8, "UserData": ["PlayCount": 9]],
    ]
    let http = CatalogHTTP([
      (
        200,
        [
          "Items": [
            ["Id": "music", "Name": "Music", "Type": "CollectionFolder", "CollectionType": "music"]
          ]
        ]
      ),
      (200, ["Items": rows]), (200, ["Items": rows]),
    ])
    let api = try client(http)
    let ranked = try await api.catalogPage(
      CatalogQuery(
        library: "music", category: .songs,
        artist: "performer", rankArtistSongs: true))
    let ordinary = try await api.catalogPage(
      CatalogQuery(library: "music", category: .songs, artist: "performer"))
    XCTAssertEqual(ranked.items.map(\.id), ["played", "zero", "unknown", "missing"])
    XCTAssertEqual(ranked.playedIDs, ["played"])
    XCTAssertEqual(ranked.rawCount, 5)
    XCTAssertEqual(ordinary.items, ranked.items)
    XCTAssertTrue(ordinary.playedIDs.isEmpty)
    let calls = await http.requests
    XCTAssertEqual(calls.count, 3)
    let params = try calls.dropFirst().map { request in
      try XCTUnwrap(
        URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
    }
    for (key, value) in [
      "UserId": "listener", "ParentId": "music", "ArtistIds": "performer",
      "IncludeItemTypes": "Audio", "SortBy": "PlayCount,SortName",
      "SortOrder": "Descending,Ascending",
      "EnableUserData": "true", "Limit": "40",
    ] {
      XCTAssertEqual(params[0].filter { $0.name == key }.map(\.value), [value], key)
    }
    XCTAssertFalse(
      params[1].contains { $0.name == "SortBy" && $0.value?.contains("PlayCount") == true })
  }

  @MainActor func testArtistHighlightsPageLazilyAndKeepEveryCreditedSongForPlay() async throws {
    let browser = MusicBrowser(
      service: FixtureCatalog(source: URL(fileURLWithPath: "/invented/tone.wav")))
    await browser.start()
    let artist = CatalogFixtures.artist(0)
    let child = try XCTUnwrap(browser.artistBrowser(artist))
    let songs = try XCTUnwrap(child.songsForArtist(artist))
    await songs.load()
    XCTAssertTrue(songs.hasHistory)
    let expected = [
      "fixture-track-2", "fixture-album-6-track-1", "fixture-track-0",
      "fixture-album-12-track-3", "fixture-album-18-track-0",
    ]
    XCTAssertEqual(songs.highlights.map(\.id), expected)
    XCTAssertNil(songs.allLoadedTracks)
    do {
      _ = try await songs.tracksForPlayback { false }
      XCTFail("A superseded Play action must discard the artist queue")
    } catch is CancellationError {}
    XCTAssertNil(songs.allLoadedTracks)
    let tracks = try await songs.tracksForPlayback { true }
    let full = (0..<CatalogFixtures.albumCount).flatMap {
      CatalogFixtures.tracks(CatalogFixtures.album($0))
    }
    .filter { $0.artistCredits?.contains(where: { $0.id == artist.id }) == true }
    XCTAssertGreaterThan(tracks.count, 80)
    XCTAssertEqual(Set(tracks.map(\.id)), Set(full.map(\.id)))
    XCTAssertEqual(tracks.count, full.count)
    XCTAssertEqual(tracks.prefix(5).map(\.id), expected)
    XCTAssertEqual(songs.allLoadedTracks, tracks)
    browser.retire()
    XCTAssertTrue(songs.highlights.isEmpty)
    XCTAssertNil(songs.allLoadedTracks)
    do {
      _ = try await songs.tracksForPlayback { true }
      XCTFail("A retired library must discard the artist queue")
    } catch is CancellationError {}
  }

  @MainActor func testReturningToArtistReplacesItsCancelledFirstPage() async throws {
    let http = CatalogHTTP([
      (
        200,
        [
          "Items": [
            ["Id": "music", "Name": "Music", "Type": "CollectionFolder", "CollectionType": "music"]
          ]
        ]
      ),
      (200, ["Items": [["Id": "returned", "Type": "Audio", "UserData": ["PlayCount": 1]]]]),
    ])
    let api = try client(http)
    _ = try await api.musicLibraries(refresh: false)
    let songs = ArtistSongs(
      service: api, library: "music", artist: "performer",
      isCurrent: { true },
      rejected: { _ in XCTFail("A superseded request must not reject a visible page") })
    await http.holdNextItems()
    let previous = Task { await songs.load() }
    try await waitForDetail { await http.itemWaiting }
    previous.cancel()
    await songs.load()
    await http.releaseItems()
    await previous.value
    XCTAssertEqual(songs.highlights.map(\.id), ["returned"])
    XCTAssertTrue(songs.hasHistory)
    XCTAssertFalse(songs.loading)
    XCTAssertFalse(songs.failed)
  }

  @MainActor func testGuestWithoutHistoryHasSongsAndIndependentAlbumAndSongDrilldowns() async throws
  {
    let browser = MusicBrowser(
      service: FixtureCatalog(source: URL(fileURLWithPath: "/invented/tone.wav")))
    await browser.start()
    let guest = CatalogFixtures.guest.item
    let overview = try XCTUnwrap(browser.artistBrowser(guest))
    let songs = try XCTUnwrap(overview.songsForArtist(guest))
    await songs.load()
    XCTAssertFalse(songs.hasHistory)
    XCTAssertEqual(
      songs.highlights.map(\.id), ["fixture-album-1-track-1", "fixture-album-1-track-0"])
    XCTAssertEqual(songs.allLoadedTracks, songs.highlights)
    let all = try XCTUnwrap(overview.artistBrowser(guest, category: .songs))
    XCTAssertEqual(overview.category, .albums)
    XCTAssertEqual(all.category, .songs)
    XCTAssertNil(overview.songsForArtist(CatalogFixtures.artist(0)))
    try await waitForDetail { all.resultsAreCurrent }
    XCTAssertEqual(Set(all.window.items.map(\.id)), Set(songs.highlights.map(\.id)))
  }

  func testHomeRequestsStayRootedAndGenrePreviewDoesNotLimitItsDetail() async throws {
    let http = CatalogHTTP([
      (
        200,
        [
          "Items": [
            ["Id": "music", "Type": "CollectionFolder", "CollectionType": "music", "Name": "Music"]
          ]
        ]
      ),
      (
        200,
        [
          "Items": [
            ["Id": "a", "Type": "MusicAlbum"], ["Id": "s", "Type": "Audio"],
            ["Type": "Other", "Name": 7],
          ]
        ]
      ),
      (200, ["Items": [["Id": "artist", "Type": "MusicArtist"]]]),
      (
        200,
        [
          "Items": [
            ["Id": "jazz", "Type": "MusicGenre", "Name": "Jazz"],
            ["Type": "Other", "Id": 7, "Name": 7],
          ]
        ]
      ),
      (200, ["Items": [["Id": "cover", "Type": "MusicAlbum"]]]),
      (200, ["Items": [["Id": "other-album", "Type": "MusicAlbum"]]]),
    ])
    let api = try client(http)
    let favorites = try await api.catalog(CatalogQuery(library: "music", shelf: .favorites))
    XCTAssertEqual(favorites.map(\.id), ["a", "s"])
    let artists = try await api.catalog(
      CatalogQuery(library: "music", category: .artists, shelf: .artists))
    XCTAssertEqual(artists.map(\.id), ["artist"])
    let genres = try await api.homeGenres(library: "music")
    XCTAssertEqual(genres.map(\.id), ["jazz"])
    XCTAssertEqual(genres.first?.covers.map(\.id), ["cover"])
    let detail = try await api.catalogPage(
      CatalogQuery(library: "music", offset: 40, genreID: "jazz"))
    XCTAssertEqual(detail.items.map(\.id), ["other-album"])
    let requests = await http.requests.dropFirst()
    XCTAssertEqual(
      requests.map { $0.url?.lastPathComponent }, ["Items", "Artists", "Genres", "Items", "Items"])
    let fields = try requests.map { request in
      try XCTUnwrap(
        URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
    }
    for query in fields {
      XCTAssertTrue(query.contains(.init(name: "ParentId", value: "music")))
      XCTAssertTrue(query.contains(.init(name: "UserId", value: "listener")))
    }
    XCTAssertTrue(fields[0].contains(.init(name: "IncludeItemTypes", value: "MusicAlbum,Audio")))
    XCTAssertTrue(fields[0].contains(.init(name: "Filters", value: "IsFavorite")))
    XCTAssertTrue(fields[1].contains(.init(name: "SortBy", value: "Random")))
    XCTAssertTrue(fields[1].contains(.init(name: "IncludeItemTypes", value: "Audio,MusicAlbum")))
    XCTAssertTrue(fields[2].contains(.init(name: "Limit", value: "6")))
    for index in [3, 4] {
      XCTAssertTrue(fields[index].contains(.init(name: "GenreIds", value: "jazz")))
    }
    XCTAssertTrue(fields[3].contains(.init(name: "Limit", value: "4")))
    XCTAssertTrue(fields[4].contains(.init(name: "Limit", value: "40")))
    XCTAssertTrue(fields[4].contains(.init(name: "StartIndex", value: "40")))
  }

  @MainActor func testMenuReceiptHeldTriggerCannotMutateSuccessorAfterLibraryRetirement()
    async throws
  {
    let browser = MusicBrowser(service: PagedCatalog())
    await browser.start()
    let owner = browser.scope
    let library = browser.authorizedLibrary
    var presentation: UUID?
    let trigger = CatalogPresentationReceipt(owner: owner, presentation: presentation)
    let held = {
      guard
        trigger.admits(
          owner: browser.scope, presentation: presentation,
          isCurrent: { browser.metadataIsCurrent(scope: owner, library: library) })
      else { return }
      presentation = presentation == nil ? UUID() : nil
    }
    browser.selectLibrary("live")
    let successor = UUID()
    presentation = successor
    held()
    XCTAssertEqual(presentation, successor)
    browser.selectLibrary("music")
    held()
    XCTAssertEqual(presentation, successor, "Returning to a root cannot revive an old trigger")
    browser.retire()
  }
  func testMenuReceiptRejectsOldTriggerContentAndDismissalWithinSameOwner() {
    let owner = UUID()
    var presentation: UUID?
    let initialTrigger = CatalogPresentationReceipt(owner: owner, presentation: presentation)
    XCTAssertTrue(
      initialTrigger.admits(owner: owner, presentation: presentation, isCurrent: { true }))
    let first = UUID()
    presentation = first
    let firstReceipt = CatalogPresentationReceipt(owner: owner, presentation: presentation)
    let content = { (receipt: CatalogPresentationReceipt<UUID>, reads: inout Int) in
      if receipt.admits(owner: owner, presentation: presentation, isCurrent: { true }) {
        reads += 1
      }
    }
    var reads = 0
    content(firstReceipt, &reads)
    XCTAssertEqual(reads, 1, "A current menu admits its real content")
    presentation = nil
    let reopened = UUID()
    presentation = reopened
    let successor = CatalogPresentationReceipt(owner: owner, presentation: presentation)
    for held in [initialTrigger, firstReceipt] {
      if held.admits(owner: owner, presentation: presentation, isCurrent: { true }) {
        presentation = nil
      }
      content(held, &reads)
      XCTAssertEqual(
        presentation, reopened, "Held trigger/dismissal must not close a reopened menu")
    }
    XCTAssertEqual(reads, 1, "Old content must not extract successor fields")
    content(successor, &reads)
    XCTAssertEqual(reads, 2)
    XCTAssertFalse(successor.admits(owner: owner, presentation: presentation, isCurrent: { false }))
    if successor.admits(owner: owner, presentation: presentation, isCurrent: { true }) {
      presentation = nil
    }
    XCTAssertNil(presentation, "The legitimate current toggle/dismiss remains admitted")
  }

  private func acceptRestoration(
    _ value: CatalogReflowAnchor.Value, position: inout CatalogReflowAnchor,
    owner: CatalogReflowAnchor.Owner, from: Double, to: Double
  ) {
    guard let ticket = position.restoration(owner: owner, viewport: from) else {
      XCTFail("Expected the original admitted restoration receipt")
      return
    }
    XCTAssertTrue(position.didRestore(ticket, viewport: to, owner: owner))
    XCTAssertFalse(position.didRestore(ticket, viewport: to, owner: owner), "One-use delivery")
    XCTAssertEqual(position.resolve(measured: nil, viewport: to), value)
  }
  private func seedRestoration(
    _ value: CatalogReflowAnchor.Value, position: inout CatalogReflowAnchor,
    owner: CatalogReflowAnchor.Owner, viewport: Double
  ) {
    position.attach(value, viewport: viewport, owner: owner)
    XCTAssertEqual(
      position.finish(owner: owner, viewport: viewport, mutationInProgress: false), value)
    acceptRestoration(value, position: &position, owner: owner, from: viewport, to: viewport)
  }
  func testRestoredAnchorAdmitsSameOwnerNativeGeometryRefinement() throws {
    var position = CatalogReflowAnchor()
    let owner = CatalogReflowAnchor.Owner(scope: UUID(), revision: UUID())
    let saved = CatalogReflowAnchor.Value(id: "song-122", fraction: 0.8)
    position.attach(saved, viewport: 0, owner: owner)
    XCTAssertEqual(position.finish(owner: owner, viewport: 0, mutationInProgress: false), saved)
    let provisional = 1000 + 72 * saved.fraction
    acceptRestoration(saved, position: &position, owner: owner, from: 0, to: provisional)
    let refinement = try XCTUnwrap(
      position.beginOwnedMutation(owner: owner, viewport: provisional),
      "The already restored item needs the same scoped synchronous native-layout boundary")
    XCTAssertTrue(position.rebase(refinement, owner: owner, viewport: 1080))
    XCTAssertEqual(position.finish(owner: owner, viewport: 1080, mutationInProgress: false), saved)
    let measured = 1040 + 56 * saved.fraction
    acceptRestoration(saved, position: &position, owner: owner, from: 1080, to: measured)
    XCTAssertEqual(
      position.resolve(measured: .init(id: "song-120", fraction: 0), viewport: measured), saved)
  }
  func testRestoredAnchorRefinementRejectsUserNonDragAndOwnerSupersession() {
    let owner = CatalogReflowAnchor.Owner(scope: UUID(), revision: UUID())
    let successor = CatalogReflowAnchor.Owner(scope: owner.scope, revision: UUID())
    let saved = CatalogReflowAnchor.Value(id: "song-122", fraction: 0.8)
    func restored() -> CatalogReflowAnchor {
      var position = CatalogReflowAnchor()
      position.attach(saved, viewport: 0, owner: owner)
      XCTAssertEqual(position.finish(owner: owner, viewport: 0, mutationInProgress: false), saved)
      acceptRestoration(saved, position: &position, owner: owner, from: 0, to: 100)
      return position
    }
    var position = restored()
    position.reset()
    XCTAssertNil(position.beginOwnedMutation(owner: owner, viewport: 100))
    position = restored()
    position.viewportChanged(to: 120)
    XCTAssertNil(position.beginOwnedMutation(owner: owner, viewport: 120))
    position = restored()
    XCTAssertNil(
      position.beginOwnedMutation(owner: owner, viewport: 120),
      "Fresh offset must reject even without didScroll")
    position = restored()
    XCTAssertNil(position.beginOwnedMutation(owner: successor, viewport: 100))
    XCTAssertNil(
      position.beginOwnedMutation(owner: owner, viewport: 100),
      "Old owner cannot return after supersession")
  }
  func testRestoredRefinementNoOpReplayAndReentrantSuccessorPreserveMeasuredOutcomes() throws {
    var position = CatalogReflowAnchor()
    let owner = CatalogReflowAnchor.Owner(scope: UUID(), revision: UUID())
    let saved = CatalogReflowAnchor.Value(id: "song-121", fraction: 0.25)
    seedRestoration(saved, position: &position, owner: owner, viewport: 200)
    let unchanged = try XCTUnwrap(position.beginOwnedMutation(owner: owner, viewport: 200))
    XCTAssertTrue(position.rebase(unchanged, owner: owner, viewport: 200, refined: false))
    XCTAssertNil(
      position.finish(owner: owner, viewport: 200, mutationInProgress: false),
      "No restore/layout loop")
    XCTAssertEqual(
      position.resolve(measured: .init(id: "song-120", fraction: 0), viewport: 200), saved)
    XCTAssertFalse(
      position.rebase(unchanged, owner: owner, viewport: 250), "Native replay is one-use")
    let inFlight = try XCTUnwrap(position.beginOwnedMutation(owner: owner, viewport: 200))
    let next = CatalogReflowAnchor.Value(id: "song-130", fraction: 0.7)
    position.attach(next, viewport: 0, owner: owner)
    XCTAssertFalse(position.rebase(inFlight, owner: owner, viewport: 250))
    XCTAssertEqual(position.finish(owner: owner, viewport: 0, mutationInProgress: false), next)
    let staleApply = try XCTUnwrap(position.restoration(owner: owner, viewport: 0))
    position.attach(saved, viewport: 200, owner: owner)
    XCTAssertFalse(position.didRestore(staleApply, viewport: 0, owner: owner))
    XCTAssertEqual(position.finish(owner: owner, viewport: 200, mutationInProgress: false), saved)
    let apply = try XCTUnwrap(position.restoration(owner: owner, viewport: 200))
    position.viewportChanged(to: 300)
    XCTAssertFalse(position.didRestore(apply, viewport: 200, owner: owner))
    let measured = CatalogReflowAnchor.Value(id: "song-140", fraction: 0.1)
    XCTAssertEqual(position.resolve(measured: measured, viewport: 300), measured)
  }
  func testReplacementAttachmentWaitsForUsableLayoutWithoutLosingSavedItem() throws {
    var position = CatalogReflowAnchor()
    let owner = CatalogReflowAnchor.Owner(scope: UUID(), revision: UUID())
    let saved = CatalogReflowAnchor.Value(id: "song-122", fraction: 0.83)
    position.attach(saved, viewport: 0, owner: owner)
    XCTAssertNil(
      position.finish(owner: owner, viewport: 0, mutationInProgress: false, geometryIsUsable: false)
    )
    position.prepare(measured: .init(id: "song-0", fraction: 0), viewport: 0, owner: owner)
    let nativeLayout = try XCTUnwrap(position.beginOwnedMutation(owner: owner, viewport: 0))
    XCTAssertNil(position.finish(owner: owner, viewport: 0, mutationInProgress: true))
    XCTAssertTrue(position.rebase(nativeLayout, owner: owner, viewport: -20))
    XCTAssertEqual(position.finish(owner: owner, viewport: -20, mutationInProgress: false), saved)
    XCTAssertNil(position.finish(owner: owner, viewport: -20, mutationInProgress: false), "One use")
    acceptRestoration(saved, position: &position, owner: owner, from: -20, to: 8910)
    XCTAssertEqual(
      position.resolve(measured: .init(id: "song-120", fraction: 0), viewport: 8910), saved)
    position.viewportChanged(to: 9000)
    XCTAssertEqual(
      position.resolve(measured: .init(id: "song-124", fraction: 0.2), viewport: 9000)?.id,
      "song-124")
  }
  func testReplacementAttachmentRejectsOwnerDragAndUnreportedViewportSupersession() throws {
    let owner = CatalogReflowAnchor.Owner(scope: UUID(), revision: UUID())
    let other = CatalogReflowAnchor.Owner(scope: owner.scope, revision: UUID())
    let saved = CatalogReflowAnchor.Value(id: "song-122", fraction: 0.83)
    var position = CatalogReflowAnchor()
    position.attach(saved, viewport: 0, owner: owner)
    XCTAssertNil(position.finish(owner: other, viewport: 0, mutationInProgress: false))
    XCTAssertNil(position.finish(owner: owner, viewport: 0, mutationInProgress: false))
    position.attach(saved, viewport: 0, owner: owner)
    position.reset()
    XCTAssertNil(position.finish(owner: owner, viewport: 0, mutationInProgress: false))
    position.attach(saved, viewport: 0, owner: owner)
    XCTAssertNil(
      position.finish(owner: owner, viewport: 50, mutationInProgress: false),
      "No intermediate didScroll is needed")
    position.attach(saved, viewport: 0, owner: owner)
    let old = try XCTUnwrap(position.beginOwnedMutation(owner: owner, viewport: 0))
    position.attach(.init(id: "successor", fraction: 0.2), viewport: 0, owner: owner)
    XCTAssertFalse(
      position.rebase(old, owner: owner, viewport: 100),
      "A retired transaction cannot rebase a same-owner successor")
    XCTAssertEqual(
      position.finish(owner: owner, viewport: 0, mutationInProgress: false)?.id, "successor")
  }
  func testSecondColumnReflowKeepsLogicalItemUntilActualUserScrollOrRetirement() throws {
    var position = CatalogReflowAnchor()
    let owner = CatalogReflowAnchor.Owner(scope: UUID(), revision: UUID())
    let list = CatalogReflowAnchor.Value(id: "song-121", fraction: 17.6666666667 / 56)
    XCTAssertEqual(position.resolve(measured: list, viewport: 100), list)
    seedRestoration(list, position: &position, owner: owner, viewport: 200)
    let grid = CatalogReflowAnchor.Value(id: "song-120", fraction: list.fraction)
    let restored = try XCTUnwrap(position.resolve(measured: grid, viewport: 200))
    XCTAssertEqual(restored, list)
    seedRestoration(restored, position: &position, owner: owner, viewport: 100)
    XCTAssertEqual(
      position.resolve(measured: grid, viewport: 100), list,
      "List round-trip must not lose a row")
    position.reset()
    let scrolled = CatalogReflowAnchor.Value(id: "song-126", fraction: 0.6)
    XCTAssertEqual(position.resolve(measured: scrolled, viewport: 300), scrolled)
    seedRestoration(scrolled, position: &position, owner: owner, viewport: 300)
    position.reset()
    let successor = CatalogReflowAnchor.Value(id: "new-query-0", fraction: 0)
    XCTAssertEqual(position.resolve(measured: successor, viewport: 0), successor)
    XCTAssertNil(position.resolve(measured: nil, viewport: 0))
  }
  func testNonDragViewportMovementRevokesReflowAnchorWithoutResurrection() {
    var position = CatalogReflowAnchor()
    let owner = CatalogReflowAnchor.Owner(scope: UUID(), revision: UUID())
    let restored = CatalogReflowAnchor.Value(id: "song-121", fraction: 0.25)
    let group = CatalogReflowAnchor.Value(id: "song-120", fraction: 0.25)
    seedRestoration(restored, position: &position, owner: owner, viewport: 200)
    XCTAssertEqual(position.resolve(measured: group, viewport: 200), restored)
    position.viewportChanged(to: 0)
    let actual = CatalogReflowAnchor.Value(id: "song-0", fraction: 0)
    XCTAssertEqual(position.resolve(measured: actual, viewport: 0), actual)
    XCTAssertEqual(position.resolve(measured: group, viewport: 200), group)
    seedRestoration(restored, position: &position, owner: owner, viewport: 200)
    XCTAssertEqual(
      position.resolve(measured: actual, viewport: 0), actual,
      "Capture also rejects a changed viewport if no delegate callback arrived")
  }
  func testPendingWidthAnchorRejectsSupersessionDragAndViewportMovement() {
    let owner = CatalogReflowAnchor.Owner(scope: UUID(), revision: UUID())
    let row = CatalogReflowAnchor.Value(id: "song-121", fraction: 0.25)
    var position = CatalogReflowAnchor()
    position.prepare(measured: row, viewport: 200, owner: owner)
    XCTAssertEqual(position.finish(owner: owner, viewport: 200, mutationInProgress: false), row)
    XCTAssertNil(
      position.finish(owner: owner, viewport: 200, mutationInProgress: false),
      "A pending width capture is one-use")
    for next in [
      CatalogReflowAnchor.Owner(scope: UUID(), revision: owner.revision),
      CatalogReflowAnchor.Owner(scope: owner.scope, revision: UUID()),
    ] {
      seedRestoration(row, position: &position, owner: owner, viewport: 200)
      position.prepare(measured: row, viewport: 200, owner: owner)
      XCTAssertNil(
        position.finish(owner: next, viewport: 200, mutationInProgress: false),
        "Neither a root nor query can adopt old reflow"
      )
      XCTAssertNil(position.resolve(measured: nil, viewport: 200))
    }
    position.prepare(measured: row, viewport: 200, owner: owner)
    position.reset()
    XCTAssertNil(position.finish(owner: owner, viewport: 200, mutationInProgress: false))
    seedRestoration(row, position: &position, owner: owner, viewport: 200)
    position.prepare(measured: row, viewport: 200, owner: owner)
    position.viewportChanged(to: 250)
    XCTAssertNil(position.finish(owner: owner, viewport: 200, mutationInProgress: false))
    XCTAssertNil(position.resolve(measured: nil, viewport: 200))
    position.prepare(measured: row, viewport: 200, owner: owner)
    XCTAssertNil(
      position.finish(owner: owner, viewport: 250, mutationInProgress: false),
      "Terminal width consumption checks the actual viewport without any delegate callback")
    XCTAssertNil(position.resolve(measured: nil, viewport: 200))
  }
  func testOwnedSynchronousReflowRebasesOnlyItsStillLivePendingCapture() throws {
    var position = CatalogReflowAnchor()
    let owner = CatalogReflowAnchor.Owner(scope: UUID(), revision: UUID())
    let row = CatalogReflowAnchor.Value(id: "song-121", fraction: 0.25)
    position.prepare(measured: row, viewport: 200, owner: owner)
    let transaction = try XCTUnwrap(position.beginOwnedMutation(owner: owner, viewport: 200))
    XCTAssertNil(position.finish(owner: owner, viewport: 250, mutationInProgress: true))
    XCTAssertTrue(
      position.rebase(transaction, owner: owner, viewport: 250),
      "Reentrant finish must not consume or revoke the original pending token")
    XCTAssertNil(position.finish(owner: owner, viewport: 250, mutationInProgress: true))
    XCTAssertEqual(position.finish(owner: owner, viewport: 250, mutationInProgress: false), row)
    acceptRestoration(row, position: &position, owner: owner, from: 250, to: 250)
    XCTAssertNil(position.finish(owner: owner, viewport: 250, mutationInProgress: false))
    XCTAssertEqual(
      position.resolve(
        measured: .init(id: "song-120", fraction: 0.25), viewport: 250), row,
      "A redundant width completion must not clear the just-restored logical anchor")
    XCTAssertFalse(position.rebase(transaction, owner: owner, viewport: 260), "One-use capture")
    position.prepare(measured: row, viewport: 200, owner: owner)
    XCTAssertNil(position.beginOwnedMutation(owner: owner, viewport: 250), "Fresh admission")
    XCTAssertNil(position.finish(owner: owner, viewport: 250, mutationInProgress: false))
    for retirement in 0..<3 {
      position.prepare(measured: row, viewport: 200, owner: owner)
      let old = try XCTUnwrap(position.beginOwnedMutation(owner: owner, viewport: 200))
      position.reset()
      let successor =
        retirement == 0
        ? owner : CatalogReflowAnchor.Owner(scope: UUID(), revision: UUID())
      let next = CatalogReflowAnchor.Value(id: "successor-0", fraction: 0)
      position.prepare(measured: next, viewport: 0, owner: successor)
      XCTAssertFalse(position.rebase(old, owner: successor, viewport: 250))
      XCTAssertEqual(
        position.finish(owner: successor, viewport: 0, mutationInProgress: false), next)
    }
    position.prepare(measured: row, viewport: 200, owner: owner)
    let old = try XCTUnwrap(position.beginOwnedMutation(owner: owner, viewport: 200))
    position.viewportChanged(to: 250)
    XCTAssertFalse(position.rebase(old, owner: owner, viewport: 250))
    XCTAssertNil(position.finish(owner: owner, viewport: 250, mutationInProgress: false))
  }
  func testViewportClampPreservesFeasibleFractionAndBoundsShorterGridNearEnd() {
    XCTAssertEqual(
      CatalogViewportOffset.clamp(
        1200, content: 1300, viewport: 640,
        topInset: 12, bottomInset: 40), 700)
    XCTAssertEqual(
      CatalogViewportOffset.clamp(
        420.5, content: 2000, viewport: 640,
        topInset: 12, bottomInset: 40), 420.5)
    XCTAssertEqual(
      CatalogViewportOffset.clamp(
        -20, content: 2000, viewport: 640,
        topInset: 12, bottomInset: 40), -12)
    XCTAssertEqual(
      CatalogViewportOffset.clamp(
        1200, content: 200, viewport: 640,
        topInset: 12, bottomInset: 40), -12)
  }
  @MainActor func testHeldCellActionRejectsReuseReconfigurationQueryAndRootBeforeExtractor()
    async throws
  {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.resultsAreCurrent }
    func bind(_ index: Int) -> CatalogActionBinding {
      CatalogActionBinding(
        scope: browser.scope, revision: browser.window.revision,
        category: browser.category, id: browser.window.items[index].id)
    }
    var renderer: RenderLifetimeProbe? = RenderLifetimeProbe()
    let rendered = CatalogActionBinding(
      scope: browser.scope, revision: browser.window.revision,
      category: browser.category, id: browser.window.items[0].id,
      isRenderedCurrent: { [weak renderer] in renderer?.live == true })
    var teardownReads = 0
    let heldAfterTeardown = { if rendered.isCurrent(in: browser) { teardownReads += 1 } }
    heldAfterTeardown()
    XCTAssertEqual(teardownReads, 1)
    renderer?.live = false
    heldAfterTeardown()
    XCTAssertEqual(teardownReads, 1)
    renderer = nil
    XCTAssertFalse(rendered.isCurrent(in: browser), "A held action cannot keep its renderer alive")
    let a = bind(0)
    var reads = 0
    let held = { if a.isCurrent(in: browser) { reads += 1 } }
    held()
    XCTAssertEqual(reads, 1)
    a.retire()
    let b = bind(1)
    held()
    XCTAssertEqual(reads, 1, "Retained metadata cannot keep a reused cell's old action live")
    XCTAssertTrue(b.isCurrent(in: browser))
    b.retire()
    let rebound = bind(1)
    XCTAssertFalse(
      b.isCurrent(in: browser),
      "Same-ID appearance/layout reconfiguration also revokes held actions")
    XCTAssertTrue(rebound.isCurrent(in: browser))
    browser.searchText = "successor"
    browser.searchChanged()
    XCTAssertFalse(rebound.isCurrent(in: browser), "New query rejects before any row extractor")
    try await settle { browser.resultsAreCurrent }
    let current = bind(0)
    browser.selectLibrary("live")
    XCTAssertFalse(current.isCurrent(in: browser))
    held()
    XCTAssertEqual(reads, 1)
    browser.retire()
  }
  @MainActor func testSharedMusicPreferencesReachArtistChildrenButNeverSearchAndRetire()
    async throws
  {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.resultsAreCurrent }
    let child = try XCTUnwrap(browser.artistBrowser(CatalogFixtures.artist(0)))
    let sibling = try XCTUnwrap(browser.artistBrowser(CatalogFixtures.artist(1)))
    let search = try XCTUnwrap(browser.searchBrowser())
    search.updateSearchText("accepted")
    try await settle { search.windows.count == 3 && search.windows.values.allSatisfy { $0.loaded } }
    let searchRows = search.searchWindow(.songs).items
    let rootScope = browser.scope
    let childScope = child.scope
    var saved: [CatalogBrowsePreferences] = []
    browser.preferencesChanged = { saved.append($0) }
    var options = child.options
    options.favoritesOnly = true
    options.sort = .year
    child.selectOptions(options)
    try await settle {
      browser.resultsAreCurrent && child.resultsAreCurrent && sibling.resultsAreCurrent
    }
    XCTAssertTrue(browser.options.favoritesOnly)
    XCTAssertEqual(sibling.options.sort, .year)
    XCTAssertEqual(browser.scope, rootScope, "Preferences must not revoke playable root authority")
    XCTAssertEqual(child.scope, childScope)
    XCTAssertEqual(search.options, CatalogBrowseOptions())
    XCTAssertEqual(search.searchWindow(.songs).items, searchRows)
    child.selectCategory(.songs)
    try await settle { child.resultsAreCurrent }
    XCTAssertEqual(
      child.options.sort, .title, "A category-incompatible sort never leaks across types")
    XCTAssertTrue(child.options.favoritesOnly)
    XCTAssertEqual(saved.count, 1)
    browser.selectLibrary("live")
    XCTAssertTrue(
      browser.options.favoritesOnly, "Account preferences survive an authorized root selection")
    child.selectOptions(CatalogBrowseOptions())
    XCTAssertEqual(saved.count, 1, "Retired children cannot mutate successor preferences")
    XCTAssertTrue(browser.options.favoritesOnly)
    browser.retire()
  }
  @MainActor func testSameQueryRefreshReplacesHistoryOnlyAfterAcceptedSuccess() async throws {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    let search = try XCTUnwrap(browser.searchBrowser())
    search.selectSearchCategory(.albums)
    search.updateSearchText("refresh")
    try await settle { search.resultsAreCurrent }
    search.loadMore()
    try await settle { search.window.items.count == 80 && !search.window.loading }
    let before = search.window.items
    let revision = search.window.revision
    await api.fail(.unavailable)
    search.loadSearch(force: true)
    try await settle { search.window.error != nil }
    XCTAssertEqual(search.window.items, before)
    XCTAssertEqual(search.window.revision, revision)
    await api.fail(nil)
    search.loadSearch(force: true)
    try await settle { search.window.error == nil && !search.window.loading }
    XCTAssertEqual(search.window.items.count, 40)
    XCTAssertEqual(
      search.window.nextOffset, 40, "Fresh first-page metadata resets the raw cursor with history")
    XCTAssertNotEqual(search.window.revision, revision)
    let calls = await api.queries.count
    search.continueListing(
      .later, scope: search.scope, category: .albums, query: "refresh", revision: revision)
    await Task.yield()
    let after = await api.queries.count
    XCTAssertEqual(after, calls)
    search.loadMore()
    try await settle { search.window.items.count == 80 && !search.window.loading }
    let requests = await api.queries
    XCTAssertEqual(requests.last?.offset, 40)
    await api.emptySearchCategories([.albums])
    search.loadSearch(force: true)
    try await settle { search.window.items.isEmpty && !search.window.loading }
    XCTAssertFalse(search.window.hasNext)
    browser.retire()
  }
  @MainActor func testVisitedMetadataSurvivesForwardAndReverseWithoutCatalogRead() async throws {
    let service = PagedCatalog()
    let browser = MusicBrowser(service: service)
    await browser.start()
    try await settle { browser.window.loaded && !browser.window.loading }
    let first = try XCTUnwrap(browser.window.items.first?.id)
    for _ in 0..<4 {
      let expected = browser.window.nextOffset
      browser.loadMore()
      try await settle { browser.window.requestedOffset == expected && !browser.window.loading }
    }
    XCTAssertEqual(browser.window.items.count, 200)
    XCTAssertEqual(browser.window.items.first?.id, first)
    let before = await service.queries.count
    browser.loadEarlier()
    try await Task.sleep(for: .milliseconds(30))
    let after = await service.queries.count
    XCTAssertEqual(after, before, "Visited backscroll must not refetch catalog metadata")
    XCTAssertEqual(browser.window.items.first?.id, first)
  }
  @MainActor func testStationaryBothEdgesAndReflowCannotPageButRealFlingAndReverseCan() async throws
  {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    var gesture = CatalogPagingGesture()
    func edge(_ later: Bool) -> Bool {
      browser.boundaryVisibilityChanged(
        id: later ? browser.window.items.last!.id : browser.window.items.first!.id, visible: true,
        scope: browser.scope, category: .albums, query: "", revision: browser.window.revision,
        direction: gesture.direction)
    }
    let initial = await api.queries.count
    for _ in 0..<20 {
      XCTAssertFalse(edge(false))
      XCTAssertFalse(edge(true))
    }
    var count = await api.queries.count
    XCTAssertEqual(count, initial)
    gesture.phase(active: true)
    gesture.movement(from: 0, to: 1)
    XCTAssertTrue(edge(true))
    gesture.admitted()
    try await settle { browser.window.pages[40] != nil && !browser.window.loading }
    gesture.movement(from: 9, to: 0)
    for _ in 0..<20 {
      XCTAssertFalse(edge(false))
      XCTAssertFalse(edge(true))
    }
    gesture.movement(from: 1, to: 8)
    XCTAssertTrue(edge(true))
    gesture.admitted()
    try await settle { browser.window.pages[80] != nil && !browser.window.loading }
    gesture.movement(from: 8, to: 16)
    XCTAssertTrue(edge(true))
    gesture.admitted()
    try await settle { browser.window.pages[120] != nil && !browser.window.loading }
    count = await api.queries.count
    gesture.phase(active: false)
    gesture.movement(from: 0, to: 20)
    for _ in 0..<20 {
      XCTAssertFalse(edge(false))
      XCTAssertFalse(edge(true))
    }
    let stationary = await api.queries.count
    XCTAssertEqual(count, stationary)
    gesture = CatalogPagingGesture()
    gesture.movement(from: 0, to: 20)
    XCTAssertFalse(edge(true))
    gesture.phase(active: true)
    gesture.movement(from: 20, to: 19)
    XCTAssertEqual(gesture.direction, .earlier)
    XCTAssertFalse(edge(false), "Reverse movement uses retained rows, never a catalog refetch")
    let reverse = await api.queries.count
    XCTAssertEqual(reverse, stationary)
    XCTAssertEqual(browser.window.firstOffset, 0)
    XCTAssertEqual(browser.window.pages.count, 4)
    browser.retire()
  }
  @MainActor func testExplicitContinuationAllowsOrdinaryFullPageWithoutGestureAndRejectsStaleScope()
    async throws
  {
    let first = (0..<40).map { ["Type": "MusicAlbum", "Id": "ordinary-\($0)", "Name": "Invented"] }
    let http = CatalogHTTP { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let object: [String: Any]
      if request.url?.lastPathComponent == "UserViews" {
        object = [
          "Items": [
            [
              "CollectionType": "music", "Type": "CollectionFolder", "Id": "music",
              "Name": "Invented",
            ]
          ]
        ]
      } else if query.contains(.init(name: "Limit", value: "12"))
        || query.contains(.init(name: "SortBy", value: "Random"))
        || query.contains(.init(name: "Filters", value: "IsFavorite"))
      {
        object = ["Items": []]
      } else {
        object = ["Items": query.contains(.init(name: "StartIndex", value: "0")) ? first : []]
      }
      return HTTPReply(data: try! JSONSerialization.data(withJSONObject: object), status: 200)
    }
    let listing: (URLRequest) -> Bool = { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      return request.url?.lastPathComponent == "Items"
        && query.contains(.init(name: "Limit", value: "40"))
        && !query.contains(.init(name: "SortBy", value: "Random"))
        && !query.contains(.init(name: "Filters", value: "IsFavorite"))
    }
    let browser = MusicBrowser(service: try client(http))
    defer { browser.retire() }
    await browser.start()
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    XCTAssertEqual(browser.window.items.count, 40)
    XCTAssertTrue(browser.window.needsExplicitContinuation)
    XCTAssertFalse(browser.window.currentPageHasOmittedRows)
    browser.continueListing(
      .later, scope: UUID(), category: .albums, query: "", revision: browser.window.revision)
    let before = await http.requests
    XCTAssertEqual(before.filter(listing).count, 1)
    browser.continueListing(
      .later, scope: browser.scope, category: .albums, query: "", revision: browser.window.revision)
    try await settle { browser.window.pages[40] != nil && !browser.window.loading }
    XCTAssertEqual(browser.window.items.count, 40)
    XCTAssertFalse(browser.window.hasNext)
    XCTAssertFalse(browser.window.needsExplicitContinuation)
    browser.continueListing(
      .later, scope: browser.scope, category: .albums, query: "", revision: browser.window.revision)
    let requests = await http.requests
    let offsets = requests.filter(listing).map {
      URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {
        $0.name == "StartIndex"
      })?.value
    }
    XCTAssertEqual(offsets, ["0", "40"])
  }
  @MainActor func testExplicitContinuationSeparatesRawOmissionsAndHealthyBoundaries() {
    let state = CatalogWindow()
    XCTAssertFalse(state.needsExplicitContinuation)
    let first = (0..<40).map { CatalogFixtures.album($0) }
    state.accept(first, at: 0, query: "ordinary", rawCount: 40)
    XCTAssertTrue(state.needsExplicitContinuation)
    XCTAssertFalse(
      state.currentPageHasOmittedRows, "Mixed ordinary Search keeps its existing5/See All path")
    state.loading = true
    XCTAssertFalse(state.needsExplicitContinuation)
    state.loading = false
    state.error = "Invented unavailable page"
    XCTAssertFalse(state.needsExplicitContinuation)
    state.error = nil
    state.accept(Array(first.prefix(1)), at: 0, query: "sparse", rawCount: 40, replacing: true)
    XCTAssertTrue(state.needsExplicitContinuation)
    XCTAssertTrue(
      state.currentPageHasOmittedRows, "Mixed sparse Search retains explicit raw continuation")
    state.accept([], at: 40, query: "sparse", rawCount: 0)
    XCTAssertFalse(state.hasNext)
    XCTAssertFalse(state.needsExplicitContinuation)
  }
  @MainActor func testSparseEOFKeepsVisitedRowsWithoutAutomaticScanning() async throws {
    let http = SparseCatalogHTTP(fullPages: 5)
    let browser = MusicBrowser(service: try client(http))
    await browser.start()
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    for offset in stride(from: 40, through: 200, by: 40) {
      browser.continueListing(
        .later, scope: browser.scope, category: .albums, query: "",
        revision: browser.window.revision)
      try await settle { browser.window.pages[offset] != nil && !browser.window.loading }
    }
    XCTAssertEqual(browser.window.firstOffset, 0)
    XCTAssertFalse(browser.window.hasNext)
    XCTAssertFalse(browser.window.hasEarlier)
    XCTAssertFalse(browser.window.needsExplicitContinuation)
    let before = await http.offsets.count
    browser.continueListing(
      .earlier, scope: browser.scope, category: .albums, query: "",
      revision: browser.window.revision)
    await Task.yield()
    let after = await http.offsets.count
    XCTAssertEqual(after, before)
    XCTAssertTrue(browser.window.items.contains { $0.id == "accepted-80" })
    XCTAssertEqual(browser.window.pages.count, 6)
    browser.retire()
  }
  @MainActor func testSparseFilteredSearchHasTruthfulContinuationAndRejectsOldQueryRoot()
    async throws
  {
    for empty in [false, true] {
      let http = SparseCatalogHTTP(emptyFirst: empty)
      let parent = MusicBrowser(service: try client(http))
      await parent.start()
      try await settle { parent.resultsAreCurrent }
      let search = try XCTUnwrap(parent.searchBrowser())
      search.selectSearchCategory(.albums)
      search.updateSearchText("sparse")
      try await settle { search.resultsAreCurrent && !search.window.loading }
      XCTAssertEqual(search.window.items.count, empty ? 0 : 1)
      XCTAssertTrue(search.window.hasNext)
      XCTAssertTrue(search.window.needsExplicitContinuation)
      XCTAssertEqual(search.visibleSearchCategories, [.albums])
      let oldScope = search.scope
      let oldRevision = search.window.revision
      search.continueListing(
        .later, scope: oldScope, category: .albums, query: "sparse", revision: oldRevision)
      try await settle { search.window.items.contains { $0.id == "accepted-later" } }
      XCTAssertFalse(search.window.hasNext)
      search.updateSearchText("new")
      try await settle { search.resultsAreCurrent && !search.window.loading }
      let count = await http.offsets.count
      search.continueListing(
        .later, scope: oldScope, category: .albums, query: "sparse", revision: oldRevision)
      parent.retire()
      search.continueListing(
        .earlier, scope: oldScope, category: .albums, query: "new", revision: search.window.revision
      )
      await Task.yield()
      let after = await http.offsets.count
      XCTAssertEqual(count, after)
      XCTAssertTrue(search.searchWindow(.albums).items.isEmpty)
    }
  }
  @MainActor func testEmptyProjectedNeighborhoodDoesNotAutoScanAndRetryKeepsAcceptedData()
    async throws
  {
    let http = SparseCatalogHTTP(emptyFirst: true)
    let browser = MusicBrowser(service: try client(http))
    await browser.start()
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    XCTAssertTrue(browser.window.items.isEmpty)
    XCTAssertTrue(browser.window.hasNext)
    browser.boundaryVisibilityChanged(
      id: "missing", visible: true, scope: browser.scope, category: .albums, query: "",
      revision: browser.window.revision, direction: .later)
    try await Task.sleep(for: .milliseconds(20))
    var offsets = await http.offsets
    XCTAssertEqual(offsets, [0], "An empty projected neighborhood cannot auto-drain the server")
    await http.failNextPage()
    browser.loadMore()
    try await settle { browser.window.error != nil && !browser.window.loading }
    XCTAssertTrue(browser.window.hasNext)
    XCTAssertTrue(browser.window.loaded)
    browser.retryListing()
    try await settle { browser.window.items.contains { $0.id == "accepted-later" } }
    XCTAssertNil(browser.window.error)
    offsets = await http.offsets
    XCTAssertEqual(offsets, [0, 40, 40], "Retry owns the same raw boundary")
    browser.retire()
  }
  func testInventedBrowseFavoritesAndOrderingAreAppliedBeforePagination() async throws {
    let fixture = FixtureCatalog(source: URL(fileURLWithPath: "/invented/tone.wav"))
    for category in MusicCategory.allCases {
      let all = try await fixture.catalog(
        CatalogQuery(library: "fixture-music", category: category))
      let favorites = try await fixture.catalog(
        CatalogQuery(
          library: "fixture-music", category: category,
          options: CatalogBrowseOptions(favoritesOnly: true)))
      XCTAssertFalse(favorites.isEmpty)
      XCTAssertLessThan(favorites.count, all.count)
      let beyond = try await fixture.catalog(
        CatalogQuery(
          library: "fixture-music", category: category, offset: 40,
          options: CatalogBrowseOptions(favoritesOnly: true)))
      XCTAssertTrue(beyond.isEmpty)
      let reverse = try await fixture.catalog(
        CatalogQuery(
          library: "fixture-music", category: category,
          options: CatalogBrowseOptions(sort: .titleDescending)))
      XCTAssertNotEqual(all.first?.id, reverse.first?.id)
    }
  }
  @MainActor func testBrowseOptionsAreServerOwnedCategoryBoundedAndRejectLateReplies() async throws
  {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    let search = try XCTUnwrap(browser.searchBrowser())
    search.updateSearchText("independent")
    try await settle { search.resultsAreCurrent && !search.window.loading }
    let oldRevision = browser.window.revision
    await api.holdSort(.artist)
    browser.selectOptions(CatalogBrowseOptions(sort: .artist, favoritesOnly: true))
    XCTAssertTrue(browser.window.loading)
    for _ in 0..<100 {
      if await api.heldOptionCount() == 1 { break }
      await Task.yield()
    }
    browser.selectOptions(CatalogBrowseOptions(sort: .recentlyAdded))
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    let accepted = browser.window.items
    XCTAssertEqual(browser.window.options, CatalogBrowseOptions(sort: .recentlyAdded))
    XCTAssertNotEqual(browser.window.revision, oldRevision)
    await api.releaseSort()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(
      browser.window.items, accepted, "An ignored cancellation cannot relabel the successor window")
    XCTAssertEqual(search.options, CatalogBrowseOptions())
    XCTAssertTrue(search.resultsAreCurrent)
    browser.selectCategory(.artists)
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    browser.selectOptions(CatalogBrowseOptions(sort: .album))
    XCTAssertEqual(browser.options, CatalogBrowseOptions(), "Unsupported artist sorts are inert")
    browser.selectOptions(CatalogBrowseOptions(sort: .titleDescending, favoritesOnly: true))
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    browser.selectCategory(.albums)
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    XCTAssertEqual(browser.options.sort, .recentlyAdded)
    browser.selectLibrary("live")
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    XCTAssertEqual(
      browser.options, CatalogBrowseOptions(sort: .recentlyAdded, favoritesOnly: true),
      "Account-scoped preferences survive root selection; old replies remain rejected")
    browser.retire()
    XCTAssertTrue(browser.window.items.isEmpty)
  }
  func testEveryBrowseSortAndFavoriteMapsToRootedServerQuery() async throws {
    for category in MusicCategory.allCases {
      for sort in CatalogSort.choices(for: category) {
        let roots: [String: Any] = [
          "Items": [
            [
              "CollectionType": "music", "Type": "CollectionFolder", "Id": "music",
              "Name": "Invented",
            ]
          ]
        ]
        let http = CatalogHTTP([(200, roots), (200, ["Items": []]), (200, ["Items": []])])
        let api = try client(http)
        _ = try await api.catalog(
          CatalogQuery(
            library: "music", category: category, offset: 80,
            options: CatalogBrowseOptions(sort: sort, favoritesOnly: true)))
        let requests = await http.requests
        let request = try XCTUnwrap(requests.last)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        for field in [
          URLQueryItem(name: "ParentId", value: "music"),
          .init(name: "StartIndex", value: category == .artists ? "0" : "80"),
          .init(name: "Limit", value: "40"), .init(name: "SortBy", value: sort.field),
          .init(name: "SortOrder", value: sort.order),
          .init(
            name: category == .artists ? "IsFavorite" : "Filters",
            value: category == .artists ? "true" : "IsFavorite"),
        ] {
          XCTAssertTrue(query.contains(field), "Missing allowlisted wire field")
        }
      }
    }
  }
  @MainActor func testNearEdgePrefetchIsBoundedAndOldWindowVisibilityIsInert() async throws {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    let owner = browser.scope
    let revision = browser.window.revision
    let edge = browser.window.items[32].id
    for _ in 0..<10 {
      browser.boundaryVisibilityChanged(
        id: edge, visible: true, scope: owner, category: .albums, query: "", revision: revision,
        direction: .later)
    }
    try await settle { browser.window.pages[40] != nil && !browser.window.loading }
    let calls = await api.queries.filter { $0.shelf == nil }
    XCTAssertEqual(calls.map(\.offset), [0, 40])
    browser.boundaryVisibilityChanged(
      id: edge, visible: true, scope: owner, category: .albums, query: "", revision: revision,
      direction: .later)
    browser.selectOptions(CatalogBrowseOptions(sort: .titleDescending))
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    let count = await api.queries.count
    browser.boundaryVisibilityChanged(
      id: browser.window.items.last!.id, visible: true, scope: owner, category: .albums, query: "",
      revision: revision, direction: .later)
    try await Task.sleep(for: .milliseconds(20))
    let after = await api.queries.count
    XCTAssertEqual(
      count, after, "Visibility from the retired option window cannot page its replacement")
    browser.retire()
  }
  @MainActor func testSparseRawCatalogPageKeepsContinuationAfterProjection() async throws {
    let http = SparseCatalogHTTP()
    let browser = MusicBrowser(service: try client(http))
    await browser.start()
    try await settle { browser.window.loaded && !browser.window.loading }
    XCTAssertEqual(browser.window.items.map(\.id), ["accepted-first"])
    XCTAssertTrue(
      browser.window.hasNext, "A full raw page is not EOF after projection/deduplication")
    guard browser.window.hasNext else {
      browser.retire()
      return
    }
    browser.loadMore()
    try await settle { browser.window.items.contains { $0.id == "accepted-later" } }
    let offsets = await http.offsets
    XCTAssertEqual(offsets, [0, 40], "Continuation consumes raw records, never displayed count")
    XCTAssertFalse(browser.window.hasNext)
    XCTAssertEqual(browser.window.items.map(\.id), ["accepted-first", "accepted-later"])
    browser.retire()
  }
  @MainActor func testAcceptedRemovalRetiresProvenanceEvenWhenBrowsingAnotherAuthorizedRoot() async
  {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    var observedRoots: [[String]] = []
    browser.libraryRetired = { observedRoots.append(browser.libraries.map(\.id)) }
    browser.selectLibrary("live")
    XCTAssertEqual(observedRoots, [["music", "live"]], "Tab selection keeps both authorized roots")
    observedRoots = []
    await browser.loadLibraries()
    XCTAssertTrue(observedRoots.isEmpty, "Healthy refresh is not retirement")
    await api.setLibraries(["live"])
    await browser.loadLibraries()
    XCTAssertEqual(observedRoots, [["live"]], "Accepted removal must notify the existing owner")
    XCTAssertEqual(browser.libraryID, "live")
  }
  func testRecentAlbumStorageIsBoundedOrderedRootedAndLeaseOwned() async throws {
    let storage = LibraryStorage()
    let account = String(repeating: "a", count: 64)
    let other = String(repeating: "b", count: 64)
    let lease = await storage.lease(account: account)
    for index in 0..<30 {
      try await storage.acceptRecentAlbum(
        account: account, lease: lease, library: "music", album: "album-\(index)")
    }
    try await storage.acceptRecentAlbum(
      account: account, lease: lease, library: "live", album: "live-album")
    try await storage.acceptRecentAlbum(
      account: account, lease: lease, library: "music", album: "album-9")
    let music = try await storage.recentAlbums(account: account, library: "music")
    XCTAssertEqual(music.count, 24)
    XCTAssertEqual(music.first, "album-9")
    XCTAssertEqual(Set(music).count, music.count)
    let live = try await storage.recentAlbums(account: account, library: "live")
    XCTAssertEqual(live, ["live-album"])
    let isolated = try await storage.recentAlbums(account: other, library: "music")
    XCTAssertTrue(isolated.isEmpty)
    _ = await storage.lease(account: account)
    try await storage.acceptRecentAlbum(
      account: account, lease: lease, library: "music", album: "stale")
    let after = try await storage.recentAlbums(account: account, library: "music")
    XCTAssertEqual(after, music)
  }
  func testRecentAlbumsPreserveAcceptedOrderWhenActorArrivalsReverse() async throws {
    let storage = LibraryStorage()
    let account = String(repeating: "c", count: 64)
    let lease = await storage.lease(account: account)
    try await storage.acceptRecentAlbum(
      account: account, lease: lease, library: "music", album: "B", revision: 2)
    try await storage.acceptRecentAlbum(
      account: account, lease: lease, library: "music", album: "A", revision: 1)
    let ordered = try await storage.recentAlbums(account: account, library: "music")
    XCTAssertEqual(ordered, ["B", "A"])
    try await storage.acceptRecentAlbum(
      account: account, lease: lease, library: "music", album: "A", revision: 3)
    try await storage.acceptRecentAlbum(
      account: account, lease: lease, library: "music", album: "A", revision: 1)
    let deduplicated = try await storage.recentAlbums(account: account, library: "music")
    XCTAssertEqual(deduplicated, ["A", "B"])
  }
  @MainActor func testRecentAlbumProjectionRevalidatesOrderAndRejectsRetiredRoot() async throws {
    let api = FixtureCatalog(
      source: URL(string: "https://invented.invalid/audio")!, catalogDelay: .milliseconds(30))
    let browser = MusicBrowser(service: api)
    await browser.start()
    let original = browser.scope
    await browser.loadRecentAlbums(
      ["fixture-album-6", "missing", "fixture-album"], scope: original)
    XCTAssertEqual(browser.recentAlbums.map(\.id), ["fixture-album-6", "fixture-album"])
    let stale = Task { await browser.loadRecentAlbums(["fixture-album"], scope: original) }
    browser.selectLibrary("fixture-concerts")
    await stale.value
    XCTAssertTrue(browser.recentAlbums.isEmpty)
    await browser.loadRecentAlbums(["fixture-album", "fixture-album-3"], scope: browser.scope)
    XCTAssertEqual(browser.recentAlbums.map(\.id), ["fixture-album-3"])
    browser.retire()
    XCTAssertTrue(browser.recentAlbums.isEmpty)
  }
  func testAlbumDetailsAreBoundedAndUseSingleRootedValidation() async throws {
    let roots: [String: Any] = [
      "Items": [
        ["Id": "music", "Name": "Music", "Type": "CollectionFolder", "CollectionType": "music"]
      ]
    ]
    let http = CatalogHTTP([
      (200, roots),
      (
        200,
        [
          "Items": [
            [
              "Id": "fixture-album", "Type": "MusicAlbum", "Name": "Invented",
              "ProductionYear": 2001,
              "Genres": Array(repeating: "Ambient", count: 2) + (0..<20).map { "Genre \($0)" },
              "Overview": "<b>Invented notes</b> " + String(repeating: "quiet ", count: 1000),
            ]
          ]
        ]
      ),
      (
        200,
        [
          "Items": [
            ["Id": "track", "Type": "Audio", "Name": "Invented track", "ParentIndexNumber": 2]
          ]
        ]
      ),
    ])
    let page = try await client(http).albumDetail(library: "music", album: .fixtureAlbum)
    XCTAssertEqual(page.album.details?.year, 2001)
    XCTAssertEqual(page.album.details?.genres.count, 8)
    XCTAssertEqual(page.album.details?.genres.first, "Ambient")
    XCTAssertLessThanOrEqual(page.album.details?.overview?.count ?? 0, 4096)
    XCTAssertFalse(page.album.details?.overview?.contains("<b>") ?? true)
    XCTAssertEqual(page.tracks.first?.details?.disc, 2)
    let requests = await http.requests
    XCTAssertEqual(
      requests.count, 3,
      "Root discovery, one album proof and one track page; no duplicate album validation")
    let proof = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
    XCTAssertTrue(proof.contains { $0.name == "ParentId" && $0.value == "music" })
    XCTAssertTrue(proof.contains { $0.name == "Fields" && $0.value?.contains("Overview") == true })
    let track = URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)!.queryItems!
    XCTAssertFalse(track.contains { $0.name == "Fields" && $0.value?.contains("Overview") == true })
  }
  func testArtistDetailsRequireRootAssociationAndRejectNonMusicBeforeProtectedFields() async throws
  {
    let roots: [String: Any] = [
      "Items": [
        ["Id": "music", "Name": "Music", "Type": "CollectionFolder", "CollectionType": "music"]
      ]
    ]
    let evidence: [String: Any] = [
      "Items": [
        [
          "Id": "song", "Name": "Invented song", "Type": "Audio",
          "ArtistItems": [["Id": "artist", "Name": "Invented"]],
        ]
      ]
    ]
    let artist = MusicItem(
      id: "artist", title: "Invented", artist: "Invented", album: "", duration: 0, number: 0,
      kind: "MusicArtist", imageID: nil, imageTag: nil)
    let good = CatalogHTTP([
      (200, roots), (200, evidence),
      (
        200,
        [
          "Id": "artist", "Type": "MusicArtist", "Name": "Invented",
          "Overview": "<b>Artist notes</b>", "Genres": ["Ambient"],
        ]
      ),
    ])
    let fresh = try await client(good).artistDetail(library: "music", artist: artist)
    XCTAssertEqual(fresh.details?.overview, "Artist notes")
    let requests = await good.requests
    XCTAssertEqual(requests.last?.url?.path, "/base/Items/artist")
    XCTAssertTrue(
      URLComponents(url: requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains
      { $0.name == "UserId" && $0.value == "listener" })
    let noAssociation = CatalogHTTP([(200, roots), (200, ["Items": []])])
    do {
      _ = try await client(noAssociation).artistDetail(library: "music", artist: artist)
      XCTFail("unassociated artist accepted")
    } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
    let deniedRequests = await noAssociation.requests
    XCTAssertEqual(
      deniedRequests.count, 2, "No identity metadata request before Music association proof")
    let protected = CatalogHTTP([
      (200, roots), (200, evidence),
      (
        200,
        [
          "Type": "Book", "Id": ["getter-trap": true], "Name": 404,
          "Overview": ["getter-trap": true], "Genres": 404, "ProductionYear": [:],
        ]
      ),
    ])
    do {
      _ = try await client(protected).artistDetail(library: "music", artist: artist)
      XCTFail("nonmusic detail accepted")
    } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
  }
  @MainActor func testRecentLoadingReservesOnlySixKnownContextSlots() async throws {
    let api = FixtureCatalog(
      source: URL(string: "https://invented.invalid/audio")!, catalogDelay: .milliseconds(40))
    let browser = MusicBrowser(service: api)
    await browser.start()
    let ids = (0..<8).map { CatalogFixtures.album($0).id }
    let load = Task { await browser.loadRecentAlbums(ids, scope: browser.scope) }
    try await settle { browser.recentLoadingCount == 6 }
    XCTAssertTrue(browser.recentAlbums.isEmpty)
    await load.value
    XCTAssertEqual(browser.recentAlbums.map(\.id), Array(ids.prefix(6)))
    XCTAssertFalse(browser.recentAlbums.contains { $0.id == ids[6] })
    XCTAssertEqual(browser.recentLoadingCount, 0)
  }
  @MainActor func testArtistMetadataRetainsTransientButClearsCurrentDenialAndRejectsRetirement()
    async throws
  {
    let api = PagedCatalog()
    let parent = MusicBrowser(service: api)
    await parent.start()
    let artist = CatalogFixtures.artist(0)
    let browser = try XCTUnwrap(parent.artistBrowser(artist))
    await browser.loadArtistMetadata(artist)
    XCTAssertNotNil(browser.artistMetadata?.details?.overview)
    await api.configureArtist(.unavailable)
    await browser.loadArtistMetadata(artist)
    XCTAssertNotNil(browser.artistMetadata?.details?.overview)
    await api.configureArtist(.forbidden)
    await browser.loadArtistMetadata(artist)
    XCTAssertNil(browser.artistMetadata)
    await api.configureArtist(nil)
    await browser.loadArtistMetadata(artist)
    XCTAssertNotNil(browser.artistMetadata?.details?.overview)
    await api.configureArtist(nil, delay: .milliseconds(40))
    let late = Task { await browser.loadArtistMetadata(artist) }
    await Task.yield()
    parent.selectLibrary("live")
    XCTAssertNil(browser.artistMetadata, "An open sheet must immediately lose retired metadata")
    XCTAssertFalse(browser.metadataIsCurrent)
    await late.value
    XCTAssertNil(browser.artistMetadata)
  }
  private func client(_ http: any HTTPTransport) throws -> JellyfinClient {
    try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test/base"), userID: "listener", username: "Invented"
      ), token: "invented-token", deviceID: "test", transport: http)
  }
  func testArtistDirectoryMergesRootedAlbumAndTrackCreditsAcrossPagesAndSearch() async throws {
    let http = CatalogHTTP { request in
      let url = request.url!
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
      var rows: [[String: String]] = []
      if url.lastPathComponent == "UserViews" {
        rows = [
          ["Id": "music", "Type": "CollectionFolder", "CollectionType": "music", "Name": "Music"]
        ]
      } else if value("ParentId") == "music" {
        let tracks = url.lastPathComponent == "Artists" && value("IncludeItemTypes") == "Audio"
        let albums =
          url.lastPathComponent == "AlbumArtists" && value("IncludeItemTypes") == "MusicAlbum"
        var ids = (0..<85).filter {
          (tracks && !$0.isMultiple(of: 3)) || (albums && $0.isMultiple(of: 2))
        }
        if value("SortOrder") == "Descending" { ids.reverse() }
        rows = ids.map { String(format: "Performer %03d", $0) }
          .filter { value("SearchTerm").map($0.contains) ?? true }
          .dropFirst(Int(value("StartIndex")!)!).prefix(40)
          .map { ["Id": $0, "Type": "MusicArtist", "Name": $0, "SortName": $0] }
      }
      return HTTPReply(
        data: try! JSONSerialization.data(withJSONObject: ["Items": rows]), status: 200)
    }
    let api = try client(http)
    var query = CatalogQuery(library: "music", category: .artists)
    let first = try await api.catalog(query)
    query.offset = 40
    let second = try await api.catalog(query)
    let expected = (0..<85).filter { $0.isMultiple(of: 2) || !$0.isMultiple(of: 3) }.map {
      String(format: "Performer %03d", $0)
    }
    XCTAssertEqual((first + second).map(\.id), expected)
    query.offset = 0
    query.search = "Performer 00"
    query.options.sort = .titleDescending
    let search = try await api.catalog(query)
    XCTAssertEqual(search.map(\.id), expected.filter { $0.contains("Performer 00") }.reversed())
  }
  func testAppearancesKeepOnlyCreditedPerformancesAndGroupVersionsByReleaseID() async throws {
    let roots = [
      "Items": [
        ["Id": "music", "Name": "Music", "Type": "CollectionFolder", "CollectionType": "music"]
      ]
    ]
    func track(_ id: String, _ album: String, _ artists: [String], _ albumArtists: [String])
      -> [String: Any]
    {
      [
        "Id": id, "Name": id, "Type": "Audio", "Album": "Same title", "AlbumId": album,
        "ArtistItems": artists.map { ["Id": $0, "Name": $0] },
        "AlbumArtists": albumArtists.map { ["Id": $0, "Name": $0] },
      ]
    }
    let rows = [
      track("original", "one", ["performer", "guest"], ["ensemble"]),
      track("remaster", "one", ["guest"], ["ensemble"]),
      track("nothing", "one", ["other"], ["ensemble"]),
      track("own", "two", ["guest"], ["ensemble", "guest"]),
      track("different", "three", ["guest"], ["other"]),
      track("original", "one", ["guest"], ["ensemble"]),
    ]
    let http = CatalogHTTP([(200, roots), (200, ["Items": rows])])
    let raw = try await client(http).catalogPage(
      CatalogQuery(library: "music", category: .songs, artist: "guest", appearancesOnly: true))
    let page = ArtistAppearancePage(raw, offset: 0)
    XCTAssertEqual(raw.rawCount, 6)
    XCTAssertEqual(page.albums.map(\.id), ["one", "three"])
    XCTAssertEqual(
      page.albums.map { $0.tracks.map(\.id) }, [["original", "remaster"], ["different"]])
    let requests = await http.requests
    let query = URLComponents(url: requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
    XCTAssertTrue(query.contains(URLQueryItem(name: "ContributingArtistIds", value: "guest")))
    XCTAssertTrue(query.contains(URLQueryItem(name: "IncludeItemTypes", value: "Audio")))
    XCTAssertTrue(query.contains(URLQueryItem(name: "ParentId", value: "music")))
  }
  func testRootDiscriminantSkipsNonmusicProtectedGettersAndRejectsUnknownRootBeforeItems()
    async throws
  {
    let http = CatalogHTTP([
      (
        200,
        [
          "Items": [
            ["CollectionType": "books", "Id": ["getter-trap": true], "Name": 404, "Type": []],
            [
              "CollectionType": "music", "Type": "CollectionFolder", "Id": "music", "Name": "Music",
            ],
          ]
        ]
      )
    ])
    let api = try client(http)
    let roots = try await api.musicLibraries(refresh: true)
    XCTAssertEqual(roots, [MusicLibrary(id: "music", title: "Music")])
    do {
      _ = try await api.catalog(CatalogQuery(library: "not-music"))
      XCTFail("Unverified root accepted")
    } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
    let paths = await http.requests.map { $0.url!.path }
    XCTAssertEqual(paths, ["/base/UserViews"])
  }
  func testTypedMusicProjectionAndCanonicalMultipleRelationships() async throws {
    let http = CatalogHTTP([
      (
        200,
        [
          "Items": [
            ["CollectionType": "music", "Type": "CollectionFolder", "Id": "music", "Name": "Music"]
          ]
        ]
      ),
      (
        200,
        [
          "Items": [
            ["Type": "Book", "Id": ["getter-trap": true], "Name": []],
            [
              "Type": "Audio", "Id": "song", "Name": "Invented song", "AlbumId": "album",
              "Album": "Invented album",
              "ArtistItems": [["Id": "a", "Name": "One"], ["Id": "b", "Name": "Two"]],
              "AlbumArtists": [["Id": "a", "Name": "One"]],
            ],
          ]
        ]
      ),
    ])
    let api = try client(http)
    let rows = try await api.catalog(
      CatalogQuery(library: "music", category: .songs, offset: 80, search: "Invented"))
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].albumID, "album")
    XCTAssertEqual(rows[0].artistCredits?.map(\.id), ["a", "b"])
    let request = await http.requests.last!
    let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
    for pair in [
      URLQueryItem(name: "ParentId", value: "music"),
      .init(name: "IncludeItemTypes", value: "Audio"), .init(name: "Limit", value: "40"),
      .init(name: "StartIndex", value: "80"), .init(name: "SearchTerm", value: "Invented"),
      .init(name: "UserId", value: "listener"),
    ] { XCTAssertTrue(q.contains(pair)) }
  }
  func testPermissionDenialStopsBeforeAnyProtectedItemRequest() async throws {
    let http = CatalogHTTP([(403, [:])])
    let api = try client(http)
    do {
      _ = try await api.catalog(CatalogQuery(library: "music", category: .songs))
      XCTFail("Denied root accepted")
    } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
    let count = await http.requests.count
    XCTAssertEqual(count, 1)
  }
  @MainActor func testHundredThousandItemWindowForwardReverseAndStableVisibleAnchor() {
    let window = CatalogWindow()
    func page(_ offset: Int) -> [MusicItem] {
      (offset..<min(offset + 40, 100_000)).map {
        MusicItem(
          id: "\($0)", title: "Invented", artist: "Invented", album: "Invented", duration: 0,
          number: $0, kind: "Audio", imageID: nil, imageTag: nil)
      }
    }
    for offset in stride(from: 0, to: 100_000, by: 40) {
      window.anchor = window.items.last?.id
      let visible = window.anchor
      window.accept(page(offset), at: offset, query: "")
      XCTAssertEqual(window.items.count, offset + 40)
      XCTAssertEqual(window.pages.count, offset / 40 + 1)
      XCTAssertEqual(window.items[offset].id, String(offset))
      if let visible { XCTAssertNotNil(window.index(of: visible)) }
      XCTAssertEqual(window.firstOffset, 0)
    }
    window.accept([], at: 100_000, query: "")
    XCTAssertFalse(window.hasNext)
    for offset in stride(from: 99_880, through: 0, by: -40) {
      window.anchor = window.items.first?.id
      window.accept(page(offset), at: offset, query: "")
      XCTAssertEqual(window.items.count, 100_000)
      XCTAssertEqual(window.firstOffset, 0)
    }
    XCTAssertFalse(window.hasEarlier)
    XCTAssertEqual(window.items.first?.id, "0")
    XCTAssertEqual(Set(window.items.map(\.id)).count, 100_000)
    XCTAssertEqual(window.items.last?.id, "99999")
    window.accept([], at: 0, query: "new")
    XCTAssertTrue(window.items.isEmpty, "A retired query releases every visited metadata block")
  }
  @MainActor private func settle(_ predicate: () -> Bool) async throws {
    for _ in 0..<150 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(4))
    }
    XCTFail("Catalog did not settle")
  }
  @MainActor func testAlbumTracksBecomeReadyWithoutFetchingUnusedArtwork() async throws {
    let api = PagedCatalog()
    await api.delayArtwork(.seconds(1))
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.resultsAreCurrent }
    let detail = try XCTUnwrap(browser.detail(CatalogFixtures.album(0)))
    let loading = Task { await detail.load() }
    for _ in 0..<100 {
      if detail.tracks.count == 4 { break }
      try await Task.sleep(for: .milliseconds(4))
    }
    XCTAssertEqual(
      detail.tracks.count, 4, "Track readiness must not await an image owned by another view")
    await loading.value
    let images = await api.artworkCalls
    XCTAssertEqual(images, 0, "Album metadata must not download a second, unused image")
    await api.fail(.unavailable)
    await detail.load()
    XCTAssertEqual(detail.tracks.count, 4)
    XCTAssertNotNil(detail.error)
    await api.fail(nil)
    await detail.load()
    XCTAssertNil(detail.error)
    browser.retire()
    await detail.load()
    let retiredImages = await api.artworkCalls
    XCTAssertEqual(retiredImages, 0)
  }
  @MainActor func testRepeatedScrollAnchorDoesNotInvalidateAcceptedListingOrRequestPages()
    async throws
  {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    let first = try XCTUnwrap(browser.window.items.first?.id)
    let second = try XCTUnwrap(browser.window.items.dropFirst().first?.id)
    browser.setAnchor(first)
    let calls = await api.queries.count
    let invalidations = InvalidationCount()
    withObservationTracking {
      _ = browser.window
    } onChange: {
      invalidations.increment()
    }
    for _ in 0..<100 { browser.setAnchor(first) }
    XCTAssertEqual(
      invalidations.value, 0, "Unchanged ScrollPosition echoes must not republish the listing")
    XCTAssertEqual(browser.window.anchor, first)
    let afterNoop = await api.queries.count
    XCTAssertEqual(afterNoop, calls)
    browser.setAnchor(second)
    XCTAssertEqual(invalidations.value, 1, "A genuinely changed anchor must still publish")
    XCTAssertEqual(browser.window.anchor, second)
    browser.retire()
    XCTAssertTrue(browser.windows.isEmpty)
  }
  @MainActor func testLatestSearchCategoryRootAndAccountRetirementRejectLateResponses() async throws
  {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.window.loaded }
    browser.searchText = "old"
    browser.loadListing(force: true)
    try await Task.sleep(for: .milliseconds(10))
    browser.searchText = "new"
    browser.searchChanged()
    try await settle { browser.window.query == "new" && !browser.window.loading }
    XCTAssertTrue(browser.window.items.allSatisfy { $0.title.hasPrefix("new") })
    browser.selectCategory(.songs)
    try await settle { browser.resultsAreCurrent && !browser.window.loading }
    XCTAssertTrue(browser.window.items.allSatisfy { $0.kind == "Audio" })
    browser.searchText = "old"
    browser.loadListing(force: true)
    browser.selectLibrary("live")
    try await settle { browser.window.loaded }
    XCTAssertTrue(browser.window.items.allSatisfy { $0.id.hasPrefix("live") })
    browser.retire()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(browser.windows.isEmpty)
    XCTAssertTrue(browser.shelves.isEmpty)
    XCTAssertNil(browser.libraryID)
  }
  @MainActor func testSentinelDedupBoundedCategoryWindowsDiscoverStabilityAndPermissionRetirement()
    async throws
  {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.window.loaded && browser.shelves.values.filter(\.loaded).count == 2 }
    let discover = browser.shelves[.discover]?.items
    for _ in 0..<4 {
      let expected = browser.window.nextOffset
      for _ in 0..<10 { browser.loadMore() }
      try await settle { browser.window.pages[expected] != nil && !browser.window.loading }
    }
    XCTAssertEqual(browser.window.firstOffset, 0)
    browser.setAnchor(browser.window.items.first?.id)
    let retained = browser.window.anchor
    let beforeReverse = await api.queries.count
    browser.loadEarlier()
    await Task.yield()
    let afterReverse = await api.queries.count
    XCTAssertEqual(afterReverse, beforeReverse)
    XCTAssertEqual(browser.window.anchor, retained)
    browser.selectCategory(.artists)
    try await settle { browser.window.loaded }
    browser.selectCategory(.albums)
    XCTAssertEqual(browser.window.firstOffset, 0)
    browser.loadDashboard()
    XCTAssertEqual(browser.shelves[.discover]?.items, discover)
    let calls = await api.queries
    XCTAssertEqual(calls.filter { $0.shelf == .discover }.count, 1)
    XCTAssertEqual(
      calls.filter { $0.shelf == nil && $0.category == .albums && $0.offset == 40 }.count, 1)
    await api.fail(.forbidden)
    browser.loadListing(force: true)
    try await settle { browser.libraryID == nil }
    XCTAssertTrue(browser.windows.isEmpty)
    XCTAssertTrue(browser.shelves.isEmpty)
  }
  @MainActor func testDetailCancellationCanRetryAndDenialRetiresAcceptedCatalog() async throws {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.window.loaded }
    let detail = try XCTUnwrap(browser.detail(CatalogFixtures.album(0)))
    let task = Task { await detail.load() }
    try await Task.sleep(for: .milliseconds(5))
    task.cancel()
    await task.value
    XCTAssertFalse(detail.loading)
    XCTAssertTrue(detail.tracks.isEmpty)
    await detail.load()
    XCTAssertEqual(detail.tracks.count, 4)
    await api.fail(.forbidden)
    await detail.load()
    XCTAssertTrue(detail.tracks.isEmpty)
    XCTAssertNil(browser.libraryID)
    XCTAssertTrue(browser.windows.isEmpty)
  }
  @MainActor func testSearchStartsQuietThenLoadsAllTypesFromLiveChangesWithoutSubmit() async throws
  {
    let api = PagedCatalog()
    let parent = MusicBrowser(service: api)
    await parent.start()
    try await settle { parent.window.loaded }
    let before = await api.queries.count
    let search = try XCTUnwrap(parent.searchBrowser())
    try await Task.sleep(for: .milliseconds(30))
    let opened = await api.queries.count
    XCTAssertEqual(opened, before, "An empty search must not fetch the entire album catalog")
    search.searchText = "n"
    search.searchChanged()
    search.searchText = "new"
    search.searchChanged()
    try await settle {
      search.window.query == "new" && search.window.loaded
        && search.windows.values.allSatisfy { !$0.loading }
    }
    let requests = await api.queries.filter { $0.search == "new" }
    XCTAssertEqual(Set(requests.map(\.category)), Set(MusicCategory.allCases))
    XCTAssertEqual(requests.count, 3, "One bounded request per actual content type")
    XCTAssertEqual(search.windows.count, 3)
    XCTAssertTrue(search.windows.values.allSatisfy { $0.query == "new" && $0.items.count == 40 })
    let old = await api.queries.filter { $0.search == "n" }
    XCTAssertTrue(old.isEmpty, "Typing before the debounce expires cancels the earlier query")
    search.retire()
    parent.retire()
  }
  @MainActor func testMixedSearchRejectsHeldRepliesAndKeepsFilteredPagingBounded() async throws {
    let api = PagedCatalog()
    let parent = MusicBrowser(service: api)
    await parent.start()
    let search = try XCTUnwrap(parent.searchBrowser())
    do {
      await api.holdSearch("held")
      search.updateSearchText("held")
      for _ in 0..<150 {
        if await api.heldCount("held") == 3 { break }
        try await Task.sleep(for: .milliseconds(4))
      }
      let held = await api.heldCount("held")
      XCTAssertEqual(held, 3)
      search.updateSearchText("new")
      XCTAssertTrue(MusicCategory.allCases.allSatisfy { search.searchWindow($0).items.isEmpty })
      try await settle {
        search.windows.count == 3 && search.windows.values.allSatisfy { $0.loaded && !$0.loading }
      }
      await api.releaseSearches()
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertTrue(
        search.windows.values.allSatisfy { $0.items.allSatisfy { $0.title.hasPrefix("new") } })
      search.selectSearchCategory(.songs)
      for _ in 0..<4 {
        let offset = search.window.nextOffset
        search.loadMore()
        try await settle { search.window.pages[offset] != nil && !search.window.loading }
      }
      XCTAssertEqual(search.window.pages.count, 5)
      XCTAssertEqual(search.window.items.count, 200)
      let calls = await api.queries.count
      search.selectSearchCategory(nil)
      let after = await api.queries.count
      XCTAssertEqual(calls, after, "All previews reuse the accepted type histories")
      XCTAssertEqual(search.searchCategories.count, 3)
      search.updateSearchText("")
      XCTAssertTrue(search.windows.isEmpty)
      search.retire()
      parent.retire()
    } catch {
      await api.releaseSearches()
      search.retire()
      parent.retire()
      throw error
    }
  }
  @MainActor func testSearchRootBDetailAndRemovalReincarnationCannotUseMainAOrRetiredData()
    async throws
  {
    let api = PagedCatalog()
    let parent = MusicBrowser(service: api)
    await parent.start()
    let search = try XCTUnwrap(parent.searchBrowser())
    search.selectLibrary("live")
    search.updateSearchText("new")
    try await settle {
      search.windows.count == 3 && search.windows.values.allSatisfy { $0.loaded && !$0.loading }
    }
    let album = try XCTUnwrap(search.searchWindow(.albums).items.first)
    let detail = try XCTUnwrap(search.detail(album))
    XCTAssertEqual(detail.authorizedLibrary, "live")
    XCTAssertEqual(parent.authorizedLibrary, "music")
    let child = try XCTUnwrap(search.artistBrowser(CatalogFixtures.artist(3)))
    let beforeSwitch = try XCTUnwrap(child.detail(album))
    XCTAssertEqual(beforeSwitch.authorizedLibrary, "live")
    child.selectLibrary("music")
    XCTAssertNil(beforeSwitch.authorizedLibrary)
    let fromChildA = try XCTUnwrap(child.detail(album))
    await fromChildA.load()
    XCTAssertEqual(fromChildA.authorizedLibrary, "music")
    let detailRoots = await api.detailLibraries
    XCTAssertEqual(
      detailRoots.last, "music",
      "Artist child A owns the actual detail request; parent Search remains B")
    XCTAssertEqual(search.authorizedLibrary, "live")
    child.retire()
    XCTAssertNil(child.detail(album))
    XCTAssertNil(fromChildA.authorizedLibrary)
    let oldScope = parent.scope
    await parent.loadLibraries()
    XCTAssertEqual(parent.scope, oldScope, "A healthy refresh must not revoke accepted Search")
    await api.setLibraries(["music"])
    await parent.loadLibraries()
    XCTAssertFalse(search.metadataIsCurrent)
    XCTAssertTrue(search.searchCategories.isEmpty)
    XCTAssertTrue(search.searchWindow(.albums).items.isEmpty)
    XCTAssertNil(detail.authorizedLibrary)
    XCTAssertNil(search.detail(album))
    await api.setLibraries(["music", "live"])
    await parent.loadLibraries()
    XCTAssertFalse(search.metadataIsCurrent, "Same-ID reauthorization cannot revive an old route")
    let fresh = try XCTUnwrap(parent.searchBrowser())
    fresh.selectLibrary("live")
    fresh.updateSearchText("fresh")
    try await settle { fresh.windows.values.contains { $0.loaded } }
    parent.retire()
    XCTAssertTrue(fresh.searchCategories.isEmpty)
    XCTAssertNil(fresh.detail(album))
    let calls = await api.queries.count
    fresh.updateSearchText("retired")
    try await Task.sleep(for: .milliseconds(20))
    let after = await api.queries.count
    XCTAssertEqual(calls, after)
    XCTAssertTrue(fresh.windows.isEmpty)
    fresh.retire()
    search.retire()
  }
  @MainActor func testContextualFindUsesAcceptedChildRootAndRejectsRetiredSourceAtomically()
    async throws
  {
    let api = PagedCatalog()
    let parent = MusicBrowser(service: api)
    await parent.start()
    let search = try XCTUnwrap(parent.searchBrowser())
    defer {
      search.retire()
      parent.retire()
    }
    search.selectLibrary("live")
    let child = try XCTUnwrap(search.artistBrowser(CatalogFixtures.artist(3)))
    child.selectLibrary("music")
    let origin = child.scope
    XCTAssertTrue(search.seedSearch("new", category: .songs, from: child, scope: origin))
    XCTAssertEqual(search.authorizedLibrary, "music")
    XCTAssertEqual(search.searchText, "new")
    XCTAssertEqual(search.searchCategory, .songs)
    XCTAssertFalse(child.metadataIsCurrent, "Changing Search root retires its former child")
    search.selectLibrary("live")
    search.updateSearchText("successor")
    search.selectSearchCategory(.albums)
    try await settle { search.window.loaded && !search.window.loading }
    let successor = search.scope
    let count = await api.queries.count
    XCTAssertFalse(search.seedSearch("stale", category: .artists, from: child, scope: origin))
    XCTAssertEqual(search.scope, successor)
    XCTAssertEqual(search.authorizedLibrary, "live")
    XCTAssertEqual(search.searchText, "successor")
    XCTAssertEqual(search.searchCategory, .albums)
    XCTAssertFalse(search.seedSearch("stale", category: .songs, from: parent, scope: UUID()))
    try await Task.sleep(for: .milliseconds(20))
    let after = await api.queries.count
    XCTAssertEqual(after, count, "Rejected Find starts no provider read")
    parent.retire()
    XCTAssertFalse(
      search.seedSearch("retired", category: .artists, from: parent, scope: parent.scope))
    XCTAssertTrue(search.windows.isEmpty || !search.metadataIsCurrent)
  }
  @MainActor func testExactArtistMatchPrioritizesActualTypeWithoutInventingTopRank() async throws {
    let browser = MusicBrowser(
      service: FixtureCatalog(source: URL(string: "https://fixture.invalid/tone")!))
    await browser.start()
    let search = try XCTUnwrap(browser.searchBrowser())
    search.updateSearchText("North Window")
    try await settle {
      search.windows.count == 3 && search.windows.values.allSatisfy { $0.loaded && !$0.loading }
    }
    XCTAssertEqual(search.searchCategories.first, .artists)
    let artist = try XCTUnwrap(search.searchWindow(.artists).items.first)
    XCTAssertEqual(artist.imageID, artist.id)
    XCTAssertEqual(artist.imageTag, "portrait")
    let album = try XCTUnwrap(search.searchWindow(.albums).items.first)
    XCTAssertNotEqual(album.imageID, artist.imageID)
    search.retire()
    browser.retire()
  }
  func testArtistPrimaryProjectionNeverBorrowsAlbumArtAndSongFallbackRemainsAlbum() async throws {
    let http = CatalogHTTP([
      (
        200,
        [
          "Items": [
            ["Id": "music", "Name": "Music", "CollectionType": "music", "Type": "CollectionFolder"]
          ]
        ]
      ),
      (
        200,
        [
          "Items": [
            [
              "Id": "artist-own", "Name": "Own portrait", "Type": "MusicArtist",
              "ImageTags": ["Primary": "own"], "AlbumId": "album",
              "AlbumPrimaryImageTag": "album-tag",
            ],
            [
              "Id": "artist-missing", "Name": "Missing portrait", "Type": "MusicArtist",
              "AlbumId": "album", "AlbumPrimaryImageTag": "album-tag",
            ],
          ]
        ]
      ),
      (200, ["Items": [["Id": "artist-own", "Name": "Own portrait", "Type": "MusicArtist"]]]),
      (
        200,
        [
          "Items": [
            [
              "Id": "song", "Name": "Song", "Type": "Audio", "AlbumId": "album",
              "AlbumPrimaryImageTag": "album-tag",
            ]
          ]
        ]
      ),
    ])
    let api = try client(http)
    let artists = try await api.catalog(CatalogQuery(library: "music", category: .artists))
    XCTAssertEqual(artists[0].imageID, "artist-own")
    XCTAssertEqual(artists[0].imageTag, "own")
    XCTAssertNil(artists[1].imageID)
    XCTAssertNil(artists[1].imageTag)
    let songs = try await api.catalog(CatalogQuery(library: "music", category: .songs))
    XCTAssertEqual(songs[0].imageID, "album")
    XCTAssertEqual(songs[0].imageTag, "album-tag")
  }
  @MainActor func testMixedBatchAndSectionOrderStayStableAcrossReplyArrivalAndRefresh() async throws
  {
    let api = PagedCatalog()
    let parent = MusicBrowser(service: api)
    await parent.start()
    let search = try XCTUnwrap(parent.searchBrowser())
    do {
      await api.exactSearchCategory(.artists)
      await api.holdSearch("typed", categories: [.artists])
      search.updateSearchText("typed")
      for _ in 0..<150 {
        if await api.heldCount("typed") == 1 { break }
        try await Task.sleep(for: .milliseconds(4))
      }
      let held = await api.heldCount("typed")
      XCTAssertEqual(held, 1)
      XCTAssertTrue(
        search.windows.values.allSatisfy { !$0.loaded },
        "Faster replies cannot expose tappable content before initial ordering")
      await api.releaseSearches()
      try await settle {
        search.windows.count == 3 && search.windows.values.allSatisfy { $0.loaded && !$0.loading }
      }
      XCTAssertEqual(search.searchCategories.first, .artists)
      let order = search.searchCategories
      let rows = search.searchWindow(.artists).items
      await api.exactSearchCategory(.songs)
      search.loadSearch(force: true)
      XCTAssertEqual(search.searchCategories, order)
      XCTAssertEqual(
        search.searchWindow(.artists).items, rows, "Same-query refresh retains accepted content")
      try await settle { search.windows.values.allSatisfy { !$0.loading } }
      XCTAssertEqual(
        search.searchCategories, order, "A refreshed match cannot move a focused section")
      await api.fail(.unavailable)
      search.loadSearch(force: true)
      try await settle { search.windows.values.allSatisfy { !$0.loading } }
      XCTAssertTrue(search.windows.values.allSatisfy { $0.error != nil && !$0.items.isEmpty })
      await api.fail(.forbidden)
      search.loadSearch()
      try await settle { search.libraryID == nil }
      XCTAssertTrue(search.windows.isEmpty)
      XCTAssertTrue(search.searchCategories.isEmpty)
      parent.retire()
    } catch {
      await api.releaseSearches()
      search.retire()
      parent.retire()
      throw error
    }
  }
  @MainActor func testLoadedEmptySearchTypeDoesNotReenterGeometryDuringHeldRefresh() async throws {
    let api = PagedCatalog()
    await api.emptySearchCategories([.songs])
    let parent = MusicBrowser(service: api)
    await parent.start()
    let search = try XCTUnwrap(parent.searchBrowser())
    do {
      search.updateSearchText("typed")
      try await settle {
        search.windows.count == 3 && search.windows.values.allSatisfy { $0.loaded && !$0.loading }
      }
      let visible = search.visibleSearchCategories
      XCTAssertEqual(visible, [.albums, .artists])
      let albums = search.searchWindow(.albums).items
      await api.holdSearch("typed", categories: [.songs])
      search.loadSearch(force: true)
      for _ in 0..<150 {
        if await api.heldCount("typed") == 1 { break }
        try await Task.sleep(for: .milliseconds(4))
      }
      XCTAssertTrue(search.searchWindow(.songs).loading)
      XCTAssertEqual(search.visibleSearchCategories, visible)
      XCTAssertFalse(
        search.needsSearchSkeleton(.songs),
        "A loaded-empty type must not insert four placeholder rows above accepted content")
      XCTAssertFalse(search.needsSearchSkeleton(.albums))
      XCTAssertEqual(search.searchWindow(.albums).items, albums)
      await api.releaseSearches()
      try await settle { search.windows.values.allSatisfy { !$0.loading } }
      XCTAssertEqual(search.visibleSearchCategories, visible)
      search.retire()
      parent.retire()
    } catch {
      await api.releaseSearches()
      search.retire()
      parent.retire()
      throw error
    }
  }
  func testInventedSharedArtistHasAnAOnlyAlbumThatRejectsOldParentBDetail() async throws {
    let api = FixtureCatalog(source: URL(string: "https://fixture.invalid/tone")!)
    let artist = CatalogFixtures.artist(1)
    let aOnly = CatalogFixtures.album(1)
    let a = try await api.catalog(CatalogQuery(library: "fixture-music", artist: artist.id))
    let b = try await api.catalog(CatalogQuery(library: "fixture-concerts", artist: artist.id))
    XCTAssertTrue(a.contains { $0.id == aOnly.id })
    XCTAssertFalse(b.contains { $0.id == aOnly.id })
    XCTAssertTrue(
      b.contains { $0.id == "fixture-album-3" }, "The artist remains genuinely available in B")
    let bArtist = try await api.artistDetail(library: "fixture-concerts", artist: artist)
    XCTAssertEqual(bArtist.id, artist.id)
    do {
      _ = try await api.albumDetail(library: "fixture-concerts", album: aOnly)
      XCTFail("A stale parent B must not load this A-only selection")
    } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
    let aDetail = try await api.albumDetail(library: "fixture-music", album: aOnly)
    XCTAssertEqual(aDetail.tracks.count, 4)
  }
  @MainActor func testGlobalSearchOwnsIndependentBoundedWindowsAndRetiresAtRootChange() async throws
  {
    let api = PagedCatalog()
    let parent = MusicBrowser(service: api)
    await parent.start()
    try await settle { parent.window.loaded }
    let accepted = parent.window.items
    let search = try XCTUnwrap(parent.searchBrowser())
    search.searchText = "new"
    search.searchChanged()
    try await settle { search.window.query == "new" && !search.window.loading }
    search.selectCategory(.songs)
    try await settle { search.resultsAreCurrent && !search.window.loading }
    XCTAssertTrue(search.window.items.allSatisfy { $0.kind == "Audio" })
    XCTAssertEqual(parent.window.items, accepted)
    XCTAssertEqual(parent.searchText, "")
    parent.selectLibrary("live")
    try await settle { parent.window.loaded }
    let before = await api.queries.count
    search.searchText = "retired"
    search.searchChanged()
    try await Task.sleep(for: .milliseconds(40))
    let after = await api.queries.count
    XCTAssertEqual(before, after)
    search.retire()
    XCTAssertTrue(search.windows.isEmpty)
  }
  @MainActor func testLargeCanonicalAlbumPreservesEveryStableRowAndSelectionAfterReload()
    async throws
  {
    let api = PagedCatalog()
    await api.largeAlbum(2_000)
    let store = PlayerStore(
      storage: LibraryStorage(), vault: MemoryVault(), driver: DriverSpy(),
      deviceID: "invented-large")
    await store.enterFixture(service: api)
    let browser = try XCTUnwrap(store.browser)
    await browser.start()
    let content = try XCTUnwrap(browser.detail(CatalogFixtures.album(0)))
    await content.load()
    let ids = content.tracks.map(\.id)
    XCTAssertEqual(ids.count, 2_000)
    XCTAssertEqual(Set(ids).count, 2_000)
    XCTAssertEqual(content.tracks.map(\.number), Array(1...2_000))
    XCTAssertTrue(content.tracks.allSatisfy { $0.albumID == CatalogFixtures.album(0).id })
    let selection = try XCTUnwrap(
      store.playbackSelection(content.tracks, library: content.authorizedLibrary))
    XCTAssertEqual(selection.items.map(\.id), ids)
    XCTAssertEqual(selection.items[1_999].id, "large-track-1999")
    await content.load()
    XCTAssertEqual(
      content.tracks.map(\.id), ids, "Reload cannot replace stable ForEach identity with indices")
    await store.logout()
    XCTAssertNil(content.authorizedLibrary)
    store.playSelection(selection)
    XCTAssertNil(store.current, "Retired large-album selection must stay inert")
  }
  @MainActor func testBrowserStartAvoidsDuplicateRequestAndReturningRootRefetches() async throws {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.window.loaded }
    let accepted = browser.window.items
    await browser.start()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(browser.window.items, accepted)
    let firstRequests = await api.queries.filter {
      $0.library == "music" && $0.category == .albums && $0.shelf == nil && $0.offset == 0
    }.count
    XCTAssertEqual(firstRequests, 1, "One canonical owner fetches the first page exactly once")
    browser.selectLibrary("live")
    try await settle { browser.window.loaded }
    browser.selectLibrary("music")
    try await settle { browser.window.loaded }
    let after = await api.queries.filter {
      $0.library == "music" && $0.category == .albums && $0.shelf == nil && $0.offset == 0
    }.count
    XCTAssertEqual(
      after, 2, "Returning queries the current root instead of resurrecting old content")
    browser.retire()
  }
  @MainActor func testQueriedAndRetiredBrowsersOnlyPublishTheirCurrentRoot() async throws {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.window.loaded }
    XCTAssertTrue(browser.window.items.allSatisfy { $0.id.hasPrefix("music") })
    browser.selectLibrary("live")
    try await settle { browser.window.loaded }
    XCTAssertEqual(browser.window.items.count, 40)
    XCTAssertTrue(browser.window.items.allSatisfy { $0.id.hasPrefix("live") })
    browser.retire()
    let queried = MusicBrowser(service: api)
    queried.searchText = "new"
    queried.searchChanged()
    await queried.start()
    try await settle { queried.window.loaded }
    XCTAssertTrue(queried.window.items.allSatisfy { $0.id.hasPrefix("musicnew") })
    queried.retire()
    var current = false
    let retired = MusicBrowser(service: api, isCurrent: { current })
    let before = await api.queries.count
    await retired.start()
    current = true
    await retired.start()
    try await Task.sleep(for: .milliseconds(20))
    let after = await api.queries.count
    XCTAssertEqual(before, after)
    XCTAssertTrue(retired.windows.isEmpty)
    XCTAssertNil(retired.libraryID)
  }
  @MainActor func testVisibleBoundaryOwnsReloadAndRejectsOffscreenInteriorStaleAndDuplicateEvents()
    async throws
  {
    let api = PagedCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.window.loaded && browser.shelves.values.filter(\.loaded).count == 2 }
    let scope = browser.scope
    let initial = await api.queries.count
    browser.boundaryVisibilityChanged(
      id: browser.window.items[20].id, visible: true, scope: scope, category: .albums, query: "",
      revision: browser.window.revision, direction: .later)
    browser.boundaryVisibilityChanged(
      id: browser.window.items.last!.id, visible: false, scope: scope, category: .albums, query: "",
      revision: browser.window.revision, direction: .later)
    browser.boundaryVisibilityChanged(
      id: browser.window.items.first!.id, visible: true, scope: scope, category: .albums, query: "",
      revision: browser.window.revision, direction: .later)
    try await Task.sleep(for: .milliseconds(20))
    let unchanged = await api.queries.count
    XCTAssertEqual(unchanged, initial)
    for offset in [40, 80, 120] {
      let last = browser.window.items.last!.id
      for _ in 0..<8 {
        browser.boundaryVisibilityChanged(
          id: last, visible: true, scope: scope, category: .albums, query: "",
          revision: browser.window.revision, direction: .later)
      }
      try await settle { browser.window.pages[offset] != nil && !browser.window.loading }
    }
    let queries = await api.queries
    for offset in [40, 80, 120] {
      XCTAssertEqual(queries.filter { $0.offset == offset && $0.shelf == nil }.count, 1)
    }
    XCTAssertEqual(browser.window.firstOffset, 0)
    let first = browser.window.items.first!.id
    let before = await api.queries.count
    browser.boundaryVisibilityChanged(
      id: first, visible: false, scope: scope, category: .albums, query: "",
      revision: browser.window.revision, direction: .earlier)
    browser.boundaryVisibilityChanged(
      id: first, visible: true, scope: UUID(), category: .albums, query: "",
      revision: browser.window.revision, direction: .earlier)
    browser.boundaryVisibilityChanged(
      id: first, visible: true, scope: scope, category: .songs, query: "",
      revision: browser.window.revision, direction: .earlier)
    browser.boundaryVisibilityChanged(
      id: first, visible: true, scope: scope, category: .albums, query: "retired",
      revision: browser.window.revision, direction: .earlier)
    try await Task.sleep(for: .milliseconds(20))
    let rejected = await api.queries.count
    XCTAssertEqual(rejected, before)
    browser.setAnchor(first)
    browser.boundaryVisibilityChanged(
      id: first, visible: true, scope: scope, category: .albums, query: "",
      revision: browser.window.revision, direction: .earlier)
    try await settle { browser.window.firstOffset == 0 && !browser.window.loading }
    XCTAssertEqual(browser.window.anchor, first)
    XCTAssertFalse(browser.window.hasEarlier)
    browser.retire()
  }
  func testInventedLibraryTabsHaveDistinctMembershipAndSingleRoot() async throws {
    let source = URL(fileURLWithPath: "/invented/tone.wav")
    let api = FixtureCatalog(source: source)
    let roots = try await api.musicLibraries(refresh: false)
    XCTAssertEqual(roots.map(\.id), ["fixture-music", "fixture-concerts"])
    let music = try await api.catalog(CatalogQuery(library: "fixture-music", category: .albums))
    let live = try await api.catalog(CatalogQuery(library: "fixture-concerts", category: .albums))
    XCTAssertTrue(music.contains(where: { $0.id == "fixture-album" }))
    XCTAssertFalse(live.contains(where: { $0.id == "fixture-album" }))
    XCTAssertEqual(live.count, 22)
    XCTAssertTrue(live.contains(where: { $0.id == "fixture-album-2" }))
    XCTAssertTrue(live.contains(where: { $0.id == "fixture-album-3" }))
    XCTAssertTrue(
      live.allSatisfy { $0.artistCredits?.contains(where: { $0.id == "fixture-artist-3" }) == true }
    )
    let single = try await FixtureCatalog(source: source, singleLibrary: true).musicLibraries(
      refresh: false)
    XCTAssertEqual(single.map(\.id), ["fixture-music"])
    do {
      _ = try await FixtureCatalog(source: source, singleLibrary: true).catalog(
        CatalogQuery(library: "fixture-concerts", category: .albums))
      XCTFail("An unavailable invented root must be rejected")
    } catch {
      XCTAssertEqual(error as? ClientError, .forbidden)
    }
  }
  func testBoundedSongUIFixtureDoesNotChangeDefaultCatalog() async throws {
    let source = URL(fileURLWithPath: "/invented/tone.wav")
    let normal = FixtureCatalog(source: source)
    let bounded = FixtureCatalog(source: source, catalogSongLimit: 160)
    let normalTail = try await normal.catalog(
      CatalogQuery(library: "fixture-music", category: .songs, offset: 480))
    let fourthPage = try await bounded.catalog(
      CatalogQuery(library: "fixture-music", category: .songs, offset: 120))
    let end = try await bounded.catalog(
      CatalogQuery(library: "fixture-music", category: .songs, offset: 160))
    XCTAssertEqual(normalTail.count, 24)
    XCTAssertEqual(fourthPage.count, 40)
    XCTAssertTrue(end.isEmpty)
  }
  func testLongAlbumFixtureAdvertisesAndResolvesItsLastTrackOnlyWhenEnabled() async throws {
    let url = URL(fileURLWithPath: "/invented/tone.wav")
    let normal = FixtureCatalog(source: url)
    let extended = FixtureCatalog(source: url, longAlbum: true)
    let album = CatalogFixtures.album(3)
    let page = try await extended.albumDetail(library: "fixture-music", album: album)
    XCTAssertEqual(page.tracks.count, 18)
    XCTAssertEqual(page.album.duration, page.tracks.reduce(0) { $0 + $1.duration })
    let last = try XCTUnwrap(page.tracks.last)
    let extendedMatches = try await extended.validate(ids: [last.id])
    let normalMatches = try await normal.validate(ids: [last.id])
    XCTAssertEqual(extendedMatches, [last])
    XCTAssertTrue(normalMatches.isEmpty)
  }

  func testLegacyPersistedTrackDecodeAndAlbumRelationshipInheritance() throws {
    let data = Data(
      #"{"id":"song","title":"Invented","artist":"Invented","album":"Invented","duration":18,"number":1,"kind":"Audio"}"#
        .utf8)
    let item = try JSONDecoder().decode(MusicItem.self, from: data)
    XCTAssertNil(item.albumID)
    let inherited = item.inheritingArtwork(from: CatalogFixtures.album(2))
    XCTAssertEqual(inherited.albumID, "fixture-album-2")
    XCTAssertEqual(inherited.artistCredits?.count, 2)
  }
}

private actor AlbumMutationCatalog: MusicCatalogServing {
  private(set) var writes: [Bool] = []
  private var replies: [Int: CheckedContinuation<Bool, any Error>] = [:]
  private var heldRead: CheckedContinuation<MusicAlbumPage, Never>?
  private var holdRead = false
  private var capturedRead: MusicAlbumPage?
  private var favorite = false
  private var holdFavorite = false
  private var shelfWaiter: ([MusicItem], CheckedContinuation<[MusicItem], Never>)?
  private(set) var queries: [CatalogQuery] = []
  var shelfWaiting: Bool { shelfWaiter != nil }
  func holdNextFavoriteShelf() { holdFavorite = true }
  func releaseFavoriteShelf() {
    if let (items, waiter) = shelfWaiter { waiter.resume(returning: items) }
    shelfWaiter = nil
  }
  private(set) var readWaiting = false
  func holdNextRead() { holdRead = true }
  func releaseRead() {
    heldRead?.resume(returning: capturedRead ?? page)
    capturedRead = nil
    heldRead = nil
  }
  func releaseWrite(_ index: Int, value: Bool? = nil) {
    if let value {
      favorite = value
      replies.removeValue(forKey: index)?.resume(returning: value)
    } else {
      replies.removeValue(forKey: index)?.resume(throwing: PlaybackProblem.httpStatus(503))
    }
  }
  private var page: MusicAlbumPage {
    var album = MusicItem.fixtureAlbum
    album.favorite = favorite
    return MusicAlbumPage(album: album, tracks: MusicItem.fixtureTracks)
  }
  func verifyIdentity() async throws {}
  func validate(ids: [String]) async throws -> [MusicItem] { MusicItem.fixtureTracks }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    MediaSource(url: URL(string: "https://invented.invalid/tone")!, quality: quality)
  }
  func artwork(item: MusicItem) async throws -> Data? { nil }
  func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
    [.init(id: "music", title: "Invented")]
  }
  func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
    queries.append(query)
    let items =
      query.offset == 0 && (!(query.options.favoritesOnly || query.shelf == .favorites) || favorite)
      ? [page.album] : []
    if query.shelf == .favorites && holdFavorite {
      holdFavorite = false
      return await withCheckedContinuation { shelfWaiter = (items, $0) }
    }
    return items
  }
  func albumTracks(library: String, album: String) async throws -> [MusicItem] { page.tracks }
  func albumDetail(library: String, album: MusicItem) async throws -> MusicAlbumPage {
    if holdRead {
      holdRead = false
      capturedRead = page
      readWaiting = true
      return await withCheckedContinuation { heldRead = $0 }
    }
    return page
  }
  func setFavorite(
    library: String, item: MusicItem, value: Bool,
    isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
  ) async throws -> Bool {
    guard await isCurrent() else { throw CancellationError() }
    writes.append(value)
    let index = writes.count
    return try await withCheckedThrowingContinuation { replies[index] = $0 }
  }
}
extension CatalogTests {
  func testOptionalMetadataKeepsEntityDatesHonestAndOmitsUnsafeLinksWithoutLosingAlbum()
    async throws
  {
    let roots: [String: Any] = [
      "Items": [
        ["Id": "music", "Name": "Music", "Type": "CollectionFolder", "CollectionType": "music"]
      ]
    ]
    let id = "e505f6a9-c645-444a-84c8-9fcb702a6aef"
    let http = CatalogHTTP([
      (200, roots),
      (
        200,
        [
          "Items": [
            [
              "Id": "fixture-album", "Type": "MusicAlbum", "Name": "Invented",
              "ProductionYear": 1990,
              "PremiereDate": "1990-01-01T00:00:00Z",
              "Studios": [["Name": "<b>Invented label</b>"]],
              "People": [
                ["Name": "Invented Composer", "Type": "Composer"],
                ["Name": "Hidden", "Type": "Unknown"],
              ],
              "ProviderIds": ["MusicBrainzAlbum": id],
              "ExternalUrls": [
                ["Url": "https://musicbrainz.org/release/" + id + "?api_key=private"],
                ["Url": "https://untrusted.invalid/private"],
                ["Url": "https://en.wikipedia.org/wiki/Invented_album"],
              ],
            ]
          ]
        ]
      ), (200, ["Items": []]),
    ])
    let page = try await client(http).albumDetail(library: "music", album: .fixtureAlbum)
    let details = try XCTUnwrap(page.album.details)
    XCTAssertEqual(details.releaseYear(for: "MusicAlbum"), 1990)
    XCTAssertNil(details.releaseYear(for: "MusicArtist"))
    XCTAssertFalse(MusicDetails(year: 1947).hasContent(for: "MusicArtist"))
    XCTAssertEqual(details.labels, ["Invented label"])
    XCTAssertEqual(details.credits.count, 1)
    XCTAssertEqual(details.links.count, 2)
    XCTAssertTrue(details.links.allSatisfy { $0.url.query == nil && $0.url.user == nil })
    XCTAssertNil(page.album.favorite, "Missing UserData is unknown, never confirmed false")
    let legacy = try JSONDecoder().decode(
      MusicDetails.self, from: Data(#"{"year":1990,"genres":[],"overview":null,"disc":1}"#.utf8))
    XCTAssertEqual(legacy.year, 1990)
    XCTAssertTrue(legacy.links.isEmpty, "Existing persisted queues remain decodable")
    let malformed = CatalogHTTP([
      (200, roots),
      (
        200,
        [
          "Items": [
            [
              "Id": "fixture-album", "Type": "MusicAlbum", "Studios": [["Name": 7]], "People": true,
              "ProviderIds": ["MusicBrainzAlbum": 8], "UserData": ["IsFavorite": "not-a-bool"],
            ]
          ]
        ]
      ), (200, ["Items": []]),
    ])
    let usable = try await client(malformed).albumDetail(library: "music", album: .fixtureAlbum)
    XCTAssertEqual(usable.album.id, "fixture-album")
    XCTAssertTrue(usable.album.details?.labels.isEmpty == true)
    XCTAssertNil(usable.album.favorite)
  }
  func testFavoriteWireUsesCurrentUserAndRootProofBeforePostOrDelete() async throws {
    let roots: [String: Any] = [
      "Items": [
        ["Id": "music", "Name": "Music", "Type": "CollectionFolder", "CollectionType": "music"]
      ]
    ]
    let proof: [String: Any] = ["Items": [["Id": "fixture-album", "Type": "MusicAlbum"]]]
    let http = CatalogHTTP([
      (200, roots), (200, proof), (200, ["IsFavorite": true]), (200, proof),
      (200, ["IsFavorite": false]),
    ])
    let api = try client(http)
    let marked = try await api.setFavorite(library: "music", item: .fixtureAlbum, value: true)
    let cleared = try await api.setFavorite(library: "music", item: .fixtureAlbum, value: false)
    XCTAssertTrue(marked)
    XCTAssertFalse(cleared)
    let calls = await http.requests
    XCTAssertEqual(calls.map(\.httpMethod), ["GET", "GET", "POST", "GET", "DELETE"])
    XCTAssertTrue(calls[2].url!.path.hasSuffix("UserFavoriteItems/fixture-album"))
    XCTAssertTrue(
      URLComponents(url: calls[2].url!, resolvingAgainstBaseURL: false)!.queryItems!.contains {
        $0.name == "UserId" && $0.value == "listener"
      })
    let denied = CatalogHTTP([(200, roots), (200, ["Items": []])])
    do {
      _ = try await client(denied).setFavorite(library: "music", item: .fixtureAlbum, value: true)
      XCTFail("Denied root must not write")
    } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
    let deniedCalls = await denied.requests
    XCTAssertFalse(deniedCalls.contains { $0.httpMethod == "POST" })
  }
  @MainActor func testFavoriteSerialWriterFailureRetirementAndHeldReadCannotOverwriteConfirmation()
    async throws
  {
    let service = AlbumMutationCatalog()
    let life = RenderLifetimeProbe()
    let content = AlbumContent(
      album: .fixtureAlbum, library: "music", service: service, isCurrent: { life.live })
    await content.load()
    await service.holdNextRead()
    let read = Task { await content.load() }
    try await waitForDetail { await service.readWaiting }
    content.toggleFavorite()
    try await waitForDetail { await service.writes.count == 1 }
    await service.releaseWrite(1, value: true)
    try await waitForDetail { !content.favoritePending }
    await service.releaseRead()
    await read.value
    XCTAssertEqual(
      content.favoriteValue, true, "Read begun before write cannot replace confirmed truth")
    content.toggleFavorite()
    try await waitForDetail { await service.writes.count == 2 }
    content.toggleFavorite()
    content.toggleFavorite()
    await service.releaseWrite(2)
    try await waitForDetail { !content.favoritePending }
    XCTAssertEqual(content.favoriteValue, true)
    XCTAssertNotNil(content.favoriteError)
    content.toggleFavorite()
    try await waitForDetail { await service.writes.count == 3 }
    life.live = false
    await service.releaseWrite(3, value: false)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertNil(content.favoriteValue)
    XCTAssertEqual(content.album.favorite, true, "Retired response cannot publish protected data")
  }
  func testTrackInformationIsLazyRootedAndDoesNotClaimOutputQuality() async throws {
    let roots: [String: Any] = [
      "Items": [
        ["Id": "music", "Name": "Music", "Type": "CollectionFolder", "CollectionType": "music"]
      ]
    ]
    let http = CatalogHTTP([
      (200, roots), (200, ["Items": [["Id": "track", "Type": "Audio"]]]),
      (
        200,
        [
          "Id": "track", "Type": "Audio",
          "MediaStreams": [
            [
              "Type": "Audio", "Codec": "flac", "SampleRate": 96000, "BitDepth": 24, "Channels": 2,
              "BitRate": 0,
            ]
          ],
        ]
      ),
    ])
    var track = MusicItem.fixtureTracks[0]
    track = MusicItem(
      id: "track", title: track.title, artist: track.artist, album: track.album,
      duration: track.duration, number: 1, kind: "Audio", imageID: nil, imageTag: nil)
    let info = try await client(http).trackInformation(library: "music", track: track)
    XCTAssertEqual(info.codec, "FLAC")
    XCTAssertEqual(info.sampleRate, 96000)
    XCTAssertEqual(info.bitDepth, 24)
    XCTAssertNil(info.bitRate)
    let calls = await http.requests
    XCTAssertEqual(calls.count, 3)
    XCTAssertEqual(calls.last?.url?.lastPathComponent, "track")
  }
}

extension CatalogTests {
  @MainActor func testHeldFavoriteRootProofRejectsRetiredIntentAndPermissionRefreshBeforeWrite()
    async throws
  {
    let roots: [String: Any] = [
      "Items": [
        ["Id": "music", "Name": "Invented", "Type": "CollectionFolder", "CollectionType": "music"]
      ]
    ]
    for permissionRefresh in [false, true] {
      let http = CatalogHTTP([(200, roots), (200, ["Items": []])])
      let api = try client(http)
      _ = try await api.musicLibraries(refresh: false)
      await http.holdNextItems()
      let life = RenderLifetimeProbe()
      let write = Task {
        try await api.setFavorite(
          library: "music", item: .fixtureAlbum, value: true, isCurrent: { life.live })
      }
      try await waitForDetail { await http.itemWaiting }
      let waiting = await http.itemWaiting
      XCTAssertTrue(waiting)
      if permissionRefresh {
        _ = try await api.musicLibraries(refresh: true)
      } else {
        life.live = false
      }
      await http.releaseItems()
      do {
        _ = try await write.value
        XCTFail("Retired proof must not mutate")
      } catch { XCTAssertTrue(error is CancellationError) }
      let calls = await http.requests
      XCTAssertFalse(calls.contains { $0.httpMethod == "POST" || $0.httpMethod == "DELETE" })
    }
  }
  @MainActor
  func testFavoriteWriteRefreshesExistingFavoriteQueriesButKeepsDiscoverAndSearchIndependent()
    async throws
  {
    let fixture = FixtureCatalog(source: URL(fileURLWithPath: "/invented/tone.wav"))
    let browser = MusicBrowser(service: fixture)
    await browser.start()
    browser.loadDashboard()
    try await waitForDetail {
      browser.shelves[.discover]?.loaded == true && browser.shelves[.favorites]?.loaded == true
    }
    let discover = try XCTUnwrap(browser.shelves[.discover]?.items)
    let target = CatalogFixtures.album(1)
    let content = try XCTUnwrap(browser.detail(target))
    await content.load()
    XCTAssertEqual(content.favoriteValue, true)
    let search = try XCTUnwrap(browser.searchBrowser())
    search.searchText = "Invented"
    search.searchChanged()
    browser.selectOptions(CatalogBrowseOptions(favoritesOnly: true))
    try await waitForDetail { browser.resultsAreCurrent }
    XCTAssertTrue(browser.window.items.contains { $0.id == target.id })
    content.toggleFavorite()
    try await waitForDetail {
      !content.favoritePending && browser.resultsAreCurrent
        && browser.shelves[.favorites]?.loaded == true
        && browser.shelves[.favorites]?.loading == false
    }
    XCTAssertEqual(content.favoriteValue, false)
    XCTAssertTrue(browser.shelves[.favorites]?.loaded == true)
    XCTAssertFalse(browser.shelves[.favorites]?.loading == true)
    XCTAssertFalse(browser.window.items.contains { $0.id == target.id })
    XCTAssertFalse(browser.shelves[.favorites]?.items.contains { $0.id == target.id } == true)
    XCTAssertEqual(browser.shelves[.discover]?.items, discover)
    XCTAssertEqual(search.searchText, "Invented")
    XCTAssertFalse(search.options.favoritesOnly)
    browser.retire()
  }
}

extension CatalogTests {
  @MainActor private func waitForDetail(
    _ predicate: @MainActor () async -> Bool,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(1)
    while ContinuousClock.now < deadline {
      if await predicate() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Required detail state did not become accepted", file: file, line: line)
    throw ClientError.unavailable
  }
  @MainActor func testHeldFavoriteUserViewsRejectsRetirementAndCancellationBeforeProof()
    async throws
  {
    for cancel in [false, true] {
      let http = CatalogHTTP([])
      await http.holdNextRoots()
      let api = try client(http)
      let life = RenderLifetimeProbe()
      let write = Task {
        try await api.setFavorite(
          library: "music", item: .fixtureAlbum,
          value: true, isCurrent: { life.live })
      }
      try await waitForDetail { await http.rootsWaiting }
      if cancel { write.cancel() } else { life.live = false }
      await http.releaseRoots()
      do {
        _ = try await write.value
        XCTFail("Retired root await must not admit proof")
      } catch { XCTAssertTrue(error is CancellationError) }
      let calls = await http.requests
      XCTAssertEqual(calls.count, 1)
      XCTAssertEqual(calls.first?.url?.lastPathComponent, "UserViews")
    }
  }
  @MainActor func testFavoriteShelfRefreshRejectsHeldOldReplyWithoutRerollingDiscover() async throws
  {
    let service = AlbumMutationCatalog()
    let browser = MusicBrowser(service: service)
    await browser.start()
    await service.holdNextFavoriteShelf()
    browser.loadDashboard()
    try await waitForDetail {
      await service.shelfWaiting && browser.shelves[.discover]?.loaded == true
    }
    let discover = try XCTUnwrap(browser.shelves[.discover]?.items)
    let content = try XCTUnwrap(browser.detail(.fixtureAlbum))
    await content.load()
    content.toggleFavorite()
    try await waitForDetail { await service.writes.count == 1 }
    await service.releaseWrite(1, value: true)
    try await waitForDetail {
      !content.favoritePending && browser.shelves[.favorites]?.loaded == true
        && browser.shelves[.favorites]?.loading == false
    }
    XCTAssertEqual(browser.shelves[.favorites]?.items.map(\.id), ["fixture-album"])
    await service.releaseFavoriteShelf()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(browser.shelves[.favorites]?.items.map(\.id), ["fixture-album"])
    XCTAssertEqual(browser.shelves[.discover]?.items, discover)
    let calls = await service.queries
    XCTAssertEqual(calls.filter { $0.shelf == .discover }.count, 1)
    XCTAssertEqual(calls.filter { $0.shelf == .favorites }.count, 2)
    browser.retire()
  }
  @MainActor func testAlbumArtistPortraitIsOwnOptionalEntityAndRetiresWithAlbum() async throws {
    let fixture = FixtureCatalog(source: URL(fileURLWithPath: "/invented/tone.wav"))
    let life = RenderLifetimeProbe()
    let content = AlbumContent(
      album: CatalogFixtures.album(0), library: "fixture-music",
      service: fixture, isCurrent: { life.live })
    await content.load()
    await content.loadArtistPortrait()
    XCTAssertEqual(content.artistPortrait?.id, "fixture-artist-0")
    XCTAssertEqual(content.artistPortrait?.imageID, "fixture-artist-0")
    XCTAssertNotEqual(content.artistPortrait?.imageID, content.album.imageID)
    XCTAssertNil(content.artistPortrait?.details, "Only lean portrait identity is retained")
    life.live = false
    XCTAssertNil(content.artistPortrait)
    XCTAssertEqual(content.tracks.count, 4, "Optional portrait never replaces the playable album")
  }
}

extension CatalogTests {
  @MainActor func testYearOnlyArtistMetadataIsHonestEmptyAndOptionalPortraitFailureKeepsAlbum()
    async throws
  {
    let service = PagedCatalog()
    await service.artistHasOnlyYear()
    let parent = MusicBrowser(service: service)
    await parent.start()
    let artist = CatalogFixtures.artist(0)
    let child = try XCTUnwrap(parent.artistBrowser(artist))
    await child.loadArtistMetadata(artist)
    XCTAssertEqual(child.artistMetadata?.details?.year, 1947)
    XCTAssertEqual(child.artistMetadataState, .empty)
    let content = AlbumContent(
      album: CatalogFixtures.album(0), library: "music", service: service, isCurrent: { true })
    await content.load()
    await service.configureArtist(.unavailable)
    await content.loadArtistPortrait()
    XCTAssertNil(content.artistPortrait)
    XCTAssertEqual(content.tracks.count, 4)
    XCTAssertNil(content.error)
    parent.retire()
  }
}

extension CatalogTests {
  @MainActor func testCanceledAlbumLoadCannotEnterOptionalArtistPortraitRead() async throws {
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    let service = PagedCatalog(albumTrackGate: gate.stream)
    let content = AlbumContent(
      album: CatalogFixtures.album(0), library: "music", service: service,
      isCurrent: { true })
    let viewTask = Task {
      await content.load()
      await content.loadArtistPortrait()
    }
    try await waitForDetail { await service.detailLibraries.count == 1 }
    viewTask.cancel()
    gate.continuation.finish()
    await viewTask.value
    let calls = await service.artistCalls
    XCTAssertEqual(calls, 0, "Canceled view continuation must not read first-credit metadata")
    XCTAssertNil(content.artistPortrait)
  }
  @MainActor func testHeldArtistMetadataLinkRejectsScopeSwitchAndRemovedRootReincarnation()
    async throws
  {
    let service = PagedCatalog()
    let parent = MusicBrowser(service: service)
    await parent.start()
    let child = try XCTUnwrap(parent.artistBrowser(CatalogFixtures.artist(0)))
    let owner = child.scope
    let library = child.authorizedLibrary
    var reads = 0
    let heldLink = {
      guard child.metadataIsCurrent(scope: owner, library: library) else { return }
      reads += 1
    }
    heldLink()
    XCTAssertEqual(reads, 1)
    child.selectLibrary("live")
    heldLink()
    child.selectLibrary("music")
    heldLink()
    XCTAssertEqual(reads, 1, "Switching back cannot revive the old sheet callback")
    let secondOwner = child.scope
    let secondLibrary = child.authorizedLibrary
    await service.setLibraries(["live"])
    await parent.loadLibraries()
    await service.setLibraries(["music", "live"])
    await parent.loadLibraries()
    XCTAssertFalse(child.metadataIsCurrent(scope: secondOwner, library: secondLibrary))
    heldLink()
    XCTAssertEqual(reads, 1)
    let fresh = try XCTUnwrap(parent.artistBrowser(CatalogFixtures.artist(0)))
    XCTAssertTrue(fresh.metadataIsCurrent(scope: fresh.scope, library: fresh.authorizedLibrary))
    XCTAssertNotEqual(fresh.scope, owner)
    parent.retire()
  }
}

extension CatalogTests {
  func testCanonicalLyricsBoundsPlainTextAndTickTimingWithoutInventedSynchronization() throws {
    let data = Data(
      #"{"Metadata":{"IsSynced":true},"Lyrics":[{"Text":"<b>Invented first line</b>","Start":20000000},{"Text":"Invented second line","Start":40000000}]}"#
        .utf8)
    let lyrics = try XCTUnwrap(MusicLyrics.decode(data))
    XCTAssertEqual(lyrics.lines.map(\.text), ["Invented first line", "Invented second line"])
    XCTAssertEqual(lyrics.lines.map(\.seconds), [2, 4])
    XCTAssertTrue(lyrics.synchronized)
    let plain = try XCTUnwrap(
      MusicLyrics.decode(Data(#"{"Lyrics":[{"Text":"Invented plain line"}]}"#.utf8)))
    XCTAssertFalse(plain.synchronized)
    XCTAssertNil(plain.lines.first?.seconds)
    XCTAssertNil(try MusicLyrics.decode(Data(#"{"Lyrics":[]}"#.utf8)))
    XCTAssertThrowsError(try MusicLyrics.decode(Data(repeating: 32, count: 512_001)))
    let excessive: [String: Any] = ["Lyrics": Array(repeating: ["Text": "Invented"], count: 1_001)]
    XCTAssertThrowsError(try MusicLyrics.decode(JSONSerialization.data(withJSONObject: excessive)))
    XCTAssertThrowsError(
      try MusicLyrics.decode(Data(#"{"Tracks":[]}"#.utf8)),
      "Unverified response shapes must not pretend to supply lyrics")
  }
  @MainActor func testLyricsAvailabilityIsTriStateAudioOnlyAndPayloadRemainsLazy() async throws {
    let roots: [String: Any] = [
      "Items": [
        ["Id": "music", "Name": "Invented", "Type": "CollectionFolder", "CollectionType": "music"]
      ]
    ]
    let http = CatalogHTTP([
      (200, roots),
      (
        200,
        [
          "Items": [
            ["Id": "yes", "Type": "Audio", "HasLyrics": true],
            ["Id": "no", "Type": "Audio", "HasLyrics": false],
            ["Id": "unknown", "Type": "Audio"],
            ["Type": "Book", "Id": ["getter-trap": true], "HasLyrics": ["getter-trap": true]],
          ]
        ]
      ),
    ])
    let items = try await client(http).catalog(CatalogQuery(library: "music", category: .songs))
    XCTAssertEqual(items.map(\.hasLyrics), [true, false, nil])
    let callCount = await http.requests.count
    XCTAssertEqual(callCount, 2, "Availability must not fetch lyric bodies")
    var legacy = MusicItem.fixtureTracks[0]
    legacy.hasLyrics = true
    XCTAssertEqual(legacy.inheritingArtwork(from: .fixtureAlbum).hasLyrics, true)
    let old = Data(
      #"{"id":"old","title":"Invented","artist":"Invented","album":"Invented","duration":1,"number":1,"kind":"Audio"}"#
        .utf8)
    XCTAssertNil(try JSONDecoder().decode(MusicItem.self, from: old).hasLyrics)
  }
  @MainActor func testLyrics404IsOptionalAbsenceAndFreshUnknownAvoidsPayloadRead() async throws {
    let roots: [String: Any] = [
      "Items": [
        ["Id": "music", "Name": "Invented", "Type": "CollectionFolder", "CollectionType": "music"]
      ]
    ]
    var track = MusicItem.fixtureTracks[0]
    track.hasLyrics = true
    for available in [true, false] {
      let wire: [String: Any] = ["Id": track.id, "Type": "Audio", "HasLyrics": available]
      let http = CatalogHTTP([(200, roots), (200, ["Items": [wire]]), (404, [:])])
      let value = try await client(http).lyrics(library: "music", track: track, isCurrent: { true })
      XCTAssertNil(value)
      let requests = await http.requests
      XCTAssertEqual(requests.count, available ? 3 : 2)
      XCTAssertEqual(requests.last?.url?.lastPathComponent, available ? "Lyrics" : "Items")
    }
  }
  @MainActor func testHeldLyricsRejectRetiredOwnerBeforeMalformedPayloadDecode() async throws {
    let roots: [String: Any] = [
      "Items": [
        ["Id": "music", "Name": "Invented", "Type": "CollectionFolder", "CollectionType": "music"]
      ]
    ]
    var track = MusicItem.fixtureTracks[0]
    track.hasLyrics = true
    let http = CatalogHTTP([
      (200, roots), (200, ["Items": [["Id": track.id, "Type": "Audio", "HasLyrics": true]]]),
      (200, ["Lyrics": "getter-trap"]),
    ])
    let life = RenderLifetimeProbe()
    let api = try client(http)
    await http.holdNextLyrics()
    let task = Task {
      try await api.lyrics(library: "music", track: track, isCurrent: { life.live })
    }
    defer { Task { await http.releaseLyrics() } }
    try await waitForDetail { await http.lyricsWaiting }
    life.live = false
    await http.releaseLyrics()
    do {
      _ = try await task.value
      XCTFail("Retired body was admitted")
    } catch {
      XCTAssertTrue(error is CancellationError, "Must reject before malformed payload extraction")
    }
  }
  @MainActor func testHeldLyricsRootProofCancellationAdmitsNoItemOrPayloadRead() async throws {
    let http = CatalogHTTP([])
    let api = try client(http)
    var track = MusicItem.fixtureTracks[0]
    track.hasLyrics = true
    await http.holdNextRoots()
    let task = Task { try await api.lyrics(library: "music", track: track, isCurrent: { true }) }
    defer { Task { await http.releaseRoots() } }
    try await waitForDetail { await http.rootsWaiting }
    task.cancel()
    await http.releaseRoots()
    do {
      _ = try await task.value
      XCTFail("Canceled root proof continued")
    } catch { XCTAssertTrue(error is CancellationError) }
    let callCount = await http.requests.count
    XCTAssertEqual(callCount, 1)
  }
}

extension CatalogTests {
  @MainActor func testPlayerArtistShelfIsLazyEightUniqueAlbumsFromExactRootAndArtist() async throws
  {
    let roots: [String: Any] = [
      "Items": [
        ["Id": "music", "Name": "Invented", "Type": "CollectionFolder", "CollectionType": "music"]
      ]
    ]
    let trackWire: [String: Any] = [
      "Id": "track", "Type": "Audio", "AlbumId": "current", "HasLyrics": true,
      "ArtistItems": [
        ["Id": "artist-first", "Name": "Invented First"],
        ["Id": "artist-second", "Name": "Invented Second"],
      ],
    ]
    var albums: [[String: Any]] = [
      ["Id": "current", "Type": "MusicAlbum"], ["Id": "album-0", "Type": "MusicAlbum"],
    ]
    albums += (0..<12).map { ["Id": "album-\($0)", "Type": "MusicAlbum"] }
    albums.append(["Type": "Book", "Id": ["getter-trap": true], "Name": ["getter-trap": true]])
    let http = CatalogHTTP([(200, roots), (200, ["Items": [trackWire]]), (200, ["Items": albums])])
    let content = AlbumContent(
      album: MusicItem(
        id: "track", title: "Invented", artist: "Invented", album: "Invented", duration: 20,
        number: 1, kind: "Audio", imageID: nil, imageTag: nil), library: "music",
      service: try client(http), isCurrent: { true })
    XCTAssertTrue(content.relatedAlbums.isEmpty)
    XCTAssertFalse(content.lyricsAvailable)
    await content.load()
    XCTAssertTrue(content.lyricsAvailable)
    let before = await http.requests.count
    XCTAssertEqual(before, 2, "Opening Player metadata must not eagerly fetch lyrics or shelf")
    await content.loadRelatedAlbums()
    XCTAssertEqual(content.relatedAlbums.map(\.id), (0..<8).map { "album-\($0)" })
    XCTAssertEqual(content.relatedArtist?.id, "artist-first")
    await content.loadRelatedAlbums()
    let requests = await http.requests
    XCTAssertEqual(requests.count, 3, "Accepted shelf is reused within this detail lifetime")
    let query = URLComponents(
      url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
    XCTAssertEqual(query?.first(where: { $0.name == "AlbumArtistIds" })?.value, "artist-first")
    XCTAssertEqual(query?.first(where: { $0.name == "ParentId" })?.value, "music")
    XCTAssertFalse(requests.contains { $0.url?.lastPathComponent == "Lyrics" })
  }
  @MainActor func testRetiredPlayerShelfResponseCompletesWithoutPublishing() async throws {
    let roots: [String: Any] = [
      "Items": [
        ["Id": "music", "Name": "Invented", "Type": "CollectionFolder", "CollectionType": "music"]
      ]
    ]
    let http = CatalogHTTP([(200, roots)])
    let api = try client(http)
    _ = try await api.musicLibraries(refresh: false)
    var track = MusicItem.fixtureTracks[0]
    track.artistCredits = [MusicCredit(id: "artist", name: "Invented")]
    let life = RenderLifetimeProbe()
    let content = AlbumContent(
      album: track, library: "music", service: api, isCurrent: { life.live })
    await http.holdNextItems()
    let task = Task { await content.loadRelatedAlbums() }
    defer { Task { await http.releaseItems() } }
    try await waitForDetail { await http.itemWaiting }
    life.live = false
    await http.releaseItems()
    await task.value
    XCTAssertTrue(content.relatedAlbums.isEmpty)
    XCTAssertNil(content.relatedArtist)
  }
}

extension CatalogTests {
  func testCanonicalLyricsInferSyncFromCompleteOrderedStartsWithoutMetadataFlag() throws {
    let timestamped = try XCTUnwrap(
      MusicLyrics.decode(
        Data(
          #"{"Lyrics":[{"Text":"Invented first","Start":20000000},{"Text":"Invented second","Start":40000000}]}"#
            .utf8)))
    XCTAssertEqual(timestamped.lines.map(\.seconds), [2, 4])
    XCTAssertTrue(timestamped.synchronized, "Official LRC parser leaves Metadata unset")
    for rows in [
      [["Text": "Invented first", "Start": 20_000_000], ["Text": "Invented plain"]],
      [
        ["Text": "Invented first", "Start": 20_000_000], ["Text": "Invented invalid", "Start": -1],
      ],
      [
        ["Text": "Invented first", "Start": 40_000_000],
        ["Text": "Invented earlier", "Start": 20_000_000],
      ],
    ] {
      let data = try JSONSerialization.data(withJSONObject: ["Lyrics": rows])
      XCTAssertFalse(try XCTUnwrap(MusicLyrics.decode(data)).synchronized)
    }
    let offset = try XCTUnwrap(
      MusicLyrics.decode(
        Data(
          #"{"Metadata":{"IsSynced":true,"Offset":10000000},"Lyrics":[{"Text":"Invented first","Start":20000000},{"Text":"Invented second","Start":40000000}]}"#
            .utf8)))
    XCTAssertEqual(offset.lines.map(\.seconds), [2, 4], "Never guess Offset's sign")
    XCTAssertFalse(offset.synchronized, "Nonzero Offset timing remains unverified")
    let claimed = try XCTUnwrap(
      MusicLyrics.decode(
        Data(
          #"{"Metadata":{"IsSynced":true},"Lyrics":[{"Text":"Invented plain"}]}"#.utf8)))
    XCTAssertFalse(claimed.synchronized)
    XCTAssertNil(claimed.lines.first?.seconds, "A missing timestamp is not zero")
  }
}

extension CatalogTests {
  @MainActor func testInventedPlayerFixtureKeepsLyricsAndSongFavoriteUnderExactRoot() async throws {
    let api = FixtureCatalog(source: URL(string: "https://invented.invalid/audio")!)
    let tracks = try await api.catalog(
      CatalogQuery(
        library: "fixture-music", category: .songs,
        ids: ["fixture-track-0", "fixture-track-1"]))
    let first = try XCTUnwrap(tracks.first(where: { $0.id == "fixture-track-0" }))
    let second = try XCTUnwrap(tracks.first(where: { $0.id == "fixture-track-1" }))
    XCTAssertEqual(first.hasLyrics, true)
    XCTAssertEqual(second.hasLyrics, false)
    let lyrics = try await api.lyrics(library: "fixture-music", track: first, isCurrent: { true })
    XCTAssertEqual(lyrics?.lines.count, 3)
    XCTAssertTrue(try XCTUnwrap(lyrics).synchronized)
    let absent = try await api.lyrics(library: "fixture-music", track: second, isCurrent: { true })
    XCTAssertNil(absent)
    let saved = try await api.setFavorite(
      library: "fixture-music", item: first, value: true, isCurrent: { true })
    XCTAssertTrue(saved)
    let refreshed = try await api.catalog(
      CatalogQuery(library: "fixture-music", category: .songs, ids: [first.id]))
    XCTAssertEqual(refreshed.first?.favorite, true)
    do {
      _ = try await api.lyrics(library: "invented-denied-root", track: first, isCurrent: { true })
      XCTFail("Fixture crossed its authorized library")
    } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
  }
}
