import Synchronization
import XCTest

@testable import JukeboxCore

actor ScriptedHTTP: HTTPTransport {
  var replies: [HTTPReply]
  private var respond: (@Sendable (URLRequest) -> HTTPReply)?
  private var heldPath: String?
  private var pending: (HTTPReply, CheckedContinuation<HTTPReply, Error>)?
  private var rootsOverride: HTTPReply?
  var waiting: Bool { pending != nil }
  func holdNext(_ path: String) { heldPath = path }
  func replaceRoots(_ reply: HTTPReply) { rootsOverride = reply }
  func release(error: (any Error)? = nil) {
    heldPath = nil
    guard let (reply, continuation) = pending else { return }
    pending = nil
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume(returning: reply)
    }
  }
  private(set) var paths: [String] = []
  private(set) var bodies: [Data] = []
  private(set) var requests: [URLRequest] = []
  init(replies: [HTTPReply]) { self.replies = replies }
  init(respond: @escaping @Sendable (URLRequest) -> HTTPReply) {
    replies = []
    self.respond = respond
  }
  init(_ objects: [(Int, [String: Any])], musicRoot: Bool = false) {
    let roots: [(Int, [String: Any])] =
      musicRoot
      ? [
        (
          200,
          [
            "Items": [
              [
                "CollectionType": "music", "Type": "CollectionFolder", "Id": "music",
                "Name": "Music",
              ]
            ]
          ]
        )
      ] : []
    replies = (roots + objects).map {
      HTTPReply(data: try! JSONSerialization.data(withJSONObject: $0.1), status: $0.0)
    }
  }
  func send(_ request: URLRequest) async throws -> HTTPReply {
    paths.append(request.url!.path)
    requests.append(request)
    bodies.append(request.httpBody ?? Data())
    let reply: HTTPReply
    if request.url?.lastPathComponent == "UserViews", let rootsOverride {
      reply = rootsOverride
    } else if let respond {
      reply = respond(request)
    } else {
      guard !replies.isEmpty else { throw ClientError.invalidResponse }
      reply = replies.removeFirst()
    }
    if request.url?.lastPathComponent == heldPath {
      heldPath = nil
      return try await withCheckedThrowingContinuation { pending = (reply, $0) }
    }
    return reply
  }
}
@MainActor private final class MediaCallerLifetime { var live = true }
final class APITests: XCTestCase {
  func testMediaForPermittedAudioDoesNotReadUnrelatedDeniedMusicRoot() async throws {
    for deniedStatus in [403, 503] {
      let roots = HTTPReply(
        data: Data(
          #"{"Items":[{"CollectionType":"music","Type":"CollectionFolder","Id":"r1","Name":"First"},{"CollectionType":"music","Type":"CollectionFolder","Id":"r2","Name":"Second"}]}"#
            .utf8),
        status: 200)
      let http = ScriptedHTTP { request in
        if request.url?.lastPathComponent == "UserViews" { return roots }
        let query =
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if request.url?.lastPathComponent == "Items" {
          if query.contains(.init(name: "ParentId", value: "r2")) {
            return HTTPReply(data: Data(), status: deniedStatus)
          }
          return HTTPReply(
            data: Data(#"{"Items":[{"Id":"song","Type":"Audio"}]}"#.utf8), status: 200)
        }
        if request.url?.lastPathComponent == "PlaybackInfo" {
          return HTTPReply(
            data: Data(#"{"MediaSources":[{"Id":"source","SupportsDirectPlay":true}]}"#.utf8),
            status: 200)
        }
        return HTTPReply(data: Data(), status: 404)
      }
      let client = try JellyfinClient(
        connection: Connection(
          server: ServerAddress("https://fixture.test/base"), userID: "listener",
          username: "Invented"),
        token: "invented-token", deviceID: "test", transport: http)
      var source: MediaSource?
      do {
        source = try await client.media(
          library: "r1", trackID: "song", quality: .original, isCurrent: { true })
      } catch {
        XCTFail("An unrelated denied root blocked an otherwise permitted Audio source")
      }
      XCTAssertEqual(source?.url.path, "/base/Audio/song/stream")
      let requests = await http.requests
      let proofs = requests.filter { $0.url?.lastPathComponent == "Items" }
      let parents = proofs.map {
        URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?
          .first(where: { $0.name == "ParentId" })?.value
      }
      XCTAssertEqual(parents, ["r1"], "R2 must not be read for normal R1 media preparation")
      XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "PlaybackInfo" }.count, 1)
    }
  }
  @MainActor
  func testPausedValidationRetainsAllRootGlobalPoolAndBatchBounds() async throws {
    let ids = (0..<205).map { "restore-\($0)" }
    let roots = HTTPReply(
      data: Data(
        #"{"Items":[{"CollectionType":"music","Type":"CollectionFolder","Id":"r1","Name":"First"},{"CollectionType":"music","Type":"CollectionFolder","Id":"r2","Name":"Second"}]}"#
          .utf8),
      status: 200)
    let http = ScriptedHTTP { request in
      if request.url?.lastPathComponent == "UserViews" { return roots }
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let parent = query.first(where: { $0.name == "ParentId" })?.value
      let batch = (query.first(where: { $0.name == "Ids" })?.value ?? "").split(separator: ",").map(
        String.init)
      let outside = parent == "r1" ? ids.first(where: { !batch.contains($0) }) : nil
      let returned: [String]
      if let outside {
        returned =
          Array(batch.prefix(39)) + [outside]
          + (batch.count < 39 ? [outside, "not-requested"] : [])
      } else {
        returned = batch
      }
      let rows = returned.map { id in
        [
          "Id": id, "Type": "Audio",
          "Name": (id == outside ? "Outside " : parent == "r1" ? "First " : "Later ") + id,
        ]
      }
      return HTTPReply(
        data: try! JSONSerialization.data(withJSONObject: ["Items": rows]), status: 200)
    }
    let client = try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test"), userID: "listener", username: "Invented"),
      token: "invented-token", deviceID: "test", transport: http)
    await http.holdNext("Items")
    let validation = Task { try await client.validate(ids: ids + [ids[0], ids[0], ids[204]]) }
    try await StoreTests().wait {
      await http.requests.filter { $0.url?.lastPathComponent == "Items" }.count >= 4
    }
    let firstWindow = await http.requests.filter { $0.url?.lastPathComponent == "Items" }
    XCTAssertEqual(firstWindow.count, 4)
    await http.release()
    let allowed = try await validation.value
    XCTAssertEqual(Set(allowed.map(\.id)), Set(ids))
    XCTAssertEqual(allowed.count, ids.count)
    XCTAssertFalse(allowed.contains { $0.id == "not-requested" })
    let requests = await http.requests
    let proofs = requests.filter { $0.url?.lastPathComponent == "Items" }
    let expected = stride(from: 0, to: ids.count, by: 40).map {
      Array(ids[$0..<min($0 + 40, ids.count)])
    }
    XCTAssertEqual(proofs.count, expected.count * 2)
    for root in ["r1", "r2"] {
      let batches = proofs.compactMap { request -> [String]? in
        let query =
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.contains(.init(name: "ParentId", value: root)) else { return nil }
        return (query.first(where: { $0.name == "Ids" })?.value ?? "").split(separator: ",").map(
          String.init)
      }
      XCTAssertEqual(batches.count, expected.count)
      XCTAssertEqual(Set(batches), Set(expected))
    }
    let outsideFirstBatch = ids[40]
    XCTAssertEqual(
      allowed.first(where: { $0.id == outsideFirstBatch })?.title, "Outside " + outsideFirstBatch,
      "Globally requested IDs returned outside this batch remain allowed; first root wins")
    XCTAssertFalse(requests.contains { $0.url?.lastPathComponent == "PlaybackInfo" })
  }
  @MainActor
  func testPausedValidationDiscardsHeldCatalogAfterMusicAccessChanges() async throws {
    let http = ScriptedHTTP(
      [(200, ["Items": [["Id": "song", "Name": "Fixture", "Type": "Audio"]]])],
      musicRoot: true)
    let client = try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test"), userID: "listener", username: "Invented"),
      token: "invented-token", deviceID: "test", transport: http)
    await http.holdNext("Items")
    let validation = Task { try await client.validate(ids: ["song"]) }
    try await waitForMediaHold(http)
    await http.replaceRoots(HTTPReply(data: Data(#"{"Items":[]}"#.utf8), status: 200))
    let refreshed = try await client.musicLibraries(refresh: true)
    XCTAssertTrue(refreshed.isEmpty)
    await http.release()
    do {
      _ = try await validation.value
      XCTFail("A retired Music root supplied the restored queue")
    } catch is CancellationError {}
  }
  @MainActor private func waitForMediaHold(_ http: ScriptedHTTP) async throws {
    try await StoreTests().wait { await http.waiting }
    guard await http.waiting else { throw ClientError.unavailable }
  }
  func testSelectedRootDenialMissingAndNonAudioNeverNegotiatePlaybackInfo() async throws {
    let roots = (
      200,
      [
        "Items": [
          [
            "CollectionType": "music", "Type": "CollectionFolder", "Id": "music",
            "Name": "Invented",
          ]
        ]
      ]
    )
    for (library, status, rows) in [
      ("missing-root", 200, [["Id": "song", "Type": "Audio"]] as [[String: Any]]),
      ("music", 403, []), ("music", 200, []),
      ("music", 200, [["Type": "Book", "Id": ["getter-trap": true], "Name": 404]]),
      ("music", 200, [["Id": "other", "Type": "Audio"]]),
    ] {
      let http = ScriptedHTTP([roots, (status, ["Items": rows])])
      let client = try JellyfinClient(
        connection: Connection(
          server: ServerAddress("https://fixture.test"), userID: "listener", username: "Invented"),
        token: "invented-token", deviceID: "test", transport: http)
      do {
        _ = try await client.media(
          library: library, trackID: "song", quality: .original, isCurrent: { true })
        XCTFail("Unproved selected-root Audio admitted")
      } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
      let requests = await http.requests
      XCTAssertFalse(requests.contains { $0.url?.lastPathComponent == "PlaybackInfo" })
      XCTAssertEqual(requests.count, library == "music" ? 2 : 1)
    }
  }
  @MainActor
  func
    testMediaEntryAndHeldRepliesRejectRetirementCancellationAndPermissionBeforeClassification()
    async throws
  {
    for phase in ["UserViews", "Items", "PlaybackInfo"] {
      for terminal in ["body", "error"] {
        for retirement in ["caller", "cancel", "permission"] {
          let http = ScriptedHTTP([
            (
              200,
              phase == "UserViews"
                ? ["Items": "malformed-root-trap"]
                : [
                  "Items": [
                    [
                      "CollectionType": "music", "Type": "CollectionFolder", "Id": "music",
                      "Name": "Invented",
                    ]
                  ]
                ]
            ),
            (
              200,
              phase == "Items"
                ? ["Items": "malformed-trap"] : ["Items": [["Id": "song", "Type": "Audio"]]]
            ),
            (200, ["MediaSources": "malformed-trap"]),
          ])
          let client = try JellyfinClient(
            connection: Connection(
              server: ServerAddress("https://fixture.test"), userID: "listener",
              username: "Invented"),
            token: "invented-token", deviceID: "test", transport: http)
          let caller = MediaCallerLifetime()
          let late = URLError(.networkConnectionLost)
          await http.holdNext(phase)
          let work = Task {
            try await client.media(
              library: "music", trackID: "song", quality: .original, isCurrent: { caller.live })
          }
          do {
            try await waitForMediaHold(http)
            if retirement == "caller" {
              caller.live = false
            } else if retirement == "cancel" {
              work.cancel()
            } else {
              await http.replaceRoots(HTTPReply(data: Data(#"{"Items":[]}"#.utf8), status: 200))
              _ = try await client.musicLibraries(refresh: true)
            }
            await http.release(error: terminal == "error" ? late : nil)
            do {
              _ = try await work.value
              XCTFail("Retired media reply admitted")
            } catch { XCTAssertTrue(error is CancellationError) }
            let requests = await http.requests
            var prefix = ["/UserViews"]
            if phase != "UserViews" { prefix.append("/Items") }
            if phase == "PlaybackInfo" { prefix.append("/Items/song/PlaybackInfo") }
            if retirement == "permission" { prefix.append("/UserViews") }
            XCTAssertEqual(requests.map { $0.url?.path }, prefix.map(Optional.some))
            XCTAssertEqual(
              requests.filter { $0.url?.lastPathComponent == "PlaybackInfo" }.count,
              phase == "PlaybackInfo" ? 1 : 0)
          } catch {
            work.cancel()
            await http.release()
            _ = try? await work.value
            throw error
          }
        }
      }
    }
    for cancelled in [false, true] {
      let http = ScriptedHTTP(replies: [])
      let client = try JellyfinClient(
        connection: Connection(
          server: ServerAddress("https://fixture.test"), userID: "listener", username: "Invented"),
        token: "invented-token", deviceID: "test", transport: http)
      let work = Task {
        if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
        return try await client.media(
          library: "music", trackID: "song", quality: .original, isCurrent: { cancelled })
      }
      do {
        _ = try await work.value
        XCTFail("Retired entry admitted")
      } catch { XCTAssertTrue(error is CancellationError) }
      let requests = await http.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }
  @MainActor func testRealStorePausedRestoreKeepsNilRootClockAndNeverNegotiatesWithoutProvenance()
    async throws
  {
    let (directory, storage, vault, driver) = try StoreTests().context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let account = Connection(
      server: try ServerAddress("https://fixture.test"), userID: "listener", username: "Invented")
    let entry = QueueEntry(MusicItem.fixtureTracks[0])
    let snapshot = QueueState(
      entries: [entry, QueueEntry(MusicItem.fixtureTracks[0], libraryID: "music")], position: 17.25,
      quality: .high)
    try await storage.save(snapshot, account: account.id)
    await vault.write("invented-token", account: account.id)
    let http = ScriptedHTTP([
      (200, ["Id": "listener"]),
      (
        200,
        [
          "Items": [
            [
              "CollectionType": "music", "Type": "CollectionFolder", "Id": "music",
              "Name": "Invented",
            ]
          ]
        ]
      ),
      (200, ["Items": [["Id": entry.track.id, "Type": "Audio"]]]),
    ])
    let client = try JellyfinClient(
      connection: account, token: "invented-token", deviceID: "test", transport: http)
    let store = PlayerStore(
      storage: storage, vault: vault, driver: driver, deviceID: "test", factory: { _, _ in client })
    await store.activate(account)
    XCTAssertEqual(store.queue.entries.map(\.id), snapshot.entries.map(\.id))
    XCTAssertEqual(store.queue.entries.map(\.libraryID), [nil, "music"])
    XCTAssertEqual(store.queue.position, 17.25)
    XCTAssertEqual(store.phase, .paused)
    XCTAssertFalse(store.playbackRequested)
    XCTAssertEqual(driver.starts, 0)
    store.play()
    try await StoreTests().wait { store.phase == .failed }
    XCTAssertEqual(store.current?.id, entry.id)
    XCTAssertEqual(store.queue.position, 17.25)
    XCTAssertEqual(driver.starts, 0)
    let requests = await http.requests
    XCTAssertEqual(requests.map { $0.url?.path }, ["/Users/Me", "/UserViews", "/Items"])
    await store.logout()
  }
  @MainActor func testStoreCurrentAndSuccessorKeepAcceptedRootWhileBrowsingAnother() async throws {
    let (directory, storage, vault, driver) = try StoreTests().context()
    defer { try? FileManager.default.removeItem(at: directory) }
    let http = ScriptedHTTP { request in
      let object: [String: Any]
      if request.url?.lastPathComponent == "UserViews" {
        object = [
          "Items": ["r1", "r2"].map {
            ["CollectionType": "music", "Type": "CollectionFolder", "Id": $0, "Name": $0]
          }
        ]
      } else if request.url?.lastPathComponent == "PlaybackInfo" {
        object = ["MediaSources": [["Id": "source", "SupportsDirectPlay": true]]]
      } else {
        let query =
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let ids = (query.first(where: { $0.name == "Ids" })?.value ?? "").split(separator: ",").map(
          String.init)
        object = ["Items": ids.map { ["Id": $0, "Type": "Audio"] }]
      }
      return HTTPReply(data: try! JSONSerialization.data(withJSONObject: object), status: 200)
    }
    let api = try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test"), userID: "listener", username: "Invented"),
      token: "invented-token", deviceID: "test", transport: http)
    let store = PlayerStore(storage: storage, vault: vault, driver: driver, deviceID: "test")
    await store.enterFixture(service: api)
    do {
      let browser = try XCTUnwrap(store.browser)
      await browser.start()
      await http.holdNext("PlaybackInfo")
      store.playItems(Array(MusicItem.fixtureTracks.prefix(2)), library: "r1")
      try await waitForMediaHold(http)
      browser.selectLibrary("r2")
      await http.release()
      try await StoreTests().wait {
        store.playing
          && store.queue.entries.dropFirst(store.queue.index + 1).first.map {
            driver.hasPrepared($0.id)
          } == true
      }
      XCTAssertEqual(browser.libraryID, "r2")
      XCTAssertEqual(store.queue.entries.map(\.libraryID), ["r1", "r1"])
      XCTAssertEqual(driver.starts, 1)
      XCTAssertEqual(driver.appended, [try XCTUnwrap(store.queue.entries.last).id])
      let requests = await http.requests
      let mediaProofs = requests.filter { request in
        let query =
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return query.contains(.init(name: "IncludeItemTypes", value: "Audio"))
          && query.contains { $0.name == "Ids" }
      }
      XCTAssertEqual(mediaProofs.count, 2)
      for request in mediaProofs {
        let query =
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(.init(name: "ParentId", value: "r1")))
      }
      XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "PlaybackInfo" }.count, 2)
    } catch {
      let settle = store.deferredPlaybackSettlementForCheck()
      store.pause()
      await http.release()
      await settle()
      await store.logout()
      throw error
    }
    let settle = store.deferredPlaybackSettlementForCheck()
    store.pause()
    await http.release()
    await settle()
    await store.logout()
  }
  @MainActor private func coldRootContext() async throws -> (
    URL, DriverSpy, PlayerStore, ScriptedHTTP
  ) {
    let (directory, storage, _, driver) = try StoreTests().context()
    do {
      let account = Connection(
        server: try ServerAddress("https://fixture.test"), userID: "listener", username: "Invented")
      try await storage.save(
        QueueState(
          entries: [QueueEntry(MusicItem.fixtureTracks[0], libraryID: "r1")], position: 3.25),
        account: account.id)
      let http = ScriptedHTTP { request in
        let object: [String: Any]
        switch request.url?.lastPathComponent {
        case "Me": object = ["Id": "listener"]
        case "UserViews":
          object = [
            "Items": ["r1", "r2"].map {
              ["CollectionType": "music", "Type": "CollectionFolder", "Id": $0, "Name": $0]
            }
          ]
        case "PlaybackInfo":
          object = ["MediaSources": [["Id": "source", "SupportsDirectPlay": true]]]
        default:
          let ids =
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "Ids" })?.value ?? ""
          object = ["Items": ids.split(separator: ",").map { ["Id": String($0), "Type": "Audio"] }]
        }
        return HTTPReply(data: try! JSONSerialization.data(withJSONObject: object), status: 200)
      }
      let store = PlayerStore(
        storage: storage, vault: ImmediateVault(), driver: driver, deviceID: "test",
        factory: {
          try JellyfinClient(connection: $0, token: $1, deviceID: "test", transport: http)
        })
      await store.activate(account)
      return (directory, driver, store, http)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
  @MainActor func testColdRestoredPlayAdmitsRootsWithoutStartingBrowse() async throws {
    let (directory, driver, store, http) = try await coldRootContext()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      let browser = try XCTUnwrap(store.browser)
      XCTAssertTrue(browser.libraries.isEmpty)
      XCTAssertNil(browser.libraryID)
      store.play()
      try await StoreTests().wait { driver.starts == 1 }
      XCTAssertEqual(driver.startedPositions, [3.25])
      XCTAssertEqual(store.queue.position, 3.25)
      XCTAssertNil(browser.libraryID, "Source admission does not choose a browse destination")
      XCTAssertTrue(browser.windows.isEmpty)
      XCTAssertTrue(browser.shelves.isEmpty)
      let beforeUI = await http.requests
      XCTAssertEqual(beforeUI.filter { $0.url?.lastPathComponent == "UserViews" }.count, 2)
      XCTAssertEqual(beforeUI.filter { $0.url?.lastPathComponent == "PlaybackInfo" }.count, 1)
      let proofs = beforeUI.filter { $0.url?.lastPathComponent == "Items" }
      XCTAssertEqual(proofs.count, 3, "Both restoration roots plus the exact current media proof")
      let fields = proofs.map {
        URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!
      }
      XCTAssertEqual(
        fields.map { $0.first(where: { $0.name == "ParentId" })?.value }, ["r1", "r2", "r1"])
      XCTAssertEqual(
        fields.map { $0.first(where: { $0.name == "Limit" })?.value }, ["40", "40", "1"])
      await browser.start()
      try await StoreTests().wait { browser.window.loaded }
      XCTAssertEqual(browser.libraryID, "r1")
      let afterUI = await http.requests
      XCTAssertEqual(afterUI.filter { $0.url?.lastPathComponent == "UserViews" }.count, 2)
      XCTAssertGreaterThan(
        afterUI.filter { $0.url?.lastPathComponent == "Items" }.count, proofs.count)
    } catch {
      let settle = store.deferredPlaybackSettlementForCheck()
      store.pause()
      await settle()
      await store.logout()
      throw error
    }
    let settle = store.deferredPlaybackSettlementForCheck()
    store.pause()
    await settle()
    await store.logout()
  }
  @MainActor func testColdRootAdmissionSharesUIProducerAndRejectsRetiredPlayback() async throws {
    for action in ["play", "canceledUI", "pause", "intent", "account"] {
      let (directory, driver, store, http) = try await coldRootContext()
      defer { try? FileManager.default.removeItem(at: directory) }
      let browser = try XCTUnwrap(store.browser)
      await http.holdNext("UserViews")
      var ui: Task<Void, Never>?
      var first: (@MainActor @Sendable () async -> Void)?
      var replacement: (@MainActor @Sendable () async -> Void)?
      do {
        if action == "play" || action == "canceledUI" {
          ui = Task { await browser.start() }
          try await waitForMediaHold(http)
          if action == "canceledUI" { ui?.cancel() }
        }
        store.play()
        first = store.deferredPlaybackSettlementForCheck()
        if action != "play" && action != "canceledUI" {
          try await waitForMediaHold(http)
          ui = Task { await browser.start() }
        }
        XCTAssertNil(browser.libraryID)
        XCTAssertEqual(driver.starts, 0)
        let held = await http.requests
        XCTAssertEqual(held.filter { $0.url?.lastPathComponent == "UserViews" }.count, 2)
        XCTAssertEqual(held.filter { $0.url?.lastPathComponent == "PlaybackInfo" }.count, 0)
        if action == "pause" {
          store.pause()
        } else if action == "intent" {
          store.play()
          replacement = store.deferredPlaybackSettlementForCheck()
        } else if action == "account" {
          await store.activate(
            Connection(
              server: try ServerAddress("https://replacement.fixture.test"), userID: "listener",
              username: "Replacement"))
        }
        await http.release()
        await ui?.value
        await first?()
        await replacement?()
        let shouldStart = action == "play" || action == "canceledUI" || action == "intent"
        XCTAssertEqual(driver.starts, shouldStart ? 1 : 0)
        XCTAssertEqual(driver.startedPositions, shouldStart ? [3.25] : [])
        let finished = await http.requests
        XCTAssertEqual(finished.filter { $0.url?.lastPathComponent == "UserViews" }.count, 2)
        XCTAssertEqual(
          finished.filter { $0.url?.lastPathComponent == "PlaybackInfo" }.count, shouldStart ? 1 : 0
        )
        if action == "account" {
          XCTAssertEqual(store.active?.server.url.host, "replacement.fixture.test")
          XCTAssertTrue(store.queue.entries.isEmpty)
          XCTAssertTrue(browser.libraries.isEmpty, "Retired producer cannot publish its late roots")
        } else {
          if action == "canceledUI" {
            XCTAssertNil(browser.libraryID, "Canceled first UI waiter cannot select a destination")
            await browser.start()
            try await StoreTests().wait { browser.window.loaded }
            let resumed = await http.requests
            XCTAssertEqual(resumed.filter { $0.url?.lastPathComponent == "UserViews" }.count, 2)
          }
          XCTAssertEqual(browser.libraryID, "r1", "Shared UI work survives a retired waiter")
          XCTAssertEqual(store.queue.position, 3.25)
        }
      } catch {
        let settle = store.deferredPlaybackSettlementForCheck()
        store.pause()
        await http.release()
        await ui?.value
        await first?()
        await replacement?()
        await settle()
        await store.logout()
        throw error
      }
      let settle = store.deferredPlaybackSettlementForCheck()
      store.pause()
      await settle()
      await store.logout()
    }
  }
  @MainActor func testRootRemovalRetiresParentActionsBeforeCallbackWithoutUIContinuation()
    async throws
  {
    for sourceOnly in [false, true] {
      for reentrantSelection in [false, true] {
        let (directory, _, store, http) = try await coldRootContext()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = try XCTUnwrap(store.browser)
        await browser.start()
        try await StoreTests().wait {
          browser.window.loaded && browser.shelves.values.allSatisfy { !$0.loading }
        }
        var album = MusicItem.fixtureAlbum
        album.favorite = false
        let detail = try XCTUnwrap(browser.detail(album))
        let priorScope = browser.scope
        var callbacks = 0
        browser.libraryRetired = {
          callbacks += 1
          guard callbacks == 1 else { return }
          XCTAssertNotEqual(browser.scope, priorScope)
          XCTAssertNil(detail.authorizedLibrary, "Retained parent detail is inert before callback")
          XCTAssertNil(detail.favoriteValue)
          detail.toggleFavorite()
          XCTAssertFalse(detail.favoritePending, "Revoked actions cannot schedule a write")
          XCTAssertTrue(browser.windows.isEmpty)
          XCTAssertNil(browser.artistMetadata)
          if reentrantSelection { browser.selectLibrary("r2") }
        }
        await http.replaceRoots(
          HTTPReply(
            data: Data(
              #"{"Items":[{"CollectionType":"music","Type":"CollectionFolder","Id":"r2","Name":"Second"}]}"#
                .utf8), status: 200))
        await http.holdNext("UserViews")
        let refresh = Task { await browser.loadLibraries() }
        var admission: Task<Bool, Never>?
        do {
          try await waitForMediaHold(http)
          if sourceOnly { refresh.cancel() }
          admission = Task { await browser.admitPlaybackLibrary("r2") }
          await http.release()
          await refresh.value
          let admitted = await admission!.value
          XCTAssertTrue(admitted)
          XCTAssertGreaterThanOrEqual(callbacks, 1)
          XCTAssertNil(detail.authorizedLibrary)
          if sourceOnly && !reentrantSelection {
            XCTAssertNil(browser.libraryID, "Root-only admission never chooses a destination")
            XCTAssertTrue(browser.windows.isEmpty)
          } else {
            XCTAssertEqual(
              browser.libraryID, "r2", "Owned transition and reentrant selection survive")
            try await StoreTests().wait {
              browser.window.loaded && browser.shelves.values.allSatisfy { !$0.loading }
            }
          }
          if sourceOnly && !reentrantSelection {
            await browser.start()
            try await StoreTests().wait {
              browser.window.loaded && browser.shelves.values.allSatisfy { !$0.loading }
            }
            XCTAssertEqual(browser.libraryID, "r2", "A new UI caller admits the cached transition")
          }
          let requests = await http.requests
          await browser.start()
          let repeated = await http.requests
          XCTAssertEqual(
            repeated.count, requests.count, "Initialized or reentrant UI stays unchanged")
          XCTAssertEqual(repeated.filter { $0.url?.lastPathComponent == "UserViews" }.count, 3)
          await detail.load()
          let afterAction = await http.requests
          XCTAssertEqual(afterAction.count, requests.count, "Revoked detail cannot issue requests")
          XCTAssertFalse(
            afterAction.contains { $0.httpMethod == "POST" || $0.httpMethod == "DELETE" })
        } catch {
          browser.retire()
          await http.release()
          await refresh.value
          _ = await admission?.value
          await store.logout()
          throw error
        }
        browser.libraryRetired = nil
        await store.logout()
      }
    }
  }
  @MainActor func testInitializedRootStartCannotRecaptureForeignSelectionAfterAwait()
    async throws
  {
    let (directory, _, store, http) = try await coldRootContext()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test"), userID: "listener", username: "Invented"),
      token: "invented-token", deviceID: "test", transport: http)
    var observeStart = false
    var entered = false
    let browser = MusicBrowser(
      service: api,
      isCurrent: {
        if observeStart { entered = true }
        return true
      })
    var refresh: Task<Void, Never>?
    var oldStart: Task<Void, Never>?
    do {
      await browser.start()
      try await StoreTests().wait {
        browser.window.loaded && browser.shelves.values.allSatisfy { !$0.loading }
      }
      await http.replaceRoots(
        HTTPReply(
          data: Data(
            #"{"Items":[{"CollectionType":"music","Type":"CollectionFolder","Id":"r1","Name":"First"}]}"#
              .utf8), status: 200))
      await http.holdNext("UserViews")
      refresh = Task { await browser.loadLibraries() }
      try await waitForMediaHold(http)
      observeStart = true
      oldStart = Task { await browser.start() }
      try await StoreTests().wait { entered }
      observeStart = false
      browser.selectLibrary("r2")
      await http.release()
      await refresh?.value
      await oldStart?.value
      XCTAssertNil(browser.libraryID, "The old UI caller cannot acquire a foreign committed scope")
      XCTAssertTrue(browser.windows.isEmpty)
      let beforeNew = await http.requests
      await browser.start()
      try await StoreTests().wait {
        browser.window.loaded && browser.shelves.values.allSatisfy { !$0.loading }
      }
      XCTAssertEqual(browser.libraryID, "r1", "A genuinely new UI caller may select accepted roots")
      let afterNew = await http.requests
      XCTAssertEqual(
        afterNew.filter { $0.url?.lastPathComponent == "UserViews" }.count,
        beforeNew.filter { $0.url?.lastPathComponent == "UserViews" }.count)
    } catch {
      observeStart = false
      browser.retire()
      await http.release()
      await refresh?.value
      await oldStart?.value
      await store.logout()
      throw error
    }
    browser.retire()
    await store.logout()
  }
  @MainActor func testMediaErrorAdmissionPrecedesLazyClassification() async throws {
    let http = ScriptedHTTP(replies: [])
    let client = try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test"), userID: "listener", username: "Invented"),
      token: "invented-token", deviceID: "test", transport: http)
    for cancelled in [false, true] {
      let evaluations = Mutex(0)
      let work = Task {
        if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
        try await client.rejectMediaError(
          library: "music", generation: nil, step: .playbackValidation,
          isCurrent: { cancelled },
          lazyError: {
            evaluations.withLock { $0 += 1 }
            return URLError(.networkConnectionLost)
          })
      }
      do {
        try await work.value
        XCTFail("Retired error admission succeeded")
      } catch { XCTAssertTrue(error is CancellationError) }
      XCTAssertEqual(evaluations.withLock { $0 }, 0, "Retired app classification stays lazy")
    }
    let evaluations = Mutex(0)
    do {
      try await client.rejectMediaError(
        library: "music", generation: nil, step: .playbackValidation, isCurrent: { true },
        lazyError: {
          evaluations.withLock { $0 += 1 }
          return URLError(.networkConnectionLost)
        })
    } catch {
      let detail = try XCTUnwrap(error as? ConnectionStepError)
      XCTAssertEqual(detail.step, .playbackValidation)
      XCTAssertEqual(detail.category, .network)
      XCTAssertEqual(detail.code, URLError.networkConnectionLost.rawValue)
    }
    XCTAssertEqual(evaluations.withLock { $0 }, 1, "Admitted app classification evaluates once")
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
  }
  @MainActor func testCurrentMediaErrorClassificationRetainsValidationStep() async throws {
    let http = ScriptedHTTP([
      (
        200,
        [
          "Items": [
            [
              "CollectionType": "music", "Type": "CollectionFolder", "Id": "music",
              "Name": "Invented",
            ]
          ]
        ]
      ),
      (200, ["Items": [["Id": "song", "Type": "Audio"]]]),
    ])
    let client = try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test"), userID: "listener", username: "Invented"),
      token: "invented-token", deviceID: "test", transport: http)
    let late = URLError(.networkConnectionLost)
    await http.holdNext("Items")
    let work = Task {
      try await client.media(
        library: "music", trackID: "song", quality: .original, isCurrent: { true })
    }
    do {
      try await waitForMediaHold(http)
      await http.release(error: late)
      var detail: ConnectionStepError?
      do {
        _ = try await work.value
        XCTFail("Current media error was not classified")
      } catch {
        detail = error as? ConnectionStepError
      }
      XCTAssertEqual(detail?.step, .playbackValidation)
      XCTAssertEqual(detail?.category, .network)
      XCTAssertEqual(detail?.code, URLError.networkConnectionLost.rawValue)
      let requests = await http.requests
      XCTAssertEqual(requests.map { $0.url?.path }, ["/UserViews", "/Items"])
    } catch {
      work.cancel()
      await http.release()
      _ = try? await work.value
      throw error
    }
  }
  func testPlaybackFailureDistinguishesValidationHTTPNegotiationAndNoSource() async throws {
    for (metadataStatus, playbackStatus, supported, expectedStep, expectedStatus, expectedKind) in [
      (
        503, 200, true, ConnectionStepError.Step.playbackValidation, 503,
        ConnectionStepError.Category.http
      ),
      (200, 500, true, .playbackInfo, 500, .http),
      (200, 200, false, .playbackSource, 0, .noSource),
    ] {
      let http = ScriptedHTTP(
        [
          (metadataStatus, ["Items": [["Id": "song", "Type": "Audio"]]]),
          (playbackStatus, ["MediaSources": [["Id": "source", "SupportsDirectPlay": supported]]]),
        ], musicRoot: true)
      let client = try JellyfinClient(
        connection: Connection(
          server: ServerAddress("https://fixture.test"), userID: "invented", username: "Invented"),
        token: "secret", deviceID: "test", transport: http)
      do {
        _ = try await client.media(
          library: "music", trackID: "song", quality: .original, isCurrent: { true })
        XCTFail("failed preparation accepted")
      } catch {
        let failure = try XCTUnwrap(error as? ConnectionStepError)
        XCTAssertEqual(failure.step, expectedStep)
        XCTAssertEqual(failure.status ?? 0, expectedStatus)
        XCTAssertEqual(failure.category, expectedKind)
      }
    }
  }
  func testNativeItemLogCodeRemainsDistinctFromHTTPAndRawErrorContent() {
    let raw = NSError(
      domain: "AVFoundationErrorDomain", code: -11800,
      userInfo: [
        NSLocalizedDescriptionKey: "private.invalid?token=secret",
        NSURLErrorFailingURLErrorKey: URL(string: "https://private.invalid/secret")!,
      ])
    let detail = ConnectionStepError(step: .playbackItem, error: raw, nativeLogCode: 502)
    XCTAssertEqual(detail.category, .nativeCode)
    XCTAssertEqual(detail.code, -11800)
    XCTAssertEqual(detail.nativeLogCode, 502)
    XCTAssertNil(detail.status, "A native error-log code is not a verified HTTP response")
    let propagated = ConnectionStepError(step: .playbackAudio, error: detail)
    XCTAssertEqual(propagated.step, .playbackItem)
    XCTAssertEqual(propagated.nativeLogCode, 502)
    let report = PlaybackFailure(detail: propagated, time: Date(timeIntervalSince1970: 0)).report(
      appVersion: "0.1(1)")
    XCTAssertTrue(report.contains("Native log code: 502"))
    XCTAssertTrue(report.contains("Code: -11800"))
    XCTAssertTrue(report.contains("HTTP: unavailable"))
    for forbidden in ["private.invalid", "secret", "token", "AVFoundationErrorDomain"] {
      XCTAssertFalse(report.contains(forbidden))
    }
  }
  func testPlaybackDiagnosticProjectsOnlySafeScalarsAndPreservesNativeSessionCode() {
    let url = URLError(
      .cannotConnectToHost,
      userInfo: [
        NSURLErrorFailingURLStringErrorKey: "https://secret.invalid/private?api_key=secret"
      ])
    let network = ConnectionStepError(step: .playbackInfo, error: url)
    XCTAssertEqual(network.code, -1004)
    XCTAssertEqual(network.category, .network)
    let native = ConnectionStepError(
      step: .audioSession,
      error: NSError(
        domain: NSOSStatusErrorDomain, code: 561_017_449,
        userInfo: [NSLocalizedDescriptionKey: "secret title and token"]))
    XCTAssertEqual(native.code, 561_017_449)
    XCTAssertEqual(native.category, .nativeCode)
    let report = PlaybackFailure(detail: native, time: Date(timeIntervalSince1970: 0)).report(
      appVersion: "0.1(1)")
    XCTAssertTrue(report.contains("Activating audio session"))
    XCTAssertTrue(report.contains("561017449"))
    XCTAssertTrue(report.contains("PB-3"))
    for secret in ["secret", "token", "title", "https", "userInfo", NSOSStatusErrorDomain] {
      XCTAssertFalse(report.contains(secret))
    }
    XCTAssertTrue(
      PlaybackFailure(detail: network, time: .now).report(appVersion: "secret").contains(
        "App: unknown"))
    let policy = ConnectionStepError(step: .audioSession, error: PlaybackProblem.audioSessionPolicy)
    XCTAssertEqual(policy.category, .audioSession)
  }
  func testPasswordsAndSavedCredentialsRequireHTTPSOutsideLiteralLoopback() async throws {
    let http = ScriptedHTTP([])
    for raw in ["http://music.example", "http://100.90.1.2", "http://node.example.ts.net"] {
      let server = try ServerAddress(raw)
      do {
        _ = try await JellyfinClient.login(
          server: server, username: "listener", password: "invented", deviceID: "fixture",
          transport: http)
        XCTFail("Allowed an unapproved HTTP sign-in")
      } catch { XCTAssertEqual(error as? ClientError, .secureConnectionRequired) }
      let saved = Connection(server: server, userID: "listener", username: "Listener")
      XCTAssertThrowsError(
        try JellyfinClient(
          connection: saved, token: "invented", deviceID: "fixture", transport: http))
    }
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
    for raw in [
      "http://100.90.1.2", "http://node.example.ts.net", "http://127.0.0.1.invalid",
      "http://100.128.1.2",
    ] {
      XCTAssertThrowsError(try ServerAddress(raw).requireCredentialTransport())
    }
    for raw in [
      "https://fixture.invalid", "https://node.example.ts.net", "http://127.0.0.1", "http://[::1]",
    ] {
      XCTAssertNoThrow(try ServerAddress(raw).requireCredentialTransport())
    }
  }
  func testSignOutTargetsOnlyTheDepartingServerSession() async throws {
    let http = ScriptedHTTP(replies: [HTTPReply(data: Data(), status: 204)])
    let connection = Connection(
      server: try ServerAddress("https://fixture.test/base"), userID: "listener",
      username: "Listener")
    let client = try JellyfinClient(
      connection: connection, token: "invented", deviceID: "fixture", transport: http)
    try await client.endSession()
    let requests = await http.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/base/Sessions/Logout")
    XCTAssertNil(request.url?.query)
    XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("invented") == true)
  }
  func testAuthenticationStatusAndSafeStepContextNeverEchoResponseOrSystemDetails() async throws {
    let http = ScriptedHTTP([(200, ["Version": "12.1.0"]), (401, ["private": "secret-body"])])
    do {
      _ = try await JellyfinClient.login(
        server: ServerAddress("https://fixture.test"), username: "invented", password: "secret",
        deviceID: "test", transport: http)
      XCTFail("HTTP authentication rejection accepted")
    } catch {
      let failure = try XCTUnwrap(error as? ConnectionStepError)
      XCTAssertEqual(failure.step, .authentication)
      XCTAssertEqual(failure.status, 401)
      XCTAssertTrue(failure.errorDescription!.contains("HTTP 401"))
      XCTAssertFalse(failure.errorDescription!.contains("secret"))
    }
    let error = URLError(
      .appTransportSecurityRequiresSecureConnection,
      userInfo: [NSURLErrorFailingURLStringErrorKey: "https://secret.invalid"])
    let failure = ConnectionStepError(step: .serverInfo, error: error)
    XCTAssertTrue(failure.errorDescription!.hasPrefix("Checking server:"))
    XCTAssertTrue(failure.errorDescription!.contains("iOS blocked"))
    XCTAssertFalse(failure.errorDescription!.contains("secret"))
    let decode = ConnectionStepError(
      step: .albums,
      error: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "secret-body")))
    XCTAssertTrue(decode.errorDescription!.hasPrefix("Loading albums:"))
    XCTAssertFalse(decode.errorDescription!.contains("secret"))
  }

  func testTransportMessagesSeparateATSNameTLSAndReachabilityWithoutEchoingSecrets() {
    let cases: [(URLError.Code, ClientError)] = [
      (.appTransportSecurityRequiresSecureConnection, .secureConnectionRequired),
      (.cannotFindHost, .serverNameNotFound), (.dnsLookupFailed, .serverNameNotFound),
      (.secureConnectionFailed, .secureConnectionFailed),
      (.serverCertificateUntrusted, .secureConnectionFailed), (.timedOut, .unavailable),
      (.notConnectedToInternet, .unavailable), (.cannotConnectToHost, .unavailable),
    ]
    for (code, expected) in cases {
      let error = URLError(
        code,
        userInfo: [NSURLErrorFailingURLStringErrorKey: "https://secret.invalid/?api_key=secret"])
      XCTAssertEqual(ClientError.transport(error), expected)
      XCTAssertFalse(ClientError.transport(error).errorDescription!.contains("secret"))
    }
  }
  func testUnsupportedServerDoesNotReceivePassword() async throws {
    let http = ScriptedHTTP([(200, ["Version": "13.0.0"])])
    do {
      _ = try await JellyfinClient.login(
        server: ServerAddress("https://fixture.test"), username: "invented",
        password: "invented-secret", deviceID: "test", transport: http)
      XCTFail("wrong baseline accepted")
    } catch { XCTAssertEqual(error as? ClientError, .unsupportedVersion) }
    let paths = await http.paths
    XCTAssertEqual(paths, ["/System/Info/Public"])
  }
  func testWrongServerInfoNeverLooksLikeVersionMismatchOrSendsPassword() async throws {
    let malformed = HTTPReply(data: Data("<html>web application</html>".utf8), status: 200)
    let missing = HTTPReply(data: Data("{\"applicationVersion\":\"12.1\"}".utf8), status: 200)
    let denied = HTTPReply(data: Data("{\"error\":\"not found\"}".utf8), status: 404)
    let unavailable = HTTPReply(data: Data(), status: 503)
    for reply in [malformed, missing, denied, unavailable] {
      let http = ScriptedHTTP(replies: [reply])
      do {
        _ = try await JellyfinClient.login(
          server: ServerAddress("https://fixture.test"), username: "invented",
          password: "invented-secret", deviceID: "test", transport: http)
        XCTFail("wrong endpoint accepted")
      } catch {
        XCTAssertEqual(
          error as? ClientError, reply.status == 503 ? .unavailable : .notJellyfinServer)
      }
      let paths = await http.paths
      XCTAssertEqual(paths, ["/System/Info/Public"])
    }
  }
  func testExactReported12_1VersionAuthenticatesWithDefaultPolicy() async throws {
    let http = ScriptedHTTP([
      (200, ["Version": "12.1.0"]),
      (200, ["AccessToken": "invented-token", "User": ["Id": "alice"]]), (200, ["Id": "alice"]),
    ])
    let (connection, _) = try await JellyfinClient.login(
      server: ServerAddress("https://fixture.test"), username: "alice", password: "invented",
      deviceID: "test", transport: http)
    XCTAssertEqual(connection.userID, "alice")
    let paths = await http.paths
    XCTAssertEqual(paths, ["/System/Info/Public", "/Users/AuthenticateByName", "/Users/Me"])
  }
  func testLoginRejectsDifferentAuthenticatedIdentity() async throws {
    let http = ScriptedHTTP([
      (200, ["Version": "12.2.0"]),
      (200, ["AccessToken": "invented-token", "User": ["Id": "alice"]]), (200, ["Id": "bob"]),
    ])
    do {
      _ = try await JellyfinClient.login(
        server: ServerAddress("https://fixture.test"), username: "alice", password: "invented",
        deviceID: "test", transport: http)
      XCTFail("wrong identity accepted")
    } catch { XCTAssertEqual(error as? ClientError, .unauthorized) }
  }
  func testDeniedItemNeverNegotiatesOrFallsBackToStaticEndpoint() async throws {
    let http = ScriptedHTTP([(200, ["Items": []])], musicRoot: true)
    let client = try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test"), userID: "alice", username: "Alice"),
      token: "invented-token", deviceID: "test", transport: http)
    do {
      _ = try await client.media(
        library: "music", trackID: "hidden", quality: .original, isCurrent: { true })
      XCTFail("denial bypassed")
    } catch { XCTAssertEqual(error as? ClientError, .forbidden) }
    let paths = await http.paths
    XCTAssertEqual(paths, ["/UserViews", "/Items"])
  }
  func testItemWireKeysDecodeForAlbumAndTrack() async throws {
    let http = ScriptedHTTP(
      [
        (
          200,
          [
            "Items": [
              [
                "Id": "album", "Name": "Invented album", "Type": "MusicAlbum",
                "AlbumArtist": "Invented artist", "ImageTags": ["Primary": "tag"],
              ]
            ]
          ]
        ),
        (200, ["Items": [["Id": "album", "Type": "MusicAlbum"]]]),
        (
          200,
          [
            "Items": [
              [
                "Id": "track", "Name": "Invented track", "Type": "Audio",
                "Artists": ["Invented artist"], "Album": "Invented album", "AlbumId": "album",
                "AlbumPrimaryImageTag": "tag", "RunTimeTicks": 80_000_000, "IndexNumber": 2,
              ]
            ]
          ]
        ),
      ], musicRoot: true)
    let api = try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test"), userID: "a", username: "A"),
      token: "invented-token", deviceID: "test", transport: http)
    let albums = try await api.catalog(CatalogQuery(library: "music"))
    let tracks = try await api.albumTracks(library: "music", album: "album")
    XCTAssertEqual(albums.first?.title, "Invented album")
    XCTAssertEqual(albums.first?.imageID, "album")
    XCTAssertEqual(tracks.first?.duration, 8)
    XCTAssertEqual(tracks.first?.artist, "Invented artist")
    XCTAssertEqual(tracks.first?.number, 2)
    XCTAssertEqual(tracks.first?.imageTag, "tag")
  }
  func testArtworkUsesAuthorizedSelectedOriginAndBoundedTaggedImageRequest() async throws {
    let http = ScriptedHTTP(replies: [HTTPReply(data: Data([1, 2, 3]), status: 200)])
    let client = try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test/jellyfin"), userID: "alice",
        username: "Invented"), token: "invented-token", deviceID: "test", transport: http)
    let item = MusicItem(
      id: "track", title: "Invented", artist: "Invented", album: "Invented", duration: 18,
      number: 1, kind: "Audio", imageID: "cover", imageTag: "v1")
    let data = try await client.artwork(item: item)
    XCTAssertEqual(data, Data([1, 2, 3]))
    let requests = await http.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.scheme, "https")
    XCTAssertEqual(request.url?.host, "fixture.test")
    XCTAssertEqual(request.url?.path, "/jellyfin/Items/cover/Images/Primary")
    XCTAssertTrue(
      request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"invented-token\"")
        == true)
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
    XCTAssertTrue(query.contains(.init(name: "maxWidth", value: "600")))
    XCTAssertTrue(query.contains(.init(name: "tag", value: "v1")))
    XCTAssertFalse(query.contains { $0.name == "api_key" })
    let missing = try await client.artwork(item: .fixtureAlbum)
    XCTAssertNil(missing)
    let count = await http.requests.count
    XCTAssertEqual(count, 1)
  }
  func testPlaybackWireRequestPolicyKeepsQualityAndCopyFlags() throws {
    for quality in [StreamQuality.original, .high, .compact] {
      let body = JellyfinPlaybackSource.requestBody(userID: "fixture-user", quality: quality)
      let reduced = quality != .original
      XCTAssertEqual(body["UserId"] as? String, "fixture-user")
      XCTAssertEqual(body["MaxStreamingBitrate"] as? Int, quality.bitrate)
      XCTAssertEqual(body["EnableDirectPlay"] as? Bool, !reduced)
      XCTAssertEqual(body["EnableDirectStream"] as? Bool, false)
      XCTAssertEqual(body["EnableTranscoding"] as? Bool, reduced)
      XCTAssertEqual(body["AllowAudioStreamCopy"] as? Bool, !reduced)
      let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
      XCTAssertEqual(profile["Name"] as? String, "Jukebox iOS")
      XCTAssertEqual(profile["MaxStreamingBitrate"] as? Int, quality.bitrate)
      XCTAssertEqual(profile["MusicStreamingTranscodingBitrate"] as? Int, quality.bitrate)
      let direct = try XCTUnwrap(profile["DirectPlayProfiles"] as? [[String: Any]])
      XCTAssertEqual(direct.count, reduced ? 0 : 1)
      if !reduced {
        XCTAssertEqual(direct.first?["Container"] as? String, "flac,mp3,aac,m4a,wav,alac,aiff")
        XCTAssertEqual(direct.first?["Type"] as? String, "Audio")
      }
      let transcode = try XCTUnwrap(
        (profile["TranscodingProfiles"] as? [[String: Any]])?.first)
      for (key, value) in [
        "Container": "mp3", "AudioCodec": "mp3", "Type": "Audio", "Context": "Streaming",
        "Protocol": "http", "TranscodeSeekInfo": "Bytes",
      ] {
        XCTAssertEqual(transcode[key] as? String, value)
      }
      XCTAssertEqual(transcode["EstimateContentLength"] as? Bool, true)
      XCTAssertEqual(transcode["EnableAudioVbrEncoding"] as? Bool, false)
      XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }
  }
  func testPlaybackWireSourceSelectionKeepsTimingAndRejectionBoundaries() throws {
    let connection = Connection(
      server: try ServerAddress("https://fixture.test/base"), userID: "fixture-user",
      username: "Invented")
    func parse(_ sources: [[String: Any]], quality: StreamQuality = .original) throws
      -> MediaSource
    {
      try JellyfinPlaybackSource.parse(
        JSONSerialization.data(withJSONObject: ["MediaSources": sources]), connection: connection,
        authorization: "invented-header", trackID: "song", quality: quality)
    }
    for quality in [StreamQuality.original, .high, .compact] {
      for runtime in [3.0, 5.0, 120.0] {
        let source = try parse(
          [
            [
              "Id": "first", "SupportsDirectPlay": true, "SupportsTranscoding": true,
              "TranscodingUrl": "/base/audio/song/stream.mp3?AudioBitRate=\(quality.bitrate)",
              "Container": "FLAC", "RunTimeTicks": runtime * 10_000_000,
            ],
            ["Id": "second", "SupportsDirectPlay": true],
          ], quality: quality)
        XCTAssertEqual(source.serverDuration, runtime)
        XCTAssertEqual(source.maximumTimeOrigin, max(0, runtime - 5))
        XCTAssertEqual(source.timeOrigin, 0)
        XCTAssertFalse(source.preferPreciseTiming)
        XCTAssertEqual(source.preciseSeekingRequired, quality == .original)
        XCTAssertEqual(source.serverTimeSeek, quality != .original)
        XCTAssertEqual(source.url.host, "fixture.test")
        let query = URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(source.usesBridge)
        XCTAssertEqual(
          try source.starting(at: 1).upstreamRequest.value(forHTTPHeaderField: "Authorization"),
          "invented-header")
        if quality == .original {
          XCTAssertEqual(source.url.path, "/base/Audio/song/stream")
          XCTAssertEqual(query.first { $0.name == "MediaSourceId" }?.value, "first")
          XCTAssertEqual(query.first { $0.name == "static" }?.value, "true")
          XCTAssertFalse(query.contains { $0.name == "api_key" })
        } else {
          XCTAssertEqual(source.url.path, "/base/audio/song/stream.mp3")
          XCTAssertEqual(query.first { $0.name == "StartTimeTicks" }?.value, "0")
          XCTAssertEqual(query.first { $0.name == "CopyTimestamps" }?.value, "false")
          XCTAssertEqual(query.filter { $0.name == "PlaySessionId" }.count, 1)
        }
      }
    }
    for quality in [StreamQuality.original, .high, .compact] {
      let selected = try parse(
        [
          ["Id": "unsupported", "SupportsDirectPlay": false, "SupportsTranscoding": false],
          [
            "Id": "usable", "SupportsDirectPlay": true, "SupportsTranscoding": true,
            "TranscodingUrl": "/base/audio/song/stream.mp3?AudioBitRate=\(quality.bitrate)",
            "RunTimeTicks": 420_000_000,
          ],
        ], quality: quality)
      XCTAssertEqual(selected.serverDuration, 42)
    }
    XCTAssertThrowsError(try parse([[:], ["Id": "second", "SupportsDirectPlay": true]])) {
      XCTAssertEqual($0 as? ClientError, .invalidResponse)
    }
    XCTAssertThrowsError(try parse([["Id": "first", "SupportsDirectPlay": "true"]])) {
      guard case PlaybackProblem.noSource = $0 else { return XCTFail("Support cast changed") }
    }
    for path in [
      "/base/audio/song/stream.mp3?AudioBitRate=128000",
      "https://other.test/base/audio/song/stream.mp3?AudioBitRate=192000",
    ] {
      XCTAssertThrowsError(
        try parse(
          [["Id": "first", "SupportsTranscoding": true, "TranscodingUrl": path]], quality: .high)
      ) { XCTAssertEqual($0 as? ClientError, .invalidResponse) }
    }
    let unknown = try parse([["Id": "first", "SupportsDirectPlay": true, "RunTimeTicks": "120"]])
    XCTAssertFalse(unknown.preferPreciseTiming)
    XCTAssertFalse(unknown.preciseSeekingRequired)
    XCTAssertNil(unknown.serverDuration)
    XCTAssertNil(unknown.maximumTimeOrigin)
    let streamFlac = try parse([
      [
        "Id": "first", "SupportsDirectPlay": true,
        "MediaStreams": [["Type": "AUDIO", "Codec": "FLAC"]],
      ]
    ])
    XCTAssertFalse(streamFlac.preferPreciseTiming)
    XCTAssertTrue(streamFlac.preciseSeekingRequired)
    XCTAssertTrue(try streamFlac.starting(at: 7.25).preferPreciseTiming)
  }
  func testOriginalFlacDefersPrecisionUntilPositiveStartWithoutChangingReducedOutput() async throws
  {
    for quality in [StreamQuality.original, .high, .compact] {
      for descriptor: [String: Any] in [
        ["Container": "FLAC"],
        ["MediaStreams": [["Type": "Audio", "Codec": "flac"]]],
        ["Container": "mp3"], [:],
      ] {
        var source = descriptor
        source["Id"] = "source"
        source["SupportsDirectPlay"] = true
        source["SupportsTranscoding"] = true
        source["TranscodingUrl"] = "/base/audio/song/stream.mp3?AudioBitRate=\(quality.bitrate)"
        source["RunTimeTicks"] = 200_000_000
        let http = ScriptedHTTP(
          [
            (200, ["Items": [["Id": "song", "Type": "Audio"]]]),
            (200, ["MediaSources": [source]]),
          ], musicRoot: true)
        let client = try JellyfinClient(
          connection: Connection(
            server: ServerAddress("https://fixture.test/base"), userID: "alice", username: "Alice"),
          token: "invented-token", deviceID: "test", transport: http)
        let media = try await client.media(
          library: "music", trackID: "song", quality: quality, isCurrent: { true })
        XCTAssertEqual(media.quality, quality)
        XCTAssertEqual(media.serverTimeSeek, quality != .original)
        XCTAssertEqual(
          media.preciseSeekingRequired,
          quality == .original
            && (descriptor["Container"] as? String == "FLAC"
              || descriptor["MediaStreams"] != nil)
        )
        XCTAssertFalse(media.preferPreciseTiming)
        let positive = try media.starting(at: 7.25)
        XCTAssertEqual(positive.preferPreciseTiming, media.preciseSeekingRequired)
        XCTAssertEqual(positive.preciseSeekingRequired, media.preciseSeekingRequired)
        if quality == .original {
          XCTAssertEqual(positive.url, media.url)
          XCTAssertEqual(positive.timeOrigin, 0)
        } else {
          XCTAssertEqual(positive.timeOrigin, 7.25)
        }
        XCTAssertEqual(media.url.host, "fixture.test")
        XCTAssertEqual(
          media.url.path,
          quality == .original ? "/base/Audio/song/stream" : "/base/audio/song/stream.mp3")
      }
    }
  }
  func testSelectedQualityOverridesServerDefault128k() async throws {
    let http = ScriptedHTTP(
      [
        (200, ["Items": [["Id": "song", "Type": "Audio"]]]),
        (
          200,
          [
            "MediaSources": [
              [
                "Id": "source", "SupportsTranscoding": true,
                "TranscodingUrl": "/audio/song/stream.mp3?AudioBitRate=192000",
              ]
            ]
          ]
        ),
      ], musicRoot: true)
    let client = try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test"), userID: "alice", username: "Alice"),
      token: "invented-token", deviceID: "test", transport: http)
    let source = try await client.media(
      library: "music", trackID: "song", quality: .high, isCurrent: { true })
    XCTAssertEqual(source.quality, .high)
    let bodies = await http.bodies
    let body = try JSONSerialization.jsonObject(with: bodies[2]) as! [String: Any]
    let profile = body["DeviceProfile"] as! [String: Any]
    XCTAssertEqual(profile["MusicStreamingTranscodingBitrate"] as? Int, 192000)
  }
  func testNegotiatedExternalOriginCannotReceiveToken() async throws {
    let http = ScriptedHTTP(
      [
        (200, ["Items": [["Id": "song", "Type": "Audio"]]]),
        (
          200,
          [
            "MediaSources": [
              [
                "Id": "source", "SupportsTranscoding": true,
                "TranscodingUrl": "https://other.test/Audio/song/stream.mp3?AudioBitRate=96000",
              ]
            ]
          ]
        ),
      ], musicRoot: true)
    let client = try JellyfinClient(
      connection: Connection(
        server: ServerAddress("https://fixture.test"), userID: "alice", username: "Alice"),
      token: "invented-token", deviceID: "test", transport: http)
    do {
      _ = try await client.media(
        library: "music", trackID: "song", quality: .compact, isCurrent: { true })
      XCTFail("foreign origin accepted")
    } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
  }
}
