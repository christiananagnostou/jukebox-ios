import XCTest

@testable import JukeboxCore

@MainActor final class PlaylistEditingTests: XCTestCase {
  let music = "fixture-music"
  func testMoveAndRemoveOnlyTheSelectedCopyAndRejectOldEditor() async throws {
    let service = FixtureCatalog(source: URL(fileURLWithPath: "/fixture"))
    let list = MusicPlaylist(id: "fixture-playlist-morning", title: "Morning rotation")
    let state = try await service.playlistEditor(
      library: music, playlist: list, isCurrent: { true })
    XCTAssertEqual(state.entries.first?.track, state.entries.last?.track)
    XCTAssertNotEqual(state.entryID(at: 0), state.entryID(at: 2))
    _ = try await service.changePlaylist(
      library: music, state: state, change: .move(2, 1), isCurrent: { true })
    do {
      _ = try await service.changePlaylist(
        library: music, state: state, change: .remove(2), isCurrent: { true })
      XCTFail("A stale position was accepted")
    } catch { XCTAssertEqual(error as? PlaylistEditError, .changed) }
    let moved = try await service.playlistEditor(
      library: music, playlist: list, isCurrent: { true })
    XCTAssertEqual(moved.entries, [state.entries[0], state.entries[2], state.entries[1]])
    _ = try await service.changePlaylist(
      library: music, state: moved, change: .remove(0), isCurrent: { true })
    let result = try await service.playlistEditor(
      library: music, playlist: list, isCurrent: { true })
    XCTAssertEqual(result.entries, [state.entries[2], state.entries[1]])
  }
  func testAmbiguousServerEntryIDsAndNonMusicAreRejected() throws {
    let state = PlaylistEditState(
      playlist: .init(id: "mix", title: "Mix"),
      entries: [
        .init(track: "one", entry: "one"), .init(track: "two", entry: "two"),
        .init(track: "one", entry: "one"), .init(track: "three", entry: "three"),
        .init(track: "four", entry: "four"),
      ], canDelete: true, canShare: true)
    XCTAssertNil(state.entryID(at: 0))
    XCTAssertNil(state.entryID(at: 2))
    XCTAssertEqual(state.entryID(at: 1), "two")
    XCTAssertFalse(state.permitsMove(to: 3))
    XCTAssertTrue(state.permitsMove(to: 1))
    XCTAssertTrue(state.permitsMove(to: 4))
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        PlaylistEditEntry.self, from: Data(#"{"Type":"Movie","Name":{},"Id":[]}"#.utf8))
    ) {
      XCTAssertEqual($0 as? PlaylistEditError, .limitedToLibrary)
    }
  }
  func testPrivateCreationAccessChangesAndDeletionRefreshBothSurfaces() async throws {
    let browser = MusicBrowser(
      service: FixtureCatalog(source: URL(fileURLWithPath: "/fixture"), singleLibrary: true))
    await browser.start()
    let owner = browser.scope
    await browser.loadPlaylistIndex(scope: owner)
    let saved = try await browser.changePlaylist(
      .create("  My playlist  ", []), state: nil, scope: owner)
    let id = saved.id
    let summary = try XCTUnwrap(browser.playlistIndex.items?.first { $0.id == id })
    XCTAssertEqual(summary.title, "My playlist")
    let state = try await browser.playlistEditor(summary, scope: owner)
    let initial = try await browser.playlistSharing(summary, scope: owner)
    XCTAssertFalse(initial.isPublic)
    let track = CatalogFixtures.tracks(CatalogFixtures.album(0))[0]
    _ = try await browser.changePlaylist(.append([track]), state: state, scope: owner)
    let contents = try await browser.playlistContents(summary, scope: owner)
    XCTAssertEqual(contents.tracks.map(\.id), [track.id])
    _ = try await browser.changePlaylist(.rename("Renamed"), state: state, scope: owner)
    XCTAssertEqual(browser.playlistIndex.items?.first(where: { $0.id == id })?.title, "Renamed")
    _ = try await browser.changePlaylist(
      .share("fixture-listener", true), state: state, scope: owner)
    _ = try await browser.changePlaylist(.visibility(true), state: state, scope: owner)
    let shared = try await browser.playlistSharing(summary, scope: owner)
    XCTAssertEqual(shared.people.first?.canEdit, true)
    XCTAssertTrue(shared.isPublic)
    _ = try await browser.changePlaylist(
      .share("fixture-listener", nil), state: state, scope: owner)
    let removed = try await browser.playlistSharing(summary, scope: owner)
    XCTAssertNil(removed.people.first?.canEdit)
    let latest = try await browser.playlistEditor(summary, scope: owner)
    _ = try await browser.changePlaylist(.delete, state: latest, scope: owner)
    XCTAssertFalse(browser.playlistIndex.permitsOpening(id))
    XCTAssertNil(browser.cachedPlaylistContents(summary, scope: owner))
  }
}

