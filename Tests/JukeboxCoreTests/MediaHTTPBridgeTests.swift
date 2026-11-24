import AVFoundation
import Darwin
import Foundation
import Network
import Synchronization
import XCTest

@testable import JukeboxCore

private final class BridgeFixturePayload: Sendable {}

private final class BridgeFixtureHold: @unchecked Sendable {
  let id = UUID()
  let owner: UUID
  private let lock = NSLock()
  private var terminal = false
  private var cancelled = false
  private var completion: (@Sendable () -> Void)?
  init(owner: UUID) { self.owner = owner }
  func register(_ completion: @escaping @Sendable () -> Void) -> Bool {
    lock.withLock {
      guard !terminal, self.completion == nil else { return false }
      self.completion = completion
      return true
    }
  }
  var isHeld: Bool { lock.withLock { completion != nil && !terminal } }
  func release() {
    let current = lock.withLock {
      terminal = true
      let current = completion
      completion = nil
      return current
    }
    current?()
  }
  @discardableResult func cancel() -> Bool {
    lock.withLock {
      let fresh = !cancelled
      cancelled = true
      terminal = true
      completion = nil
      return fresh
    }
  }
}
private final class BridgeFixtureState: @unchecked Sendable {
  enum Mode: Sendable {
    case normal, ignoredRange, malformedRange, truncated, redirect, held, prefixHeld, nonHTTP,
      prefixFailure
  }
  struct Value: Sendable {
    let url: URL
    let data: Data
    let mime: String
    let ranged: Bool
    var mode: Mode = .normal
    var status = 200
    var authorization: String?
    var secondBody: Data?
  }
  private let lock = NSLock()
  private var value: Value?
  private var valuesByURL: [URL: Value] = [:]
  private var requestsByURL: [URL: Int] = [:]
  private var eof = false
  private var failureReleased = false
  private var requests = 0
  private var cancellations = 0
  private var unexpected = 0
  private var generation = UUID()
  private var holds: [UUID: BridgeFixtureHold] = [:]
  func reset(_ value: Value) { reset([value]) }
  func reset(_ values: [Value]) {
    precondition(!values.isEmpty && Set(values.map(\.url)).count == values.count)
    lock.lock()
    let retired = Array(holds.values)
    holds = [:]
    generation = UUID()
    self.value = values.first
    valuesByURL = Dictionary(uniqueKeysWithValues: values.map { ($0.url, $0) })
    requestsByURL = [:]
    eof = false
    failureReleased = false
    requests = 0
    cancellations = 0
    unexpected = 0
    lock.unlock()
    for hold in retired { hold.cancel() }
  }
  var owner: UUID { lock.withLock { generation } }
  func begin(_ url: URL?) -> (Value, BridgeFixtureHold) {
    lock.lock()
    defer { lock.unlock() }
    requests += 1
    var selected = url.flatMap { valuesByURL[$0] } ?? value!
    if let body = selected.secondBody, requestsByURL[selected.url, default: 0] == 1 {
      selected = Value(url: selected.url, data: body, mime: selected.mime, ranged: selected.ranged)
    }
    if url != selected.url { unexpected += 1 }
    if let url, valuesByURL[url] != nil { requestsByURL[url, default: 0] += 1 }
    let hold = BridgeFixtureHold(owner: generation)
    if selected.mode == .prefixHeld || selected.mode == .prefixFailure { holds[hold.id] = hold }
    return (selected, hold)
  }
  func count(for url: URL) -> Int { lock.withLock { requestsByURL[url, default: 0] } }
  func releaseHeldCompletion(_ owner: UUID) {
    let current = lock.withLock {
      let current = holds.values.filter { $0.owner == owner }
      if owner == generation, value?.mode == .prefixFailure { failureReleased = true }
      for hold in current { holds.removeValue(forKey: hold.id) }
      return current
    }
    for hold in current { hold.release() }
  }
  func releasedFailure(_ owner: UUID) -> Bool {
    lock.withLock { owner == generation && failureReleased }
  }
  func hasHeldCompletion(_ owner: UUID) -> Bool {
    let current = lock.withLock { holds.values.filter { $0.owner == owner } }
    return current.contains { $0.isHeld }
  }
  func finish(_ hold: BridgeFixtureHold) {
    lock.withLock {
      guard hold.owner == generation else { return }
      holds.removeValue(forKey: hold.id)
      eof = true
    }
  }
  func cancel(_ hold: BridgeFixtureHold) {
    let fresh = hold.cancel()
    lock.withLock {
      guard hold.owner == generation else { return }
      holds.removeValue(forKey: hold.id)
      if fresh { cancellations += 1 }
    }
  }
  var unexpectedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return unexpected
  }
  var cancelledCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancellations
  }
  var ended: Bool {
    lock.lock()
    defer { lock.unlock() }
    return eof
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}
private final class BridgeFixtureProtocol: URLProtocol, @unchecked Sendable {
  static let state = BridgeFixtureState()
  private let lock = NSLock()
  private var stopped = false
  private var hold: BridgeFixtureHold?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {
    lock.lock()
    stopped = true
    let owned = hold
    lock.unlock()
    if let owned { Self.state.cancel(owned) }
  }
  private var cancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
  override func startLoading() {
    let (value, hold) = Self.state.begin(request.url)
    let accepted = lock.withLock {
      guard !stopped else { return false }
      self.hold = hold
      return true
    }
    guard accepted else {
      Self.state.cancel(hold)
      return
    }
    guard request.url == value.url,
      value.authorization == nil
        || request.value(forHTTPHeaderField: "Authorization") == value.authorization
    else {
      client?.urlProtocol(self, didFailWithError: ClientError.forbidden)
      return
    }
    if value.mode == .redirect {
      let response = HTTPURLResponse(
        url: value.url, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": "http://denied.invalid/audio"])!
      client?.urlProtocol(
        self, wasRedirectedTo: URLRequest(url: URL(string: "http://denied.invalid/audio")!),
        redirectResponse: response)
      return
    }
    if value.mode == .held { Thread.sleep(forTimeInterval: 1) }
    guard !cancelled else { return }
    var status = value.status
    var data = value.data
    var headers = ["Content-Type": value.mime]
    if value.ranged {
      if value.mode != .ignoredRange, let raw = request.value(forHTTPHeaderField: "Range"),
        let range = try? MediaBridgeRange(raw)
      {
        let first = Int(range.start ?? max(0, Int64(data.count) - range.end!))
        let last = Int(
          min(
            range.start == nil ? Int64(data.count - 1) : range.end ?? Int64(data.count - 1),
            Int64(data.count - 1)))
        guard first <= last else {
          client?.urlProtocol(self, didFailWithError: ClientError.invalidResponse)
          return
        }
        headers["Content-Range"] = "bytes \(first)-\(last)/\(data.count)"
        data = data.subdata(in: first..<(last + 1))
        status = 206
      }
      headers["Content-Length"] = String(data.count)
      if value.mode != .ignoredRange { headers["Accept-Ranges"] = "bytes" }
      if value.mode == .malformedRange {
        headers["Content-Range"] = "bytes 1-8/100"
        status = 206
      }
      if value.mode == .truncated, data.count > 2 { data = Data(data.prefix(data.count / 2)) }
    }
    let response: URLResponse =
      value.mode == .nonHTTP
      ? URLResponse(
        url: value.url, mimeType: value.mime, expectedContentLength: data.count,
        textEncodingName: nil)
      : HTTPURLResponse(
        url: value.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let payload = request.httpMethod == "HEAD" ? Data() : data
    DispatchQueue.global().async {
      if value.mode == .prefixFailure {
        self.client?.urlProtocol(self, didLoad: Data(payload.prefix(65_536)))
        let fail: @Sendable () -> Void = { [self] in
          guard !cancelled else { return }
          Self.state.cancel(hold)
          client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
        if Self.state.releasedFailure(hold.owner) {
          fail()
        } else if !hold.register(fail), Self.state.releasedFailure(hold.owner) {
          fail()
        }
        return
      }
      if value.mode == .prefixHeld {
        self.client?.urlProtocol(self, didLoad: Data(payload.prefix(1024)))
        _ = hold.register { [self] in
          guard !cancelled else { return }
          client?.urlProtocol(self, didLoad: Data(payload.dropFirst(1024)))
          Self.state.finish(hold)
          client?.urlProtocolDidFinishLoading(self)
        }
        return
      }
      if !value.ranged {
        self.client?.urlProtocol(self, didLoad: Data(payload.prefix(65_536)))
        Thread.sleep(forTimeInterval: 3)
        guard !self.cancelled else { return }
        self.client?.urlProtocol(self, didLoad: Data(payload.dropFirst(65_536)))
      } else {
        self.client?.urlProtocol(self, didLoad: payload)
      }
      guard !self.cancelled else { return }
      Self.state.finish(hold)
      self.client?.urlProtocolDidFinishLoading(self)
    }
  }
}
@MainActor private final class BridgeWireServer {
  private let listener: NWListener
  private let response: Data
  private let pauseAt: Int?
  private let pauseFor: Double
  private let partialByteAfter: Double?
  private var connections: [NWConnection] = []
  private(set) var receivedRanges: [String?] = []
  private var startup: CheckedContinuation<URL, Error>?
  private var deadline: Task<Void, Never>?
  init(
    _ response: Data, pauseAt: Int? = nil, pauseFor: Double = 0,
    partialByteAfter: Double? = nil
  ) throws {
    self.response = response
    self.pauseAt = pauseAt
    self.pauseFor = pauseFor
    self.partialByteAfter = partialByteAfter
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    parameters.requiredInterfaceType = .loopback
    listener = try NWListener(using: parameters)
  }
  func start() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      startup = continuation
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in self?.state(state) }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in self?.accept(connection) }
      }
      deadline = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        self?.stop()
      }
      listener.start(queue: .global())
    }
  }
  private func state(_ state: NWListener.State) {
    guard let startup else { return }
    if case .ready = state, let port = listener.port {
      self.startup = nil
      deadline?.cancel()
      startup.resume(returning: URL(string: "http://127.0.0.1:\(port)/invented")!)
    } else if case .failed(let error) = state {
      self.startup = nil
      deadline?.cancel()
      startup.resume(throwing: error)
    }
  }
  private func accept(_ connection: NWConnection) {
    connections.append(connection)
    connection.start(queue: .global())
    read(connection, bytes: Data())
  }
  private func read(_ connection: NWConnection, bytes: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
      [weak self] data, _, ended, error in
      Task { @MainActor in
        guard let self else { return }
        let bytes = bytes + (data ?? Data())
        if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
          let range = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
          if self.receivedRanges.count < 8 { self.receivedRanges.append(range) }
          if let split = self.pauseAt {
            let rest = Data(self.response.dropFirst(split))
            let delay = self.pauseFor
            let partialByteAfter = self.partialByteAfter
            connection.send(
              content: Data(self.response.prefix(split)),
              completion: .contentProcessed { error in
                guard error == nil else {
                  connection.cancel()
                  return
                }
                if let partialByteAfter {
                  DispatchQueue.global().asyncAfter(deadline: .now() + partialByteAfter) {
                    guard case .ready = connection.state, !rest.isEmpty else { return }
                    connection.send(
                      content: Data(rest.prefix(1)),
                      completion: .contentProcessed { error in
                        guard error == nil else {
                          connection.cancel()
                          return
                        }
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                          guard case .ready = connection.state else { return }
                          connection.send(
                            content: Data(rest.dropFirst()),
                            completion: .contentProcessed { _ in
                              connection.cancel()
                            })
                        }
                      })
                  }
                } else {
                  DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    guard case .ready = connection.state else { return }
                    connection.send(
                      content: rest, completion: .contentProcessed { _ in connection.cancel() })
                  }
                }
              })
          } else {
            connection.send(
              content: self.response, completion: .contentProcessed { _ in connection.cancel() })
          }
        } else if error != nil || ended || bytes.count > 16_384 {
          connection.cancel()
        } else {
          self.read(connection, bytes: bytes)
        }
      }
    }
  }
  func stop() {
    deadline?.cancel()
    listener.stateUpdateHandler = nil
    listener.newConnectionHandler = nil
    listener.cancel()
    for connection in connections { connection.cancel() }
    connections.removeAll()
    let startup = self.startup
    self.startup = nil
    startup?.resume(throwing: CancellationError())
  }
}
@MainActor private final class BridgeRawClient {
  private let connection: NWConnection
  private var continuation: CheckedContinuation<Data, Never>?
  private var output = Data()
  private var timer: Task<Void, Never>?
  private var input = Data()
  private var reading = true
  private var stopAfterBodyBytes: Int?
  init(port: UInt16) {
    connection = NWConnection(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
  }
  func run(_ request: String, reading: Bool = true, stopAfterBodyBytes: Int? = nil) async -> Data {
    self.reading = reading
    self.stopAfterBodyBytes = stopAfterBodyBytes
    input = Data(request.utf8)
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
      connection.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in self?.state(state) }
      }
      timer = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        self?.finish()
      }
      connection.start(queue: .global())
    }
  }
  private func state(_ state: NWConnection.State) {
    if case .ready = state {
      connection.send(
        content: input,
        completion: .contentProcessed { [weak self] error in
          Task { @MainActor in
            if error == nil { if self?.reading == true { self?.read() } } else { self?.finish() }
          }
        })
    } else if case .failed = state {
      finish()
    } else if case .cancelled = state {
      finish()
    }
  }
  private func read() {
    guard continuation != nil else { return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
      [weak self] data, _, end, error in
      Task { @MainActor in
        guard let self, self.continuation != nil else { return }
        if let data { self.output.append(data) }
        let hasPrefix =
          self.stopAfterBodyBytes.map { count in
            self.output.range(of: Data("\r\n\r\n".utf8)).map {
              self.output.distance(from: $0.upperBound, to: self.output.endIndex) >= count
            } ?? false
          } ?? false
        if end || error != nil || hasPrefix || self.output.count >= 16_384 {
          self.finish()
        } else {
          self.read()
        }
      }
    }
  }
  private func finish() {
    let done = continuation
    continuation = nil
    timer?.cancel()
    connection.stateUpdateHandler = nil
    connection.cancel()
    done?.resume(returning: output)
  }
}

