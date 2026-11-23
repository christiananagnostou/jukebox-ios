#if DEBUG
  import AVFoundation
  import CryptoKit
  import Foundation
  import MediaPlayer
  import UIKit

  @MainActor enum DevelopmentAcceptance {
    struct Input: Decodable {
      let base: String
      let username: String
      let password: String
      let runID: UUID
      let stage: Int
      let expectedOriginalSHA256: String
    }
    struct CheckFailure: Error { let step: String }
    static func readyBrowser(store: PlayerStore) async throws -> MusicBrowser {
      guard let browser = store.browser, store.active != nil else {
        throw CheckFailure(step: "fixture-browser-missing")
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      await browser.start()
      while true {
        try Task.checkCancellation()
        guard store.browser === browser, store.active != nil else {
          throw CheckFailure(step: "fixture-browser-retired")
        }
        guard ContinuousClock.now < deadline else {
          throw CheckFailure(step: "fixture-library-ready-timeout")
        }
        if !browser.loadingLibraries, let root = browser.authorizedLibrary,
          store.playbackOrigin(library: root) != nil
        {
          return browser
        }
        try await Task.sleep(for: .milliseconds(50))
      }
    }
    static func albumSelection(store: PlayerStore, album: MusicItem, library: String? = nil)
      async throws -> PlaybackSelection
    {
      let browser = try await readyBrowser(store: store)
      if let library { browser.selectLibrary(library) }
      guard let origin = store.playbackOrigin(library: browser.authorizedLibrary),
        library == nil || origin.library == library, let content = browser.detail(album)
      else { throw CheckFailure(step: "fixture-album-root-not-accepted") }
      async let cover: Void = store.loadCover(album, origin: origin)
      await content.load()
      _ = await cover
      guard store.browser === browser, !content.loading, content.error == nil,
        let selection = store.playbackSelection(content.tracks, library: content.authorizedLibrary)
      else { throw CheckFailure(step: "fixture-album-not-accepted") }
      return selection
    }
    static func fixtureAlbumSelection(store: PlayerStore) async throws -> PlaybackSelection {
      guard store.isFixture else { throw CheckFailure(step: "fixture-account-required") }
      return try await albumSelection(store: store, album: .fixtureAlbum)
    }
    static func firstAlbumSelection(store: PlayerStore) async throws -> PlaybackSelection {
      let browser = try await readyBrowser(store: store)
      browser.selectCategory(.albums)
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while !browser.window.loaded || browser.window.loading {
        try Task.checkCancellation()
        guard store.browser === browser, ContinuousClock.now < deadline else {
          throw CheckFailure(step: "fixture-first-album-timeout")
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      guard let album = browser.window.items.first else {
        throw CheckFailure(step: "fixture-first-album-missing")
      }
      return try await albumSelection(store: store, album: album)
    }
    static func run(
      store: PlayerStore, native: NativePlayer, storage: LibraryStorage, vault: any TokenVault
    ) async {
      let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      let inputURL = documents.appendingPathComponent("development-input.json")
      var result: [String: Any] = [:]
      func require(_ condition: Bool, _ step: String) throws {
        if !condition { throw CheckFailure(step: step) }
      }
      func wait(_ step: String, seconds: Double = 12, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
          if condition() { return }
          if store.phase == .failed || store.error != nil {
            throw CheckFailure(step: step + "-player-error")
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        throw CheckFailure(step: step + "-timeout")
      }
      do {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: inputURL))
        try FileManager.default.removeItem(at: inputURL)
        result = ["run_id": input.runID.uuidString, "stage": input.stage]
        let address = try ServerAddress(input.base)
        try require(
          address.url.host == "127.0.0.1" && address.url.scheme == "http", "loopback-only-input")
        if input.stage == 0 {
          for connection in try await storage.connections() {
            try await vault.erase(account: connection.id)
            try await storage.retire(account: connection.id, erase: true)
          }
          try await storage.saveConnections([])
          result["finished"] = true
        } else if input.stage == 10 || input.stage == 11 {
          let (connection, token) = try await JellyfinClient.login(
            server: address, username: input.username, password: input.password,
            deviceID: "catalog-acceptance")
          let api = try JellyfinClient(
            connection: connection, token: token, deviceID: "catalog-acceptance")
          await store.signIn(
            address: input.base, username: input.username, password: input.password)
          try require(store.active != nil, "catalog-normal-login")
          result["catalog"] = try await CatalogAcceptance.run(
            api: api, store: store, checkCover: input.stage == 11)
          await store.logout()
          result["finished"] = true
        } else if input.stage == 9 {
          result["tail_lifetime"] = try await tailLifetime(native: native, address: address.url)
          result["finished"] = true
        } else if input.stage == 8 {
          await store.signIn(
            address: input.base, username: input.username, password: input.password)
          let selection = try await firstAlbumSelection(store: store)
          result["selected_near_end"] = try await localTailControl(
            store: store, native: native, vault: vault, selection: selection)
          await store.logout()
          result["finished"] = true
        } else if input.stage == 7 {
          await store.signIn(
            address: input.base, username: input.username, password: input.password)
          try require(store.active != nil, "long-quality-login")
          let selection = try await firstAlbumSelection(store: store)
          result["quality_transitions"] = try await qualityTransitions(
            store: store, native: native, selection: selection)
          await store.logout()
          result["finished"] = true
        } else if input.stage == 6 {
          await store.signIn(
            address: input.base, username: input.username, password: input.password)
          let selection = try await firstAlbumSelection(store: store)
          result["selected_near_end"] = try await selectedQualityNearEnd(
            store: store, native: native, selection: selection)
          await store.logout()
          result["finished"] = true
        } else if input.stage == 5 {
          result["timing"] = try await timing(store: store, native: native, address: address.url)
          result["finished"] = true
        } else if input.stage == 4 {
          result["recovery"] = try await recovery(
            store: store, native: native, address: address.url)
          result["finished"] = true
        } else if input.stage == 13 {
          result["completed_readiness_controls"] = try await readinessControls(
            store: store, native: native, address: address.url)
          result["finished"] = true
        } else if input.stage == 3 {
          await store.signIn(
            address: input.base, username: input.username, password: input.password)
          try require(store.active != nil && store.error == nil, "transition-login")
          let selection = try await firstAlbumSelection(store: store)
          try require(selection.items.count == 3, "three-contiguous-generated-parts")
          var cases: [[String: Any]] = []
          for quality in StreamQuality.allCases {
            cases.append(
              try await transitions(
                store: store, native: native, quality: quality, selection: selection))
          }
          result["cases"] = cases
          await store.logout()
          let delayed = PlayerStore(
            storage: storage, vault: vault, driver: native, deviceID: "delayed-fixture",
            factory: { connection, token in
              DelayedSuccessor(
                api: try JellyfinClient(
                  connection: connection, token: token, deviceID: "delayed-fixture"))
            })
          await delayed.signIn(
            address: input.base, username: input.username, password: input.password)
          let controlSelection = try await firstAlbumSelection(store: delayed)
          let control = try await transitions(
            store: delayed, native: native, quality: .original, selection: controlSelection)
          result["delayed_successor_control"] = control
          try require(
            control["engineering_gate"] as? Bool == false, "control-failed-to-detect-delay")
          try require(
            control["retry_required_at_end"] as? Bool == true, "control-retains-explicit-retry")
          await delayed.logout()
          result["finished"] = true
        } else if input.stage == 1 {
          let (connection, token) = try await JellyfinClient.login(
            server: address, username: input.username, password: input.password,
            deviceID: "acceptance-bytes", allowedFamilies: ["12.1", "12.2"])
          result["ordinary_api_login"] = true
          let api = try JellyfinClient(
            connection: connection, token: token, deviceID: "acceptance-bytes")
          await store.signIn(
            address: input.base, username: input.username, password: input.password)
          if store.active == nil {
            result["login_message"] = store.error
            if let keychain = vault as? KeychainVault {
              result["keychain_status"] = await keychain.diagnosticStatus
            }
          }
          try require(store.active != nil && store.error == nil, "normal-login")
          guard
            let controlledRoot = try await api.musicLibraries(refresh: false).first(where: {
              $0.title == "restricted"
            }),
            let album = try await api.catalog(CatalogQuery(library: controlledRoot.id)).first(
              where: { $0.title == "Restricted Album" })
          else { throw CheckFailure(step: "album-metadata") }
          let selection = try await albumSelection(
            store: store, album: album, library: controlledRoot.id)
          try require(!selection.items.isEmpty, "album-tracks")
          result["album_count"] = store.browser?.window.items.count ?? 0
          result["track_count"] = selection.items.count
          let track = selection.items[0]
          for quality in StreamQuality.allCases {
            let source = try await api.media(
              library: selection.origin.library, trackID: track.id, quality: quality,
              isCurrent: {
                store.playbackOrigin(library: selection.origin.library) == selection.origin
              })
            try require(
              source.preferPreciseTiming == (quality == .original),
              "negotiated-payload-timing-\(quality.rawValue)")
            result["precise_timing_\(quality.rawValue)"] = source.preferPreciseTiming
            let reply = try await LiveHTTP().send(source.upstreamRequest)
            try require(
              reply.status == 200 && !reply.data.isEmpty, "quality-body-\(quality.rawValue)")
            if quality == .original {
              let digest = SHA256.hash(data: reply.data).map { String(format: "%02x", $0) }.joined()
              try require(digest == input.expectedOriginalSHA256, "original-byte-identity")
              result["original_bytes_match"] = true
            } else {
              try reply.data.write(
                to: documents.appendingPathComponent("development-\(quality.rawValue).mp3"),
                options: .atomic)
            }
          }
          store.quality(.original)
          store.playSelection(selection)
          try await wait("original-advances") { store.playing && store.queue.position > 0.5 }
          store.seek(4)
          try await wait("original-forward-seek") { store.queue.position >= 4.1 }
          try await wait("original-completes", seconds: 14) {
            store.phase == .paused && !store.playbackRequested
          }
          try require(
            store.queue.index == store.queue.entries.count - 1, "queue-reaches-last-occurrence")
          result["queue_occurrences"] = store.queue.entries.count
          result["original_play_seek_completion"] = true
          store.quality(.high)
          try require(
            store.phase == .paused && !store.playbackRequested, "paused-quality-does-not-autoplay")
          store.play()
          try await wait("selected-quality-advances") { store.playing && store.queue.position > 1 }
          store.pause()
          let pausedClock = native.queueReadout.absoluteSeconds
          try require(
            abs(store.queue.position - pausedClock) < 0.02, "pause-clock-not-sampled-before-save")
          result["paused_native_clock"] = pausedClock
          let outgoingPosition = store.queue.position
          let outgoingOccurrence = store.current?.id
          guard let outgoingAccount = store.active else {
            throw CheckFailure(step: "outgoing-account-missing")
          }
          await store.activate(outgoingAccount)
          result["outgoing_save_state"] = [
            "position_before": outgoingPosition, "position_after": store.queue.position,
            "same_occurrence": store.current?.id == outgoingOccurrence,
            "quality_high": store.queue.quality == .high, "phase": store.phase.rawValue,
            "playback_requested": store.playbackRequested,
          ]
          try require(
            abs(store.queue.position - outgoingPosition) <= 0.05
              && store.current?.id == outgoingOccurrence && store.queue.quality == .high
              && store.phase == .paused && !store.playbackRequested
              && native.safeStatus["queue_items"] as? Int == 0,
            "outgoing-save-before-paused-reactivation")
          try await store.saveNow()
          try require(store.queue.position > 1, "paused-position-saved")
          result["saved_position"] = store.queue.position
          result["saved_occurrence"] = store.current?.id.uuidString
          result["native_configuration"] = native.safeStatus
          result["ready_for_relaunch"] = true
        } else {
          await store.bootstrap()
          result["restoration_state"] = [
            "active": store.active != nil, "quality": store.queue.quality.rawValue,
            "position": store.queue.position, "phase": store.phase.rawValue,
            "playback_requested": store.playbackRequested, "safe_error_present": store.error != nil,
          ]
          try require(
            store.active != nil && store.queue.quality == .high && store.queue.position > 1
              && store.phase == .paused && !store.playbackRequested, "relaunch-restores-paused")
          result["restored_position"] = store.queue.position
          result["restored_occurrence"] = store.current?.id.uuidString
          try await Task.sleep(for: .seconds(1))
          try require(store.phase == .paused, "no-delayed-autoplay")
          store.quality(.compact)
          store.play()
          try await wait("compact-advances") { store.playing && store.queue.position > 1.5 }
          store.seek(4)
          try await wait("compact-seek") { store.queue.position > 4.1 }
          try await wait("compact-completes", seconds: 14) {
            store.phase == .paused && !store.playbackRequested
          }
          result["compact_play_seek_completion"] = true
          guard let account = store.active?.id else {
            throw CheckFailure(step: "account-before-logout")
          }
          await store.logout()
          let token = try await vault.read(account: account)
          let queue = try await storage.restore(account: account)
          try require(
            store.active == nil && token == nil && queue == nil && store.connections.isEmpty,
            "logout-retires-credential-and-queue")
          result["logout_retirement"] = true
          result["finished"] = true
        }
      } catch {
        if !recoverySnapshot.isEmpty { result["recovery_snapshot"] = recoverySnapshot }
        if !qualitySnapshot.isEmpty { result["quality_snapshot"] = qualitySnapshot }
        result["error_domain"] = (error as NSError).domain
        result["error_code"] = (error as NSError).code
        result["failure"] =
          (error as? CheckFailure)?.step ?? (error as? ClientError)?.rawDiagnostic
          ?? "unexpected-acceptance-error"
      }
      if let data = try? JSONSerialization.data(
        withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
      {
        try? data.write(
          to: documents.appendingPathComponent("development-report.json"), options: .atomic)
      }
    }
  }
  extension ClientError {
    fileprivate var rawDiagnostic: String {
      switch self {
      case .invalidServer: "invalid-server"
      case .invalidResponse: "invalid-response"
      case .unauthorized: "unauthorized"
      case .forbidden: "forbidden"
      case .unsupportedVersion: "unsupported-version"
      case .unavailable: "unavailable"
      case .secureStorage: "secure-storage"
      case .notJellyfinServer: "not-jellyfin-server"
      case .secureConnectionRequired: "secure-connection-required"
      case .secureConnectionFailed: "secure-connection-failed"
      case .serverNameNotFound: "server-name-not-found"
      }
    }
  }

#endif
