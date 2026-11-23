#if DEBUG && AUDIO_CLOCK_ACCEPTANCE && LIVE_MUSIC_ACCEPTANCE
  import AVFoundation
  import Foundation
  import UIKit

  @MainActor enum AudioClockAcceptance {
    private enum Phase: String, Sendable {
      case full = "high_full"
      case resume = "high_resume"
      case second = "second_high"

      nonisolated var origin: Double { self == .resume ? 60 : 0 }
    }

    private struct Anchor: Sendable {
      let item: Double
      let display: Double
    }

    private struct Observation: Sendable {
      var points: [AudioClockPoint] = []
      var anchors: [Anchor] = []
      var dropped = 0
      var ends = 0
      var failures = 0
      var pauses = 0
      var regressions = 0
      var reopens: Set<Int> = []
      var ignored: Set<Int> = []
      var trackTap = false
      var calls = 0
      var format = 0
      var sourceStatus = 0
      var insertions = 0
      var firstOrigin: Double?
      var actualOrigin: Double?
      var seekBound: Double?
      var seekIssued = false
      var beforeSeek: Double?
      var storeFailure = 0
      var storeFailureCode = 0
      var pausedWhileMeasuring = 0
      var mixedPauseBoundary: Double?
    }

    private enum AlbumFailure: Int, Error {
      case input = 4701
      case selection = 4702
      case ambiguous = 4703
      case budget = 4704
      case queue = 4707
      case source = 4708
      case playback = 4709
    }

    @MainActor private final class AlbumItem {
      let track: MusicItem
      let reference: AudioClockReference
      var occurrence: UUID?
      var observation = Observation()
      var taps: [AudioClockTap] = []
      var currentCount = 0
      var handoffIn = 0
      var handoffOut = 0
      private var overflow = 0

      init(track: MusicItem, reference: AudioClockReference) {
        self.track = track
        self.reference = reference
      }

      func drain() {
        for tap in taps {
          let cells = tap.drain()
          if observation.points.count + cells.count <= 60_000 {
            observation.points.append(contentsOf: cells)
          } else {
            overflow += cells.count
          }
        }
        observation.dropped = overflow + taps.reduce(0) { $0 + Int(clamping: $1.dropped) }
        observation.calls = taps.reduce(0) { $0 + Int(clamping: $1.processCallbacks) }
        observation.format =
          taps.isEmpty
          ? 0
          : Int(taps.first(where: { $0.formatStatus != 1 })?.formatStatus ?? 1)
        observation.sourceStatus = Int(
          taps.first(where: { $0.sourceStatus != 0 })?.sourceStatus ?? 0)
      }
    }

    @MainActor private final class AlbumCapture {
      let items: [AlbumItem]
      var observers: [NSObjectProtocol] = []
      var currentIndex: Int?
      var measuring = false
      var done = false
      var queueCount = 0
      var queueChecked = false
      var handoffs = 0
      var handoffErrors = 0
      var forcedNext = 0
      var forcedSeek = 0
      var unexpectedCommands = 0
      var startupRouteMask = 0
      var playingRouteMask = 0
      var finalRouteMask = 0
      var routeSamples = 0
      var speakerSamples = 0
      var routeChanges = 0
      var routeBad = 0
      var volumeBad = 0
      var inserted = 0
      var stopping = false

      init(items: [AlbumItem]) { self.items = items }

      func samplePlayingRoute(_ native: NativePlayer) {
        let mask = AudioClockRoute.current
        finalRouteMask = mask
        playingRouteMask |= mask
        routeSamples += 1
        if mask == AudioClockRoute.speaker { speakerSamples += 1 } else { routeBad += 1 }
        if AVAudioSession.sharedInstance().outputVolume <= 0 || !native.audioClockOutputEnabled {
          volumeBad += 1
        }
      }

      func stopAtThirdEnd(_ store: PlayerStore) {
        guard done, !stopping else { return }
        stopping = true
        measuring = false
        if store.playbackRequested { store.pause() }
      }

      func close() {
        measuring = false
        for item in items {
          item.drain()
          for tap in item.taps { tap.invalidate() }
        }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
      }
    }

    static func runAlbum(
      _ input: [String: String], runID: UUID, documents: URL, store: PlayerStore,
      native: NativePlayer
    ) async throws {
      let required: Set<String> = [
        "run_id", "scenario", "version", "nonce", "deadline_unix_ms", "in_app_budget_ms",
        "artist", "album",
      ]
      guard Set(input.keys) == required || Set(input.keys) == required.union(["wanted_route"]),
        input["run_id"].flatMap(UUID.init(uuidString:)) == runID,
        input["scenario"] == "real-music-album-audio-clock", input["version"] == "1",
        input["in_app_budget_ms"] == "1200000",
        input["wanted_route"] == nil || input["wanted_route"] == "builtInSpeaker",
        let artist = input["artist"], let album = input["album"],
        !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        artist.count <= 128, album.count <= 128,
        let nonce = input["nonce"].flatMap(UUID.init(uuidString:)),
        let endMS = input["deadline_unix_ms"].flatMap(Int64.init)
      else { throw AlbumFailure.input }
      let now = Date()
      let end = Date(timeIntervalSince1970: Double(endMS) / 1000)
      guard (180...1500).contains(end.timeIntervalSince(now)),
        store.active == nil, store.current == nil,
        native.measureAudioItem == nil, native.measureAudioItemBeforeInsertion == nil
      else { throw AlbumFailure.input }
      let deadline = min(end.addingTimeInterval(-180), now.addingTimeInterval(1200))
      let current: @MainActor @Sendable () -> Bool = { !Task.isCancelled && Date() < deadline }
      try native.beginAudioClockOutput()
      let priorIdleTimer = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      defer {
        native.measureAudioItem = nil
        native.measureAudioItemBeforeInsertion = nil
        if let lease = store.transportAcceptanceLease() {
          _ = store.retireTransportAcceptance(owned: lease)
        }
        native.endAudioClockOutput()
        UIApplication.shared.isIdleTimerDisabled = priorIdleTimer
      }
      var rows: [[String: Any]] = []
      var evidence: [String: Any] = [
        "stage": "failed", "self_check": false, "music_only": false,
        "selection_exact": false, "first_three_distinct": false,
        "queue_count": 0, "handoffs": 0, "handoff_errors": 0,
        "forced_next": 0, "forced_seek": 0, "unexpected_commands": 0,
        "route_samples": 0, "speaker_samples": 0, "route_changes": 0,
        "route_bad": 0, "volume_bad": 0, "error_code": 0,
        "startup_route_mask": 0, "playing_route_mask": 0, "final_route_mask": 0,
        "pause_control": AudioClockPauseControl.empty,
      ]
      do {
        let referenceCheck = await Task.detached(priority: .utility) {
          AudioClockReference.selfCheck()
        }.value
        guard referenceCheck, AudioClockRoute.mask([]) == 1,
          AudioClockRoute.mask([.builtInSpeaker, .builtInSpeaker]) == AudioClockRoute.speaker,
          AudioClockRoute.mask([.builtInSpeaker, .usbAudio]) == 34
        else { throw AlbumFailure.source }
        evidence["self_check"] = true
        let client = try await TransportAcceptance.realMusicClient(isCurrent: current)
        try await client.verifyIdentity()
        let (library, selectedAlbum, tracks) = try await exactAlbum(
          client: client, artist: artist, album: album, current: current)
        evidence["music_only"] = true
        evidence["selection_exact"] = true
        let firstThree = Array(tracks.prefix(3))
        guard firstThree.count == 3, Set(firstThree.map(\.id)).count == 3,
          firstThree.allSatisfy({ $0.kind == "Audio" && (24...600).contains($0.duration) })
        else { throw AlbumFailure.selection }
        evidence["first_three_distinct"] = true
        var measured = [AlbumItem]()
        for track in firstThree {
          guard current() else { throw CancellationError() }
          let original = try await reference(
            client: client, library: library.id, item: track, origin: 0,
            quality: .original, maximumDuration: 600, current: current)
          measured.append(AlbumItem(track: track, reference: original))
        }
        let playbackSeconds = measured.reduce(0) { $0 + $1.reference.duration }
        guard current(), playbackSeconds + 220 <= deadline.timeIntervalSinceNow else {
          throw AlbumFailure.budget
        }
        await store.enterFixture(service: client)
        guard current(), await store.browser?.admitPlaybackLibrary(library.id) == true,
          store.queue.entries.isEmpty, store.repeatMode == .off, !store.shuffleEnabled,
          let origin = store.playbackOrigin(library: library.id)
        else { throw AlbumFailure.queue }
        store.quality(.high)
        let capture = AlbumCapture(items: measured)
        var captureError: Error?
        do {
          try await observeAlbum(
            capture, tracks: tracks, album: selectedAlbum, origin: origin,
            store: store, native: native, deadline: deadline)
        } catch { captureError = error }
        for (index, item) in measured.enumerated() {
          let observation = item.observation
          let reference = item.reference
          let scored = await Task.detached(priority: .utility) {
            Self.assess(.full, reference: reference, result: observation)
          }.value
          var row: [String: Any] = scored.mapValues { $0 as Any }
          row["phase"] = "album_\(index + 1)"
          row["index"] = index
          row["reference_original"] = 1
          row["current_count"] = item.currentCount
          row["handoff_in"] = item.handoffIn
          row["handoff_out"] = item.handoffOut
          row["fresh_probe_count"] = 0
          row["fresh_probe_aligned"] = 0
          row["fresh_probe_clock_ms"] = -1
          row["fresh_probe_audio_ms"] = -1
          row["fresh_probe_code"] = 0
          rows.append(row)
        }
        evidence["queue_count"] = capture.queueCount
        evidence["handoffs"] = capture.handoffs
        evidence["handoff_errors"] = capture.handoffErrors
        evidence["forced_next"] = capture.forcedNext
        evidence["forced_seek"] = capture.forcedSeek
        evidence["unexpected_commands"] = capture.unexpectedCommands
        evidence["startup_route_mask"] = capture.startupRouteMask
        evidence["playing_route_mask"] = capture.playingRouteMask
        evidence["final_route_mask"] = capture.finalRouteMask
        evidence["route_samples"] = capture.routeSamples
        evidence["speaker_samples"] = capture.speakerSamples
        evidence["route_changes"] = capture.routeChanges
        evidence["route_bad"] = capture.routeBad
        evidence["volume_bad"] = capture.volumeBad
        if let index = rows.firstIndex(where: { ($0["mismatches"] as? Int ?? 0) > 0 }),
          current(), deadline.timeIntervalSinceNow >= 250
        {
          await freshAlbumProbe(
            row: &rows[index], item: measured[index], client: client,
            library: library.id, current: current)
        }
        if captureError == nil, current(), let first = measured.first {
          evidence["pause_control"] = await AudioClockPauseControl.measure(
            store: store, native: native, library: library.id, item: first.track,
            reference: first.reference, deadline: deadline)
        }
        if let captureError { throw captureError }
        evidence["stage"] = "complete"
      } catch {
        evidence["error_code"] =
          (error as? AlbumFailure)?.rawValue
          ?? ((error as NSError).code == 0 ? -1 : (error as NSError).code)
      }
      evidence["runs"] = rows
      let report: [String: Any] = [
        "run_id": runID.uuidString, "scenario": "real-music-album-audio-clock", "version": 1,
        "nonce": nonce.uuidString, "evidence": evidence,
      ]
      try TransportControlFiles.publish(
        JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
        in: documents, runID: runID)
      try await retireAcknowledgedReport(
        in: documents, runID: runID, nonce: nonce, deadline: deadline)
    }

    static func exactAlbum(
      client: JellyfinClient, artist: String, album: String,
      current: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> (MusicLibrary, MusicItem, [MusicItem]) {
      func exact(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
          .precomposedStringWithCanonicalMapping.lowercased()
      }
      let libraries = try await client.musicLibraries(refresh: true)
      guard !libraries.isEmpty, libraries.count <= 8 else { throw AlbumFailure.selection }
      let until = Date().addingTimeInterval(60)
      var matches: [(MusicLibrary, MusicItem)] = []
      for library in libraries {
        var offset = 0
        var complete = false
        var seen = Set<String>()
        for _ in 0..<8 {
          guard current(), Date() < until else { throw CancellationError() }
          let page = try await client.catalogPage(
            CatalogQuery(library: library.id, category: .albums, offset: offset, search: album))
          guard current() else { throw CancellationError() }
          for item in page.items where seen.insert(item.id).inserted {
            if item.kind == "MusicAlbum", exact(item.title) == exact(album),
              exact(item.artist) == exact(artist)
            {
              matches.append((library, item))
            }
          }
          if page.rawCount < 40 {
            complete = true
            break
          }
          offset += page.rawCount
        }
        guard complete else { throw AlbumFailure.selection }
      }
      guard matches.count == 1 else {
        throw matches.isEmpty ? AlbumFailure.selection : AlbumFailure.ambiguous
      }
      let match = matches[0]
      let tracks = try await client.albumTracks(library: match.0.id, album: match.1.id)
      guard current(), (3...200).contains(tracks.count),
        tracks.allSatisfy({ $0.kind == "Audio" }), Set(tracks.map(\.id)).count == tracks.count
      else { throw AlbumFailure.selection }
      return (match.0, match.1, tracks)
    }

    private static func observeAlbum(
      _ capture: AlbumCapture, tracks: [MusicItem], album: MusicItem, origin: PlaybackOrigin,
      store: PlayerStore, native: NativePlayer, deadline: Date
    ) async throws {
      let receive = native.onEvent
      let remote = native.onRemote
      let expectedIDs = tracks.map(\.id)
      native.measureAudioItemBeforeInsertion = { [capture] item, prepared in
        guard !capture.done else { return }
        guard Date() < deadline, !Task.isCancelled, capture.inserted < 8,
          prepared.entry.libraryID == origin.library,
          prepared.authority?.library == origin.library,
          expectedIDs.contains(prepared.entry.track.id), prepared.source.quality == .high,
          abs(prepared.source.timeOrigin) < 0.001
        else { throw AlbumFailure.source }
        capture.measuring = true
        if capture.inserted == 0 { capture.startupRouteMask |= AudioClockRoute.current }
        capture.inserted += 1
        guard
          let index = capture.items.firstIndex(where: { $0.track.id == prepared.entry.track.id })
        else { return }
        let tap = try AudioClockTap.install(on: item)
        let measured = capture.items[index]
        guard measured.occurrence == nil || measured.occurrence == prepared.entry.id,
          measured.taps.count < 4
        else {
          tap.invalidate()
          throw AlbumFailure.queue
        }
        measured.occurrence = prepared.entry.id
        measured.observation.insertions += 1
        if measured.observation.firstOrigin == nil {
          measured.observation.firstOrigin = prepared.source.timeOrigin
        }
        measured.observation.actualOrigin = prepared.source.timeOrigin
        measured.taps.append(tap)
        let observer = NotificationCenter.default.addObserver(
          forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak capture, weak measured] _ in
          MainActor.assumeIsolated {
            guard let capture, let measured else { return }
            measured.observation.ends = max(1, measured.observation.ends)
            if index == 2 {
              capture.done = true
              capture.stopAtThirdEnd(store)
            }
          }
        }
        capture.observers.append(observer)
      }
      native.onRemote = { action in
        capture.unexpectedCommands += 1
        switch action {
        case .next: capture.forcedNext += 1
        case .seek: capture.forcedSeek += 1
        default: break
        }
        remote?(action)
      }
      native.onEvent = { event in
        switch event {
        case .advanced(let id):
          if let next = capture.items.firstIndex(where: { $0.occurrence == id }) {
            let item = capture.items[next]
            item.currentCount += 1
            if let previous = capture.currentIndex {
              if next == previous + 1, previous < 2 {
                let prior = capture.items[previous]
                prior.handoffOut = 1
                item.handoffIn = 1
                capture.handoffs += 1
                if let last = prior.observation.anchors.last,
                  last.display >= prior.reference.duration - 2
                {
                  prior.observation.ends = max(1, prior.observation.ends)
                }
              } else {
                capture.handoffErrors += 1
              }
            } else if next != 0 {
              capture.handoffErrors += 1
            }
            capture.currentIndex = next
          } else if capture.currentIndex == 2 {
            let third = capture.items[2]
            if third.observation.ends > 0
              || (third.observation.anchors.last.map { $0.display >= third.reference.duration - 2 }
                ?? false)
            {
              third.observation.ends = max(1, third.observation.ends)
              capture.done = true
            } else {
              capture.handoffErrors += 1
            }
          } else {
            capture.handoffErrors += 1
          }
        case .finished(let id):
          if let index = capture.items.firstIndex(where: { $0.occurrence == id }) {
            capture.items[index].observation.ends = max(1, capture.items[index].observation.ends)
            if index == 2 { capture.done = true }
          }
        case .failure, .failureDetails:
          capture.items[capture.currentIndex ?? 0].observation.failures += 1
        default: break
        }
        receive?(event)
        capture.stopAtThirdEnd(store)
      }
      let routeObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
      ) { [weak capture] _ in
        MainActor.assumeIsolated {
          guard let capture, capture.measuring else { return }
          capture.routeChanges += 1
          if capture.routeSamples == 0 { capture.startupRouteMask |= AudioClockRoute.current }
        }
      }
      capture.observers.append(routeObserver)
      defer {
        native.measureAudioItemBeforeInsertion = nil
        native.onEvent = receive
        native.onRemote = remote
        capture.close()
        if store.playbackRequested { store.pause() }
      }
      store.playAlbum(album, origin: origin)
      let begun = Date()
      let duration = capture.items.reduce(0) { $0 + $1.reference.duration }
      let cap = min(deadline, begun.addingTimeInterval(duration + 45))
      while Date() < cap, !Task.isCancelled, !capture.done {
        if !store.queue.entries.isEmpty, !capture.queueChecked {
          capture.queueCount = store.queue.entries.count
          guard store.queue.entries.map({ $0.track.id }) == expectedIDs,
            store.queue.entries.allSatisfy({ $0.libraryID == origin.library })
          else { throw AlbumFailure.queue }
          capture.queueChecked = true
        }
        guard capture.unexpectedCommands == 0 else { throw AlbumFailure.playback }
        for item in capture.items { item.drain() }
        let readout = native.queueReadout
        if let occurrence = readout.occurrence,
          let index = capture.items.firstIndex(where: { $0.occurrence == occurrence })
        {
          let item = capture.items[index]
          for transfer in native.liveMusicReadout(for: occurrence)?.transfers ?? []
          where !transfer.head && (transfer.rangeStart ?? 0) > 0 {
            item.observation.reopens.insert(transfer.ordinal)
            if transfer.status == 200 { item.observation.ignored.insert(transfer.ordinal) }
          }
          if store.phase == .failed {
            item.observation.failures = max(1, item.observation.failures)
            item.observation.storeFailure = 1
            item.observation.storeFailureCode = store.lastPlaybackFailure?.detail.code ?? 0
            throw AlbumFailure.playback
          }
          if store.playing, store.current?.id == item.occurrence,
            !readout.seeking, !readout.preparing,
            readout.timeControlStatus == AVPlayer.TimeControlStatus.playing.rawValue,
            readout.seconds.isFinite, readout.seconds >= 0
          {
            capture.samplePlayingRoute(native)
            let display = store.playbackPosition
            if let last = item.observation.anchors.last, display + 0.45 < last.display {
              item.observation.regressions += 1
            }
            if item.observation.anchors.count < 18_000 {
              item.observation.anchors.append(Anchor(item: readout.seconds, display: display))
            } else {
              throw AlbumFailure.budget
            }
          }
          if store.phase == .paused, !store.playbackRequested, item.observation.ends == 0 {
            item.observation.pausedWhileMeasuring = 1
            throw AlbumFailure.playback
          }
        } else if store.phase == .failed {
          throw AlbumFailure.playback
        }
        guard !capture.items.contains(where: { $0.observation.failures > 0 }) else {
          throw AlbumFailure.playback
        }
        if !capture.queueChecked, Date().timeIntervalSince(begun) > 45 { throw AlbumFailure.queue }
        try await Task.sleep(for: .milliseconds(90))
      }
      for item in capture.items { item.drain() }
      guard capture.done, capture.queueChecked, capture.handoffs == 2 else {
        throw AlbumFailure.playback
      }
      for index in 0..<2 where capture.items[index].observation.ends == 0 {
        capture.handoffErrors += 1
      }
      guard capture.handoffErrors == 0, capture.routeSamples > 0 else {
        throw AlbumFailure.playback
      }
    }

    private static func freshAlbumProbe(
      row: inout [String: Any], item: AlbumItem, client: JellyfinClient, library: String,
      current: @escaping @MainActor @Sendable () -> Bool
    ) async {
      guard let firstBad = row["first_bad_clock_ms"] as? Int, firstBad >= 0 else { return }
      row["fresh_probe_count"] = 1
      row["fresh_probe_clock_ms"] = firstBad
      do {
        let fresh = try await reference(
          client: client, library: library, item: item.track, origin: 0,
          quality: .high, maximumDuration: 600, current: current)
        let clock = Double(firstBad) / 1000
        for width in [400, 150] {
          let span = Double(width) * 0.020
          let start = max(0, min(clock - span / 2, fresh.duration - span - 0.025))
          let points = fresh.points(from: start, count: width)
          let original = item.reference
          let match = await Task.detached(priority: .utility) {
            original.match(points)
          }.value
          guard let match else { continue }
          let audio = match.time + clock - start
          row["fresh_probe_audio_ms"] = ms(audio)
          row["fresh_probe_aligned"] = abs(audio - clock) <= 1.5 ? 1 : 0
          return
        }
      } catch {
        row["fresh_probe_code"] = (error as NSError).code == 0 ? -1 : (error as NSError).code
      }
    }

    nonisolated private static func ms(_ seconds: Double) -> Int {
      guard seconds.isFinite, abs(seconds) < 1_000_000 else { return -1 }
      return Int((seconds * 1000).rounded())
    }

    static func run(
      _ input: [String: String], runID: UUID, documents: URL, store: PlayerStore,
      native: NativePlayer
    ) async throws {
      let now = Date()
      guard
        Set(input.keys) == [
          "run_id", "scenario", "version", "nonce", "deadline_unix_ms", "in_app_budget_ms",
        ], input["run_id"].flatMap(UUID.init(uuidString:)) == runID,
        input["version"] == "1", input["scenario"] == "real-music-audio-clock-v2",
        input["in_app_budget_ms"] == "1200000",
        let nonce = input["nonce"].flatMap(UUID.init(uuidString:)),
        let endMS = input["deadline_unix_ms"].flatMap(Int64.init)
      else { throw ClientError.invalidResponse }
      let end = Date(timeIntervalSince1970: Double(endMS) / 1000)
      guard (180...1500).contains(end.timeIntervalSince(now)) else { throw CancellationError() }
      let deadline = min(end.addingTimeInterval(-180), now.addingTimeInterval(1200))
      let current: @MainActor @Sendable () -> Bool = { !Task.isCancelled && Date() < deadline }

      guard store.active == nil, store.current == nil else { throw ClientError.invalidResponse }
      try native.beginAudioClockOutput()
      let priorIdleTimer = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      defer {
        native.measureAudioItem = nil
        if let lease = store.transportAcceptanceLease() {
          _ = store.retireTransportAcceptance(owned: lease)
        }
        native.endAudioClockOutput()
        UIApplication.shared.isIdleTimerDisabled = priorIdleTimer
      }
      var rows: [[String: Any]] = []
      var evidence: [String: Any] = [
        "stage": "failed", "self_check": false, "music_only": false, "second_distinct": false,
        "tail_probe_count": 0, "tail_aligned": 0, "tail_first_match_ms": -1,
        "tail_first_expected_ms": -1, "error_code": 0,
      ]
      do {
        guard AudioClockReference.selfCheck() else { throw ClientError.invalidResponse }
        evidence["self_check"] = true
        let client = try await TransportAcceptance.realMusicClient(isCurrent: current)
        try await client.verifyIdentity()
        let (library, first, second) = try await TransportAcceptance.realMusicPair(
          client: client, secondDuration: 85...300, isCurrent: current)
        guard current(), first.id != second.id else { throw CancellationError() }
        evidence["music_only"] = true
        evidence["second_distinct"] = true

        let firstCanonical = try await canonical(client, library.id, first, current: current)
        let firstReference = firstCanonical.audio
        let tail = try await reference(
          client: client, library: library.id, item: first, origin: 60, current: current)
        var aligned = 0
        for seconds in [4.0, 12, 20] {
          let expected = 60 + seconds
          let query = tail.points(from: seconds, count: 150)
          let match = await Task.detached(priority: .utility) {
            firstReference.match(query)
          }.value
          if seconds == 4 {
            evidence["tail_first_expected_ms"] = ms(expected)
            evidence["tail_first_match_ms"] = match.map { ms($0.time) } ?? -1
          }
          if let match, abs(expected - match.time) <= 1.5 { aligned += 1 }
        }
        evidence["tail_probe_count"] = 3
        evidence["tail_aligned"] = aligned

        await store.enterFixture(service: client)
        guard current(), await store.browser?.admitPlaybackLibrary(library.id) == true else {
          throw ClientError.invalidResponse
        }
        store.quality(.high)
        var trackTap = false
        for phase in [Phase.resume, .second, .full] {
          guard current() else { throw CancellationError() }
          let selection = phase == .second ? second : first
          let canonical =
            phase == .second
            ? try await self.canonical(client, library.id, second, current: current)
            : firstCanonical
          let ref = canonical.audio
          var observation = try await observe(
            phase, store: store, native: native, library: library.id, item: selection,
            referenceDuration: ref.duration,
            trackTap: trackTap, deadline: deadline)
          if phase == .full, current(), observation.points.isEmpty, !trackTap {
            trackTap = true
            observation = try await observe(
              phase, store: store, native: native, library: library.id, item: selection,
              referenceDuration: ref.duration,
              trackTap: true, deadline: deadline)
          }
          let frozenObservation = observation
          let scored = await Task.detached(priority: .utility) {
            Self.assess(phase, reference: ref, result: frozenObservation)
          }.value
          var row: [String: Any] = scored.mapValues { $0 as Any }
          row["phase"] = phase.rawValue
          row["reference_original"] = canonical.original ? 1 : 0
          rows.append(row)

        }
        evidence["stage"] = "complete"
      } catch {
        evidence["error_code"] = (error as NSError).code == 0 ? -1 : (error as NSError).code
      }
      evidence["runs"] = rows
      let report: [String: Any] = [
        "run_id": runID.uuidString, "scenario": "real-music-audio-clock-v2", "version": 1,
        "nonce": nonce.uuidString, "evidence": evidence,
      ]
      try TransportControlFiles.publish(
        JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), in: documents,
        runID: runID)
      try await retireAcknowledgedReport(
        in: documents, runID: runID, nonce: nonce, deadline: deadline)
    }

    static func retireAcknowledgedReport(
      in documents: URL, runID: UUID, nonce: UUID, deadline: Date
    ) async throws {
      let folder = TransportControlFiles.directory(in: documents, runID: runID)
      for parent in [folder.deletingLastPathComponent(), folder] {
        let attrs = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attrs.isDirectory == true, attrs.isSymbolicLink != true else {
          throw ClientError.invalidResponse
        }
      }
      let ack = folder.appendingPathComponent("input.json")
      let until = min(deadline, Date().addingTimeInterval(90))
      while Date() < until, !Task.isCancelled {
        if FileManager.default.fileExists(atPath: ack.path) {
          let attrs = try ack.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
          ])
          guard attrs.isRegularFile == true, attrs.isSymbolicLink != true,
            let size = attrs.fileSize, size < 4096
          else { throw ClientError.invalidResponse }
          let data = try Data(contentsOf: ack)
          guard data.count < 4096 else { throw ClientError.invalidResponse }
          if let receipt = try? JSONDecoder().decode([String: String].self, from: data) {
            guard Set(receipt.keys) == ["run_id", "nonce", "scenario"],
              receipt["run_id"].flatMap(UUID.init(uuidString:)) == runID,
              receipt["nonce"].flatMap(UUID.init(uuidString:)) == nonce,
              receipt["scenario"] == "audio-clock-receipt"
            else { throw ClientError.invalidResponse }
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try TransportControlFiles.cleanupTails(in: caches, runID: runID)
            try TransportControlFiles.cleanup(in: documents, runID: runID)
            return
          }
        }
        try await Task.sleep(for: .milliseconds(200))
      }
    }

    private static func canonical(
      _ client: JellyfinClient, _ library: String, _ item: MusicItem,
      current: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> (audio: AudioClockReference, original: Bool) {
      do {
        return (
          try await reference(
            client: client, library: library, item: item, origin: 0, quality: .original,
            current: current), true
        )
      } catch {
        guard current() else { throw CancellationError() }
        return (
          try await reference(
            client: client, library: library, item: item, origin: 0, current: current), false
        )
      }
    }

    private static func reference(
      client: JellyfinClient, library: String, item: MusicItem, origin: Double,
      quality: StreamQuality = .high, maximumDuration: Double = 310,
      current: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> AudioClockReference {
      let full = try await client.media(
        library: library, trackID: item.id, quality: quality, isCurrent: current)
      let source = try full.starting(at: origin)
      guard current(), quality == .original || source.serverTimeSeek,
        abs(source.timeOrigin - origin) < 0.001
      else {
        throw ClientError.invalidResponse
      }
      let limit = quality == .original ? 67_108_864 : 8_388_608
      let response = try await LiveHTTP(maximumBytes: limit, resourceTimeout: 60)
        .send(source.upstreamRequest)
      guard current(), response.status == 200, !response.data.isEmpty else {
        throw ClientError.invalidResponse
      }
      let data = response.data
      let ref = try await Task.detached(priority: .utility) { try AudioClockReference(data: data) }
        .value
      guard current(), ref.duration >= 24, ref.duration <= maximumDuration,
        origin > 0 || abs(ref.duration - (source.serverDuration ?? -1)) <= 2
      else { throw ClientError.invalidResponse }
      return ref
    }

    private static func observe(
      _ phase: Phase, store: PlayerStore, native: NativePlayer, library: String, item: MusicItem,
      referenceDuration: Double, trackTap: Bool, deadline: Date
    ) async throws -> Observation {
      var tap: AudioClockTap?
      var occurrence: UUID?
      var observation = Observation()
      observation.trackTap = trackTap
      var waitingForReplacement = false
      native.measureAudioItem = { playingItem, prepared in
        guard Date() < deadline, !Task.isCancelled else { throw CancellationError() }
        guard prepared.entry.id == occurrence else { return }
        observation.insertions += 1
        if observation.firstOrigin == nil { observation.firstOrigin = prepared.source.timeOrigin }
        if phase == .resume && !observation.seekIssued { return }
        observation.actualOrigin = prepared.source.timeOrigin
        waitingForReplacement = false
        if trackTap {
          guard let track = try await playingItem.asset.loadTracks(withMediaType: .audio).first
          else {
            throw ClientError.invalidResponse
          }
          tap = try AudioClockTap.install(on: playingItem, track: track)
        } else {
          tap = try AudioClockTap.install(on: playingItem)
        }
      }
      let receive = native.onEvent
      native.onEvent = { event in
        switch event {
        case .finished(let id) where id == occurrence: observation.ends += 1
        case .failure, .failureDetails: observation.failures += 1
        default: break
        }
        receive?(event)
      }
      defer {
        tap?.invalidate()
        native.measureAudioItem = nil
        native.onEvent = receive
        if store.playbackRequested { store.pause() }
      }
      guard Date() < deadline, let selected = store.playbackSelection([item], library: library)
      else {
        throw ClientError.invalidResponse
      }
      store.playSelection(selected)
      guard let active = store.current?.id else { throw ClientError.invalidResponse }
      occurrence = active
      let began = ContinuousClock.now
      var observationBegan = began
      var pauseAt: ContinuousClock.Instant?
      let cap = min(
        deadline, Date().addingTimeInterval(phase == .full ? referenceDuration + 35 : 115))
      while Date() < cap, !Task.isCancelled, observation.ends == 0, observation.failures == 0 {
        let readout = native.queueReadout
        if store.phase == .failed {
          observation.failures = max(1, observation.failures)
          observation.storeFailure = 1
          observation.storeFailureCode = store.lastPlaybackFailure?.detail.code ?? 0
          break
        }
        if phase == .resume, !observation.seekIssued, store.playing, store.playbackPosition >= 1 {
          observation.seekIssued = true
          observation.beforeSeek = store.playbackPosition
          observation.seekBound = store.seekUpperBound
          waitingForReplacement = true
          observationBegan = .now
          store.seek(phase.origin, occurrence: active)
        }
        if !waitingForReplacement, let actual = observation.actualOrigin,
          readout.occurrence == active, abs(readout.timeOrigin - actual) < 0.001
        {
          if let tap {
            let cells = tap.drain()
            if observation.points.count + cells.count <= 18_000 {
              observation.points.append(contentsOf: cells)
            } else {
              observation.dropped += cells.count
            }
          }
          for transfer in native.liveMusicReadout(for: active)?.transfers ?? []
          where !transfer.head && (transfer.rangeStart ?? 0) > 0 {
            observation.reopens.insert(transfer.ordinal)
            if transfer.status == 200 { observation.ignored.insert(transfer.ordinal) }
          }
          if store.playing, !readout.seeking, !readout.preparing,
            readout.timeControlStatus == AVPlayer.TimeControlStatus.playing.rawValue,
            readout.seconds.isFinite, readout.seconds >= 0, store.current?.id == active
          {
            let display = store.playbackPosition
            if let last = observation.anchors.last, display + 0.45 < last.display {
              observation.regressions += 1
            }
            observation.anchors.append(Anchor(item: readout.seconds, display: display))
          }
          if phase == .second, pauseAt == nil, store.playing, store.playbackPosition >= 30 {
            if !trackTap { observation.mixedPauseBoundary = readout.seconds }
            store.pause()
            pauseAt = .now
            observation.pauses += 1
          }
          if phase == .resume, (observation.anchors.last?.display ?? 0) >= actual + 34 {
            break
          }
          if phase == .second, (observation.anchors.last?.display ?? 0) >= 75 { break }
        }
        if let pauseAt, observation.pauses == 1, !store.playbackRequested,
          pauseAt.duration(to: .now) >= .seconds(2)
        {
          store.play()
        }
        if store.phase == .paused && !store.playbackRequested && pauseAt == nil {
          observation.pausedWhileMeasuring = 1
        }
        if observationBegan.duration(to: .now) >= .seconds(45), observation.points.isEmpty { break }
        try await Task.sleep(for: .milliseconds(90))
      }
      if let tap {
        observation.dropped += Int(clamping: tap.dropped)
        observation.calls = Int(clamping: tap.processCallbacks)
        observation.format = Int(tap.formatStatus)
        observation.sourceStatus = Int(tap.sourceStatus)
        let remaining = tap.drain()
        if observation.points.count + remaining.count <= 18_000 {
          observation.points.append(contentsOf: remaining)
        } else {
          observation.dropped += remaining.count
        }
      }
      return observation
    }

    nonisolated private static func assess(
      _ phase: Phase, reference: AudioClockReference, result: Observation
    ) -> [String: Int] {
      let points = result.points
      let first = result.anchors.first?.display
      let last = result.anchors.last?.display
      var gaps = [Double]()
      var aligned = [Double]()
      var matched = 0
      var ambiguous = 0
      var weak = 0
      var repeated = 0
      var silent = 0
      var other = 0
      var windows = 0
      var restart = 0
      var jumps = 0
      var lastMatch: (display: Double, audio: Double)?
      var firstBad: (display: Double, audio: Double)?
      var maxError: Double?
      let shortWindow = 150
      var segment = 0
      for i in 0...points.count {
        let end = i == points.count
        guard end || (i > 0 && abs(points[i].time - points[i - 1].time - 0.020) > 0.045) else {
          continue
        }
        if !end { jumps += 1 }
        if jumps <= (end ? 0 : 1), i - segment >= shortWindow {
          for center in stride(
            from: segment + shortWindow / 2 + 25, through: i - shortWindow / 2, by: 100)
          {
            let middle = points[center].time
            guard
              let clock = result.anchors.min(by: { abs($0.item - middle) < abs($1.item - middle) }),
              abs(clock.item - middle) <= 0.25
            else { continue }
            windows += 1
            var audioTime: Double?
            var reason = AudioClockReference.MatchReason.tooShort
            for width in [400, shortWindow] {
              let start = center - width / 2
              guard start >= segment, start + width <= i else { continue }
              if let boundary = result.mixedPauseBoundary,
                points[start + width - 1].time + 0.020 >= boundary
              {
                continue
              }
              let score = reference.diagnose(Array(points[start..<(start + width)]))
              reason = score.reason
              if score.reason == .matched {
                audioTime = score.bestTime + middle - points[start].time
                break
              }
            }
            guard let audio = audioTime else {
              ambiguous += 1
              switch reason {
              case .weakFit: weak += 1
              case .ambiguous: repeated += 1
              case .silence: silent += 1
              default: other += 1
              }
              continue
            }
            matched += 1
            let error = abs(audio - clock.display)
            maxError = max(maxError ?? 0, error)
            if error <= 1.5 {
              aligned.append(clock.display)
            } else {
              if firstBad == nil { firstBad = (clock.display, audio) }
              if let prior = lastMatch, clock.display >= prior.display,
                audio < prior.audio - 2
              {
                restart += 1
              }
            }
            lastMatch = (clock.display, audio)
          }
        }
        segment = i
      }
      if let first, let last, let a = aligned.first, let b = aligned.last {
        gaps = [a - first, last - b]
        gaps.append(contentsOf: zip(aligned, aligned.dropFirst()).map { $1 - $0 })
      }
      return [
        "weak_windows": weak, "repeated_windows": repeated,
        "silent_windows": silent, "other_windows": other,
        "insertions": result.insertions, "initial_origin_ms": result.firstOrigin.map(ms) ?? -1,
        "request_ms": phase == .resume ? 60_000 : 0,
        "seek_issued": result.seekIssued ? 1 : 0, "seek_bound_ms": result.seekBound.map(ms) ?? -1,
        "before_seek_ms": result.beforeSeek.map(ms) ?? -1, "store_failure": result.storeFailure,
        "store_code": result.storeFailureCode, "unexpected_pause": result.pausedWhileMeasuring,
        "duration_ms": ms(reference.duration),
        "origin_ms": result.actualOrigin.map(ms) ?? -1,
        "clock_first_ms": first.map(ms) ?? -1, "clock_last_ms": last.map(ms) ?? -1,
        "end_count": result.ends, "failures": result.failures, "pcm_cells": points.count,
        "dropped": result.dropped, "windows": windows, "matched": matched, "aligned": aligned.count,
        "ambiguous": ambiguous, "mismatches": matched - aligned.count, "restarts": restart,
        "max_error_ms": maxError.map(ms) ?? -1,
        "first_bad_clock_ms": firstBad.map { ms($0.display) } ?? -1,
        "first_bad_audio_ms": firstBad.map { ms($0.audio) } ?? -1,
        "first_aligned_ms": aligned.first.map(ms) ?? -1,
        "last_aligned_ms": aligned.last.map(ms) ?? -1,
        "max_gap_ms": gaps.max().map(ms) ?? -1, "clock_regressions": result.regressions,
        "pause_count": result.pauses, "pts_jumps": jumps, "range_reopens": result.reopens.count,
        "range_ignored": result.ignored.count, "tap_path": result.trackTap ? 2 : 1,
        "tap_callbacks": result.calls, "tap_format": result.format,
        "tap_osstatus": result.sourceStatus,
      ]
    }
  }
#endif