private final class BridgeHeldSocket: Sendable {
  struct Result: Sendable {
    var body = Data()
    var http200 = false
    var eofCount = 0
    var error: Int32?
    var receiveBuffer: Int32 = 0
    var prefixAt: Double?
    var endedAt = 0.0
  }
  private struct State: Sendable {
    var socket: Int32 = -1
    var cancelled = false
    var held = false
    var released = false
  }
  private let state = Mutex(State())
  var held: Bool { state.withLock { $0.held } }
  func release() { state.withLock { $0.released = true } }
  func cancel() {
    state.withLock {
      $0.cancelled = true
      if $0.socket >= 0 { _ = Darwin.shutdown($0.socket, SHUT_RDWR) }
    }
  }
  func read(_ url: URL, holding: Bool) async -> Result {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: self.blockingRead(url, holding: holding))
      }
    }
  }
  private func blockingRead(_ url: URL, holding: Bool) -> Result {
    var result = Result()
    var wire = Data()
    var fd: Int32 = -1
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    defer {
      state.withLock { if $0.socket == fd { $0.socket = -1 } }
      if fd >= 0 { _ = Darwin.close(fd) }
    }
    do {
      guard url.scheme == "http", url.host == "127.0.0.1", let rawPort = url.port,
        let port = UInt16(exactly: rawPort), url.query == nil
      else { throw URLError(.badURL) }
      fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
      guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      try state.withLock {
        guard !$0.cancelled else { throw CancellationError() }
        $0.socket = fd
      }
      var buffer: Int32 = 16_384
      var noSigpipe: Int32 = 1
      guard
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size)) == 0,
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
          == 0
      else { throw POSIXError(.EIO) }
      var length = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, &length) == 0 else {
        throw POSIXError(.EIO)
      }
      result.receiveBuffer = buffer
      let flags = fcntl(fd, F_GETFL, 0)
      guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
      func ready(_ events: Int16) throws {
        while true {
          guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
          guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
          var descriptor = pollfd(fd: fd, events: events, revents: 0)
          let count = Darwin.poll(&descriptor, 1, 20)
          if count > 0 { return }
          if count < 0, errno != EINTR { throw POSIXError(.EIO) }
        }
      }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
      let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      if connected < 0 {
        guard errno == EINPROGRESS else { throw POSIXError(.EIO) }
        try ready(Int16(POLLOUT))
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
          throw POSIXError(.EIO)
        }
      }
      let request = Data(
        "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n".utf8)
      var sent = 0
      while sent < request.count {
        try ready(Int16(POLLOUT))
        let count = request.withUnsafeBytes {
          Darwin.send(fd, $0.baseAddress!.advanced(by: sent), request.count - sent, 0)
        }
        if count > 0 {
          sent += count
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
          throw POSIXError(.EIO)
        }
      }
      var bytes = [UInt8](repeating: 0, count: 16_384)
      var heldOnce = false
      while true {
        try ready(Int16(POLLIN))
        let count = bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
        if count > 0 {
          wire.append(contentsOf: bytes.prefix(count))
          guard wire.count <= 8 * 1024 * 1024 + 16_384 else {
            throw URLError(.dataLengthExceedsMaximum)
          }
          if let header = wire.range(of: Data("\r\n\r\n".utf8)),
            wire.count - header.upperBound >= 65_536
          {
            if result.prefixAt == nil { result.prefixAt = ProcessInfo.processInfo.systemUptime }
            if holding && !heldOnce {
              heldOnce = true
              state.withLock { $0.held = true }
              while !state.withLock({ $0.released }) {
                guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                  throw URLError(.timedOut)
                }
                Thread.sleep(forTimeInterval: 0.005)
              }
            }
          }
        } else if count == 0 {
          result.eofCount += 1
          break
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
          result.error = errno
          break
        }
      }
    } catch {
      result.error = Int32(clamping: (error as NSError).code)
    }
    if let header = wire.range(of: Data("\r\n\r\n".utf8)) {
      result.http200 = String(decoding: wire[..<header.lowerBound], as: UTF8.self).hasPrefix(
        "HTTP/1.1 200 ")
      result.body = Data(wire[header.upperBound...])
    }
    result.endedAt = ProcessInfo.processInfo.systemUptime
    return result
  }
}

@MainActor private final class BridgeMixedQueueEvents {
  var ended: [Int] = []
  var endDurations: [Int: Double] = [:]
  var failed: [Int] = []
  var seeks: [Int: (completed: Bool, clock: Double)] = [:]
}

