import CryptoKit
import Foundation
import Network
import Security
import Synchronization

struct MediaBridgeRequest: Sendable {
  let method: String
  let path: String
  let range: String?
  static func parse(_ bytes: Data, port: UInt16) throws -> Self {
    guard bytes.count <= 16_384,
      bytes.allSatisfy({ $0 == 13 || $0 == 10 || (32...126).contains($0) }),
      let text = String(data: bytes, encoding: .ascii), text.hasSuffix("\r\n\r\n")
    else { throw ClientError.invalidResponse }
    let lines = String(decoding: bytes.dropLast(4), as: UTF8.self).components(separatedBy: "\r\n")
    guard lines.count <= 33, let line = lines.first else { throw ClientError.invalidResponse }
    let start = line.split(separator: " ", omittingEmptySubsequences: false)
    guard start.count == 3, ["GET", "HEAD"].contains(String(start[0])),
      ["HTTP/1.0", "HTTP/1.1"].contains(String(start[2])), start[1].count == 67,
      start[1].hasPrefix("/m/"),
      start[1].dropFirst(3).allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else { throw ClientError.invalidResponse }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard line.utf8.allSatisfy({ (32...126).contains($0) }) else {
        throw ClientError.invalidResponse
      }
      guard let colon = line.firstIndex(of: ":") else { throw ClientError.invalidResponse }
      let name = String(line[..<colon]).lowercased()
      guard !name.isEmpty,
        name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
        headers[name] == nil
      else { throw ClientError.invalidResponse }
      headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }
    guard headers["host"] == "127.0.0.1:\(port)", headers["origin"] == nil,
      headers["transfer-encoding"] == nil, headers["expect"] == nil,
      headers["content-length"] == nil || headers["content-length"] == "0"
    else { throw ClientError.invalidResponse }
    if let range = headers["range"] { _ = try MediaBridgeRange(range) }
    return Self(method: String(start[0]), path: String(start[1]), range: headers["range"])
  }
}
struct MediaBridgeRange: Sendable {
  let start: Int64?
  let end: Int64?
  init(_ text: String) throws {
    guard text.hasPrefix("bytes="), text.count <= 64 else { throw ClientError.invalidResponse }
    let pair = text.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
    guard pair.count == 2, pair.allSatisfy({ $0.utf8.allSatisfy({ (48...57).contains($0) }) })
    else { throw ClientError.invalidResponse }
    start = pair[0].isEmpty ? nil : Int64(pair[0])
    end = pair[1].isEmpty ? nil : Int64(pair[1])
    guard pair[0].isEmpty || start != nil, pair[1].isEmpty || end != nil,
      start != nil || end != nil,
      start == nil ? end! > 0 : (end == nil || end! >= start!)
    else { throw ClientError.invalidResponse }
  }
  func matches(start actual: Int64, end last: Int64, total: Int64) -> Bool {
    if let start { return actual == start && last == min(end ?? (total - 1), total - 1) }
    return actual == max(0, total - end!) && last == total - 1
  }
}
struct MediaBridgeResponse: Sendable {
  struct Rejection: Error, Sendable {
    let status: Int?
    let reason: DiagnosticResponseRejection
  }
  let status: Int
  let header: Data
  let bodyLength: Int64?
  let chunked: Bool
  let noBody: Bool
  private(set) var lengthlessMP3 = false
  init(_ response: HTTPURLResponse, request: MediaBridgeRequest) throws {
    let status = response.statusCode
    self.status = status
    guard (200...599).contains(status) else {
      throw Rejection(status: status, reason: .status)
    }
    if status != 200 && status != 206 {
      header = Data(
        "HTTP/1.1 \(status) Media response\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
      bodyLength = 0
      chunked = false
      noBody = true
      return
    }
    let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
    guard encoding == nil || encoding == "identity" else {
      throw Rejection(status: status, reason: .contentEncoding)
    }
    let length = response.value(forHTTPHeaderField: "Content-Length")
    let transfer = response.value(forHTTPHeaderField: "Transfer-Encoding")?.lowercased()
    guard transfer == nil || ((transfer == "chunked" || transfer == "identity") && length == nil)
    else {
      throw Rejection(status: status, reason: .transferFraming)
    }
    var expected: Int64?
    if let length {
      guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
        let number = Int64(length)
      else { throw Rejection(status: status, reason: .contentLength) }
      expected = number
    }
    let allowed = [
      "audio/mpeg", "audio/mp3", "audio/flac", "audio/x-flac", "audio/wav", "audio/x-wav",
      "audio/wave", "audio/aac", "audio/aacp", "audio/mp4", "audio/ogg", "audio/opus", "audio/aiff",
      "audio/x-aiff", "audio/x-ms-wma", "application/ogg", "application/octet-stream",
    ]
    let mime = response.mimeType?.lowercased() ?? "application/octet-stream"
    guard allowed.contains(mime) else {
      throw Rejection(status: status, reason: .contentType)
    }
    var fields =
      "HTTP/1.1 \(status) Media response\r\nContent-Type: \(mime)\r\nConnection: close\r\n"
    if status == 206 {
      guard let range = response.value(forHTTPHeaderField: "Content-Range"),
        range.hasPrefix("bytes "), range.count <= 100
      else { throw Rejection(status: status, reason: .contentRange) }
      let pieces = range.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
      let bounds = pieces.first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
      guard pieces.count == 2, bounds.count == 2,
        (bounds + [pieces[1]]).allSatisfy({
          !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) })
        }),
        let first = Int64(bounds[0]), let last = Int64(bounds[1]), let total = Int64(pieces[1]),
        first <= last, last < total, let wanted = request.range,
        let requested = try? MediaBridgeRange(wanted),
        requested.matches(start: first, end: last, total: total),
        expected == nil || expected == last - first + 1
      else { throw Rejection(status: status, reason: .contentRange) }
      expected = last - first + 1
      fields += "Content-Range: \(range)\r\n"
    }
    if response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes" {
      fields += "Accept-Ranges: bytes\r\n"
    }
    lengthlessMP3 =
      status == 200 && expected == nil && ["audio/mpeg", "audio/mp3"].contains(mime)
      && response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() != "bytes"
    noBody = request.method == "HEAD"
    bodyLength = expected
    chunked = expected == nil && !noBody
    if let expected {
      fields += "Content-Length: \(expected)\r\n"
    } else if chunked {
      fields += "Transfer-Encoding: chunked\r\n"
    }
    header = Data((fields + "\r\n").utf8)
  }
  func frame(_ data: Data) -> Data {
    guard chunked else { return data }
    return Data((String(data.count, radix: 16) + "\r\n").utf8) + data + Data("\r\n".utf8)
  }
}

