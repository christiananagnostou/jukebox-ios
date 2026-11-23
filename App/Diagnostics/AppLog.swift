import Foundation
import OSLog

enum AppLog {
  private static let lifecycle = Logger(subsystem: "dev.jukebox.ios", category: "lifecycle")
  private static let intent = Logger(subsystem: "dev.jukebox.ios", category: "intent")
  private static let network = Logger(subsystem: "dev.jukebox.ios", category: "network")
  private static let playback = Logger(subsystem: "dev.jukebox.ios", category: "playback")
  static func makeSession(mode: DiagnosticLaunchMode = .normal) -> DiagnosticSession {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return DiagnosticSession(
      build: DiagnosticBuild(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
          ?? "unknown",
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        marker: Bundle.main.object(forInfoDictionaryKey: "JukeboxBuildMarker") as? String
          ?? "unknown",
        os: [version.majorVersion, version.minorVersion, version.patchVersion], mode: mode),
      sink: write)
  }
  private static func write(_ record: DiagnosticRecord) {
    let logger =
      switch record.category {
      case .lifecycle: lifecycle
      case .intent: intent
      case .network: network
      case .playback: playback
      }
    let line = record.line
    #if DEBUG
      probe.record(record, line: line)
    #endif
    if record.facts.outcome == .failed {
      logger.error("\(line, privacy: .public)")
    } else {
      logger.notice("\(line, privacy: .public)")
    }
  }
  #if DEBUG
    private static let probe = ConsoleAcceptanceProbe()
    static func beginAcceptance(_ runID: UUID) { probe.begin(runID) }
    static func endAcceptance(_ runID: UUID) { probe.end(runID) }
    static func acceptance(_ runID: UUID) -> ConsoleAcceptanceProbe.Snapshot? {
      probe.snapshot(runID)
    }
  #endif

}

#if DEBUG
  final class ConsoleAcceptanceProbe: @unchecked Sendable {
    struct Snapshot {
      let count: UInt64
      let chain: Bool
      let example: String
      let acceptanceMode: Bool
      let scopedRetirement: Bool
    }
    private struct State {
      let run: UUID
      var count: UInt64 = 0
      var headers = 0
      var records: [DiagnosticRecord] = []
      var example = ""
    }
    private let lock = NSLock()
    private var state: State?
    func begin(_ run: UUID) { lock.withLock { state = State(run: run) } }
    func end(_ run: UUID) {
      lock.withLock { if state?.run == run { state = nil } }
    }
    func record(_ record: DiagnosticRecord, line: String) {
      lock.withLock {
        guard var current = state else { return }
        current.count += 1
        if record.build != nil { current.headers += 1 }
        if current.records.count < 64 { current.records.append(record) }
        if current.example.isEmpty, record.build != nil { current.example = line }
        state = current
      }
    }
    func snapshot(_ run: UUID) -> Snapshot? {
      lock.withLock {
        guard let state, state.run == run else { return nil }
        let accepted = Set(
          state.records.filter { $0.facts.outcome == .accepted }.compactMap(\.action))
        let preparing = Set(
          state.records.filter { $0.facts.stage == .source && $0.facts.outcome == .preparing }
            .compactMap(\.action))
        let started = Set(
          state.records.filter { $0.facts.stage == .native && $0.facts.outcome == .started }
            .compactMap(\.action))
        return Snapshot(
          count: state.count,
          chain: state.headers == 1
            && !accepted.intersection(preparing).intersection(started)
              .isEmpty,
          example: state.example,
          acceptanceMode: state.headers == 1 && state.records.first?.build?.mode == .acceptance,
          scopedRetirement: state.records.contains {
            $0.scope != .intent && $0.facts.stage == .scope && $0.facts.outcome == .cancelled
          })
      }
    }
  }
#endif
