import Foundation

enum StreamQuality: String, CaseIterable, Codable, Identifiable, Sendable {
  case original, high, compact
  var id: String { rawValue }
  var title: String {
    switch self {
    case .original: "Original"
    case .high: "High · 192 kbps"
    case .compact: "Data saver · 96 kbps"
    }
  }
  var bitrate: Int {
    switch self {
    case .original: 20_000_000
    case .high: 192_000
    case .compact: 96_000
    }
  }
}
struct QueueEntry: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  let track: MusicItem
  let libraryID: String?
  init(_ track: MusicItem, id: UUID = UUID(), libraryID: String? = nil) {
    self.track = track
    self.id = id
    self.libraryID = libraryID
  }
  func playbackDuration(nativeDuration: Double?, sourceDuration: Double? = nil, position: Double)
    -> Double?
  {
    if let nativeDuration, nativeDuration.isFinite, nativeDuration > 0 { return nativeDuration }
    if let sourceDuration, sourceDuration.isFinite, sourceDuration > 0 { return sourceDuration }
    let hint = track.duration
    guard hint.isFinite, hint > 0, position.isFinite, position <= hint + 0.25 else { return nil }
    return hint
  }
}
struct QueueState: Codable, Equatable, Sendable {
  enum RepeatMode: String, CaseIterable, Sendable { case off, all, one }
  enum Completion {
    case stop
    case play(at: Int)
    case awaitRetry(at: Int)
  }
  func orderingFuture(restoring canonical: [UUID]?) -> [QueueEntry] {
    guard entries.indices.contains(index + 1) else { return entries }
    var result = entries
    let future = (index + 1)...
    if let canonical {
      let order = Dictionary(uniqueKeysWithValues: canonical.enumerated().map { ($1, $0) })
      result[future].sort { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
    } else {
      result[future].shuffle()
    }
    return result
  }
  var entries: [QueueEntry] = [] {
    didSet { membershipRevision = UUID() }
  }
  var index = 0
  var position = 0.0
  var quality: StreamQuality = .original
  var playlistID: String?
  private(set) var membershipRevision = UUID()
  private enum CodingKeys: String, CodingKey { case entries, index, position, quality, playlistID }
  init(
    entries: [QueueEntry] = [], index: Int = 0, position: Double = 0,
    quality: StreamQuality = .original
  ) {
    self.entries = entries
    self.index = index
    self.position = position
    self.quality = quality
  }
  init(restoring state: Self, membershipRevision: UUID) {
    self = state
    self.membershipRevision = membershipRevision
  }
  static func == (left: Self, right: Self) -> Bool {
    left.entries == right.entries && left.index == right.index
      && left.position == right.position && left.quality == right.quality
      && left.playlistID == right.playlistID
  }
  var current: QueueEntry? { entries.indices.contains(index) ? entries[index] : nil }
  var successor: QueueEntry? { nextIndex(repeating: .off).map { entries[$0] } }

  func lookahead(repeating mode: RepeatMode) -> QueueEntry? {
    mode == .one ? nil : successor
  }
  func nextIndex(repeating mode: RepeatMode) -> Int? {
    guard entries.indices.contains(index) else { return nil }
    if index + 1 < entries.count { return index + 1 }
    return mode == .all ? 0 : nil
  }
  func completion(repeating mode: RepeatMode, failedSuccessor: Bool) -> Completion {
    if mode == .one, current != nil { return .play(at: index) }
    guard let next = nextIndex(repeating: mode) else { return .stop }
    if failedSuccessor, next == index + 1 { return .awaitRetry(at: next) }
    return .play(at: next)
  }
  mutating func normalize() {
    index = entries.isEmpty ? 0 : min(max(0, index), entries.count - 1)
    position = current != nil && position.isFinite ? max(0, position) : 0
  }
  mutating func reconcile(_ allowed: [MusicItem]) {
    let currentID = current?.id
    let oldPosition = position
    let items = Dictionary(allowed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    if entries.contains(where: { items[$0.track.id] != $0.track }) {
      entries = entries.compactMap { entry in
        items[entry.track.id].map { QueueEntry($0, id: entry.id, libraryID: entry.libraryID) }
      }
    }
    index = entries.firstIndex { $0.id == currentID } ?? 0
    position = current?.id == currentID ? oldPosition : 0
    normalize()
  }
  func restoredForPlayback(using service: any MusicCatalogServing) async throws
    -> (ready: Self, remainder: Self?)
  {
    guard let current else { return (self, nil) }
    let count = min(40, entries.count)
    let start = min(max(0, index - 1), entries.count - count)
    let window = entries[start..<(start + count)]
    let requested = Set(window.map(\.track.id))
    let verified = try await service.validate(ids: window.map(\.track.id))
    try Task.checkCancellation()
    var saved = self
    if entries.count == count || entries.allSatisfy({ requested.contains($0.track.id) }) {
      saved.reconcile(verified)
      return (saved, nil)
    }
    guard verified.contains(where: { $0.id == current.track.id }) else {
      saved.reconcile(try await service.validate(ids: entries.map(\.track.id)))
      return (saved, nil)
    }
    var ready = self
    ready.entries = Array(window)
    ready.index -= start
    ready.reconcile(verified)
    let denied = requested.subtracting(verified.map(\.id))
    if !denied.isEmpty {
      saved.remove(Set(entries.lazy.filter { denied.contains($0.track.id) }.map(\.id)))
    }
    return (ready, saved)
  }
  mutating func remove(_ ids: Set<UUID>) {
    let removingCurrent = current.map { ids.contains($0.id) } ?? true
    let survivingBeforeCurrent = entries.prefix(max(0, index)).count { !ids.contains($0.id) }
    entries.removeAll { ids.contains($0.id) }
    index = survivingBeforeCurrent
    if removingCurrent { position = 0 }
    normalize()
  }
  mutating func move(from: Int, to: Int) {
    guard entries.indices.contains(from), to >= 0, to <= entries.count else { return }
    let currentID = current?.id
    let entry = entries.remove(at: from)
    entries.insert(entry, at: min(to > from ? to - 1 : to, entries.count))
    index = entries.firstIndex { $0.id == currentID } ?? 0
  }
}
struct MediaSource: Sendable {
  let url: URL
  private let authorization: String?
  var usesBridge: Bool {
    url.scheme == "http" || (url.scheme == "https" && authorization != nil)
  }
  var upstreamRequest: URLRequest {
    var request = URLRequest(url: url)
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    return request
  }
  let quality: StreamQuality
  let preferPreciseTiming: Bool
  let preciseSeekingRequired: Bool
  let serverTimeSeek: Bool
  let timeOrigin: Double
  let maximumTimeOrigin: Double?
  let serverDuration: Double?
  init(
    url: URL, quality: StreamQuality, preferPreciseTiming: Bool = false,
    preciseSeekingRequired: Bool = false,
    serverTimeSeek: Bool = false, timeOrigin: Double = 0, maximumTimeOrigin: Double? = nil,
    serverDuration: Double? = nil, authorization: String? = nil
  ) {
    self.url = url
    self.authorization = authorization
    self.quality = quality
    self.preferPreciseTiming = preferPreciseTiming
    self.preciseSeekingRequired = preciseSeekingRequired
    self.serverTimeSeek = serverTimeSeek
    self.timeOrigin = timeOrigin
    self.maximumTimeOrigin = maximumTimeOrigin
    self.serverDuration = serverDuration
  }
  func starting(at position: Double) throws -> MediaSource {
    if !serverTimeSeek {
      guard preciseSeekingRequired else { return self }
      guard position.isFinite, position >= 0 else { throw ClientError.invalidResponse }
      return MediaSource(
        url: url, quality: quality, preferPreciseTiming: position > 0,
        preciseSeekingRequired: true, timeOrigin: timeOrigin,
        maximumTimeOrigin: maximumTimeOrigin, serverDuration: serverDuration,
        authorization: authorization)
    }
    guard position.isFinite, position >= 0, position <= Double(Int64.max / 10_000_000),
      var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { throw ClientError.invalidResponse }
    guard position == 0 || maximumTimeOrigin != nil else { throw ClientError.unavailable }
    let origin = min(position, maximumTimeOrigin ?? 0)
    guard origin.isFinite, origin >= 0 else { throw ClientError.invalidResponse }
    let ticks = Int64((origin * 10_000_000).rounded(.down))
    var query = parts.queryItems ?? []
    guard
      !query.contains(where: {
        $0.name.lowercased() == "params"
          && !($0.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else { throw ClientError.invalidResponse }
    query.removeAll {
      ["starttimeticks", "copytimestamps", "playsessionid"].contains($0.name.lowercased())
    }
    query += [
      .init(name: "StartTimeTicks", value: String(ticks)),
      .init(name: "CopyTimestamps", value: "false"),
      .init(
        name: "PlaySessionId", value: UUID().uuidString.replacingOccurrences(of: "-", with: "")),
    ]
    parts.queryItems = query
    guard let url = parts.url else { throw ClientError.invalidResponse }
    return MediaSource(
      url: url, quality: quality, preferPreciseTiming: preferPreciseTiming,
      preciseSeekingRequired: preciseSeekingRequired,
      serverTimeSeek: true, timeOrigin: Double(ticks) / 10_000_000,
      maximumTimeOrigin: maximumTimeOrigin, serverDuration: serverDuration,
      authorization: authorization)
  }
}

struct PlaybackProgressDeadline: Sendable {
  static let precisePreparationTimeout = 60.0
  let timeout: Double
  let preparationTimeout: Double
  private var lastAdvance = 0.0
  private var clock = 0.0
  private(set) var stallStep = ConnectionStepError.Step.playbackAudio
  private var preparationStartedAt: Double?
  init(timeout: Double = 15, preparationTimeout: Double = precisePreparationTimeout) {
    self.timeout = timeout
    self.preparationTimeout = preparationTimeout
  }
  mutating func reset(
    at now: Double, position: Double = 0, preparationStartedAt: Double? = nil
  ) {
    lastAdvance = now
    clock = position.isFinite ? position : 0
    stallStep = .playbackAudio
    self.preparationStartedAt = preparationStartedAt
  }
  mutating func markReady(at now: Double) {
    guard preparationStartedAt != nil else { return }
    preparationStartedAt = nil
    lastAdvance = now
  }
  func evidence(at now: Double) -> (noProgress: Double, preparing: Double?) {
    (max(0, now - lastAdvance), preparationStartedAt.map { max(0, now - $0) })
  }
  mutating func expired(at now: Double, position: Double, ready: Bool = false) -> Bool {
    let advanced = position.isFinite && position > clock + 0.01
    if ready || advanced { markReady(at: now) }
    if advanced {
      clock = position
      stallStep = .playbackProgress
      lastAdvance = now
    }
    if let preparationStartedAt { return now - preparationStartedAt >= preparationTimeout }
    return now - lastAdvance >= timeout
  }
}

extension MediaSource {
  var diagnosticSource: DiagnosticSource {
    if url.isFileURL { return .local }
    if usesBridge { return .httpBridge }
    return url.scheme == "https" ? .https : .unknown
  }
}

func musicTimeText(_ seconds: Double) -> String? {
  guard seconds.isFinite, seconds >= 0,
    let whole = Int(exactly: seconds.rounded(.towardZero))
  else { return nil }
  return "\(whole / 60):" + String(format: "%02d", whole % 60)
}
