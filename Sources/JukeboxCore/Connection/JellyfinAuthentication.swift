import Foundation

struct QuickConnectCode: Hashable, Sendable {
  let digits: String

  init?(_ input: String) {
    guard input.utf8.count <= 32 else { return nil }
    let value = input.filter { !$0.isWhitespace && $0 != "-" }
    guard value.utf8.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) }) else {
      return nil
    }
    digits = value
  }
}

enum QuickConnectError: Error, Equatable, LocalizedError {
  case disabled, expired, invalidCode, denied, unconfirmed, accountChanged

  var errorDescription: String? {
    switch self {
    case .disabled: "Quick Connect is turned off on this server."
    case .expired: "This code expired. Get a new code to continue."
    case .invalidCode: "This code is invalid or has expired. Check the code on the other device."
    case .denied: "This account can’t approve the sign-in."
    case .unconfirmed: "Approval couldn’t be confirmed. Check the other device before trying again."
    case .accountChanged: "The active account changed. Open Quick Connect again."
    }
  }

  static func message(for error: any Error) -> String {
    if let error = error as? QuickConnectError { return error.localizedDescription }
    if let error = error as? ConnectionStepError { return error.localizedDescription }
    if let error = error as? URLError { return ClientError.transport(error).localizedDescription }
    return (error as? ClientError)?.localizedDescription ?? "Couldn’t complete Quick Connect."
  }
}

protocol QuickConnectAuthorizing: Sendable {
  func authorizeQuickConnect(
    _ code: QuickConnectCode, isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws
}

struct JellyfinAuthentication: Sendable {
  let server: ServerAddress
  let deviceID: String
  var transport: any HTTPTransport = LiveHTTP()
  var allowedFamilies = ServerCompatibility.verifiedFamilies

  func signInCodeAvailability() async throws -> Bool? {
    _ = try await serverInfo()
    try Task.checkCancellation()
    var request = URLRequest(url: try server.endpoint("QuickConnect/Enabled"))
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 5
    let reply = try? await transport.send(request)
    try Task.checkCancellation()
    guard let reply, reply.status == 200 else { return nil }
    return try? JSONDecoder().decode(Bool.self, from: reply.data)
  }

  func serverInfo() async throws -> JellyfinServerInfo {
    try server.requireCredentialTransport()
    var request = URLRequest(url: try server.endpoint("System/Info/Public"))
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let reply: HTTPReply
    do { reply = try await transport.send(request) } catch {
      throw ConnectionStepError(step: .serverInfo, error: error)
    }
    guard reply.status == 200 else {
      if reply.status == 429 || reply.status >= 500 { throw ClientError.unavailable }
      throw ClientError.notJellyfinServer
    }
    guard let info = try? JSONDecoder().decode(JellyfinServerInfo.self, from: reply.data),
      !info.version.isEmpty
    else { throw ClientError.notJellyfinServer }
    guard ServerCompatibility.accepts(info.version, families: allowedFamilies) else {
      throw ClientError.unsupportedVersion
    }
    try Task.checkCancellation()
    return info
  }

  private func send(
    _ path: String, method: String, query: [URLQueryItem] = [], body: [String: String]? = nil
  ) async throws -> HTTPReply {
    try Task.checkCancellation()
    var request = URLRequest(url: try server.endpoint(path, query: query))
    request.httpMethod = method
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(
      JellyfinClient.authorization(device: deviceID), forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }
    let reply = try await transport.send(request)
    try Task.checkCancellation()
    return reply
  }

  func password(username: String, password: String) async throws -> (Connection, String) {
    let info = try await serverInfo()
    let reply: HTTPReply
    do {
      reply = try await send(
        "Users/AuthenticateByName", method: "POST", body: ["Username": username, "Pw": password])
    } catch { throw ConnectionStepError(step: .authentication, error: error) }
    guard (200..<300).contains(reply.status) else {
      throw ConnectionStepError(
        step: .authentication, error: ClientError.unauthorized, status: reply.status)
    }
    return try await verifiedAccount(reply, info: info, fallbackName: username)
  }

