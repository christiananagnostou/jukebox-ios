import Foundation
import XCTest

@testable import JukeboxCore

private actor YearHTTP: HTTPTransport {
  private(set) var requests: [URLRequest] = []
  private var hold = false
  private var holdRoots = false
  private var rootWaiters: [CheckedContinuation<HTTPReply, Never>?] = []
  private var years = [0, 1951, 1990, 2025]
  private var waiters: [CheckedContinuation<HTTPReply, Never>] = []
  func holdRootRefreshes() { holdRoots = true }
  func rootRequestCount() -> Int { rootWaiters.count }
  func setYears(_ values: [Int]) { years = values }
  func releaseRoots(_ index: Int, ids: [String], status: Int = 200, malformed: Bool = false) throws
  {
    let object: [String: Any] =
      malformed
      ? ["Items": "invalid"]
      : [
        "Items": ids.map {
          ["Id": $0, "Name": "Invented", "Type": "CollectionFolder", "CollectionType": "music"]
        }
      ]
    let waiter = rootWaiters[index]
    rootWaiters[index] = nil
    waiter?.resume(
      returning: HTTPReply(data: try JSONSerialization.data(withJSONObject: object), status: status)
    )
  }
  func holdFacet() { hold = true }
  func heldCount() -> Int { waiters.count }
  func releaseFacet() throws {
    hold = false
    let reply = HTTPReply(
      data: try JSONSerialization.data(withJSONObject: ["Years": [1900]]), status: 200)
    let captured = waiters
    waiters = []
    for waiter in captured { waiter.resume(returning: reply) }
  }
  func send(_ request: URLRequest) async throws -> HTTPReply {
    requests.append(request)
    let path = request.url!.path
    if path.hasSuffix("/UserViews"), holdRoots {
      return await withCheckedContinuation { rootWaiters.append($0) }
    }
    if path.hasSuffix("/Items/Filters"), hold {
      return await withCheckedContinuation { waiters.append($0) }
    }
    let object: [String: Any]
    if path.hasSuffix("/UserViews") {
      object = [
        "Items": [
          [
            "Id": "music", "Name": "Invented", "Type": "CollectionFolder",
            "CollectionType": "music",
          ]
        ]
      ]
    } else if path.hasSuffix("/Items/Filters") {
      object = ["Years": years]
    } else {
      object = [
        "Items": [
          ["Id": "dated", "Name": "Invented", "Type": "MusicAlbum", "ProductionYear": 1990],
          ["Id": "undated", "Name": "Undated", "Type": "MusicAlbum"],
        ]
      ]
    }
    return HTTPReply(data: try JSONSerialization.data(withJSONObject: object), status: 200)
  }
}

private actor YearCatalog: MusicCatalogServing {
  private(set) var yearRequests: [String] = []
  private var hold = false
  private var waiters: [CheckedContinuation<CatalogYearFacet, any Error>] = []
  func holdFacet() { hold = true }
  func heldCount() -> Int { waiters.count }
  func releaseFacet(_ value: Result<CatalogYearFacet, ClientError>) {
    hold = false
    let captured = waiters
    waiters = []
    for waiter in captured { waiter.resume(with: value.mapError { $0 as any Error }) }
  }
  func verifyIdentity() async throws {}
  func validate(ids: [String]) async throws -> [MusicItem] { [] }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    throw ClientError.unavailable
  }
  func artwork(item: MusicItem) async throws -> Data? { nil }
  func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
    [
      MusicLibrary(id: "music", title: "Invented"), MusicLibrary(id: "other", title: "Other"),
      MusicLibrary(id: "empty", title: "Unknown"),
    ]
  }
  func catalogYears(library: String) async throws -> CatalogYearFacet {
    yearRequests.append(library)
    if hold { return try await withCheckedThrowingContinuation { waiters.append($0) } }
    return try CatalogYearFacet(
      library == "music" ? [1951, 1990, 2025] : library == "other" ? [2010] : [])
  }
  func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
    [
      MusicItem(
        id: "item", title: "Invented", artist: "Invented", album: "Invented", duration: 18,
        number: 1, kind: query.category.itemType, imageID: nil, imageTag: nil)
    ]
  }
  func albumTracks(library: String, album: String) async throws -> [MusicItem] { [] }
}