private struct MediaBridgeBody {
  struct ReadFailure: Error { let cause: URLError }
  static let maximumReplayBytes: Int64 = 4 * 1024 * 1024
  var received: Int64 = 0
  var delivered: Int64 = 0
  var prefix: SHA256?

  mutating func forward(
    _ bytes: URLSession.AsyncBytes, plan: MediaBridgeResponse, replaying: Bool,
    deliver: (Data, Bool) async throws -> Void, note: (Int64, Int64, Bool) -> Void
  ) async throws {
    let offset = replaying ? delivered : 0
    let expected = replaying ? prefix?.finalize() : nil
    var verification = SHA256()
    var iterator = bytes.makeAsyncIterator()
    var chunk = Data()
    received = 0
    while true {
      let byte: UInt8?
      do { byte = try await iterator.next() } catch let error as URLError {
        throw ReadFailure(cause: error)
      }
      if let byte {
        received += 1
        if let length = plan.bodyLength, received > length { throw ClientError.invalidResponse }
        chunk.append(byte)
        if chunk.count < 16_384 { continue }
      } else {
        guard received >= offset, plan.bodyLength == nil || received == plan.bodyLength else {
          throw ClientError.invalidResponse
        }
      }
      try Task.checkCancellation()
      if !chunk.isEmpty {
        if received <= offset {
          verification.update(data: chunk)
          if received == offset {
            guard verification.finalize() == expected else {
              throw MediaBridgeResponse.Rejection(status: plan.status, reason: .changedPrefix)
            }
            note(received, delivered, true)
          }
        } else {
          note(received, delivered, false)
          try await deliver(plan.frame(chunk), plan.bodyLength == received)
          delivered = received
          if !replaying && delivered <= Self.maximumReplayBytes {
            prefix?.update(data: chunk)
          } else {
            prefix = nil
          }
          note(received, delivered, false)
        }
        chunk.removeAll(keepingCapacity: true)
      }
      if byte == nil { return }
    }
  }
}

