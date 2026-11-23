#if DEBUG
  import AVFoundation
  import CryptoKit
  import Foundation
  import MediaPlayer
  import UIKit

  extension DevelopmentAcceptance {
    static var qualitySnapshot: [String: Any] = [:]
    static func qualityTransitions(
      store: PlayerStore, native: NativePlayer, selection: PlaybackSelection
    ) async throws
      -> [[String: Any]]
    {
      qualitySnapshot = [:]
      var results: [[String: Any]] = []
      var settleSeconds: [String: Double] = [:]
      func snapshot(_ name: String, id: UUID?) -> [String: Any] {
        let r = native.queueReadout
        func number(_ x: Double) -> Double { x.isFinite ? x : -1 }
        return [
          "case": name, "settle_seconds": settleSeconds[name] ?? -1,
          "model_clock": number(store.queue.position),
          "item_clock": number(r.seconds), "player_clock": number(r.playerSeconds),
          "native_duration": number(r.duration), "absolute_clock": number(r.absoluteSeconds),
          "source_origin": r.timeOrigin, "phase": store.phase.rawValue,
          "preparing": r.preparing, "seeking": r.seeking,
          "time_control": r.timeControlStatus, "item_statuses": r.itemStatuses,
          "item_errors": r.itemErrors, "same_occurrence": store.current?.id == id,
          "playing_intent": store.playbackRequested,
          "now_playing_clock":
            (MPNowPlayingInfoCenter.default().nowPlayingInfo?[
              MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) ?? -1,
        ]
      }
      func wait(_ name: String, id: UUID?, seconds: Double = 12, _ condition: () -> Bool)
        async throws
      {
        let began = ProcessInfo.processInfo.systemUptime
        let end = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < end {
          if condition() {
            settleSeconds[name] = ProcessInfo.processInfo.systemUptime - began
            return
          }
          if store.phase == .failed { break }
          try await Task.sleep(for: .milliseconds(25))
        }
        qualitySnapshot = snapshot(name, id: id)
        throw CheckFailure(step: name)
      }
      store.quality(.original)
      store.playSelection(selection)
      let first = store.current?.id
      try await wait("long-original-start", id: first) {
        store.playing && store.queue.position > 0.5
      }
      store.seek(76)
      try await wait("long-original-seek", id: first) {
        store.playing && store.queue.position > 76.1
      }
      let before = store.queue.position
      store.quality(.high)
      try await wait("playing-original-to-high", id: first) {
        store.playing && store.current?.id == first && store.queue.position >= before - 0.05
      }
      results.append(snapshot("playing-original-to-high", id: first))
      store.pause()
      store.quality(.original)
      store.seek(40)
      store.quality(.high)
      guard !store.playbackRequested && store.phase == .paused else {
        throw CheckFailure(step: "paused-quality-autoplay")
      }
      store.play()
      try await wait("paused-high-explicit-play", id: first) {
        store.playing && store.queue.position >= 40.1
      }
      results.append(snapshot("paused-high-explicit-play", id: first))
      store.playSelection(selection)
      try await wait("fresh-high-start", id: nil) { store.playing && store.queue.position > 0.5 }
      let direct = store.current?.id
      results.append(snapshot("fresh-high-start", id: direct))
      store.next()
      let second = store.current?.id
      try await wait("high-next-start", id: second) { store.playing && store.queue.position > 0.3 }
      store.previous()
      try await wait("high-previous-start", id: direct) {
        store.playing && store.current?.id == direct && store.queue.position > 0.3
      }
      results.append(snapshot("high-next-previous", id: direct))
      store.seek(76)
      try await wait("high-forward-seek", id: direct) {
        store.playing && !native.queueReadout.preparing && !native.queueReadout.seeking
          && native.queueReadout.absoluteSeconds >= 76.1 && store.queue.position >= 76.1
      }
      results.append(snapshot("high-forward-seek", id: direct))
      store.seek(20)
      try await wait("high-backward-seek", id: direct) {
        store.playing && !native.queueReadout.preparing && !native.queueReadout.seeking
          && native.queueReadout.absoluteSeconds >= 20 && native.queueReadout.absoluteSeconds < 22
          && store.queue.position >= 20 && store.queue.position < 22
      }
      results.append(snapshot("high-backward-seek", id: direct))
      store.seek(76)
      store.seek(20)
      store.seek(40)
      try await wait("latest-high-seek", id: direct) {
        store.playing && !native.queueReadout.preparing
          && native.queueReadout.timeOrigin == 40 && native.queueReadout.absoluteSeconds > 40.1
      }
      results.append(snapshot("latest-high-seek", id: direct))
      store.seek(90.56)
      try await wait("offset-tail-natural-handoff", id: second, seconds: 5) {
        store.playing && store.current?.id == second && store.queue.position > 0.1
          && store.queue.position < 2 && native.queueReadout.timeOrigin == 0
      }
      results.append(snapshot("offset-tail-natural-handoff", id: second))
      for record in results {
        guard record["same_occurrence"] as? Bool == true,
          let model = record["model_clock"] as? Double,
          let clock = record["absolute_clock"] as? Double,
          let published = record["now_playing_clock"] as? Double,
          abs(model - clock) < 0.3, abs(published - clock) < 0.3
        else { throw CheckFailure(step: "absolute-position-publication-mismatch") }
      }
      store.pause()
      return results
    }
    static func selectedQualityNearEnd(
      store: PlayerStore, native: NativePlayer, selection: PlaybackSelection
    ) async throws
      -> [[String: Any]]
    {
      var results: [[String: Any]] = []
      for quality in [StreamQuality.high, .compact] {
        store.quality(quality)
        store.playSelection(selection)
        let start = ProcessInfo.processInfo.systemUptime
        while store.queue.position < 0.3 && ProcessInfo.processInfo.systemUptime - start < 8 {
          try await Task.sleep(for: .milliseconds(20))
        }
        guard store.queue.index == 0, store.queue.position >= 0.3, let first = store.current?.id
        else {
          throw CheckFailure(step: "selected-near-end-start")
        }
        let durationBefore = native.queueReadout.duration
        let estimatedBefore = store.durationIsEstimated
        store.seek(7.25)
        let requestedAt = ProcessInfo.processInfo.systemUptime
        var actual: Double?
        var maximum = 0.0
        var handedOff = false
        while ProcessInfo.processInfo.systemUptime - requestedAt < 5 {
          let state = native.queueReadout
          if state.occurrence == first && !state.seeking && !state.preparing
            && state.absoluteSeconds >= 7.25
          {
            if actual == nil { actual = state.absoluteSeconds }
            if state.absoluteSeconds.isFinite { maximum = max(maximum, state.absoluteSeconds) }
          }
          if store.queue.index == 1 && store.queue.position > 0.1 {
            handedOff = true
            break
          }
          if store.phase == .failed { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        results.append([
          "quality": quality.rawValue, "requested_seek": 7.25,
          "actual_clock_after_completed_seek": actual ?? -1, "maximum_first_clock": maximum,
          "native_duration_before_seek": durationBefore.isFinite ? durationBefore : -1,
          "display_estimated_before_seek": estimatedBefore, "handed_off": handedOff,
          "seconds_to_handoff": ProcessInfo.processInfo.systemUptime - requestedAt,
          "end_state": [
            "absolute_clock": native.queueReadout.absoluteSeconds.isFinite
              ? native.queueReadout.absoluteSeconds : -1,
            "raw_clock": native.queueReadout.seconds.isFinite ? native.queueReadout.seconds : -1,
            "origin": native.queueReadout.timeOrigin, "preparing": native.queueReadout.preparing,
            "loaded_end": native.queueReadout.loadedEnd,
            "phase": store.phase.rawValue, "item_statuses": native.queueReadout.itemStatuses,
            "item_errors": native.queueReadout.itemErrors,
          ],
        ])
        store.pause()
      }
      return results
    }
    static func localTailControl(
      store: PlayerStore, native: NativePlayer, vault: any TokenVault, selection: PlaybackSelection
    ) async throws -> [[String: Any]] {
      guard let account = store.active, selection.items.count == 2,
        let token = try await vault.read(account: account.id)
      else { throw CheckFailure(step: "local-tail-fixture-login") }
      let api = try JellyfinClient(connection: account, token: token, deviceID: "invented-tail")
      var results: [[String: Any]] = []
      for quality in [StreamQuality.high, .compact] {
        let source = try await api.media(
          library: selection.origin.library, trackID: selection.items[0].id, quality: quality,
          isCurrent: {
            store.active?.id == account.id
              && store.playbackOrigin(library: selection.origin.library) == selection.origin
          }
        ).starting(
          at: 7.25)
        let response = try await LiveHTTP().send(source.upstreamRequest)
        guard response.status == 200, response.data.count < 500_000 else {
          throw CheckFailure(step: "local-tail-bounded-response")
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString + ".mp3")
        try response.data.write(
          to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: path) }
        let first = QueueEntry(selection.items[0])
        let second = QueueEntry(selection.items[1])
        let next = try await api.media(
          library: selection.origin.library, trackID: selection.items[1].id, quality: quality,
          isCurrent: {
            store.active?.id == account.id
              && store.playbackOrigin(library: selection.origin.library) == selection.origin
          })
        let started = ProcessInfo.processInfo.systemUptime
        let start = Task {
          try await native.start(
            [
              PreparedEntry(
                entry: first,
                source: MediaSource(url: path, quality: quality, timeOrigin: source.timeOrigin)),
              PreparedEntry(entry: second, source: next),
            ], position: 7.25)
        }
        var actual: Double?
        var handedOff = false
        while ProcessInfo.processInfo.systemUptime - started < 5 {
          let state = native.queueReadout
          if state.occurrence == first.id, !state.preparing, state.absoluteSeconds >= 7.25 {
            if actual == nil { actual = state.absoluteSeconds }
          }
          if state.occurrence == second.id, state.seconds > 0.1 {
            handedOff = true
            break
          }
          try await Task.sleep(for: .milliseconds(20))
        }
        results.append([
          "quality": quality.rawValue, "actual_clock_after_completed_seek": actual ?? -1,
          "handed_off": handedOff,
          "seconds_to_handoff": ProcessInfo.processInfo.systemUptime - started,
          "bytes": response.data.count, "source_origin": source.timeOrigin,
          "final_raw_clock": native.queueReadout.seconds.isFinite
            ? native.queueReadout.seconds : -1,
        ])
        native.stop()
        start.cancel()
        _ = try? await start.value
        try? FileManager.default.removeItem(at: path)
      }
      return results
    }
    static func tailLifetime(native: NativePlayer, address: URL) async throws -> [String: Any] {
      var result: [String: Any] = [:]
      let disk = try NativePlayer.tailStorageCheck()
      guard
        disk.filter({ !["protected", "protection_attribute_present"].contains($0.key) }).values
          .allSatisfy({ $0 })
      else {
        throw CheckFailure(
          step: "tail-disk-policy-" + disk.filter { !$0.value }.keys.sorted().joined(separator: "-")
        )
      }
      result["disk_policy"] = disk
      func source(_ path: String) -> MediaSource {
        MediaSource(
          url: address.appendingPathComponent(path), quality: .high,
          serverTimeSeek: true, timeOrigin: 3, maximumTimeOrigin: 3, serverDuration: 8)
      }
      func wait(_ name: String, _ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(6))
        while ContinuousClock.now < end {
          if condition() { return }
          try await Task.sleep(for: .milliseconds(25))
        }
        throw CheckFailure(step: name)
      }
      let first = QueueEntry(MusicItem.fixtureTracks[0])
      let next = QueueEntry(MusicItem.fixtureTracks[1])
      try await native.start(
        [PreparedEntry(entry: first, source: source("tone.mp3"))], position: 7.25)
      try await wait(
        "tail-published", { !native.queueReadout.preparing && native.tailFileCount == 1 })
      native.pause()
      guard native.tailFileCount == 1 else {
        throw CheckFailure(step: "paused-file-retired-too-early")
      }
      native.stop()
      guard native.tailFileCount == 0 else { throw CheckFailure(step: "stop-tail-leak") }
      result["paused_native_use_then_stop_cleanup"] = true
      try await native.start(
        [
          PreparedEntry(entry: first, source: source("tone.mp3")),
          PreparedEntry(
            entry: next,
            source: MediaSource(url: address.appendingPathComponent("tone.mp3"), quality: .high)),
        ], position: 7.25)
      try await wait(
        "natural-tail-retirement",
        { native.queueReadout.occurrence == next.id && native.tailFileCount == 0 })
      native.stop()
      result["natural_handoff_cleanup"] = true
      for path in ["large", "redirect"] {
        var rejected = false
        do {
          try await native.start(
            [PreparedEntry(entry: first, source: source(path))], position: 7.25)
        } catch { rejected = true }
        guard rejected, native.tailFileCount == 0 else {
          throw CheckFailure(step: "tail-limit-or-redirect")
        }
      }
      result["byte_limit_and_redirect_rejected_without_files"] = true
      let old = Task {
        try await native.start(
          [PreparedEntry(entry: first, source: source("delayed"))], position: 7.25)
      }
      try await Task.sleep(for: .milliseconds(200))
      native.pause()
      try await native.start(
        [
          PreparedEntry(
            entry: next,
            source: MediaSource(url: address.appendingPathComponent("tone.mp3"), quality: .high))
        ], position: 0)
      _ = try await LiveHTTP().send(URLRequest(url: address.appendingPathComponent("release")))
      _ = try? await old.value
      guard native.queueReadout.occurrence == next.id, native.tailFileCount == 0 else {
        throw CheckFailure(step: "late-tail-replaced-new-source")
      }
      native.stop()
      result["canceled_late_reply_cannot_replace_or_retain_file"] = true
      var timeout = false
      do {
        _ = try await LiveHTTP(maximumBytes: 500_000, resourceTimeout: 0.5).send(
          URLRequest(url: address.appendingPathComponent("slow")))
      } catch { timeout = true }
      guard timeout else { throw CheckFailure(step: "tail-timeout-not-enforced") }
      result["transport_resource_deadline"] = true
      return result
    }
  }
#endif
