#if DEBUG
  import AVFoundation
  import CryptoKit
  import Foundation
  import MediaPlayer
  import UIKit

  extension DevelopmentAcceptance {
    static var recoverySnapshot: [String: Any] = [:]
    actor DelayedSuccessor: MusicCatalogServing {
      let api: any MusicCatalogServing
      private var calls = 0
      init(api: any MusicCatalogServing) { self.api = api }
      func verifyIdentity() async throws { try await api.verifyIdentity() }
      func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
        try await api.musicLibraries(refresh: refresh)
      }
      func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
        try await api.catalog(query)
      }
      func albumTracks(library: String, album: String) async throws -> [MusicItem] {
        try await api.albumTracks(library: library, album: album)
      }
      func albumDetail(library: String, album: MusicItem) async throws -> MusicAlbumPage {
        try await api.albumDetail(library: library, album: album)
      }
      func artistDetail(library: String, artist: MusicItem) async throws -> MusicItem {
        try await api.artistDetail(library: library, artist: artist)
      }
      func validate(ids: [String]) async throws -> [MusicItem] { try await api.validate(ids: ids) }
      func artwork(item: MusicItem) async throws -> Data? { try await api.artwork(item: item) }
      func media(
        library: String, trackID: String, quality: StreamQuality,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
      ) async throws -> MediaSource {
        calls += 1
        if calls == 2 { try await Task.sleep(for: .seconds(10)) }
        return try await api.media(
          library: library, trackID: trackID, quality: quality, isCurrent: isCurrent)
      }
    }
    static func transitions(
      store: PlayerStore, native: NativePlayer, quality: StreamQuality, selection: PlaybackSelection
    )
      async throws -> [String: Any]
    {
      store.quality(quality)
      store.playSelection(selection)
      let started = ProcessInfo.processInfo.systemUptime
      var startup: Double?
      var order: [Int] = []
      var enqueueHeadroom: [Int: Double] = [:]
      var readyHeadroom: [Int: Double] = [:]
      var futureStatuses: [Int: Set<Int>] = [:]
      var waits = 0
      var indefiniteDurationSamples = 0
      var transitionIntervals: [Double] = []
      var lastSample = started
      var lastIndex = -1
      while ProcessInfo.processInfo.systemUptime - started < 24 {
        let now = ProcessInfo.processInfo.systemUptime
        let state = native.queueReadout
        if let occurrence = state.occurrence,
          let index = store.queue.entries.firstIndex(where: { $0.id == occurrence })
        {
          if order.last != index {
            if !order.isEmpty { transitionIntervals.append(now - lastSample) }
            order.append(index)
          }
          if index == 0 && state.seconds > 0.02 && startup == nil { startup = now - started }
          if index + 1 < store.queue.entries.count {
            let next = store.queue.entries[index + 1].id
            if state.itemStatuses.count > 1 {
              futureStatuses[index, default: []].insert(state.itemStatuses[1])
            }
            if !state.duration.isFinite { indefiniteDurationSamples += 1 }
            let remaining = store.queue.entries[index].track.duration - state.seconds
            if remaining.isFinite {
              if state.queued.contains(next) && enqueueHeadroom[index] == nil {
                enqueueHeadroom[index] = remaining
              }
              if state.ready.contains(next) && readyHeadroom[index] == nil {
                readyHeadroom[index] = remaining
              }
            }
          }
          if startup != nil && state.waiting && store.playbackRequested { waits += 1 }
          if index == lastIndex { lastSample = now }
          lastIndex = index
        }
        if store.phase == .failed || (!store.playbackRequested && startup != nil) { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      let expected = Array(store.queue.entries.indices)
      let enqueued = expected.dropLast().map { enqueueHeadroom[$0] ?? -1 }
      let ready = expected.dropLast().map { readyHeadroom[$0] ?? -1 }
      let complete = store.phase == .paused && !store.playbackRequested
      let gate =
        (startup ?? 99) <= 5 && order == expected && complete && waits == 0
        && enqueued.allSatisfy { $0 >= 0.5 } && ready.allSatisfy { $0 >= 0.5 }
      let result: [String: Any] = [
        "quality": quality.rawValue, "startup_seconds": startup ?? -1,
        "observed_order": order, "enqueue_headroom_seconds": enqueued,
        "ready_headroom_seconds": ready, "headroom_basis": "known-invented-source-duration",
        "future_statuses_before_current": expected.dropLast().map {
          (futureStatuses[$0] ?? []).sorted()
        },
        "indefinite_native_duration_samples": indefiniteDurationSamples,
        "waiting_samples_after_start": waits,
        "transition_observation_intervals_seconds": transitionIntervals,
        "completed": complete, "engineering_gate": gate,
        "retained_queue_count": store.queue.entries.count,
        "retry_required_at_end": store.phase == .failed && !store.playbackRequested,
        "native_configuration": native.safeStatus,
      ]
      store.pause()
      return result
    }
    private struct ReadinessCatalog: MusicCatalogServing {
      let root: URL
      let durations = [144137.0, 158731.0, 120055.0].map { $0 / 48000 }
      var items: [MusicItem] {
        durations.enumerated().map {
          MusicItem(
            id: "readiness-\($0.offset)", title: "Invented part \($0.offset)",
            artist: "Fixture", album: "Fixture", duration: $0.element, number: $0.offset + 1,
            kind: "Audio", imageID: nil, imageTag: nil)
        }
      }
      func verifyIdentity() async throws {}
      func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
        [MusicLibrary(id: "fixture-music", title: "Invented")]
      }
      func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
        guard query.library == "fixture-music" else { throw ClientError.forbidden }
        return query.category == .albums && query.offset == 0 ? [.fixtureAlbum] : []
      }
      func albumTracks(library: String, album: String) async throws -> [MusicItem] {
        guard library == "fixture-music" else { throw ClientError.forbidden }
        return items
      }
      func validate(ids: [String]) async throws -> [MusicItem] {
        items.filter { ids.contains($0.id) }
      }
      func artwork(item: MusicItem) async throws -> Data? { nil }
      func media(
        library: String, trackID: String, quality: StreamQuality,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
      ) async throws -> MediaSource {
        try Task.checkCancellation()
        guard await isCurrent() else { throw CancellationError() }
        try Task.checkCancellation()
        guard library == "fixture-music" else { throw ClientError.forbidden }

        guard let index = items.firstIndex(where: { $0.id == trackID }) else {
          throw ClientError.forbidden
        }
        return MediaSource(url: root.appendingPathComponent("\(index).mp3"), quality: quality)
      }
    }
    static func readinessControls(store: PlayerStore, native: NativePlayer, address: URL)
      async throws -> [[String: Any]]
    {
      let files = FileManager.default
      let root = files.temporaryDirectory.appendingPathComponent("readiness-" + UUID().uuidString)
      try files.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? files.removeItem(at: root) }
      var playable = true
      for index in 0..<3 {
        let (data, response) = try await URLSession.shared.data(
          from: address.appendingPathComponent("range/\(index).mp3"))
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty, data.count < 200000
        else {
          throw CheckFailure(step: "readiness-completed-positive-control")
        }
        let local = root.appendingPathComponent("\(index).mp3")
        try data.write(to: local)
        let canPlay = try await AVURLAsset(url: local).load(.isPlayable)
        playable = playable && canPlay
      }
      guard playable else { throw CheckFailure(step: "readiness-local-not-playable") }
      var cases: [[String: Any]] = []
      for mode in ["range", "progressive", "local"] {
        let source = mode == "local" ? root : address.appendingPathComponent(mode)
        await store.enterFixture(service: ReadinessCatalog(root: source))
        let selection = try await fixtureAlbumSelection(store: store)
        var result = try await transitions(
          store: store, native: native, quality: .high, selection: selection)
        result["transport"] = mode
        result["local_assets_playable"] = playable
        cases.append(result)
        await store.logout()
      }
      return cases
    }
    private struct RecoveryCatalog: MusicCatalogServing {
      let base: URL
      var track: MusicItem {
        MusicItem(
          id: "recovery-tone", title: "Invented recovery", artist: "Fixture", album: "Fixture",
          duration: 120, number: 1, kind: "Audio", imageID: nil, imageTag: nil)
      }
      func verifyIdentity() async throws {}
      func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
        [MusicLibrary(id: "fixture-music", title: "Invented")]
      }
      func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
        guard query.library == "fixture-music" else { throw ClientError.forbidden }
        return query.category == .albums && query.offset == 0 ? [.fixtureAlbum] : []
      }
      func albumTracks(library: String, album: String) async throws -> [MusicItem] {
        guard library == "fixture-music" else { throw ClientError.forbidden }
        return [track]
      }
      func validate(ids: [String]) async throws -> [MusicItem] {
        ids.contains(track.id) ? [track] : []
      }
      func artwork(item: MusicItem) async throws -> Data? { nil }
      func media(
        library: String, trackID: String, quality: StreamQuality,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
      ) async throws -> MediaSource {
        try Task.checkCancellation()
        guard await isCurrent() else { throw CancellationError() }
        try Task.checkCancellation()
        guard library == "fixture-music" else { throw ClientError.forbidden }

        return MediaSource(url: base.appendingPathComponent("tone.mp3"), quality: quality)
      }
    }
    static func recovery(store: PlayerStore, native: NativePlayer, address: URL) async throws
      -> [String: Any]
    {
      func wait(_ step: String, seconds: Double, _ condition: () -> Bool) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < seconds {
          if condition() { return }
          try await Task.sleep(for: .milliseconds(50))
        }
        let observed = native.queueReadout
        recoverySnapshot["wait_step"] = step
        recoverySnapshot["wait_model_clock"] = store.queue.position
        recoverySnapshot["wait_native_clock"] =
          observed.absoluteSeconds.isFinite ? observed.absoluteSeconds : -1
        recoverySnapshot["wait_native_seeking"] = observed.seeking
        recoverySnapshot["wait_phase"] = store.phase.rawValue
        throw CheckFailure(step: step)
      }
      recoverySnapshot = [:]
      await store.enterFixture(service: RecoveryCatalog(base: address))
      guard store.isFixture else { throw CheckFailure(step: "recovery-fixture-admission") }
      try native.requireIntegrationTailStorage()
      let selection = try await fixtureAlbumSelection(store: store)
      store.playSelection(selection)
      try await wait("truncated-stream-start", seconds: 10) { store.queue.position > 0.5 }
      let occurrence = store.current?.id
      try await wait("native-did-not-enter-buffering", seconds: 16) { native.queueReadout.waiting }
      try await Task.sleep(for: .milliseconds(350))
      let waitingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
      let waitingRate = (waitingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?
        .doubleValue
      recoverySnapshot = [
        "waiting_rate": waitingRate ?? -1,
        "waiting_time_control": native.queueReadout.timeControlStatus,
        "waiting_phase": store.phase.rawValue,
        "waiting_clock": store.queue.position,
        "waiting_info_present": waitingInfo != nil,
      ]
      guard waitingRate == 0 else { throw CheckFailure(step: "buffering-lock-clock-not-frozen") }
      try await wait("buffering-deadline-not-enforced", seconds: 32) { store.phase == .failed }
      let stalled = store.queue.position
      guard stalled > 0.5 && !store.playbackRequested else {
        throw CheckFailure(step: "stall-not-paused")
      }
      let (_, response) = try await URLSession.shared.data(
        from: address.appendingPathComponent("recover"))
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw CheckFailure(step: "fixture-recover")
      }
      try await Task.sleep(for: .seconds(1))
      guard store.phase == .failed && store.current?.id == occurrence,
        abs(store.queue.position - stalled) < 0.05
      else { throw CheckFailure(step: "reconnection-autoplay-or-clock-jump") }
      store.play()
      var minimum = Double.infinity
      let retryStart = ProcessInfo.processInfo.systemUptime
      while ProcessInfo.processInfo.systemUptime - retryStart < 8 {
        minimum = min(minimum, store.queue.position)
        if store.playing && store.queue.position > stalled + 0.25 { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      let observed = native.queueReadout
      recoverySnapshot = [
        "stalled": stalled, "minimum_retry_model": minimum,
        "final_model": store.queue.position, "native_clock": observed.seconds,
        "native_duration": observed.duration.isFinite ? observed.duration : -1,
        "same_occurrence": store.current?.id == occurrence,
        "phase": store.phase.rawValue,
      ]
      guard minimum >= stalled - 0.05, store.queue.position > stalled + 0.25,
        store.current?.id == occurrence
      else { throw CheckFailure(step: "retry-position-or-occurrence-changed") }
      let resumedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
      let resumedRate = (resumedInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?
        .doubleValue
      let resumedClock = (resumedInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?
        .doubleValue
      guard resumedRate == 1, let resumedClock, let anchor = native.lastNowPlayingProjection,
        anchor.rate == 1, abs(anchor.clock - resumedClock) < 0.001
      else {
        throw CheckFailure(step: "retry-lock-clock-not-reanchored")
      }
      let projected = anchor.clock + max(0, ProcessInfo.processInfo.systemUptime - anchor.uptime)
      guard abs(projected - native.queueReadout.absoluteSeconds) < 0.35 else {
        throw CheckFailure(step: "retry-lock-clock-projection-drift")
      }
      let acceptedBeforeSeek = store.queue.position
      store.seek(50)
      store.seek(20)
      let pendingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
      guard store.playbackPosition == 20, store.queue.position == acceptedBeforeSeek,
        (pendingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue == 20,
        (pendingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 0
      else { throw CheckFailure(step: "pending-seek-app-and-os-clock-disagree") }
      try await wait("latest-seek-not-applied", seconds: 6) {
        let actual = native.queueReadout
        return store.queue.position >= 20 && store.queue.position < 22
          && store.playbackPosition == store.queue.position
          && !actual.seeking && actual.absoluteSeconds >= 20 && actual.absoluteSeconds < 22
      }
      let latestNativeClock = native.queueReadout.absoluteSeconds
      store.pause()
      let paused = store.queue.position
      try await Task.sleep(for: .seconds(1))
      guard !store.playbackRequested && abs(store.queue.position - paused) < 0.05 else {
        throw CheckFailure(step: "explicit-pause-not-stable")
      }
      await store.logout()
      return [
        "started_then_stalled": true, "stalled_position": stalled,
        "buffering_os_clock_frozen_and_retry_reanchored": true,
        "reconnection_requires_explicit_play": true, "retry_minimum_position": minimum,
        "same_occurrence_and_no_backward_retry": true, "latest_seek_and_pause": true,
        "latest_seek_native_clock": latestNativeClock,
        "native_configuration": native.safeStatus,
      ]
    }
    private struct TimingCatalog: MusicCatalogServing {
      let base: URL
      let file: String
      let metadataDuration: Double
      var items: [MusicItem] {
        [metadataDuration, 2.137].enumerated().map { index, duration in
          MusicItem(
            id: "timing-\(index)", title: "Invented timing \(index)", artist: "Fixture",
            album: "Fixture",
            duration: duration, number: index + 1, kind: "Audio", imageID: nil, imageTag: nil)
        }
      }
      func verifyIdentity() async throws {}
      func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
        [MusicLibrary(id: "fixture-music", title: "Invented")]
      }
      func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
        guard query.library == "fixture-music" else { throw ClientError.forbidden }
        return query.category == .albums && query.offset == 0 ? [.fixtureAlbum] : []
      }
      func albumTracks(library: String, album: String) async throws -> [MusicItem] {
        guard library == "fixture-music" else { throw ClientError.forbidden }
        return items
      }
      func validate(ids: [String]) async throws -> [MusicItem] {
        items.filter { ids.contains($0.id) }
      }
      func artwork(item: MusicItem) async throws -> Data? { nil }
      func media(
        library: String, trackID: String, quality: StreamQuality,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
      ) async throws -> MediaSource {
        try Task.checkCancellation()
        guard await isCurrent() else { throw CancellationError() }
        try Task.checkCancellation()
        guard library == "fixture-music" else { throw ClientError.forbidden }

        return MediaSource(
          url: base.appendingPathComponent(trackID == "timing-0" ? file : "tail.flac"),
          quality: quality,
          preferPreciseTiming: trackID != "timing-0" || file.hasSuffix(".flac"))
      }
    }
    static func timing(store: PlayerStore, native: NativePlayer, address: URL) async throws
      -> [[String: Any]]
    {
      var results: [[String: Any]] = []
      for (name, file, metadata, target) in [
        ("short-metadata", "short.flac", 3.0, 0.0),
        ("long-metadata-near-end", "short.flac", 15.0, 7.5),
        ("short-metadata-long-near-end", "long.flac", 170.137, 169.5),
        ("matching-long-flac-near-end", "long.flac", 177.137, 176.0),
        ("matching-long-mp3-near-end", "long.mp3", 177.137, 176.0),
      ] {
        await store.enterFixture(
          service: TimingCatalog(base: address, file: file, metadataDuration: metadata))
        guard store.isFixture else { throw CheckFailure(step: "timing-fixture-admission") }
        if results.isEmpty { try native.requireIntegrationTailStorage() }
        let selection = try await fixtureAlbumSelection(store: store)
        store.playSelection(selection)
        let start = ProcessInfo.processInfo.systemUptime
        var seekAt: Double?
        var actualAfterSeek: Double?
        var nativeDuration: Double?
        var maximum = 0.0
        var order: [Int] = []
        var handedOff = false
        var overrunSnapshot: [String: Any]?
        var timingMatches = false
        while ProcessInfo.processInfo.systemUptime - start < 15 {
          let now = ProcessInfo.processInfo.systemUptime
          let state = native.queueReadout
          if let occurrence = state.occurrence,
            let index = store.queue.entries.firstIndex(where: { $0.id == occurrence })
          {
            if order.last != index { order.append(index) }
            if index == 0 {
              if state.duration.isFinite && state.duration > 0 {
                nativeDuration = state.duration
                timingMatches =
                  store.playbackDuration == state.duration && !store.durationIsEstimated
              }
              if state.seconds.isFinite { maximum = max(maximum, state.seconds) }
              if target > 0 && seekAt == nil && store.queue.position > 0.2 {
                store.seek(target)
                seekAt = now
              } else if seekAt != nil && !state.seeking && actualAfterSeek == nil {
                actualAfterSeek = state.seconds
              }
              if store.queue.position > metadata + 0.25 && overrunSnapshot == nil {
                overrunSnapshot = [
                  "elapsed": store.queue.position, "metadata_total": metadata,
                  "native_total": nativeDuration ?? -1,
                  "display_total": store.playbackDuration ?? -1,
                  "display_estimated": store.durationIsEstimated,
                ]
              }
            } else if state.seconds > 0.1 {
              handedOff = true
              break
            }
          }
          if store.phase == .failed { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        results.append([
          "case": name, "metadata_duration": metadata, "native_duration": nativeDuration ?? -1,
          "seek_target": target, "actual_clock_after_completed_seek": actualAfterSeek ?? -1,
          "maximum_first_item_clock": maximum,
          "handoff_seconds_from_seek_or_start": ProcessInfo.processInfo.systemUptime
            - (seekAt ?? start),
          "observed_order": order, "handed_off": handedOff,
          "overrun_snapshot": overrunSnapshot ?? [:], "display_uses_native_timing": timingMatches,
          "native_configuration": native.safeStatus,
        ])
        await store.logout()
      }
      return results
    }
  }
#endif
