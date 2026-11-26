#if DEBUG && LIVE_MUSIC_ACCEPTANCE && AUDIO_CLOCK_ACCEPTANCE
  import AVFoundation
  import Foundation
  import SwiftUI

  struct QueueResumeAcceptance: View {
    let run: UUID
    let operation: String
    let deadline: Date
    let native: NativePlayer
    @State private var result: String?

    private var directory: URL {
      FileManager.default.temporaryDirectory.appendingPathComponent(
        "QueueResume-\(run.uuidString)", isDirectory: true)
    }
    private func checkTime() throws {
      try Task.checkCancellation()
      guard Date.now < deadline, deadline.timeIntervalSinceNow <= 1800 else {
        throw CancellationError()
      }
    }
    var body: some View {
      Group {
        if let result {
          Text(result).accessibilityIdentifier("queue-resume-result")
        } else {
          ProgressView()
        }
      }.task {
        do {
          try checkTime()
          switch operation {
          case "prepare":
            if let failure = try await calibrateMeter() {
              result = failure
              return
            }
            try await prepare()
            result = "prepared"
          case "cleanup":
            try Self.clean(run: run)
            result = "clean"
          case "one", "many":
            result = try await measure()
          default: throw ClientError.invalidResponse
          }
        } catch {
          let detail = ConnectionStepError(step: .restoration, error: error)
          result = "failed \(detail.category.rawValue) \(detail.code ?? 0)"
        }
      }
    }
    private var account: Connection {
      get throws {
        Connection(
          server: try ServerAddress("https://fixture.invalid"), userID: "benchmark",
          username: "Fixture")
      }
    }
    private func client() async throws -> JellyfinClient {
      try await TransportAcceptance.realMusicClient(isCurrent: {
        !Task.isCancelled && Date.now < deadline
      })
    }
    private func calibrateMeter() async throws -> String? {
      guard
        let tone = Bundle.main.url(
          forResource: "tone", withExtension: "wav", subdirectory: "Fixtures")
      else { throw ClientError.invalidResponse }
      let item = AVPlayerItem(url: tone)
      let meter = try await AudioClockTap.installForOnset(on: item)
      let player = AVQueuePlayer()
      player.isMuted = true
      defer {
        player.pause()
        player.removeAllItems()
        meter.invalidate()
      }
      player.insert(item, after: nil)
      guard
        await player.seek(
          to: CMTime(seconds: 12, preferredTimescale: 600), toleranceBefore: .zero,
          toleranceAfter: .zero)
      else {
        throw PlaybackProblem.seek
      }
      meter.armOnset()
      player.play()
      let end = ContinuousClock.now.advanced(by: .seconds(5))
      while ContinuousClock.now < end {
        try checkTime()
        if meter.firstSignalUptime != nil, item.currentTime().seconds > 12.03 { return nil }
        try await Task.sleep(for: .milliseconds(10))
      }
      return
        "failed calibration buffers=\(meter.measuredBuffers) callbacks=\(meter.processCallbacks) format=\(meter.formatStatus) source=\(meter.sourceStatus)"
    }
    private func prepare() async throws {
      let files = FileManager.default
      guard !files.fileExists(atPath: directory.path) else { throw ClientError.invalidResponse }
      let service = try await client()
      try await service.verifyIdentity()
      guard let library = try await service.musicLibraries(refresh: true).first else {
        throw PlaybackProblem.noSource
      }
      var seen = Set<String>()
      var entries: [QueueEntry] = []
      var offset = 0
      while entries.count < 7_789 && offset < 8_040 {
        try checkTime()
        let page = try await service.catalogPage(
          CatalogQuery(library: library.id, category: .songs, offset: offset))
        guard page.rawCount > 0 else { throw PlaybackProblem.noSource }
        for song in page.items where entries.count < 7_789 && seen.insert(song.id).inserted {
          entries.append(QueueEntry(song, libraryID: library.id))
        }
        offset += page.rawCount
      }
      guard entries.count == 7_789,
        let cursor = entries.indices.dropFirst(entries.count / 2).first(where: {
          (45...420).contains(entries[$0].track.duration)
        })
      else { throw PlaybackProblem.noSource }
      let current = QueueEntry(entries[cursor].track, id: run, libraryID: library.id)
      entries[cursor] = current
      entries.insert(QueueEntry(current.track, libraryID: library.id), at: cursor + 1)
      try files.createDirectory(at: directory, withIntermediateDirectories: false)
      for (name, state) in [
        ("one", QueueState(entries: [current], position: 12)),
        ("many", QueueState(entries: entries, index: cursor, position: 12)),
      ] {
        try await LibraryStorage(directory: directory.appendingPathComponent(name)).save(
          state, account: account.id)
      }
    }
    private func measure() async throws -> String {
      let files = FileManager.default
      let base = directory.appendingPathComponent(operation)
      let work = directory.appendingPathComponent("sample")
      guard !files.fileExists(atPath: work.path) else { throw ClientError.invalidResponse }
      try files.copyItem(at: base, to: work)
      defer { try? files.removeItem(at: work) }
      let storage = try LibraryStorage(directory: work)
      let account = try account
      try await storage.saveConnections([account])
      let vault = MemoryVault()
      await vault.write("fixture", account: account.id)
      let start = DispatchTime.now().uptimeNanoseconds
      func ms(_ instant: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Int {
        Int((instant - start) / 1_000_000)
      }
      let service = try await client()
      let store = PlayerStore(
        storage: storage, vault: vault, driver: native, deviceID: "fixture",
        factory: { _, _ in service })
      var tap: AudioClockTap?
      native.measureAudioItem = { item, prepared in
        if prepared.entry.id == run { tap = try await AudioClockTap.installForOnset(on: item) }
      }
      defer {
        if let owner = store.transportAcceptanceLease() {
          _ = store.retireTransportAcceptance(owned: owner)
        }
        native.measureAudioItem = nil
        tap?.invalidate()
        native.stop()
      }
      await store.bootstrap()
      let ready = ms()
      guard store.current?.id == run, store.phase == .paused, !store.playbackRequested,
        store.queue.position == 12, native.queueReadout.queued.isEmpty,
        store.hasRemainingQueue == (operation == "many")
      else { throw ClientError.invalidResponse }
      store.play()
      var clock: Int?
      while ms() < 30_000 {
        try checkTime()
        let readout = native.queueReadout
        if readout.occurrence == run, !readout.preparing, !readout.seeking,
          readout.absoluteSeconds >= 11.95
        {
          tap?.armOnset()
          if clock == nil, store.playing, readout.absoluteSeconds > 12.03 { clock = ms() }
        }
        if let onset = tap?.firstSignalUptime, let clock {
          return "ok \(ready) \(ms(onset)) \(clock) \(ProcessInfo.processInfo.processIdentifier)"
        }
        if store.phase == .failed {
          throw store.lastPlaybackFailure?.detail
            ?? ConnectionStepError(step: .playbackAudio, error: PlaybackProblem.nativeStart)
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      return
        "failed onset signal=\(tap?.firstSignalUptime != nil) clock_ms=\(clock ?? -1) buffers=\(tap?.measuredBuffers ?? 0) callbacks=\(tap?.processCallbacks ?? 0) format=\(tap?.formatStatus ?? -1) source=\(tap?.sourceStatus ?? -1)"
    }
    static func clean(run: UUID) throws {
      let files = FileManager.default
      let root = files.temporaryDirectory.appendingPathComponent(
        "QueueResume-\(run.uuidString)", isDirectory: true)
      guard files.fileExists(atPath: root.path) else { return }
      func children(_ directory: URL) throws -> [URL] {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
          throw ClientError.invalidResponse
        }
        return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      }
      let account = Connection(
        server: try ServerAddress("https://fixture.invalid"), userID: "benchmark",
        username: "Fixture")
      let names: Set<String> = [
        account.id + ".json", account.id + ".progress.json", account.id + ".recent.json",
        "connections.json",
      ]
      for folder in try children(root) {
        guard ["one", "many", "sample"].contains(folder.lastPathComponent) else {
          throw ClientError.invalidResponse
        }
        for file in try children(folder) {
          let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          guard names.contains(file.lastPathComponent), values.isRegularFile == true,
            values.isSymbolicLink != true
          else { throw ClientError.invalidResponse }
        }
      }
      try files.removeItem(at: root)
      guard !files.fileExists(atPath: root.path) else { throw ClientError.invalidResponse }
    }
  }
#endif
