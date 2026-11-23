import XCTest

@testable import JukeboxCore

actor ControlledCatalog: MusicCatalogServing {
  private var identityBlocked = false
  private var identityWaiter: CheckedContinuation<Void, Never>?
  private(set) var identityEntered = false
  func blockIdentity() { identityBlocked = true }
  func releaseIdentity() {
    identityBlocked = false
    identityWaiter?.resume()
    identityWaiter = nil
  }
  var mediaBlocked = false
  var tracksBlocked = false
  var mediaError: (any Error)?
  private var preciseTiming = false
  func usePreciseTiming() { preciseTiming = true }
  private(set) var mediaCalls = 0
  private(set) var trackCalls = 0
  private var mediaWaiter: CheckedContinuation<Void, Never>?
  private var trackWaiter: CheckedContinuation<Void, Never>?
  func blockMedia() { mediaBlocked = true }
  func blockTracks() { tracksBlocked = true }
  func releaseMedia() {
    mediaBlocked = false
    mediaWaiter?.resume()
    mediaWaiter = nil
  }
  func releaseTracks() {
    tracksBlocked = false
    trackWaiter?.resume()
    trackWaiter = nil
  }
  func failMedia(_ error: any Error) { mediaError = error }
  func verifyIdentity() async throws {
    identityEntered = true
    if identityBlocked { await withCheckedContinuation { identityWaiter = $0 } }
  }
  func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
    [MusicLibrary(id: "fixture-music", title: "Invented")]
  }
  func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
    guard query.library == "fixture-music" else { throw ClientError.forbidden }
    return query.offset == 0 && query.category == .albums ? [.fixtureAlbum] : []
  }
  func albumTracks(library: String, album: String) async throws -> [MusicItem] {
    guard library == "fixture-music" else { throw ClientError.forbidden }
    trackCalls += 1
    if tracksBlocked { await withCheckedContinuation { trackWaiter = $0 } }
    return MusicItem.fixtureTracks
  }
  func validate(ids: [String]) async throws -> [MusicItem] {
    MusicItem.fixtureTracks.filter { ids.contains($0.id) }
  }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    mediaCalls += 1
    if mediaBlocked { await withCheckedContinuation { mediaWaiter = $0 } }
    if let mediaError { throw mediaError }
    return MediaSource(
      url: URL(string: "https://fixture.invalid/Audio/test")!, quality: quality,
      preferPreciseTiming: preciseTiming && quality == .original)
  }
  func artwork(item: MusicItem) async throws -> Data? { nil }
}
actor ArtworkCatalog: MusicCatalogServing {
  let albumArt: Data?
  private(set) var artworkCalls = 0
  private var waiters: [Int: CheckedContinuation<Data?, Never>] = [:]
  init(albumArt: Data? = nil) { self.albumArt = albumArt }
  func verifyIdentity() async throws {}
  func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
    [MusicLibrary(id: "fixture-music", title: "Invented")]
  }
  func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
    guard query.library == "fixture-music" else { throw ClientError.forbidden }
    return query.offset == 0 && query.category == .albums ? [.fixtureAlbum] : []
  }
  func albumTracks(library: String, album: String) async throws -> [MusicItem] {
    guard library == "fixture-music" else { throw ClientError.forbidden }
    return MusicItem.fixtureTracks
  }
  func validate(ids: [String]) async throws -> [MusicItem] {
    MusicItem.fixtureTracks.filter { ids.contains($0.id) }
  }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    MediaSource(url: URL(string: "https://fixture.invalid/Audio/test")!, quality: quality)
  }
  func artwork(item: MusicItem) async throws -> Data? {
    if item.kind == "MusicAlbum" { return albumArt }
    artworkCalls += 1
    let call = artworkCalls
    return await withCheckedContinuation { waiters[call] = $0 }
  }
  func release(_ call: Int, data: Data?) {
    waiters.removeValue(forKey: call)?.resume(returning: data)
  }
}
actor LookaheadCatalog: MusicCatalogServing {
  private(set) var requests: [(String, StreamQuality)] = []
  var blocked: Set<Int> = []
  var failures: [Int: ClientError] = [:]
  private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
  func block(_ call: Int) { blocked.insert(call) }
  func fail(_ call: Int, _ error: ClientError) { failures[call] = error }
  func release(_ call: Int) {
    blocked.remove(call)
    waiters.removeValue(forKey: call)?.resume()
  }
  func verifyIdentity() async throws {}
  func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
    [MusicLibrary(id: "fixture-music", title: "Invented")]
  }
  func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
    guard query.library == "fixture-music" else { throw ClientError.forbidden }
    return query.offset == 0 && query.category == .albums ? [.fixtureAlbum] : []
  }
  func albumTracks(library: String, album: String) async throws -> [MusicItem] {
    guard library == "fixture-music" else { throw ClientError.forbidden }
    return MusicItem.fixtureTracks
  }
  func validate(ids: [String]) async throws -> [MusicItem] {
    MusicItem.fixtureTracks.filter { ids.contains($0.id) }
  }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    requests.append((trackID, quality))
    let call = requests.count
    if blocked.contains(call) { await withCheckedContinuation { waiters[call] = $0 } }
    if let error = failures[call] { throw error }
    return MediaSource(url: URL(string: "https://fixture.invalid/Audio/\(call)")!, quality: quality)
  }
  func artwork(item: MusicItem) async throws -> Data? { nil }
}
actor HeldCatalog: MusicCatalogServing {
  private var detailsHeld = false
  private var detailTracks: [MusicItem]?
  func respondWithDetailTracks(_ items: [MusicItem]) { detailTracks = items }
  private(set) var detailCalls = 0
  private var detailWaiters: [Int: (MusicAlbumPage, CheckedContinuation<MusicAlbumPage, Error>)] =
    [:]
  func holdDetails() { detailsHeld = true }
  func releaseDetail(_ call: Int, error: ClientError? = nil) {
    guard let (page, continuation) = detailWaiters.removeValue(forKey: call) else { return }
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume(returning: page)
    }
  }
  func releaseAllDetails() {
    detailsHeld = false
    for call in Array(detailWaiters.keys) { releaseDetail(call) }
  }
  let base: FixtureCatalog
  private var held = false
  private var artworkHeld = false
  private(set) var coverCalls = 0
  private var coverWaiters: [Int: CheckedContinuation<Data?, Error>] = [:]
  private(set) var cancelledCovers: Set<Int> = []
  private var usesCoverResponse = false
  private var coverResponse: Data?
  var pendingCovers: [Int] { coverWaiters.keys.sorted() }
  func respondWithArtwork(_ data: Data?) {
    usesCoverResponse = true
    coverResponse = data
  }
  func cancelArtwork(_ call: Int) { cancelledCovers.insert(call) }
  func releaseCover(_ call: Int, data: Data? = nil, error: ClientError? = nil) {
    guard let continuation = coverWaiters.removeValue(forKey: call) else { return }
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume(returning: data)
    }
  }
  func holdArtwork() { artworkHeld = true }
  func releaseArtwork(_ data: Data?) {
    artworkHeld = false
    let waiting = coverWaiters.values
    coverWaiters.removeAll()
    for waiter in waiting { waiter.resume(returning: data) }
  }
  private var rootIDs = ["fixture-music", "fixture-concerts"]
  func setLibraries(_ ids: [String]) { rootIDs = ids }
  private var deferredPrecision = false
  func useDeferredPrecision() { deferredPrecision = true }
  private var sequence = 0
  private var pending: [Int: (MediaSource, CheckedContinuation<MediaSource, Error>)] = [:]
  init(_ base: FixtureCatalog) { self.base = base }
  func hold() { held = true }
  var pendingRequests: [Int] { pending.keys.sorted() }
  func release(_ id: Int, error: ClientError? = nil) {
    guard let (source, continuation) = pending.removeValue(forKey: id) else { return }
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume(returning: source)
    }
  }
  func releaseAll() {
    held = false
    for id in pendingRequests { release(id) }
  }
  func verifyIdentity() async throws { try await base.verifyIdentity() }
  func validate(ids: [String]) async throws -> [MusicItem] { try await base.validate(ids: ids) }
  func artwork(item: MusicItem) async throws -> Data? {
    coverCalls += 1
    if artworkHeld {
      let call = coverCalls
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { coverWaiters[call] = $0 }
      } onCancel: {
        Task { await self.cancelArtwork(call) }
      }
    }
    if usesCoverResponse { return coverResponse }
    return try await base.artwork(item: item)
  }
  func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
    rootIDs.map { MusicLibrary(id: $0, title: $0) }
  }
  func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
    try await base.catalog(query)
  }
  func albumTracks(library: String, album: String) async throws -> [MusicItem] {
    try await base.albumTracks(library: library, album: album)
  }
  func albumDetail(library: String, album: MusicItem) async throws -> MusicAlbumPage {
    let result = try await base.albumDetail(library: library, album: album)
    let page = MusicAlbumPage(album: result.album, tracks: detailTracks ?? result.tracks)
    detailCalls += 1
    guard detailsHeld else { return page }
    let call = detailCalls
    return try await withCheckedThrowingContinuation { detailWaiters[call] = (page, $0) }
  }
  func artistDetail(library: String, artist: MusicItem) async throws -> MusicItem {
    try await base.artistDetail(library: library, artist: artist)
  }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    _ = try await base.media(
      library: library, trackID: trackID, quality: quality, isCurrent: isCurrent)
    let source =
      deferredPrecision && quality == .original
      ? MediaSource(
        url: URL(string: "https://fixture.invalid/audio")!, quality: quality,
        preciseSeekingRequired: true, serverDuration: 18)
      : MediaSource(
        url: URL(string: "https://fixture.invalid/audio")!, quality: quality,
        serverTimeSeek: true, maximumTimeOrigin: 18)
    guard held else { return source }
    guard pending.count < 8 else { throw ClientError.unavailable }
    sequence += 1
    let id = sequence
    return try await withCheckedThrowingContinuation { pending[id] = (source, $0) }
  }
}