private final class MediaBridgeReadDeadline: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private struct State {
    var task: URLSessionTask?
    var observation: NSKeyValueObservation?
    var readingSince: Double? = ProcessInfo.processInfo.systemUptime
    var sendingSince: Double?
    var longestSend = 0.0
    var received: Int64?
    var timedOut = false
    var finished = false
  }
  private let state = Mutex(State())
  let interval: TimeInterval
  init(interval: TimeInterval) { self.interval = interval }

  func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
    let observation = task.observe(\.countOfBytesReceived, options: [.new]) {
      [weak self] _, change in
      guard let count = change.newValue else { return }
      self?.state.withLock {
        guard !$0.finished, count > ($0.received ?? 0) else { return }
        $0.received = count
        if $0.readingSince != nil { $0.readingSince = ProcessInfo.processInfo.systemUptime }
      }
    }
    let initialCount = task.countOfBytesReceived
    let expired = state.withLock {
      guard !$0.finished else { return true }
      $0.task = task
      $0.observation = observation
      $0.received = max($0.received ?? 0, initialCount)
      return $0.timedOut
    }
    if expired { task.cancel() }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }

  func setReading(_ reading: Bool) {
    let now = ProcessInfo.processInfo.systemUptime
    state.withLock {
      if let start = $0.sendingSince { $0.longestSend = max($0.longestSend, now - start) }
      $0.sendingSince = reading ? nil : now
      $0.readingSince = reading && !$0.finished ? now : nil
    }
  }
  var timedOut: Bool { state.withLock { $0.timedOut } }

  func monitor() async {
    var delay = interval
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      let (remaining, task): (Double, URLSessionTask?) = state.withLock {
        guard !$0.finished else { return (0, nil) }
        guard let since = $0.readingSince else { return (interval, nil) }
        let wait = interval - (ProcessInfo.processInfo.systemUptime - since)
        if wait > 0 { return (wait, nil) }
        $0.timedOut = true
        return (0, $0.task)
      }
      if remaining == 0 {
        task?.cancel()
        return
      }
      delay = remaining
    }
  }

  func collect(into facts: inout PlaybackTransferEvidence, at now: Double) {
    state.withLock {
      facts.taskReceived = $0.received
      facts.longestPlayerWait = max($0.longestSend, $0.sendingSince.map { max(0, now - $0) } ?? 0)
      facts.inputTimedOut = $0.timedOut
    }
  }
  @discardableResult func finish() -> Bool {
    let (observation, expired) = state.withLock {
      $0.finished = true
      let observation = $0.observation
      $0.observation = nil
      $0.task = nil
      return (observation, $0.timedOut)
    }
    observation?.invalidate()
    return expired
  }
}

