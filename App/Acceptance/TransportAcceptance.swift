#if DEBUG
  import AVFoundation
  import CryptoKit
  import Foundation
  import MediaPlayer
  import UIKit

  @MainActor enum TransportAcceptance {
    static func run(
      runID: UUID, store: PlayerStore, native: NativePlayer, vault: any TokenVault,
      fixture: FixtureCatalog
    ) async {
      defer { AppLog.endAcceptance(runID) }
      let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      var report: [String: Any] = ["run_id": runID.uuidString, "control_version": 4]
      var phase: TransportControlPhase?
      var storeLease: PlayerStore.TransportAcceptanceLease?
      var playerSelection: PlaybackSelection?
      defer { phase?.retire() }
      do {
        let data = try TransportControlFiles.consumeInput(in: documents, runID: runID)
        let input = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #if AUDIO_CLOCK_ACCEPTANCE && LIVE_MUSIC_ACCEPTANCE
          if let input, input["scenario"] == "real-music-speaker-pause" {
            try await AudioClockAcceptance.runSpeakerPause(
              input, runID: runID, documents: documents, store: store, native: native)
            return
          }
          if let input, input["scenario"] == "real-music-album-audio-clock" {
            try await AudioClockAcceptance.runAlbum(
              input, runID: runID, documents: documents, store: store, native: native)
            return
          }
          if let input, input["scenario"] == "real-music-audio-clock-v2" {
            try await AudioClockAcceptance.run(
              input, runID: runID, documents: documents, store: store, native: native)
            return
          }
        #endif
        #if LIVE_MUSIC_ACCEPTANCE
          if input?["scenario"] == "real-music-high" {
            guard let input,
              Set(input.keys) == ["run_id", "scenario", "version", "nonce", "deadline_unix_ms"],
              input["run_id"].flatMap(UUID.init(uuidString:)) == runID, input["version"] == "1",
              let nonce = input["nonce"].flatMap(UUID.init(uuidString:)),
              let deadlineMS = input["deadline_unix_ms"].flatMap(Double.init), deadlineMS.isFinite,
              deadlineMS > Date().timeIntervalSince1970 * 1000,
              deadlineMS <= (Date().timeIntervalSince1970 + 1200) * 1000
            else { throw ClientError.invalidResponse }
            await realMusicHigh(
              runID: runID, nonce: nonce, deadline: Date(timeIntervalSince1970: deadlineMS / 1000),
              documents: documents, native: native)
            return
          }
        #endif
        if input?["version"] != nil || input?["nonce"] != nil
          || ["session", "artwork"].contains(input?["scenario"] ?? "")
        {
          let local = try TransportLocalInput(input ?? [:], runID: runID)
          await localGate(
            local.scenario, runID: runID, nonce: local.nonce, documents: documents,
            store: store, native: native, fixture: fixture)
          return
        }
        let capture = TransportCapture.shared
        report["diagnostics_off_by_default"] =
          capture.currentState() == .idle && capture.context() == nil
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: String],
          let address = value["server"], let url = URL(string: address), url.scheme == "http",
          url.path.isEmpty,
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          let host = url.host, let port = url.port, (1024...65535).contains(port),
          TransportControlFiles.acceptsLiteral(host)
        else { throw ClientError.invalidServer }
        let scenario = value["scenario"] ?? "baseline"
        guard ["baseline", "cancellation", "player", "original-startup"].contains(scenario) else {
          throw ClientError.invalidResponse
        }
        report["scenario"] = scenario
        let server = try ServerAddress(address)
        if scenario == "original-startup" {
          guard Set(value.keys) == ["run_id", "server", "scenario", "variant"],
            value["run_id"].flatMap(UUID.init(uuidString:)) == runID,
            let variant = value["variant"], ["plain", "precise"].contains(variant)
          else { throw ClientError.invalidResponse }
          let original = try TransportControlPhase(
            capture: capture, policyBits: TransportCapture.bundledPolicyBits())
          phase = original
          report = try await originalStartup(
            runID: runID, variant: variant, server: server, native: native, phase: original)
          try original.perform {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try TransportControlFiles.publish(data, in: documents, runID: runID)
          }
          return
        }
        if scenario == "player" {
          let connection = Connection(server: server, userID: "fixture-user", username: "Invented")
          try await vault.write("invented-transport-token", account: connection.id)
          guard let accepted = await store.activateTransportAcceptance(connection) else {
            throw ClientError.invalidResponse
          }
          storeLease = accepted
          try Task.checkCancellation()
          guard store.ownsTransportAcceptance(accepted) else { throw CancellationError() }
          let selection = try await DevelopmentAcceptance.firstAlbumSelection(store: store)
          guard store.ownsTransportAcceptance(accepted), store.active?.id == connection.id,
            selection.items.count == 2, store.error == nil
          else { throw ClientError.invalidResponse }
          playerSelection = selection
        }
        let preparation = try TransportControlPhase(
          capture: capture, policyBits: TransportCapture.bundledPolicyBits())
        phase = preparation
        let client = try JellyfinClient(
          connection: Connection(server: server, userID: "fixture-user", username: "Invented"),
          token: "invented-transport-token", deviceID: "transport-control",
          transport: TransportControlHTTP(phase: preparation))
        let empty = try snapshot(preparation)
        report["diagnostic_start_empty"] = (empty["events"] as? [Any])?.isEmpty == true
        if scenario == "player" {
          guard let accepted = storeLease, let playerSelection else {
            throw ClientError.invalidResponse
          }
          var owned = accepted
          do {
            report["player_witness"] = try await playerWitness(
              store: store, native: native, server: server, phase: preparation,
              selection: playerSelection, owner: &owned)
          } catch {
            storeLease = owned
            throw error
          }
          storeLease = owned
          let observed = try snapshot(preparation)
          report["preparation_events"] = observed["events"]
          report["preparation_event_count"] = (observed["events"] as? [Any])?.count ?? -1
        } else {
          var codes: [Int] = []
          for index in 0..<8 {
            guard preparation.current() else { throw CancellationError() }
            codes.append(await prepare(client, index: index, phase: preparation))
          }
          report["sequential_preparation_codes"] = codes
          let concurrent = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for index in 0..<16 {
              group.addTask { await prepare(client, index: index, phase: preparation) }
            }
            var values: [Int] = []
            for await code in group { values.append(code) }
            return values.sorted()
          }
          report["concurrent_preparation_codes"] = concurrent
          let bounded = try snapshot(preparation)
          report["diagnostic_event_count"] = (bounded["events"] as? [Any])?.count ?? -1
          report["diagnostic_bounded_state"] = bounded["state"]
          if scenario == "cancellation" {
            var cancelled: [Int] = []
            var current: [Int] = []
            for index in 0..<12 {
              try preparation.perform {}
              let outgoing = Task { await prepare(client, index: index, phase: preparation) }
              try await Task.sleep(for: .milliseconds(index.isMultiple(of: 2) ? 30 : 160))
              let latest = Task { await prepare(client, index: index + 1, phase: preparation) }
              outgoing.cancel()
              cancelled.append(await outgoing.value)
              current.append(await latest.value)
            }
            report["synthetic_cancelled_codes"] = cancelled
            report["synthetic_current_codes"] = current
          }
        }
        try preparation.perform {}
        preparation.retire()
        let policy = try TransportControlPhase(
          capture: capture, policyBits: TransportCapture.bundledPolicyBits())
        phase = policy
        let transport = TransportControlHTTP(phase: policy)
        let redirect = try await transport.send(URLRequest(url: try server.endpoint("redirect")))
        report["redirect_status"] = try policy.perform { redirect.status }
        report["public_http_code"] = await code(
          transport, url: URL(string: "http://192.0.2.1:\(port)/blocked")!, phase: policy)
        report["public_https_code"] = await code(
          transport, url: URL(string: "https://www.apple.com/library/test/success.html")!,
          phase: policy)
        let observed = try snapshot(policy)
        report["native_denial_captured"] = (observed["events"] as? [[String: Any]] ?? []).contains {
          ($0["evidence"] as? [String: Any])?["error"] as? Int == -1022
        }
        report["diagnostic_policy_bits"] = observed["policyBits"]
        report["finished"] = true
      } catch {
        if let phase, phase.current() { report["failure_code"] = numeric(error) }
      }
      if let phase {
        try? phase.perform {
          let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
          try TransportControlFiles.publish(data, in: documents, runID: runID)
        }
      }
      if let storeLease { _ = store.retireTransportAcceptance(owned: storeLease) }
    }
    #if LIVE_MUSIC_ACCEPTANCE
      private final class RealMusicScope {
        let deadline: Date
        var live = true
        init(deadline: Date) { self.deadline = deadline }
        func current() -> Bool { live && !Task.isCancelled && Date() < deadline }
      }
      private static func realMusicRead(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size > 0, size <= maximum
        else { throw ClientError.invalidResponse }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw ClientError.invalidResponse }
        return data
      }
      private static func realMusicMS(_ value: Double) -> Int {
        guard value.isFinite, abs(value) <= 1_000_000 else { return -1 }
        return Int((value * 1000).rounded())
      }
      private static func realMusicError(_ error: Error) -> [String: Any] {
        let detail = ConnectionStepError(step: .playbackAudio, error: error)
        return [
          "code": detail.code ?? 0, "code_present": detail.code != nil,
          "domain": detail.diagnosticDomain.rawValue, "kind": detail.category.rawValue,
        ]
      }
      static func realMusicClient(isCurrent: @MainActor () -> Bool) async throws -> JellyfinClient {
        let support = FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("Jukebox", isDirectory: true)
        let directory = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard isCurrent(), directory.isDirectory == true, directory.isSymbolicLink != true,
          let connection = try JSONDecoder().decode(
            [Connection].self,
            from: realMusicRead(root.appendingPathComponent("connections.json"), maximum: 65_536)
          ).first,
          let device = String(
            data: try realMusicRead(root.appendingPathComponent("installation-id"), maximum: 128),
            encoding: .utf8),
          !device.isEmpty, device.count <= 128
        else { throw ClientError.invalidResponse }
        guard let token = try await KeychainVault().read(account: connection.id), isCurrent()
        else { throw ClientError.unauthorized }
        return try JellyfinClient(connection: connection, token: token, deviceID: device)
      }
      static func realMusicPair(
        client: JellyfinClient, secondDuration: ClosedRange<Double>,
        isCurrent: @MainActor () -> Bool
      ) async throws -> (MusicLibrary, MusicItem, MusicItem) {
        guard let library = try await client.musicLibraries(refresh: true).first else {
          throw PlaybackProblem.noSource
        }
        var first: MusicItem?
        var second: MusicItem?
        var offset = 0
        let selectionDeadline = Date().addingTimeInterval(60)
        for _ in 0..<8 {
          guard isCurrent(), Date() < selectionDeadline else { throw CancellationError() }
          let page = try await client.catalogPage(
            CatalogQuery(library: library.id, category: .songs, offset: offset))
          guard isCurrent() else { throw CancellationError() }
          for item in page.items where item.kind == "Audio" && item.duration.isFinite {
            if first == nil, (216.6...300).contains(item.duration) { first = item }
            if second?.id == first?.id { second = nil }
            if second == nil, secondDuration.contains(item.duration), item.id != first?.id {
              second = item
            }
          }
          if let first, let second, first.id != second.id { break }
          if page.rawCount == 0 { break }
          offset += page.rawCount
        }
        guard let first, let second, first.id != second.id else { throw PlaybackProblem.noSource }
        return (library, first, second)
      }
      private static func realMusicHigh(
        runID: UUID, nonce: UUID, deadline: Date, documents: URL, native: NativePlayer
      ) async {
        let scope = RealMusicScope(deadline: deadline.addingTimeInterval(-180))
        var evidence: [String: Any] = [
          "finished": false, "observation_complete": false, "normal_state_write_calls": 0,
          "keychain_write_calls": 0, "favorite_write_calls": 0, "normal_queue_loaded": false,
          "normal_history_loaded": false, "normal_preferences_loaded": false,
          "requested_min_duration_ms": 216_600, "requested_max_duration_ms": 300_000,
          "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown",
        ]
        var stage = "saved-account"
        defer {
          scope.live = false
          native.stop()
        }
        do {
          let client = try await realMusicClient(isCurrent: { scope.current() })
          stage = "identity"
          try await client.verifyIdentity()
          guard scope.current() else { throw CancellationError() }
          stage = "music-catalog"
          let (library, first, second) = try await realMusicPair(
            client: client, secondDuration: Double(25).nextUp...Double.greatestFiniteMagnitude,
            isCurrent: { scope.current() })
          evidence["music_only"] = true
          evidence["saved_account_path"] = true
          evidence["second_is_distinct"] = true
          stage = "first-native"
          let firstResult = await realMusicNative(
            client: client, library: library.id, item: first, native: native, scope: scope,
            quality: .high, full: true)
          for (key, value) in firstResult { evidence["first_" + key] = value }
          guard scope.current() else { throw CancellationError() }
          stage = "ordinary-download"
          do {
            let source = try await client.media(
              library: library.id, trackID: first.id, quality: .high, isCurrent: { scope.current() }
            )
            guard scope.current(), source.timeOrigin == 0, let duration = source.serverDuration,
              duration.isFinite, (216.6...300).contains(duration)
            else { throw ClientError.invalidResponse }
            let budget = min(330, scope.deadline.timeIntervalSinceNow - 5)
            guard budget >= 5 else { throw CancellationError() }
            let transport = LiveHTTP(maximumBytes: 8_388_608, resourceTimeout: budget)
            let start = ProcessInfo.processInfo.systemUptime
            let reply = try await transport.send(source.upstreamRequest)
            guard scope.current(), reply.status == 200, !reply.data.isEmpty else {
              throw ClientError.invalidResponse
            }
            let decoded = try AVAudioPlayer(data: reply.data)
            evidence["download_finished"] = true
            evidence["download_bytes"] = reply.data.count
            evidence["download_http"] = reply.status
            evidence["download_duration_ms"] = realMusicMS(decoded.duration)
            evidence["download_source_duration_ms"] = realMusicMS(duration)
            evidence["download_duration_matches"] =
              decoded.duration.isFinite && abs(decoded.duration - duration) <= 1
            evidence["download_elapsed_ms"] = realMusicMS(
              ProcessInfo.processInfo.systemUptime - start)
          } catch {
            evidence["download_finished"] = false
            for (key, value) in realMusicError(error) { evidence["download_" + key] = value }
          }
          guard scope.current() else { throw CancellationError() }
          stage = "second-native"
          let secondResult = await realMusicNative(
            client: client, library: library.id, item: second, native: native, scope: scope,
            quality: .high, full: false)
          for (key, value) in secondResult { evidence["second_" + key] = value }
          guard scope.current() else { throw CancellationError() }
          stage = "original-native"
          let originalResult = await realMusicNative(
            client: client, library: library.id, item: second, native: native, scope: scope,
            quality: .original, full: false)
          for (key, value) in originalResult { evidence["original_" + key] = value }
          guard scope.current() else { throw CancellationError() }
          stage = "data-saver-native"
          let dataSaverResult = await realMusicNative(
            client: client, library: library.id, item: second, native: native, scope: scope,
            quality: .compact, full: false)
          for (key, value) in dataSaverResult { evidence["data_saver_" + key] = value }
          evidence["observation_complete"] = true
        } catch {
          evidence["failure_stage"] = stage
          for (key, value) in realMusicError(error) { evidence["failure_" + key] = value }
        }
        native.stop()
        evidence["finished"] = true
        evidence["native_empty_after_stop"] = native.queueReadout.queued.isEmpty
        let report: [String: Any] = [
          "run_id": runID.uuidString, "scenario": "real-music-high",
          "version": 1, "nonce": nonce.uuidString, "evidence": evidence,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
          try? TransportControlFiles.publish(data, in: documents, runID: runID)
        }
      }
      private static func realMusicNative(
        client: JellyfinClient, library: String, item: MusicItem, native: NativePlayer,
        scope: RealMusicScope, quality: StreamQuality, full: Bool
      ) async -> [String: Any] {
        let previous = native.onEvent
        let previousRemote = native.onRemote
        let entry = QueueEntry(item, libraryID: library)
        var ends = 0
        var failures = 0
        var backward = 0
        var wrong = 0
        var last = 0.0
        var maximum = 0.0
        var firstProgress = -1
        var failure: ConnectionStepError?
        var observedTransfer: PlaybackTransferEvidence?
        var transferAt: Double?
        var transferOrigin = 0
        var previousSample: Double?
        var sampleCount = 0
        var largestSamplingGap = 0.0
        var pauseCount = 0
        var lastTimeControl = -1
        var lastWaiting = -1
        var stateAt: Double?
        var finalStateCurrent = false
        func retainTransfer(_ transfers: [PlaybackTransferEvidence], origin: Int, at now: Double) {
          guard
            let transfer = transfers.filter({ !$0.head }).max(by: {
              $0.delivered == $1.delivered ? $0.ordinal < $1.ordinal : $0.delivered < $1.delivered
            })
          else { return }
          if let previous = observedTransfer, transfer.ordinal != previous.ordinal,
            transfer.delivered < previous.delivered
              || (transfer.delivered == previous.delivered && transfer.ordinal < previous.ordinal)
          {
            return
          }
          observedTransfer = transfer
          transferAt = now
          transferOrigin = origin
        }
        func sample() {
          let now = ProcessInfo.processInfo.systemUptime
          sampleCount += 1
          if let previousSample {
            largestSamplingGap = max(largestSamplingGap, now - previousSample)
          }
          previousSample = now
          guard let observed = native.liveMusicReadout(for: entry.id) else {
            finalStateCurrent = false
            return
          }
          if observed.timeControl == 0, lastTimeControl != 0 { pauseCount += 1 }
          lastTimeControl = observed.timeControl
          lastWaiting = observed.waiting
          stateAt = now
          finalStateCurrent = true
          retainTransfer(observed.transfers, origin: 1, at: now)
        }
        var result: [String: Any] = [
          "started": false, "source_class": "unknown",
          "first_progress_includes_metadata": true, "requested_quality_bps": quality.bitrate,
        ]
        let started = ProcessInfo.processInfo.systemUptime
        var handoff: Double?
        let diagnostics = DiagnosticSession()
        let log = diagnostics.begin(.play, quality: DiagnosticQuality(quality))
        native.onRemote = nil
        native.onEvent = { event in
          guard scope.current() else { return }
          switch event {
          case .position(let id, let seconds):
            guard id == entry.id else {
              wrong += 1
              return
            }
            if seconds.isFinite {
              if seconds < last - 0.25 { backward += 1 }
              last = seconds
              maximum = max(maximum, seconds)
              if seconds > 0.15, firstProgress < 0 {
                firstProgress = realMusicMS(ProcessInfo.processInfo.systemUptime - started)
              }
            }
          case .finished(let id): if id == entry.id { ends += 1 } else { wrong += 1 }
          case .failureDetails(let id, let detail):
            if id == entry.id {
              failures += 1
              failure = detail
              retainTransfer(
                detail.playbackEvidence?.transfers ?? [], origin: 2,
                at: ProcessInfo.processInfo.systemUptime)
            } else {
              wrong += 1
            }
          case .failure: failures += 1
          case .advanced(let id): if id != entry.id { wrong += 1 }
          default: break
          }
        }
        defer {
          native.stop()
          log?.retire(.sourceRetired)
          native.onEvent = previous
          native.onRemote = previousRemote
        }
        do {
          let source = try await client.media(
            library: library, trackID: item.id, quality: quality, isCurrent: { scope.current() })
          guard scope.current(), source.timeOrigin == 0, let duration = source.serverDuration,
            duration.isFinite, duration > 25, !full || (216.6...300).contains(duration)
          else { throw ClientError.invalidResponse }
          result["source_duration_ms"] = realMusicMS(duration)
          result["quality_bps"] = source.quality.bitrate
          result["source_class"] = source.diagnosticSource.rawValue
          result["origin_ms"] = realMusicMS(source.timeOrigin)
          handoff = ProcessInfo.processInfo.systemUptime
          result["source_negotiation_ms"] = realMusicMS((handoff ?? started) - started)
          try await native.start(
            [PreparedEntry(entry: entry, source: source, diagnostic: log)], position: 0)
          result["started"] = true
          let cap = (handoff ?? started) + (full ? duration + 30 : 35)
          while scope.current(), ProcessInfo.processInfo.systemUptime < cap,
            ends == 0, failures == 0, full || maximum < 20
          {
            sample()
            let current = native.queueReadout
            if current.occurrence == entry.id, current.seconds.isFinite {
              maximum = max(maximum, current.seconds)
            }
            try await Task.sleep(for: .milliseconds(100))
          }
        } catch {
          failures += 1
          let detail = ConnectionStepError(step: .playbackAudio, error: error)
          failure = detail
          retainTransfer(
            detail.playbackEvidence?.transfers ?? [], origin: 2,
            at: ProcessInfo.processInfo.systemUptime)
        }
        sample()
        let observedAt = ProcessInfo.processInfo.systemUptime
        result["sample_count"] = sampleCount
        result["pause_count"] = pauseCount
        result["largest_sampling_gap_ms"] = realMusicMS(largestSamplingGap)
        result["final_time_control"] = lastTimeControl
        result["final_waiting_state"] = lastWaiting
        result["final_state_current"] = finalStateCurrent
        result["final_state_age_ms"] = stateAt.map { realMusicMS(observedAt - $0) } ?? -1
        result["first_progress_ms"] = firstProgress
        result["max_clock_ms"] = realMusicMS(maximum)
        result["last_clock_ms"] = realMusicMS(last)
        result["elapsed_ms"] = realMusicMS(ProcessInfo.processInfo.systemUptime - started)
        result["native_elapsed_ms"] =
          handoff.map { realMusicMS(ProcessInfo.processInfo.systemUptime - $0) } ?? -1
        result["end_count"] = ends
        result["failure_count"] = failures
        result["backward_count"] = backward
        result["wrong_item_count"] = wrong
        result["muted"] = native.safeStatus["muted"] as? Bool == true
        if let failure {
          result["failure_kind"] = failure.category.rawValue
          result["failure_code_present"] = failure.code != nil
          result["failure_code"] = failure.code ?? 0
          result["failure_domain"] = failure.diagnosticDomain.rawValue
        }
        if let transfer = observedTransfer {
          result["bridge_request_ordinal"] = transfer.ordinal
          result["bridge_snapshot_origin"] = transferOrigin
          result["bridge_snapshot_age_ms"] = transferAt.map { realMusicMS(observedAt - $0) } ?? -1
          result["bridge_received_bytes"] = transfer.received
          result["bridge_delivered_bytes"] = transfer.delivered
          result["bridge_expected_bytes"] = transfer.expected ?? -1
          result["bridge_http"] = transfer.status ?? 0
          result["bridge_code_present"] = transfer.code != nil
          result["bridge_code"] = transfer.code?.value ?? 0
          result["bridge_domain"] = transfer.code?.domain.rawValue ?? "unknown"
          result["bridge_terminal"] = transfer.state.rawValue
          result["bridge_recovery"] = transfer.recovery.rawValue
          if let received = transfer.taskReceived {
            result["bridge_task_received_bytes"] = received
          }
          if let wait = transfer.longestPlayerWait, wait.isFinite {
            result["bridge_max_player_wait_ms"] = realMusicMS(wait)
          }
          if let timedOut = transfer.inputTimedOut { result["bridge_input_timeout"] = timedOut }
        }
        return result
      }
    #endif
    private static func originalStartup(
      runID: UUID, variant: String, server: ServerAddress, native: NativePlayer,
      phase: TransportControlPhase
    ) async throws -> [String: Any] {
      let previous = native.onEvent
      var failureCode = 0
      var ended = false
      let entry = QueueEntry(
        MusicItem(
          id: "fixture-track-0", title: "Invented FLAC", artist: "Invented artist",
          album: "Invented album", duration: 8, number: 1, kind: "Audio", imageID: nil,
          imageTag: nil), libraryID: "fixture-music")
      native.onEvent = { event in
        guard phase.current() else { return }
        switch event {
        case .failureDetails(let id, let detail) where id == entry.id:
          failureCode = detail.code ?? -1
        case .failure: failureCode = -1
        case .finished(let id) where id == entry.id: ended = true
        default: break
        }
      }
      defer {
        native.stop()
        native.onEvent = previous
      }
      let precise = variant == "precise"
      let source = MediaSource(
        url: try server.endpoint("Audio/fixture-track-0/stream"),
        quality: .original, preferPreciseTiming: precise,
        authorization: "MediaBrowser Token=\"invented-transport-token\"")
      let started = ContinuousClock.now
      let deadline = started.advanced(by: .seconds(65))
      do {
        try phase.perform {}
        try await native.start([PreparedEntry(entry: entry, source: source)], position: 0)
      } catch {
        try phase.perform {}
        failureCode = (error as? ConnectionStepError)?.code ?? numeric(error)
      }
      while true {
        try phase.perform {}
        let current = native.queueReadout
        if failureCode != 0 || ended
          || (current.occurrence == entry.id && current.ready == [entry.id]
            && current.seconds.isFinite && current.seconds > 0.2)
          || ContinuousClock.now >= deadline
        {
          break
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      return try phase.perform {
        func milliseconds(_ seconds: Double) -> Int {
          guard seconds.isFinite, seconds >= 0, seconds <= 65 else { return -1 }
          return Int((seconds * 1000).rounded())
        }
        let current = native.queueReadout
        let elapsed = started.duration(to: .now).components
        return [
          "run_id": runID.uuidString, "scenario": "original-startup", "control_version": 5,
          "variant": variant, "finished": true, "native_code": failureCode,
          "ended": ended, "initial_position_ms": 0,
          "startup_ms": Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000),
          "clock_ms": milliseconds(current.seconds),
          "absolute_ms": milliseconds(current.absoluteSeconds),
          "origin_ms": milliseconds(current.timeOrigin),
          "current_matches": current.occurrence == entry.id,
          "ready_items": current.ready.count, "queue_items": current.queued.count,
          "item_status": current.itemStatuses.count == 1 ? current.itemStatuses[0] : -1,
          "preparing": current.preparing, "seeking": current.seeking,
          "muted": native.safeStatus["muted"] as? Bool == true,
          "allows_external": native.safeStatus["allows_external"] as? Bool == true,
          "precise": precise,
        ]
      }
    }
    private static func localGate(
      _ scenario: String, runID: UUID, nonce: UUID, documents: URL,
      store: PlayerStore, native: NativePlayer, fixture: FixtureCatalog
    ) async {
      defer { native.stop() }
      await store.enterFixture(service: fixture)
      let publish: ([String: Any]) -> Void = { evidence in
        let report: [String: Any] = [
          "run_id": runID.uuidString, "scenario": scenario, "version": 1,
          "nonce": nonce.uuidString, "evidence": evidence,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
          try? TransportControlFiles.publish(data, in: documents, runID: runID)
        }
      }
      if scenario == "session" {
        await DevelopmentAcceptance.runSessionEvents(
          store: store, native: native, runID: runID, publish: publish)
      } else {
        await DevelopmentAcceptance.runArtworkCheck(
          store: store, native: native, runID: runID, publish: publish)
      }
    }
    private static func playerWitness(
      store: PlayerStore, native: NativePlayer, server: ServerAddress, phase: TransportControlPhase,
      selection: PlaybackSelection, owner: inout PlayerStore.TransportAcceptanceLease
    ) async throws -> [String: Bool] {
      func wait(_ lease: PlayerStore.TransportAcceptanceLease, _ predicate: () -> Bool) async throws
      {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
          let accepted = try phase.perform {
            guard store.ownsTransportAcceptance(lease) else { throw CancellationError() }
            return predicate()
          }
          if accepted { return }
          guard ContinuousClock.now < deadline else { throw ClientError.unavailable }
          try await Task.sleep(for: .milliseconds(25))
        }
      }
      try phase.perform {}
      owner = try store.performTransportAcceptance(.play(selection), owned: owner)
      let initial = try phase.perform { store.current?.id }
      try await wait(owner) {
        native.queueReadout.occurrence == initial && native.queueReadout.seconds > 0.25
          && store.playing
      }
      let control = TransportControlHTTP(phase: phase)
      let held = try await control.send(URLRequest(url: try server.endpoint("witness/status")))
      let open = try phase.perform {
        (try JSONSerialization.jsonObject(with: held.data) as? [String: Bool])?["held_open"] == true
      }
      guard open else { throw ClientError.invalidResponse }
      try phase.perform {}
      owner = try store.performTransportAcceptance(.next, owned: owner)
      let replacement = try phase.perform { store.current?.id }
      guard replacement != nil, replacement != initial else { throw ClientError.invalidResponse }
      try await wait(owner) {
        native.queueReadout.occurrence == replacement && native.queueReadout.seconds > 0.25
          && store.playing && store.error == nil
      }
      let before = try phase.perform { native.queueReadout.seconds }
      try await Task.sleep(for: .seconds(3.3))
      let remains = try phase.perform {
        guard store.ownsTransportAcceptance(owner) else { throw CancellationError() }
        return native.queueReadout.occurrence == replacement && store.current?.id == replacement
          && native.queueReadout.seconds > before && store.playing && store.error == nil
      }
      guard remains else { throw ClientError.invalidResponse }
      try phase.perform {}
      owner = try store.performTransportAcceptance(.pause, owned: owner)
      return [
        "current_native_advanced": true, "successor_preparing": true,
        "replacement_while_server_held": open, "latest_native_advanced": true,
        "replacement_continues_beyond_nominal_hold": remains,
        "paused_at_end": try phase.perform { !store.playbackRequested },
      ]
    }
    private static func snapshot(_ phase: TransportControlPhase) throws -> [String: Any] {
      guard let snapshot = phase.snapshot(),
        let value = try JSONSerialization.jsonObject(with: Data(snapshot.text.utf8))
          as? [String: Any]
      else { throw CancellationError() }
      return value
    }
    private static func prepare(_ client: JellyfinClient, index: Int, phase: TransportControlPhase)
      async -> Int
    {
      guard phase.current() else { return -999 }
      return await TransportCapture.$caller.withValue(phase.context) {
        do {
          let source = try await client.media(
            library: "fixture-music", trackID: "fixture-track-\(index % 2)",
            quality: index % 2 == 0 ? .original : .high, isCurrent: { phase.current() })
          return try phase.perform { source.url.scheme == "http" ? 0 : -2 }
        } catch { return (try? phase.perform { numeric(error) }) ?? -999 }
      }
    }
    private static func code(_ transport: any HTTPTransport, url: URL, phase: TransportControlPhase)
      async -> Int
    {
      guard phase.current() else { return -999 }
      return await TransportCapture.$caller.withValue(phase.context) {
        do {
          let reply = try await transport.send(URLRequest(url: url))
          return try phase.perform { reply.status }
        } catch { return (try? phase.perform { numeric(error) }) ?? -999 }
      }
    }
    private static func numeric(_ error: Error) -> Int {
      if let error = error as? URLError { return error.errorCode }
      return -1
    }
  }

#endif
