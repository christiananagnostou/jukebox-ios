import AVFoundation
import Foundation
import MediaPlayer
import UIKit

@MainActor final class NativePlayer: PlaybackDriving {
  var onEvent: (@MainActor (DriverEvent) -> Void)?
  var onRemote: (@MainActor (RemoteAction) -> Void)?
  #if DEBUG && AUDIO_CLOCK_ACCEPTANCE
    private var measuringFixtureOutput = false
    func beginAudioClockOutput() throws {
      guard muted, !measuringFixtureOutput, player.currentItem == nil else {
        throw ClientError.invalidResponse
      }
      measuringFixtureOutput = true
      player.isMuted = false
    }
    func endAudioClockOutput() {
      measuringFixtureOutput = false
      player.isMuted = muted
    }
    var measureAudioItem: (@MainActor (AVPlayerItem, PreparedEntry) async throws -> Void)?
    var measureAudioItemBeforeInsertion: (@MainActor (AVPlayerItem, PreparedEntry) throws -> Void)?
    var audioClockOutputEnabled: Bool {
      measuringFixtureOutput && !player.isMuted && player.volume > 0
    }
  #endif
  private var player = AVQueuePlayer()
  private let session = MusicAudioSession()
  private var revision = UUID()
  private let sessionState = PlaybackAudioSessionState()
  private let muted: Bool
  private var entries: [ObjectIdentifier: PreparedEntry] = [:]
  private var sourceOrdinal = 0
  private var sourceOrdinals: [ObjectIdentifier: Int] = [:]
  private var preparationDiagnostic: DiagnosticContext?
  private var currentObserver: NSKeyValueObservation?
  private var itemObserver: NSKeyValueObservation?
  private var durationObserver: NSKeyValueObservation?
  private var timeObserver: Any?
  private var notificationObservers: [NSObjectProtocol] = []
  private let systemCommands = SystemPlaybackCommands()
  private var progress = PlaybackProgressDeadline()
  private var watchdog: Task<Void, Never>?
  private struct PreparedPresentation {
    let entry: QueueEntry
    let authority: PlaybackAuthority
    let data: Data?
    let image: MPMediaItemArtwork?
    func matches(_ ready: PreparedEntry) -> Bool {
      ready.entry == entry && ready.authority == authority
    }
  }
  private enum Transport {
    case idle
    case preparing(occurrence: UUID, position: Double, presentation: PreparedPresentation?)
    case active(requested: Bool)
    case seeking(requested: Bool, target: Double)
    case failed
    var requested: Bool {
      switch self {
      case .preparing: true
      case .active(let requested), .seeking(let requested, _): requested
      case .idle, .failed: false
      }
    }
  }
  private var transport: Transport = .idle
  private var seekRequest = UUID()
  private var graphID = UUID()
  private var playerObserver: NSKeyValueObservation?
  private var timeControlObserver: NSKeyValueObservation?
  private var endObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
  private var endedItem: ObjectIdentifier?
  private var observedItem: AVPlayerItem?
  #if DEBUG
    struct PublicationMeasurement {
      let runID: UUID
      var callbacks = 0
      var positions = 0
      var timelines = 0
    }
    private var publicationMeasurement: PublicationMeasurement?
    func beginMeasurement(_ runID: UUID) {
      publicationMeasurement = PublicationMeasurement(runID: runID)
    }
    func measurement(_ runID: UUID) -> PublicationMeasurement? {
      publicationMeasurement.flatMap { $0.runID == runID ? $0 : nil }
    }
    func endMeasurement(_ runID: UUID) {
      if publicationMeasurement?.runID == runID { publicationMeasurement = nil }
    }
    private func countPublication(_ field: WritableKeyPath<PublicationMeasurement, Int>) {
      if let count = publicationMeasurement?[keyPath: field], count < 10_000 {
        publicationMeasurement?[keyPath: field] = count + 1
      }
    }
    private(set) var itemObservationInstallations = 0
    private(set) var nowPlayingPublications = 0
    private(set) var artworkClearingPublications = 0
    var beforeStartInsertionForCheck: (@MainActor () async -> Void)?
    private(set) var lastNowPlayingProjection: (clock: Double, rate: Float, uptime: Double)?
    func recheckCurrentItem() { changedItem() }
    func receiveRemoteForCheck(_ action: RemoteAction) {
      handleRemote(action, owner: systemCommands.receipt)
    }
    func receiveRouteChangeForCheck(_ reason: UInt?) { routeChanged(reason: reason) }
    var remoteSourceRevisionForCheck: UUID { revision }
    func remoteDeliveryForCheck() -> @MainActor @Sendable (RemoteAction) -> Void {
      let receipt = systemCommands.receipt
      return { [weak self] action in self?.handleRemote(action, owner: receipt) }
    }
    var artworkPreparationReadout: (cached: Int, authorized: Int, decoded: Bool) {
      (
        entries.values.filter { $0.artwork != nil }.count,
        entries.values.filter { $0.authority != nil }.count,
        preparedArtwork != nil
      )
    }
    func preparedArtworkReady(for occurrence: UUID) -> Bool {
      guard let preparedArtwork else { return false }
      return player.items().contains {
        ObjectIdentifier($0) == preparedArtwork.item
          && entries[preparedArtwork.item]?.entry.id == occurrence
      }
    }
  #endif
  #if DEBUG && LIVE_MUSIC_ACCEPTANCE
    struct LiveMusicReadout {
      let timeControl: Int
      let waiting: Int
      let transfers: [PlaybackTransferEvidence]
    }
    func liveMusicReadout(for occurrence: UUID) -> LiveMusicReadout? {
      guard let item = player.currentItem,
        entries[ObjectIdentifier(item)]?.entry.id == occurrence
      else { return nil }
      let now = ProcessInfo.processInfo.systemUptime
      let transfers: [PlaybackTransferEvidence]
      if let url = bridgeURLs[ObjectIdentifier(item)], let mediaBridge {
        transfers = mediaBridge.evidence(for: url, at: now)
      } else {
        transfers = []
      }
      let waiting: Int
      switch player.reasonForWaitingToPlay {
      case nil: waiting = 0
      case .toMinimizeStalls: waiting = 1
      case .evaluatingBufferingRate: waiting = 2
      case .noItemToPlay: waiting = 3
      default: waiting = 4
      }
      return LiveMusicReadout(
        timeControl: player.timeControlStatus.rawValue, waiting: waiting, transfers: transfers)
    }
  #endif
  private var preparingStart: Bool { if case .preparing = transport { true } else { false } }
  private var seeking: Bool { if case .seeking = transport { true } else { false } }
  private var intent: Bool { transport.requested }
  private var pendingStartPosition: Double {
    if case .preparing(_, let position, _) = transport { position } else { 0 }
  }
  private let tailTransport: any HTTPTransport
  private let tailFiles: PlaybackTailFiles?
  private var lastClock = 0.0
  private var lastID: UUID?
  private var retainedFailureItem: AVPlayerItem?
  private var mediaBridge: MediaHTTPBridge?
  private var bridgeURLs: [ObjectIdentifier: URL] = [:]
  private var artworkRevision = UUID()
  private var artworkTask: Task<Void, Never>?
  private var nowPlayingArtwork: MPMediaItemArtwork?
  private var nowPlayingArtworkData: Data?
  private var artworkEntry: PreparedEntry?
  private var currentArtworkOwner: ArtworkOwner?
  private var preparedArtwork:
    (item: ObjectIdentifier, ready: PreparedEntry, image: MPMediaItemArtwork)?
  private var preparedArtworkTask: Task<Void, Never>?
  private var preparedArtworkRevision = UUID()
  private struct NowPlayingSignature: Equatable {
    let occurrence: UUID
    let rate: Float
    let duration: Double?
    let artwork: UUID
    let hasArtwork: Bool
    let timeControl: Int
    let seeking: Bool
  }
  private var nowPlayingSignature: NowPlayingSignature?
  init(
    muted: Bool = false,
    tailTransport: any HTTPTransport = LiveHTTP(maximumBytes: 500_000, resourceTimeout: 12),
    tailDirectory: URL? = nil, tailsEnabled: Bool = true
  ) {
    self.tailTransport = tailTransport
    self.tailFiles = tailsEnabled ? try? PlaybackTailFiles(directory: tailDirectory) : nil
    self.muted = muted
    installPlayerObservers()
    notificationObservers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.mediaServicesReset() }
      })
    notificationObservers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard
          let context = note.userInfo?[AVAudioSession.deactivationContextKey]
            as? AVAudioSession.DeactivationContext
        else { return }
        MainActor.assumeIsolated { self?.sessionDeactivated(source: context.source) }
      })
    notificationObservers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
      ) { [weak self] note in
        let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        MainActor.assumeIsolated { self?.routeChanged(reason: reason) }
      })
  }
  private func installPlayerObservers() {
    let observed = player
    let graph = graphID
    #if DEBUG && AUDIO_CLOCK_ACCEPTANCE
      observed.isMuted = muted && !measuringFixtureOutput
    #else
      observed.isMuted = muted
    #endif
    observed.allowsExternalPlayback = false
    currentObserver = observed.observe(\.currentItem, options: [.new]) {
      [weak self, weak observed] _, _ in
      Task { @MainActor in
        guard let self, self.graphID == graph, self.player === observed else { return }
        self.changedItem()
      }
    }
    playerObserver = observed.observe(\.status, options: [.new]) {
      [weak self, weak observed] _, _ in
      Task { @MainActor in
        guard let self, self.graphID == graph, self.player === observed else { return }
        self.checkFailure()
      }
    }
    timeControlObserver = observed.observe(\.timeControlStatus, options: [.new]) {
      [weak self, weak observed] _, _ in
      Task { @MainActor in
        guard let self, self.graphID == graph, self.player === observed else { return }
        if self.intent, !self.preparingStart,
          self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
          let id = self.currentOccurrence
        {
          self.onEvent?(.state(id, .waiting))
        }
        self.publish()
      }
    }
    timeObserver = observed.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
    ) { [weak self, weak observed] _ in
      Task { @MainActor in
        guard let self, self.graphID == graph, self.player === observed else { return }
        #if DEBUG
          self.countPublication(\.callbacks)
        #endif
        self.tick()
      }
    }
  }
  private func rebuildFailedPlayer() {
    let previous = player
    graphID = UUID()
    currentObserver = nil
    playerObserver = nil
    timeControlObserver = nil
    itemObserver = nil
    durationObserver = nil
    if let timeObserver { previous.removeTimeObserver(timeObserver) }
    timeObserver = nil
    previous.pause()
    previous.removeAllItems()
    player = AVQueuePlayer()
    installPlayerObservers()
  }
  private func mediaServicesReset() {
    let occurrence = currentOccurrence
    let requested = intent
    let log =
      player.currentItem.flatMap { entries[ObjectIdentifier($0)]?.diagnostic }
      ?? preparationDiagnostic
    log?.event(.playback, .init(.native, .reset))
    var detail = ConnectionStepError(
      step: .playbackAudio,
      error: NSError(domain: AVFoundationErrorDomain, code: AVError.mediaServicesWereReset.rawValue)
    )
    if requested {
      detail = captureFailure(detail, item: player.currentItem ?? retainedFailureItem, log: log)
    }
    retireSource(replacingGraph: true)
    if let occurrence {
      transport = .failed
      if requested {
        onEvent?(
          .failureDetails(
            occurrence,
            detail))
      }
    }
  }
  private var currentOccurrence: UUID? {
    player.currentItem.flatMap { entries[ObjectIdentifier($0)]?.entry.id }
      ?? lastID ?? { if case .preparing(let id, _, _) = transport { id } else { nil } }()
  }
  private func hasMediaServicesReset(_ error: Error?) -> Bool {
    guard let error else { return false }
    if let detail = error as? ConnectionStepError {
      return detail.diagnosticDomain == .avFoundation && detail.code == -11819
    }
    let native = error as NSError
    return native.domain == AVFoundationErrorDomain
      && native.code == AVError.mediaServicesWereReset.rawValue
  }
  private func routeChanged(reason: UInt?) {
    guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
    onRemote?(.pause)
  }
  func sessionDeactivated(source: AVAudioSession.DeactivationSource) {
    guard source == .system, sessionState.interrupt() else { return }
    onRemote?(.pause)
  }
  func start(_ ready: [PreparedEntry], position: Double) async throws {
    #if DEBUG
      let beforeInsertion = beforeStartInsertionForCheck
      beforeStartInsertionForCheck = nil
    #endif
    let replace = player.status == .failed || hasMediaServicesReset(player.error)
    let presentation: PreparedPresentation?
    let target: Double
    if case .preparing(_, let pending, let accepted) = transport, let accepted {
      guard let first = ready.first, accepted.matches(first) else {
        throw CancellationError()
      }
      presentation = PreparedPresentation(
        entry: accepted.entry, authority: accepted.authority, data: first.artwork,
        image: first.artwork == accepted.data ? accepted.image : nil)
      target = pending
    } else {
      presentation = nil
      target = position.isFinite ? max(0, position) : 0
    }
    retireSource(replacingGraph: replace, presentation: presentation)
    guard let first = ready.first else { throw PlaybackProblem.noSource }
    let occurrence = first.entry.id
    preparationDiagnostic = first.diagnostic
    first.diagnostic?.event(
      .playback,
      .init(.native, .started, source: first.source.diagnosticSource))
    transport = .preparing(occurrence: occurrence, position: target, presentation: presentation)
    let request = UUID()
    revision = request
    installRemoteCommands()
    beginWatchdog(precisePreparation: first.source.preferPreciseTiming, position: target)
    var step = ConnectionStepError.Step.audioSession
    do {
      try await sessionState.activate(request) {
        try await session.activate(owner: request)
      } replacingExpiredPlayer: {
        first.diagnostic?.event(.playback, .init(.audioSession, .reset))
        rebuildFailedPlayer()
      }
      guard revision == request, !Task.isCancelled else { return }
      if player.status == .failed { rebuildFailedPlayer() }
      step = .playbackAudio
      installRemoteCommands()
      if ready.contains(where: { $0.source.usesBridge }) {
        let bridge = MediaHTTPBridge()
        mediaBridge = bridge
        try await bridge.start()
        guard revision == request, !Task.isCancelled else { return }
      }
      let prepared = try await bufferedTail(first, position: pendingStartPosition, request: request)
      guard revision == request, !Task.isCancelled else { return }
      #if DEBUG
        if let beforeInsertion { await beforeInsertion() }
      #endif
      guard revision == request, !Task.isCancelled else { return }
      let inserted: AVPlayerItem?
      #if DEBUG && AUDIO_CLOCK_ACCEPTANCE
        if let measureAudioItem {
          let payload = try makeItem(prepared)
          try await measureAudioItem(payload.item, prepared)
          guard revision == request, !Task.isCancelled else { return }
          inserted = try appendItem(prepared, prepared: payload)
        } else {
          inserted = try appendItem(prepared)
        }
      #else
        inserted = try appendItem(prepared)
      #endif
      guard player.currentItem != nil else {
        throw nativeFailure(inserted, step: .playbackItem)
      }
      changedItem()
      guard revision == request, !Task.isCancelled else { return }
      if let item = player.currentItem {
        var preciseEnd = Double.nan
        let source = entries[ObjectIdentifier(item)]!.source
        let origin = source.timeOrigin
        if pendingStartPosition > origin,
          source.preferPreciseTiming,
          let timing = try? await item.asset.load(.providesPreciseDurationAndTiming, .duration),
          timing.0, timing.1.seconds.isFinite, timing.1.seconds > 0
        {
          preciseEnd = origin + timing.1.seconds
        }
        guard revision == request, player.currentItem === item, !Task.isCancelled else { return }
        var mustSeek = pendingStartPosition > origin + 0.0001
        while mustSeek {
          let seek = seekRequest
          let completed = await player.seek(
            to: CMTime(
              seconds: max(0, Self.seekTarget(pendingStartPosition, duration: preciseEnd) - origin),
              preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
          guard revision == request, player.currentItem === item, !Task.isCancelled else { return }
          if seek == seekRequest {
            guard completed else { throw PlaybackProblem.seek }
            mustSeek = false
          }
        }
      }
      guard revision == request, !Task.isCancelled else { return }
      if let current = player.currentItem, let first = entries[ObjectIdentifier(current)] {
        _ = adoptCurrentArtwork(for: first)
      }
      transport = .active(requested: true)
      player.play()
      changedItem()
      onEvent?(.state(occurrence, .waiting))
      for successor in ready.dropFirst() {
        try await append(successor) { self.revision == request && !Task.isCancelled }
        if !hasPrepared(successor.entry.id) { break }
      }
    } catch {
      guard revision == request, !Task.isCancelled else { throw CancellationError() }
      let detail = captureFailure(
        ConnectionStepError(step: step, error: error),
        item: player.currentItem ?? retainedFailureItem, log: preparationDiagnostic)
      retireSource(
        replacingGraph: player.status == .failed || hasMediaServicesReset(error)
          || detail.category == .expiredAudioSession)
      transport = .failed
      throw detail
    }
  }
  private func bufferedTail(_ ready: PreparedEntry, position: Double, request: UUID) async throws
    -> PreparedEntry
  {
    let source = ready.source
    guard source.serverTimeSeek, position > source.timeOrigin + 0.0001 else { return ready }
    guard let duration = source.serverDuration, duration.isFinite,
      duration > source.timeOrigin, duration - source.timeOrigin <= 5.01,
      let tailFiles
    else { throw ClientError.unavailable }
    let reply = try await tailTransport.send(source.upstreamRequest)
    try Task.checkCancellation()
    guard revision == request else { throw CancellationError() }
    guard reply.status == 200, !reply.data.isEmpty, reply.data.count <= 500_000 else {
      throw ClientError.unavailable
    }
    let path = try tailFiles.write(reply.data)
    var accepted = false
    defer { if !accepted { tailFiles.remove(path) } }
    let actual = try await AVURLAsset(url: path).load(.duration).seconds
    try Task.checkCancellation()
    guard revision == request else { throw CancellationError() }
    guard actual.isFinite, actual > 0,
      abs(actual - (duration - source.timeOrigin)) <= 0.15
    else { throw ClientError.unavailable }
    accepted = true
    return PreparedEntry(
      entry: ready.entry,
      source: MediaSource(
        url: path, quality: source.quality, timeOrigin: source.timeOrigin),
      authority: ready.authority, artwork: ready.artwork, diagnostic: ready.diagnostic)
  }
  func append(
    _ ready: PreparedEntry, isCurrent: @MainActor @Sendable () -> Bool
  ) async throws {
    guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
    guard !hasPrepared(ready.entry.id) else { return }
    guard ready.source.serverTimeSeek else {
      _ = try appendItem(ready)
      return
    }
    guard let predecessor = player.currentItem, let tailFiles else { return }
    let request = revision
    let asset: AVURLAsset
    do {
      guard
        let completed = try await tailFiles.prepareQueued(
          ready.source,
          isCurrent: {
            isCurrent() && self.revision == request && self.player.currentItem === predecessor
          })
      else { return }
      asset = completed
    } catch {
      try Task.checkCancellation()
      guard isCurrent(), revision == request, player.currentItem === predecessor else {
        throw CancellationError()
      }
      ready.diagnostic?.event(.network) {
        .failure(ConnectionStepError(step: .playbackSource, error: error), stage: .source)
      }
      return
    }
    let file = asset.url
    defer {
      if !entries.values.contains(where: { $0.source.url == file }) { tailFiles.remove(file) }
    }
    try Task.checkCancellation()
    guard isCurrent(), revision == request, player.currentItem === predecessor else {
      throw CancellationError()
    }
    let local = MediaSource(
      url: file, quality: ready.source.quality, preferPreciseTiming: true,
      serverDuration: ready.source.serverDuration)
    _ = try appendItem(
      PreparedEntry(
        entry: ready.entry, source: local, authority: ready.authority, artwork: ready.artwork,
        diagnostic: ready.diagnostic), prepared: (AVPlayerItem(asset: asset), file))
  }
  private func makeItem(_ ready: PreparedEntry) throws -> (item: AVPlayerItem, url: URL) {
    let url: URL
    if ready.source.usesBridge {
      guard let mediaBridge else { throw ClientError.unavailable }
      url = try mediaBridge.register(ready.source, diagnostic: ready.diagnostic)
    } else {
      url = ready.source.url
    }
    let item: AVPlayerItem
    if ready.source.preferPreciseTiming {
      let asset = AVURLAsset(
        url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
      item = AVPlayerItem(asset: asset)
    } else {
      item = AVPlayerItem(url: url)
    }
    return (item, url)
  }
  private func appendItem(
    _ ready: PreparedEntry, prepared: (item: AVPlayerItem, url: URL)? = nil
  ) throws -> AVPlayerItem? {
    guard !entries.values.contains(where: { $0.entry.id == ready.entry.id }) else { return nil }
    let (item, url) = try prepared ?? makeItem(ready)
    #if DEBUG && AUDIO_CLOCK_ACCEPTANCE
      if let measureAudioItemBeforeInsertion {
        let admissionGraph = graphID
        let admissionRevision = revision
        try measureAudioItemBeforeInsertion(item, ready)
        guard graphID == admissionGraph, revision == admissionRevision, !Task.isCancelled else {
          throw CancellationError()
        }
      }
    #endif
    entries[ObjectIdentifier(item)] = ready
    sourceOrdinal = min(Int.max - 1, sourceOrdinal) + 1
    sourceOrdinals[ObjectIdentifier(item)] = sourceOrdinal
    if url != ready.source.url { bridgeURLs[ObjectIdentifier(item)] = url }
    if retainedFailureItem == nil { retainedFailureItem = item }
    let identity = ObjectIdentifier(item)
    let graph = graphID
    endObservers[identity] = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
    ) { [weak self, weak item] _ in
      MainActor.assumeIsolated {
        guard let self, let item, self.graphID == graph, self.entries[identity] != nil else {
          return
        }
        self.endedItem = ObjectIdentifier(item)
        self.changedItem()
      }
    }
    let request = revision
    player.insert(item, after: nil)
    guard graphID == graph, revision == request, entries[identity] != nil else {
      throw CancellationError()
    }
    ready.diagnostic?.event(.playback) {
      var facts = DiagnosticFacts(.source, .started, source: ready.source.diagnosticSource)
      var evidence = PlaybackEvidence()
      evidence.sourceOrdinal = self.sourceOrdinals[ObjectIdentifier(item)] ?? 0
      evidence.source = ready.source.diagnosticSource
      evidence.quality = DiagnosticQuality(ready.source.quality)
      evidence.origin = ready.source.timeOrigin
      evidence.sourceDuration = ready.source.serverDuration
      evidence.precise = ready.source.preferPreciseTiming
      evidence.serverSeek = ready.source.serverTimeSeek
      evidence.target = self.preparingStart ? self.pendingStartPosition : 0
      facts.playback = evidence
      return facts
    }
    guard graphID == graph, revision == request, entries[identity] != nil else {
      throw CancellationError()
    }
    if player.currentItem !== item { prepareArtwork(ready, item: item) }
    return item
  }
  func observeCurrent() -> Bool {
    changedItem()
    if case .failed = transport { return false }
    samplePosition()
    return true
  }
  func retainCurrent(occurrence: UUID, keeping successor: UUID?) -> CurrentItemRetention {
    changedItem()
    guard let current = player.currentItem else {
      if case .preparing(let pending, _, _) = transport, pending != occurrence { return .changed }
      return .unbound
    }
    guard entries[ObjectIdentifier(current)]?.entry.id == occurrence else { return .changed }
    let retained = player.retainFuture(after: current) { item in
      guard let successor else { return false }
      return entries[ObjectIdentifier(item)]?.entry.id == successor
    } didRemove: { item in
      let key = ObjectIdentifier(item)
      if let removed = entries.removeValue(forKey: key) {
        removed.diagnostic?.retire(.superseded)
        tailFiles?.remove(removed.source.url)
      }
      sourceOrdinals.removeValue(forKey: key)
      if let observer = endObservers.removeValue(forKey: key) {
        NotificationCenter.default.removeObserver(observer)
      }
      if let url = bridgeURLs.removeValue(forKey: key) { mediaBridge?.retire(url) }
      if preparedArtwork?.item == key { clearPreparedArtwork() }
    }
    guard retained else {
      changedItem()
      return .changed
    }
    return .retained
  }
  func hasPrepared(_ occurrence: UUID) -> Bool {
    player.items().contains { entries[ObjectIdentifier($0)]?.entry.id == occurrence }
  }
  func hasCompleteLocalFile(occurrence: UUID) -> Bool {
    guard let item = player.currentItem, let ready = entries[ObjectIdentifier(item)],
      ready.entry.id == occurrence
    else { return false }
    return ready.source.url.isFileURL && ready.source.timeOrigin == 0
  }
  func requiresSourceReplacementForSeek(occurrence: UUID, position: Double) -> Bool {
    guard position.isFinite, position > 0, let item = player.currentItem,
      let ready = entries[ObjectIdentifier(item)], ready.entry.id == occurrence
    else { return false }
    return ready.source.preciseSeekingRequired && !ready.source.preferPreciseTiming
  }
  func hasPending(_ occurrence: UUID) -> Bool {
    if case .preparing(let id, _, let presentation) = transport {
      return id == occurrence && presentation?.entry.id == occurrence
    }
    return false
  }
  func advancePrepared(to occurrence: UUID) -> Bool {
    let items = player.items()
    guard case .active(let requested) = transport, requested, sessionState.isActive,
      player.status != .failed, items.count >= 2,
      let current = player.currentItem, items[0] === current,
      current.status == .readyToPlay, current.error == nil,
      items[1].status == .readyToPlay, items[1].error == nil,
      let old = entries[ObjectIdentifier(current)], let authority = old.authority,
      let next = entries[ObjectIdentifier(items[1])], next.entry.id == occurrence,
      next.authority == authority, old.entry.libraryID == authority.library,
      next.entry.libraryID == authority.library
    else { return false }
    player.advanceToNextItem()
    changedItem()
    installRemoteCommands(renewIntent: true)
    return player.currentItem === items[1]
  }
  func prepareReplacement(_ replacement: PlaybackReplacement) -> Bool {
    guard replacement.target.libraryID == replacement.authority.library,
      !replacement.authority.library.isEmpty, replacement.position.isFinite,
      replacement.position >= 0, (replacement.artwork?.count ?? 0) <= 3_000_000
    else { return false }
    let previous: PreparedPresentation?
    if case .preparing(_, _, let presentation) = transport {
      previous = presentation
    } else {
      previous = nil
    }
    let bound = player.currentItem.flatMap { entries[ObjectIdentifier($0)] }
    let oldAuthority = previous?.authority ?? bound?.authority
    if let oldAuthority, oldAuthority.account != replacement.authority.account { return false }
    if let previous, previous.entry == replacement.target,
      previous.authority == replacement.authority, previous.data == replacement.artwork,
      pendingStartPosition == replacement.position
    {
      return true
    }
    var image: MPMediaItemArtwork?
    let oldEntry = previous?.entry ?? artworkEntry?.entry
    if let oldAuthority, oldAuthority.account == replacement.authority.account,
      oldAuthority.library == replacement.authority.library,
      let oldEntry, let imageID = replacement.target.track.imageID, !imageID.isEmpty,
      let tag = replacement.target.track.imageTag, !tag.isEmpty,
      oldEntry.track.imageID == imageID, oldEntry.track.imageTag == tag,
      let data = replacement.artwork, nowPlayingArtworkData == data
    {
      image = nowPlayingArtwork
    }
    if image == nil, let preparedArtwork,
      preparedArtwork.ready.entry == replacement.target,
      preparedArtwork.ready.authority?.account == replacement.authority.account,
      preparedArtwork.ready.authority?.library == replacement.authority.library,
      preparedArtwork.ready.artwork == replacement.artwork
    {
      image = preparedArtwork.image
    }
    let presentation = PreparedPresentation(
      entry: replacement.target, authority: replacement.authority,
      data: replacement.artwork, image: image)
    retireSource(
      replacingGraph: player.status == .failed || hasMediaServicesReset(player.error),
      presentation: presentation)
    transport = .preparing(
      occurrence: replacement.target.id, position: replacement.position, presentation: presentation)
    preparationDiagnostic = replacement.diagnostic
    preparationDiagnostic?.event(.playback, .init(.native, .preparing))
    installRemoteCommands()
    publish(forceClock: true)
    updateArtwork(replacement.artwork, occurrence: replacement.target.id)
    return true
  }
  func renewRemoteIntent() {
    installRemoteCommands(renewIntent: true)
  }
  func resume(id: UUID) -> Bool {
    guard case .active = transport, sessionState.isActive, player.status != .failed,
      let item = player.currentItem,
      item.status == .readyToPlay,
      item.error == nil,
      entries[ObjectIdentifier(item)]?.entry.id == id
    else { return false }
    transport = .active(requested: true)
    installRemoteCommands(renewIntent: true)
    beginWatchdog()
    player.play()
    publish()
    return true
  }
  func pause() {
    if preparingStart {
      stop()
      return
    }
    watchdog?.cancel()
    revision = UUID()
    if case .seeking(_, let target) = transport {
      transport = .seeking(requested: false, target: target)
    } else {
      transport = .active(requested: false)
    }
    installRemoteCommands(renewIntent: true)
    player.pause()
    samplePosition()
    publish(forceClock: true)
  }
  private func clearArtwork() {
    artworkRevision = UUID()
    artworkTask?.cancel()
    artworkTask = nil
    nowPlayingArtwork = nil
    nowPlayingArtworkData = nil
    artworkEntry = nil
    currentArtworkOwner = nil
  }
  private func clearPreparedArtwork() {
    preparedArtworkRevision = UUID()
    preparedArtworkTask?.cancel()
    preparedArtworkTask = nil
    preparedArtwork = nil
  }
  func stop() { retireSource() }
  private func retireSource(
    replacingGraph: Bool = false, presentation: PreparedPresentation? = nil
  ) {
    let continuing: Bool
    if let presentation, case .preparing(_, _, let previous) = transport, let previous {
      continuing =
        previous.entry == presentation.entry
        && previous.authority == presentation.authority && previous.data == presentation.data
    } else {
      continuing = false
    }
    preparationDiagnostic?.retire(.sourceRetired)
    preparationDiagnostic = nil
    for ready in entries.values { ready.diagnostic?.retire(.sourceRetired) }
    transport = .idle
    watchdog?.cancel()
    seekRequest = UUID()
    observedItem = nil
    endedItem = nil
    for observer in endObservers.values { NotificationCenter.default.removeObserver(observer) }
    endObservers.removeAll()
    if !continuing { clearArtwork() }
    clearPreparedArtwork()
    revision = UUID()
    player.pause()
    mediaBridge?.stop()
    mediaBridge = nil
    bridgeURLs.removeAll()
    player.removeAllItems()
    retainedFailureItem = nil
    entries.removeAll()
    sourceOrdinals.removeAll()
    tailFiles?.clear()
    itemObserver = nil
    durationObserver = nil
    lastID = nil
    if presentation == nil { systemCommands.clear() }
    nowPlayingSignature = nil
    if let presentation {
      nowPlayingArtwork = presentation.image
      nowPlayingArtworkData = presentation.data
      if presentation.image != nil {
        currentArtworkOwner = .authorized(presentation.entry, presentation.authority)
      }
    } else {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    if replacingGraph { rebuildFailedPlayer() }
    if let owner = sessionState.retire() {
      Task { await session.deactivate(owner: owner) }
    }
  }
  func seek(_ seconds: Double, request: UUID) {
    guard seconds.isFinite else { return }
    if preparingStart {
      if case .preparing(let occurrence, _, let presentation) = transport {
        transport = .preparing(
          occurrence: occurrence, position: max(0, seconds), presentation: presentation)
      }
      seekRequest = request
      publish(forceClock: true)
      return
    }
    guard let item = player.currentItem else { return }
    seekRequest = request
    transport = .seeking(requested: intent, target: max(0, seconds))
    publish(forceClock: true)
    resetProgress(position: seconds)
    player.seek(
      to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] completed in
      Task { @MainActor in
        guard let self, self.seekRequest == request, self.player.currentItem === item else {
          return
        }
        self.transport = .active(requested: self.intent)
        if completed {
          self.lastClock = self.absoluteClock(item)
          self.resetProgress(position: self.lastClock)
          self.samplePosition(seek: request)
          self.publish(forceClock: true)
        } else if self.intent {
          self.failPlayback(retainPosition: true, error: PlaybackProblem.seek)
        } else {
          if let id = self.currentOccurrence {
            self.onEvent?(.seekCancelled(id, request: request))
          }
          self.publish(forceClock: true, clockOverride: self.lastClock)
        }
      }
    }
  }
  nonisolated private static func seekTarget(_ requested: Double, duration: Double) -> Double {
    let target = requested.isFinite ? max(0, requested) : 0
    guard duration.isFinite, duration > 0 else { return target }
    return min(target, max(0, duration - 0.05))
  }
  private func resetProgress(position: Double? = nil) {
    let now = ProcessInfo.processInfo.systemUptime
    let item = player.currentItem
    let precisePreparation =
      item.map {
        $0.status == .unknown && entries[ObjectIdentifier($0)]?.source.preferPreciseTiming == true
      } ?? false
    progress.reset(
      at: now, position: position ?? absoluteClock(item),
      preparationStartedAt: precisePreparation ? now : nil)
  }
  private func beginWatchdog(precisePreparation: Bool = false, position: Double? = nil) {
    watchdog?.cancel()
    let now = ProcessInfo.processInfo.systemUptime
    progress.reset(
      at: now, position: position ?? absoluteClock(player.currentItem),
      preparationStartedAt: precisePreparation ? now : nil)
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        guard let self, self.intent else { return }
        if self.progress.expired(
          at: ProcessInfo.processInfo.systemUptime,
          position: self.absoluteClock(player.currentItem),
          ready: self.player.currentItem?.status == .readyToPlay
        ) {
          self.failPlayback()
          return
        }
      }
    }
  }
  private func failPlayback(retainPosition: Bool = false, error: (any Error)? = nil) {
    guard intent else { return }
    let occurrence = currentOccurrence
    let item = player.currentItem ?? retainedFailureItem
    var detail: ConnectionStepError
    if let error {
      detail = ConnectionStepError(step: .playbackAudio, error: error)
    } else if item?.status == .failed || player.status == .failed {
      detail = nativeFailure(item)
    } else {
      detail = ConnectionStepError(step: progress.stallStep, error: PlaybackProblem.stalled)
    }
    let log = item.flatMap { entries[ObjectIdentifier($0)]?.diagnostic } ?? preparationDiagnostic
    detail = captureFailure(detail, item: item, log: log)
    if !retainPosition && detail.category != .expiredAudioSession { samplePosition() }
    retireSource(
      replacingGraph: player.status == .failed || hasMediaServicesReset(detail)
        || detail.category == .expiredAudioSession)
    transport = .failed
    if let occurrence {
      onEvent?(.failureDetails(occurrence, detail))
    } else {
      onEvent?(.failure)
    }
  }
  private func captureFailure(
    _ detail: ConnectionStepError, item: AVPlayerItem?, log: DiagnosticContext?
  ) -> ConnectionStepError {
    var captured = detail
    let now = ProcessInfo.processInfo.systemUptime
    let capture: ([PlaybackTransferEvidence]) -> DiagnosticEmission? = { transfers in
      log?.prepareEvent(.playback) {
        captured.playbackEvidence = self.playbackEvidence(item: item, transfers: transfers, at: now)
        return .failure(captured, stage: .native)
      }
    }
    let emission: DiagnosticEmission?
    if let item, let url = bridgeURLs[ObjectIdentifier(item)], let mediaBridge {
      emission = mediaBridge.withEvidence(for: url, at: now, capture) ?? nil
    } else {
      emission = capture([])
    }
    captured.nativeDiagnostic = emission?.record
    emission?.publish()
    return captured
  }
  private func playbackEvidence(
    item: AVPlayerItem?, transfers: [PlaybackTransferEvidence], at now: Double
  ) -> PlaybackEvidence {
    let key = item.map(ObjectIdentifier.init)
    let source = key.flatMap { entries[$0]?.source }
    var facts = PlaybackEvidence()
    switch transport {
    case .idle: facts.transport = .idle
    case .preparing(_, let target, _):
      facts.transport = .preparing
      facts.target = target
    case .active: facts.transport = .active
    case .seeking(_, let target):
      facts.transport = .seeking
      facts.target = target
    case .failed: facts.transport = .failed
    }
    switch player.reasonForWaitingToPlay {
    case nil: facts.waiting = PlaybackEvidence.Waiting.none
    case .toMinimizeStalls: facts.waiting = .minimizeStalls
    case .evaluatingBufferingRate: facts.waiting = .evaluateBuffer
    case .noItemToPlay: facts.waiting = .noItem
    default: facts.waiting = .other
    }
    facts.sourceOrdinal = key.flatMap { sourceOrdinals[$0] } ?? 0
    facts.source = source?.diagnosticSource ?? .unknown
    facts.quality = source.map { DiagnosticQuality($0.quality) } ?? .unknown
    facts.playerStatus = player.status.rawValue
    facts.itemStatus = item?.status.rawValue
    facts.timeControl = player.timeControlStatus.rawValue
    facts.requested = intent
    facts.itemIsCurrent = item.map { $0 === player.currentItem }
    facts.precise = source?.preferPreciseTiming
    facts.serverSeek = source?.serverTimeSeek
    facts.nativeClock = item?.currentTime().seconds
    facts.absoluteClock = item.map { absoluteClock($0) }
    facts.origin = source?.timeOrigin
    facts.nativeDuration = item?.duration.seconds
    facts.sourceDuration = source?.serverDuration
    facts.loadedEnd = item?.loadedTimeRanges.prefix(8).map { $0.timeRangeValue.end.seconds }.max()
    facts.seekableEnd = item?.seekableTimeRanges.prefix(8).map { $0.timeRangeValue.end.seconds }
      .max()
    facts.bufferEmpty = item?.isPlaybackBufferEmpty
    facts.keepUp = item?.isPlaybackLikelyToKeepUp
    let deadline = progress.evidence(at: now)
    facts.noProgressSeconds = deadline.noProgress
    facts.preparationSeconds = deadline.preparing
    facts.transfers = transfers
    return facts
  }
  private func changedItem() {
    if checkFailure() { return }
    let alive = Set(player.items().map(ObjectIdentifier.init))
    for (id, url) in bridgeURLs where !alive.contains(id) { mediaBridge?.retire(url) }
    bridgeURLs = bridgeURLs.filter { alive.contains($0.key) }
    guard let item = player.currentItem, let ready = entries[ObjectIdentifier(item)] else {
      if case .preparing(_, _, let presentation) = transport, presentation != nil {
        publish()
        return
      }
      if !preparingStart { tailFiles?.clear() }
      clearArtwork()
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      if intent, let previous = retainedFailureItem,
        endedItem == ObjectIdentifier(previous), let id = lastID
      {
        transport = .idle
        onEvent?(.finished(id))
      }
      return
    }
    installRemoteCommands()
    guard observedItem !== item else { return }
    observedItem = item
    #if DEBUG
      itemObservationInstallations += 1
    #endif
    itemObserver = nil
    durationObserver = nil
    retainedFailureItem = item
    for (id, observer) in endObservers where !alive.contains(id) {
      NotificationCenter.default.removeObserver(observer)
      endObservers.removeValue(forKey: id)
    }
    for (id, ready) in entries where !alive.contains(id) {
      ready.diagnostic?.retire(.sourceRetired)
    }
    entries = entries.filter { alive.contains($0.key) }
    sourceOrdinals = sourceOrdinals.filter { alive.contains($0.key) }
    tailFiles?.retire(keeping: Set(entries.values.map { $0.source.url }))
    if lastID != ready.entry.id {
      seekRequest = UUID()
      if seeking { transport = .active(requested: intent) }
      if !preparingStart { resetProgress(position: 0) }
      if adoptCurrentArtwork(for: ready) {
      } else if canReuseArtwork(from: artworkEntry, to: ready) {
        artworkEntry = ready
        currentArtworkOwner = artworkOwner(for: ready.entry.id)
      } else if let preparedArtwork, preparedArtwork.item == ObjectIdentifier(item),
        preparedArtwork.ready.entry == ready.entry,
        preparedArtwork.ready.authority == ready.authority
      {
        clearArtwork()
        nowPlayingArtwork = preparedArtwork.image
        nowPlayingArtworkData = preparedArtwork.ready.artwork
        artworkEntry = ready
        currentArtworkOwner = artworkOwner(for: ready.entry.id)
      } else {
        clearArtwork()
      }
      clearPreparedArtwork()
      lastID = ready.entry.id
      lastClock = 0
      onEvent?(.advanced(ready.entry.id))
    }
    let graph = graphID
    durationObserver = item.observe(\.duration, options: [.initial, .new]) {
      [weak self] observed, _ in
      Task { @MainActor in
        guard let self, self.graphID == graph, self.player.currentItem === observed else { return }
        self.publishTimeline(observed)
        self.publish()
      }
    }
    publishTimeline(item)
    itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
      Task { @MainActor in
        guard let self, self.graphID == graph, self.player.currentItem === observed else { return }
        if observed.status == .readyToPlay {
          self.progress.markReady(at: ProcessInfo.processInfo.systemUptime)
        }
        self.checkFailure()
      }
    }
    publish()
  }
  private func publishTimeline(_ item: AVPlayerItem) {
    guard player.currentItem === item, let ready = entries[ObjectIdentifier(item)] else { return }
    #if DEBUG
      countPublication(\.timelines)
    #endif
    let duration = absoluteDuration(item)
    let end = item.seekableTimeRanges.map {
      $0.timeRangeValue.end.seconds + (entries[ObjectIdentifier(item)]?.source.timeOrigin ?? 0)
    }
    .filter { $0.isFinite && $0 > 0 }.max()
    let graph = graphID
    let request = revision
    onEvent?(.sourceDuration(ready.entry.id, ready.source.serverDuration))
    guard graphID == graph, revision == request, player.currentItem === item else { return }
    onEvent?(
      .timeline(
        ready.entry.id,
        duration: duration.isFinite && duration > 0 ? duration : nil, seekableEnd: end))
  }
  private func nativeFailure(
    _ item: AVPlayerItem?, step: ConnectionStepError.Step = .playbackAudio
  ) -> ConnectionStepError {
    ConnectionStepError(
      step: step, error: item?.error ?? player.error ?? PlaybackProblem.nativeStart)
  }
  @discardableResult private func checkFailure() -> Bool {
    guard intent || preparingStart else { return false }
    if preparingStart, player.currentItem == nil, !sessionState.isActive { return false }
    let item = player.currentItem ?? retainedFailureItem
    if hasMediaServicesReset(player.error) || hasMediaServicesReset(item?.error) {
      mediaServicesReset()
      return true
    }
    guard player.status == .failed || item?.status == .failed else { return false }
    failPlayback(error: nativeFailure(item))
    return true
  }
  private func absoluteClock(_ item: AVPlayerItem?) -> Double {
    guard let item else { return .nan }
    return item.currentTime().seconds + (entries[ObjectIdentifier(item)]?.source.timeOrigin ?? 0)
  }
  private func absoluteDuration(_ item: AVPlayerItem) -> Double {
    let duration = item.duration.seconds
    guard duration.isFinite, duration > 0 else { return .nan }
    return duration + (entries[ObjectIdentifier(item)]?.source.timeOrigin ?? 0)
  }
  private func samplePosition(seek request: UUID? = nil) {
    guard !preparingStart, !seeking, player.status != .failed, let item = player.currentItem,
      item.status != .failed,
      let ready = entries[ObjectIdentifier(item)]
    else { return }
    let seconds = absoluteClock(item)
    if seconds.isFinite {
      lastClock = seconds
      #if DEBUG
        countPublication(\.positions)
      #endif
      if let request {
        onEvent?(.seekCompleted(ready.entry.id, seconds, request: request))
      } else {
        onEvent?(.position(ready.entry.id, seconds))
      }
    }
  }
  private func tick() {
    if checkFailure() { return }
    guard player.status != .failed, let item = player.currentItem, item.status != .failed,
      let ready = entries[ObjectIdentifier(item)]
    else { return }
    guard !preparingStart, !seeking else { return }
    if lastID != ready.entry.id { changedItem() }
    guard player.currentItem === item else { return }
    let seconds = absoluteClock(item)
    guard seconds.isFinite else { return }
    publishTimeline(item)
    #if DEBUG
      countPublication(\.positions)
    #endif
    onEvent?(.position(ready.entry.id, seconds))
    if intent {
      onEvent?(
        .state(
          ready.entry.id,
          player.timeControlStatus == .playing && seconds > lastClock + 0.01 ? .playing : .waiting))
    }
    lastClock = seconds
    publish()
  }
  private func publish(forceClock: Bool = false, clockOverride: Double? = nil) {
    let entry: QueueEntry
    let duration: Double?
    let rate: Float
    let clock: Double
    if case .preparing(_, let position, let presentation) = transport {
      guard let presentation else { return }
      entry = presentation.entry
      let timing: (native: Double?, source: Double?) = {
        guard let item = player.currentItem,
          let ready = entries[ObjectIdentifier(item)], presentation.matches(ready)
        else { return (nil, nil) }
        return (absoluteDuration(item), ready.source.serverDuration)
      }()
      duration = entry.playbackDuration(
        nativeDuration: timing.native, sourceDuration: timing.source, position: position)
      rate = 0
      clock = position
    } else {
      guard let item = player.currentItem, let ready = entries[ObjectIdentifier(item)] else {
        return
      }
      entry = ready.entry
      duration = entry.playbackDuration(
        nativeDuration: absoluteDuration(item), sourceDuration: ready.source.serverDuration,
        position: absoluteClock(item))
      rate = intent && !seeking && player.timeControlStatus == .playing ? player.rate : 0
      if let clockOverride {
        clock = clockOverride
      } else if case .seeking(_, let target) = transport {
        clock = target
      } else {
        clock = absoluteClock(item)
      }
    }
    let signature = NowPlayingSignature(
      occurrence: entry.id, rate: rate,
      duration: duration, artwork: artworkRevision,
      hasArtwork: nowPlayingArtwork != nil, timeControl: player.timeControlStatus.rawValue,
      seeking: seeking)
    guard forceClock || signature != nowPlayingSignature else { return }
    #if DEBUG
      if nowPlayingSignature?.occurrence == signature.occurrence,
        nowPlayingSignature?.hasArtwork == true, !signature.hasArtwork
      {
        artworkClearingPublications += 1
      }
    #endif
    nowPlayingSignature = signature
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: entry.track.title,
      MPMediaItemPropertyArtist: entry.track.artist,
      MPMediaItemPropertyAlbumTitle: entry.track.album,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.isFinite ? clock : 0,
      MPNowPlayingInfoPropertyPlaybackRate: rate,
    ]
    if let duration = signature.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
    if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    #if DEBUG
      nowPlayingPublications += 1
      lastNowPlayingProjection = (
        clock.isFinite ? clock : 0, rate, ProcessInfo.processInfo.systemUptime
      )
    #endif
  }
  private enum ArtworkOwner: Equatable {
    case authorized(QueueEntry, PlaybackAuthority)
    case item(ObjectIdentifier, UUID)
  }
  private func artworkOwner(for occurrence: UUID) -> ArtworkOwner? {
    if case .preparing(let id, _, let presentation) = transport, id == occurrence,
      let presentation
    {
      return .authorized(presentation.entry, presentation.authority)
    }
    guard let item = player.currentItem,
      let ready = entries[ObjectIdentifier(item)], ready.entry.id == occurrence
    else { return nil }
    if let authority = ready.authority { return .authorized(ready.entry, authority) }
    return .item(ObjectIdentifier(item), occurrence)
  }
  @discardableResult private func adoptCurrentArtwork(for ready: PreparedEntry) -> Bool {
    guard let owner = currentArtworkOwner, artworkOwner(for: ready.entry.id) == owner,
      nowPlayingArtworkData != nil, nowPlayingArtwork != nil || artworkTask != nil
    else { return false }
    artworkEntry = ready
    return true
  }
  func updateArtwork(_ data: Data?, occurrence: UUID) {
    guard let owner = artworkOwner(for: occurrence) else { return }
    if let data, nowPlayingArtworkData == data,
      nowPlayingArtwork != nil || artworkTask != nil
    {
      return
    }
    clearArtwork()
    if case .preparing(let id, let position, let presentation) = transport,
      id == occurrence, let presentation
    {
      transport = .preparing(
        occurrence: id, position: position,
        presentation: PreparedPresentation(
          entry: presentation.entry, authority: presentation.authority, data: data, image: nil))
    }
    publish()
    guard let data, data.count <= 3_000_000 else { return }
    nowPlayingArtworkData = data
    currentArtworkOwner = owner
    let request = artworkRevision
    artworkTask = Task { [weak self] in
      let thumbnail = await Task.detached(priority: .utility) {
        MusicCoverThumbnail.make(data)
      }.value
      guard let self, !Task.isCancelled, self.artworkRevision == request,
        self.artworkOwner(for: occurrence) == owner
      else { return }
      self.artworkTask = nil
      guard let thumbnail, let image = UIImage(data: thumbnail) else { return }
      let artwork = NowPlayingArtworkRenderer.makeArtwork(image: image)
      self.nowPlayingArtwork = artwork
      self.artworkEntry = self.player.currentItem.flatMap { self.entries[ObjectIdentifier($0)] }
      if case .preparing(let id, let position, let presentation) = self.transport,
        id == occurrence, let presentation
      {
        self.transport = .preparing(
          occurrence: id, position: position,
          presentation: PreparedPresentation(
            entry: presentation.entry, authority: presentation.authority, data: data, image: artwork
          ))
      }
      self.publish()
    }
  }
  private func canReuseArtwork(from old: PreparedEntry?, to next: PreparedEntry) -> Bool {
    guard nowPlayingArtwork != nil, let old, let authority = old.authority,
      next.authority == authority, old.entry.libraryID == authority.library,
      next.entry.libraryID == authority.library,
      let image = old.entry.track.imageID, !image.isEmpty,
      let tag = old.entry.track.imageTag, !tag.isEmpty,
      next.entry.track.imageID == image, next.entry.track.imageTag == tag,
      let data = next.artwork, nowPlayingArtworkData == data
    else { return false }
    return true
  }
  private func prepareArtwork(_ ready: PreparedEntry, item: AVPlayerItem) {
    clearPreparedArtwork()
    guard let authority = ready.authority, ready.entry.libraryID == authority.library,
      let data = ready.artwork, data.count <= 3_000_000
    else { return }
    let identity = ObjectIdentifier(item)
    if canReuseArtwork(from: artworkEntry, to: ready), let image = nowPlayingArtwork {
      preparedArtwork = (identity, ready, image)
      return
    }
    let request = preparedArtworkRevision
    let graph = graphID
    preparedArtworkTask = Task { [weak self] in
      let thumbnail = await Task.detached(priority: .utility) {
        MusicCoverThumbnail.make(data)
      }.value
      guard let self, !Task.isCancelled, self.graphID == graph,
        self.preparedArtworkRevision == request,
        self.player.items().contains(where: { ObjectIdentifier($0) == identity }),
        self.entries[identity]?.entry == ready.entry,
        self.entries[identity]?.authority == authority, self.entries[identity]?.artwork == data,
        let thumbnail, let decoded = UIImage(data: thumbnail)
      else { return }
      let image = NowPlayingArtworkRenderer.makeArtwork(image: decoded)
      if self.player.currentItem === item {
        self.clearArtwork()
        self.nowPlayingArtwork = image
        self.nowPlayingArtworkData = data
        self.artworkEntry = ready
        self.currentArtworkOwner = self.artworkOwner(for: ready.entry.id)
        self.publish()
      } else {
        self.preparedArtwork = (identity, ready, image)
      }
    }
  }
  private var remoteBinding: (occurrence: UUID, authority: PlaybackAuthority?)? {
    let bound = player.currentItem.flatMap { entries[ObjectIdentifier($0)] }
    switch transport {
    case .idle, .failed: return nil
    case .active, .seeking: return bound.map { ($0.entry.id, $0.authority) }
    case .preparing(let target, _, let presentation):
      if let presentation, presentation.entry.id == target {
        return (target, presentation.authority)
      }
      guard let bound, bound.entry.id == target else { return nil }
      return (target, bound.authority)
    }
  }
  private func handleRemote(_ action: RemoteAction, owner: PlaybackRemoteReceipt?) {
    guard let owner, let installed = systemCommands.receipt, let binding = remoteBinding else {
      return
    }
    let live = PlaybackRemoteReceipt(
      intent: installed.intent, occurrence: binding.occurrence, authority: binding.authority,
      revision: revision)
    guard live.admits(owner, for: action) else { return }
    onRemote?(action)
  }
  private func installRemoteCommands(renewIntent: Bool = false) {
    guard let binding = remoteBinding else { return }
    systemCommands.install(
      occurrence: binding.occurrence, authority: binding.authority, revision: revision,
      renewIntent: renewIntent
    ) { [weak self] action, owner in self?.handleRemote(action, owner: owner) }
  }
  #if DEBUG
    var nativePlayerIdentity: ObjectIdentifier { ObjectIdentifier(player) }
    var tailFileCount: Int { tailFiles?.owned.count ?? 0 }
    func requireIntegrationTailStorage() throws {
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
      guard let expected = PlaybackTailFiles.startupDirectory(integration: true, support: support),
        tailFiles?.directory.standardizedFileURL == expected.standardizedFileURL
      else { throw ClientError.invalidResponse }
      let checks = try Self.tailStorageCheck()
      guard checks["normal_startup_mapping_unchanged"] == true,
        checks["integration_tail_retired"] == true,
        checks["integration_unsafe_components_rejected"] == true,
        checks["normal_tail_sentinel_preserved"] == true
      else { throw ClientError.invalidResponse }
    }
    static func tailStorageCheck() throws -> [String: Bool] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "tail-control-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let files = try PlaybackTailFiles(directory: root)
      let file = try files.write(Data([1, 2, 3]))
      let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
      let protection =
        (attrs[.protectionKey] as? FileProtectionType)?.rawValue
        ?? (attrs[.protectionKey] as? String)
      let protected = protection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue
      let excluded =
        try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
      let opaque =
        file.lastPathComponent.hasPrefix("tail-") && !file.lastPathComponent.contains("http")
      let sentinel = root.appendingPathComponent("leave-untouched.txt")
      try Data([4]).write(to: sentinel)
      _ = try PlaybackTailFiles(directory: root)
      let orphanRemoved = !FileManager.default.fileExists(atPath: file.path)
      let sentinelPreserved = FileManager.default.fileExists(atPath: sentinel.path)
      var oversizedRejected = false
      do { _ = try files.write(Data(repeating: 0, count: 500_001)) } catch {
        oversizedRejected = true
      }
      let support = root.appendingPathComponent("support", isDirectory: true)
      let normal = root.appendingPathComponent("normal-cache", isDirectory: true)
      try FileManager.default.createDirectory(at: normal, withIntermediateDirectories: true)
      let normalTail = normal.appendingPathComponent("tail-" + UUID().uuidString + ".mp3")
      try Data([7, 8, 9]).write(to: normalTail)
      guard
        let integration = PlaybackTailFiles.startupDirectory(integration: true, support: support)
      else { throw ClientError.invalidResponse }
      let integrationFiles = try PlaybackTailFiles(directory: integration)
      let integrationTail = try integrationFiles.write(Data([1, 2, 3]))
      _ = try PlaybackTailFiles(directory: integration)
      let integrationRetired = !FileManager.default.fileExists(atPath: integrationTail.path)
      var unsafeRejected = 0
      for (name, leaf, symbolic) in [
        ("linked-parent", false, true), ("linked-leaf", true, true),
        ("file-parent", false, false), ("file-leaf", true, false),
      ] {
        let support = root.appendingPathComponent(name, isDirectory: true)
        let parent = support.appendingPathComponent("JukeboxIntegration", isDirectory: true)
        try FileManager.default.createDirectory(
          at: leaf ? parent : support, withIntermediateDirectories: true)
        let component = leaf ? parent.appendingPathComponent("PlaybackTails") : parent
        if symbolic {
          try FileManager.default.createSymbolicLink(at: component, withDestinationURL: normal)
        } else {
          try Data([5]).write(to: component)
        }
        guard let path = PlaybackTailFiles.startupDirectory(integration: true, support: support)
        else { throw ClientError.invalidResponse }
        do {
          _ = try PlaybackTailFiles(directory: path)
        } catch {
          let unchanged = symbolic || (try? Data(contentsOf: component)) == Data([5])
          if unchanged { unsafeRejected += 1 }
        }
      }
      let normalPreserved = (try? Data(contentsOf: normalTail)) == Data([7, 8, 9])
      return [
        "normal_startup_mapping_unchanged":
          PlaybackTailFiles.startupDirectory(integration: false, support: support) == nil,
        "integration_tail_retired": integrationRetired,
        "integration_unsafe_components_rejected": unsafeRejected == 4,
        "normal_tail_sentinel_preserved": normalPreserved,
        "protected": protected, "protection_attribute_present": attrs[.protectionKey] != nil,
        "excluded": excluded, "opaque": opaque,
        "orphan_removed": orphanRemoved, "unowned_preserved": sentinelPreserved,
        "oversized_rejected": oversizedRejected,
      ]
    }
    struct QueueReadout {
      let occurrence: UUID?
      let seconds: Double
      let playerSeconds: Double
      let absoluteSeconds: Double
      let timeOrigin: Double
      let preparing: Bool
      let loadedEnd: Double
      let timeControlStatus: Int
      let itemStatuses: [Int]
      let itemErrors: [Int]
      let duration: Double
      let queued: Set<UUID>
      let ready: Set<UUID>
      let waiting: Bool
      let seeking: Bool
    }
    var queueReadout: QueueReadout {
      let items = player.items()
      let current = player.currentItem
      return QueueReadout(
        occurrence: current.flatMap { entries[ObjectIdentifier($0)]?.entry.id },
        seconds: current?.currentTime().seconds ?? .nan,
        playerSeconds: player.currentTime().seconds,
        absoluteSeconds: absoluteClock(current),
        timeOrigin: current.flatMap { entries[ObjectIdentifier($0)]?.source.timeOrigin } ?? 0,
        preparing: preparingStart,
        loadedEnd: current?.loadedTimeRanges.map { $0.timeRangeValue.end.seconds }.filter {
          $0.isFinite
        }.max() ?? -1,
        timeControlStatus: player.timeControlStatus.rawValue,
        itemStatuses: items.map { $0.status.rawValue },
        itemErrors: items.map { ($0.error as NSError?)?.code ?? 0 },
        duration: current?.duration.seconds ?? .nan,
        queued: Set(items.compactMap { entries[ObjectIdentifier($0)]?.entry.id }),
        ready: Set(
          items.filter { $0.status == .readyToPlay }.compactMap {
            entries[ObjectIdentifier($0)]?.entry.id
          }), waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate, seeking: seeking)
    }
  #endif
  var profilingReadout: ProfilingPlayback {
    let seconds = player.currentTime().seconds
    return ProfilingPlayback(
      clock: seconds.isFinite ? seconds : nil, rate: player.rate,
      timeControl: player.timeControlStatus.rawValue,
      routeTypes: AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue })
  }
  var safeStatus: [String: Any] {
    [
      "allows_external": player.allowsExternalPlayback, "muted": player.isMuted,
      "queue_items": player.items().count,
      "audio_mix_attached": player.items().contains { $0.audioMix != nil },
      "session_policy": AVAudioSession.sharedInstance().routeSharingPolicy.rawValue,
    ]
  }
}
