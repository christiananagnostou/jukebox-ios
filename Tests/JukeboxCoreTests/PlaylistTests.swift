import Synchronization
import XCTest

@testable import JukeboxCore

@MainActor final class PlaylistAPITests: XCTestCase {
  private final class Lifetime { var active = true }
  private struct PagedPlaylistServer: HTTPTransport {
    let http: ScriptedHTTP
    func send(_ request: URLRequest) async throws -> HTTPReply {
      if request.url?.deletingLastPathComponent().lastPathComponent == "Playlists" {
        return HTTPReply(data: Data(), status: 404)
      }
      return try await http.send(request)
    }
  }
  private func client(_ http: ScriptedHTTP, manifests: Bool = false) throws -> JellyfinClient {
    try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test/base"), userID: "listener", username: "Invented"
      ), token: "invented-token", deviceID: "test",
      transport: manifests ? http as any HTTPTransport : PagedPlaylistServer(http: http))
  }
  private func page(_ rows: [[String: Any]], total: Int? = nil, at start: Int = 0) -> [String: Any]
  {
    ["Items": rows, "TotalRecordCount": total ?? rows.count, "StartIndex": start]
  }
  private let summary = ["Type": "Playlist", "MediaType": "Audio", "Id": "mix", "Name": "Test mix"]
  private func query(_ request: URLRequest) -> [String: String] {
    let fields = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
  }

  private func parentHTTP(verified: Bool) -> ScriptedHTTP {
    ScriptedHTTP { request in
      let url = request.url!
      let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
      let q = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
      var body: [String: Any]
      if url.lastPathComponent == "UserViews" {
        body = [
          "Items": [
            [
              "Type": "CollectionFolder", "Id": "music", "Name": "Music", "CollectionType": "music",
            ],
            [
              "Type": "CollectionFolder", "Id": "second", "Name": "Second",
              "CollectionType": "music",
            ],
          ]
        ]
      } else if url.path.hasSuffix("/mix/Images/Primary") {
        return HTTPReply(data: Data([1, 2, 3]), status: 200)
      } else if url.lastPathComponent == "mix" {
        body = ["ItemIds": ["b", "a", "b"]]
      } else if url.path.hasSuffix("/mix/Items") {
        let rows: [[String: Any]] = ["b", "a", "b"].map { id in
          [
            "Type": "Audio", "Id": id, "ParentId": id == "b" ? "parent-b" : "parent-a",
            "AlbumId": "untrusted-album",
            "Name": q["EnableImages"] == "true" ? id as Any : [0] as Any,
          ]
        }
        body = ["Items": rows, "StartIndex": 0, "TotalRecordCount": rows.count]
      } else if q["IncludeItemTypes"] == "Playlist" {
        body = [
          "Items": [
            [
              "Type": "Playlist", "MediaType": "Audio", "Id": "mix",
              "Name": verified ? "Mix" as Any : [0] as Any,
              "ChildCount": 99, "ImageTags": verified ? ["Primary": "mix-art"] as Any : [0] as Any,
            ]
          ], "StartIndex": 0, "TotalRecordCount": 1,
        ]
      } else if q["ParentId"] == "music", q["IncludeItemTypes"] == "Folder,MusicAlbum",
        q["Ids"] == nil
      {
        body = [
          "Items": [
            ["Type": "Folder", "Id": "parent-a", "Name": [0]],
            ["Type": "MusicAlbum", "Id": verified ? "parent-b" : "other", "Name": [0]],
          ]
        ]
      } else {
        body = ["Items": [], "StartIndex": 0, "TotalRecordCount": 0]
      }
      return HTTPReply(data: try! JSONSerialization.data(withJSONObject: body), status: 200)
    }
  }
  func testFirstPlaylistAndImmediateTapUseCurrentPhysicalMusicParents() async throws {
    let http = parentHTTP(verified: true)
    let api = try client(http, manifests: true)
    var updates: [[String]] = []
    let lists = try await api.playlists(
      library: "music", isCurrent: { true }, onUpdate: { updates.append($0.map(\.id)) })
    XCTAssertEqual(lists.map(\.title), ["Mix"])
    XCTAssertEqual(updates, [["mix"]])
    let songs = try await api.playlistTracks(
      library: "music", playlistID: "mix", isCurrent: { true })
    XCTAssertEqual(songs.map(\.title), ["b", "a", "b"])
    let requests = await http.requests.map(query)
    XCTAssertEqual(requests.filter { $0["IncludeItemTypes"] == "Folder,MusicAlbum" }.count, 2)
    XCTAssertFalse(requests.contains { $0["IncludeItemTypes"] == "Audio" })
  }
  func testVerifiedPlaylistCoverAndOccurrenceCountComeFromTheIndex() async throws {
    let http = parentHTTP(verified: true)
    let api = try client(http, manifests: true)
    let lists = try await api.playlists(library: "music", isCurrent: { true }, onUpdate: { _ in })
    let playlist = try XCTUnwrap(lists.first)
    XCTAssertEqual(playlist.songCount, 3)
    let cover = try XCTUnwrap(playlist.artworkItem)
    XCTAssertEqual(cover.imageID, playlist.id)
    let initial = await http.requests
    XCTAssertFalse(initial.contains { $0.url?.path.contains("/Images/") == true })
    let index = try XCTUnwrap(initial.map(query).first { $0["IncludeItemTypes"] == "Playlist" })
    XCTAssertEqual(index["EnableImages"], "true")
    XCTAssertEqual(index["EnableImageTypes"], "Primary")
    let data = try await api.artwork(item: cover)
    XCTAssertEqual(data, Data([1, 2, 3]))
    let last = await http.requests.last
    let request = try XCTUnwrap(last)
    XCTAssertEqual(request.url?.path, "/base/Items/mix/Images/Primary")
    XCTAssertEqual(query(request)["tag"], "mix-art")
  }
  func testMissingPlaylistArtAndUnknownCountStillAllowAnAuthorizedList() throws {
    let data = Data(
      #"{"Type":"Playlist","MediaType":"Audio","Id":"mix","Name":"Mix","ImageTags":{},"ChildCount":-1}"#
        .utf8)
    let decoder = JSONDecoder()
    XCTAssertNil(try decoder.decode(PlaylistSummaryDTO.self, from: data).playlist)
    decoder.userInfo[PlaylistSummaryDTO.confirmedMusic] = ["mix": 0]
    let summary = try XCTUnwrap(decoder.decode(PlaylistSummaryDTO.self, from: data).playlist)
    XCTAssertEqual(summary.title, "Mix")
    XCTAssertNil(summary.artworkItem)
    XCTAssertEqual(summary.songCount, 0)
  }
  func testEqualSizedFolderResultCannotAuthorizeAnOutsideEntryOrItsPlaylistName() async throws {
    let http = parentHTTP(verified: false)
    let api = try client(http, manifests: true)
    let lists = try await api.playlists(
      library: "music", isCurrent: { true }, onUpdate: { _ in XCTFail("Unverified name published") }
    )
    XCTAssertTrue(lists.isEmpty)
    let requests = await http.requests.map(query)
    XCTAssertTrue(
      requests.contains { $0["ParentId"] == "music" && $0["IncludeItemTypes"] == "Audio" })
  }
  func testReturningToPlaylistsReusesTheIndexAndLibrarySwitchDropsIt() async throws {
    let http = parentHTTP(verified: true)
    let api = try client(http, manifests: true)
    let browser = MusicBrowser(service: api)
    await browser.start()
    let owner = browser.scope
    await browser.loadPlaylistIndex(scope: owner)
    XCTAssertEqual(browser.playlistIndex.items?.map(\.title), ["Mix"])
    let before = await http.requests.map(query).filter { $0["IncludeItemTypes"] == "Playlist" }
      .count
    await browser.loadPlaylistIndex(scope: owner)
    let after = await http.requests.map(query).filter { $0["IncludeItemTypes"] == "Playlist" }.count
    XCTAssertEqual(after, before)
    await browser.loadPlaylistIndex(scope: owner, refresh: true)
    let refresh = await http.requests.map(query).filter { $0["IncludeItemTypes"] == "Playlist" }
      .count
    XCTAssertEqual(refresh, before + 1)
    browser.selectLibrary("second")
    XCTAssertNil(browser.playlistIndex.items)
    await browser.loadPlaylistIndex(scope: owner)
    XCTAssertNil(browser.playlistIndex.items)
    browser.retire()
  }

  func testIndexLoadFinishesAfterNavigationAndOneRefreshKeepsRowsThroughANetworkFailure()
    async throws
  {
    let http = parentHTTP(verified: true)
    let browser = MusicBrowser(service: try client(http, manifests: true))
    await browser.start()
    let owner = browser.scope
    await http.holdNext("mix")
    let first = Task { await browser.loadPlaylistIndex(scope: owner) }
    for _ in 0..<200 where !(await http.waiting) { try await Task.sleep(for: .milliseconds(5)) }
    let held = await http.waiting
    XCTAssertTrue(held)
    first.cancel()
    let returned = Task { await browser.loadPlaylistIndex(scope: owner) }
    await http.release()
    await first.value
    await returned.value
    XCTAssertEqual(browser.playlistIndex.items?.map(\.id), ["mix"])
    let reads = await http.requests.map(query).filter { $0["IncludeItemTypes"] == "Playlist" }.count
    XCTAssertEqual(reads, 1)
    await http.holdNext("mix")
    let refresh = Task { await browser.loadPlaylistIndex(scope: owner, refresh: true) }
    for _ in 0..<200 where !(await http.waiting) { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(browser.playlistIndex.items?.map(\.id), ["mix"])
    await http.release(error: URLError(.notConnectedToInternet))
    await refresh.value
    XCTAssertEqual(browser.playlistIndex.items?.map(\.id), ["mix"])
    XCTAssertNotNil(browser.playlistIndex.error)
    await http.holdNext("mix")
    let denied = Task { await browser.loadPlaylistIndex(scope: owner) }
    for _ in 0..<200 where !(await http.waiting) { try await Task.sleep(for: .milliseconds(5)) }
    await http.release(error: ClientError.unauthorized)
    await denied.value
    XCTAssertNil(browser.playlistIndex.items)
    XCTAssertNotEqual(browser.scope, owner)
  }

  func testIndexPagesByRawRowsAndAdmitsAnEmptyAudioPlaylistOnlyWithACompleteManifest() async throws
  {
    let http = ScriptedHTTP { request in
      let url = request.url!
      let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let offset = q.first { $0.name == "StartIndex" }?.value ?? "0"
      let body: [String: Any]
      if url.lastPathComponent == "UserViews" {
        body = [
          "Items": [
            ["Type": "CollectionFolder", "CollectionType": "music", "Id": "music", "Name": "Music"]
          ]
        ]
      } else if url.path.hasSuffix("/Playlists/mix") {
        body = ["ItemIds": []]
      } else if url.path.hasSuffix("/Playlists/other") {
        return HTTPReply(data: Data(), status: 404)
      } else if url.path.hasSuffix("/Playlists/other/Items") {
        body = ["Items": [], "TotalRecordCount": 0]
      } else if offset == "0" {
        body = [
          "Items": [
            ["Type": "Playlist", "MediaType": "Audio", "Id": "mix", "Name": "Empty"],
            ["Type": "Playlist", "MediaType": "Video", "Name": [0]],
          ], "TotalRecordCount": 3, "StartIndex": 0,
        ]
      } else {
        body = [
          "Items": [["Type": "Playlist", "MediaType": "Audio", "Id": "other", "Name": [0]]],
          "TotalRecordCount": 3, "StartIndex": 2,
        ]
      }
      return HTTPReply(data: try! JSONSerialization.data(withJSONObject: body), status: 200)
    }
    let lists = try await client(http, manifests: true).playlists(
      library: "music", isCurrent: { true })
    XCTAssertEqual(lists.map(\.id), ["mix"])
    XCTAssertEqual(lists.first?.songCount, 0)
    let requests = await http.requests
    let pages = requests.filter { query($0)["IncludeItemTypes"] == "Playlist" }
    XCTAssertEqual(pages.map { query($0)["StartIndex"] }, ["0", "2"])
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    XCTAssertTrue(
      pages.allSatisfy { query($0)["UserId"] == "listener" && query($0)["ParentId"] == nil })
  }
  func testExcessivePlaylistIndexCountStopsBeforeReadingNextPage() async throws {
    let http = ScriptedHTTP([(200, page([summary], total: 2_049))], musicRoot: true)
    do {
      _ = try await client(http).playlists(library: "music", isCurrent: { true })
      XCTFail("Accepted an excessive collection")
    } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
    let requests = await http.requests
    XCTAssertEqual(requests.count, 2)
  }

  func testUntypedPlaylistsReadNamesOnlyAfterMusicProofAndPreserveIndexOrder() async throws {
    let absentType: [String: Any] = ["Type": "Playlist", "Id": "empty", "Name": [0]]
    let other: [String: Any] = [
      "Type": "Playlist", "MediaType": "Unknown", "Id": "other", "Name": [0],
    ]
    let visible = ["Type": "Playlist", "MediaType": "Unknown", "Id": "saved", "Name": "Saved mix"]
    let song: [String: Any] = ["Type": "Audio", "Id": "song", "Name": [0]]
    let http = ScriptedHTTP(
      [
        (200, page([visible, absentType, other, summary])),
        (200, page([song, song])),
        (200, page([song])),
        (200, page([])),
        (200, page([["Type": "Book", "Id": [0], "Name": [0]]])),
        (200, page([song])),
      ], musicRoot: true)
    var visibleTitles: [[String]] = []
    let lists = try await client(http).playlists(
      library: "music", isCurrent: { true },
      onUpdate: { visibleTitles.append($0.map(\.title)) })
    XCTAssertEqual(visibleTitles, [["Saved mix"], ["Saved mix", "Test mix"]])
    XCTAssertEqual(lists.map(\.title), ["Saved mix", "Test mix"])
    let requests = await http.requests
    XCTAssertEqual(query(requests[3])["ParentId"], "music")
    XCTAssertNil(query(requests[3])["Ids"])
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }

  func testUntypedPlaylistsShareMembershipReadsAndRequireMusicAcrossRoots() async throws {
    let roots = ["music", "second"].map {
      ["Type": "CollectionFolder", "Id": $0, "Name": $0, "CollectionType": "music"]
    }
    let cross = ["Type": "Playlist", "Id": "cross", "Name": "Across libraries"]
    let shared = ["Type": "Playlist", "Id": "shared", "Name": "Same songs"]
    let privateList: [String: Any] = ["Type": "Playlist", "Id": "private-list", "Name": [0]]
    let gone: [String: Any] = ["Type": "Playlist", "Id": "gone", "Name": [0]]
    func links(_ ids: [String]) -> [String: Any] {
      page(ids.map { ["Type": "Audio", "Id": $0, "Name": [0]] as [String: Any] })
    }
    let http = ScriptedHTTP([
      (200, ["Items": roots]), (200, page([cross, shared, gone, privateList])),
      (200, links(["a", "b", "a"])), (200, links(["a"])), (200, links(["b"])),
      (200, links(["b", "a"])), (403, [:]),
      (200, links(["a", "outside"])),
    ])
    let lists = try await client(http).playlists(library: "music", isCurrent: { true })
    XCTAssertEqual(lists.map(\.id), ["cross", "shared"])
    let requests = await http.requests
    let lookups = requests.map(query).filter { $0["ParentId"] != nil }
    XCTAssertEqual(lookups.compactMap { $0["ParentId"] }, ["music", "second"])
    XCTAssertTrue(lookups.allSatisfy { $0["Ids"] == nil })
  }

  func testLeavingTheIndexAfterItsFirstPlaylistStopsTheRemainingReads() async throws {
    let lifetime = Lifetime()
    let first = ["Type": "Playlist", "Id": "first", "Name": "First"]
    let later: [String: Any] = ["Type": "Playlist", "Id": "later", "Name": [0]]
    let song = ["Type": "Audio", "Id": "song"]
    let http = ScriptedHTTP(
      [
        (200, page([first, later])), (200, page([song])), (200, page([song])),
      ], musicRoot: true)
    var received: [[String]] = []
    do {
      _ = try await client(http).playlists(
        library: "music", isCurrent: { lifetime.active },
        onUpdate: {
          received.append($0.map(\.id))
          lifetime.active = false
        })
      XCTFail("The index finished after its caller retired")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(received, [["first"]])
    let paths = await http.paths
    XCTAssertEqual(
      paths, ["/base/UserViews", "/base/Items", "/base/Playlists/first/Items", "/base/Items"])
  }

  func testUntypedPlaylistRequiresRootedSongsAndKeepsRepeatedOccurrencesOnOpen() async throws {
    let header: [String: Any] = ["Type": "Playlist", "Id": "mix", "Name": [0]]
    let links = page([
      ["Type": "Audio", "Id": "a"], ["Type": "Audio", "Id": "b"], ["Type": "Audio", "Id": "a"],
    ])
    let http = ScriptedHTTP(
      [
        (200, page([header])), (200, links),
        (200, page([["Type": "Audio", "Id": "b"], ["Type": "Audio", "Id": "a"]])),
        (200, page([header])), (200, links), (200, page([["Type": "Audio", "Id": "a"]])),
      ], musicRoot: true)
    let api = try client(http)
    let complete = try await api.playlistTracks(
      library: "music", playlistID: "mix", isCurrent: { true })
    XCTAssertEqual(complete.map(\.id), ["a", "b", "a"])
    let partial = try await api.playlistTracks(
      library: "music", playlistID: "mix", isCurrent: { true })
    XCTAssertTrue(partial.isEmpty)
  }

  func testPlaylistReconstructsRepeatedSongsInServerOrderAcrossPagesFromRootedMetadata()
    async throws
  {
    let a: [String: Any] = ["Type": "Audio", "Id": "a", "PlaylistItemId": "shared", "Name": [1]]
    let http = ScriptedHTTP(
      [
        (200, page([summary])),
        (
          200,
          page(
            [
              a, ["Type": "Audio", "Id": "outside", "Name": [1]],
              ["Type": "Video", "Id": [1], "Name": [1]],
            ], total: 5)
        ),
        (200, page([["Type": "Audio", "Id": "b"], a], total: 5, at: 3)),
        (
          200,
          [
            "TotalRecordCount": 2, "StartIndex": 0,
            "Items": [
              ["Type": "Audio", "Id": "b", "Name": "B"], ["Type": "Audio", "Id": "a", "Name": "A"],
            ],
          ]
        ),
      ], musicRoot: true)
    let tracks = try await client(http).playlistTracks(
      library: "music", playlistID: "mix", isCurrent: { true })
    XCTAssertEqual(tracks.map(\.title), ["A", "B", "A"])
    let requests = await http.requests
    XCTAssertEqual(
      requests.map { $0.url!.path },
      [
        "/base/UserViews", "/base/Items", "/base/Playlists/mix/Items", "/base/Playlists/mix/Items",
        "/base/Items",
      ])
    XCTAssertEqual(query(requests[1])["Ids"], "mix")
    XCTAssertNil(query(requests[2])["SortBy"])
    XCTAssertEqual(query(requests[3])["StartIndex"], "3")
    XCTAssertEqual(query(requests[4])["ParentId"], "music")
    XCTAssertEqual(query(requests[4])["IncludeItemTypes"], "Audio")
    XCTAssertNil(query(requests[4])["Ids"])
    XCTAssertTrue(
      requests.allSatisfy { $0.httpMethod == "GET" && query($0)["UserId"] == "listener" })
    let source = PlaylistContents.Source(id: "mix", library: "music", scope: UUID())
    let contents = PlaylistContents(tracks, source: source)
    XCTAssertEqual(Set(contents.rows.map(\.id)).count, 3)
    XCTAssertEqual(contents.rows.map(\.id), PlaylistContents(tracks, source: source).rows.map(\.id))
  }

  func testAnIncompletePlaylistCannotStartAPartialQueue() async throws {
    let http = ScriptedHTTP(
      [
        (200, page([summary])), (200, page([["Type": "Audio", "Id": "a"]], total: 2)),
        (200, page([], total: 2, at: 1)),
      ], musicRoot: true)
    do {
      _ = try await client(http).playlistTracks(
        library: "music", playlistID: "mix", isCurrent: { true })
      XCTFail("An incomplete playlist was accepted")
    } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
    let requests = await http.requests
    XCTAssertEqual(requests.count, 4)
  }
  func testReplayedPageIsRejectedEvenWhenRepeatingThatSongWouldBeValid() async throws {
    let repeated = [["Type": "Audio", "Id": "a"]]
    let http = ScriptedHTTP(
      [
        (200, page([summary])), (200, page(repeated, total: 2)), (200, page(repeated, total: 2)),
      ], musicRoot: true)
    do {
      _ = try await client(http).playlistTracks(
        library: "music", playlistID: "mix", isCurrent: { true })
      XCTFail("The same page was accepted twice")
    } catch {
      XCTAssertEqual(error as? ClientError, .invalidResponse)
    }
    let paths = await http.paths
    XCTAssertEqual(paths.last, "/base/Playlists/mix/Items")
  }
  func testEmptyPlaylistReturnsAnEmptySelectionWithoutLookingUpAudio() async throws {
    let http = ScriptedHTTP([(200, page([summary])), (200, page([]))], musicRoot: true)
    let tracks = try await client(http).playlistTracks(
      library: "music", playlistID: "mix", isCurrent: { true })
    XCTAssertTrue(tracks.isEmpty)
    let paths = await http.paths
    XCTAssertEqual(paths, ["/base/UserViews", "/base/Items", "/base/Playlists/mix/Items"])
  }

  func testUnknownMusicRootAndMissingAudioPlaylistStopBeforeReadingEntries() async throws {
    let http = ScriptedHTTP([(200, page([]))], musicRoot: true)
    let service = try client(http)
    for library in ["unknown", "music"] {
      do {
        _ = try await service.playlistTracks(
          library: library, playlistID: "mix", isCurrent: { true })
        XCTFail("An unverified playlist was accepted")
      } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
    }
    let paths = await http.paths
    XCTAssertEqual(paths, ["/base/UserViews", "/base/Items"])
  }
  func testRetiredPlaylistRequestDiscardsItsResponseBeforeEntryLookup() async throws {
    let lifetime = Lifetime()
    let http = ScriptedHTTP([(200, page([summary]))], musicRoot: true)
    let service = try client(http)
    await http.holdNext("Items")
    let request = Task {
      try await service.playlistTracks(
        library: "music", playlistID: "mix", isCurrent: { lifetime.active })
    }
    for _ in 0..<200 {
      if await http.waiting { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    let wasHeld = await http.waiting
    XCTAssertTrue(wasHeld)
    lifetime.active = false
    await http.release()
    do {
      _ = try await request.value
      XCTFail("A retired playlist request returned music")
    } catch { XCTAssertTrue(error is CancellationError) }
    let paths = await http.paths
    XCTAssertEqual(paths, ["/base/UserViews", "/base/Items"])
  }
  func testLongIdentifiersStayOutOfTheQueryAndRepeatedOccurrencesKeepTheirOrder() async throws {
    let ids = (0..<45).map { String(repeating: "a", count: 125) + String(format: "%03d", $0) }
    let ordered = ids + [ids[0]]
    let http = ScriptedHTTP { request in
      let url = request.url!
      let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
      let rows: [[String: String]]
      if url.lastPathComponent == "UserViews" {
        rows = [
          ["Type": "CollectionFolder", "CollectionType": "music", "Id": "music", "Name": "Music"]
        ]
      } else if url.path.hasSuffix("/mix/Items") {
        rows = ordered.map { ["Type": "Audio", "Id": $0] }
      } else if q.contains(where: { $0.name == "ParentId" }) {
        rows = ids.reversed().map { ["Type": "Audio", "Id": $0] }
      } else {
        rows = [["Type": "Playlist", "MediaType": "Audio", "Id": "mix", "Name": "Mix"]]
      }
      let body = try! JSONSerialization.data(withJSONObject: [
        "Items": rows, "StartIndex": 0, "TotalRecordCount": rows.count,
      ])
      return HTTPReply(data: body, status: 200)
    }
    let songs = try await client(http).playlistTracks(
      library: "music", playlistID: "mix", isCurrent: { true })
    XCTAssertEqual(songs.map(\.id), ordered)
    let requests = await http.requests
    let lookups = requests.filter { query($0)["ParentId"] == "music" }
    XCTAssertEqual(lookups.count, 1)
    XCTAssertNil(query(lookups[0])["Ids"])
  }

  func testBrowsingALargeUntypedPlaylistBoundsMusicMembershipRequests() async throws {
    let ids = (0..<7_790).map { String(format: "%032x", $0) }
    let http = ScriptedHTTP { request in
      let url = request.url!
      let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
      let query = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
      let start = Int(query["StartIndex"] ?? "") ?? 0
      var total = 1
      let rows: [[String: String]]
      if url.lastPathComponent == "UserViews" {
        rows = [
          ["Type": "CollectionFolder", "Id": "music", "Name": "Music", "CollectionType": "music"]
        ]
      } else if url.path.hasSuffix("/Playlists/mix/Items") {
        let limit = Int(query["Limit"] ?? "") ?? 0
        total = ids.count
        rows = ids.dropFirst(start).prefix(limit).map { ["Type": "Audio", "Id": $0] }
      } else if query["ParentId"] == "music", query["IncludeItemTypes"] == "Audio",
        query["Ids"] == nil
      {
        total = ids.count
        rows = ids.dropFirst(start).prefix(Int(query["Limit"] ?? "") ?? total).map {
          ["Type": "Audio", "Id": $0]
        }
      } else if query["IncludeItemTypes"] == "Playlist" {
        rows = [["Type": "Playlist", "Id": "mix", "Name": "Large mix"]]
      } else {
        return HTTPReply(data: Data(), status: 400)
      }
      let data = try! JSONSerialization.data(
        withJSONObject: ["Items": rows, "StartIndex": start, "TotalRecordCount": total])
      return HTTPReply(data: data, status: 200)
    }
    let lists = try await client(http).playlists(library: "music", isCurrent: { true })
    XCTAssertEqual(lists.map(\.title), ["Large mix"])
    let requests = await http.requests
    XCTAssertEqual(requests.count, 34)
    XCTAssertTrue(requests.allSatisfy { query($0)["Ids"] == nil })
  }
  func testLargeCompactManifestGetsCompleteOrderedMetadataFromPositiveRootPages() async throws {
    let ids = (1...7790).map { String(format: "%032x", $0) }
    let ordered = [ids[70], ids[2], ids[70]] + ids
    let dashed = ordered.map { id in
      let s = id.uppercased()
      return [
        s.prefix(8), s.dropFirst(8).prefix(4), s.dropFirst(12).prefix(4), s.dropFirst(16).prefix(4),
        s.suffix(12),
      ].joined(separator: "-")
    }
    let http = ScriptedHTTP { request in
      let url = request.url!
      let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
      let q = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
      let body: [String: Any]
      if url.lastPathComponent == "UserViews" {
        body = [
          "Items": [
            ["Type": "CollectionFolder", "Id": "music", "Name": "Music", "CollectionType": "music"]
          ]
        ]
      } else if url.path.hasSuffix("/Playlists/mix") {
        body = ["ItemIds": dashed, "Shares": [0], "Name": [0]]
      } else if q["ParentId"] == "music", q["IncludeItemTypes"] == "Audio", q["Ids"] == nil {
        let start = Int(q["StartIndex"]!)!
        let rows = ids.dropFirst(start).prefix(Int(q["Limit"]!)!).map {
          ["Type": "Audio", "Id": $0, "Name": "Song"]
        }
        body = ["Items": rows, "StartIndex": start, "TotalRecordCount": ids.count]
      } else if q["IncludeItemTypes"] == "Playlist" {
        body = [
          "Items": [["Type": "Playlist", "Id": "mix", "Name": "Large mix"]], "StartIndex": 0,
          "TotalRecordCount": 1,
        ]
      } else {
        return HTTPReply(data: Data(), status: 400)
      }
      return HTTPReply(data: try! JSONSerialization.data(withJSONObject: body), status: 200)
    }
    let service = try client(http, manifests: true)
    let lists = try await service.playlists(library: "music", isCurrent: { true })
    XCTAssertEqual(lists.map(\.id), ["mix"])
    let index = await http.requests
    let checks = index.map(query).filter { $0["ParentId"] != nil }
    XCTAssertEqual(checks.count, 16)
    XCTAssertTrue(checks.allSatisfy { $0["Limit"] == "500" && $0["Ids"] == nil })
    XCTAssertFalse(index.contains { $0.url!.path.hasSuffix("/mix/Items") })
    let songs = try await service.playlistTracks(
      library: "music", playlistID: "mix", isCurrent: { true })
    XCTAssertEqual(songs.map(\.id), ordered)
    let requests = await http.requests
    let metadata = requests.dropFirst(index.count).map(query).filter { $0["ParentId"] != nil }
    XCTAssertEqual(metadata.count, 16)
    XCTAssertTrue(metadata.allSatisfy { $0["Ids"] == nil && $0["ParentId"] == "music" })
  }

  private func largePlaylistHTTP(_ ids: [String], manifest: @escaping @Sendable () -> [String])
    -> ScriptedHTTP
  {
    ScriptedHTTP { request in
      let url = request.url!
      let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
      let q = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
      let start = Int(q["StartIndex"] ?? "") ?? 0
      let limit = Int(q["Limit"] ?? "") ?? 500
      let body: [String: Any]
      if url.lastPathComponent == "UserViews" {
        body = [
          "Items": [
            ["Type": "CollectionFolder", "Id": "music", "Name": "Music", "CollectionType": "music"]
          ]
        ]
      } else if url.lastPathComponent == "large" {
        body = ["ItemIds": manifest()]
      } else if url.lastPathComponent == "other" {
        body = ["ItemIds": [ids[2], ids[71], ids[2]]]
      } else if q["IncludeItemTypes"] == "Playlist" {
        let rows = ["large", "other"].map { ["Type": "Playlist", "Id": $0, "Name": $0] }
        body = ["Items": rows, "StartIndex": 0, "TotalRecordCount": 2]
      } else if q["IncludeItemTypes"] == "Audio", q["ParentId"] == "music", q["Ids"] == nil {
        let rows = ids.dropFirst(start).prefix(limit).map {
          [
            "Type": "Audio", "Id": $0, "Name": "Music " + $0, "Artists": ["Artist"],
            "ImageTags": ["Primary": "cover"],
          ] as [String: Any]
        }
        body = ["Items": rows, "StartIndex": start, "TotalRecordCount": ids.count]
      } else {
        body = ["Items": [], "StartIndex": 0, "TotalRecordCount": 0]
      }
      return HTTPReply(data: try! JSONSerialization.data(withJSONObject: body), status: 200)
    }
  }

  func testLargePlaylistIsReadyAtPublicationAndReturnsWithoutReadingTheLibraryAgain() async throws {
    let ids = (0..<7_788).map { "track-\($0)" }
    let order = [ids[71], ids[2], ids[71]] + ids.dropFirst()
    let saved = Mutex(Array(order))
    let http = largePlaylistHTTP(ids) { saved.withLock { $0 } }
    let browser = MusicBrowser(service: try client(http, manifests: true))
    await browser.start()
    let scope = browser.scope
    await http.holdNext("other")
    let index = Task { await browser.loadPlaylistIndex(scope: scope) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await http.waiting), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let held = await http.waiting
    XCTAssertTrue(held)
    defer { Task { await http.release() } }
    let large = try XCTUnwrap(browser.playlistIndex.items?.first)
    XCTAssertTrue(browser.playlistIndex.loading)
    let atPublication = try XCTUnwrap(browser.cachedPlaylistContents(large, scope: scope))
    XCTAssertEqual(atPublication.rows.count, 7_790)
    XCTAssertEqual(atPublication.tracks.map(\.id), order)
    XCTAssertEqual(atPublication.tracks.first?.artist, "Artist")
    XCTAssertEqual(atPublication.tracks.first?.imageTag, "cover")
    XCTAssertNotEqual(atPublication.rows[0].id, atPublication.rows[2].id)
    let before = await http.requests.count
    let opened = try await browser.playlistContents(large, scope: scope)
    XCTAssertEqual(opened.tracks.map(\.id), order)
    let after = await http.requests.count
    XCTAssertEqual(before, after)
    await http.release()
    await index.value
    let other = try XCTUnwrap(browser.playlistIndex.items?.last)
    let beforeReturn = await http.requests.count
    let switched = try await browser.playlistContents(other, scope: scope)
    XCTAssertEqual(switched.tracks.map(\.id), [ids[2], ids[71], ids[2]])
    let returned = try await browser.playlistContents(large, scope: scope)
    XCTAssertEqual(returned.rows.map(\.id), opened.rows.map(\.id))
    let requests = await http.requests
    XCTAssertEqual(requests.count, beforeReturn)
    XCTAssertEqual(requests.map(query).filter { $0["IncludeItemTypes"] == "Audio" }.count, 16)

    saved.withLock { $0.swapAt(0, 1) }
    await browser.loadPlaylistIndex(scope: scope, refresh: true)
    XCTAssertFalse(browser.acceptsPlaylist(atPublication.source))
    XCTAssertEqual(
      browser.cachedPlaylistContents(large, scope: scope)?.tracks.map(\.id), saved.withLock { $0 })
    saved.withLock { $0[100] = "outside" }
    await browser.loadPlaylistIndex(scope: scope, refresh: true)
    XCTAssertEqual(browser.playlistIndex.items?.map(\.id), ["other"])
    XCTAssertNil(browser.cachedPlaylistContents(large, scope: scope))
    XCTAssertFalse(browser.acceptsPlaylist(returned.source))
    browser.retire()
    XCTAssertNil(browser.cachedPlaylistContents(other, scope: scope))
  }

  func testColdLaunchRestoresLargeOrderedPlaylistBeforeNetworkAndRefreshesInPlace() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ids = (0..<7788).map { "track-\($0)" }
    let original = [ids[4], ids[2], ids[4]] + ids.dropFirst()
    let order = Mutex(Array(original))
    let http = largePlaylistHTTP(ids) { order.withLock { $0 } }
    func launch() async throws -> MusicBrowser {
      let storage = try LibraryStorage(directory: directory)
      let account = String(repeating: "a", count: 64)
      let lease = await storage.lease(account: account)
      let browser = MusicBrowser(
        service: try client(http, manifests: true),
        playlistSnapshot: .init(storage: storage, account: account, lease: lease))
      await browser.start()
      return browser
    }
    let first = try await launch()
    await first.loadPlaylistIndex(scope: first.scope)
    let large = try XCTUnwrap(first.playlistIndex.items?.first)
    let old = try XCTUnwrap(first.cachedPlaylistContents(large, scope: first.scope))
    first.retire()
    order.withLock { $0.swapAt(0, 1) }
    let next = try await launch()
    let scope = next.scope
    await http.holdNext("large")
    defer { Task { await http.release() } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while next.playlistIndex.restoring, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let immediate = try await next.playlistContents(large, scope: scope)
    XCTAssertEqual(immediate.rows.map(\.id), old.rows.map(\.id))
    let refresh = Task { await next.loadPlaylistIndex(scope: scope) }
    while !(await http.waiting), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let held = await http.waiting
    XCTAssertTrue(held)
    XCTAssertTrue(next.playlistIndex.loading)
    XCTAssertEqual(next.playlistIndex.items?.map(\.id), ["large", "other"])
    let beforeTap = await http.requests.count
    let restored = try await next.playlistContents(large, scope: scope)
    XCTAssertEqual(restored.tracks.map(\.id), original)
    XCTAssertEqual(restored.rows.map(\.id), old.rows.map(\.id))
    XCTAssertTrue(next.acceptsPlaylist(restored.source))
    XCTAssertFalse(next.acceptsPlaylist(old.source))
    let afterTap = await http.requests.count
    XCTAssertEqual(beforeTap, afterTap)
    await http.release(error: URLError(.notConnectedToInternet))
    await refresh.value
    XCTAssertNotNil(next.playlistIndex.error)
    XCTAssertEqual(next.cachedPlaylistContents(large, scope: scope)?.tracks.map(\.id), original)
    await next.loadPlaylistIndex(scope: scope, refresh: true)
    XCTAssertEqual(
      next.cachedPlaylistContents(large, scope: scope)?.tracks.map(\.id), order.withLock { $0 })
    XCTAssertFalse(next.acceptsPlaylist(restored.source))
    order.withLock { $0[100] = "no-longer-in-music" }
    await next.loadPlaylistIndex(scope: scope, refresh: true)
    XCTAssertEqual(next.playlistIndex.items?.map(\.id), ["other"])
    next.retire()
    let third = try await launch()
    let end = ContinuousClock.now.advanced(by: .seconds(5))
    while third.playlistIndex.restoring, ContinuousClock.now < end {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(third.playlistIndex.items?.map(\.id), ["other"])
    XCTAssertNil(third.cachedPlaylistContents(large, scope: third.scope))
  }

  func testUnreadablePlaylistSnapshotFallsBackToJellyfinAndCanBeReplaced() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try LibraryStorage(directory: directory)
    let account = String(repeating: "a", count: 64)
    let access = PlaylistSnapshotAccess(
      storage: storage, account: account, lease: await storage.lease(account: account))
    try await storage.savePlaylists([], details: [], access: access, library: "music")
    let file = directory.appendingPathComponent(account + ".playlists/music.plist")
    try Data("incomplete write".utf8).write(to: file)
    let browser = MusicBrowser(
      service: try client(parentHTTP(verified: true), manifests: true), playlistSnapshot: access)
    await browser.start()
    await browser.loadPlaylistIndex(scope: browser.scope)
    XCTAssertNil(browser.playlistIndex.error)
    let live = try XCTUnwrap(browser.playlistIndex.items)
    XCTAssertFalse(live.isEmpty)
    let saved = try await storage.savedPlaylists(access, library: "music", scope: UUID())
    XCTAssertEqual(saved?.playlists, live)
  }

  func testPlaylistSnapshotIsIsolatedByAccountLibraryAndLeaseAndIsErasedOnLogout() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    for storage in [LibraryStorage(), try LibraryStorage(directory: directory)] {
      let account = String(repeating: "a", count: 64)
      let other = String(repeating: "b", count: 64)
      let access = PlaylistSnapshotAccess(
        storage: storage, account: account, lease: await storage.lease(account: account))
      let foreign = PlaylistSnapshotAccess(
        storage: storage, account: other, lease: await storage.lease(account: other))
      let list = MusicPlaylist(id: "mix", title: "Invented", songCount: 3, primaryImageTag: "art")
      let scope = UUID()
      let songs = MusicItem.fixtureTracks
      let details = PlaylistContents(
        [songs[0], songs[1], songs[0]], source: .init(id: list.id, library: "one", scope: scope))
      try await storage.savePlaylists([list], details: [details], access: access, library: "one")
      try await storage.savePlaylists([], details: [], access: access, library: "two")
      let outside = try await storage.savedPlaylists(foreign, library: "one", scope: scope)
      let otherRoot = try await storage.savedPlaylists(access, library: "two", scope: scope)
      XCTAssertNil(outside)
      XCTAssertEqual(otherRoot?.playlists, [])
      try await storage.retainPlaylistLibraries(["one"], access: access)
      let removedRoot = try await storage.savedPlaylists(access, library: "two", scope: scope)
      XCTAssertNil(removedRoot)
      let latest = PlaylistSnapshotAccess(
        storage: storage, account: account, lease: await storage.lease(account: account))
      try await storage.clearPlaylists(access, library: "one")
      try await storage.savePlaylists([], details: [], access: access, library: "one")
      let owned = try await storage.savedPlaylists(latest, library: "one", scope: scope)
      XCTAssertEqual(
        owned?.details.contents(for: list.id)?.tracks.map(\.id), details.tracks.map(\.id))
      XCTAssertNil(owned?.details.contents(for: list.id, freshAt: .now))
      try await storage.retire(account: account, erase: true)
      let signedIn = PlaylistSnapshotAccess(
        storage: storage, account: account, lease: await storage.lease(account: account))
      let loggedOut = try await storage.savedPlaylists(signedIn, library: "one", scope: scope)
      XCTAssertNil(loggedOut)
    }
  }

  func testRejectedOptionalMetadataStillPublishesVerifiedPlaylistWithoutAPartialDetail()
    async throws
  {
    let http = ScriptedHTTP { request in
      let url = request.url!
      let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
      let body: [String: Any]
      if url.lastPathComponent == "UserViews" {
        body = [
          "Items": [
            ["Type": "CollectionFolder", "Id": "music", "Name": "Music", "CollectionType": "music"]
          ]
        ]
      } else if url.lastPathComponent == "mix" {
        body = ["ItemIds": ["song", "song"]]
      } else if q.contains(.init(name: "IncludeItemTypes", value: "Playlist")) {
        body = [
          "Items": [["Type": "Playlist", "Id": "mix", "Name": "Music mix"]], "TotalRecordCount": 1,
        ]
      } else if q.contains(.init(name: "IncludeItemTypes", value: "Audio")) {
        if q.contains(.init(name: "EnableImages", value: "true")) {
          return HTTPReply(data: Data(), status: 400)
        }
        body = ["Items": [["Type": "Audio", "Id": "song", "Name": [0]]], "TotalRecordCount": 1]
      } else {
        body = ["Items": [], "TotalRecordCount": 0]
      }
      return HTTPReply(data: try! JSONSerialization.data(withJSONObject: body), status: 200)
    }
    let browser = MusicBrowser(service: try client(http, manifests: true))
    await browser.start()
    await browser.loadPlaylistIndex(scope: browser.scope)
    let list = try XCTUnwrap(browser.playlistIndex.items?.first)
    XCTAssertEqual(list.songCount, 2)
    XCTAssertNil(browser.cachedPlaylistContents(list, scope: browser.scope))
    XCTAssertNil(browser.playlistIndex.error)
  }
  func testDetailSurvivesBackAndSharesRevalidationUntilAccessIsRemoved() async throws {
    let http = parentHTTP(verified: true)
    let browser = MusicBrowser(service: try client(http, manifests: true))
    await browser.start()
    let scope = browser.scope
    await browser.loadPlaylistIndex(scope: scope)
    let list = try XCTUnwrap(browser.playlistIndex.items?.first)
    let first = try await browser.playlistContents(list, scope: scope)
    await http.holdNext("mix")
    let one = Task { try await browser.playlistContents(list, scope: scope, refresh: true) }
    for _ in 0..<200 where !(await http.waiting) { try await Task.sleep(for: .milliseconds(5)) }
    one.cancel()
    let two = Task { try await browser.playlistContents(list, scope: scope, refresh: true) }
    await Task.yield()
    XCTAssertEqual(
      browser.cachedPlaylistContents(list, scope: scope)?.rows.map(\.id), first.rows.map(\.id))
    let before = await http.paths.filter { $0.hasSuffix("/Playlists/mix") }.count
    await http.release()
    _ = try await two.value
    do {
      _ = try await one.value
      XCTFail("Retired view received detail")
    } catch is CancellationError {}
    let after = await http.paths.filter { $0.hasSuffix("/Playlists/mix") }.count
    XCTAssertEqual(before, after)
    await http.holdNext("mix")
    let removed = Task { try await browser.playlistContents(list, scope: scope, refresh: true) }
    for _ in 0..<200 where !(await http.waiting) { try await Task.sleep(for: .milliseconds(5)) }
    await http.release(error: ClientError.forbidden)
    do {
      _ = try await removed.value
      XCTFail("Unshared playlist retained")
    } catch ClientError.forbidden {}
    XCTAssertNil(browser.cachedPlaylistContents(list, scope: scope))
    XCTAssertEqual(browser.playlistIndex.items, [])
  }

  func testDetailCacheBoundsOccurrencesAndKeepsStaleRowsAvailableDuringRefresh() {
    let track = CatalogFixtures.tracks(CatalogFixtures.album(0))[0]
    let scope = UUID()
    let now = ContinuousClock.now
    func contents(_ id: String, count: Int) -> PlaylistContents {
      PlaylistContents(
        Array(repeating: track, count: count), source: .init(id: id, library: "music", scope: scope)
      )
    }
    var cache = PlaylistDetailCache()
    cache.insert(contents("large", count: 7_790), at: now)
    XCTAssertNotNil(cache.contents(for: "large", freshAt: now.advanced(by: .seconds(59))))
    XCTAssertNil(cache.contents(for: "large", freshAt: now.advanced(by: .seconds(60))))
    XCTAssertNotNil(cache.contents(for: "large"))
    cache.insert(contents("second", count: 9_000), at: now)
    XCTAssertNil(cache.contents(for: "large"))
    cache.finishIndex(["second"], started: now.advanced(by: .seconds(1)))
    XCTAssertNil(cache.contents(for: "second", freshAt: now.advanced(by: .seconds(2))))
    XCTAssertNotNil(cache.contents(for: "second"))
    cache.insert(contents("huge", count: PlaylistDetailCache.occurrenceLimit + 1), at: now)
    XCTAssertNil(cache.contents(for: "huge"))
    XCTAssertNotNil(cache.contents(for: "second"))
  }
  func testCompactPlaylistWithUnresolvedMembersNeverReadsItsTitleOrQueuesItsPrefix() async throws {
    let ids = (0..<22).map { "track-" + String($0) }
    let header: [String: Any] = ["Type": "Playlist", "Id": "private-mix", "Name": [0]]
    let song = ["Type": "Audio", "Id": ids[0]]
    let http = ScriptedHTTP(
      [
        (200, page([header])), (200, ["ItemIds": ids]), (200, page([song])),
        (200, page([header])), (200, ["ItemIds": ids]), (200, page([song])),
      ], musicRoot: true)
    let service = try client(http, manifests: true)
    let lists = try await service.playlists(library: "music", isCurrent: { true })
    XCTAssertTrue(lists.isEmpty)
    let content = try await service.playlistTracks(
      library: "music", playlistID: "private-mix", isCurrent: { true })
    XCTAssertTrue(content.isEmpty)
  }

  func testAlbumHintMustBeConfirmedByFreshParentTraversalAndRecoversAMove() async throws {
    let header = ["Type": "Playlist", "Id": "mix", "Name": "Music"]
    let old = ["Type": "Audio", "Id": "a", "AlbumId": "old", "Name": "Old"]
    let fresh = ["Type": "Audio", "Id": "a", "AlbumId": "new", "Name": "Fresh"]
    let http = ScriptedHTTP(
      [
        (200, page([header])), (200, ["ItemIds": ["a"]]), (200, page([old])),
        (200, page([header])), (200, ["ItemIds": ["a"]]), (200, page([])), (200, page([fresh])),
        (200, page([header])), (200, ["ItemIds": ["a"]]), (200, page([])), (200, page([])),
      ], musicRoot: true)
    let service = try client(http, manifests: true)
    _ = try await service.playlists(library: "music", isCurrent: { true })
    let moved = try await service.playlistTracks(
      library: "music", playlistID: "mix", isCurrent: { true })
    XCTAssertEqual(moved.map(\.title), ["Fresh"])
    let removed = try await service.playlistTracks(
      library: "music", playlistID: "mix", isCurrent: { true })
    XCTAssertTrue(removed.isEmpty)
    let reads = await http.requests.map(query).filter { $0["ParentId"] != nil }
    XCTAssertEqual(reads.compactMap { $0["AlbumIds"] }, ["old", "new"])
    XCTAssertTrue(reads.allSatisfy { $0["Ids"] == nil && $0["ParentId"] == "music" })
  }
  func testRootMembershipRejectsAReplayedPageBeforeReadingThePlaylistName() async throws {
    let song = ["Type": "Audio", "Id": "a"]
    let header: [String: Any] = ["Type": "Playlist", "Id": "mix", "Name": [0]]
    let http = ScriptedHTTP(
      [
        (200, page([header])), (200, ["ItemIds": ["a"]]), (200, page([song], total: 2)),
        (200, page([song], total: 2, at: 1)),
      ], musicRoot: true)
    do {
      _ = try await client(http, manifests: true).playlists(library: "music", isCurrent: { true })
      XCTFail("Root scan accepted a repeated row")
    } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
  }

  func testPartialAlbumMatchReadsOnlyMissingRowsFromTheSameFolder() async throws {
    let http = ScriptedHTTP { request in
      let url = request.url!
      let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
      func field(_ name: String) -> String? { q.first { $0.name == name }?.value }
      let body: [String: Any]
      if url.lastPathComponent == "UserViews" {
        body = [
          "Items": [
            ["Type": "CollectionFolder", "Id": "music", "Name": "Music", "CollectionType": "music"]
          ]
        ]
      } else if url.lastPathComponent == "mix" {
        body = ["ItemIds": ["s899", "s12", "s899", "s904"]]
      } else if field("IncludeItemTypes") == "Playlist" {
        body = [
          "Items": [["Type": "Playlist", "Id": "mix", "Name": "Mix"]], "StartIndex": 0,
          "TotalRecordCount": 1,
        ]
      } else if field("ParentId") == "music", field("Ids") == nil, field("SortBy") == "SortName" {
        let source = field("AlbumIds") == nil ? Array(0..<1_000) : [12]
        let start = Int(field("StartIndex")!)!
        let rows = source.dropFirst(start).prefix(Int(field("Limit")!)!).map { i in
          [
            "Type": "Audio", "Id": "s" + String(i), "Name": "Current",
            "AlbumId": i == 12 ? "hit" : "miss",
          ]
        }
        body = ["Items": rows, "StartIndex": start, "TotalRecordCount": source.count]
      } else {
        return HTTPReply(data: Data(), status: 400)
      }
      return HTTPReply(data: try! JSONSerialization.data(withJSONObject: body), status: 200)
    }
    let service = try client(http, manifests: true)
    _ = try await service.playlists(library: "music", isCurrent: { true })
    let before = await http.requests.count
    let songs = try await service.playlistTracks(
      library: "music", playlistID: "mix", isCurrent: { true })
    XCTAssertEqual(songs.map(\.id), ["s899", "s12", "s899", "s904"])
    let reads = await http.requests.dropFirst(before).map(query).filter { $0["ParentId"] != nil }
    XCTAssertEqual(reads.count, 2)
    XCTAssertEqual(reads.first?["AlbumIds"], "hit,miss")
    XCTAssertEqual(reads.last?["StartIndex"], "899")
    XCTAssertEqual(reads.last?["Limit"], "6")
  }

  func testStaleFolderPositionRequiresAnExactMatchAndRecoversAMovedTrack() async throws {
    let header = ["Type": "Playlist", "Id": "mix", "Name": "Mix"]
    let old = (0..<501).map { ["Type": "Audio", "Id": "s" + String($0)] }
    var changed = old
    changed.swapAt(7, 500)
    let http = ScriptedHTTP(
      [
        (200, page([header])), (200, ["ItemIds": ["s500"]]),
        (200, page(Array(old.prefix(500)), total: 501)),
        (200, page([old[500]], total: 501, at: 500)),
        (200, page([header])), (200, ["ItemIds": ["s500"]]),
        (200, page([changed[500]], total: 501, at: 500)),
        (200, page(Array(changed.prefix(500)), total: 501)),
        (200, page([changed[500]], total: 501, at: 500)),
        (200, page([header])), (200, ["ItemIds": ["s500"]]),
        (200, page([changed[7]], total: 501, at: 7)),
      ], musicRoot: true)
    let service = try client(http, manifests: true)
    _ = try await service.playlists(library: "music", isCurrent: { true })
    for _ in 0..<2 {
      let songs = try await service.playlistTracks(
        library: "music", playlistID: "mix", isCurrent: { true })
      XCTAssertEqual(songs.map(\.id), ["s500"])
    }
    let reads = await http.requests.map(query).filter { $0["ParentId"] != nil }
    XCTAssertEqual(reads.compactMap { $0["StartIndex"] }, ["0", "500", "500", "0", "500", "7"])
    XCTAssertEqual(reads.last?["Limit"], "1")
  }

}

extension StoreTests {
  func testPrePlaylistQueueRestoresItsAlbumTrackAndPosition() throws {
    let track = CatalogFixtures.tracks(CatalogFixtures.album(0))[0]
    let state = QueueState(entries: [QueueEntry(track, libraryID: "fixture-music")], position: 7)
    var legacy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    legacy.removeValue(forKey: "playlistID")
    let restored = try JSONDecoder().decode(
      QueueState.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertNil(restored.playlistID)
    XCTAssertEqual(restored, state)
  }
  func testPlaylistRowPlaysTheSelectedOccurrenceAndNextFollowsSavedOrder() async throws {
    let (directory, storage, vault, driver) = try context()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    addTeardownBlock { @MainActor in
      await store.logout()
      try FileManager.default.removeItem(at: directory)
    }
    await store.enterFixture(
      service: FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    let browser = try XCTUnwrap(store.browser)
    await browser.start()
    let playlists = try await browser.playlists(scope: browser.scope)
    let list = try XCTUnwrap(playlists.first { $0.id == "fixture-playlist-morning" })
    let contents = try await browser.playlistContents(list, scope: browser.scope)
    let selection = try XCTUnwrap(store.playbackSelection(contents))
    XCTAssertTrue(store.queue.entries.isEmpty)
    store.toggleSelection(selection)
    try await wait { store.phase == .playing }
    let ids = store.queue.entries.map(\.id)
    let secondID = try XCTUnwrap(ids.dropFirst().first)
    let thirdID = try XCTUnwrap(ids.dropFirst(2).first)
    XCTAssertEqual(Set(ids).count, 3)
    XCTAssertEqual(store.queue.entries.map(\.track.id), contents.tracks.map(\.id))
    store.next()
    try await wait { store.current?.id == secondID && store.phase == .playing }
    store.next()
    try await wait { store.current?.id == thirdID && store.phase == .playing }
    store.toggleSelection(selection)
    XCTAssertFalse(store.playbackRequested)
    XCTAssertEqual(store.queue.entries.map(\.id), ids)
    let last = try XCTUnwrap(contents.rows.last)
    store.playSelection(selection, startAt: last.index)
    try await wait { store.phase == .playing }
    XCTAssertEqual(store.queue.index, 2)
    XCTAssertEqual(store.current?.track.id, contents.tracks[0].id)
    XCTAssertNotEqual(store.current?.id, store.queue.entries.first?.id)
    try await store.saveNow()
    let account = try XCTUnwrap(store.active?.id)
    let saved = try await storage.restore(account: account)
    XCTAssertEqual(saved?.playlistID, list.id)
    XCTAssertEqual(saved?.index, 2)
    await store.enterFixture(
      service: FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    let restoredBrowser = try XCTUnwrap(store.browser)
    await restoredBrowser.start()
    let fresh = try await restoredBrowser.playlistContents(list, scope: restoredBrowser.scope)
    XCTAssertTrue(store.selectionIsCurrent(try XCTUnwrap(store.playbackSelection(fresh))))
    XCTAssertFalse(store.playbackRequested)
    XCTAssertEqual(store.current?.id, saved?.current?.id)
  }

  func testSwitchingPlaylistsWithIdenticalMembershipReplacesTheQueueAndPreservesAlbumMatching()
    async throws
  {
    let (directory, storage, vault, driver) = try context()
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    addTeardownBlock { @MainActor in
      await store.logout()
      try FileManager.default.removeItem(at: directory)
    }
    await store.enterFixture(
      service: FixtureCatalog(source: URL(string: "https://fixture.invalid/audio")!))
    let browser = try XCTUnwrap(store.browser)
    await browser.start()
    let lists = try await browser.playlists(scope: browser.scope)
    let firstList = try XCTUnwrap(lists.first { $0.id == "fixture-playlist-morning" })
    let secondList = try XCTUnwrap(lists.first { $0.id == "fixture-playlist-evening" })
    let morning = try await browser.playlistContents(firstList, scope: browser.scope)
    let evening = try await browser.playlistContents(secondList, scope: browser.scope)
    let first = try XCTUnwrap(store.playbackSelection(morning))
    let second = try XCTUnwrap(store.playbackSelection(evening))
    let sameOrder = try XCTUnwrap(
      store.playbackSelection(
        PlaylistContents(
          morning.tracks,
          source: .init(id: "third", library: first.origin.library, scope: browser.scope))))
    store.toggleSelection(first)
    try await wait { store.phase == .playing }
    XCTAssertFalse(store.selectionIsCurrent(second))
    XCTAssertFalse(store.selectionIsCurrent(sameOrder))
    let originalOccurrences = store.queue.entries.map(\.id)
    store.toggleSelection(sameOrder)
    try await wait { store.phase == .playing }
    XCTAssertEqual(store.queue.playlistID, "third")
    XCTAssertNotEqual(store.queue.entries.map(\.id), originalOccurrences)
    store.toggleSelection(second)
    try await wait { store.phase == .playing }
    XCTAssertEqual(store.queue.entries.map(\.track.id), evening.tracks.map(\.id))
    XCTAssertEqual(store.current?.track.id, evening.tracks[0].id)
    XCTAssertTrue(store.selectionIsCurrent(second))
    XCTAssertFalse(store.selectionIsCurrent(first))
    store.toggleShuffle()
    XCTAssertTrue(store.selectionIsCurrent(second))
    XCTAssertFalse(store.selectionIsCurrent(first))
    let album = try await acceptedAlbumSelection(store)
    store.playSelection(album)
    try await wait { store.phase == .playing }
    XCTAssertNil(store.queue.playlistID)
    XCTAssertTrue(store.selectionIsCurrent(album))
    XCTAssertFalse(store.selectionIsCurrent(second))
    store.toggleSelection(album)
    XCTAssertFalse(store.playbackRequested)
    browser.selectLibrary("fixture-concerts")
    let before = store.queue
    store.toggleSelection(first)
    XCTAssertEqual(store.queue, before)
    XCTAssertFalse(store.playbackRequested)
    browser.selectLibrary("fixture-music")
    XCTAssertNil(
      store.playbackSelection(morning), "Returning to a root cannot revive its old playlist rows")
    store.playSelection(first, startAt: 2)
    XCTAssertEqual(store.queue, before)
  }
}