@MainActor final class DriverSpy: PlaybackDriving {
  var onEvent: (@MainActor (DriverEvent) -> Void)?
  var startError: (any Error)?
  var beforeStart: (@MainActor () async -> Void)?
  var appendError: (any Error)?
  var deferAppend = false
  var deferredEntries: [UUID] = []
  var completeLocalOccurrence: UUID?
  var starts = 0
  var resumeAllowed = true
  var remoteIntentRenewals = 0
  func renewRemoteIntent() { remoteIntentRenewals += 1 }
  var stops = 0
  var startedPositions: [Double] = []
  var lastSeek: Double?
  var seekRequests: [UUID] = []
  var seekOccurrences: [UUID?] = []
  var current: UUID?
  var observedCurrent: UUID?
  var beforeObserve: (@MainActor () -> Void)?
  var observationAccepted = true
  var afterStop: (@MainActor () -> Void)?
  var allowsPreparedAdvance = false
  var afterPreparedAdvance: (@MainActor () -> Void)?
  var pauses = 0
  var sampledPausePosition: Double?
  var prepared: [UUID] = []
  var appended: [UUID] = []
  var currentArtwork: Data?
  var artworkPublications: [(UUID, Data)] = []
  var receivedArtworkData: [Data] = []
  var replacements: [PlaybackReplacement] = []
  var acceptsPlaybackReplacement = false
  var deniesCurrentRetention = false
  var pending: UUID?
  var startedSources: [MediaSource] = []
  private var boundSources: [UUID: MediaSource] = [:]
  func prepareReplacement(_ replacement: PlaybackReplacement) -> Bool {
    replacements.append(replacement)
    guard acceptsPlaybackReplacement else { return false }
    pending = replacement.target.id
    current = nil
    prepared = []
    boundSources = [:]
    return true
  }
  func updateArtwork(_ data: Data?, occurrence: UUID) {
    if let data { receivedArtworkData.append(data) }
    guard current == occurrence else { return }
    currentArtwork = data
    if let data { artworkPublications.append((occurrence, data)) }
  }
  func start(_ entries: [PreparedEntry], position: Double) async throws {
    if let beforeStart {
      await beforeStart()
      try Task.checkCancellation()
    }
    if let startError { throw startError }
    starts += 1
    observationAccepted = true
    pending = nil
    startedSources += entries.map(\.source)
    startedPositions.append(position)
    prepared = entries.map { $0.entry.id }
    boundSources = Dictionary(uniqueKeysWithValues: entries.map { ($0.entry.id, $0.source) })
    current = entries.first?.entry.id
    observedCurrent = current
    if let current { onEvent?(.advanced(current)) }
    if let id = entries.first?.entry.id { onEvent?(.state(id, .playing)) }
  }
  func append(_ entry: PreparedEntry, isCurrent: @MainActor @Sendable () -> Bool) async throws {
    guard isCurrent() else { throw CancellationError() }
    if let appendError { throw appendError }
    if deferAppend {
      deferredEntries.append(entry.entry.id)
      return
    }
    prepared.append(entry.entry.id)
    appended.append(entry.entry.id)
    boundSources[entry.entry.id] = entry.source
  }
  func observeCurrent() -> Bool {
    beforeObserve?()
    guard observationAccepted else { return false }
    if let current, observedCurrent != current {
      observedCurrent = current
      onEvent?(.advanced(current))
    }
    if let current, let sampledPausePosition { onEvent?(.position(current, sampledPausePosition)) }
    return true
  }
  func retainCurrent(occurrence: UUID, keeping successor: UUID?) -> CurrentItemRetention {
    guard !deniesCurrentRetention else { return .changed }
    if let current, current != occurrence {
      observedCurrent = current
      onEvent?(.advanced(current))
    }
    guard let current else { return .unbound }
    guard current == occurrence else { return .changed }
    prepared = prepared.filter { $0 == occurrence || $0 == successor }
    return .retained
  }
  func hasPrepared(_ occurrence: UUID) -> Bool { prepared.contains(occurrence) }
  func hasCompleteLocalFile(occurrence: UUID) -> Bool {
    current == occurrence && completeLocalOccurrence == occurrence
  }
  func hasPending(_ occurrence: UUID) -> Bool { pending == occurrence }
  func requiresSourceReplacementForSeek(occurrence: UUID, position: Double) -> Bool {
    guard position.isFinite, position > 0, current == occurrence,
      let source = boundSources[occurrence]
    else { return false }
    return source.preciseSeekingRequired && !source.preferPreciseTiming
  }
  func finishCurrent() {
    guard let current else { return }
    prepared.removeAll()
    self.current = nil
    onEvent?(.finished(current))
  }
  func advancePrepared(to occurrence: UUID) -> Bool {
    guard allowsPreparedAdvance, prepared.count >= 2, prepared.first == current,
      prepared[1] == occurrence
    else { return false }
    prepared.removeFirst()
    current = occurrence
    observedCurrent = occurrence
    onEvent?(.advanced(occurrence))
    let callback = afterPreparedAdvance
    afterPreparedAdvance = nil
    callback?()
    return current == occurrence
  }
  func advance() {
    prepared.removeFirst()
    current = prepared.first
    observedCurrent = current
    if let current { onEvent?(.advanced(current)) }
  }
  func resume(id: UUID) -> Bool { resumeAllowed && current == id }
  func pause() {
    pauses += 1
    pending = nil
    if let current, let sampledPausePosition { onEvent?(.position(current, sampledPausePosition)) }
  }
  func stop() {
    stops += 1
    pending = nil
    prepared = []
    current = nil
    boundSources = [:]
    currentArtwork = nil
    observedCurrent = nil
    observationAccepted = true
    let callback = afterStop
    afterStop = nil
    callback?()
  }
  func seek(_ seconds: Double, request: UUID) {
    lastSeek = seconds
    seekRequests.append(request)
    seekOccurrences.append(current)
  }
}
struct ImmediateVault: TokenVault {
  func read(account: String) -> String? { "invented-token" }
  func write(_ token: String, account: String) {}
  func erase(account: String) {}
}
struct ImmediateCatalog: MusicCatalogServing {
  func verifyIdentity() throws {}
  func musicLibraries(refresh: Bool) throws -> [MusicLibrary] {
    [MusicLibrary(id: "fixture-music", title: "Invented")]
  }
  func catalog(_ query: CatalogQuery) throws -> [MusicItem] {
    guard query.library == "fixture-music" else { throw ClientError.forbidden }
    return query.offset == 0 && query.category == .albums ? [.fixtureAlbum] : []
  }
  func albumTracks(library: String, album: String) throws -> [MusicItem] {
    guard library == "fixture-music" else { throw ClientError.forbidden }
    return MusicItem.fixtureTracks
  }
  func validate(ids: [String]) throws -> [MusicItem] {
    MusicItem.fixtureTracks.filter { ids.contains($0.id) }
  }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    MediaSource(url: URL(string: "https://fixture.invalid/audio/invented")!, quality: quality)
  }
  func artwork(item: MusicItem) throws -> Data? { nil }
}
final class StorageWriteGate: @unchecked Sendable {
  private let lock = NSLock()
  private let releaseSignal = DispatchSemaphore(value: 0)
  private var started = false
  var entered: Bool {
    lock.lock()
    defer { lock.unlock() }
    return started
  }
  func hold() {
    lock.lock()
    started = true
    lock.unlock()
    releaseSignal.wait()
  }
  func release() { releaseSignal.signal() }
}
extension LibraryStorage {
  func holdWritesForTest(_ gate: StorageWriteGate) { gate.hold() }
}