actor MediaHTTPBridge {
  private final class Job {
    let connection: NWConnection
    var header = Data()
    var token: String?
    var task: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    var finalWriteStarted = false
    init(_ connection: NWConnection) { self.connection = connection }
  }
  private let session: URLSession
  private let readTimeout: TimeInterval
  private var listener: NWListener?
  private var startup: CheckedContinuation<Void, Error>?
  private var startupDeadline: Task<Void, Never>?
  private struct Worker: Sendable {
    let token: String
    let task: Task<Void, Never>
  }
  private struct Source: Sendable {
    let upstream: URLRequest
    let progressiveTranscode: Bool
    let diagnostic: DiagnosticContext?
    var requestOrdinal = 0
    var transfers: [UUID: Transfer] = [:]
  }
  private struct Transfer: Sendable {
    var evidence: PlaybackTransferEvidence
    var lastByte: Double?
    var readDeadline: MediaBridgeReadDeadline?
  }
  private struct Catalog: Sendable {
    var stopped = false
    var port: UInt16?
    var sources: [String: Source] = [:]
    var workers: [UUID: Worker] = [:]
  }
  private let catalog = Mutex(Catalog())
  nonisolated var port: UInt16? { catalog.withLock { $0.port } }
  private var stopped: Bool { catalog.withLock { $0.stopped } }
  private var jobs: [UUID: Job] = [:]
  private(set) var maximumActive = 0
  private(set) var maximumChunk = 0
  var activeCount: Int { jobs.count }
  init(protocolClasses: [AnyClass]? = nil, idleTimeout: TimeInterval? = nil) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    readTimeout = idleTimeout ?? configuration.timeoutIntervalForRequest
    configuration.timeoutIntervalForRequest = configuration.timeoutIntervalForResource
    configuration.protocolClasses = protocolClasses
    session = URLSession(configuration: configuration)
  }
  func start() async throws {
    guard !stopped, listener == nil else { throw ClientError.unavailable }
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    parameters.requiredInterfaceType = .loopback
    let owned = try NWListener(using: parameters)
    owned.newConnectionLimit = 4
    listener = owned
    owned.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) }
    }
    owned.stateUpdateHandler = { [weak self] state in Task { await self?.state(state) } }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        startup = continuation
        startupDeadline = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
          self?.stop()
        }
        owned.start(queue: .global(qos: .userInitiated))
      }
    } onCancel: {
      Task { [weak self] in self?.stop() }
    }
  }
  private func state(_ state: NWListener.State) {
    guard !stopped, let listener else { return }
    switch state {
    case .ready:
      guard let value = listener.port?.rawValue, value != 0 else {
        stop()
        return
      }
      catalog.withLock { $0.port = value }
      startupDeadline?.cancel()
      startupDeadline = nil
      let ready = startup
      startup = nil
      ready?.resume()
    case .failed, .cancelled: stop()
    default: break
    }
  }
  nonisolated func register(_ source: MediaSource, diagnostic: DiagnosticContext? = nil) throws
    -> URL
  {
    return try catalog.withLock { state in
      guard !state.stopped, let port = state.port, source.usesBridge,
        let host = source.url.host,
        !host.isEmpty, source.url.user == nil, source.url.password == nil,
        source.url.fragment == nil,
        !(host == "127.0.0.1" && source.url.port == Int(port)), state.sources.count < 3
      else { throw ClientError.invalidResponse }
      var random = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
        throw ClientError.unavailable
      }
      let token = random.map { String(format: "%02x", $0) }.joined()
      state.sources[token] = Source(
        upstream: source.upstreamRequest,
        progressiveTranscode: source.serverTimeSeek && source.quality != .original,
        diagnostic: diagnostic)
      return URL(string: "http://127.0.0.1:\(port)/m/\(token)")!
    }
  }
  nonisolated func retire(_ url: URL) {
    let token = String(url.path.dropFirst(3))
    let cancelled: [Task<Void, Never>]? = catalog.withLock { state in
      guard url.scheme == "http", url.host == "127.0.0.1", url.port == state.port.map(Int.init),
        url.path == "/m/" + token, state.sources.removeValue(forKey: token) != nil
      else { return nil }
      let ids = state.workers.keys.filter { state.workers[$0]?.token == token }
      return ids.compactMap { state.workers.removeValue(forKey: $0)?.task }
    }
    if let cancelled {
      for task in cancelled { task.cancel() }
      Task { await retireJobs(token) }
    }
  }
  nonisolated func evidence(for url: URL, at now: Double) -> [PlaybackTransferEvidence] {
    withEvidence(for: url, at: now) { $0 } ?? []
  }
  nonisolated func withEvidence<T>(
    for url: URL, at now: Double, _ body: ([PlaybackTransferEvidence]) -> T
  ) -> T? {
    catalog.withLock { state in
      let token = String(url.path.dropFirst(3))
      guard !state.stopped, url.scheme == "http", url.host == "127.0.0.1",
        url.port == state.port.map(Int.init), url.path == "/m/" + token,
        let source = state.sources[token]
      else { return nil }
      let evidence = source.transfers.values.sorted { $0.evidence.ordinal < $1.evidence.ordinal }
        .map {
          var evidence = $0.evidence
          evidence.lastByteAge = $0.lastByte.map { max(0, now - $0) }
          $0.readDeadline?.collect(into: &evidence, at: now)
          return evidence
        }
      return body(evidence)
    }
  }
  private nonisolated func beginTransfer(_ id: UUID, token: String, request: MediaBridgeRequest) {
    catalog.withLock { state in
      guard !state.stopped, var source = state.sources[token] else { return }
      let terminal = source.transfers.filter {
        ![.requesting, .streaming].contains($0.value.evidence.state)
      }
      if source.transfers.count >= 4,
        let oldest = terminal.min(by: {
          $0.value.evidence.ordinal < $1.value.evidence.ordinal
        })
      {
        source.transfers.removeValue(forKey: oldest.key)
      }
      guard source.transfers.count < 4 else { return }
      source.requestOrdinal = min(Int.max - 1, source.requestOrdinal) + 1
      let range = request.range.flatMap { try? MediaBridgeRange($0) }
      var facts = PlaybackTransferEvidence()
      facts.ordinal = source.requestOrdinal
      facts.head = request.method == "HEAD"
      facts.rangeStart = range?.start
      facts.rangeEnd = range?.end
      facts.suffix = range != nil && range?.start == nil
      source.transfers[id] = Transfer(evidence: facts)
      state.sources[token] = source
    }
  }
  private nonisolated func noteTransfer(
    _ id: UUID, token: String, status: Int? = nil, expected: Int64? = nil,
    received: Int64? = nil, delivered: Int64? = nil,
    terminal: PlaybackTransferEvidence.State? = nil,
    rejection: DiagnosticResponseRejection? = nil, code: DiagnosticCode? = nil,
    recovery: PlaybackTransferEvidence.Recovery? = nil
  ) {
    catalog.withLock { state in
      guard !state.stopped, var transfer = state.sources[token]?.transfers[id] else { return }
      if let status { transfer.evidence.status = status }
      if let recovery { transfer.evidence.recovery = recovery }
      if let code { transfer.evidence.code = code }
      if let rejection { transfer.evidence.rejection = rejection }
      if let expected { transfer.evidence.expected = expected }
      if let received {
        if received > transfer.evidence.received, terminal == nil {
          transfer.lastByte = ProcessInfo.processInfo.systemUptime
        }
        transfer.evidence.received = received
      }
      if let delivered { transfer.evidence.delivered = delivered }
      if let terminal { transfer.evidence.state = terminal }
      state.sources[token]?.transfers[id] = transfer
    }
  }
  private func retireJobs(_ token: String) {
    for id in jobs.keys.filter({ jobs[$0]?.token == token }) { close(id, aborting: true) }
  }
  nonisolated func stop() {
    let cancelled: [Task<Void, Never>]? = catalog.withLock { state in
      guard !state.stopped else { return nil }
      state.stopped = true
      state.port = nil
      state.sources.removeAll()
      let tasks = state.workers.values.map(\.task)
      state.workers.removeAll()
      return tasks
    }
    guard let cancelled else { return }
    for task in cancelled { task.cancel() }
    session.invalidateAndCancel()
    Task { await shutdown() }
  }
  private func shutdown() {
    startupDeadline?.cancel()
    startupDeadline = nil
    let waiting = startup
    startup = nil
    waiting?.resume(throwing: CancellationError())
    listener?.newConnectionHandler = nil
    listener?.stateUpdateHandler = nil
    listener?.cancel()
    listener = nil
    for id in Array(jobs.keys) { close(id, aborting: true) }
  }
  private static func loopback(_ endpoint: NWEndpoint?) -> Bool {
    guard case .hostPort(let host, _) = endpoint, case .ipv4(let ip) = host else { return false }
    return ip == .loopback
  }
  private func accept(_ connection: NWConnection) {
    guard !stopped, port != nil, jobs.count < 4, Self.loopback(connection.endpoint) else {
      connection.cancel()
      releaseListenerSlot()
      return
    }
    let id = UUID()
    let job = Job(connection)
    jobs[id] = job
    maximumActive = max(maximumActive, jobs.count)
    connection.stateUpdateHandler = { [weak self] state in
      Task { await self?.connectionState(state, id: id) }
    }
    job.deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      await self?.close(id)
    }
    connection.start(queue: .global(qos: .userInitiated))
  }
  private func connectionState(_ state: NWConnection.State, id: UUID) {
    guard let job = jobs[id] else { return }
    if case .ready = state {
      guard Self.loopback(job.connection.currentPath?.localEndpoint),
        case .hostPort(_, let localPort) = job.connection.currentPath?.localEndpoint,
        localPort.rawValue == port
      else {
        close(id)
        return
      }
      readHeader(id)
    } else if case .failed = state {
      peerDisconnected(id)
    } else if case .cancelled = state {
      peerDisconnected(id)
    }
  }
  private func readHeader(_ id: UUID) {
    guard let job = jobs[id], !stopped else { return }
    job.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
      [weak self] data, _, ended, error in
      Task { await self?.receivedHeader(id, data: data, ended: ended, error: error) }
    }
  }
  private func receivedHeader(_ id: UUID, data: Data?, ended: Bool, error: NWError?) {
    guard let job = jobs[id], !stopped else { return }
    guard error == nil, let data, !data.isEmpty, job.header.count + data.count <= 16_384 else {
      close(id)
      return
    }
    job.header.append(data)
    if let end = job.header.range(of: Data("\r\n\r\n".utf8)) {
      guard end.upperBound == job.header.endIndex, let port,
        let request = try? MediaBridgeRequest.parse(job.header, port: port),
        let source = catalog.withLock({ $0.sources[String(request.path.dropFirst(3))] })
      else {
        close(id)
        return
      }
      job.deadline?.cancel()
      job.deadline = nil
      job.header = Data()
      job.token = String(request.path.dropFirst(3))
      beginTransfer(id, token: String(request.path.dropFirst(3)), request: request)
      monitorDisconnect(id)
      upstream(id, request: request, source: source)
    } else if ended {
      close(id)
    } else {
      readHeader(id)
    }
  }
  private func monitorDisconnect(_ id: UUID) {
    guard let job = jobs[id] else { return }
    job.connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
      [weak self] data, _, ended, error in
      Task {
        await self?.receivedExtra(id, hasData: data?.isEmpty == false, ended: ended, error: error)
      }
    }
  }
  private func receivedExtra(_ id: UUID, hasData: Bool, ended: Bool, error: NWError?) {
    if hasData {
      close(id)
    } else if ended || error != nil {
      peerDisconnected(id)
    } else {
      monitorDisconnect(id)
    }
  }
  private func peerDisconnected(_ id: UUID) {
    guard jobs[id]?.finalWriteStarted == false else { return }
    close(id)
  }
  private func live(_ id: UUID) -> Bool {
    guard !stopped, let job = jobs[id], let token = job.token else { return false }
    return catalog.withLock { !$0.stopped && $0.sources[token] != nil }
  }
  private func upstream(_ id: UUID, request: MediaBridgeRequest, source: Source) {
    guard let job = jobs[id], live(id) else { return }
    var wire = source.upstream
    wire.httpMethod = request.method
    if let range = request.range { wire.setValue(range, forHTTPHeaderField: "Range") }
    wire.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let session = session
    let readTimeout = readTimeout
    let token = String(request.path.dropFirst(3))
    let task = Task.detached { [weak self] in
      var status: Int?
      var body = MediaBridgeBody()
      var transportRequest = wire
      var deadline: MediaBridgeReadDeadline?
      do {
        for attempt in 0...1 {
          try Task.checkCancellation()
          guard await self?.live(id) == true else { throw CancellationError() }
          let read = MediaBridgeReadDeadline(interval: readTimeout)
          deadline = read
          self?.catalog.withLock { $0.sources[token]?.transfers[id]?.readDeadline = read }
          let timer = Task { await read.monitor() }
          defer {
            timer.cancel()
            read.finish()
          }
          let deliver: @Sendable (Data, Bool) async throws -> Void = { [weak self] data, isFinal in
            guard let self else { throw CancellationError() }
            read.setReading(false)
            defer { read.setReading(true) }
            try await self.send(data, id: id, isFinal: isFinal)
          }
          let (bytes, response) = try await session.bytes(for: transportRequest, delegate: read)
          defer { bytes.task.cancel() }
          try Task.checkCancellation()
          guard let plan = try await self?.response(response, request: request, id: id) else {
            throw CancellationError()
          }
          status = plan.status
          if attempt == 0 {
            self?.noteTransfer(
              id, token: token, status: plan.status, expected: plan.bodyLength, terminal: .streaming
            )
            if plan.status != 200 && plan.status != 206 {
              await self?.recordFailure(
                id, context: source.diagnostic, status: plan.status, bytes: 0,
                error: PlaybackProblem.httpStatus(plan.status))
            }
            try await deliver(plan.header, plan.noBody || plan.bodyLength == 0)
            if source.progressiveTranscode, plan.lengthlessMP3, !plan.noBody,
              request.range == nil || request.range == "bytes=0-"
            {
              body.prefix = SHA256()
            }
          } else {
            guard plan.status == 200 else { throw PlaybackProblem.httpStatus(plan.status) }
            guard plan.lengthlessMP3 else { throw ClientError.invalidResponse }
          }
          if !plan.noBody {
            do {
              try await body.forward(bytes, plan: plan, replaying: attempt == 1, deliver: deliver) {
                [weak self] received, delivered, verified in
                self?.noteTransfer(
                  id, token: token, received: received, delivered: delivered,
                  recovery: verified ? .resumed : nil)
              }
            } catch let failure as MediaBridgeBody.ReadFailure {
              guard !read.finish(), attempt == 0, failure.cause.code == .networkConnectionLost,
                body.prefix != nil, body.delivered > 0
              else { throw failure.cause }
              transportRequest.setValue(nil, forHTTPHeaderField: "Range")
              self?.noteTransfer(id, token: token, recovery: .verifying)
              continue
            }
            if read.finish() { throw URLError(.timedOut) }
            if plan.chunked { try await deliver(Data("0\r\n\r\n".utf8), true) }
          }
          self?.noteTransfer(
            id, token: token, received: body.received, delivered: body.delivered,
            terminal: plan.status == 200 || plan.status == 206 ? .completed : .failed)
          break
        }
        await self?.close(id)
      } catch {
        let error: any Error = deadline?.timedOut == true ? URLError(.timedOut) : error
        self?.noteTransfer(
          id, token: token, status: status, received: body.received, delivered: body.delivered,
          terminal: Task.isCancelled || error is CancellationError
            || (error as? URLError)?.code == .cancelled ? .cancelled : .failed)
        await self?.recordFailure(
          id, context: source.diagnostic, status: status, bytes: Int(clamping: body.received),
          error: error)
        await self?.close(id, aborting: true)
      }
    }
    job.task = task
    let accepted = catalog.withLock { state in
      guard !state.stopped, let token = job.token, state.sources[token] != nil else { return false }
      state.workers[id] = Worker(token: token, task: task)
      return true
    }
    if !accepted {
      task.cancel()
      close(id)
    }
  }
  private func recordFailure(
    _ id: UUID, context: DiagnosticContext?, status: Int?, bytes: Int, error: any Error
  ) {
    guard let token = jobs[id]?.token else { return }
    let emission = try? withLiveCapability(token) {
      context?.prepareEvent(.network) {
        let rejection = error as? MediaBridgeResponse.Rejection
        return .init(
          .bridge, .failed, http: rejection?.status ?? status,
          code: rejection != nil
            ? DiagnosticCode(ClientError.invalidResponse) : DiagnosticCode(error),
          bytes: bytes, source: .httpBridge, responseRejection: rejection?.reason)
      }
    }
    if let record = emission?.record {
      noteTransfer(
        id, token: token, status: record.facts.http,
        rejection: record.facts.responseRejection, code: record.facts.code)
    }
    emission?.publish()
  }
  private func response(_ response: URLResponse, request: MediaBridgeRequest, id: UUID) throws
    -> MediaBridgeResponse
  {
    guard let token = jobs[id]?.token else { throw CancellationError() }
    return try withLiveCapability(token) {
      guard let response = response as? HTTPURLResponse else {
        throw MediaBridgeResponse.Rejection(status: nil, reason: .nonHTTP)
      }
      return try MediaBridgeResponse(response, request: request)
    }
  }
  private func send(_ data: Data, id: UUID, isFinal: Bool) async throws {
    guard live(id), let job = jobs[id] else { throw CancellationError() }
    if isFinal { job.finalWriteStarted = true }
    maximumChunk = max(maximumChunk, data.count)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      do {
        guard let token = job.token else { throw CancellationError() }
        try withLiveCapability(token) {
          job.connection.send(
            content: data,
            completion: .contentProcessed { error in
              if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
      } catch { continuation.resume(throwing: error) }
    }
    guard live(id), jobs[id] === job else { throw CancellationError() }
  }
  nonisolated func withLiveCapability<T>(_ token: String, _ body: () throws -> T) throws -> T {
    try catalog.withLock { state in
      guard !state.stopped, state.sources[token] != nil else { throw CancellationError() }
      return try body()
    }
  }
  private func releaseListenerSlot() {
    guard !stopped, let listener else { return }
    listener.newConnectionLimit += 1
  }
  private func close(_ id: UUID, aborting: Bool = false) {
    guard let job = jobs.removeValue(forKey: id) else { return }
    if let token = job.token {
      catalog.withLock { state in
        guard let terminal = state.sources[token]?.transfers[id]?.evidence.state,
          terminal == .requesting || terminal == .streaming
        else { return }
        state.sources[token]?.transfers[id]?.evidence.state = aborting ? .failed : .cancelled
      }
    }
    _ = catalog.withLock { $0.workers.removeValue(forKey: id) }
    job.deadline?.cancel()
    job.task?.cancel()
    job.connection.stateUpdateHandler = nil
    if aborting { job.connection.forceCancel() } else { job.connection.cancel() }
    releaseListenerSlot()
  }
}
