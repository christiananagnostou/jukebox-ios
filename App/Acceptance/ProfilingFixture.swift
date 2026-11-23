import Darwin
import Foundation
import UIKit
import os

actor ProfilingCatalog: MusicCatalogServing {
  let fixture: FixtureCatalog
  private var counts: [String: Int] = [:]
  init(_ fixture: FixtureCatalog) { self.fixture = fixture }
  private func count(_ kind: String) { counts[kind, default: 0] += 1 }
  #if DEBUG
    private var snapshotGate: ProfilingSnapshotGate?
    func holdNextSnapshot(_ gate: ProfilingSnapshotGate) { snapshotGate = gate }
  #endif
  func snapshot() async -> [String: Int] {
    #if DEBUG
      if let gate = snapshotGate {
        snapshotGate = nil
        await gate.wait()
      }
    #endif
    return counts
  }
  func verifyIdentity() async throws {
    count("identity")
    try await fixture.verifyIdentity()
  }
  func validate(ids: [String]) async throws -> [MusicItem] {
    count("authorization")
    return try await fixture.validate(ids: ids)
  }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    count("source")
    return try await fixture.media(
      library: library, trackID: trackID, quality: quality, isCurrent: isCurrent)
  }
  func artwork(item: MusicItem) async throws -> Data? {
    count("artwork")
    return try await fixture.artwork(item: item)
  }
  func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
    count("libraries")
    return try await fixture.musicLibraries(refresh: refresh)
  }
  func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
    let kind = query.shelf == nil ? (query.search.isEmpty ? "browse" : "search") : "shelf"
    count(kind + query.category.rawValue)
    return try await fixture.catalog(query)
  }
  func albumTracks(library: String, album: String) async throws -> [MusicItem] {
    count("albumTracks")
    return try await fixture.albumTracks(library: library, album: album)
  }
  func albumDetail(library: String, album: MusicItem) async throws -> MusicAlbumPage {
    count("albumDetail")
    return try await fixture.albumDetail(library: library, album: album)
  }
  func artistDetail(library: String, artist: MusicItem) async throws -> MusicItem {
    count("artistDetail")
    return try await fixture.artistDetail(library: library, artist: artist)
  }
}

