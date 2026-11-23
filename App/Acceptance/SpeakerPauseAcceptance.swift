#if DEBUG && AUDIO_CLOCK_ACCEPTANCE && LIVE_MUSIC_ACCEPTANCE
  import AVFoundation
  import Foundation
  import UIKit

  extension AudioClockAcceptance {
    static func runSpeakerPause(
      _ input: [String: String], runID: UUID, documents: URL, store: PlayerStore,
      native: NativePlayer
    ) async throws {
      guard
        Set(input.keys) == [
          "run_id", "scenario", "version", "nonce", "artist", "album", "deadline_unix_ms",
          "in_app_budget_ms",
        ], input["run_id"].flatMap(UUID.init(uuidString:)) == runID, input["version"] == "1",
        input["scenario"] == "real-music-speaker-pause", input["in_app_budget_ms"] == "180000",
        let nonce = input["nonce"].flatMap(UUID.init(uuidString:)),
        let artist = input["artist"], let album = input["album"],
        (1...128).contains(artist.count), (1...128).contains(album.count),
        let ms = input["deadline_unix_ms"].flatMap(Int64.init),
        store.active == nil, store.current == nil,
        native.measureAudioItem == nil, native.measureAudioItemBeforeInsertion == nil
      else { throw ClientError.invalidResponse }
      let end = Date(timeIntervalSince1970: Double(ms) / 1000)
      guard (180...600).contains(end.timeIntervalSinceNow) else { throw CancellationError() }
      let deadline = min(end.addingTimeInterval(-120), Date().addingTimeInterval(180))
      let current: @MainActor @Sendable () -> Bool = { !Task.isCancelled && Date() < deadline }
      let idle = UIApplication.shared.isIdleTimerDisabled
      try native.beginAudioClockOutput()
      UIApplication.shared.isIdleTimerDisabled = true
      defer {
        if let lease = store.transportAcceptanceLease() {
          _ = store.retireTransportAcceptance(owned: lease)
        }
        native.endAudioClockOutput()
        UIApplication.shared.isIdleTimerDisabled = idle
      }
      var passes = [[String: Any]]()
      var errorCode = 0
      do {
        let client = try await TransportAcceptance.realMusicClient(isCurrent: current)
        try await client.verifyIdentity()
        let (library, _, songs) = try await exactAlbum(
          client: client, artist: artist, album: album, current: current)
        guard current(), let song = songs.first, song.kind == "Audio", song.duration > 45 else {
          throw ClientError.invalidResponse
        }
        await store.enterFixture(service: client)
        guard current(), await store.browser?.admitPlaybackLibrary(library.id) == true,
          store.queue.entries.isEmpty, store.repeatMode == .off, !store.shuffleEnabled,
          let selection = store.playbackSelection([song], library: library.id)
        else { throw ClientError.invalidResponse }
        store.quality(.high)
        let cue = try SpeakerClockCue()
        for hold in [false, true] {
          try Task.checkCancellation()
          let data = try await speakerPass(
            hold: hold, selection: selection, cue: cue, store: store,
            native: native, deadline: deadline)
          passes.append(data)
          try await Task.sleep(for: .milliseconds(450))
        }
      } catch {
        errorCode = (error as NSError).code
        if errorCode == 0 { errorCode = -1 }
      }
      let report: [String: Any] = [
        "run_id": runID.uuidString, "nonce": nonce.uuidString,
        "version": 1, "scenario": "real-music-speaker-pause", "error": errorCode, "passes": passes,
      ]
      try TransportControlFiles.publish(
        JSONSerialization.data(withJSONObject: report), in: documents, runID: runID)
      try await retireAcknowledgedReport(
        in: documents, runID: runID, nonce: nonce, deadline: deadline)
    }

    private static func speakerPass(
      hold: Bool, selection: PlaybackSelection, cue: SpeakerClockCue, store: PlayerStore,
      native: NativePlayer, deadline: Date
    ) async throws -> [String: Any] {
      let origin = ProcessInfo.processInfo.systemUptime
      func tick(_ time: Double) -> Int { Int(((time - origin) * 1000).rounded()) }
      var anchors = [[Int]]()
      var cues = [Int]()
      var holdStart: Double?
      var holdEnd: Double?
      var frozen = [[Int]]()
      var playingSamples = 0
      store.playSelection(selection)
      defer { if store.playbackRequested { store.pause() } }
      guard let occurrence = store.current?.id else { throw ClientError.invalidResponse }
      while Date() < deadline, !Task.isCancelled {
        let now = ProcessInfo.processInfo.systemUptime
        guard store.current?.id == occurrence, store.phase != .failed, now - origin < 53 else {
          throw ClientError.invalidResponse
        }
        let readout = native.queueReadout
        if readout.occurrence == occurrence {
          let display = store.playbackPosition
          guard display.isFinite, readout.seconds.isFinite, display >= 0,
            readout.timeOrigin == 0, anchors.count < 650
          else { throw ClientError.invalidResponse }
          if store.playing, readout.timeControlStatus == AVPlayer.TimeControlStatus.playing.rawValue
          {
            guard AudioClockRoute.current == AudioClockRoute.speaker,
              native.audioClockOutputEnabled,
              AVAudioSession.sharedInstance().outputVolume > 0
            else { throw ClientError.invalidResponse }
            playingSamples += 1
            let value = Int((display * 1000).rounded())
            anchors.append([tick(now), value])
            if (cues.isEmpty && display >= 2) || (cues.count == 1 && display >= 36) {
              cues.append(tick(try cue.schedule()))
            }
            if hold, holdStart == nil, display >= 17 {
              store.pause()
              holdStart = ProcessInfo.processInfo.systemUptime
            }
            if display >= 38, cues.count == 2, !hold || holdEnd != nil {
              guard !hold || frozen.count >= 12 else { throw ClientError.invalidResponse }
              return [
                "paused": hold, "cues_ms": cues, "anchors": anchors,
                "playing_samples": playingSamples, "frozen": frozen,
                "hold_ms": Int((((holdEnd ?? 0) - (holdStart ?? 0)) * 1000).rounded()),
              ]
            }
          }
          if let holdStart, holdEnd == nil {
            if now - holdStart > 0.35,
              readout.timeControlStatus == AVPlayer.TimeControlStatus.paused.rawValue
            {
              frozen.append([
                Int((readout.seconds * 1000).rounded()), Int((display * 1000).rounded()),
              ])
            }
            if now - holdStart >= 3 {
              holdEnd = now
              store.play()
            }
          }
        }
        try await Task.sleep(for: .milliseconds(80))
      }
      throw CancellationError()
    }
  }

  @MainActor private final class SpeakerClockCue {
    private let player: AVAudioPlayer
    init() throws {
      let rate = 24_000
      let slot = rate / 8
      let sequence = [1_300, 2_900, 2_900, 1_300, 2_900]
      let frames = slot * sequence.count
      var data = Data()
      func tag(_ value: String) { data.append(contentsOf: value.utf8) }
      func write<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
      }
      tag("RIFF")
      write(UInt32(36 + frames * 2))
      tag("WAVEfmt ")
      write(UInt32(16))
      write(UInt16(1))
      write(UInt16(1))
      write(UInt32(rate))
      write(UInt32(2 * rate))
      write(UInt16(2))
      write(UInt16(16))
      tag("data")
      write(UInt32(frames * 2))
      for i in 0..<frames {
        let j = i % slot
        let envelope = min(1, max(0, Double(min(j, slot - rate / 40 - j)) / 100))
        let angle = 2 * Double.pi * Double(sequence[i / slot] * j) / Double(rate)
        write(Int16(8_000 * envelope * sin(angle)))
      }
      player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
      guard player.prepareToPlay() else { throw ClientError.invalidResponse }
    }
    func schedule() throws -> Double {
      player.currentTime = 0
      guard player.prepareToPlay() else { throw ClientError.invalidResponse }
      let before = ProcessInfo.processInfo.systemUptime
      let device = player.deviceCurrentTime
      let after = ProcessInfo.processInfo.systemUptime
      guard after - before < 0.02, player.play(atTime: device + 0.18) else {
        throw ClientError.invalidResponse
      }
      return (before + after) / 2 + 0.18
    }
  }
#endif