@MainActor func acceptedAlbumSelection(_ store: PlayerStore, album: MusicItem = .fixtureAlbum)
  async throws -> PlaybackSelection
{
  let browser = try XCTUnwrap(store.browser)
  await browser.start()
  let origin = try XCTUnwrap(store.playbackOrigin(library: browser.authorizedLibrary))
  let content = try XCTUnwrap(browser.detail(album))
  async let cover: Void = store.loadCover(album, origin: origin)
  await content.load()
  _ = await cover
  XCTAssertNil(content.error)
  return try XCTUnwrap(store.playbackSelection(content.tracks, library: content.authorizedLibrary))
}

actor ArtworkToneGate {
  private(set) var calls = 0
  private var held = false
  private var continuation: CheckedContinuation<ArtworkTone?, Never>?
  var waiting: Bool { continuation != nil }
  func hold() { held = true }
  func release() {
    continuation?.resume(returning: ArtworkTone(red: 0.2, green: 0.3, blue: 0.4))
    continuation = nil
  }
  func tone(_ data: Data) async -> ArtworkTone? {
    calls += 1
    if held {
      held = false
      return await withCheckedContinuation { continuation = $0 }
    }
    return ArtworkTone(red: 0.2, green: 0.3, blue: 0.4)
  }
}

actor ControlledSleep {
  private(set) var durations: [Duration] = []
  func wait(for duration: Duration) async {
    durations.append(duration)
    await wait(until: .distantFuture)
  }
  private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
  private(set) var calls = 0
  func wait(until deadline: Date) async {
    calls += 1
    let call = calls
    await withCheckedContinuation { waiters[call] = $0 }
  }
  func release(_ call: Int) { waiters.removeValue(forKey: call)?.resume() }
  func releaseAll() {
    let pending = waiters.values
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}