private actor PlaylistWire: HTTPTransport {
  enum Access { case unowned, viewer, owner }
  var writes: [(String, String, Data, String)] = []
  var entries = ["one", "two", "one"]
  var keys = ["first", "middle", "last"]
  var created: [String] = []
  var access = Access.owner
  var includeHidden = false
  func setAccess(_ access: Access) { self.access = access }
  private var manifestAvailable = true
  func hideManifest() { manifestAvailable = false }
  func hideMember() { includeHidden = true }
  func sharedIDs() { keys = entries }
  func send(_ request: URLRequest) async throws -> HTTPReply {
    let path = request.url!.path
    let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
    let method = request.httpMethod ?? "GET"
    func data(_ value: Any) throws -> HTTPReply {
      HTTPReply(data: try JSONSerialization.data(withJSONObject: value), status: 200)
    }
    func page(_ rows: [[String: Any]]) throws -> HTTPReply {
      try data(["Items": rows, "StartIndex": 0, "TotalRecordCount": rows.count])
    }
    if method != "GET" {
      let body = request.httpBody ?? Data()
      writes.append((method, path, body, request.value(forHTTPHeaderField: "Content-Type") ?? ""))
      if path.hasSuffix("/last/Move/1") {
        entries = ["one", "one", "two"]
        keys = ["first", "last", "middle"]
      }
      if path.hasSuffix("/Playlists") {
        created =
          (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["Ids"] as? [String]
          ?? []
        return try data(["Id": "new"])
      }
      if path.hasSuffix("/mix/Items"), method == "POST" {
        let raw = q.first { $0.name == "Ids" }?.value ?? ""
        let added = raw.split(separator: ",").map(String.init)
        entries += added
        keys += added.map { _ in UUID().uuidString }
      }
      return HTTPReply(data: Data(), status: 204)
    }
    if path.hasSuffix("/Playlists/new") { return try data(["ItemIds": created]) }
    if path.hasSuffix("/UserViews") {
      return try page([
        ["Type": "CollectionFolder", "CollectionType": "music", "Name": "Music", "Id": "music"]
      ])
    }
    if q.contains(URLQueryItem(name: "IncludeItemTypes", value: "Playlist")) {
      return try page([
        [
          "Type": "Playlist", "MediaType": "Audio", "Name": "Invented", "Id": "mix",
          "CanDelete": true,
        ]
      ])
    }
    if path.hasSuffix("/Playlists/mix/Users/listener") {
      if access == .unowned { return HTTPReply(data: Data(), status: 404) }
      return try data(["UserId": "listener", "CanEdit": access == .owner])
    }
    if path.hasSuffix("/Playlists/mix/Users") {
      return access == .owner ? try data([]) : HTTPReply(data: Data(), status: 403)
    }
    if path.hasSuffix("/Playlists/mix/Items") {
      return try page(zip(entries, keys).map { ["Type": "Audio", "Id": $0, "PlaylistItemId": $1] })
    }
    if path.hasSuffix("/Playlists/mix") {
      guard manifestAvailable else { return HTTPReply(data: Data(), status: 404) }
      return try data([
        "ItemIds": entries + (includeHidden ? ["other"] : []), "OpenAccess": false,
        "Shares": [["UserId": "friend", "CanEdit": false]],
      ])
    }
    if path.hasSuffix("/Users") {
      return try data([["Id": "friend", "Name": "Alex"], ["Id": "listener", "Name": "Me"]])
    }
    if q.contains(URLQueryItem(name: "ParentId", value: "music")),
      q.contains(URLQueryItem(name: "IncludeItemTypes", value: "Audio"))
    {
      return try page(["one", "two"].map { ["Type": "Audio", "Id": $0, "AlbumId": "release"] })
    }
    return HTTPReply(data: Data(), status: 404)
  }
}

extension PlaylistEditingTests {
  private func network(_ wire: PlaylistWire) throws -> JellyfinClient {
    try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test"), userID: "listener", username: "Invented"),
      token: "fixture", deviceID: "fixture", transport: wire)
  }
  func testImportedPlaylistOpensForEditingAfterItsExistingIDGetsAnOwner() async throws {
    let wire = PlaylistWire()
    let api = try network(wire)
    let list = MusicPlaylist(id: "mix", title: "Imported music")
    await wire.setAccess(.unowned)
    do {
      _ = try await api.playlistEditor(library: "music", playlist: list, isCurrent: { true })
      XCTFail("Opened an unowned imported playlist for editing")
    } catch { XCTAssertEqual(error as? PlaylistEditError, .readOnly) }

    await wire.setAccess(.owner)
    let editor = try await api.playlistEditor(library: "music", playlist: list, isCurrent: { true })
    XCTAssertEqual(editor.playlist.id, list.id)
    XCTAssertTrue(editor.canShare)
    XCTAssertEqual(editor.entries.map(\.track), ["one", "two", "one"])
    let writes = await wire.writes
    XCTAssertTrue(writes.isEmpty)
  }
  func testWireMutationsPreserveSharesAndTargetExactOccurrenceAndImage() async throws {
    let wire = PlaylistWire()
    let api = try network(wire)
    let list = MusicPlaylist(id: "mix", title: "Invented")
    let state = try await api.playlistEditor(library: "music", playlist: list, isCurrent: { true })
    let permissions = try await api.playlistSharing(
      library: "music", playlist: list, isCurrent: { true })
    XCTAssertEqual(permissions.people, [.init(id: "friend", name: "Alex", canEdit: false)])
    _ = try await api.changePlaylist(
      library: "music", state: state, change: .rename("New name"), isCurrent: { true })
    _ = try await api.changePlaylist(
      library: "music", state: state, change: .visibility(true), isCurrent: { true })
    _ = try await api.changePlaylist(
      library: "music", state: state, change: .share("friend", true), isCurrent: { true })
    let jpeg = Data([255, 216, 255, 217])
    _ = try await api.changePlaylist(
      library: "music", state: state, change: .cover(jpeg), isCurrent: { true })
    _ = try await api.changePlaylist(
      library: "music", state: state, change: .move(2, 1), isCurrent: { true })
    let writes = await wire.writes
    XCTAssertEqual(
      writes.map { $0.1 },
      [
        "/Playlists/mix", "/Playlists/mix", "/Playlists/mix/Users/friend",
        "/Items/mix/Images/Primary", "/Playlists/mix/Items/last/Move/1",
      ])
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: writes[0].2) as? [String: String], ["Name": "New name"]
    )
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: writes[1].2) as? [String: Bool], ["IsPublic": true])
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: writes[2].2) as? [String: Bool], ["CanEdit": true])
    XCTAssertEqual(writes[3].2, jpeg.base64EncodedData())
    XCTAssertEqual(writes[3].3, "image/jpeg")
  }
  func testWireRejectsAmbiguousHiddenAndReadOnlyEditsBeforeWriting() async throws {
    let wire = PlaylistWire()
    let api = try network(wire)
    let list = MusicPlaylist(id: "mix", title: "Invented")
    await wire.sharedIDs()
    let state = try await api.playlistEditor(library: "music", playlist: list, isCurrent: { true })
    do {
      _ = try await api.changePlaylist(
        library: "music", state: state, change: .remove(2), isCurrent: { true })
      XCTFail("Removed an ambiguous occurrence")
    } catch { XCTAssertEqual(error as? PlaylistEditError, .ambiguousEntry) }
    await wire.hideMember()
    do {
      _ = try await api.changePlaylist(
        library: "music", state: state, change: .delete, isCurrent: { true })
      XCTFail("Allowed deletion with hidden entries")
    } catch { XCTAssertEqual(error as? PlaylistEditError, .limitedToLibrary) }
    await wire.hideManifest()
    do {
      _ = try await api.changePlaylist(
        library: "music", state: state, change: .delete, isCurrent: { true })
      XCTFail("Allowed a whole-playlist write without its complete order")
    } catch { XCTAssertEqual(error as? PlaylistEditError, .limitedToLibrary) }
    await wire.setAccess(.viewer)
    do {
      _ = try await api.changePlaylist(
        library: "music", state: state, change: .rename("Changed"), isCurrent: { true })
      XCTFail("Allowed a revoked edit")
    } catch { XCTAssertEqual(error as? PlaylistEditError, .readOnly) }
    let writes = await wire.writes
    XCTAssertTrue(writes.isEmpty)
  }
  func testCreateAndAppendSendRepeatedIDsInExactOrder() async throws {
    let wire = PlaylistWire()
    let api = try network(wire)
    let song = MusicItem(
      id: "one", title: "Song", artist: "Artist", album: "", duration: 18, number: 1, kind: "Audio",
      imageID: nil, imageTag: nil)
    let created = try await api.changePlaylist(
      library: "music", state: nil, change: .create("Private", [song, song]), isCurrent: { true })
    XCTAssertEqual(created.id, "new")
    XCTAssertNil(created.notice)
    let state = try await api.playlistEditor(
      library: "music", playlist: .init(id: "mix", title: "Mix"), isCurrent: { true })
    let appended = try await api.changePlaylist(
      library: "music", state: state, change: .append([song, song]), isCurrent: { true })
    XCTAssertNil(appended.notice)
    let entries = await wire.entries
    XCTAssertEqual(entries, ["one", "two", "one", "one", "one"])
    let writes = await wire.writes
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: writes[0].2) as? [String: Any])
    XCTAssertEqual(body["IsPublic"] as? Bool, false)
    XCTAssertEqual(body["Ids"] as? [String], ["one", "one"])
  }
  func testCreatingWithRepeatsDoesNotSilentlyDropSongs() {
    let requested = ["a", "b", "a"]
    XCTAssertNil(
      PlaylistSave.addition(
        id: "mix", previous: ["b"], requested: requested, saved: ["b", "a", "b", "a"]
      ).notice)
    XCTAssertEqual(
      PlaylistSave.addition(id: "mix", previous: ["b"], requested: requested, saved: ["b", "a"])
        .notice, "Jellyfin skipped 2 repeated songs.")
    XCTAssertNotNil(
      PlaylistSave.addition(id: "mix", previous: ["b"], requested: requested, saved: ["a", "b"])
        .notice)
  }
}