@MainActor final class MediaHTTPBridgeTests: XCTestCase {
  private func fixture(_ type: String, ranged: Bool, mode: BridgeFixtureState.Mode = .normal) throws
    -> MediaSource
  {
    let data = try Data(
      contentsOf: Bundle.module.url(
        forResource: "bridge", withExtension: type, subdirectory: "Fixtures")!)
    let source = MediaSource(
      url: URL(
        string: "http://fixture.invalid/Audio/invented/stream?api_key=invented&quality=original")!,
      quality: .original)
    BridgeFixtureProtocol.state.reset(
      .init(
        url: source.url, data: data,
        mime: ["wav": "audio/wav", "mp3": "audio/mpeg", "flac": "audio/flac"][type]!,
        ranged: ranged, mode: mode
      ))
    return source
  }
  private func client() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    configuration.timeoutIntervalForResource = 3
    return URLSession(configuration: configuration)
  }
  private func wait(_ condition: () async -> Bool) async throws {
    for _ in 0..<100 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("bounded bridge premise timed out")
  }
  func testAuthenticatedHTTPSRangesUseHeadersAndAnOpaquePlayerURL() async throws {
    let upstream = try XCTUnwrap(URL(string: "https://fixture.invalid/music/Audio/song/stream"))
    let source = MediaSource(url: upstream, quality: .original, authorization: "invented-header")
    let bytes = Data((0..<128).map(UInt8.init))
    BridgeFixtureProtocol.state.reset(
      .init(
        url: upstream, data: bytes, mime: "audio/wav", ranged: true,
        authorization: "invented-header"))
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    defer { bridge.stop() }
    let local = try bridge.register(source)
    XCTAssertEqual(local.host, "127.0.0.1")
    XCTAssertNil(local.query)
    XCTAssertFalse(local.absoluteString.contains("invented"))
    let session = client()
    defer { session.invalidateAndCancel() }
    var read = URLRequest(url: local)
    read.setValue("bytes=16-31", forHTTPHeaderField: "Range")
    let (data, response) = try await session.data(for: read)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
    XCTAssertEqual(data, bytes[16..<32])
  }
  func testBridgePrivacyAndRetirementStopLateRequests() async throws {
    let recorder = DiagnosticRecorder()
    let context = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.play))
    let source = try fixture("wav", ranged: true)
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    defer { bridge.stop() }
    let url = try bridge.register(source, diagnostic: context)
    let consumer = client()
    defer { consumer.invalidateAndCancel() }
    let (data, response) = try await consumer.data(from: url)
    XCTAssertFalse(data.isEmpty)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let output = recorder.records.map(\.line).joined()
    XCTAssertFalse(output.contains("fixture.invalid"))
    XCTAssertFalse(output.contains("api_key"))
    XCTAssertFalse(output.contains(url.path))
    bridge.retire(url)
    var getters = 0
    let rejected = bridge.withEvidence(for: url, at: 0) { _ in
      getters += 1
      return true
    }
    XCTAssertNil(rejected)
    XCTAssertEqual(getters, 0, "Retired capabilities reject before evidence getters")
    let count = recorder.records.count
    do { _ = try await consumer.data(from: url) } catch {}
    XCTAssertEqual(recorder.records.count, count)
  }
  func testBridgeKeepsBoundedRangeAndBodyEvidenceUntilExactSourceRetirement() async throws {
    let source = try fixture("wav", ranged: true)
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    defer { bridge.stop() }
    let url = try bridge.register(source)
    let consumer = client()
    defer { consumer.invalidateAndCancel() }
    for index in 0..<6 {
      var request = URLRequest(url: url)
      request.setValue("bytes=\(index * 16)-\(index * 16 + 15)", forHTTPHeaderField: "Range")
      let (data, response) = try await consumer.data(for: request)
      XCTAssertEqual(data.count, 16)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
    }
    try await wait { await bridge.activeCount == 0 }
    let evidence = bridge.evidence(for: url, at: ProcessInfo.processInfo.systemUptime)
    XCTAssertEqual(evidence.map(\.ordinal), [3, 4, 5, 6])
    XCTAssertEqual(evidence.last?.rangeStart, 80)
    XCTAssertEqual(evidence.last?.rangeEnd, 95)
    XCTAssertTrue(evidence.allSatisfy { $0.status == 206 && $0.expected == 16 })
    XCTAssertTrue(evidence.allSatisfy { $0.received == 16 && $0.delivered == 16 })
    XCTAssertTrue(evidence.allSatisfy { $0.state == .completed && $0.lastByteAge != nil })
    let output = evidence.map(\.fields).joined()
    for forbidden in ["fixture.invalid", "api_key", "invented", url.path] {
      XCTAssertFalse(output.contains(forbidden))
    }
    bridge.retire(url)
    XCTAssertTrue(bridge.evidence(for: url, at: ProcessInfo.processInfo.systemUptime).isEmpty)
  }
  func testHTTPErrorStatusesRemainVisibleWithoutCopyingTheirBodyOrURL() async throws {
    for status in [401, 403, 404, 503] {
      let source = try fixture("mp3", ranged: false)
      BridgeFixtureProtocol.state.reset(
        .init(
          url: source.url, data: Data("private-error-body".utf8), mime: "text/html",
          ranged: false, status: status))
      let recorder = DiagnosticRecorder()
      let context = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.play))
      let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
      try await bridge.start()
      defer { bridge.stop() }
      let url = try bridge.register(source, diagnostic: context)
      let consumer = client()
      defer { consumer.invalidateAndCancel() }
      let (body, response) = try await consumer.data(from: url)
      XCTAssertTrue(body.isEmpty)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
      let failures = recorder.records.filter { $0.facts.outcome == .failed }
      XCTAssertEqual(failures.count, 1)
      XCTAssertEqual(failures.first?.facts.http, status)
      XCTAssertFalse(failures.map(\.line).joined().contains("private-error-body"))
      XCTAssertFalse(failures.map(\.line).joined().contains("fixture.invalid"))
    }
  }
  func testRejectedUpstreamResponseRetainsStatusAndFixedReasonBeforeAnyDownstreamHeaders()
    async throws
  {
    let source = try fixture("mp3", ranged: true)
    BridgeFixtureProtocol.state.reset(
      .init(
        url: source.url, data: Data("invented non-audio body".utf8), mime: "text/html", ranged: true
      ))
    let recorder = DiagnosticRecorder()
    let context = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.play))
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    defer { bridge.stop() }
    let url = try bridge.register(source, diagnostic: context)
    let port = try XCTUnwrap(bridge.port)
    let downstream = await BridgeRawClient(port: port).run(
      "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
    XCTAssertTrue(downstream.isEmpty)
    let failure = try XCTUnwrap(recorder.records.last { $0.facts.outcome == .failed })
    XCTAssertEqual(failure.scope, .intent)
    XCTAssertEqual(failure.facts.code, DiagnosticCode(domain: .client, value: 2))
    XCTAssertEqual(failure.facts.code, DiagnosticCode(ClientError.invalidResponse))
    XCTAssertEqual(failure.facts.bytes, 0)
    XCTAssertEqual(failure.facts.http, 200)
    XCTAssertEqual(failure.facts.responseRejection, .contentType)
    XCTAssertTrue(failure.line.contains("responseRejection=contentType http=200"))
    XCTAssertFalse(failure.line.contains("text/html"))
    XCTAssertFalse(failure.line.contains("fixture.invalid"))
    XCTAssertFalse(failure.line.contains("invented non-audio body"))
    XCTAssertEqual(BridgeFixtureProtocol.state.count, 1)
    try await wait { await bridge.activeCount == 0 }
    let evidence = bridge.evidence(for: url, at: ProcessInfo.processInfo.systemUptime)
    XCTAssertEqual(evidence.last?.status, 200)
    XCTAssertEqual(evidence.last?.rejection, .contentType)
  }
  func testNonHTTPResponseRejectionDoesNotInventHTTPStatus() async throws {
    let source = try fixture("mp3", ranged: true, mode: .nonHTTP)
    let recorder = DiagnosticRecorder()
    let context = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.play))
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    defer { bridge.stop() }
    let url = try bridge.register(source, diagnostic: context)
    let port = try XCTUnwrap(bridge.port)
    let downstream = await BridgeRawClient(port: port).run(
      "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
    XCTAssertTrue(downstream.isEmpty)
    let failure = try XCTUnwrap(recorder.records.last { $0.facts.outcome == .failed })
    XCTAssertEqual(failure.facts.code, DiagnosticCode(domain: .client, value: 2))
    XCTAssertNil(failure.facts.http)
    XCTAssertEqual(failure.facts.responseRejection, .nonHTTP)
  }
  func testActualURLSessionDecodesGzipButBridgeRetainsStrictRejectionAndSafeStatus() async throws {
    let body = Data("invented audio payload".utf8)
    let gzip = try XCTUnwrap(
      Data(base64Encoded: "H4sIAAAAAAAA/8vMK0vNK0lNUUgsTcnMVyhIrMzJT0wBAA1qaUIWAAAA"))
    let header =
      "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Encoding: gzip\r\nContent-Length: \(gzip.count)\r\nConnection: close\r\n\r\n"
    let server = try BridgeWireServer(Data(header.utf8) + gzip)
    let upstream = try await server.start()
    defer { server.stop() }
    let consumer = client()
    defer { consumer.invalidateAndCancel() }
    var request = URLRequest(url: upstream)
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let (stream, observed) = try await consumer.bytes(for: request)
    var decoded = Data()
    for try await byte in stream { decoded.append(byte) }
    XCTAssertEqual(decoded, body)
    let response = try XCTUnwrap(observed as? HTTPURLResponse)
    XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
    XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), String(gzip.count))
    let recorder = DiagnosticRecorder()
    let context = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.play))
    let bridge = MediaHTTPBridge()
    try await bridge.start()
    defer { bridge.stop() }
    let source = MediaSource(url: upstream, quality: .compact)
    let downstream = try bridge.register(source, diagnostic: context)
    let port = try XCTUnwrap(bridge.port)
    let output = await BridgeRawClient(port: port).run(
      "GET \(downstream.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
    XCTAssertTrue(output.isEmpty, "Encoded audio remains rejected before downstream publication")
    let failure = try XCTUnwrap(recorder.records.last { $0.facts.outcome == .failed })
    XCTAssertEqual(failure.facts.http, 200)
    XCTAssertEqual(failure.facts.responseRejection, .contentEncoding)
    XCTAssertEqual(failure.facts.code, DiagnosticCode(domain: .client, value: 2))
    XCTAssertEqual(failure.facts.bytes, 0)
    XCTAssertFalse(failure.line.contains(upstream.absoluteString))
    XCTAssertFalse(failure.line.contains("gzip"))
  }
  func testActualChunkedURLSessionBodyKeepsExactAcceptedBridgeBytes() async throws {
    let body = Data("invented chunked audio".utf8)
    let header =
      "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
    let framed =
      Data((String(body.count, radix: 16) + "\r\n").utf8) + body + Data("\r\n0\r\n\r\n".utf8)
    let server = try BridgeWireServer(Data(header.utf8) + framed)
    let upstream = try await server.start()
    defer { server.stop() }
    let recorder = DiagnosticRecorder()
    let context = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.play))
    let bridge = MediaHTTPBridge()
    try await bridge.start()
    defer { bridge.stop() }
    let source = MediaSource(url: upstream, quality: .compact)
    let consumer = client()
    defer { consumer.invalidateAndCancel() }
    let (direct, upstreamResponse) = try await consumer.data(from: upstream)
    XCTAssertEqual(direct, body)
    let observed = try XCTUnwrap(upstreamResponse as? HTTPURLResponse)
    let transfer = observed.value(forHTTPHeaderField: "Transfer-Encoding")?.lowercased()
    XCTAssertTrue(transfer == nil || transfer == "chunked" || transfer == "identity")
    XCTAssertNil(observed.value(forHTTPHeaderField: "Content-Length"))
    let decoded: Data
    let response: URLResponse
    do {
      (decoded, response) = try await consumer.data(
        from: bridge.register(source, diagnostic: context))
    } catch {
      XCTFail(recorder.records.map { $0.facts.fields }.joined(separator: "\n"))
      throw error
    }
    XCTAssertEqual(decoded, body)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

  }
  func testActualFixedLengthOriginalResponsePreservesExactBytes() async throws {
    try await assertActualOriginalResponse(partial: false)
  }
  func testActualOriginalRangeResponsePreservesExactSeekBytes() async throws {
    try await assertActualOriginalResponse(partial: true)
  }
  private func assertActualOriginalResponse(partial: Bool) async throws {
    let full = try Data(
      contentsOf: XCTUnwrap(
        Bundle.module.url(forResource: "bridge", withExtension: "flac", subdirectory: "Fixtures")))
    XCTAssertGreaterThan(full.count, 32_768)
    let range = partial ? "bytes=16384-32767" : nil
    let body = partial ? full.subdata(in: 16_384..<32_768) : full
    let status = partial ? 206 : 200
    let contentRange = partial ? "bytes 16384-32767/\(full.count)" : nil
    let header =
      "HTTP/1.1 \(status) Audio\r\nContent-Type: audio/flac\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\n"
      + (contentRange.map { "Content-Range: \($0)\r\n" } ?? "")
      + "Connection: close\r\n\r\n"
    let server = try BridgeWireServer(Data(header.utf8) + body)
    let upstream = try await server.start()
    defer { server.stop() }
    let consumer = client()
    defer { consumer.invalidateAndCancel() }
    var directRequest = URLRequest(url: upstream)
    if let range { directRequest.setValue(range, forHTTPHeaderField: "Range") }
    let (direct, directResponse) = try await consumer.data(for: directRequest)
    XCTAssertEqual(direct, body)
    let observed = try XCTUnwrap(directResponse as? HTTPURLResponse)
    XCTAssertEqual(observed.statusCode, status)
    XCTAssertEqual(observed.value(forHTTPHeaderField: "Content-Length"), String(body.count))
    XCTAssertEqual(observed.value(forHTTPHeaderField: "Content-Range"), contentRange)
    let transfer = observed.value(forHTTPHeaderField: "Transfer-Encoding")?.lowercased()
    XCTAssertTrue(transfer == nil || transfer == "identity")
    let recorder = DiagnosticRecorder()
    let context = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.play))
    let bridge = MediaHTTPBridge()
    try await bridge.start()
    defer { bridge.stop() }
    var request = URLRequest(
      url: try bridge.register(MediaSource(url: upstream, quality: .original), diagnostic: context))
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    let decoded: Data
    let response: URLResponse
    do {
      (decoded, response) = try await consumer.data(for: request)
    } catch {
      XCTFail(
        "Original \(status) adapted transfer=\(transfer ?? "absent") length=\(body.count)\n"
          + recorder.records.map { $0.facts.fields }.joined(separator: "\n"))
      return
    }
    XCTAssertEqual(decoded, body)
    let adapted = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertEqual(adapted.statusCode, status)
    XCTAssertEqual(adapted.value(forHTTPHeaderField: "Content-Length"), String(body.count))
    XCTAssertEqual(adapted.value(forHTTPHeaderField: "Content-Range"), contentRange)
    XCTAssertGreaterThanOrEqual(server.receivedRanges.count, 2)
    XCTAssertEqual(server.receivedRanges.last ?? nil, range)

  }
  func testResponseValidationReasonsRetainEveryExistingGuard() throws {
    let url = URL(string: "http://fixture.invalid/private?api_key=secret")!
    let request = MediaBridgeRequest(method: "GET", path: "/m/unused", range: "bytes=0-3")
    let cases: [(Int, [String: String], DiagnosticResponseRejection)] = [
      (199, [:], .status),
      (200, ["Content-Encoding": "gzip"], .contentEncoding),
      (206, ["Content-Encoding": "gzip"], .contentEncoding),
      (200, ["Transfer-Encoding": "gzip"], .transferFraming),
      (200, ["Transfer-Encoding": "identity, chunked"], .transferFraming),
      (200, ["Transfer-Encoding": "identity", "Content-Length": "4"], .transferFraming),
      (200, ["Content-Length": "4", "Transfer-Encoding": "chunked"], .transferFraming),
      (200, ["Content-Length": "4,4"], .contentLength),
      (200, ["Content-Length": "-1"], .contentLength),
      (200, ["Content-Length": "9223372036854775808"], .contentLength),
      (200, ["Content-Type": "text/html"], .contentType),
      (206, [:], .contentRange),
      (206, ["Content-Range": "bytes 0-3/*"], .contentRange),
      (206, ["Content-Range": "bytes 1-4/10"], .contentRange),
      (206, ["Content-Range": "bytes 0-3/10", "Content-Length": "3"], .contentRange),
    ]
    for (status, headers, reason) in cases {
      let response = try XCTUnwrap(
        HTTPURLResponse(
          url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
      XCTAssertThrowsError(try MediaBridgeResponse(response, request: request)) { error in
        let failure = error as? MediaBridgeResponse.Rejection
        XCTAssertEqual(failure?.status, status)
        XCTAssertEqual(failure?.reason, reason)
      }
    }
  }
  func testBulkBodyPrefixWaitsForCompletionAndPreservesExactBytes() async throws {
    let source = try fixture("wav", ranged: true, mode: .prefixHeld)
    let owner = BridgeFixtureProtocol.state.owner
    let expected = try Data(
      contentsOf: Bundle.module.url(
        forResource: "bridge", withExtension: "wav", subdirectory: "Fixtures")!)
    XCTAssertGreaterThan(expected.count, 16_384)
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    defer {
      BridgeFixtureProtocol.state.releaseHeldCompletion(owner)
      bridge.stop()
    }
    let url = try bridge.register(source)
    let port = try XCTUnwrap(bridge.port)
    let response = await BridgeRawClient(port: port).run(
      "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n",
      stopAfterBodyBytes: 1024)
    let separator = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)))
    let body = response[separator.upperBound...]
    XCTAssertTrue(BridgeFixtureProtocol.state.hasHeldCompletion(owner))
    XCTAssertFalse(BridgeFixtureProtocol.state.ended)
    XCTAssertEqual(body.count, 0, "The retained bulk policy waits for more bytes or EOF")
    XCTAssertEqual(BridgeFixtureProtocol.state.count, 1)
    BridgeFixtureProtocol.state.releaseHeldCompletion(owner)
    try await wait { await bridge.activeCount == 0 }
    let consumer = client()
    let completed = Task { try await consumer.data(from: url) }
    do {
      try await wait {
        BridgeFixtureProtocol.state.count == 2
          && BridgeFixtureProtocol.state.hasHeldCompletion(owner)
      }
      BridgeFixtureProtocol.state.releaseHeldCompletion(owner)
      let (data, info) = try await completed.value
      XCTAssertEqual((info as? HTTPURLResponse)?.statusCode, 200)
      XCTAssertEqual(data, expected)
      XCTAssertTrue(BridgeFixtureProtocol.state.ended)
      XCTAssertEqual(BridgeFixtureProtocol.state.count, 2)
    } catch {
      completed.cancel()
      consumer.invalidateAndCancel()
      BridgeFixtureProtocol.state.releaseHeldCompletion(owner)
      _ = try? await completed.value
      throw error
    }
    consumer.invalidateAndCancel()
  }
  func testHeldPrefixRegistrationAndRetirementAreRequestOwnedAndTerminal() {
    let state = BridgeFixtureState()
    let url = URL(string: "http://fixture.invalid/owned-prefix")!
    let value = BridgeFixtureState.Value(
      url: url, data: Data(repeating: 1, count: 2048), mime: "audio/wav", ranged: true,
      mode: .prefixHeld)
    let calls = Mutex(0)
    state.reset(value)
    let oldOwner = state.owner
    let (_, beforeRegistration) = state.begin(url)
    state.releaseHeldCompletion(oldOwner)
    XCTAssertFalse(beforeRegistration.register { calls.withLock { $0 += 1 } })
    XCTAssertFalse(beforeRegistration.isHeld)
    let (_, beforeCancel) = state.begin(url)
    state.cancel(beforeCancel)
    XCTAssertFalse(beforeCancel.register { calls.withLock { $0 += 1 } })
    let (_, beforeReset) = state.begin(url)
    weak var payload: BridgeFixturePayload?
    do {
      let retained = BridgeFixturePayload()
      payload = retained
      XCTAssertTrue(
        beforeReset.register { withExtendedLifetime(retained) { calls.withLock { $0 += 100 } } })
    }
    XCTAssertNotNil(payload)
    state.reset(value)
    XCTAssertNil(payload, "Reset must release the retired request's captured payload")
    XCTAssertFalse(beforeReset.register { calls.withLock { $0 += 1 } })
    let currentOwner = state.owner
    XCTAssertNotEqual(currentOwner, oldOwner)
    let (_, current) = state.begin(url)
    XCTAssertTrue(current.register { calls.withLock { $0 += 1 } })
    state.cancel(beforeReset)
    state.finish(beforeReset)
    state.releaseHeldCompletion(oldOwner)
    XCTAssertTrue(
      state.hasHeldCompletion(currentOwner), "Old release/cancel cannot steal current work")
    XCTAssertFalse(state.ended)
    XCTAssertEqual(state.cancelledCount, 0)
    state.releaseHeldCompletion(currentOwner)
    state.releaseHeldCompletion(currentOwner)
    XCTAssertEqual(calls.withLock { $0 }, 1)
    XCTAssertFalse(current.register { calls.withLock { $0 += 1 } })
    XCTAssertFalse(state.hasHeldCompletion(currentOwner))
  }

  func testStrictRequestAndRangeParsing() throws {
    let path = "/m/" + String(repeating: "a", count: 64)
    func input(_ method: String = "GET", _ headers: String = "", _ suffix: String = "") -> Data {
      Data("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:1234\r\n\(headers)\r\n\(suffix)".utf8)
    }
    XCTAssertEqual(
      try MediaBridgeRequest.parse(input("GET", "Range: bytes=2-9\r\n"), port: 1234).range,
      "bytes=2-9")
    for bytes in [
      input("POST"), input("GET", "Origin: http://browser.invalid\r\n"),
      input("GET", "Host: 127.0.0.1:99\r\n"), input("GET", "Content-Length: 1\r\n", "x"),
      input("GET", "Transfer-Encoding: chunked\r\n"), input("GET", "Range: bytes=0-1,2-3\r\n"),
      input("GET", "Range: bytes=1-2\r\nrange: bytes=3-4\r\n"),
      input("GET", "", "GET / HTTP/1.1\r\n\r\n"),
      input("GET", String(repeating: "X: y\r\n", count: 34)), input("GET", "X: y\nz\r\n"),
    ] {
      XCTAssertThrowsError(try MediaBridgeRequest.parse(bytes, port: 1234))
    }
    for value in [
      "bytes=-", "bytes=-0", "bytes=3-2", "bytes=9223372036854775808-", "bytes=0-1,2-3",
      "bytes= 1-2", "items=1-2",
    ] { XCTAssertThrowsError(try MediaBridgeRange(value)) }
    XCTAssertTrue(try MediaBridgeRange("bytes=-3").matches(start: 7, end: 9, total: 10))
  }
  func testResponseFramingRejectsAmbiguityAndNeverForwardsPrivateHeaders() throws {
    let url = URL(string: "http://fixture.invalid/audio")!
    let request = MediaBridgeRequest(method: "GET", path: "/m/unused", range: "bytes=0-3")
    func response(_ fields: [String: String], _ status: Int = 200) -> HTTPURLResponse {
      HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
    }
    let valid = try MediaBridgeResponse(
      response(
        [
          "Content-Type": "audio/mpeg", "Content-Range": "bytes 0-3/10", "Content-Length": "4",
          "Set-Cookie": "secret", "X-Private": "secret",
        ], 206), request: request)
    XCTAssertEqual(valid.bodyLength, 4)
    XCTAssertFalse(String(decoding: valid.header, as: UTF8.self).contains("secret"))
    for fields in [
      ["Content-Length": "4,4"], ["Content-Length": "4", "Transfer-Encoding": "chunked"],
      ["Content-Length": "-1"], ["Content-Type": "text/html"], ["Content-Encoding": "gzip"],
    ] { XCTAssertThrowsError(try MediaBridgeResponse(response(fields), request: request)) }
    XCTAssertThrowsError(
      try MediaBridgeResponse(
        response(
          ["Content-Type": "audio/mpeg", "Content-Range": "bytes 1-4/10", "Content-Length": "4"],
          206), request: request))
    let chunked = try MediaBridgeResponse(
      response(["Content-Type": "audio/mpeg"]), request: request)
    XCTAssertTrue(chunked.chunked)
    XCTAssertNil(chunked.bodyLength)
    XCTAssertEqual(chunked.frame(Data([1, 2])), Data([50, 13, 10, 1, 2, 13, 10]))
    for identity in ["Identity", "identity", "IDENTITY"] {
      let adapted = try MediaBridgeResponse(
        response(["Content-Type": "audio/mpeg", "Transfer-Encoding": identity]), request: request)
      XCTAssertNil(adapted.bodyLength)
      XCTAssertTrue(adapted.chunked)
      XCTAssertEqual(adapted.frame(Data([1, 2])), chunked.frame(Data([1, 2])))
    }
  }
  func testIgnoredRange200AndHEADRemainHonest() async throws {
    let source = try fixture("mp3", ranged: true, mode: .ignoredRange)
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    defer { bridge.stop() }
    let url = try bridge.register(source)
    let client = client()
    defer { client.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
    let (data, response) = try await client.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertGreaterThan(data.count, 4)
    XCTAssertNil((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"))
    request.httpMethod = "HEAD"
    let (head, info) = try await client.data(for: request)
    XCTAssertTrue(head.isEmpty)
    XCTAssertEqual(info.expectedContentLength, Int64(data.count))
  }
  func testUnknownRevokedCapabilityAndStoppedBridgePerformNoUpstreamRequest() async throws {
    let source = try fixture("mp3", ranged: true)
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    let url = try bridge.register(source)
    let client = client()
    defer {
      client.invalidateAndCancel()
      bridge.stop()
    }
    bridge.retire(url)
    do {
      _ = try await client.data(from: url)
      XCTFail("revoked capability must fail")
    } catch {}
    let unknown = URL(
      string: "http://127.0.0.1:\(bridge.port!)/m/" + String(repeating: "0", count: 64))!
    do {
      _ = try await client.data(from: unknown)
      XCTFail("unknown capability must fail")
    } catch {}
    XCTAssertEqual(BridgeFixtureProtocol.state.count, 0)
    bridge.stop()
    XCTAssertThrowsError(try bridge.register(source))
  }
  func testRedirectTargetUntouchedAndMalformedOrTruncatedRangeFails() async throws {
    for mode in [BridgeFixtureState.Mode.redirect, .malformedRange, .truncated] {
      let source = try fixture("mp3", ranged: true, mode: mode)
      let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
      try await bridge.start()
      defer { bridge.stop() }
      let url = try bridge.register(source)
      let port = bridge.port!
      let raw = await BridgeRawClient(port: port).run(
        "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nRange: bytes=0-1023\r\n\r\n")
      if mode == .malformedRange {
        XCTAssertTrue(raw.isEmpty)
      } else if mode == .truncated {
        XCTAssertTrue(raw.starts(with: Data("HTTP/1.1 206".utf8)))
        XCTAssertLessThan(raw.count, 1024)
      } else {
        XCTAssertTrue(raw.isEmpty || raw.starts(with: Data("HTTP/1.1 302".utf8)))
      }
      XCTAssertEqual(BridgeFixtureProtocol.state.count, 1)
      XCTAssertEqual(
        BridgeFixtureProtocol.state.unexpectedCount, 0, "redirect target must remain untouched")
    }
  }
  func testBadHostOriginMethodAndPipelineNeverReachUpstream() async throws {
    let source = try fixture("mp3", ranged: true)
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    defer { bridge.stop() }
    let url = try bridge.register(source)
    let port = bridge.port!
    let requests = [
      "GET \(url.path) HTTP/1.1\r\nHost: other.invalid\r\n\r\n",
      "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: http://browser.invalid\r\n\r\n",
      "POST \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n",
      "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\nGET / HTTP/1.1\r\n\r\n",
    ]
    for request in requests {
      let result = await BridgeRawClient(port: port).run(request)
      XCTAssertTrue(result.isEmpty)
    }
    XCTAssertEqual(BridgeFixtureProtocol.state.count, 0)
  }
  func testRetirementCancelsHeldResponseWithoutLatePublication() async throws {
    let recorder = DiagnosticRecorder()
    let context = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.play))
    let source = try fixture("mp3", ranged: true, mode: .held)
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    let url = try bridge.register(source, diagnostic: context)
    let client = client()
    defer {
      bridge.stop()
      client.invalidateAndCancel()
    }
    let pending = Task { try await client.data(from: url) }
    try await wait { BridgeFixtureProtocol.state.count == 1 }
    bridge.retire(url)
    do {
      _ = try await pending.value
      XCTFail("retired request must not publish")
    } catch {}
    try await wait { BridgeFixtureProtocol.state.cancelledCount > 0 }
    let active = await bridge.activeCount
    XCTAssertEqual(active, 0)
    XCTAssertEqual(BridgeFixtureProtocol.state.count, 1)
    XCTAssertFalse(recorder.records.contains { $0.category == .network })
    var getters = 0
    XCTAssertThrowsError(
      try bridge.withLiveCapability(String(url.path.dropFirst(3))) {
        context.prepareEvent(.network) {
          getters += 1
          return .init(.bridge, .failed, http: 502)
        }
      })
    XCTAssertEqual(getters, 0)
    context.retire(.sourceRetired)
  }
  func testListenerBudgetSupportsTwelveSequentialRequests() async throws {
    let source = try fixture("mp3", ranged: true)
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    defer { bridge.stop() }
    let url = try bridge.register(source)
    let client = client()
    defer { client.invalidateAndCancel() }
    for index in 0..<12 {
      var request = URLRequest(url: url)
      request.httpMethod = index.isMultiple(of: 2) ? "HEAD" : "GET"
      request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
      let (data, info) = try await client.data(for: request)
      XCTAssertEqual((info as? HTTPURLResponse)?.statusCode, 206)
      XCTAssertEqual(data.count, request.httpMethod == "HEAD" ? 0 : 1024)
    }
    XCTAssertEqual(BridgeFixtureProtocol.state.count, 12)
    let peak = await bridge.maximumActive
    XCTAssertLessThanOrEqual(peak, 4)
  }
  func testFourNonreadingConsumersStayBoundedAndStopCancelsAll() async throws {
    let source = try fixture("wav", ranged: true)
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    let url = try bridge.register(source)
    defer { bridge.stop() }
    let port = bridge.port!
    let request = "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
    let consumers = (0..<4).map { _ in
      Task { await BridgeRawClient(port: port).run(request, reading: false) }
    }
    try await wait { await bridge.maximumChunk > 0 }
    bridge.stop()
    for consumer in consumers { _ = await consumer.value }
    try await wait { await bridge.activeCount == 0 }
    let peak = await bridge.maximumActive
    let chunk = await bridge.maximumChunk
    XCTAssertLessThanOrEqual(peak, 4)
    XCTAssertLessThanOrEqual(chunk, 16_400)
    XCTAssertLessThanOrEqual(BridgeFixtureProtocol.state.count, 4)
    XCTAssertThrowsError(try bridge.register(source))
  }
  func testRetirementBeforeHeldPublicationPreventsExtractionOrSendEntry() async throws {
    for stopping in [false, true] {
      let source = try fixture("mp3", ranged: true)
      let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
      try await bridge.start()
      defer { bridge.stop() }
      let url = try bridge.register(source)
      let token = String(url.path.dropFirst(3))
      var entered = 0
      try bridge.withLiveCapability(token) { entered += 1 }
      XCTAssertEqual(entered, 1)
      var release: CheckedContinuation<Void, Never>?
      let pending = Task {
        await withCheckedContinuation { release = $0 }
        return
          (try? bridge.withLiveCapability(token) {
            entered += 1
            return true
          }) ?? false
      }
      while release == nil { await Task.yield() }
      if stopping { bridge.stop() } else { bridge.retire(url) }
      release?.resume()
      let published = await pending.value
      XCTAssertFalse(published)
      XCTAssertEqual(entered, 1, "retired projection/publication closure must never enter")
      XCTAssertEqual(BridgeFixtureProtocol.state.count, 0)
    }
  }
  func testEnteredPublicationMustCompleteBeforeConcurrentRetirement() async throws {
    let source = try fixture("mp3", ranged: true)
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    let token = String(try bridge.register(source).path.dropFirst(3))
    final class Progress: Sendable {
      struct State: Sendable {
        var entered = false
        var attempted = false
        var order: [Int] = []
      }
      let state = Mutex(State())
    }
    let progress = Progress()
    let release = DispatchSemaphore(value: 0)
    defer {
      release.signal()
      bridge.stop()
    }
    let publisher = Task.detached {
      try bridge.withLiveCapability(token) {
        progress.state.withLock { $0.entered = true }
        release.wait()
        progress.state.withLock { $0.order.append(1) }
      }
    }
    try await wait { progress.state.withLock { $0.entered } }
    let retirement = Task.detached {
      progress.state.withLock { $0.attempted = true }
      bridge.stop()
      progress.state.withLock { $0.order.append(2) }
    }
    try await wait { progress.state.withLock { $0.attempted } }
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertFalse(
      progress.state.withLock { $0.order.contains(2) },
      "retirement must not return while accepted publication is still held")
    release.signal()
    try await publisher.value
    await retirement.value
    XCTAssertEqual(progress.state.withLock { $0.order }, [1, 2])
  }

  func testDownstreamBackpressureDoesNotConsumeInputIdleDeadline() async throws {
    let idle = 0.15
    var body = Data(count: 8 * 1024 * 1024)
    body.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
      for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index ^ (index >> 8)) }
    }
    let header = Data(
      "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        .utf8)
    let server = try BridgeWireServer(header + body)
    defer { server.stop() }
    let upstream = try await server.start()
    let bridge = MediaHTTPBridge(idleTimeout: idle)
    defer { bridge.stop() }
    try await bridge.start()
    let context = DiagnosticSession().begin(.play)
    let url = try bridge.register(MediaSource(url: upstream, quality: .high), diagnostic: context)
    let receiver = BridgeHeldSocket()
    defer { receiver.cancel() }
    let reading = Task { await receiver.read(url, holding: true) }
    var provedBlocked = false
    var previous: (Int64, Int64)?
    var stableSince = ProcessInfo.processInfo.systemUptime
    let deadline = stableSince + 2
    do {
      while ProcessInfo.processInfo.systemUptime < deadline {
        let now = ProcessInfo.processInfo.systemUptime
        if receiver.held, let transfer = bridge.evidence(for: url, at: now).last,
          transfer.state == .streaming, transfer.received > transfer.delivered
        {
          if previous?.0 == transfer.received && previous?.1 == transfer.delivered {
            if now - stableSince >= idle * 2 {
              provedBlocked = true
              break
            }
          } else {
            previous = (transfer.received, transfer.delivered)
            stableSince = now
          }
        } else {
          previous = nil
          stableSince = now
        }
        try await Task.sleep(for: .milliseconds(10))
      }
    } catch {
      receiver.cancel()
      _ = await reading.value
      throw error
    }
    receiver.release()
    let result = await reading.value
    try await wait { await bridge.activeCount == 0 }
    XCTAssertTrue(
      provedBlocked,
      "An unchanged received>delivered chunk must prove socket backpressure beyond the idle budget")
    XCTAssertGreaterThan(result.receiveBuffer, 0)
    XCTAssertLessThanOrEqual(result.receiveBuffer, 65_536)
    XCTAssertTrue(result.http200)
    XCTAssertNil(result.error)
    XCTAssertEqual(result.eofCount, 1)
    XCTAssertEqual(
      result.body, body, "Every byte must arrive once, in order, after the real reader hold")
    XCTAssertEqual(server.receivedRanges.count, 1)
    let transfer = try XCTUnwrap(
      bridge.evidence(for: url, at: ProcessInfo.processInfo.systemUptime).last)
    XCTAssertEqual(transfer.state, .completed)
    XCTAssertEqual(transfer.received, Int64(body.count))
    XCTAssertEqual(transfer.delivered, Int64(body.count))
    XCTAssertEqual(transfer.recovery, .unused)
    bridge.retire(url)
  }

  func testPartialInputProgressStillExpiresAfterTheTrueInputIdleInterval() async throws {
    let idle = 0.5
    let body = Data((0..<131_072).map { UInt8(truncatingIfNeeded: $0) })
    let header = Data(
      "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        .utf8)
    let server = try BridgeWireServer(
      header + body, pauseAt: header.count + 65_536, pauseFor: 1.5, partialByteAfter: 0.05)
    defer { server.stop() }
    let upstream = try await server.start()
    let bridge = MediaHTTPBridge(idleTimeout: idle)
    defer { bridge.stop() }
    try await bridge.start()
    let context = DiagnosticSession().begin(.play)
    let url = try bridge.register(MediaSource(url: upstream, quality: .high), diagnostic: context)
    let receiver = BridgeHeldSocket()
    defer { receiver.cancel() }
    let result = await receiver.read(url, holding: false)
    try await wait { await bridge.activeCount == 0 }
    let prefixAt = try XCTUnwrap(result.prefixAt)
    XCTAssertTrue(result.http200)
    XCTAssertEqual(result.body, Data(body.prefix(65_536)))
    XCTAssertLessThan(result.body.count, body.count)
    XCTAssertGreaterThanOrEqual(result.endedAt - prefixAt, 0.4)
    XCTAssertLessThan(
      result.endedAt - prefixAt, 0.9,
      "A byte arriving50ms after the prefix cannot earn a fresh interval at the500ms poll")
    XCTAssertEqual(server.receivedRanges.count, 1)
    let transfer = try XCTUnwrap(
      bridge.evidence(for: url, at: ProcessInfo.processInfo.systemUptime).last)
    XCTAssertEqual(transfer.state, .failed)
    XCTAssertEqual(transfer.code, DiagnosticCode(domain: .url, value: -1001))
    XCTAssertEqual(
      transfer.taskReceived, 65_537, "The partial byte reached the upstream task before timeout")
    XCTAssertEqual(transfer.inputTimedOut, true)
    XCTAssertGreaterThanOrEqual(transfer.received, 65_536)
    XCTAssertLessThanOrEqual(transfer.received, 65_537)
    XCTAssertEqual(transfer.delivered, 65_536)
    XCTAssertEqual(transfer.recovery, .unused)
    bridge.retire(url)
  }

  func testBufferedProgressiveStreamSurvivesThirteenSecondUpstreamIdle() async throws {
    let path = try XCTUnwrap(
      Bundle.module.url(forResource: "bridge", withExtension: "mp3", subdirectory: "Fixtures"))
    let original = try Data(contentsOf: path)
    XCTAssertEqual(Data(original.prefix(3)), Data("ID3".utf8))
    let tagBytes = original[6..<10].reduce(0) { ($0 << 7) | Int($1 & 127) } + 10
    let frameBytes = 288
    XCTAssertEqual(Data(original[(tagBytes + 13)..<(tagBytes + 17)]), Data("Info".utf8))
    let frames = Data(original.dropFirst(tagBytes + frameBytes))
    XCTAssertEqual(frames.count, 336 * frameBytes)
    for index in stride(from: 0, to: frames.count, by: frameBytes) {
      XCTAssertEqual(Data(frames[index..<(index + 3)]), Data([0xff, 0xf3, 0xa4]))
    }
    var data = Data()
    for _ in 0..<6 { data.append(frames) }
    let prefix = 1000 * frameBytes
    let header = Data(
      "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        .utf8)
    for bridged in [false, true] {
      let server = try BridgeWireServer(
        header + data, pauseAt: header.count + prefix, pauseFor: 13)
      let upstream = try await server.start()
      let bridge = MediaHTTPBridge()
      let url: URL
      if bridged {
        try await bridge.start()
        url = try bridge.register(MediaSource(url: upstream, quality: .high))
      } else {
        url = upstream
      }
      let item = AVPlayerItem(url: url)
      let player = AVPlayer(playerItem: item)
      player.isMuted = true
      let ends = Mutex(0)
      let observer = NotificationCenter.default.addObserver(
        forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
      ) { _ in ends.withLock { $0 += 1 } }
      do {
        let start = ProcessInfo.processInfo.systemUptime
        player.play()
        for second in 1...30 {
          try await Task.sleep(for: .seconds(1))
          let clock = player.currentTime().seconds
          let nativeCode = (item.error as NSError?)?.code ?? 0
          if second == 1 || second == 12 || second == 15 || second == 24 || second == 30 {
            print(
              "GAP-NATIVE bridge=\(bridged) wall=\(second) clock=\(clock) status=\(item.status.rawValue) native=\(nativeCode) requests=\(server.receivedRanges.count) end=\(ends.withLock { $0 })"
            )
          }
        }
        let clock = player.currentTime().seconds
        XCTAssertGreaterThan(
          clock, 27, "Buffered source must survive the authored13s upstream pause")
        XCTAssertEqual(ends.withLock { $0 }, 0, "A48s file cannot finish within30s")
        XCTAssertNotEqual(item.status, .failed)
        print(
          "GAP-ELAPSED bridge=\(bridged) seconds=\(ProcessInfo.processInfo.systemUptime - start)")
      } catch {
        player.pause()
        player.replaceCurrentItem(with: nil)
        NotificationCenter.default.removeObserver(observer)
        bridge.stop()
        server.stop()
        throw error
      }
      player.pause()
      player.replaceCurrentItem(with: nil)
      NotificationCenter.default.removeObserver(observer)
      bridge.stop()
      server.stop()
      try await wait { await bridge.activeCount == 0 }
    }
    for bridged in [false, true] {
      let server = try BridgeWireServer(
        header + data, pauseAt: header.count + prefix, pauseFor: 13)
      let upstream = try await server.start()
      let bridge = MediaHTTPBridge()
      let session = URLSession(configuration: .ephemeral)
      defer {
        bridge.stop()
        server.stop()
        session.invalidateAndCancel()
      }
      let url: URL
      if bridged {
        try await bridge.start()
        url = try bridge.register(MediaSource(url: upstream, quality: .high))
      } else {
        url = upstream
      }
      var delivered = Data()
      var code = 0
      do {
        let (bytes, _) = try await session.bytes(from: url)
        for try await byte in bytes { delivered.append(byte) }
      } catch { code = (error as NSError).code }
      print(
        "GAP-BYTES bridge=\(bridged) delivered=\(delivered.count) expected=\(data.count) code=\(code)"
      )
      XCTAssertEqual(
        delivered, Data(data.prefix(delivered.count)), "No body replay or substituted prefix")
      XCTAssertEqual(
        delivered.count, data.count, "A buffered silence interval must not truncate the response")
      XCTAssertEqual(code, 0)
    }
  }

  func testMixedOriginalFormatsAdvanceSeekAndEndOnceInOrder() async throws {
    let formats: [(resource: String, ext: String, mime: String, seek: Bool)] = [
      ("bridge", "wav", "audio/wav", false),
      ("bridge-aac", "aac", "audio/aac", true),
      ("bridge", "flac", "audio/flac", false),
      ("bridge-aac", "m4a", "audio/mp4", true),
      ("bridge", "mp3", "audio/mpeg", false),
      ("bridge-alac", "m4a", "audio/mp4", true),
      ("bridge", "aiff", "audio/x-aiff", true),
    ]
    let payloads = try formats.map { format in
      try Data(
        contentsOf: XCTUnwrap(
          Bundle.module.url(
            forResource: format.resource, withExtension: format.ext, subdirectory: "Fixtures")))
    }
    let upstream = formats.indices.map {
      URL(string: "http://fixture.invalid/Audio/mixed-original-\($0)/stream")!
    }
    let sources = upstream.map { MediaSource(url: $0, quality: .original) }
    BridgeFixtureProtocol.state.reset(
      formats.indices.map {
        .init(url: upstream[$0], data: payloads[$0], mime: formats[$0].mime, ranged: true)
      })
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    let consumer = client()
    let player = AVQueuePlayer()
    player.isMuted = true
    player.allowsExternalPlayback = false
    let events = BridgeMixedQueueEvents()
    var items: [AVPlayerItem] = []
    var observers: [NSObjectProtocol] = []
    var capabilities: [Int: URL] = [:]
    defer {
      player.pause()
      for item in items { item.cancelPendingSeeks() }
      player.removeAllItems()
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      for url in capabilities.values { bridge.retire(url) }
      consumer.invalidateAndCancel()
      bridge.stop()
    }
    let started = ContinuousClock.now
    let deadline = started.advanced(by: .seconds(100))
    for index in formats.indices {
      guard ContinuousClock.now.duration(to: deadline) > .seconds(4) else {
        XCTFail("Mixed-format preflight exhausted its fixed deadline")
        throw ClientError.unavailable
      }
      let url = try bridge.register(sources[index])
      do {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-31", forHTTPHeaderField: "Range")
        let (data, response) = try await consumer.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206, formats[index].ext)
        XCTAssertEqual(response.mimeType, formats[index].mime)
        XCTAssertEqual(data, Data(payloads[index].prefix(32)))
        XCTAssertEqual(
          (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
          "bytes 0-31/\(payloads[index].count)")
      } catch {
        bridge.retire(url)
        throw error
      }
      bridge.retire(url)
      try await wait { await bridge.activeCount == 0 }
      let active = await bridge.activeCount
      guard active == 0 else { throw ClientError.unavailable }
    }
    let beforeNative = upstream.map { BridgeFixtureProtocol.state.count(for: $0) }
    var next = 0
    func appendNext() throws {
      let index = next
      let url = try bridge.register(sources[index])
      capabilities[index] = url
      let item = AVPlayerItem(url: url)
      guard player.canInsert(item, after: nil) else {
        XCTFail("Native queue refused invented item \(index)")
        throw ClientError.unavailable
      }
      observers.append(
        NotificationCenter.default.addObserver(
          forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { _ in
          MainActor.assumeIsolated {
            events.ended.append(index)
            events.endDurations[index] = item.duration.seconds
          }
        })
      observers.append(
        NotificationCenter.default.addObserver(
          forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { _ in MainActor.assumeIsolated { events.failed.append(index) } })
      items.append(item)
      player.insert(item, after: nil)
      next += 1
    }
    try appendNext()
    try appendNext()
    var adopted: [Int] = []
    var progressed: Set<Int> = []
    var reachedFinalQuarterSecond: Set<Int> = []
    var firstSeen: [Int: ContinuousClock.Instant] = [:]
    var seekRequested: [Int: ContinuousClock.Instant] = [:]
    var seekChecked: Set<Int> = []
    var retired: Set<Int> = []
    player.play()
    while ContinuousClock.now < deadline && events.ended.count < formats.count {
      let now = ContinuousClock.now
      if player.status == .failed || !events.failed.isEmpty {
        XCTFail("Native mixed queue failed before ordinary EOF")
        throw ClientError.unavailable
      }
      if let item = player.currentItem, let index = items.firstIndex(where: { $0 === item }) {
        if firstSeen[index] == nil {
          firstSeen[index] = now
          adopted.append(index)
        }
        let position = item.currentTime().seconds
        if position.isFinite && position > 0.15 { progressed.insert(index) }
        if (7.75...8.25).contains(position) { reachedFinalQuarterSecond.insert(index) }
        if !progressed.contains(index), let first = firstSeen[index],
          first.duration(to: now) > .seconds(12)
        {
          XCTFail("Invented item \(index) never advanced within 12 seconds")
          throw ClientError.unavailable
        }
        if formats[index].seek, position.isFinite, position > 0.2, seekRequested[index] == nil {
          seekRequested[index] = now
          player.seek(
            to: CMTime(seconds: 3, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
          ) { [weak player, weak item] completed in
            Task { @MainActor in
              let stillCurrent = item != nil && player?.currentItem === item
              events.seeks[index] = (
                completed && stillCurrent, item?.currentTime().seconds ?? .nan
              )
            }
          }
        }
      }
      for (index, requested) in seekRequested where !seekChecked.contains(index) {
        if let result = events.seeks[index] {
          XCTAssertTrue(result.completed, "Exact current seek must complete for item \(index)")
          XCTAssertEqual(result.clock, 3, accuracy: 0.15, "Item \(index)")
          guard result.completed, result.clock.isFinite, abs(result.clock - 3) <= 0.15 else {
            throw ClientError.unavailable
          }
          seekChecked.insert(index)
        } else if requested.duration(to: now) > .seconds(3) {
          items[index].cancelPendingSeeks()
          XCTFail("Invented item \(index) seek missed its three-second callback bound")
          throw ClientError.unavailable
        }
      }
      for index in events.ended where !retired.contains(index) {
        if let url = capabilities.removeValue(forKey: index) { bridge.retire(url) }
        retired.insert(index)
      }
      while next < formats.count && player.items().count < 2 { try appendNext() }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(adopted, Array(formats.indices), "No skipped/reordered current identity")
    XCTAssertEqual(progressed, Set(formats.indices), "Every exact item must advance")
    XCTAssertEqual(
      reachedFinalQuarterSecond, Set(formats.indices), "Each current item reached its known end")
    XCTAssertEqual(events.ended, Array(formats.indices), "Ordinary EOF exactly once and in order")
    XCTAssertTrue(events.failed.isEmpty)
    XCTAssertEqual(seekChecked, Set(formats.indices.filter { formats[$0].seek }))
    XCTAssertEqual(next, formats.count)
    XCTAssertNil(player.currentItem)
    XCTAssertEqual(BridgeFixtureProtocol.state.unexpectedCount, 0)
    for index in formats.indices {
      XCTAssertGreaterThan(
        BridgeFixtureProtocol.state.count(for: upstream[index]), beforeNative[index],
        "Native must request its distinct invented resource")
      XCTAssertEqual(events.endDurations[index] ?? .nan, 8, accuracy: 0.25, "Item \(index)")
    }
    let maximumActive = await bridge.maximumActive
    let maximumChunk = await bridge.maximumChunk
    XCTAssertLessThanOrEqual(maximumActive, 4)
    XCTAssertLessThanOrEqual(maximumChunk, 16_400)
    player.pause()
    player.removeAllItems()
    for url in capabilities.values { bridge.retire(url) }
    capabilities = [:]
    bridge.stop()
    try await wait { await bridge.activeCount == 0 }
    let drained = await bridge.activeCount
    XCTAssertEqual(drained, 0)
  }

  func testRangedNativeWAVMP3FLACAdvanceAndSeek() async throws {
    for type in ["wav", "mp3", "flac"] {
      let source = try fixture(type, ranged: true)
      let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
      try await bridge.start()
      let url = try bridge.register(source)
      let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
      let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      player.isMuted = true
      defer {
        player.pause()
        player.replaceCurrentItem(with: nil)
        bridge.stop()
      }
      player.play()
      for _ in 0..<80 {
        if player.currentTime().seconds > 0.15 { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertGreaterThan(player.currentTime().seconds, 0.15, type)
      player.pause()
      let sought = await player.seek(
        to: CMTime(seconds: 3, preferredTimescale: 600), toleranceBefore: .zero,
        toleranceAfter: .zero)
      XCTAssertTrue(sought, type)
      XCTAssertEqual(player.currentTime().seconds, 3, accuracy: 0.05, type)
      let peak = await bridge.maximumActive
      let chunk = await bridge.maximumChunk
      XCTAssertLessThanOrEqual(peak, 4)
      XCTAssertLessThanOrEqual(chunk, 16_400)
    }
  }
  func testPostHeaderUpstreamFailureCannotBecomeSuccessfulDownstreamEOF() async throws {
    for ranged in [false, true] {
      let source = try fixture("mp3", ranged: ranged, mode: .prefixFailure)
      let owner = BridgeFixtureProtocol.state.owner
      let recorder = DiagnosticRecorder()
      let context = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.play))
      let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
      try await bridge.start()
      let consumer = client()
      let url = try bridge.register(source, diagnostic: context)
      let delivered = Mutex(0)
      let request = Task {
        let (bytes, _) = try await consumer.bytes(from: url)
        var count = 0
        for try await _ in bytes {
          count += 1
          if count.isMultiple(of: 16_384) { delivered.withLock { $0 = count } }
        }
        return count
      }
      defer {
        request.cancel()
        consumer.invalidateAndCancel()
        bridge.stop()
      }
      try await wait {
        BridgeFixtureProtocol.state.hasHeldCompletion(owner)
          && delivered.withLock { $0 >= 16_384 }
      }
      BridgeFixtureProtocol.state.releaseHeldCompletion(owner)
      do {
        _ = try await request.value
        XCTFail("An upstream failure after body publication must not become clean HTTP EOF")
      } catch {
        XCTAssertFalse(error is CancellationError)
        XCTAssertNotEqual((error as NSError).code, URLError.Code.cancelled.rawValue)
      }
      try await wait { recorder.records.contains { $0.facts.outcome == .failed } }
      let failed = try XCTUnwrap(recorder.records.last { $0.facts.outcome == .failed })
      XCTAssertEqual(failed.facts.http, 200)
      XCTAssertGreaterThanOrEqual(failed.facts.bytes ?? 0, 16_384)
      XCTAssertEqual(failed.facts.code?.value, URLError.Code.networkConnectionLost.rawValue)
      try await wait { await bridge.activeCount == 0 }
      let transfer = try XCTUnwrap(
        bridge.evidence(for: url, at: ProcessInfo.processInfo.systemUptime).last)
      XCTAssertEqual(transfer.code, DiagnosticCode(domain: .url, value: -1005))
      XCTAssertEqual(transfer.state, .failed)
      XCTAssertFalse(
        recorder.records.contains {
          $0.facts.outcome == .succeeded
        })
    }
  }
  func testProgressiveRecoveryVerifiesEveryCommittedByteBeforeForwardingMore() async throws {
    let fixture = try XCTUnwrap(
      Bundle.module.url(
        forResource: "bridge", withExtension: "mp3",
        subdirectory: "Fixtures"))
    let data = try Data(contentsOf: fixture)
    for mismatch in [false, true] {
      let upstream = URL(string: "http://fixture.invalid/Audio/transcode/stream")!
      var second = data
      if mismatch { second[65_535] ^= 1 }
      BridgeFixtureProtocol.state.reset(
        .init(
          url: upstream, data: data, mime: "audio/mpeg",
          ranged: false, mode: .prefixFailure, secondBody: second))
      let owner = BridgeFixtureProtocol.state.owner
      let recorder = DiagnosticRecorder()
      let context = try XCTUnwrap(DiagnosticSession(sink: recorder.append).begin(.play))
      let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
      try await bridge.start()
      let url = try bridge.register(
        MediaSource(url: upstream, quality: .high, serverTimeSeek: true),
        diagnostic: context)
      let consumer = URLSession(configuration: .ephemeral)
      let request = Task { try await consumer.data(from: url).0 }
      defer {
        request.cancel()
        consumer.invalidateAndCancel()
        bridge.stop()
      }
      try await wait {
        BridgeFixtureProtocol.state.hasHeldCompletion(owner)
          && bridge.evidence(for: url, at: 0).last?.delivered == 65_536
      }
      BridgeFixtureProtocol.state.releaseHeldCompletion(owner)
      let result = await request.result
      try await wait { await bridge.activeCount == 0 }
      let evidence = try XCTUnwrap(bridge.evidence(for: url, at: 0).last)
      XCTAssertEqual(BridgeFixtureProtocol.state.count, 2)
      if mismatch {
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(evidence.state, .failed)
        XCTAssertEqual(evidence.rejection, .changedPrefix)
        XCTAssertEqual(evidence.recovery, .verifying)
        XCTAssertEqual(evidence.delivered, 65_536)
      } else {
        XCTAssertEqual(try result.get(), data)
        XCTAssertEqual(evidence.state, .completed)
        XCTAssertEqual(evidence.recovery, .resumed)
        XCTAssertEqual(evidence.delivered, Int64(data.count))
      }
    }
  }
  func testLengthlessProgressiveMP3StartsBeforeEOFAndEndsNaturally() async throws {
    let source = try fixture("mp3", ranged: false)
    let bridge = MediaHTTPBridge(protocolClasses: [BridgeFixtureProtocol.self])
    try await bridge.start()
    let player = AVPlayer(url: try bridge.register(source))
    player.isMuted = true
    defer {
      player.pause()
      player.replaceCurrentItem(with: nil)
      bridge.stop()
    }
    player.play()
    for _ in 0..<50 {
      if player.currentTime().seconds > 0.15 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertFalse(BridgeFixtureProtocol.state.ended)
    XCTAssertGreaterThan(
      player.currentTime().seconds, 0.15,
      "Must stream before source EOF without a fabricated length")
    let nativeDuration = try XCTUnwrap(player.currentItem).duration.seconds
    let entry = QueueEntry(
      MusicItem(
        id: "invented-progressive", title: "Authored stream", artist: "Fixture", album: "Timing",
        duration: 8, number: 1, kind: "Audio", imageID: nil, imageTag: nil))
    let selected = entry.playbackDuration(
      nativeDuration: nativeDuration, position: player.currentTime().seconds)
    XCTAssertEqual(selected, nativeDuration.isFinite && nativeDuration > 0 ? nativeDuration : 8)
    XCTAssertNotNil(selected, "Advancing lengthless audio retains its accepted timeline hint")
    for _ in 0..<220 {
      if player.currentTime().seconds >= 7.9 && player.rate == 0 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(BridgeFixtureProtocol.state.ended)
    XCTAssertEqual(player.currentTime().seconds, 8, accuracy: 0.2)
    XCTAssertEqual(player.rate, 0)
  }

  func testQueuedTranscodeUsesOneLengthlessGETAndRetainsTheExactRendition() async throws {
    let template = try fixture("mp3", ranged: false)
    let source = MediaSource(
      url: template.url, quality: .high, serverTimeSeek: true, serverDuration: 8)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".mp3")
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BridgeFixtureProtocol.self]
    let asset = try await QueuedTranscode.write(source, to: file, configuration: configuration)
    let original = try XCTUnwrap(
      Bundle.module.url(forResource: "bridge", withExtension: "mp3", subdirectory: "Fixtures"))
    XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: original))
    let firstOpen = try await asset.load(.duration)
    let secondOpen = try await AVURLAsset(url: file).load(.duration)
    XCTAssertEqual(firstOpen.seconds, 8, accuracy: 0.2)
    XCTAssertEqual(secondOpen, firstOpen)
    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    player.isMuted = true
    defer { player.replaceCurrentItem(with: nil) }
    let target = CMTime(seconds: 5.25, preferredTimescale: 600)
    let completed = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    XCTAssertTrue(completed)
    XCTAssertEqual(player.currentTime().seconds, 5.25, accuracy: 0.05)
    XCTAssertEqual(BridgeFixtureProtocol.state.count, 1)
  }

  func testQueuedTranscodeRejectsIncompleteReplayedAndOversizedBodies() async throws {
    let template = try fixture("mp3", ranged: false)
    let encoded = try Data(
      contentsOf: XCTUnwrap(
        Bundle.module.url(forResource: "bridge", withExtension: "mp3", subdirectory: "Fixtures")))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".mp3")
    defer { try? FileManager.default.removeItem(at: file) }
    let source = MediaSource(
      url: template.url, quality: .compact, serverTimeSeek: true, serverDuration: 8)
    let frame = Data([0xff, 0xf3, 0xa4, 0xc4])
    let first = try XCTUnwrap(encoded.range(of: frame)?.lowerBound)
    let replayAt = first + 84 * 288
    XCTAssertEqual(encoded[replayAt..<(replayAt + frame.count)], frame)
    let replayed = encoded[..<replayAt] + encoded[first...]
    let invalid: [(String, BridgeFixtureState.Value)] = [
      (
        "short fixed body",
        .init(url: source.url, data: encoded, mime: "audio/mpeg", ranged: true, mode: .truncated)
      ),
      (
        "short body with its full header",
        .init(
          url: source.url, data: Data(encoded.prefix(encoded.count / 2)), mime: "audio/mpeg",
          ranged: false)
      ),
      (
        "repeated opening with its full header",
        .init(url: source.url, data: replayed, mime: "audio/mpeg", ranged: false)
      ),
      (
        "size limit",
        .init(
          url: source.url, data: Data(repeating: 15, count: QueuedTranscode.maximumBytes + 1),
          mime: "audio/mpeg", ranged: false)
      ),
      (
        "redirect",
        .init(url: source.url, data: encoded, mime: "audio/mpeg", ranged: true, mode: .redirect)
      ),
    ]
    for (label, value) in invalid {
      try Data().write(to: file)
      BridgeFixtureProtocol.state.reset(value)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [BridgeFixtureProtocol.self]
      configuration.timeoutIntervalForRequest = 6
      configuration.timeoutIntervalForResource = 9
      do {
        try await QueuedTranscode.write(source, to: file, configuration: configuration)
        XCTFail("Unusable lookahead must never become a queued item: " + label)
      } catch {
        XCTAssertEqual(BridgeFixtureProtocol.state.unexpectedCount, 0)
        XCTAssertLessThanOrEqual(
          try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1,
          QueuedTranscode.maximumBytes)
      }
    }
    XCTAssertFalse(QueuedTranscode.canPrepare(template))
    XCTAssertFalse(
      QueuedTranscode.canPrepare(
        MediaSource(url: source.url, quality: .high, serverTimeSeek: true, serverDuration: 3600)))
    XCTAssertFalse(
      QueuedTranscode.canPrepare(
        MediaSource(
          url: source.url, quality: .high, serverTimeSeek: true, timeOrigin: 4, serverDuration: 8)))
  }

  func testCancellationRetiresAnIncompleteQueuedTranscode() async throws {
    let template = try fixture("mp3", ranged: false, mode: .prefixHeld)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".mp3")
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let source = MediaSource(
      url: template.url, quality: .high, serverTimeSeek: true, serverDuration: 8)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BridgeFixtureProtocol.self]
    let task = Task {
      try await QueuedTranscode.write(source, to: file, configuration: configuration)
    }
    try await wait { BridgeFixtureProtocol.state.count == 1 }
    task.cancel()
    do {
      try await task.value
      XCTFail("A canceled preparation cannot publish a file")
    } catch {
      XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
    }
    try await wait { BridgeFixtureProtocol.state.cancelledCount == 1 }
    XCTAssertFalse(BridgeFixtureProtocol.state.ended)
  }
}
