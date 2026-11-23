import Foundation

final class DiagnosticSession: @unchecked Sendable {
  struct Time: Sendable {
    let utc: Date
    let uptime: TimeInterval
  }
  typealias Sink = @Sendable (DiagnosticRecord) -> Void
  static let disabled = DiagnosticSession(enabled: false)
  private let lock = NSLock()
  private var sequence: UInt64 = 0
  private var action: UInt64 = 0
  private let enabled: Bool
  private let launch: UUID
  private let start: TimeInterval
  private let clock: @Sendable () -> Time
  private let sink: Sink
  init(
    build: DiagnosticBuild? = nil, launch: UUID = UUID(), enabled: Bool = true,
    clock: @escaping @Sendable () -> Time = {
      Time(utc: Date(), uptime: ProcessInfo.processInfo.systemUptime)
    }, sink: @escaping Sink = { _ in }
  ) {
    self.enabled = enabled
    self.launch = launch
    self.clock = clock
    self.sink = sink
    start = clock().uptime
    if enabled, let build {
      deliver(record(category: .lifecycle, facts: .init(.launch, .started), build: build))
    }
  }
  func begin(
    _ kind: DiagnosticAction, quality: DiagnosticQuality = .unknown,
    role: DiagnosticRole = .current
  ) -> DiagnosticContext? {
    guard enabled else { return nil }
    let ordinal = lock.withLock {
      action += 1
      return action
    }
    let context = DiagnosticContext(
      session: self, action: ordinal, kind: kind, quality: quality, role: role)
    context.event(.intent, .init(.command, .accepted))
    return context
  }
  fileprivate func now() -> Time { clock() }
  fileprivate func record(
    category: DiagnosticCategory, action: UInt64? = nil, kind: DiagnosticAction? = nil,
    quality: DiagnosticQuality = .unknown, role: DiagnosticRole = .unknown,
    scope: DiagnosticScope? = nil, facts: DiagnosticFacts,
    dropped: UInt64 = 0, build: DiagnosticBuild? = nil
  ) -> DiagnosticRecord {
    lock.withLock {
      sequence += 1
      let time = clock()
      return DiagnosticRecord(
        launch: launch, sequence: sequence, utc: time.utc,
        elapsedMS: Self.milliseconds(time.uptime - start), category: category, action: action,
        actionKind: kind, quality: quality, role: role, scope: scope,
        facts: facts, dropped: dropped,
        build: build)
    }
  }
  fileprivate func deliver(_ record: DiagnosticRecord) { sink(record) }
  static func milliseconds(_ seconds: TimeInterval) -> UInt64 {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return UInt64(min(seconds * 1000, Double(UInt64.max / 2)))
  }
}

struct DiagnosticEmission: Sendable {
  fileprivate let session: DiagnosticSession
  let record: DiagnosticRecord
  func publish() { session.deliver(record) }
}

private final class DiagnosticBudget: @unchecked Sendable {
  private let lock = NSLock()
  private var states = 0
  private var dropped: UInt64 = 0
  func admit(limit: Int = 64) -> Bool {
    lock.withLock {
      guard states < limit else {
        dropped += 1
        return false
      }
      states += 1
      return true
    }
  }
  func drop() { lock.withLock { dropped += 1 } }
  func takeDropped() -> UInt64 {
    lock.withLock {
      let count = dropped
      dropped = 0
      return count
    }
  }
}

final class DiagnosticContext: @unchecked Sendable {
  private let session: DiagnosticSession
  private let action: UInt64
  private let kind: DiagnosticAction
  private let quality: DiagnosticQuality
  private let role: DiagnosticRole
  private let scope: DiagnosticScope
  private let ownsAction: Bool
  private let started: TimeInterval
  private let lock = NSLock()
  private var live = true
  private let budget: DiagnosticBudget
  private var lastState: DiagnosticFacts?
  fileprivate init(
    session: DiagnosticSession, action: UInt64, kind: DiagnosticAction, quality: DiagnosticQuality,
    role: DiagnosticRole
  ) {
    self.session = session
    budget = DiagnosticBudget()
    self.action = action
    self.kind = kind
    self.quality = quality
    self.role = role
    scope = .intent
    ownsAction = true
    started = session.now().uptime
  }
  private init(copying context: DiagnosticContext, role: DiagnosticRole?, scope: DiagnosticScope) {
    session = context.session
    action = context.action
    kind = context.kind
    quality = context.quality
    self.role = role ?? context.role
    self.scope = scope
    ownsAction = false
    started = context.started
    budget = context.budget
  }
  func handoff(role: DiagnosticRole? = nil, scope: DiagnosticScope = .preparation)
    -> DiagnosticContext?
  {
    lock.withLock {
      guard live, !Task.isCancelled else { return nil }
      return DiagnosticContext(copying: self, role: role, scope: scope)
    }
  }
  @discardableResult func event(_ category: DiagnosticCategory, _ facts: DiagnosticFacts)
    -> DiagnosticRecord?
  {
    event(category) { facts }
  }
  @discardableResult func event(_ category: DiagnosticCategory, extract: () -> DiagnosticFacts)
    -> DiagnosticRecord?
  {
    let emission = prepareEvent(category, extract: extract)
    emission?.publish()
    return emission?.record
  }
  func prepareEvent(_ category: DiagnosticCategory, extract: () -> DiagnosticFacts)
    -> DiagnosticEmission?
  {
    lock.withLock {
      guard live, !Task.isCancelled else { return nil }
      if category == .network, !budget.admit(limit: 32) { return nil }
      var facts = extract()
      if [.preparing, .playing, .waiting, .paused].contains(facts.outcome) {
        guard facts != lastState else {
          budget.drop()
          return nil
        }
        if category != .network, !budget.admit() { return nil }
        lastState = facts
      }
      if facts.durationMS == nil,
        [.playing, .succeeded, .failed, .cancelled].contains(facts.outcome)
      {
        facts.durationMS = DiagnosticSession.milliseconds(session.now().uptime - started)
      }
      return DiagnosticEmission(session: session, record: stamp(category, facts: facts))
    }
  }
  func retire(_ reason: DiagnosticReason) {
    let record: DiagnosticRecord? = lock.withLock {
      guard live else { return nil }
      live = false
      return stamp(
        .lifecycle,
        facts: .init(
          ownsAction ? .command : .scope, .cancelled, reason: reason,
          durationMS: DiagnosticSession.milliseconds(session.now().uptime - started)))
    }
    if let record { session.deliver(record) }
  }
  private func stamp(
    _ category: DiagnosticCategory, facts: DiagnosticFacts
  ) -> DiagnosticRecord {
    let count = budget.takeDropped()
    return session.record(
      category: category, action: action, kind: kind, quality: quality,
      role: role, scope: scope, facts: facts, dropped: count)
  }
}
