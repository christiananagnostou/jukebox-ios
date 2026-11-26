import Foundation
import Observation

@MainActor @Observable final class PlayerStore {
  private(set) var connections: [Connection] = []
  private(set) var session = AccountSession.opening
  var active: Connection? {
    guard case .signedIn(let connection, _) = session else { return nil }
    return connection
  }
  var browser: MusicBrowser? {
    guard case .signedIn(_, let browser) = session else { return nil }
    return browser
  }
  private(set) var queue = QueueState() {
    didSet {
      if queue.current != oldValue.current { playerContentRevision = UUID() }
      if queue.membershipRevision != oldValue.membershipRevision
        || queue.playlistID != oldValue.playlistID
      {
        queueMembership = QueueMembership(queue, account: active == nil ? nil : epoch)
      }
    }
  }
  private struct QueueMembership: Equatable {
    let account: UUID?
    let library: String?
    let count: Int
    let tracks: [String: Int]
    let playlistID: String?
    let playlistOrder: [String]?
    init(_ queue: QueueState, account: UUID?) {
      let entries = queue.entries
      playlistID = queue.playlistID
      playlistOrder = playlistID == nil ? nil : entries.map(\.track.id)
      self.account = account
      count = entries.count
      let first = entries.first?.libraryID
      library = entries.allSatisfy { $0.libraryID == first } ? first : nil
      tracks = Dictionary(entries.map { ($0.track.id, 1) }, uniquingKeysWith: +)
    }
    func matches(_ selection: PlaybackSelection, shuffled: Bool) -> Bool {
      guard account == selection.origin.account, library == selection.origin.library,
        count == selection.items.count, count > 0
      else { return false }
      if let source = selection.playlist?.id {
        guard playlistID == source else { return false }
        if !shuffled { return playlistOrder?.elementsEqual(selection.items.lazy.map(\.id)) == true }
      }
      var remaining = tracks
      for item in selection.items {
        guard let count = remaining[item.id], count > 0 else { return false }
        if count == 1 { remaining[item.id] = nil } else { remaining[item.id] = count - 1 }
      }
      return remaining.isEmpty
    }
  }
  private(set) var playerContentRevision = UUID()
  private var queueMembership = QueueMembership(QueueState(), account: nil)
  @MainActor private final class QueueRestoration {
    var saved: QueueState
    enum Stage {
      case current
      case remaining([MusicItem])
    }
    let stage: Stage
    var task: Task<Void, Never>?
    var actions: [(PlayerStore) -> Void] = []
    private var membership: (UUID, QueueMembership)?
    init(_ saved: QueueState, stage: Stage) {
      self.saved = saved
      self.stage = stage
    }
    func checkpoint(_ ready: QueueState) -> QueueState {
      var result = saved
      result.quality = ready.quality
      if case .current = stage { return result }
      let index = ready.current.flatMap { entry in
        saved.entries.firstIndex { $0.id == entry.id }
      }
      result.index = index ?? 0
      result.position = index == nil ? 0 : ready.position
      return result
    }
    func matches(_ selection: PlaybackSelection, account: UUID) -> Bool {
      guard selection.items.count == saved.entries.count else { return false }
      if membership?.0 != saved.membershipRevision {
        membership = (saved.membershipRevision, QueueMembership(saved, account: account))
      }
      return membership?.1.matches(selection, shuffled: false) == true
    }
  }
  private var restoringQueue: QueueRestoration?
  var hasRemainingQueue: Bool { restoringQueue != nil }
  private(set) var queueRestoreFailed = false
  private var queueCheckpoint: QueueState { restoringQueue?.checkpoint(queue) ?? queue }
  private var successorPreparation: SuccessorPreparation?
  var nextRequiresRetry: Bool {
    guard let successorPreparation, case .failed = successorPreparation.phase else { return false }
    return successorPreparation.occurrence == queue.successor?.id
  }
  typealias RepeatMode = QueueState.RepeatMode
  private(set) var repeatMode: RepeatMode = .off
  private(set) var shuffleEnabled = false
  @ObservationIgnored private var canonicalQueueOrder: [UUID] = []
  private(set) var sleepTimerDeadline: Date?
  @ObservationIgnored private var sleepTimerID = UUID()
  @ObservationIgnored private var sleepTimerTask: Task<Void, Never>?
  @ObservationIgnored private let now: @Sendable () -> Date
  @ObservationIgnored private let sleepUntil: @Sendable (Date) async throws -> Void
  private(set) var nativeDuration: Double?
  private(set) var sourceDuration: Double?
  private(set) var seekableEnd: Double?
  private var seekPresentation: (occurrence: UUID, request: UUID, position: Double)?
  private(set) var phase: PlayerPhase = .paused
  private(set) var catalogLayout = CatalogLayout.grid
  private(set) var catalogSelectionFeedback = true
  @ObservationIgnored private var devicePreferenceRevision: UInt64 = 0
  @ObservationIgnored private var browseRevision: UInt64 = 0
  func toggleCatalogLayout() {
    catalogLayout = catalogLayout == .grid ? .list : .grid
    persistCatalogDevicePreferences()
  }
  func setCatalogSelectionFeedback(_ value: Bool) {
    guard value != catalogSelectionFeedback else { return }
    catalogSelectionFeedback = value
    persistCatalogDevicePreferences()
  }
  private func persistCatalogDevicePreferences() {
    devicePreferenceRevision += 1
    let value = CatalogDevicePreferences(
      layout: catalogLayout, selectionFeedback: catalogSelectionFeedback)
    let revision = devicePreferenceRevision
    Task { try? await storage.saveCatalogDevicePreferences(value, revision: revision) }
  }
  private func restoreCatalogDevicePreferences() async {
    let revision = devicePreferenceRevision
    let value = (try? await storage.catalogDevicePreferences()) ?? .init()
    if devicePreferenceRevision == revision {
      catalogLayout = value.layout
      catalogSelectionFeedback = value.selectionFeedback
    }
  }
  private(set) var busy = false
  private(set) var error: String?
  private(set) var lastPlaybackFailure: PlaybackFailure?
  private struct CoverKey: Hashable {
    let library: String?
    let image: String
    let tag: String?
  }
  private var covers: [CoverKey: Data] = [:]
  private var coverTones: [CoverKey: ArtworkTone] = [:]
  private let artworkTone: @Sendable (Data) async -> ArtworkTone?
  private let prepareCover: @Sendable (Data) async -> Data?
  @ObservationIgnored private var playCommandRevision: UInt64 = 0
  @ObservationIgnored private var removingSavedConnection = false
  var pendingSignOut: String? {
    guard case .ending(let account, _) = session else { return nil }
    return account.id
  }
  @ObservationIgnored private var coverOrder: [CoverKey] = []
  @ObservationIgnored private var coverBytes = 0
  private static let coverCountLimit = 64
  private static let coverByteLimit = 12_000_000
  private struct LibraryOwner: Sendable {
    let account: UUID
    let library: String?
    let root: UUID?
  }
  @ObservationIgnored private var libraryOwners: [String: UUID] = [:]
  @MainActor private final class CoverRequest {
    let id = UUID()
    var consumers: [UUID: CheckedContinuation<Data?, Never>] = [:]
    var producer: Task<Void, Never>?
  }
  @ObservationIgnored private var coverRequests: [CoverKey: CoverRequest] = [:]
  private var preparation = PlaybackPreparation.idle
  var showPlayer = false
  var showQueue = false
  private(set) var isFixture = false
  @ObservationIgnored private let diagnostics: DiagnosticSession
  @ObservationIgnored private var playbackDiagnostic: DiagnosticContext?
  @ObservationIgnored private var seekDiagnostic: DiagnosticContext?
  private let storage: LibraryStorage
  private let vault: any TokenVault
  private let driver: any PlaybackDriving
  private let deviceID: String
  private let allowedFamilies: Set<String>
  private let authenticationTransport: any HTTPTransport
  private let preparationTimeout: Duration
  private let preparationSleep: @Sendable (Duration) async throws -> Void
  private let factory: @Sendable (Connection, String) throws -> any MusicCatalogServing
  private var service: (any MusicCatalogServing)?
  private struct DiagnosticOwner: Equatable {
    let account: UUID
    let library: UUID?
  }
  @ObservationIgnored private var nativeDiagnosticOwner: DiagnosticOwner?
  @ObservationIgnored private var failureDiagnosticOwner: DiagnosticOwner?
  private var diagnosticOwner: DiagnosticOwner {
    DiagnosticOwner(account: epoch, library: browser?.diagnosticScope)
  }
  private func clearPlaybackFailure() {
    lastPlaybackFailure = nil
    failureDiagnosticOwner = nil
  }
  private func recordPlaybackFailure(
    _ detail: ConnectionStepError, owner: DiagnosticOwner, diagnostic: DiagnosticRecord? = nil
  ) {
    guard active != nil, owner == diagnosticOwner else { return }
    var captured = detail
    captured.playbackEvidence?.acceptedClock = queue.position
    let record =
      captured.nativeDiagnostic ?? diagnostic
      ?? playbackDiagnostic?.event(.playback, .failure(captured, stage: .native))
    lastPlaybackFailure = PlaybackFailure(detail: captured, time: Date(), diagnostic: record)
    failureDiagnosticOwner = owner
  }
  func playbackFailureReport(id: UUID, appVersion: String) -> String? {
    guard active != nil, failureDiagnosticOwner == diagnosticOwner,
      let failure = lastPlaybackFailure, failure.id == id
    else { return nil }
    return failure.report(appVersion: appVersion)
  }
  @ObservationIgnored private var epoch = UUID()
  @ObservationIgnored private var playID = UUID()
  @ObservationIgnored private var playbackIntentID = UUID()
  @ObservationIgnored private var searchHistoryTask: Task<Void, Never>?
  @ObservationIgnored private var searchHistoryRevision: UInt64 = 0
  private var storageLease: UUID?
  private var saveRevision: UInt64 = 0
  @ObservationIgnored private var pendingIntent: PlaybackReplacement?
  @ObservationIgnored private var artworkTask: Task<Void, Never>?
  @ObservationIgnored private var artworkRequest = UUID()
  @ObservationIgnored private var recentTask: Task<Void, Never>?
  @ObservationIgnored private var recentOccurrence: UUID?
  @ObservationIgnored private var recentLoadID = UUID()
  @ObservationIgnored private var recentRevision: UInt64 = 0
  private var lastSavedSecond = -1
  init(
    storage: LibraryStorage, vault: any TokenVault, driver: any PlaybackDriving, deviceID: String,
    allowedFamilies: Set<String> = ServerCompatibility.verifiedFamilies,
    preparationTimeout: Duration = .seconds(15),
    preparationSleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }, diagnostics: DiagnosticSession = .disabled,
    now: @escaping @Sendable () -> Date = { Date() },
    sleepUntil: @escaping @Sendable (Date) async throws -> Void = { deadline in
      while deadline.timeIntervalSinceNow > 0 {
        try await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
      }
    },
    authenticationTransport: any HTTPTransport = LiveHTTP(),
    prepareCover: @escaping @Sendable (Data) async -> Data? = { $0 },
    artworkTone: @escaping @Sendable (Data) async -> ArtworkTone? = { _ in nil },
    factory: @escaping @Sendable (Connection, String) throws -> any MusicCatalogServing = {
      try JellyfinClient(connection: $0, token: $1, deviceID: "jukebox")
    }
  ) {
    self.now = now
    self.sleepUntil = sleepUntil
    self.artworkTone = artworkTone
    self.prepareCover = prepareCover
    self.diagnostics = diagnostics
    self.storage = storage
    self.vault = vault
    self.driver = driver
    self.deviceID = deviceID
    self.allowedFamilies = allowedFamilies
    self.authenticationTransport = authenticationTransport
    self.preparationTimeout = preparationTimeout
    self.preparationSleep = preparationSleep
    self.factory = factory
    driver.onEvent = { [weak self] event in self?.receive(event) }
  }
  var current: QueueEntry? { queue.current }
  var playing: Bool { phase == .playing }
  var playbackRequested: Bool { phase.requestsPlayback }
  var playbackPosition: Double {
    if let seekPresentation, seekPresentation.occurrence == current?.id {
      return seekPresentation.position
    }
    if playbackRequested, let pendingIntent, pendingIntent.target == current {
      return pendingIntent.position
    }
    return queue.position
  }
  var canControl: Bool { current != nil }
  var playbackDuration: Double? {
    current?.playbackDuration(
      nativeDuration: nativeDuration, sourceDuration: sourceDuration, position: queue.position)
  }
  var durationIsEstimated: Bool {
    nativeDuration == nil && sourceDuration == nil && playbackDuration != nil
  }
  var durationAccessibilityLabel: String {
    if nativeDuration != nil { return "Duration" }
    if sourceDuration != nil { return "Track duration reported by Jellyfin" }
    return "Estimated duration"
  }
  var seekUpperBound: Double {
    if let nativeDuration { return nativeDuration }
    let hint = sourceDuration ?? current?.track.duration ?? 0
    return max(1, hint.isFinite ? hint : 0, seekableEnd ?? 0, queue.position)
  }
  private func clearTimeline() {
    seekPresentation = nil
    nativeDuration = nil
    sourceDuration = nil
    seekableEnd = nil
  }
  func dismissError() { error = nil }
  @discardableResult private func stopDriver(
    replacing replacement: PlaybackReplacement? = nil, reason: DiagnosticReason = .sourceRetired
  ) -> UUID {
    let generation = epoch
    cancelAlbumPlay(reason: reason)
    playbackDiagnostic?.retire(reason)
    playbackDiagnostic = nil
    retireSuccessor(reason)
    seekDiagnostic?.retire(reason)
    seekDiagnostic = nil
    let request = replacement?.authority.replacement ?? UUID()
    playID = request
    playbackIntentID = playID
    pendingIntent = replacement
    preparation.cancel()
    clearTimeline()
    artworkRequest = UUID()
    artworkTask?.cancel()
    if let replacement, driver.prepareReplacement(replacement) { return request }
    guard epoch == generation, playID == request else { return request }
    driver.stop()
    return request
  }
  private func retire() {
    cancelQueueRestoration()
    cancelSleepTimer()
    repeatMode = .off
    shuffleEnabled = false
    canonicalQueueOrder = []
    clearPlaybackFailure()
    nativeDiagnosticOwner = nil
    #if DEBUG
      TransportCapture.shared.clear(retire: true)
    #endif
    searchHistoryTask?.cancel()
    searchHistoryTask = nil
    searchHistoryRevision = 0
    recentTask?.cancel()
    recentOccurrence = nil
    recentRevision = 0
    recentLoadID = UUID()
    browser?.retire()
    session = .signedOut(suggested: nil)
    epoch = UUID()
    playID = UUID()
    phase = .paused
    showPlayer = false
    showQueue = false
    stopDriver(reason: .accountRetired)
    service = nil
    retireCovers(except: nil)
    covers = [:]
    coverTones = [:]
    coverOrder = []
    coverBytes = 0
    libraryOwners = [:]
    queue = QueueState()
    storageLease = nil
    saveRevision = 0
    browseRevision = 0
    lastSavedSecond = -1
    error = nil
  }
  func bootstrap(autoConnect: Bool = true) async {
    guard case .opening = session, !busy else { return }
    busy = true
    let generation = epoch
    do {
      let saved = try await storage.connections()
      guard generation == epoch else { return }
      connections = saved
      await restoreCatalogDevicePreferences()
      guard generation == epoch else { return }
      busy = false
      guard autoConnect, let first = saved.first else {
        session = .signedOut(suggested: nil)
        return
      }
      guard first.server.supportsCredentials else {
        session = .recovery(.requiresHTTPS(first))
        return
      }
      await reconnect(first)
    } catch {
      guard generation == epoch else { return }
      busy = false
      session = .recovery(.savedAccounts)
    }
  }
  func retryAccountStartup() async {
    guard case .recovery(let reason) = session, !busy else { return }
    switch reason {
    case .savedAccounts:
      session = .opening
      await bootstrap()
    case .reconnect(let connection, _):
      await reconnect(connection)
    case .expired(let connection), .requiresHTTPS(let connection):
      session = .signedOut(suggested: connection)
    }
  }
  private func reconnect(_ connection: Connection) async {
    session = .reconnecting(connection)
    await activate(connection, restoringAtLaunch: true)
    if let pending = restoringQueue, case .current = pending.stage { await pending.task?.value }
  }
  func signIn(address: String, username: String, password: String)
    async
  {
    do {
      _ = try await signIn {
        let server = try ServerAddress(address)
        return try await authentication(for: server).password(
          username: username, password: password)
      }
    } catch is CancellationError {
    } catch {
      self.error = message(
        error is ConnectionStepError
          ? error : ConnectionStepError(step: .authentication, error: error))
    }
  }
  private func authentication(for server: ServerAddress) -> JellyfinAuthentication {
    JellyfinAuthentication(
      server: server, deviceID: deviceID, transport: authenticationTransport,
      allowedFamilies: allowedFamilies)
  }
  func serverInfo(for connection: Connection) async throws -> JellyfinServerInfo {
    let generation = epoch
    guard active?.id == connection.id, !isFixture else { throw CancellationError() }
    let info = try await authentication(for: connection.server).serverInfo()
    guard generation == epoch else { throw CancellationError() }
    return info
  }
  func signInCodeAvailability(on server: ServerAddress) async throws -> Bool? {
    try await authentication(for: server).signInCodeAvailability()
  }
  func signInWithQuickConnect(
    server: ServerAddress, showCode: @MainActor @Sendable (QuickConnectCode) -> Void
  ) async throws {
    guard active == nil else { throw QuickConnectError.accountChanged }
    let account = try await signIn {
      try await authentication(for: server).quickConnect(showCode: showCode)
    }
    guard active?.id == account.id else { throw ClientError.unavailable }
  }
  var canApproveQuickConnect: Bool { active != nil && service is any QuickConnectAuthorizing }
  func approveQuickConnect(_ code: QuickConnectCode, for account: Connection) async throws {
    guard !busy, active?.id == account.id, let authorizer = service as? any QuickConnectAuthorizing
    else { throw QuickConnectError.accountChanged }
    let generation = epoch
    try Task.checkCancellation()
    try await authorizer.authorizeQuickConnect(code) { [weak self] in
      self?.epoch == generation && self?.active?.id == account.id
    }
    try Task.checkCancellation()
    guard generation == epoch, active?.id == account.id else {
      throw QuickConnectError.accountChanged
    }
  }
  private func signIn(_ authenticate: () async throws -> (Connection, String)) async throws
    -> Connection
  {
    guard !busy, !removingSavedConnection, pendingSignOut == nil else { throw CancellationError() }
    busy = true
    error = nil
    let generation = epoch
    var step = ConnectionStepError.Step.authentication
    do {
      let (connection, token) = try await authenticate()
      try Task.checkCancellation()
      guard generation == epoch else { throw CancellationError() }
      step = .secureStorage
      try await vault.write(token, account: connection.id)
      guard generation == epoch else { throw CancellationError() }
      step = .savedConnection
      let saved = [connection] + connections.filter { $0.id != connection.id }
      try await storage.saveConnections(saved)
      guard generation == epoch else { throw CancellationError() }
      connections = saved
      try Task.checkCancellation()
      busy = false
      await activate(connection)
      return connection
    } catch {
      guard generation == epoch else { throw CancellationError() }
      busy = false
      try Task.checkCancellation()
      if step == .authentication { throw error }
      throw ConnectionStepError(step: step, error: error)
    }
  }
  func activate(_ connection: Connection) async {
    await activate(connection, restoringAtLaunch: false)
  }
  private func activate(_ connection: Connection, restoringAtLaunch: Bool) async {
    guard !busy, !removingSavedConnection, pendingSignOut == nil else { return }
    busy = true
    var generation = epoch
    var intent = playID
    var revision = saveRevision
    let playCommand = playCommandRevision
    var step = ConnectionStepError.Step.identity
    defer { if epoch == generation { busy = false } }
    do {
      try connection.server.requireCredentialTransport()
      step = .secureStorage
      guard let token = try await vault.read(account: connection.id) else {
        throw ClientError.unauthorized
      }
      guard generation == epoch else { return }
      try Task.checkCancellation()
      let api = try factory(connection, token)
      step = .identity
      try await api.verifyIdentity()
      try Task.checkCancellation()
      guard generation == epoch, playCommand == playCommandRevision, playID == intent,
        playbackRequested || saveRevision == revision
      else { return }
      if active != nil {
        step = .savingQueue
        pause()
        intent = playID
        revision = saveRevision + 1
        try await saveNow()
      }
      try Task.checkCancellation()
      guard generation == epoch, playCommand == playCommandRevision, !playbackRequested,
        playID == intent, saveRevision == revision
      else { return }
      step = .restoration
      let savedQueue = try await storage.restore(account: connection.id) ?? QueueState()
      let restored = restoringAtLaunch ? nil : try await savedQueue.restoredForPlayback(using: api)
      let preferences =
        (try? await storage.catalogPreferences(account: connection.id))
        ?? CatalogBrowsePreferences()
      try Task.checkCancellation()
      guard generation == epoch, playCommand == playCommandRevision, !playbackRequested,
        playID == intent, saveRevision == revision
      else { return }
      let saved = [connection] + connections.filter { $0.id != connection.id }
      step = .savedConnection
      if saved != connections { try await storage.saveConnections(saved) }
      guard generation == epoch else { return }
      let lease = await storage.lease(account: connection.id)
      guard generation == epoch else { return }
      retire()
      generation = epoch
      isFixture = false
      service = api
      storageLease = lease
      installBrowser(api, connection: connection, preferences: preferences)
      if let restored {
        installRestoredQueue(restored)
      } else if savedQueue.current != nil {
        queue.quality = savedQueue.quality
        restoringQueue = QueueRestoration(savedQueue, stage: .current)
        retryQueueRestoration()
      } else {
        queue = savedQueue
      }
      connections = saved
      #if DEBUG
        Self.transportActivationReceipt?.accept(
          store: self, lease: TransportAcceptanceLease(epoch: epoch, intent: playID))
      #endif
    } catch {
      guard generation == epoch else { return }
      if error is CancellationError && !restoringAtLaunch { return }
      if error as? ClientError == .unauthorized {
        if active?.id == connection.id {
          await logout(ifCurrent: generation)
          return
        }
        do {
          try await vault.erase(account: connection.id)
          guard generation == epoch else { return }
          try await storage.removeSavedConnection(account: connection.id)
          guard generation == epoch else { return }
          connections.removeAll { $0.id == connection.id }
          if restoringAtLaunch {
            session = .recovery(.expired(connection))
            return
          }
        } catch {
          guard generation == epoch else { return }
          if restoringAtLaunch {
            session = .recovery(
              .reconnect(connection, ConnectionStepError(step: .secureStorage, error: error)))
            return
          }
          self.error =
            "This saved sign-in has expired. Open its connection details to finish removing it."
          return
        }
      }
      let detail = ConnectionStepError(step: step, error: error)
      if restoringAtLaunch {
        session = .recovery(.reconnect(connection, detail))
      } else {
        self.error = message(detail)
      }
    }
  }
  func removeSavedConnection(_ connection: Connection) async throws {
    guard !busy, !removingSavedConnection, pendingSignOut == nil, active?.id != connection.id,
      connections.contains(where: { $0.id == connection.id })
    else { throw CancellationError() }
    removingSavedConnection = true
    let generation = epoch
    busy = true
    defer {
      removingSavedConnection = false
      if generation == epoch { busy = false }
    }
    try await vault.erase(account: connection.id)
    try await storage.removeSavedConnection(account: connection.id)
    connections.removeAll { $0.id == connection.id }
  }
  func enterFixture(service: any MusicCatalogServing) async {
    guard !busy, pendingSignOut == nil else { return }
    persist()
    retire()
    session = .opening
    isFixture = true
    busy = true
    let generation = epoch
    do {
      let connection = Connection(
        server: try ServerAddress("https://fixture.invalid"), userID: "invented-listener",
        username: "Demo listener")
      let savedQueue = try await storage.restore(account: connection.id) ?? QueueState()
      let restored = try await savedQueue.restoredForPlayback(using: service)
      guard generation == epoch else { return }
      await restoreCatalogDevicePreferences()
      let preferences =
        (try? await storage.catalogPreferences(account: connection.id))
        ?? CatalogBrowsePreferences()
      let lease = await storage.lease(account: connection.id)
      guard generation == epoch else { return }
      self.service = service
      storageLease = lease
      installBrowser(service, connection: connection, preferences: preferences)
      installRestoredQueue(restored)
      busy = false
    } catch {
      guard generation == epoch else { return }
      session = .signedOut(suggested: nil)
      busy = false
      self.error = message(error)
    }
  }
  private func installRestoredQueue(
    _ result: (ready: QueueState, remainder: QueueState?), actions: [(PlayerStore) -> Void] = []
  ) {
    queue = result.ready
    if let remainder = result.remainder {
      let pending = QueueRestoration(
        remainder, stage: .remaining(result.ready.entries.map(\.track)))
      pending.actions = actions
      restoringQueue = pending
      retryQueueRestoration()
    } else {
      restoringQueue = nil
      let generation = epoch
      for action in actions where epoch == generation { action(self) }
    }
  }
  private func cancelQueueRestoration() {
    restoringQueue?.task?.cancel()
    restoringQueue = nil
    queueRestoreFailed = false
  }
  func retryQueueRestoration() {
    guard let pending = restoringQueue, pending.task == nil, let service, let browser else {
      return
    }
    queueRestoreFailed = false
    pending.task = Task(priority: .utility) { [weak self, weak pending] in
      do {
        try Task.checkCancellation()
        guard let pending else { return }
        let verified: [MusicItem]
        switch pending.stage {
        case .current:
          try await browser.prepareSavedQueueLibraries()
          let saved = pending.saved
          var result = try await saved.restoredForPlayback(using: service)
          try Task.checkCancellation()
          guard let self, self.restoringQueue === pending else { return }
          if saved.membershipRevision != pending.saved.membershipRevision {
            let retained = Set(pending.saved.entries.map(\.id))
            let revoked = Set(saved.entries.lazy.map(\.id).filter { !retained.contains($0) })
            result.ready.remove(revoked)
            result.remainder?.remove(revoked)
          }
          result.ready.quality = self.queue.quality
          self.installRestoredQueue(result, actions: pending.actions)
          return
        case .remaining(let items):
          verified = items
        }
        let known = Set(verified.map(\.id))
        let remaining = pending.saved.entries.compactMap {
          known.contains($0.track.id) ? nil : $0.track.id
        }
        let items: [MusicItem]
        do {
          items = try await service.validate(ids: remaining)
        } catch is CancellationError {
          try Task.checkCancellation()
          items = try await service.validate(ids: remaining)
        }
        try Task.checkCancellation()
        guard let self, self.restoringQueue === pending else { return }
        var complete = pending.checkpoint(self.queue)
        complete.reconcile(verified + items)
        self.restoringQueue = nil
        self.queue = complete
        self.prepareNext()
        let generation = self.epoch
        for action in pending.actions where self.epoch == generation { action(self) }
      } catch {
        guard let self, let pending, self.restoringQueue === pending, !Task.isCancelled else {
          return
        }
        pending.task = nil
        self.queueRestoreFailed = true
        if error as? ClientError == .unauthorized { await self.logout(ifCurrent: self.epoch) }
      }
    }
  }
  private func afterQueueRestoration(_ action: @escaping (PlayerStore) -> Void) -> Bool {
    guard let pending = restoringQueue else { return false }
    pending.actions.append(action)
    retryQueueRestoration()
    return true
  }
  private func installBrowser(
    _ service: any MusicCatalogServing, connection: Connection,
    preferences: CatalogBrowsePreferences
  ) {
    let account = connection.id
    let generation = epoch
    let snapshot = storageLease.map {
      PlaylistSnapshotAccess(storage: storage, account: account, lease: $0)
    }
    let model = MusicBrowser(
      service: service,
      isCurrent: { [weak self] in
        guard let self, self.epoch == generation else { return false }
        return self.active?.id == account
      }, preferences: preferences, playlistSnapshot: snapshot)
    model.preferencesChanged = { [weak self] value in
      guard let self, self.epoch == generation, self.active?.id == account,
        let lease = self.storageLease
      else { return }
      self.browseRevision += 1
      let revision = self.browseRevision
      Task {
        try? await self.storage.saveCatalogPreferencesIfCurrent(
          value, account: account, lease: lease, revision: revision)
      }
    }
    model.readSearchHistory = { [weak self] library in
      guard let self, self.epoch == generation, !Task.isCancelled,
        self.active?.id == account, let lease = self.storageLease,
        let owner = self.libraryOwner(library: library)
      else { return [] }
      await self.searchHistoryTask?.value
      guard self.epoch == generation, self.acceptsLibraryOwner(owner), !Task.isCancelled else {
        return []
      }
      return
        (try? await self.storage.searchRecents(account: account, lease: lease, library: library))
        ?? []
    }
    model.changeSearchHistory = { [weak self] value, removing in
      guard let self, self.epoch == generation, !Task.isCancelled,
        self.active?.id == account, let lease = self.storageLease,
        let owner = self.libraryOwner(library: value.library)
      else { return }
      self.searchHistoryRevision += 1
      let revision = self.searchHistoryRevision
      let previous = self.searchHistoryTask
      self.searchHistoryTask = Task { [weak self] in
        await previous?.value
        guard let self, self.epoch == generation, self.acceptsLibraryOwner(owner),
          !Task.isCancelled
        else { return }
        try? await self.storage.changeSearchRecent(
          value, removing: removing, account: account, lease: lease, revision: revision)
      }
    }
    model.authorizationFailed = { [weak self] reason in
      guard let self, self.epoch == generation else { return }
      if reason == .unauthorized { Task(operation: self.authorizationLogoutOperation()) }
    }
    model.libraryRetired = { [weak self] in
      guard let self, self.epoch == generation, let browser = self.browser else { return }
      self.clearPlaybackFailure()
      let authorized = Set(browser.libraries.map(\.id))
      self.libraryOwners = self.libraryOwners.filter { authorized.contains($0.key) }
      self.retireCovers(except: authorized)
      if let pending = self.preparation.pendingAlbum, !self.accepts(pending.origin) {
        self.cancelAlbumPlay(reason: .rootRetired)
      }
      for key in self.coverOrder where key.library.map({ !authorized.contains($0) }) == true {
        self.removeCover(key)
      }
    }
    model.librariesRevoked = { [weak self] removed in
      guard let self, self.epoch == generation else { return }
      self.retireUnavailablePlayback(removedLibraries: removed)
    }
    session = .signedIn(connection, model)
  }
  private func retireUnavailablePlayback(removedLibraries: Set<String>) {
    if let pending = restoringQueue {
      let ids = pending.saved.entries.compactMap { entry in
        entry.libraryID.map(removedLibraries.contains) == true ? entry.id : nil
      }
      if !ids.isEmpty {
        pending.saved.remove(Set(ids))
        persist()
      }
    }
    let removed = Set(
      queue.entries.filter { entry in
        entry.libraryID.map(removedLibraries.contains) == true
      }.map(\.id))
    guard !removed.isEmpty else { return }
    let oldCurrent = current
    let successorRemoved = queue.successor.map { removed.contains($0.id) } == true
    queue.remove(removed)
    persist()
    if let current = oldCurrent, !removed.contains(current.id) {
      guard successorRemoved else { return }
      retireSuccessor(.rootRetired)
      let generation = epoch
      let request = playID
      let retention = driver.retainCurrent(occurrence: current.id, keeping: nil)
      guard epoch == generation, playID == request else { return }
      switch retention {
      case .retained, .unbound:
        prepareNext()
        return
      case .changed:
        break
      }
    }
    phase = .paused
    stopDriver(reason: .rootRetired)
    persist()
  }
  private func authorizationLogoutOperation() -> @MainActor @Sendable () async -> Void {
    let generation = epoch
    return { await self.logout(ifCurrent: generation) }
  }
  #if DEBUG
    func deferredAuthorizationLogoutForCheck() -> @MainActor @Sendable () async -> Void {
      authorizationLogoutOperation()
    }
    func deferredPlaybackSettlementForCheck() -> @MainActor @Sendable () async -> Void {
      let current = preparation.task
      let next = successorPreparation?.task
      return {
        await current?.value
        await next?.value
      }
    }
  #endif
  func playerContent(occurrence: UUID) -> AlbumContent? {
    guard active != nil, let entry = current, entry.id == occurrence,
      let library = entry.libraryID, let owner = libraryOwner(library: library),
      acceptsLibraryOwner(owner), let service
    else { return nil }
    let revision = playerContentRevision
    return AlbumContent(
      album: entry.track, library: library, service: service,
      isCurrent: { [weak self] in
        guard let self, self.current?.id == occurrence, self.playerContentRevision == revision
        else { return false }
        return self.acceptsLibraryOwner(owner)
      },
      rejected: { [weak self] reason in
        guard let self, self.current?.id == occurrence, self.acceptsLibraryOwner(owner) else {
          return
        }
        if reason == .unauthorized { Task(operation: self.authorizationLogoutOperation()) }
      },
      favoriteChanged: { [weak self] in
        guard let self, self.current?.id == occurrence, self.acceptsLibraryOwner(owner) else {
          return
        }
        self.browser?.favoriteChanged(library: library)
      })
  }
  func playbackOrigin(library: String?) -> PlaybackOrigin? {
    guard let library, !library.isEmpty, let owner = libraryOwner(library: library),
      let root = owner.root
    else { return nil }
    return PlaybackOrigin(account: owner.account, library: library, root: root)
  }
  func playbackSelection(_ items: [MusicItem], library: String?)
    -> PlaybackSelection?
  {
    guard let origin = playbackOrigin(library: library),
      !items.isEmpty, items.allSatisfy({ $0.kind == "Audio" })
    else { return nil }
    return PlaybackSelection(items: items, origin: origin)
  }
  func playbackSelection(_ contents: PlaylistContents) -> PlaybackSelection? {
    let source = contents.source
    guard contents.allAudio, browser?.acceptsPlaylist(source) == true,
      let origin = playbackOrigin(library: source.library)
    else { return nil }
    return PlaybackSelection(items: contents.tracks, origin: origin, playlist: source)
  }
  func playAlbum(_ album: MusicItem, origin: PlaybackOrigin?) {
    guard let origin, accepts(origin), let api = service, album.kind == "MusicAlbum"
    else { return }
    consumeElapsedSleepTimer()
    cancelAlbumPlay()
    preparation.cancel()
    retireSuccessor(.superseded)
    let log = diagnostics.begin(.play, quality: DiagnosticQuality(queue.quality))
    log?.event(.intent, .init(.detail, .started))
    let request = PlaybackPreparation.AlbumRequest(
      origin: origin, albumID: album.id, diagnostic: log)
    playID = request.id
    let content = AlbumContent(
      album: album, library: origin.library, service: api,
      isCurrent: { [weak self] in self?.ownsAlbumPlay(request) == true },
      rejected: { [weak self] reason in
        guard let self, self.ownsAlbumPlay(request) else { return }
        _ = self.browser?.rejectAuthorization(reason)
      })
    let task = observedPreparationTask { [weak self] in
      guard self?.ownsAlbumPlay(request) == true, !Task.isCancelled else { return }
      await content.load()
      guard let self, self.preparation.pendingAlbum?.id == request.id else { return }
      guard self.ownsAlbumPlay(request), !Task.isCancelled else {
        self.preparation = .idle
        return
      }
      let selection = self.playbackSelection(content.tracks, library: content.authorizedLibrary)
      let detailError = content.error
      self.preparation = .idle
      guard let selection, detailError == nil else {
        log?.event(.intent, .init(.detail, .failed))
        log?.retire(.sourceRetired)
        self.error = detailError
        return
      }
      log?.event(.intent, .init(.detail, .succeeded))
      self.adoptItems(
        selection.items, origin: selection.origin, diagnostic: log, continuingIntent: true)
    }
    preparation = .album(request, task)
    driver.renewRemoteIntent()
  }
  func isPreparingAlbum(_ id: String, origin: PlaybackOrigin?) -> Bool {
    guard let pending = preparation.pendingAlbum, pending.origin == origin, pending.albumID == id
    else { return false }
    return ownsAlbumPlay(pending)
  }
  private func ownsAlbumPlay(_ request: PlaybackPreparation.AlbumRequest) -> Bool {
    preparation.pendingAlbum?.id == request.id && playID == request.id && accepts(request.origin)
  }
  private func cancelAlbumPlay(reason: DiagnosticReason = .superseded) {
    guard let request = preparation.pendingAlbum else { return }
    request.diagnostic?.retire(reason)
    preparation.cancel()
    playID = UUID()
  }
  func playbackCommandIsCurrent() -> @MainActor () -> Bool {
    let request = playID
    return { [weak self] in self?.playID == request }
  }
  func playSelection(_ selection: PlaybackSelection, startAt index: Int = 0) {
    guard accepts(selection) else { return }
    adoptItems(
      selection.items, startAt: index, origin: selection.origin, playlistID: selection.playlist?.id,
      continuingIntent: false)
  }
  private func accepts(_ selection: PlaybackSelection) -> Bool {
    guard accepts(selection.origin) else { return false }
    guard let source = selection.playlist else { return true }
    return browser?.acceptsPlaylist(source) == true
  }
  private func accepts(_ origin: PlaybackOrigin) -> Bool {
    origin.account == epoch && playbackOrigin(library: origin.library) == origin
  }
  func playItems(
    _ items: [MusicItem], startAt index: Int = 0, origin: PlaybackOrigin? = nil,
    library: String? = nil, diagnostic: DiagnosticContext? = nil
  ) {
    adoptItems(
      items, startAt: index, origin: origin, library: library,
      diagnostic: diagnostic, continuingIntent: false)
  }
  private func adoptItems(
    _ items: [MusicItem], startAt index: Int = 0, origin: PlaybackOrigin? = nil,
    library: String? = nil, diagnostic: DiagnosticContext? = nil, playlistID: String? = nil,
    continuingIntent: Bool
  ) {
    guard service != nil else { return }
    if let origin, !accepts(origin) { return }
    guard items.indices.contains(index), items.allSatisfy({ $0.kind == "Audio" }) else { return }
    if !continuingIntent { consumeElapsedSleepTimer() }
    let accepted = origin ?? playbackOrigin(library: library)
    var entries = items.map { QueueEntry($0, libraryID: accepted?.library) }
    let canonicalOrder = entries.map(\.id)
    if shuffleEnabled { entries[(index + 1)...].shuffle() }
    replaceQueueTarget(
      entries: entries, at: index, diagnostic: diagnostic, canonicalOrder: canonicalOrder,
      playlistID: playlistID)
  }
  func selectionIsCurrent(_ selection: PlaybackSelection) -> Bool {
    guard accepts(selection) else { return false }
    if let pending = restoringQueue {
      guard current != nil else { return false }
      return pending.matches(selection, account: epoch)
    }
    return queueMembership.matches(
      selection, shuffled: selection.playlist?.id != nil && shuffleEnabled)
  }
  func toggleSelection(_ selection: PlaybackSelection) {
    guard accepts(selection) else { return }
    if selectionIsCurrent(selection) { toggle() } else { playSelection(selection) }
  }
  func shuffleSelection(_ selection: PlaybackSelection) {
    guard accepts(selection), !selection.items.isEmpty,
      selection.items.allSatisfy({ $0.kind == "Audio" })
    else { return }
    consumeElapsedSleepTimer()
    let entries = selection.items.map { QueueEntry($0, libraryID: selection.origin.library) }
    replaceQueueTarget(
      entries: entries.shuffled(), at: 0, canonicalOrder: entries.map(\.id), shuffle: true,
      playlistID: selection.playlist?.id)
  }
  private func retainCurrentBeforeFutureEdit(keeping successor: () -> UUID? = { nil }) -> Bool {
    let generation = epoch
    let request = playID
    for _ in 0..<2 {
      guard epoch == generation, playID == request else { return false }
      let keep = successor()
      guard let incumbent = current?.id else { return true }
      let membership = queue.membershipRevision
      let mode = repeatMode
      let shuffled = shuffleEnabled
      let proof = driver.retainCurrent(occurrence: incumbent, keeping: keep)
      guard epoch == generation, playID == request, queue.membershipRevision == membership,
        repeatMode == mode, shuffleEnabled == shuffled
      else { return false }
      switch proof {
      case .retained, .unbound:
        return current?.id == incumbent
      case .changed:
        guard current?.id != incumbent else {
          if error == nil { error = "Playback changed before the queue edit. Try again." }
          return false
        }
      }
    }
    return false
  }
  func enqueueSelection(_ selection: PlaybackSelection, next: Bool) {
    guard accepts(selection), !selection.items.isEmpty,
      selection.items.allSatisfy({ $0.kind == "Audio" })
    else { return }
    if afterQueueRestoration({ $0.enqueueSelection(selection, next: next) }) { return }
    guard
      retainCurrentBeforeFutureEdit(keeping: {
        next ? nil : queue.lookahead(repeating: repeatMode)?.id
      }),
      accepts(selection.origin)
    else { return }
    let incumbent = current?.id
    let entries = selection.items.map { QueueEntry($0, libraryID: selection.origin.library) }
    if shuffleEnabled {
      let anchor = incumbent.flatMap { canonicalQueueOrder.firstIndex(of: $0) }
      canonicalQueueOrder.insert(
        contentsOf: entries.map(\.id),
        at: next ? anchor.map { $0 + 1 } ?? canonicalQueueOrder.count : canonicalQueueOrder.count)
    }
    queue.entries.insert(
      contentsOf: entries,
      at: next ? min(queue.index + 1, queue.entries.count) : queue.entries.count)
    persist()
    prepareNext()
  }
  @discardableResult func setRepeatMode(_ mode: RepeatMode) -> Task<Void, Never>? {
    guard active != nil, mode != repeatMode,
      retainCurrentBeforeFutureEdit(keeping: { queue.lookahead(repeating: mode)?.id })
    else { return nil }
    let retired = mode == .one ? successorPreparation?.task : nil
    repeatMode = mode
    prepareNext()
    return retired
  }
  func toggleShuffle() {
    if afterQueueRestoration({ $0.toggleShuffle() }) { return }
    var reordered: [QueueEntry] = []
    guard active != nil,
      retainCurrentBeforeFutureEdit(keeping: {
        reordered = queue.orderingFuture(restoring: shuffleEnabled ? canonicalQueueOrder : nil)
        guard repeatMode != .one, reordered.indices.contains(queue.index + 1) else { return nil }
        return reordered[queue.index + 1].id
      })
    else { return }
    if !shuffleEnabled {
      canonicalQueueOrder = queue.entries.map(\.id)
    }
    shuffleEnabled.toggle()
    if queue.index + 1 < reordered.count { queue.entries = reordered }
    prepareNext()
    persist()
  }
  @discardableResult func setSleepTimer(minutes: Int?) -> Task<Void, Never>? {
    guard active != nil else { return nil }
    guard let minutes else {
      cancelSleepTimer()
      return nil
    }
    guard current != nil, [15, 30, 60].contains(minutes) else { return nil }
    cancelSleepTimer()
    let deadline = now().addingTimeInterval(Double(minutes) * 60)
    let request = UUID()
    let account = epoch
    let wait = sleepUntil
    sleepTimerID = request
    sleepTimerDeadline = deadline
    sleepTimerTask = Task { [weak self] in
      do { try await wait(deadline) } catch { return }
      guard let self, !Task.isCancelled, self.active != nil, self.epoch == account,
        self.sleepTimerID == request, self.sleepTimerDeadline == deadline, self.now() >= deadline
      else { return }
      self.sleepTimerDeadline = nil
      self.sleepTimerTask = nil
      self.sleepTimerID = UUID()
      self.pause()
    }
    return sleepTimerTask
  }
  private func consumeElapsedSleepTimer() {
    if let deadline = sleepTimerDeadline, now() >= deadline { cancelSleepTimer() }
  }
  private func cancelSleepTimer() {
    sleepTimerID = UUID()
    sleepTimerTask?.cancel()
    sleepTimerTask = nil
    sleepTimerDeadline = nil
  }
  func addConnection() {
    guard !removingSavedConnection, pendingSignOut == nil else { return }
    persist()
    retire()
    busy = false
    isFixture = false
  }
  private func coverKey(_ item: MusicItem, library: String?) -> CoverKey {
    CoverKey(library: library, image: item.imageID ?? item.id, tag: item.imageTag)
  }
  private func cover(_ item: MusicItem, library: String?) -> Data? {
    covers[coverKey(item, library: library)]
  }
  func cover(_ item: MusicItem?, origin: PlaybackOrigin? = nil) -> Data? {
    if let origin, !accepts(origin) { return nil }
    return item.flatMap { cover($0, library: origin?.library ?? browser?.libraryID) }
  }
  func coverTone(_ item: MusicItem, origin: PlaybackOrigin?) -> ArtworkTone? {
    guard let origin, accepts(origin) else { return nil }
    return coverTones[coverKey(item, library: origin.library)]
  }
  var playbackArtwork: Data? {
    current.flatMap { cover($0.track, library: $0.libraryID) }
  }
  private func authority(for entry: QueueEntry, replacement: UUID) -> PlaybackAuthority? {
    guard active != nil, let library = entry.libraryID, !library.isEmpty,
      browser?.libraries.contains(where: { $0.id == library }) == true
    else { return nil }
    return PlaybackAuthority(account: epoch, replacement: replacement, library: library)
  }
  private func prepared(_ entry: QueueEntry, source: MediaSource, diagnostic: DiagnosticContext?)
    -> PreparedEntry
  {
    let authority = authority(for: entry, replacement: playbackIntentID)
    return PreparedEntry(
      entry: entry, source: source, authority: authority,
      artwork: cover(entry.track, library: entry.libraryID),
      diagnostic: diagnostic?.handoff(scope: .nativeItem))
  }
  func loadCover(_ item: MusicItem, origin: PlaybackOrigin? = nil) async {
    if let origin, !accepts(origin) { return }
    guard let service else { return }
    let owner = libraryOwner(library: origin?.library ?? browser?.libraryID)
    guard item.imageID != nil else { return }
    _ = await requestCover(item, owner: owner, service: service)
  }
  private func libraryOwner(library: String?) -> LibraryOwner? {
    guard active != nil else { return nil }
    if let library {
      guard browser?.libraries.contains(where: { $0.id == library }) == true else { return nil }
      if libraryOwners[library] == nil { libraryOwners[library] = UUID() }
    }
    return LibraryOwner(
      account: epoch, library: library, root: library.flatMap { libraryOwners[$0] })
  }
  private func acceptsLibraryOwner(_ owner: LibraryOwner) -> Bool {
    guard active != nil, epoch == owner.account else { return false }
    return owner.library.map { root in
      browser?.libraries.contains(where: { $0.id == root }) == true
        && libraryOwners[root] == owner.root
    } ?? true
  }
  private func requestCover(
    _ item: MusicItem, owner: LibraryOwner?, service: any MusicCatalogServing
  ) async -> Data? {
    guard let owner, acceptsLibraryOwner(owner), !Task.isCancelled else { return nil }
    let library = owner.library
    let key = coverKey(item, library: library)
    if let cached = covers[key] { return Task.isCancelled ? nil : cached }
    let consumer = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled, acceptsLibraryOwner(owner) else {
          continuation.resume(returning: nil)
          return
        }
        if let request = coverRequests[key] {
          request.consumers[consumer] = continuation
          return
        }
        let request = CoverRequest()
        request.consumers[consumer] = continuation
        coverRequests[key] = request
        let token = request.id
        request.producer = Task { [weak self] in
          let data: Data?
          do {
            try Task.checkCancellation()
            if let bytes = try await service.artwork(item: item), bytes.count <= 3_000_000 {
              data = await self?.prepareCover(bytes)
            } else {
              data = nil
            }
          } catch { data = nil }
          guard let self, self.acceptsLibraryOwner(owner), !Task.isCancelled,
            self.coverRequests[key]?.id == token
          else { return }
          let tone =
            if let data, data.count <= 3_000_000 { await self.artworkTone(data) } else {
              nil as ArtworkTone?
            }
          self.finishCover(data, tone: tone, key: key, token: token, owner: owner)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelCoverConsumer(consumer, key: key) }
    }
  }
  #if DEBUG
    func deferredCoverRequestForCheck(
      _ item: MusicItem, origin: PlaybackOrigin
    ) -> @MainActor @Sendable () async -> Void {
      guard accepts(origin), let service else { return {} }
      let owner = libraryOwner(library: origin.library)
      return { [weak self] in
        _ = await self?.requestCover(item, owner: owner, service: service)
      }
    }
  #endif
  private func finishCover(
    _ data: Data?, tone: ArtworkTone?, key: CoverKey, token: UUID, owner: LibraryOwner
  ) {
    guard let request = coverRequests[key], request.id == token else { return }
    coverRequests[key] = nil
    let accepted = acceptsLibraryOwner(owner)
    let bounded = accepted ? data.flatMap { $0.count <= 3_000_000 ? $0 : nil } : nil
    if let bounded {
      insertCover(bounded, key: key)
      coverTones[key] = tone
    }
    for consumer in request.consumers.values { consumer.resume(returning: bounded) }
  }
  private func cancelCoverConsumer(_ consumer: UUID, key: CoverKey) {
    guard let request = coverRequests[key],
      let continuation = request.consumers.removeValue(forKey: consumer)
    else { return }
    continuation.resume(returning: nil)
    if request.consumers.isEmpty {
      coverRequests[key] = nil
      request.producer?.cancel()
    }
  }
  private func retireCovers(except authorized: Set<String>?) {
    for (key, request) in coverRequests
    where authorized.map({ roots in key.library.map(roots.contains) ?? true }) != true {
      coverRequests[key] = nil
      request.producer?.cancel()
      for consumer in request.consumers.values { consumer.resume(returning: nil) }
    }
  }
  private func removeCover(_ key: CoverKey) {
    if let old = covers.removeValue(forKey: key) { coverBytes -= old.count }
    coverTones[key] = nil
    coverOrder.removeAll { $0 == key }
  }
  private func insertCover(_ data: Data, key: CoverKey) {
    removeCover(key)
    covers[key] = data
    coverBytes += data.count
    coverOrder.append(key)
    let currentKey = current.map { coverKey($0.track, library: $0.libraryID) }
    while covers.count > Self.coverCountLimit || coverBytes > Self.coverByteLimit {
      guard let oldest = coverOrder.first(where: { $0 != currentKey }) else { break }
      removeCover(oldest)
    }
  }
  func saveNow() async throws {
    guard let active, let lease = storageLease else { return }
    saveRevision += 1
    try await storage.saveIfCurrent(
      queueCheckpoint, account: active.id, lease: lease, revision: saveRevision)
  }
  private func observedPreparationTask(
    _ work: @escaping @MainActor @Sendable () async -> Void
  ) -> Task<Void, Never> {
    #if DEBUG
      let context = TransportCapture.shared.context()
      return Task { await TransportCapture.$caller.withValue(context, operation: work) }
    #else
      return Task { await work() }
    #endif
  }
  func play() {
    playCommandRevision &+= 1
    consumeElapsedSleepTimer()
    cancelAlbumPlay()
    startPlayback()
  }
  private func startPlayback(
    replacement: UUID? = nil, position: Double? = nil, diagnostic: DiagnosticContext? = nil,
    continuingIntent: UUID? = nil
  ) {
    guard let current = queue.current, let api = service else { return }
    let generation = epoch
    let admission = playID
    let log =
      diagnostic
      ?? diagnostics.begin(
        phase == .failed ? .retry : .play, quality: DiagnosticQuality(queue.quality))
    if playbackDiagnostic !== log { playbackDiagnostic?.retire(.superseded) }
    playbackDiagnostic = log
    error = nil
    phase = .preparing
    let resumed = driver.resume(id: current.id)
    guard ownsCommand(generation, admission, current.id), playbackRequested else { return }
    if resumed {
      log?.event(.playback, .init(.native, .succeeded))
      if phase == .preparing { phase = .waiting }
      prepareNext()
      return
    }
    seekPresentation = nil
    preparation.cancel()
    retireSuccessor(.superseded)
    let request = replacement ?? UUID()
    playID = request
    var snapshot = queue
    if let position {
      snapshot.position = max(0, position)
    } else if let pendingIntent, pendingIntent.target == current,
      pendingIntent.authority.account == generation,
      authority(for: current, replacement: request) != nil
    {
      snapshot.position = pendingIntent.position
    }
    let state = snapshot
    let intent =
      continuingIntent
      ?? (position != nil ? pendingIntent?.authority.replacement ?? request : request)
    playbackIntentID = intent
    let replacementIntent = authority(for: current, replacement: intent).map {
      PlaybackReplacement(
        target: current, authority: $0, position: state.position,
        artwork: cover(current.track, library: current.libraryID),
        diagnostic: log?.handoff(scope: .nativeItem))
    }
    pendingIntent = replacementIntent
    if let replacementIntent { _ = driver.prepareReplacement(replacementIntent) }
    guard ownsCommand(generation, request, current.id), playbackRequested else { return }
    let failureOwner = diagnosticOwner
    log?.event(.playback, .init(.source, .preparing))
    let deadline = Task { [weak self, preparationSleep, preparationTimeout] in
      do { try await preparationSleep(preparationTimeout) } catch { return }
      guard let self, !Task.isCancelled, self.ownsCommand(generation, request, current.id),
        self.playbackRequested
      else { return }
      let record = log?.event(.playback, .init(.source, .failed, reason: .deadline))
      self.phase = .failed
      let stopped = self.stopDriver(reason: .deadline)
      guard self.ownsCommand(generation, stopped, current.id), self.phase == .failed else { return }
      self.recordPlaybackFailure(
        ConnectionStepError(step: .preparationDeadline, error: PlaybackProblem.stalled),
        owner: failureOwner, diagnostic: record)
      self.error = "Playback couldn’t prepare. Check your connection and tap Play to retry."
      self.persist()
    }
    let sourceLibrary = current.libraryID
    let sourceBrowser = browser
    let preparationIsCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
      guard let self else { return false }
      return self.ownsMediaPreparation(generation, request, intent, current)
        && self.browser === sourceBrowser
    }
    let task = observedPreparationTask { [weak self] in
      defer {
        if let self, self.playID == request { self.preparation.finish() }
      }
      var step = ConnectionStepError.Step.playbackSource
      var sourceOwner: LibraryOwner?
      do {
        try Task.checkCancellation()
        guard let sourceLibrary, !sourceLibrary.isEmpty, let sourceBrowser else {
          throw PlaybackProblem.noSource
        }
        guard preparationIsCurrent() else { return }
        let admitted = await sourceBrowser.admitPlaybackLibrary(sourceLibrary)
        try Task.checkCancellation()
        guard let self, preparationIsCurrent() else { return }
        guard admitted, let owner = self.libraryOwner(library: sourceLibrary) else {
          throw PlaybackProblem.noSource
        }
        sourceOwner = owner
        let mediaIsCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
          guard let self, preparationIsCurrent() else { return false }
          return self.acceptsLibraryOwner(owner)
        }
        let negotiated = try await api.media(
          library: sourceLibrary, trackID: current.track.id, quality: state.quality,
          isCurrent: mediaIsCurrent)
        try Task.checkCancellation()
        guard mediaIsCurrent() else { return }
        let source = try negotiated.starting(at: state.position)
        step = .playbackAudio
        guard self.preparation.handOffToNative() else { return }
        self.nativeDiagnosticOwner = failureOwner
        try await self.driver.start(
          [self.prepared(current, source: source, diagnostic: log)], position: state.position)
        guard mediaIsCurrent() else { return }
        self.persist()
      } catch {
        guard let self, preparationIsCurrent(), !Task.isCancelled,
          sourceOwner.map(self.acceptsLibraryOwner) ?? true
        else { return }
        let record = log?.event(.playback) {
          .failure(ConnectionStepError(step: step, error: error), stage: .source)
        }
        self.phase = .failed
        let stopped = self.stopDriver()
        guard self.ownsCommand(generation, stopped, current.id), self.phase == .failed else {
          return
        }
        self.recordPlaybackFailure(
          ConnectionStepError(step: step, error: error), owner: failureOwner, diagnostic: record)
        self.error = self.message(
          error is URLError ? ConnectionStepError(step: step, error: error) : error)
        self.persist()
        if error as? ClientError == .unauthorized { await self.logout(ifCurrent: self.epoch) }
        if error as? ClientError == .forbidden {
          self.restoringQueue?.saved.remove([current.id])
          self.queue.remove([current.id])
          self.stopDriver()
          self.persist()
        }
      }
    }
    preparation = .source(task, deadline: deadline)
  }
  private func ownsMediaPreparation(
    _ generation: UUID, _ request: UUID, _ listening: UUID, _ entry: QueueEntry
  ) -> Bool {
    ownsCommand(generation, request, entry.id) && playbackIntentID == listening
      && playbackRequested && current?.libraryID == entry.libraryID
  }
  private func observeCurrentForCommand() -> Bool {
    let generation = epoch
    let request = playID
    let listening = playbackIntentID
    let requested = playbackRequested
    let failed = phase == .failed
    let failure = lastPlaybackFailure?.id
    let accepted = driver.observeCurrent()
    guard epoch == generation else { return false }
    if playID == request {
      return accepted
        || (failed && phase == .failed && lastPlaybackFailure?.id == failure)
    }
    return accepted && requested && playbackRequested && playbackIntentID == listening
  }
  private func ownsCommand(_ generation: UUID, _ request: UUID, _ occurrence: UUID?) -> Bool {
    epoch == generation && playID == request && current?.id == occurrence
  }
  func pause() {
    guard observeCurrentForCommand() else { return }
    let generation = epoch
    let occurrence = current?.id
    cancelAlbumPlay(reason: .userPause)
    playbackDiagnostic?.event(.intent, .init(.command, .paused, reason: .userPause))
    playbackDiagnostic?.retire(.userPause)
    playbackDiagnostic = nil
    retireSuccessor(.userPause)
    seekDiagnostic?.retire(.userPause)
    seekDiagnostic = nil
    phase = .paused
    pendingIntent = nil
    playID = UUID()
    let request = playID
    preparation.cancel()
    driver.pause()
    guard ownsCommand(generation, request, occurrence) else { return }
    persist()
  }
  func toggle() { playbackRequested ? pause() : play() }
  func select(_ id: UUID) {
    guard let index = queue.entries.firstIndex(where: { $0.id == id }) else { return }
    replaceQueueTarget(at: index)
  }
  func next() {
    if queue.successor == nil && deferRestoredNavigation(forward: true) { return }
    guard let index = queue.nextIndex(repeating: repeatMode) else {
      pause()
      return
    }
    replaceQueueTarget(entries: queue.entries, at: index, action: .next)
  }
  private func replaceQueueTarget(at index: Int) {
    replaceQueueTarget(entries: queue.entries, at: index)
  }
  private func replaceQueueTarget(
    entries: [QueueEntry], at index: Int, diagnostic: DiagnosticContext? = nil,
    action: DiagnosticAction = .selection, canonicalOrder: [UUID]? = nil, shuffle: Bool? = nil,
    playlistID: String? = nil
  ) {
    cancelAlbumPlay()
    let generation = epoch
    let admission = playID
    let membership = queue.membershipRevision
    let mode = shuffleEnabled
    let order = canonicalQueueOrder
    let occurrence = current?.id
    func ownsReplacement(_ request: UUID, _ occurrence: UUID?) -> Bool {
      ownsCommand(generation, request, occurrence) && queue.membershipRevision == membership
        && shuffleEnabled == mode && canonicalQueueOrder == order
    }
    let target = entries[index]
    let log = diagnostic ?? diagnostics.begin(action, quality: DiagnosticQuality(queue.quality))
    guard ownsReplacement(admission, occurrence) else {
      log?.retire(.superseded)
      return
    }
    let advanced = playbackRequested && driver.advancePrepared(to: target.id)
    guard ownsReplacement(admission, advanced ? target.id : occurrence) else {
      log?.retire(.superseded)
      return
    }
    if advanced {
      playbackDiagnostic?.retire(.superseded)
      playbackDiagnostic = log
      log?.event(.playback, .init(.native, .succeeded))
      return
    }
    let request = UUID()
    let replacement = authority(for: target, replacement: request).map {
      PlaybackReplacement(
        target: target, authority: $0, artwork: cover(target.track, library: target.libraryID),
        diagnostic: log?.handoff(scope: .nativeItem))
    }
    let stopped = stopDriver(replacing: replacement)
    guard ownsReplacement(stopped, occurrence) else {
      log?.retire(.superseded)
      return
    }
    var replacementQueue = queue
    replacementQueue.entries = entries
    replacementQueue.index = index
    replacementQueue.position = 0
    if let canonicalOrder {
      cancelQueueRestoration()
      canonicalQueueOrder = canonicalOrder
      replacementQueue.playlistID = playlistID
    }
    queue = replacementQueue
    if let shuffle { shuffleEnabled = shuffle }
    persist()
    startPlayback(replacement: request, diagnostic: log)
  }
  func previous() {
    if queue.position > 3 {
      seek(0)
    } else if queue.index > 0 {
      select(queue.entries[queue.index - 1].id)
    } else if deferRestoredNavigation(forward: false) {
      return
    } else if repeatMode == .all, let last = queue.entries.last {
      select(last.id)
    }
  }
  private func deferRestoredNavigation(forward: Bool) -> Bool {
    guard let pending = restoringQueue, let occurrence = current?.id,
      let index = pending.saved.entries.firstIndex(where: { $0.id == occurrence }),
      repeatMode == .all || (forward ? index + 1 < pending.saved.entries.count : index > 0)
    else { return false }
    let request = playID
    return afterQueueRestoration { store in
      guard store.playID == request, store.current?.id == occurrence else { return }
      if forward { store.next() } else { store.previous() }
    }
  }
  func seek(_ seconds: Double, occurrence: UUID? = nil) {
    guard seconds.isFinite, observeCurrentForCommand() else { return }
    guard occurrence == nil || occurrence == current?.id else { return }
    cancelAlbumPlay()
    let generation = epoch
    let command = playID
    let producer = current?.id
    seekDiagnostic?.retire(.superseded)
    let log = diagnostics.begin(.seek, quality: DiagnosticQuality(queue.quality))
    seekDiagnostic = log
    log?.event(.intent, .init(.seek, .started))
    let target = min(max(0, seconds), max(0, seekUpperBound - 0.05))
    if let current, driver.hasPending(current.id), playbackRequested {
      startPlayback(position: target, diagnostic: log)
      return
    }
    if let current, driver.hasPrepared(current.id),
      queue.quality == .original || driver.hasCompleteLocalFile(occurrence: current.id)
    {
      if driver.requiresSourceReplacementForSeek(occurrence: current.id, position: target) {
        if playbackRequested {
          rebuildAfterEdit(position: target)
        } else {
          choosePausedOriginalPosition(target, generation: generation, occurrence: producer)
        }
        return
      }
      let request = UUID()
      seekPresentation = (current.id, request, target)
      driver.seek(target, request: request)
      guard ownsCommand(generation, command, producer),
        seekPresentation == nil || seekPresentation?.request == request
      else { return }
      persist()
      return
    }
    if queue.quality != .original, playbackRequested, let current, driver.hasPrepared(current.id) {
      rebuildAfterEdit(position: target)
      return
    }
    if queue.quality == .original, !playbackRequested {
      choosePausedOriginalPosition(target, generation: generation, occurrence: producer)
      return
    }
    queue.position = target
    queue.normalize()
    if queue.quality != .original {
      rebuildAfterEdit()
    } else {
      driver.seek(queue.position)
      guard ownsCommand(generation, command, producer) else { return }
      persist()
    }
  }
  private func choosePausedOriginalPosition(
    _ target: Double, generation: UUID, occurrence: UUID?
  ) {
    let stopped = stopDriver()
    guard ownsCommand(generation, stopped, occurrence), !playbackRequested else { return }
    queue.position = target
    queue.normalize()
    phase = .paused
    persist()
  }
  func quality(_ quality: StreamQuality) {
    guard quality != queue.quality, observeCurrentForCommand() else { return }
    let generation = epoch
    let request = playID
    let producer = current?.id
    driver.pause()
    guard ownsCommand(generation, request, producer) else { return }
    queue.quality = quality
    rebuildAfterEdit()
  }
  func enqueue(_ track: MusicItem, next: Bool, origin: PlaybackOrigin? = nil) {
    guard
      let origin = origin
        ?? playbackOrigin(library: current?.libraryID ?? browser?.authorizedLibrary)
    else { return }
    enqueueSelection(PlaybackSelection(items: [track], origin: origin), next: next)
  }
  func remove(_ ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    if afterQueueRestoration({ $0.remove(ids) }) { return }
    editQueue(
      { $0.remove(ids) }, commitOrder: { canonicalQueueOrder.removeAll { ids.contains($0) } })
  }
  func move(from: Int, to: Int) {
    guard queue.entries.indices.contains(from), to >= 0, to <= queue.entries.count else { return }
    if let pending = restoringQueue {
      let moved = queue.entries[from].id
      let before =
        queue.entries.indices.contains(to)
        ? queue.entries[to].id
        : queue.entries.last.flatMap { last in
          guard let index = pending.saved.entries.firstIndex(where: { $0.id == last.id }),
            pending.saved.entries.indices.contains(index + 1)
          else { return nil }
          return pending.saved.entries[index + 1].id
        }
      _ = afterQueueRestoration { store in
        let entries = store.queue.entries
        guard let from = entries.firstIndex(where: { $0.id == moved }) else { return }
        let to = before.flatMap { id in entries.firstIndex { $0.id == id } } ?? entries.count
        store.move(from: from, to: to)
      }
      return
    }
    editQueue(
      { $0.move(from: from, to: to) },
      commitOrder: {
        shuffleEnabled = false
        canonicalQueueOrder = []
      })
  }
  private func editQueue(_ edit: (inout QueueState) -> Void, commitOrder: () -> Void) {
    let membership = queue.membershipRevision
    guard observeCurrentForCommand(), queue.membershipRevision == membership else { return }
    var edited = queue
    edit(&edited)
    let rebind = edited.current?.id == current?.id && edited.successor?.id != queue.successor?.id
    if rebind {
      guard retainCurrentBeforeFutureEdit(), queue.membershipRevision == membership else { return }
      edited = queue
      edit(&edited)
    }
    let replacesCurrent = edited.current?.id != current?.id
    queue = edited
    commitOrder()
    if replacesCurrent {
      rebuildAfterEdit()
    } else {
      if rebind { prepareNext() }
      persist()
    }
  }
  private func rebuildAfterEdit(position: Double? = nil) {
    let generation = epoch
    let producer = current?.id
    let resume = playbackRequested
    let stopped = stopDriver()
    guard ownsCommand(generation, stopped, producer) else { return }
    persist()
    if resume && current != nil {
      startPlayback(position: position)
    } else {
      phase = .paused
    }
  }
  private func updateNowPlayingArtwork() {
    artworkTask?.cancel()
    let request = UUID()
    artworkRequest = request
    guard let entry = current, let api = service, let account = active?.id else { return }
    if let data = cover(entry.track, library: entry.libraryID) {
      driver.updateArtwork(data, occurrence: entry.id)
      return
    }
    driver.updateArtwork(nil, occurrence: entry.id)
    let generation = epoch
    let owner = libraryOwner(library: entry.libraryID)
    artworkTask = Task { [weak self] in
      let data = await self?.requestCover(entry.track, owner: owner, service: api)
      guard let self, !Task.isCancelled, self.epoch == generation,
        self.active?.id == account, self.artworkRequest == request,
        self.current?.id == entry.id, self.current?.track == entry.track
      else { return }
      guard let data, data.count <= 3_000_000 else { return }
      self.driver.updateArtwork(data, occurrence: entry.id)
    }
  }
  private func receive(_ event: DriverEvent) {
    guard active != nil, phase != .failed else { return }
    switch event {
    case .sourceDuration(let id, let duration):
      guard current?.id == id else { return }
      sourceDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    case .timeline(let id, let duration, let seekableEnd):
      guard current?.id == id else { return }
      nativeDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
      self.seekableEnd = seekableEnd.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    case .seekCancelled(let id, let request):
      guard current?.id == id, seekPresentation?.request == request else { return }
      seekPresentation = nil
    case .position(let id, let seconds), .seekCompleted(let id, let seconds, _):
      guard current?.id == id, seconds.isFinite else { return }
      if case .seekCompleted(_, _, let request) = event {
        guard request == seekPresentation?.request else { return }
        seekPresentation = nil
      }
      queue.position = max(0, seconds)
      if pendingIntent?.target.id == id { pendingIntent = nil }
      let second = Int(seconds)
      if case .seekCompleted = event {
        seekDiagnostic?.event(.playback, .init(.seek, .succeeded))
        seekDiagnostic = nil
        persist()
      } else if second != lastSavedSecond && second % 5 == 0 {
        lastSavedSecond = second
        persist()
      }
    case .advanced(let id):
      if id != current?.id {
        guard playbackRequested, queue.lookahead(repeating: repeatMode)?.id == id else { return }
        clearTimeline()
        queue.index += 1
        queue.position = 0
        persist()
      }
      prepareNext()
      updateNowPlayingArtwork()
    case .state(let occurrence, let state):
      guard current?.id == occurrence, playbackRequested else { return }
      phase = state == .playing ? .playing : .waiting
      if state == .playing { acceptRecentAlbum(occurrence) }
    case .finished(let id):
      guard current?.id == id else { return }
      finishCurrent()
    case .failure, .failureDetails:
      if case .failureDetails(let occurrence, let detail) = event {
        guard current?.id == occurrence else { return }
        if let owner = nativeDiagnosticOwner { recordPlaybackFailure(detail, owner: owner) }
      } else if let owner = nativeDiagnosticOwner {
        recordPlaybackFailure(
          ConnectionStepError(step: .playbackAudio, error: PlaybackProblem.nativeStart),
          owner: owner)
      }
      cancelAlbumPlay()
      playID = UUID()
      preparation.cancel()
      retireSuccessor(.sourceRetired)
      seekPresentation = nil
      phase = .failed
      if case .failureDetails(_, let detail) = event,
        detail.category == .expiredAudioSession
          || (detail.diagnosticDomain == .avFoundation && detail.code == -11819)
      {
        error = detail.localizedDescription
      } else {
        error = "Playback stopped. Check your connection and tap Play to retry."
      }
      persist()
    }
  }
  private func finishCurrent() {
    let listening = playbackIntentID
    let advance = playbackRequested && preparation.pendingAlbum == nil
    let completion =
      advance
      ? queue.completion(repeating: repeatMode, failedSuccessor: nextRequiresRetry) : .stop
    playbackDiagnostic?.event(.playback, .init(.native, .ended))
    playbackDiagnostic?.retire(.sourceRetired)
    playbackDiagnostic = nil
    clearTimeline()
    artworkRequest = UUID()
    artworkTask?.cancel()
    phase = .paused
    if preparation.pendingAlbum == nil {
      playID = UUID()
      preparation.cancel()
    }
    retireSuccessor(.sourceRetired)
    queue.position = 0
    if advance, repeatMode != .one, queue.successor == nil,
      deferRestoredNavigation(forward: true)
    {
      persist()
      return
    }
    switch completion {
    case .stop: break
    case .awaitRetry(let index):
      queue.index = index
      phase = .failed
      error = "The next track couldn’t load. Tap Play to retry."
    case .play(let index):
      queue.index = index
      pendingIntent = nil
      startPlayback(position: 0, continuingIntent: listening)
    }
    persist()
  }
  func loadRecentAlbums() async {
    guard let browser, let library = browser.libraryID, let account = active?.id else { return }
    let generation = epoch
    let scope = browser.scope
    let request = UUID()
    recentLoadID = request
    let ids = (try? await storage.recentAlbums(account: account, library: library)) ?? []
    guard epoch == generation, active?.id == account, self.browser === browser,
      recentLoadID == request, browser.scope == scope, !Task.isCancelled
    else { return }
    await browser.loadRecentAlbums(ids, scope: scope)
  }
  private func acceptRecentAlbum(_ occurrence: UUID) {
    guard recentOccurrence != occurrence, current?.id == occurrence,
      let album = current?.track.albumID, let library = current?.libraryID,
      let account = active?.id, let lease = storageLease
    else { return }
    recentOccurrence = occurrence
    recentRevision += 1
    let acceptedRevision = recentRevision
    recentLoadID = UUID()
    let generation = epoch
    let storage = storage
    recentTask = Task { [weak self] in
      guard let self, self.epoch == generation, self.active?.id == account,
        self.storageLease == lease
      else { return }
      try? await storage.acceptRecentAlbum(
        account: account, lease: lease, library: library, album: album, revision: acceptedRevision)
      guard self.epoch == generation, self.active?.id == account else { return }
      if self.browser?.libraryID == library { await self.loadRecentAlbums() }
    }
  }
  func retryNext() {
    guard playbackRequested, nextRequiresRetry else { return }
    retireSuccessor(.superseded)
    prepareNext(
      diagnostic: diagnostics.begin(
        .retry, quality: DiagnosticQuality(queue.quality), role: .successor))
  }
  private func retireSuccessor(_ reason: DiagnosticReason) {
    guard let retired = successorPreparation else { return }
    successorPreparation = nil
    retired.task?.cancel()
    retired.diagnostic?.retire(reason)
  }
  private func prepareNext(diagnostic: DiagnosticContext? = nil) {
    guard playbackRequested, let api = service, let current,
      let entry = queue.lookahead(repeating: repeatMode)
    else {
      retireSuccessor(.superseded)
      return
    }
    guard successorPreparation?.occurrence != entry.id else { return }
    retireSuccessor(.superseded)
    guard driver.hasPrepared(current.id), !driver.hasPrepared(entry.id) else { return }
    let attempt = UUID()
    let log = diagnostic ?? playbackDiagnostic?.handoff(role: .successor)
    guard let sourceLibrary = entry.libraryID,
      let sourceOwner = libraryOwner(library: sourceLibrary),
      let currentLibrary = current.libraryID,
      let currentOwner = libraryOwner(library: currentLibrary)
    else {
      successorPreparation = SuccessorPreparation(
        id: attempt, occurrence: entry.id, diagnostic: log, phase: .failed)
      log?.event(.playback) {
        .failure(
          ConnectionStepError(step: .playbackSource, error: PlaybackProblem.noSource),
          stage: .source)
      }
      return
    }
    let quality = queue.quality
    let generation = epoch
    let request = playID
    let listening = playbackIntentID
    let ownsSource: @MainActor @Sendable () -> Bool = { [weak self] in
      guard let self, self.successorPreparation?.id == attempt else { return false }
      return self.ownsMediaPreparation(generation, request, listening, current)
        && self.acceptsLibraryOwner(currentOwner) && self.acceptsLibraryOwner(sourceOwner)
        && self.queue.lookahead(repeating: self.repeatMode) == entry
    }
    let mediaIsCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
      guard let self, ownsSource(), self.driver.hasPrepared(current.id) else { return false }
      return ownsSource()
    }
    let task = observedPreparationTask { [weak self] in
      do {
        try Task.checkCancellation()
        let source = try await api.media(
          library: sourceLibrary, trackID: entry.track.id, quality: quality,
          isCurrent: mediaIsCurrent)
        try Task.checkCancellation()
        guard let self, mediaIsCurrent() else { return }
        try await self.driver.append(
          self.prepared(entry, source: source, diagnostic: log), isCurrent: mediaIsCurrent)
        guard !Task.isCancelled, ownsSource() else { return }
        self.successorPreparation?.phase = .awaitingTurn
      } catch {
        guard let self, !Task.isCancelled, mediaIsCurrent() else { return }
        if error as? ClientError == .unauthorized {
          await self.logout(ifCurrent: self.epoch)
        } else {
          log?.event(.playback) {
            .failure(ConnectionStepError(step: .playbackSource, error: error), stage: .source)
          }
          guard self.successorPreparation?.id == attempt else { return }
          self.successorPreparation?.phase = .failed
        }
      }
    }
    successorPreparation = SuccessorPreparation(
      id: attempt, occurrence: entry.id, diagnostic: log, phase: .loading(task))
  }
  func persist() {
    guard let active, let lease = storageLease else { return }
    saveRevision += 1
    let snapshot = queueCheckpoint
    let storage = storage
    let revision = saveRevision
    Task {
      try? await storage.saveIfCurrent(
        snapshot, account: active.id, lease: lease, revision: revision)
    }
  }
  #if DEBUG
    struct TransportAcceptanceLease: Sendable {
      fileprivate let epoch: UUID
      fileprivate let intent: UUID
    }
    enum TransportAcceptanceAction {
      case play(PlaybackSelection)
      case next, pause
    }
    @MainActor private final class TransportActivationReceipt {
      let storeIdentity: ObjectIdentifier
      private(set) var accepted: TransportAcceptanceLease?
      init(store: PlayerStore) { storeIdentity = ObjectIdentifier(store) }
      func accept(store: PlayerStore, lease: TransportAcceptanceLease) {
        guard accepted == nil, storeIdentity == ObjectIdentifier(store) else { return }
        accepted = lease
      }
    }
    @TaskLocal private static var transportActivationReceipt: TransportActivationReceipt?
    func activateTransportAcceptance(_ connection: Connection) async -> TransportAcceptanceLease? {
      let receipt = TransportActivationReceipt(store: self)
      await Self.$transportActivationReceipt.withValue(receipt) { await activate(connection) }
      guard let accepted = receipt.accepted, ownsTransportAcceptance(accepted) else { return nil }
      return accepted
    }
    func transportAcceptanceLease() -> TransportAcceptanceLease? {
      guard active != nil else { return nil }
      return TransportAcceptanceLease(epoch: epoch, intent: playID)
    }
    func ownsTransportAcceptance(_ lease: TransportAcceptanceLease) -> Bool {
      epoch == lease.epoch && playID == lease.intent
    }
    func performTransportAcceptance(
      _ action: TransportAcceptanceAction, owned lease: TransportAcceptanceLease
    ) throws -> TransportAcceptanceLease {
      guard !Task.isCancelled, ownsTransportAcceptance(lease) else { throw CancellationError() }
      switch action {
      case .play(let selection): playSelection(selection)
      case .next: next()
      case .pause: pause()
      }
      return TransportAcceptanceLease(epoch: epoch, intent: playID)
    }
    func retireTransportAcceptance(owned lease: TransportAcceptanceLease) -> Bool {
      guard ownsTransportAcceptance(lease) else { return false }
      retire()
      busy = false
      isFixture = false
      return true
    }
  #endif
  func logout() async { await logout(ifCurrent: nil) }
  private func logout(ifCurrent generation: UUID?) async {
    guard pendingSignOut == nil, generation == nil || generation == epoch else { return }
    let old = active
    let session = generation == nil ? service : nil
    retire()
    isFixture = false
    guard let old else {
      busy = false
      return
    }
    self.session = .ending(old, expired: generation != nil)
    connections.removeAll { $0.id == old.id }
    busy = false
    await finishSignOut()
    guard let session else { return }
    let retiredEpoch = epoch
    busy = true
    defer { if epoch == retiredEpoch { busy = false } }
    do { try await session.endSession() } catch ClientError.unauthorized {
      return
    } catch {
      if epoch == retiredEpoch, active == nil, pendingSignOut == nil {
        self.error =
          "Signed out on this device. Jellyfin could not confirm that the server session ended."
      }
    }
  }
  func finishSignOut() async {
    guard !busy, case .ending(let connection, let expired) = session else { return }
    let account = connection.id
    busy = true
    var complete = true
    do { try await vault.erase(account: account) } catch { complete = false }
    do { try await storage.removeSavedConnection(account: account) } catch { complete = false }
    if complete {
      session = expired ? .recovery(.expired(connection)) : .signedOut(suggested: nil)
    }
    error = complete ? nil : "Some saved account data could not be removed. Retry sign-out."
    busy = false
  }
  private func message(_ error: Error) -> String {
    if let stepError = error as? ConnectionStepError { return stepError.errorDescription! }
    if let urlError = error as? URLError {
      return ClientError.transport(urlError).errorDescription!
    }
    if let problem = error as? PlaybackProblem { return problem.errorDescription! }
    return (error as? ClientError)?.errorDescription
      ?? "Couldn’t complete that action. Check your connection and try again."
  }
}
