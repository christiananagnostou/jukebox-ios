import Foundation

enum DiagnosticCategory: String, Sendable { case lifecycle, intent, network, playback }
enum DiagnosticLaunchMode: String, Sendable {
  case normal, invented, acceptance, preview, rejected
  init(
    profiling: ProfilingLaunch, transport: Self? = nil, scale: Self? = nil,
    fixture: Bool, integration: Bool
  ) {
    if let transport {
      self = transport
    } else if profiling.isRejected {
      self = .rejected
    } else if profiling.isAttempted {
      self = .acceptance
    } else if let scale {
      self = scale
    } else {
      self = fixture ? .invented : integration ? .acceptance : .normal
    }
  }
}
enum DiagnosticRole: String, Sendable { case unknown, current, successor }
enum DiagnosticScope: String, Sendable {
  case intent, preparation, nativeItem
}
enum DiagnosticResponseRejection: String, Sendable {
  case nonHTTP, status, contentEncoding, transferFraming, contentLength, contentType, contentRange,
    changedPrefix
}
enum DiagnosticAction: String, Sendable {
  case play, selection, next, previous, seek, retry, quality
}
enum DiagnosticStage: String, Codable, Sendable {
  case launch, command, detail, metadata, playbackInfo, artwork, authentication, identity,
    serverInfo
  case source, native, audioSession, seek, bridge, scope, other
  static func classify(_ request: URLRequest) -> Self {
    let path = request.url?.path ?? ""
    if path.hasSuffix("/PlaybackInfo") { return .playbackInfo }
    if path.hasSuffix("/Items") { return .metadata }
    if path.hasSuffix("/Images/Primary") { return .artwork }
    if path.hasSuffix("/AuthenticateByName") { return .authentication }
    if path.hasSuffix("/Users/Me") { return .identity }
    if path.hasSuffix("/System/Info/Public") { return .serverInfo }
    return .other
  }
}
enum DiagnosticOutcome: String, Sendable {
  case accepted, started, succeeded, failed, cancelled, preparing, playing, waiting, paused, ended,
    reset
}
enum DiagnosticReason: String, Sendable {
  case none, userPause, superseded, accountRetired, rootRetired, stop, deadline, taskCancelled
  case sourceRetired
}
enum DiagnosticSource: String, Sendable {
  case unknown, local, https, httpBridge

}
enum DiagnosticQuality: String, Sendable {
  case unknown, original, high, dataSaver
  init(_ quality: StreamQuality) {
    switch quality {
    case .original: self = .original
    case .high: self = .high
    case .compact: self = .dataSaver
    }
  }
}
struct DiagnosticCode: Equatable, Sendable {
  enum Domain: String, Sendable { case url, avFoundation, osStatus, client, unknown }
  let domain: Domain
  let value: Int
  init(_ error: any Error) {
    if let error = error as? URLError {
      domain = .url
      value = error.errorCode
    } else {
      let native = error as NSError
      switch native.domain {
      case "AVFoundationErrorDomain": domain = .avFoundation
      case NSOSStatusErrorDomain: domain = .osStatus
      default: domain = error is ClientError || error is PlaybackProblem ? .client : .unknown
      }
      value = domain == .unknown ? 0 : native.code
    }
  }
  init(domain: Domain, value: Int) {
    self.domain = domain
    self.value = value
  }
}
struct PlaybackEvidence: Equatable, Sendable {
  enum Transport: String, Sendable { case idle, preparing, active, seeking, failed }
  enum Waiting: String, Sendable { case none, minimizeStalls, evaluateBuffer, noItem, other }
  var transport: Transport?
  var waiting: Waiting?
  var source: DiagnosticSource = .unknown
  var quality: DiagnosticQuality = .unknown
  var sourceOrdinal: Int = 0
  var playerStatus: Int?
  var itemStatus: Int?
  var timeControl: Int?
  var requested: Bool?
  var itemIsCurrent: Bool?
  var precise: Bool?
  var serverSeek: Bool?
  var bufferEmpty: Bool?
  var keepUp: Bool?
  var nativeClock: Double?
  var absoluteClock: Double?
  var acceptedClock: Double?
  var target: Double?
  var origin: Double?
  var nativeDuration: Double?
  var sourceDuration: Double?
  var loadedEnd: Double?
  var seekableEnd: Double?
  var noProgressSeconds: Double?
  var preparationSeconds: Double?
  var transfers: [PlaybackTransferEvidence] = []
  static func number(_ value: Double?) -> String {
    guard let value, value.isFinite, abs(value) <= 1e12 else { return "unavailable" }
    return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
  }
  var fields: String {
    let flags =
      "requested=\(requested.map(String.init) ?? "unavailable") item_is_current=\(itemIsCurrent.map(String.init) ?? "unavailable") precise=\(precise.map(String.init) ?? "unavailable") server_seek=\(serverSeek.map(String.init) ?? "unavailable")"
    let state =
      "transport=\(transport?.rawValue ?? "unavailable") player_status=\(playerStatus.map(String.init) ?? "unavailable") item_status=\(itemStatus.map(String.init) ?? "unavailable") time_control=\(timeControl.map(String.init) ?? "unavailable") waiting=\(waiting?.rawValue ?? "unavailable")"
    let clocks =
      "native_s=\(Self.number(nativeClock)) absolute_s=\(Self.number(absoluteClock)) accepted_s=\(Self.number(acceptedClock)) target_s=\(Self.number(target)) origin_s=\(Self.number(origin))"
    let timing =
      "native_duration_s=\(Self.number(nativeDuration)) source_duration_s=\(Self.number(sourceDuration)) loaded_end_s=\(Self.number(loadedEnd)) seekable_end_s=\(Self.number(seekableEnd)) no_progress_s=\(Self.number(noProgressSeconds)) preparing_s=\(Self.number(preparationSeconds))"
    let buffers =
      "buffer_empty=\(bufferEmpty.map(String.init) ?? "unavailable") keep_up=\(keepUp.map(String.init) ?? "unavailable")"
    return
      "source_ordinal=\(max(0, sourceOrdinal)) source=\(source.rawValue) quality=\(quality.rawValue) \(state) \(flags) \(clocks) \(timing) \(buffers)"
      + transfers.prefix(4).enumerated().map { " transfer\($0.offset)={\($0.element.fields)}" }
      .joined()
  }
}
struct PlaybackTransferEvidence: Equatable, Sendable {
  enum State: String, Sendable { case requesting, streaming, completed, failed, cancelled }
  enum Recovery: String, Sendable { case unused, verifying, resumed }
  var recovery: Recovery = .unused
  var ordinal = 0
  var head = false
  var rangeStart: Int64?
  var rangeEnd: Int64?
  var suffix = false
  var status: Int?
  var code: DiagnosticCode?
  var rejection: DiagnosticResponseRejection?
  var expected: Int64?
  var received: Int64 = 0
  var delivered: Int64 = 0
  var state: State = .requesting
  var lastByteAge: Double?
  var taskReceived: Int64?
  var longestPlayerWait: Double?
  var inputTimedOut: Bool?
  var fields: String {
    let summary =
      "request=\(max(0, ordinal)) method=\(head ? "HEAD" : "GET") range_start=\(rangeStart.map(String.init) ?? "none") range_end=\(rangeEnd.map(String.init) ?? "none") suffix=\(suffix) http=\(status.map(String.init) ?? "unavailable") error_domain=\(code?.domain.rawValue ?? "unavailable") error_code=\(code.map { String($0.value) } ?? "unavailable") rejection=\(rejection?.rawValue ?? "none") expected=\(expected.map(String.init) ?? "unavailable") received=\(max(0, received)) delivered=\(max(0, delivered)) terminal=\(state.rawValue) recovery=\(recovery.rawValue) last_chunk_age_s=\(PlaybackEvidence.number(lastByteAge))"
    guard let inputTimedOut else { return summary }
    return summary
      + " task_received=\(taskReceived.map(String.init) ?? "unavailable") max_player_wait_s=\(PlaybackEvidence.number(longestPlayerWait)) input_timeout=\(inputTimedOut)"
  }
}
struct DiagnosticFacts: Equatable, Sendable {
  var stage: DiagnosticStage
  var outcome: DiagnosticOutcome
  var reason: DiagnosticReason = .none
  var http: Int?
  var code: DiagnosticCode?
  var nativeCode: Int?
  var failure: ConnectionStepError.Category?
  var responseRejection: DiagnosticResponseRejection?
  var bytes: Int?
  var source: DiagnosticSource = .unknown
  var durationMS: UInt64?
  var playback: PlaybackEvidence?
  init(
    _ stage: DiagnosticStage, _ outcome: DiagnosticOutcome, reason: DiagnosticReason = .none,
    http: Int? = nil, code: DiagnosticCode? = nil, nativeCode: Int? = nil, bytes: Int? = nil,
    source: DiagnosticSource = .unknown, durationMS: UInt64? = nil,
    responseRejection: DiagnosticResponseRejection? = nil
  ) {
    self.stage = stage
    self.outcome = outcome
    self.reason = reason
    self.http = http.flatMap { (100...599).contains($0) ? $0 : nil }
    self.code = code
    self.nativeCode = nativeCode
    self.bytes = bytes.map { max(0, $0) }
    self.source = source
    self.durationMS = durationMS
    self.responseRejection = responseRejection
  }
  static func failure(_ detail: ConnectionStepError, stage: DiagnosticStage) -> Self {
    var facts = Self(
      detail.step == .audioSession ? .audioSession : stage, .failed, http: detail.status,
      code: detail.code.map { DiagnosticCode(domain: detail.diagnosticDomain, value: $0) },
      nativeCode: detail.nativeLogCode)
    facts.failure = detail.category
    facts.playback = detail.playbackEvidence
    return facts
  }
  var fields: String {
    var result = "stage=\(stage.rawValue) outcome=\(outcome.rawValue)"
    if reason != .none { result += " reason=\(reason.rawValue)" }
    if let failure { result += " failure=\(failure.rawValue)" }
    if let responseRejection { result += " responseRejection=\(responseRejection.rawValue)" }
    if let http { result += " http=\(http)" }
    if let code { result += " domain=\(code.domain.rawValue) code=\(code.value)" }
    if let nativeCode { result += " native=\(nativeCode)" }
    if let bytes { result += " bytes=\(bytes)" }
    if source != .unknown { result += " source=\(source.rawValue)" }
    if let durationMS { result += " duration_ms=\(durationMS)" }
    if let playback { result += " " + playback.fields }
    return result
  }
}
struct DiagnosticBuild: Sendable {
  let version: String
  let build: String
  let marker: String
  let os: [Int]
  let mode: DiagnosticLaunchMode
  init(
    version: String, build: String, marker: String, os: [Int], mode: DiagnosticLaunchMode = .normal
  ) {
    func safe(_ value: String) -> String {
      String(
        value.prefix(64).filter {
          $0.isASCII && ($0.isLetter || $0.isNumber || ".-()".contains($0))
        })
    }
    self.version = safe(version)
    self.build = safe(build)
    self.marker = safe(marker)
    self.os = Array(os.prefix(3)).map { min(999, max(0, $0)) }
    self.mode = mode
  }
  var fields: String {
    "app=Jukebox version=\(version) build=\(build) marker=\(marker) os=\(os.map(String.init).joined(separator: ".")) mode=\(mode.rawValue)"
  }
}
struct DiagnosticRecord: Sendable {
  let launch: UUID
  let sequence: UInt64
  let utc: Date
  let elapsedMS: UInt64
  let category: DiagnosticCategory
  let action: UInt64?
  let actionKind: DiagnosticAction?
  let quality: DiagnosticQuality
  let role: DiagnosticRole
  let scope: DiagnosticScope?
  let facts: DiagnosticFacts
  let dropped: UInt64
  let build: DiagnosticBuild?
  var line: String {
    var text =
      "JBX v=1 launch=\(launch.uuidString) seq=\(sequence) utc=\(utc.ISO8601Format()) ms=\(elapsedMS) cat=\(category.rawValue)"
    if let action { text += " action=\(action)" }
    if let actionKind { text += " command=\(actionKind.rawValue)" }
    if role != .unknown { text += " role=\(role.rawValue)" }
    if let scope { text += " scope=\(scope.rawValue)" }
    if quality != .unknown { text += " quality=\(quality.rawValue)" }
    text += " " + facts.fields
    if dropped > 0 { text += " dropped=\(dropped)" }
    if let build { text += " " + build.fields }
    return text
  }
}