@MainActor final class ProfilingRun {
  static let browseNotification = Notification.Name("JukeboxInventedProfilingBrowse")
  static var isEnabled: Bool {
    let args = ProcessInfo.processInfo.arguments
    return args.contains("--fixture")
      && args.contains { value in
        value.hasPrefix("--profile-fixture=")
          && UUID(uuidString: String(value.dropFirst("--profile-fixture=".count))) != nil
      }
  }
  static func cleanup(id: UUID) throws {
    let files = FileManager.default
    try ProfilingFixtureFiles.cleanup(
      support: files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
      documents: files.urls(for: .documentDirectory, in: .userDomainMask)[0], runID: id)
  }
  enum Phase: String, Codable { case settle, idle, browse, foreground, background, finished }
  struct Sample: Codable {
    let elapsed: Double
    let phase: Phase
    let cpuSeconds: Double
    let residentBytes: UInt64?
    let physicalBytes: UInt64?
    let thermal: Int
    let charging: Int
    let battery: Float
    let appState: Int
    let logicalCalls: [String: Int]
    let playbackPhase: String?
    let position: Double?
    let queueIndex: Int?
    let native: ProfilingPlayback?
  }
  let id: UUID
  let catalog: ProfilingCatalog
  private let started = ProcessInfo.processInfo.systemUptime
  private let signposter = OSSignposter(subsystem: "dev.jukebox.ios.profile", category: "Workload")
  private var phase = Phase.settle
  private var samples: [Sample] = []
  private var sampler: Task<Void, Never>?
  private var command: DispatchSourceSignal?
  private var stopCommand: DispatchSourceSignal?
  private var commandIndex = 0
  private weak var store: PlayerStore?
  private weak var native: NativePlayer?
  private let backgroundUsingSettings: Bool
  private var idleTimer = ProfilingIdleTimerState()
  private var settingsOpenAttempted = false
  private var settingsOpenSucceeded: Bool?
  init(
    id: UUID, fixture: FixtureCatalog, native: NativePlayer, backgroundUsingSettings: Bool = false
  ) {
    self.backgroundUsingSettings = backgroundUsingSettings
    self.native = native
    self.id = id
    catalog = ProfilingCatalog(fixture)
  }
  func start(_ store: PlayerStore) {
    guard sampler == nil, store.isFixture else { return }
    self.store = store
    if idleTimer.begin(current: UIApplication.shared.isIdleTimerDisabled) {
      UIApplication.shared.isIdleTimerDisabled = true
    }
    signal(SIGUSR1, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    source.setEventHandler { [weak self, weak store] in
      Task { @MainActor in
        guard let self, let store, store.isFixture else { return }
        self.commandIndex += 1
        switch self.commandIndex {
        case 1:
          store.pause()
          self.mark(.idle)
        case 2:
          self.mark(.browse)
          NotificationCenter.default.post(name: Self.browseNotification, object: nil)
        case 3: self.play(store)
        case 4:
          self.play(store)
          if self.backgroundUsingSettings { await self.openOwnSettings(store) }
        default:
          store.pause()
          await self.finish()
        }
      }
    }
    command = source
    source.resume()
    signal(SIGUSR2, SIG_IGN)
    let stop = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
    stop.setEventHandler { [weak self, weak store] in
      Task { @MainActor in
        if store?.isFixture == true { store?.pause() }
        await self?.finish()
      }
    }
    stopCommand = stop
    stop.resume()
    UIDevice.current.isBatteryMonitoringEnabled = true
    sampler = Task { [weak self] in
      for _ in 0..<360 {
        guard let self else { return }
        guard !Task.isCancelled else {
          self.restoreIdleTimer()
          return
        }
        await self.sample()
        do { try await Task.sleep(for: .seconds(1)) } catch {
          self.restoreIdleTimer()
          return
        }
      }
      await self?.finish()
    }
  }
  func mark(_ value: Phase) {
    phase = value
    switch value {
    case .idle: signposter.emitEvent("Idle")
    case .browse: signposter.emitEvent("Browse")
    case .foreground: signposter.emitEvent("Playback")
    default: break
    }
  }
  func play(_ store: PlayerStore) {
    guard phase != .finished, self.store === store, store.isFixture,
      let origin = store.playbackOrigin(library: store.browser?.authorizedLibrary)
    else { return }
    mark(.foreground)
    store.playAlbum(.fixtureAlbum, origin: origin)
  }
  private func openOwnSettings(_ store: PlayerStore) async {
    guard !settingsOpenAttempted, phase == .foreground, self.store === store, store.isFixture else {
      return
    }
    do { try await Task.sleep(for: .seconds(2)) } catch { return }
    guard !Task.isCancelled, phase == .foreground, self.store === store, store.isFixture,
      let url = URL(string: UIApplication.openSettingsURLString)
    else { return }
    settingsOpenAttempted = true
    let opened = await UIApplication.shared.open(url)
    guard !Task.isCancelled, phase == .foreground, self.store === store, store.isFixture else {
      return
    }
    settingsOpenSucceeded = opened
  }
  private func restoreIdleTimer() {
    if let prior = idleTimer.restore() { UIApplication.shared.isIdleTimerDisabled = prior }
  }
  func finish() async {
    defer { restoreIdleTimer() }
    guard phase != .finished else { return }
    await sample()
    phase = .finished
    sampler?.cancel()
    sampler = nil
    command?.cancel()
    command = nil
    stopCommand?.cancel()
    stopCommand = nil
    signposter.emitEvent("Finished")
    struct Report: Codable {
      let marker: String
      let runID: UUID
      let optimization: String
      let os: String
      let samples: [Sample]
      let settingsOpenAttempted: Bool
      let settingsOpenSucceeded: Bool?
    }
    #if DEBUG
      let optimization = "Debug"
    #else
      let optimization = "Release"
    #endif
    let report = Report(
      marker: "JUKEBOX-PROFILE-1", runID: id, optimization: optimization,
      os: ProcessInfo.processInfo.operatingSystemVersionString, samples: samples,
      settingsOpenAttempted: settingsOpenAttempted, settingsOpenSucceeded: settingsOpenSucceeded)
    if let data = try? JSONEncoder().encode(report), data.count <= 300_000 {
      let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("profiling-report.json")
      try? data.write(
        to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    UIDevice.current.isBatteryMonitoringEnabled = false
  }
  #if DEBUG
    static func checkRetirement(
      store: PlayerStore, native: NativePlayer, fixture: FixtureCatalog, runID: UUID
    ) async {
      let run = ProfilingRun(id: runID, fixture: fixture, native: native)
      run.store = store
      await run.sample()
      let initial = run.samples.count
      let gate = ProfilingSnapshotGate()
      await run.catalog.holdNextSnapshot(gate)
      let pending = Task { await run.sample() }
      var entered = false
      for _ in 0..<100 {
        entered = await gate.entered
        if entered { break }
        try? await Task.sleep(for: .milliseconds(5))
      }
      await store.logout()
      await gate.release()
      await pending.value
      let result: [String: Any] = [
        "run_id": runID.uuidString, "finished": true, "snapshot_suspended": entered,
        "before": initial, "after": run.samples.count,
        "passed": entered && initial == 1 && run.samples.count == initial,
      ]
      let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("development-report.json")
      if let data = try? JSONSerialization.data(withJSONObject: result) {
        try? data.write(
          to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      }
    }
  #endif
  private func sample() async {
    guard !Task.isCancelled, store?.isFixture == true else {
      restoreIdleTimer()
      return
    }
    guard samples.count < 365 else { return }
    let calls = await catalog.snapshot()
    guard !Task.isCancelled, store?.isFixture == true else {
      restoreIdleTimer()
      return
    }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let cpu =
      Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    let state = UIApplication.shared.applicationState
    samples.append(
      Sample(
        elapsed: ProcessInfo.processInfo.systemUptime - started,
        phase: phase == .foreground && state == .background ? .background : phase,
        cpuSeconds: cpu, residentBytes: result == KERN_SUCCESS ? info.resident_size : nil,
        physicalBytes: result == KERN_SUCCESS ? info.phys_footprint : nil,
        thermal: ProcessInfo.processInfo.thermalState.rawValue,
        charging: UIDevice.current.batteryState.rawValue, battery: UIDevice.current.batteryLevel,
        appState: state.rawValue, logicalCalls: calls,
        playbackPhase: store?.phase.rawValue, position: store?.queue.position,
        queueIndex: store?.queue.index, native: native?.profilingReadout))
  }
}

struct ProfilingPlayback: Codable {
  let clock: Double?
  let rate: Float
  let timeControl: Int
  let routeTypes: [String]
}

#if DEBUG
  actor ProfilingSnapshotGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
      entered = true
      if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() {
      released = true
      continuation?.resume()
      continuation = nil
    }
  }
#endif