  func quickConnect(
    pollInterval: Duration = .seconds(5), lifetime: Duration = .seconds(600),
    showCode: @MainActor @Sendable (QuickConnectCode) -> Void
  ) async throws -> (Connection, String) {
    let info = try await serverInfo()
    let deadline = ContinuousClock.now.advanced(by: lifetime)
    let start = try await send("QuickConnect/Initiate", method: "POST")
    if [401, 403].contains(start.status) { throw QuickConnectError.disabled }
    guard start.status == 200 else { throw ClientError.unavailable }
    struct Challenge: Decodable {
      let code: String
      let secret: String
      enum CodingKeys: String, CodingKey {
        case code = "Code"
        case secret = "Secret"
      }
    }
    let challenge = try JSONDecoder().decode(Challenge.self, from: start.data)
    guard let code = QuickConnectCode(challenge.code), !challenge.secret.isEmpty,
      challenge.secret.utf8.count <= 1024
    else { throw ClientError.invalidResponse }
    guard ContinuousClock.now < deadline else { throw QuickConnectError.expired }
    await showCode(code)
    var failures = 0
    while ContinuousClock.now < deadline {
      try await Task.sleep(
        until: min(ContinuousClock.now.advanced(by: pollInterval), deadline), clock: .continuous)
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else { break }
      let state: HTTPReply
      do {
        state = try await send(
          "QuickConnect/Connect", method: "GET",
          query: [.init(name: "secret", value: challenge.secret)])
        if state.status == 429 || state.status >= 500 { throw ClientError.unavailable }
      } catch {
        try Task.checkCancellation()
        let transient =
          (error as? ClientError) == .unavailable
          || (error as? URLError).map {
            [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost]
              .contains($0.code)
          } == true
        guard transient, failures < 3 else { throw error }
        failures += 1
        continue
      }
      failures = 0
      guard ContinuousClock.now < deadline else { throw QuickConnectError.expired }
      if state.status == 404 { throw QuickConnectError.expired }
      if [401, 403].contains(state.status) { throw QuickConnectError.disabled }
      struct State: Decodable {
        let authenticated: Bool
        enum CodingKeys: String, CodingKey { case authenticated = "Authenticated" }
      }
      guard state.status == 200 else { throw ClientError.invalidResponse }
      if try JSONDecoder().decode(State.self, from: state.data).authenticated {
        let reply = try await send(
          "Users/AuthenticateWithQuickConnect", method: "POST", body: ["Secret": challenge.secret])
        if [400, 401, 404].contains(reply.status) { throw QuickConnectError.expired }
        guard reply.status == 200 else { throw ClientError.unavailable }
        return try await verifiedAccount(reply, info: info)
      }
    }
    throw QuickConnectError.expired
  }

  private func verifiedAccount(
    _ reply: HTTPReply, info: JellyfinServerInfo, fallbackName: String? = nil
  ) async throws -> (
    Connection, String
  ) {
    struct User: Decodable {
      let id: String
      let name: String?
      enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
      }
    }
    struct Session: Decodable {
      let user: User
      let accessToken: String
      enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
      }
    }
    guard let session = try? JSONDecoder().decode(Session.self, from: reply.data),
      !session.user.id.isEmpty, let name = session.user.name ?? fallbackName
    else { throw ConnectionStepError(step: .authentication, error: ClientError.invalidResponse) }
    let connection = Connection(
      server: server, userID: session.user.id, username: name, serverInfo: info)
    let client = try JellyfinClient(
      connection: connection, token: session.accessToken, deviceID: deviceID, transport: transport)
    try await client.verifyIdentity()
    try Task.checkCancellation()
    return (connection, session.accessToken)
  }
}
