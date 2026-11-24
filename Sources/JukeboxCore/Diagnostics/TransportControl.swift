import Foundation

enum TransportControlLaunch {
  case absent, rejected
  #if DEBUG
    case run(UUID)
    case cleanup(UUID)
    case interactive(UUID)
  #endif
  init(arguments: [String]) {
    let flags = arguments.filter { $0.hasPrefix("--transport-") }
    guard !flags.isEmpty else {
      self = .absent
      return
    }
    #if DEBUG
      guard flags.count == 1, arguments.filter({ $0 == "--fixture" }).count == 1,
        !arguments.contains(where: {
          $0 == "--integration" || $0 == "--connect" || $0.hasPrefix("--profile-")
            || $0.hasPrefix("--catalog-scale") || $0.hasPrefix("--session-check")
            || $0.hasPrefix("--artwork-check")
        })
      else {
        self = .rejected
        return
      }
      let parts = flags[0].split(separator: "=", omittingEmptySubsequences: false)
      guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else {
        self = .rejected
        return
      }
      switch parts[0] {
      case "--transport-check": self = .run(id)
      case "--transport-cleanup": self = .cleanup(id)
      case "--transport-ui":
        let required: Set<String> = ["--fixture", "--muted", flags[0]]
        let supplied = Set(arguments)
        if supplied.contains("--quick-connect-fixture"),
          supplied != required.union(["--quick-connect-fixture"])
        {
          self = .rejected
          return
        }
        self =
          supplied.count == arguments.count && supplied.isSuperset(of: required)
            && supplied.isSubset(
              of: required.union([
                "--slow-fixture", "--long-album", "--saved-account-fixture",
                "--quick-connect-fixture",
              ]))
          ? .interactive(id) : .rejected
      default: self = .rejected
      }
    #else
      self = .rejected
    #endif
  }
  #if DEBUG
    var runID: UUID? {
      switch self {
      case .run(let id), .cleanup(let id): id
      case .absent, .rejected, .interactive: nil
      }
    }
  #endif
  var isAttempted: Bool { if case .absent = self { false } else { true } }
  func startup<T>(normal: () -> T, isolated: () -> T) -> T {
    isAttempted ? isolated() : normal()
  }
}
#if DEBUG
  struct TransportLocalInput {
    let scenario: String
    let nonce: UUID
    init(_ value: [String: String], runID: UUID) throws {
      guard Set(value.keys) == ["run_id", "scenario", "version", "nonce"],
        value["run_id"].flatMap(UUID.init(uuidString:)) == runID, value["version"] == "1",
        let scenario = value["scenario"], ["session", "artwork"].contains(scenario),
        let nonce = value["nonce"].flatMap(UUID.init(uuidString:))
      else { throw ClientError.invalidResponse }
      self.scenario = scenario
      self.nonce = nonce
    }
  }
  enum TransportControlFiles {
    static func tailDirectory(in caches: URL, runID: UUID) -> URL {
      caches.appendingPathComponent("JukeboxTransportTails", isDirectory: true)
        .appendingPathComponent(runID.uuidString, isDirectory: true)
    }
    static func prepareTails(in caches: URL, runID: UUID) throws -> URL {
      let folder = tailDirectory(in: caches, runID: runID)
      for directory in [folder.deletingLastPathComponent(), folder] {
        if !FileManager.default.fileExists(atPath: directory.path) {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
          throw ClientError.invalidResponse
        }
      }
      return try validatedTails(in: caches, runID: runID)
    }
    static func cleanupTails(in caches: URL, runID: UUID) throws {
      let folder = tailDirectory(in: caches, runID: runID)
      guard FileManager.default.fileExists(atPath: folder.path) else { return }
      try FileManager.default.removeItem(at: validatedTails(in: caches, runID: runID))
    }
    private static func validatedTails(in caches: URL, runID: UUID) throws -> URL {
      let folder = tailDirectory(in: caches, runID: runID)
      for directory in [folder.deletingLastPathComponent(), folder] {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
          throw ClientError.invalidResponse
        }
      }
      let files = try FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard files.count <= 8 else { throw ClientError.invalidResponse }
      for file in files {
        let values = try file.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard file.pathExtension == "mp3", file.lastPathComponent.hasPrefix("tail-"),
          UUID(uuidString: String(file.deletingPathExtension().lastPathComponent.dropFirst(5)))
            != nil,
          values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size <= 500_000
        else { throw ClientError.invalidResponse }
      }
      return folder
    }
    static func directory(in documents: URL, runID: UUID) -> URL {
      documents.appendingPathComponent("JukeboxTransport", isDirectory: true)
        .appendingPathComponent(runID.uuidString, isDirectory: true)
    }
    static func acceptsLiteral(_ host: String) -> Bool {
      let parts = host.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count == 4 else { return false }
      let bytes = parts.compactMap { part -> UInt8? in
        guard let value = UInt8(part), String(value) == part else { return nil }
        return value
      }
      return bytes.count == 4 && bytes[0] == 100 && (64...127).contains(bytes[1])
    }
    private static func validated(in documents: URL, runID: UUID) throws -> URL {
      let folder = directory(in: documents, runID: runID)
      for path in [documents.appendingPathComponent("JukeboxTransport"), folder] {
        let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
          throw ClientError.invalidResponse
        }
      }
      return folder
    }
    static func consumeInput(
      in documents: URL, runID: UUID, read: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) throws -> Data {
      let folder = try validated(in: documents, runID: runID)
      guard
        !FileManager.default.fileExists(atPath: folder.appendingPathComponent("report.json").path)
      else { throw ClientError.invalidResponse }
      let input = folder.appendingPathComponent("input.json")
      let values = try input.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size < 4096
      else { throw ClientError.invalidResponse }
      let data = try read(input)
      guard data.count < 4096,
        let value = try JSONSerialization.jsonObject(with: data) as? [String: String],
        value["run_id"].flatMap(UUID.init(uuidString:)) == runID
      else { throw ClientError.invalidResponse }
      try FileManager.default.removeItem(at: input)
      return data
    }
    static func publish(_ data: Data, in documents: URL, runID: UUID) throws {
      let folder = try validated(in: documents, runID: runID)
      let output = folder.appendingPathComponent("report.json")
      guard data.count <= 65536, !FileManager.default.fileExists(atPath: output.path) else {
        throw ClientError.invalidResponse
      }
      try data.write(to: output, options: .atomic)
    }
    static func cleanup(in documents: URL, runID: UUID) throws {
      let folder = directory(in: documents, runID: runID)
      guard FileManager.default.fileExists(atPath: folder.path) else { return }
      _ = try validated(in: documents, runID: runID)
      let files = try FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
      guard files.count <= 2 else { throw ClientError.invalidResponse }
      for file in files {
        guard ["input.json", "report.json"].contains(file.lastPathComponent),
          try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
          try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
          let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
          let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            as? [String: Any],
          (object["run_id"] as? String).flatMap(UUID.init(uuidString:)) == runID
        else { throw ClientError.invalidResponse }
      }
      try FileManager.default.removeItem(at: folder)
    }
  }
  nonisolated final class TransportCapture: @unchecked Sendable {
    static let shared = TransportCapture()
    enum State: String, Codable { case idle, recording, full, expired }
    typealias Stage = DiagnosticStage
    struct Evidence: Codable {
      let stage: Stage
      let http: Int
      let error: Int
      let bytes: Int
      let httpResponseObserved: Bool
      var diagnosticFacts: DiagnosticFacts {
        .init(
          stage, error != 0 || http >= 400 ? .failed : .succeeded,
          http: httpResponseObserved ? http : nil,
          code: error == 0 ? nil : DiagnosticCode(domain: .url, value: error), bytes: bytes)
      }
      init(stage: Stage, http: Int, error: Int, bytes: Int, httpResponseObserved: Bool? = nil) {
        self.stage = stage
        self.http = http
        self.error = error
        self.bytes = bytes
        self.httpResponseObserved = httpResponseObserved ?? (http > 0)
      }
    }
    struct Event: Codable {
      let elapsedMS: Int
      let evidence: Evidence
      let summary: String
      init(elapsedMS: Int, evidence: Evidence) {
        self.elapsedMS = elapsedMS
        self.evidence = evidence
        summary = evidence.diagnosticFacts.fields
      }
    }
    struct Context: Sendable {
      fileprivate let generation: UUID
      fileprivate let owner: UUID
    }
    @TaskLocal static var caller: Context?
    struct Ticket: Sendable {
      fileprivate let generation: UUID
      fileprivate let owner: UUID
      fileprivate let ordinal: Int
    }
    struct Export: Sendable {
      fileprivate let generation: UUID
      fileprivate let owner: UUID
      let text: String
    }
    private struct Report: Encodable {
      let marker = "ATS-20261022-3"
      let os: [Int]
      let policyBits: Int
      let state: State
      let truncated: Bool
      let discardedInFlight: Int
      let events: [Event]
    }
    private let lock = NSLock()
    private var generation = UUID()
    private var recording = UUID()
    private var owner = UUID()
    private var started: ContinuousClock.Instant?
    private var state = State.idle
    private var events: [Event] = []
    private var pending: Set<Int> = []
    private var ordinal = 0
    private var discarded = 0
    private var truncated = false
    private var policyBits = 0
    func start(policyBits: Int, now: ContinuousClock.Instant = .now) {
      lock.lock()
      defer { lock.unlock() }
      clearLocked()
      self.policyBits = policyBits & 63
      started = now
      state = .recording
    }
    func clear(retire: Bool = false) {
      lock.lock()
      defer { lock.unlock() }
      if retire { owner = UUID() }
      clearLocked()
    }
    private func clearLocked() {
      generation = UUID()
      recording = UUID()
      started = nil
      state = .idle
      events = []
      pending = []
      ordinal = 0
      discarded = 0
      truncated = false
      policyBits = 0
    }
    private func expireLocked(_ now: ContinuousClock.Instant) {
      if let started, started.duration(to: now) >= .seconds(90) {
        clearLocked()
        state = .expired
      }
    }
    func currentState(now: ContinuousClock.Instant = .now) -> State {
      lock.lock()
      defer { lock.unlock() }
      expireLocked(now)
      return state
    }
    func context(now: ContinuousClock.Instant = .now) -> Context? {
      lock.lock()
      defer { lock.unlock() }
      expireLocked(now)
      guard state == .recording else { return nil }
      return Context(generation: generation, owner: owner)
    }
    struct RecordingLease: Sendable { fileprivate let id: UUID }
    func recordingLease(now: ContinuousClock.Instant = .now) -> RecordingLease? {
      lock.lock()
      defer { lock.unlock() }
      expireLocked(now)
      guard state == .recording || state == .full else { return nil }
      return RecordingLease(id: recording)
    }
    func owns(_ lease: RecordingLease, now: ContinuousClock.Instant = .now) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      expireLocked(now)
      return !Task.isCancelled && lease.id == recording && (state == .recording || state == .full)
    }
    func withRecording<T>(
      _ lease: RecordingLease, now: ContinuousClock.Instant = .now, perform: () throws -> T
    ) throws -> T {
      lock.lock()
      defer { lock.unlock() }
      expireLocked(now)
      guard !Task.isCancelled, lease.id == recording, state == .recording || state == .full else {
        throw CancellationError()
      }
      return try perform()
    }
    func clear(owned lease: RecordingLease) {
      lock.lock()
      defer { lock.unlock() }
      guard lease.id == recording else { return }
      clearLocked()
    }
    func export(owned lease: RecordingLease, now: ContinuousClock.Instant = .now) -> Export? {
      lock.lock()
      defer { lock.unlock() }
      expireLocked(now)
      guard !Task.isCancelled, lease.id == recording else { return nil }
      return exportLocked()
    }
    func begin(context: Context? = nil, now: ContinuousClock.Instant = .now) -> Ticket? {
      lock.lock()
      defer { lock.unlock() }
      expireLocked(now)
      guard !Task.isCancelled, state == .recording, let context,
        context.generation == generation, context.owner == owner
      else { return nil }
      guard pending.count < 32 else {
        discarded += 1
        truncated = true
        return nil
      }
      ordinal += 1
      pending.insert(ordinal)
      return Ticket(generation: generation, owner: owner, ordinal: ordinal)
    }
    func finish(_ ticket: Ticket, now: ContinuousClock.Instant = .now, extract: () -> Evidence) {
      lock.lock()
      defer { lock.unlock() }
      expireLocked(now)
      guard !Task.isCancelled, state == .recording, ticket.generation == generation,
        ticket.owner == owner,
        pending.remove(ticket.ordinal) != nil, let started
      else { return }
      let evidence = extract()
      let elapsed = started.duration(to: now).components
      events.append(
        Event(
          elapsedMS: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000),
          evidence: evidence))
      if events.count == 32 {
        discarded += pending.count
        pending = []
        truncated = true
        state = .full
        generation = UUID()
      }
    }
    func export(now: ContinuousClock.Instant = .now) -> Export? {
      lock.lock()
      defer { lock.unlock() }
      expireLocked(now)
      return exportLocked()
    }
    private func exportLocked() -> Export? {
      guard state == .recording || state == .full else { return nil }
      let os = ProcessInfo.processInfo.operatingSystemVersion
      let report = Report(
        os: [os.majorVersion, os.minorVersion, os.patchVersion], policyBits: policyBits,
        state: state, truncated: truncated, discardedInFlight: discarded, events: events)
      guard let data = try? JSONEncoder().encode(report),
        let text = String(data: data, encoding: .utf8)
      else { return nil }
      return Export(generation: generation, owner: owner, text: text)
    }
    @discardableResult func withCurrentExport(
      _ value: Export, now: ContinuousClock.Instant = .now, publish: () -> Void
    ) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      expireLocked(now)
      guard state == .recording || state == .full, value.generation == generation,
        value.owner == owner
      else { return false }
      publish()
      return true
    }
    static func bundledPolicyBits() -> Int {
      let policy =
        Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any] ?? [:]
      let domains = policy["NSExceptionDomains"] as? [String: [String: Any]] ?? [:]
      let local = policy["NSAllowsLocalNetworking"] as? Bool == true
      let cidr = domains["100.64.0.0/10"]?["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true
      let dns =
        domains["ts.net"]?["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true
        && domains["ts.net"]?["NSIncludesSubdomains"] as? Bool == true
      return (local ? 1 : 0) | (cidr ? 2 : 0) | (dns ? 4 : 0)
        | (policy["NSAllowsArbitraryLoads"] as? Bool == true ? 8 : 0)
        | (policy["NSAllowsArbitraryLoadsForMedia"] as? Bool == true ? 16 : 0)
        | (policy["NSAllowsArbitraryLoadsInWebContent"] as? Bool == true ? 32 : 0)
    }
  }
  @MainActor final class TransportControlPhase {
    let context: TransportCapture.Context
    private let capture: TransportCapture
    private let lease: TransportCapture.RecordingLease
    private var active = true
    init(capture: TransportCapture, policyBits: Int, now: ContinuousClock.Instant = .now) throws {
      self.capture = capture
      capture.start(policyBits: policyBits, now: now)
      guard let lease = capture.recordingLease(now: now), let context = capture.context(now: now)
      else { throw CancellationError() }
      self.lease = lease
      self.context = context
    }
    func current(now: ContinuousClock.Instant = .now) -> Bool {
      active && capture.owns(lease, now: now)
    }
    func perform<T>(now: ContinuousClock.Instant = .now, _ action: () throws -> T) throws -> T {
      guard active else { throw CancellationError() }
      return try capture.withRecording(lease, now: now, perform: action)
    }
    func snapshot(now: ContinuousClock.Instant = .now) -> TransportCapture.Export? {
      guard active else { return nil }
      return capture.export(owned: lease, now: now)
    }
    func retire() {
      active = false
      capture.clear(owned: lease)
    }
  }

  actor TransportControlHTTP: HTTPTransport {
    let phase: TransportControlPhase
    let base: any HTTPTransport
    init(phase: TransportControlPhase, base: any HTTPTransport = LiveHTTP()) {
      self.phase = phase
      self.base = base
    }
    func send(_ request: URLRequest) async throws -> HTTPReply {
      guard await phase.current() else { throw CancellationError() }
      let reply = try await base.send(request)
      guard await phase.current() else { throw CancellationError() }
      return reply
    }
  }

#endif
