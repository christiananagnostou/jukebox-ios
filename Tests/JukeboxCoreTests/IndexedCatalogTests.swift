#if DEBUG || CATALOG_SCALE_FIXTURE
  import XCTest
  @testable import JukeboxCore

  private actor HeldIndexedReply: MusicCatalogServing {
    let source: IndexedCatalogFixture
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    init(_ source: IndexedCatalogFixture) { self.source = source }
    func release() {
      continuation?.resume()
      continuation = nil
    }
    func verifyIdentity() async throws {}
    func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
      try await source.musicLibraries(refresh: refresh)
    }
    func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
      let rows = try await source.catalog(query)
      if query.offset == 40 {
        entered = true
        await withCheckedContinuation { continuation = $0 }
      }
      return rows
    }
    func albumTracks(library: String, album: String) async throws -> [MusicItem] {
      try await source.albumTracks(library: library, album: album)
    }
    func validate(ids: [String]) async throws -> [MusicItem] { try await source.validate(ids: ids) }
    func media(
      library: String, trackID: String, quality: StreamQuality,
      isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> MediaSource {
      try await source.media(
        library: library, trackID: trackID, quality: quality, isCurrent: isCurrent)
    }
    func artwork(item: MusicItem) async throws -> Data? { nil }
  }

  final class IndexedCatalogTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/invented/tone.wav")
    func testScaleInputRequiresExplicitIdentityAndAllowlistedSize() {
      let id = UUID().uuidString
      let flag = "--catalog-scale=\(id):50000"
      XCTAssertNil(IndexedCatalogInput(arguments: [flag]))
      XCTAssertNil(IndexedCatalogInput(arguments: ["--fixture", "--catalog-scale=../other:50000"]))
      XCTAssertNil(IndexedCatalogInput(arguments: ["--fixture", "--catalog-scale=\(id):1000000"]))
      XCTAssertNil(IndexedCatalogInput(arguments: ["--fixture", flag, flag]))
      XCTAssertNil(IndexedCatalogInput(arguments: ["--fixture", flag, "--integration"]))
      let value = IndexedCatalogInput(arguments: ["--fixture", flag])
      XCTAssertEqual(value?.songCount, 50_000)
      XCTAssertEqual(value?.directory, "JukeboxScale/" + id)
      XCTAssertFalse(value?.cleanup ?? true)
    }
    func testRejectedScaleIntentNeverAccessesNormalStorageVaultIDOrActivationFactory() {
      let id = UUID().uuidString
      let valid = "--catalog-scale=\(id):50000"
      let invalid: [[String]] = [
        [valid], ["--fixture", "--catalog-scale=bad:50000"],
        ["--fixture", "--catalog-scale=\(id):99999"], ["--fixture", valid, valid],
        ["--fixture", valid, "--integration"],
        ["--fixture", valid, "--profile-fixture=\(id)"],
        ["--catalog-scale-cleanup"], ["--fixture", "--catalog-scale=\(id)::50000"],
      ]
      for arguments in invalid {
        var normalAccess = 0
        let launch = IndexedCatalogLaunch(arguments: arguments)
        XCTAssertTrue(launch.isRejected)
        let result = launch.startup(
          normal: {
            normalAccess += 1
            return "normal"
          }, accepted: { _ in "accepted" }, rejected: { "memory-only-connect" })
        XCTAssertEqual(normalAccess, 0, "Rejected diagnostic intent accessed normal startup")
        XCTAssertEqual(result, "memory-only-connect")
      }
      let absent = IndexedCatalogLaunch(arguments: [])
      XCTAssertFalse(absent.isAttempted)
      XCTAssertEqual(absent.startup(normal: { 1 }, accepted: { _ in 2 }, rejected: { 3 }), 1)
    }
    func testBothScaleSizesConstructOnlyRequestedPagesAndExactSearch() async throws {
      for count in [50_000, 100_000] {
        let service = IndexedCatalogFixture(songCount: count, source: source)
        for offset in [0, count / 2, count - 40] {
          let rows = try await service.catalog(
            CatalogQuery(library: IndexedCatalogFixture.library, category: .songs, offset: offset))
          XCTAssertEqual(rows.count, 40)
          XCTAssertEqual(rows.first?.id, "scale-song-\(offset)")
          XCTAssertEqual(rows.last?.id, "scale-song-\(offset + 39)")
        }
        let found = try await service.catalog(
          CatalogQuery(
            library: IndexedCatalogFixture.library, category: .songs,
            search: String(format: "Song %06d", count - 1)))
        XCTAssertEqual(found.map(\.id), ["scale-song-\(count - 1)"])
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot["constructed_rows"], 121)
        XCTAssertEqual(snapshot["maximum_batch"], 40)
      }
    }
    func testCanonicalArtistAndAlbumAssociationsAndDeniedRoots() async throws {
      let service = IndexedCatalogFixture(songCount: 100_000, source: source)
      let albums = try await service.catalog(
        CatalogQuery(library: IndexedCatalogFixture.library, artist: "scale-artist-99"))
      XCTAssertEqual(albums.count, 40)
      XCTAssertEqual(albums.first?.id, "scale-album-99")
      XCTAssertTrue(albums.allSatisfy { $0.artistCredits?.first?.id == "scale-artist-99" })
      let tracks = try await service.albumTracks(
        library: IndexedCatalogFixture.library,
        album: "scale-album-24999")
      XCTAssertEqual(tracks.map(\.id), (99_996..<100_000).map { "scale-song-\($0)" })
      XCTAssertTrue(tracks.allSatisfy { $0.albumID == "scale-album-24999" })
      do {
        _ = try await service.catalog(CatalogQuery(library: "unrelated-private-root"))
        XCTFail("Foreign root accepted")
      } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
      do {
        _ = try await service.media(
          library: IndexedCatalogFixture.library, trackID: "scale-song-100000", quality: .original,
          isCurrent: { true })
        XCTFail("Invalid canonical item accepted")
      } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
    }
    @MainActor func testFiftyThousandVisitedMetadataBackscrollAndChildRetirement() async throws {
      let service = IndexedCatalogFixture(songCount: 50_000, source: source)
      let browser = MusicBrowser(service: service)
      await browser.start()
      browser.selectCategory(.songs)
      func settle(_ model: MusicBrowser) async throws {
        for _ in 0..<10_000 {
          if model.resultsAreCurrent && !model.window.loading { return }
          await Task.yield()
        }
        XCTFail("Invented page did not settle")
      }
      try await settle(browser)
      for offset in stride(from: 40, to: 50_000, by: 40) {
        browser.loadMore()
        try await settle(browser)
        XCTAssertEqual(browser.window.items.count, offset + 40)
      }
      let count = await service.snapshot()["queries"]
      for offset in stride(from: 49_960, through: 0, by: -40) {
        browser.loadListing(offset: offset)
        XCTAssertEqual(browser.window.items.count, 50_000)
      }
      let after = await service.snapshot()["queries"]
      XCTAssertEqual(count, after, "Visited backscroll issues zero catalog requests")
      let bytes = try JSONEncoder().encode(Array(browser.window.items)).count
      XCTAssertLessThan(bytes, 40_000_000, "Invented lean encoded payload budget, not a RAM claim")
      let artist = try await service.catalog(
        CatalogQuery(
          library: IndexedCatalogFixture.library,
          category: .artists)
      ).first!
      let child = try XCTUnwrap(browser.artistBrowser(artist))
      try await settle(child)
      child.loadMore()
      try await settle(child)
      XCTAssertEqual(child.window.items.count, 80)
      browser.selectCategory(.artists)
      try await settle(browser)
      XCTAssertEqual(browser.windows.values.reduce(0) { $0 + $1.items.count }, 50_040)
      browser.retire()
      XCTAssertTrue(browser.windows.isEmpty)
      XCTAssertTrue(
        child.windows.isEmpty, "Retired child metadata must be released, not only hidden")
      XCTAssertNil(child.authorizedLibrary)
    }
    @MainActor func testActualBrowserScaleWindowSearchAndRetirement() async throws {
      let service = IndexedCatalogFixture(songCount: 100_000, source: source)
      let browser = MusicBrowser(service: service)
      await browser.start()
      browser.selectCategory(.songs)
      func settle() async throws {
        for _ in 0..<200 {
          if browser.window.loaded && !browser.window.loading { return }
          try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Bounded fixture did not settle")
      }
      try await settle()
      for offset in stride(from: 40, through: 200, by: 40) {
        browser.loadListing(offset: offset)
        try await settle()
        XCTAssertEqual(browser.window.items.count, offset + 40)
        XCTAssertEqual(browser.window.pages.count, offset / 40 + 1)
      }
      XCTAssertEqual(browser.window.firstOffset, 0)
      for offset in stride(from: 80, through: 0, by: -40) {
        browser.loadListing(offset: offset)
        try await settle()
      }
      XCTAssertEqual(browser.window.items.first?.id, "scale-song-0")
      browser.searchText = "Song 099999"
      browser.searchChanged()
      try await settle()
      XCTAssertEqual(browser.window.items.map(\.id), ["scale-song-99999"])
      browser.searchText = "Song 000001"
      browser.searchChanged()
      browser.retire()
      try await Task.sleep(for: .milliseconds(350))
      XCTAssertTrue(browser.window.items.isEmpty)
      XCTAssertNil(browser.libraryID)
    }
    @MainActor func testHeldIndexedCompletionCannotRepublishAfterRetirement() async throws {
      let service = HeldIndexedReply(IndexedCatalogFixture(songCount: 100_000, source: source))
      let browser = MusicBrowser(service: service)
      await browser.start()
      for _ in 0..<100 {
        if browser.window.loaded && !browser.window.loading { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      XCTAssertTrue(browser.window.loaded)
      browser.loadMore()
      for _ in 0..<100 {
        if await service.entered { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      let entered = await service.entered
      XCTAssertTrue(entered, "The result must actually be held in flight before retirement")
      browser.retire()
      await service.release()
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertTrue(browser.windows.isEmpty)
      XCTAssertTrue(browser.shelves.isEmpty)
      XCTAssertNil(browser.libraryID)
    }
  }
#endif