final class CatalogYearTests: XCTestCase {
  func testHeldFeedbackReadsLivePreferenceAndSuppressesJitterWithoutCatchup() throws {
    var enabled = true
    var feedback = CatalogSelectionFeedback()
    var pulses = 0
    var committed = CatalogYearRange.all
    let requested = try XCTUnwrap(CatalogYearRange(lower: 1970, upper: 1980))
    let pendingCommit = {
      committed = requested
      if feedback.admit(enabled: { enabled }, at: 0.3) { pulses += 1 }
    }
    enabled = false
    pendingCommit()
    XCTAssertEqual(committed, requested, "Turning feedback off must not cancel the pending range")
    XCTAssertEqual(
      pulses, 0, "A held callback reads the current preference, not its captured old flag")
    enabled = true
    XCTAssertTrue(feedback.admit(enabled: { enabled }, at: 0.31))
    for instant in [0.32, 0.33, 0.34, 0.35, 0.36, 0.37] {
      XCTAssertFalse(feedback.admit(enabled: { enabled }, at: instant))
    }
    XCTAssertTrue(feedback.admit(enabled: { enabled }, at: 0.47))
    XCTAssertFalse(feedback.admit(enabled: { enabled }, at: 0.48), "No queued catchup burst")
    XCTAssertFalse(feedback.admit(enabled: { enabled }, at: .infinity))
    XCTAssertFalse(feedback.admit(enabled: { enabled }, at: -1))
    XCTAssertFalse(feedback.admit(enabled: { enabled }, at: 0.1), "Monotonic regression rejects")
  }
  func testSingleLibraryWideYearsComeFromActualRecordsAndKeepOriginalGestureFixture() async throws {
    let source = URL(fileURLWithPath: "/invented/tone.wav")
    let original = FixtureCatalog(source: source)
    let originalBounds = try await original.catalogYears(library: "fixture-music").bounds
    XCTAssertEqual(originalBounds, 1951...2025)
    let wide = FixtureCatalog(source: source, singleLibrary: true)
    let facet = try await wide.catalogYears(library: "fixture-music")
    XCTAssertEqual(facet.bounds, 1700...2026)
    XCTAssertTrue(facet.decades.contains(1700...1709))
    XCTAssertFalse(facet.decades.contains(1800...1809))
    var query = CatalogQuery(library: "fixture-music")
    query.options.years = CatalogYearRange(lower: 1700, upper: 1700)!
    let ancient = try await wide.catalog(query)
    XCTAssertEqual(ancient.map(\.id), ["fixture-album-124"])
    XCTAssertEqual(ancient.first?.details?.year, 1700)
    query.category = .songs
    let tracks = try await wide.catalog(query)
    XCTAssertEqual(tracks.count, 4)
    XCTAssertTrue(tracks.allSatisfy { $0.details?.year == 1700 })
    query.category = .albums
    query.options.years = CatalogYearRange(lower: 2026, upper: 2026)!
    let newest = try await wide.catalog(query)
    XCTAssertEqual(newest.map(\.id), ["fixture-album-125"])
    let details = try await wide.albumTracks(library: "fixture-music", album: "fixture-album-125")
    XCTAssertTrue(details.allSatisfy { $0.details?.year == 2026 })
  }
  func testExactYearDraftKeepsAbsoluteRangeAndRejectsInvalidInputWithoutMutatingSelection() throws {
    let selection = try XCTUnwrap(CatalogYearRange(lower: 1700, upper: 2026))
    var draft = CatalogYearDraft(selection: selection, bounds: 1951...2025)
    XCTAssertEqual(draft.from, "1700")
    XCTAssertEqual(draft.to, "2026")
    draft.from = "1970"
    draft.to = "1980"
    XCTAssertEqual(draft.accepted, CatalogYearRange(lower: 1970, upper: 1980))
    XCTAssertEqual(selection.lower, 1700, "Editing alone leaves the accepted preference untouched")
    for invalid in ["", "0", "10000", "197x", " 1970", "١٩٧٠"] {
      draft.from = invalid
      XCTAssertNil(draft.accepted)
    }
    draft.from = "1981"
    XCTAssertNil(draft.accepted)
    draft.from = "1980"
    XCTAssertEqual(draft.accepted, CatalogYearRange(lower: 1980, upper: 1980))
    let all = CatalogYearDraft(selection: .all, bounds: 1700...2026)
    XCTAssertEqual(all.from, "1700")
    XCTAssertEqual(all.to, "2026")
    XCTAssertTrue(CatalogYearRange.all.isAll)
  }
  func testDecadeChoicesUseExistingFacetWithHonestCalendarLabelsAndHoles() throws {
    let facet = try CatalogYearFacet([0, 1, 8, 1701, 1709, 1970, 1972, 1979, 2026, 9999])
    XCTAssertEqual(facet.decades, [1...9, 1700...1709, 1970...1979, 2020...2029, 9990...9999])
    XCTAssertFalse(facet.decades.contains(1980...1989))
    XCTAssertTrue(try CatalogYearFacet([]).decades.isEmpty)
  }
  func testDeviceFeedbackPreferenceMigratesLayoutAndRejectsStaleCombinedWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStorage(directory: root)
    try JSONEncoder().encode(CatalogLayout.list).write(
      to: root.appendingPathComponent("music-layout.json"))
    let migrated = try await store.catalogDevicePreferences()
    XCTAssertEqual(migrated, CatalogDevicePreferences(layout: .list, selectionFeedback: true))
    try await store.saveCatalogDevicePreferences(
      .init(layout: .grid, selectionFeedback: false), revision: 12)
    try await store.saveCatalogDevicePreferences(
      .init(layout: .list, selectionFeedback: true), revision: 11)
    let reopened = try LibraryStorage(directory: root)
    let restored = try await reopened.catalogDevicePreferences()
    XCTAssertEqual(restored, .init(layout: .grid, selectionFeedback: false))
    XCTAssertLessThanOrEqual(
      try Data(contentsOf: root.appendingPathComponent("music-layout.json")).count, 128)
  }
  #if DEBUG
    func testRejectedRTLMixedValidDiagnosticsRejectBeforePayloadAndResourceFactories() {
      let id = "00000000-0000-0000-0000-000000000001"
      let base = ["--fixture", "--muted", "--fixture-rtl"]
      let run = TransportControlLaunch(arguments: base + ["--transport-check=" + id])
      let cleanup = TransportControlLaunch(arguments: base + ["--transport-cleanup=" + id])
      XCTAssertEqual(run.runID, UUID(uuidString: id), "The mixed raw transport input is valid")
      XCTAssertEqual(cleanup.runID, UUID(uuidString: id))
      let mixed = [
        ["--transport-check=" + id], ["--transport-cleanup=" + id],
        ["--profile-fixture=" + id], ["--profile-fixture=" + id, "--profile-cleanup"],
        ["--profile-retirement-check=" + id], ["--profile-inspect-report=" + id],
        ["--profile-inspect-cleanup=" + id], ["--catalog-scale=" + id + ":50000"],
        ["--catalog-scale=" + id + ":50000", "--catalog-scale-cleanup"],
        ["--session-check=" + id], ["--artwork-check=" + id], ["--integration"],
      ]
      for extra in mixed {
        let arguments = base + extra
        let admission = CatalogFixtures.Presentation(arguments: arguments)
        XCTAssertTrue(admission.isRejected)
        var payloadReads = 0
        func payload() -> [String] {
          payloadReads += 1
          XCTFail("Rejected presentation read diagnostic payload")
          return arguments
        }
        let launch = admission.diagnosticLaunches(arguments: payload())
        XCTAssertEqual(payloadReads, 0)
        if case .run = launch.transport { XCTFail("Rejected input began acceptance") }
        XCTAssertNil(launch.transport.runID, "Neither run nor cleanup may prepare tails")
        XCTAssertTrue(launch.profile.isRejected)
        XCTAssertNil(launch.profile.runID)
        XCTAssertTrue(launch.scale.isRejected)
        XCTAssertNil(launch.scale.input)
        XCTAssertEqual(
          launch.transport.startup(
            normal: {
              XCTFail("Rejected input opened storage or Keychain")
              return 1
            }, isolated: { 0 }), 0)
        XCTAssertEqual(
          launch.profile.startup(
            normal: {
              XCTFail("Rejected profile opened normal storage")
              return 1
            },
            fixture: { _ in
              XCTFail("Rejected profile created generated audio")
              return 1
            }, isolated: { 0 }), 0)
        XCTAssertEqual(
          launch.scale.startup(
            normal: {
              XCTFail("Rejected scale opened normal storage")
              return 1
            },
            accepted: { _ in
              XCTFail("Rejected scale opened owned disk")
              return 1
            }, rejected: { 0 }), 0)
      }
      let ordinary = ["--fixture", "--transport-check=" + id]
      let unchanged = CatalogFixtures.Presentation(arguments: ordinary)
        .diagnosticLaunches(arguments: ordinary)
      XCTAssertEqual(unchanged.transport.runID, UUID(uuidString: id))
      XCTAssertFalse(unchanged.profile.isAttempted)
      XCTAssertFalse(unchanged.scale.isAttempted)
    }
    func testInventedRTLAdmissionDispatchAndCurrentFixtureRetirement() {
      let accepted = CatalogFixtures.Presentation(arguments: [
        "--fixture", "--muted", "--fixture-rtl", "--appearance-dark", "--large-text",
      ])
      var normalReads = 0
      let value = accepted.startup(
        normal: {
          normalReads += 1
          return 7
        }, isolated: { 0 })
      XCTAssertEqual(value, 7)
      XCTAssertEqual(normalReads, 1)
      var fixture = true
      XCTAssertTrue(accepted.rightToLeft(currentFixture: fixture))
      fixture = false
      XCTAssertFalse(
        accepted.rightToLeft(currentFixture: fixture),
        "A previous fixture cannot style a normal owner")
      for arguments in [
        ["--fixture-rtl"], ["--fixture", "--fixture-rtl"],
        ["--fixture", "--muted", "--fixture-rtl", "--fixture-rtl"],
        ["--fixture", "--muted", "--fixture-rtl=invalid"],
        ["--fixture", "--muted", "--fixture-rtl", "--connect"],
        ["--fixture", "--muted", "--fixture-rtl", "--window-fixture"],
        ["--fixture", "--muted", "--fixture-rtl", "--profile-fixture=invalid"],
        ["--fixture", "--muted", "--fixture-rtl", "--transport-check=invalid"],
        ["--fixture", "--muted", "--fixture-rtl", "--unknown"],
      ] {
        let input = CatalogFixtures.Presentation(arguments: arguments)
        XCTAssertTrue(input.isRejected)
        let result = input.startup(
          normal: {
            normalReads += 1
            XCTFail("Rejected presentation reached normal storage/keychain factory")
            return 7
          },
          isolated: { 0 })
        XCTAssertEqual(result, 0)
        XCTAssertFalse(input.rightToLeft(currentFixture: true))
      }
      XCTAssertEqual(normalReads, 1)
      let absent = CatalogFixtures.Presentation(arguments: ["--fixture", "--muted"])
      XCTAssertFalse(absent.isAttempted)
      XCTAssertFalse(absent.rightToLeft(currentFixture: true))
      XCTAssertEqual(
        absent.startup(
          normal: { 9 },
          isolated: {
            XCTFail("Absent input changed startup")
            return 0
          }), 9)
    }
  #endif
  private func client(_ http: YearHTTP) throws -> JellyfinClient {
    try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://invented.test/base"),
        userID: "listener", username: "Invented"), token: "invented-token", deviceID: "invented",
      transport: http)
  }
  private func fields(_ request: URLRequest) -> [String: String] {
    Dictionary(
      (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
  }
  @MainActor private func settle(_ predicate: () -> Bool) async throws {
    for _ in 0..<100 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Invented year work did not settle")
  }
  func testRootUnionFacetAndInclusiveYearsReachServerBeforePaging() async throws {
    let http = YearHTTP()
    let api = try client(http)
    let facet = try await api.catalogYears(library: "music")
    XCTAssertEqual(facet.bounds, 1951...2025)
    var options = CatalogBrowseOptions()
    options.years = CatalogYearRange(lower: 1951, upper: 1990)!
    options.favoritesOnly = true
    _ = try await api.catalogPage(CatalogQuery(library: "music", offset: 40, options: options))
    let requests = await http.requests
    XCTAssertEqual(requests.count, 3)
    XCTAssertTrue(requests[1].url!.path.hasSuffix("/Items/Filters"))
    XCTAssertEqual(
      fields(requests[1]),
      ["UserId": "listener", "ParentId": "music", "IncludeItemTypes": "MusicAlbum,Audio"])
    let query = fields(requests[2])
    XCTAssertEqual(query["Years"], "1951,1990")
    XCTAssertEqual(query["Filters"], "IsFavorite")
    XCTAssertEqual(query["StartIndex"], "40")
    XCTAssertEqual(query["Limit"], "40")
    XCTAssertEqual(query["ParentId"], "music")
    let all = try await api.catalogPage(CatalogQuery(library: "music"))
    XCTAssertTrue(all.items.contains { $0.id == "undated" && $0.details?.year == nil })
    let last = await http.requests.last!
    XCTAssertNil(fields(last)["Years"])
    let artistHTTP = YearHTTP()
    _ = try await client(artistHTTP).catalogPage(
      CatalogQuery(library: "music", category: .artists, options: options))
    let artistRequests = await artistHTTP.requests
    XCTAssertEqual(artistRequests.count, 3)
    XCTAssertTrue(artistRequests[1].url!.path.hasSuffix("/Artists/AlbumArtists"))
    XCTAssertTrue(artistRequests[2].url!.path.hasSuffix("/Artists"))
    XCTAssertNil(fields(artistRequests.last!)["Years"])
  }
  func testEmptyNumericSelectionCannotBecomeAllAndOversizedQueriesFailClosed() async throws {
    let http = YearHTTP()
    let api = try client(http)
    var options = CatalogBrowseOptions()
    options.years = CatalogYearRange(lower: 2000, upper: 2001)!
    let empty = try await api.catalogPage(CatalogQuery(library: "music", options: options))
    XCTAssertEqual(empty.rawCount, 0)
    XCTAssertTrue(empty.items.isEmpty)
    let requests = await http.requests
    XCTAssertEqual(requests.count, 2, "No unfiltered Items request for an empty selected year set")
    let dense = try CatalogYearFacet(Array(1...9999))
    XCTAssertThrowsError(try dense.wireYears(for: CatalogYearRange(lower: 1, upper: 9999)!))
    XCTAssertNil(try dense.wireYears(for: .all))
    XCTAssertThrowsError(try CatalogYearFacet([-1]))
    XCTAssertThrowsError(try CatalogYearFacet([10000]))
    XCTAssertThrowsError(try CatalogYearFacet(Array(repeating: 1951, count: 10001)))
    XCTAssertNil(try CatalogYearFacet([0]).bounds)
    XCTAssertEqual(try CatalogYearFacet([1990, 1990]).bounds, 1990...1990)
    let soleYear = try XCTUnwrap(CatalogYearFacet([2010, 2010]).bounds?.lowerBound)
    XCTAssertEqual(soleYear, 2010)
    XCTAssertFalse(CatalogYearRange(lower: 1800, upper: 1900)!.contains(soleYear))
    XCTAssertTrue(CatalogYearRange(lower: 2000, upper: 2020)!.contains(soleYear))
    XCTAssertTrue(CatalogYearRange.all.contains(soleYear))
  }
  func testPermissionRefreshRejectsLateFacetBeforeItCanPopulateCache() async throws {
    let http = YearHTTP()
    let api = try client(http)
    _ = try await api.musicLibraries(refresh: false)
    await http.holdFacet()
    let old = Task { try await api.catalogYears(library: "music") }
    for _ in 0..<100 {
      if await http.heldCount() == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let sampled1 = await http.heldCount()
    XCTAssertEqual(sampled1, 1)
    _ = try await api.musicLibraries(refresh: true)
    try await http.releaseFacet()
    do {
      _ = try await old.value
      XCTFail("Old generation cannot fill the current cache")
    } catch { XCTAssertTrue(error is CancellationError) }
    let fresh = try await api.catalogYears(library: "music")
    XCTAssertEqual(fresh.bounds, 1951...2025)
    let before = await http.requests.count
    _ = try await api.catalogYears(library: "music")
    let sampled2 = await http.requests.count
    XCTAssertEqual(sampled2, before)
    do {
      _ = try await api.catalogYears(library: "unauthorized")
      XCTFail("Unknown root")
    } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
    let sampled3 = await http.requests.count
    XCTAssertEqual(sampled3, before, "Reject unknown root before facet request")
  }
  func testFacetAdmittedDuringRefreshCannotSurviveItsSuccessOrFailure() async throws {
    let http = YearHTTP()
    let api = try client(http)
    _ = try await api.catalogYears(library: "music")
    await http.holdRootRefreshes()
    let refresh = Task { try await api.musicLibraries(refresh: true) }
    for _ in 0..<100 {
      if await http.rootRequestCount() == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let firstCount = await http.rootRequestCount()
    XCTAssertEqual(firstCount, 1)
    await http.setYears([1900])
    let during = try await api.catalogYears(library: "music")
    XCTAssertEqual(during.bounds, 1900...1900)
    await http.setYears([2025])
    try await http.releaseRoots(0, ids: ["music"])
    _ = try await refresh.value
    let fresh = try await api.catalogYears(library: "music")
    XCTAssertEqual(
      fresh.bounds, 2025...2025,
      "Accepted permissions retire facets admitted while refresh was suspended")
    let failed = Task { try await api.musicLibraries(refresh: true) }
    for _ in 0..<100 {
      if await http.rootRequestCount() == 2 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    await http.setYears([1800])
    let beforeFailure = try await api.catalogYears(library: "music")
    XCTAssertEqual(beforeFailure.bounds, 1800...1800)
    try await http.releaseRoots(1, ids: [], status: 503)
    do {
      _ = try await failed.value
      XCTFail("Transient permission failure")
    } catch {
      guard case PlaybackProblem.httpStatus(let status) = error else {
        return XCTFail("Expected the existing numeric HTTP failure contract")
      }
      XCTAssertEqual(status, 503)
    }
    await http.setYears([2010])
    let recovered = try await api.catalogYears(library: "music")
    XCTAssertEqual(
      recovered.bounds, 2010...2010, "Failed refresh cannot bless an in-flight facet generation")
  }
  func testReversedRootRefreshRejectsOldPayloadBeforeDecodeAndCannotRestorePermissions()
    async throws
  {
    let http = YearHTTP()
    let api = try client(http)
    _ = try await api.musicLibraries(refresh: false)
    await http.holdRootRefreshes()
    let old = Task { try await api.musicLibraries(refresh: true) }
    for _ in 0..<100 {
      if await http.rootRequestCount() == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let fresh = Task { try await api.musicLibraries(refresh: true) }
    for _ in 0..<100 {
      if await http.rootRequestCount() == 2 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let count = await http.rootRequestCount()
    XCTAssertEqual(count, 2)
    try await http.releaseRoots(1, ids: ["other"])
    let accepted = try await fresh.value
    XCTAssertEqual(accepted.map(\.id), ["other"])
    try await http.releaseRoots(0, ids: ["music"], malformed: true)
    do {
      _ = try await old.value
      XCTFail("Retired refresh")
    } catch {
      XCTAssertTrue(error is CancellationError, "Reject before decoding the malformed old payload")
    }
    let before = await http.requests.count
    do {
      _ = try await api.catalogYears(library: "music")
      XCTFail("Removed root")
    } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
    let after = await http.requests.count
    XCTAssertEqual(after, before)
    let roots = try await api.musicLibraries(refresh: false)
    XCTAssertEqual(roots.map(\.id), ["other"])
  }
  func testSharedAbsoluteRangeSurvivesArtistOptionsAndFullNumericExcludesUnknown() throws {
    var preferences = CatalogBrowsePreferences()
    let numeric = CatalogYearRange(lower: 1951, upper: 2025)!
    preferences.years = numeric
    var artist = preferences.options(for: .artists)
    XCTAssertTrue(artist.years.isAll)
    artist.favoritesOnly = true
    artist.sort = .titleDescending
    preferences.accept(artist, for: .artists)
    XCTAssertEqual(preferences.years, numeric)
    XCTAssertEqual(preferences.options(for: .albums).years, numeric)
    XCTAssertEqual(preferences.options(for: .songs).years, numeric)
    XCTAssertTrue(preferences.options(for: .songs).favoritesOnly)
    XCTAssertFalse(numeric.contains(nil))
    XCTAssertTrue(CatalogYearRange.all.contains(nil))
    let unknown = try CatalogYearFacet([])
    XCTAssertEqual(try unknown.wireYears(for: numeric), "")
    XCTAssertEqual(
      preferences.years, numeric, "Empty/new root metadata never clamps stored preference")
  }
  @MainActor func testBrowserFacetScopeArtistSearchSuppressionAndStableFavoritesBounds()
    async throws
  {
    let api = YearCatalog()
    let browser = MusicBrowser(service: api)
    await browser.start()
    try await settle { browser.resultsAreCurrent }
    let initial = browser.scope
    await api.holdFacet()
    browser.loadYears(scope: initial)
    for _ in 0..<100 {
      if await api.heldCount() == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(browser.yearsLoading)
    browser.selectLibrary("other")
    browser.loadYears(scope: initial)
    let sampled4 = await api.yearRequests.count
    XCTAssertEqual(sampled4, 1, "Stale entry rejected before provider access")
    await api.releaseFacet(.success(try CatalogYearFacet([1900])))
    browser.loadYears(scope: browser.scope)
    try await settle { browser.releaseYearsLoaded }
    XCTAssertEqual(browser.releaseYearBounds, 2010...2010)
    var options = browser.options
    options.favoritesOnly = true
    options.years = CatalogYearRange(lower: 1800, upper: 1900)!
    browser.selectOptions(options)
    browser.loadYears(scope: browser.scope)
    XCTAssertEqual(
      browser.releaseYearBounds, 2010...2010,
      "Stable whole-library bounds, not favorite/range subset")
    let calls = await api.yearRequests.count
    browser.selectCategory(.artists)
    browser.loadYears(scope: browser.scope)
    XCTAssertTrue(browser.options.years.isAll)
    let search = try XCTUnwrap(browser.searchBrowser())
    search.loadYears(scope: search.scope)
    let sampled5 = await api.yearRequests.count
    XCTAssertEqual(sampled5, calls)
    browser.selectCategory(.songs)
    XCTAssertEqual(browser.options.years, options.years)
    browser.selectLibrary("empty")
    browser.loadYears(scope: browser.scope)
    try await settle { browser.releaseYearsLoaded }
    XCTAssertNil(browser.releaseYearBounds)
    XCTAssertEqual(browser.options.years, options.years)
    browser.retire()
    XCTAssertNil(browser.releaseYearBounds)
    browser.loadYears(scope: initial)
    let sampled6 = await api.yearRequests.count
    XCTAssertEqual(sampled6, calls + 1)
  }
}
