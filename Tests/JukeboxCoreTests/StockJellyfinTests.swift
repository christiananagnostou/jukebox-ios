#if STOCK_JELLYFIN_TEST && os(macOS)
  import AVFoundation
  import Synchronization
  import XCTest

  @testable import JukeboxCore

  @MainActor
  final class StockJellyfinTests: XCTestCase {
    private func signedIn() async throws -> (client: JellyfinClient, token: String) {
      let environment = ProcessInfo.processInfo.environment
      let port = try XCTUnwrap(environment["JUKEBOX_FIXTURE_PORT"].flatMap(UInt16.init))
      let password = try XCTUnwrap(environment["JUKEBOX_FIXTURE_PASSWORD"])
      let server = try ServerAddress("http://127.0.0.1:\(port)")
      let first = JellyfinAuthentication(server: server, deviceID: UUID().uuidString)
      let (owner, token) = try await first.password(username: "Listener", password: password)
      XCTAssertEqual(owner.username, "Listener")
      let version = try XCTUnwrap(owner.serverInfo?.version)
      XCTAssertTrue(ServerCompatibility.accepts(version, families: ["12.4"]))
      return (try JellyfinClient(connection: owner, token: token, deviceID: first.deviceID), token)
    }

    private func libraryID(_ client: JellyfinClient) async throws -> String {
      let roots = try await client.musicLibraries()
      return try XCTUnwrap(roots.first { $0.title == "Fixture Music" }).id
    }

    func testPasswordSignIn() async throws {
      let (client, _) = try await signedIn()
      _ = try await libraryID(client)
    }

    func testQuickConnectSignInAndApproval() async throws {
      let (approver, token) = try await signedIn()
      let owner = await approver.connection
      let second = JellyfinAuthentication(server: owner.server, deviceID: UUID().uuidString)
      let enabled = try await second.signInCodeAvailability()
      XCTAssertEqual(enabled, true)
      let codes = AsyncStream<QuickConnectCode>.makeStream()
      defer { codes.continuation.finish() }
      async let approval: Void = {
        for await code in codes.stream {
          try await approver.authorizeQuickConnect(code, isCurrent: { true })
          return
        }
        throw QuickConnectError.unconfirmed
      }()
      let (connection, secondToken) = try await second.quickConnect(
        pollInterval: .milliseconds(300), lifetime: .seconds(25)
      ) { codes.continuation.yield($0) }
      try await approval
      XCTAssertEqual(connection.userID, owner.userID)
      XCTAssertFalse(secondToken == token)
      let client = try JellyfinClient(
        connection: connection, token: secondToken, deviceID: second.deviceID)
      _ = try await libraryID(client)
    }

    func testCopyPreservesRepeatsOrderAndPrivacy() async throws {
      let (client, _) = try await signedIn()
      let library = try await libraryID(client)
      let songs = try await client.catalog(CatalogQuery(library: library, category: .songs))
      let firstSong = try XCTUnwrap(songs.first { $0.title == "First" }).id
      let secondSong = try XCTUnwrap(songs.first { $0.title == "Second" }).id
      XCTAssertNotEqual(firstSong, secondSong)
      let playlists = try await client.playlists(
        library: library, isCurrent: { true }, onUpdate: nil, onSongs: nil)
      let source = try XCTUnwrap(playlists.first { $0.title == "Fixture repeats" })
      func tracks(_ playlist: String) async throws -> [String] {
        try await client.playlistTracks(library: library, playlistID: playlist, isCurrent: { true })
          .map(\.id)
      }
      let order = try await tracks(source.id)
      XCTAssertEqual(order, [firstSong, secondSong, firstSong])
      let copy = try await client.changePlaylist(
        library: library, state: nil, change: .copy(source, name: "Private copy"),
        isCurrent: { true })
      XCTAssertNotEqual(copy.id, source.id)
      XCTAssertNil(copy.notice)
      let copyOrder = try await tracks(copy.id)
      let originalOrder = try await tracks(source.id)
      XCTAssertEqual(copyOrder, order)
      XCTAssertEqual(originalOrder, order)
      let copyModel = MusicPlaylist(id: copy.id, title: "Private copy")
      let editor = try await client.playlistEditor(
        library: library, playlist: copyModel, isCurrent: { true })
      XCTAssertTrue(editor.canShare)
      let sharing = try await client.playlistSharing(
        library: library, playlist: copyModel, isCurrent: { true })
      XCTAssertFalse(sharing.isPublic)
      XCTAssertTrue(sharing.people.allSatisfy { $0.canEdit == nil })
    }

    func testOriginalPlayback() async throws { try await playToEnd(.original) }
    func testHighPlayback() async throws { try await playToEnd(.high) }

    private func playToEnd(_ quality: StreamQuality) async throws {
      let (client, _) = try await signedIn()
      let library = try await libraryID(client)
      let songs = try await client.catalog(CatalogQuery(library: library, category: .songs))
      let flac = try XCTUnwrap(songs.first { $0.title == "First" })
      let media = try await client.media(
        library: library, trackID: flac.id, quality: quality, isCurrent: { true })
      XCTAssertEqual(media.quality, quality)
      XCTAssertEqual(media.serverTimeSeek, quality == .high)
      let duration = try XCTUnwrap(media.serverDuration)
      XCTAssertGreaterThan(duration, 7)
      let bridge = MediaHTTPBridge()
      try await bridge.start()
      defer { bridge.stop() }
      let asset = AVURLAsset(url: try bridge.register(media))
      let item = AVPlayerItem(asset: asset)
      let player = AVPlayer(playerItem: item)
      player.isMuted = true
      let ended = Mutex(false)
      let observation = NotificationCenter.default.addObserver(
        forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: nil
      ) { _ in ended.withLock { $0 = true } }
      defer {
        NotificationCenter.default.removeObserver(observation)
        player.pause()
        player.replaceCurrentItem(with: nil)
      }
      player.play()
      var advanced = false
      var furthest = 0.0
      let deadline = ContinuousClock.now.advanced(by: .seconds(28))
      while !ended.withLock({ $0 }), item.status != .failed, ContinuousClock.now < deadline {
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite {
          advanced = advanced || (elapsed > 0.25 && elapsed < duration - 0.25)
          furthest = max(furthest, elapsed)
        }
        try await Task.sleep(for: .milliseconds(80))
      }
      XCTAssertEqual(item.status, .readyToPlay, quality.title)
      XCTAssertTrue(advanced, quality.title)
      XCTAssertTrue(ended.withLock { $0 }, quality.title)
      XCTAssertEqual(furthest, duration, accuracy: 0.5, quality.title)
      let (download, response) = try await URLSession.shared.download(
        from: try bridge.register(media))
      defer { try? FileManager.default.removeItem(at: download) }
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
      let suffix = quality == .original ? "flac" : "mp3"
      let local = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + "." + suffix)
      try FileManager.default.moveItem(at: download, to: local)
      defer { try? FileManager.default.removeItem(at: local) }
      let audio = try AVAudioFile(forReading: local)
      XCTAssertEqual(
        audio.fileFormat.streamDescription.pointee.mFormatID,
        quality == .original ? kAudioFormatFLAC : kAudioFormatMPEGLayer3, quality.title)
      if quality == .high {
        let bytes = try XCTUnwrap(local.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let bitsPerSecond = Double(bytes) * 8 / duration
        XCTAssertEqual(bitsPerSecond, Double(quality.bitrate), accuracy: 9_600)
      }
    }
  }
#endif
