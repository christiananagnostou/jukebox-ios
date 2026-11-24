import XCTest

@testable import JukeboxCore

final class QuickConnectTests: XCTestCase {
  private let server = try! ServerAddress("https://music.invalid/base")
  private let info = HTTPReply(data: Data(#"{"Version":"12.1.0"}"#.utf8), status: 200)
  private let challenge = HTTPReply(
    data: Data(#"{"Code":"012345","Secret":"invented/+&"}"#.utf8), status: 200)
  private let waiting = HTTPReply(data: Data(#"{"Authenticated":false}"#.utf8), status: 200)
  private let approved = HTTPReply(data: Data(#"{"Authenticated":true}"#.utf8), status: 200)
  private let session = HTTPReply(
    data: Data(#"{"User":{"Id":"listener","Name":"Demo"},"AccessToken":"invented-token"}"#.utf8),
    status: 200)
  private let identity = HTTPReply(data: Data(#"{"Id":"listener"}"#.utf8), status: 200)

  func testCodeKeepsLeadingZeroAndAcceptsPastedGroups() {
    for input in ["012345", "012 345", "012-345\n"] {
      XCTAssertEqual(QuickConnectCode(input)?.digits, "012345")
    }
    for input in ["123", "1234567", "code123456", "１２３４５６", "123&45", ""] {
      XCTAssertNil(QuickConnectCode(input))
    }
  }

  func testCheckingSignInOptionsNeverIssuesACodeOrSendsCredentials() async throws {
    for (reply, expected) in [
      (HTTPReply(data: Data("true".utf8), status: 200), true as Bool?),
      (HTTPReply(data: Data("false".utf8), status: 200), false),
      (HTTPReply(data: Data(), status: 404), nil),
      (HTTPReply(data: Data("{}".utf8), status: 200), nil),
    ] {
      let http = ScriptedHTTP(replies: [info, reply])
      let auth = JellyfinAuthentication(server: server, deviceID: "fixture", transport: http)
      let availability = try await auth.signInCodeAvailability()
      XCTAssertEqual(availability, expected)
      let requests = await http.requests
      XCTAssertEqual(
        requests.compactMap { $0.url?.path },
        ["/base/System/Info/Public", "/base/QuickConnect/Enabled"])
      XCTAssertTrue(
        requests.allSatisfy {
          $0.httpMethod == "GET" && $0.httpBody == nil
            && $0.value(forHTTPHeaderField: "Authorization") == nil
        })
    }
  }

  func testUnavailableServerStopsBeforeCheckingSignInMethods() async throws {
    let http = ScriptedHTTP(replies: [.init(data: Data(), status: 503)])
    let auth = JellyfinAuthentication(server: server, deviceID: "fixture", transport: http)
    do {
      _ = try await auth.signInCodeAvailability()
      XCTFail("Offered sign-in on an unverified server")
    } catch { XCTAssertEqual(error as? ClientError, .unavailable) }
    let paths = await http.paths
    XCTAssertEqual(paths, ["/base/System/Info/Public"])
  }

  @MainActor func testPasswordlessSignInPollsSameChallengeAndVerifiesAccount() async throws {
    let http = ScriptedHTTP(replies: [
      info, challenge, waiting, .init(data: Data(), status: 503), approved, session, identity,
    ])
    let auth = JellyfinAuthentication(server: server, deviceID: "test-device", transport: http)
    var displayed: [String] = []
    let (account, token) = try await auth.quickConnect(pollInterval: .zero) {
      displayed.append($0.digits)
    }
    XCTAssertEqual(displayed, ["012345"])
    XCTAssertEqual(account.username, "Demo")
    XCTAssertEqual(account.userID, "listener")
    XCTAssertEqual(token, "invented-token")
    let requests = await http.requests
    XCTAssertEqual(
      requests.compactMap { $0.url?.path },
      [
        "/base/System/Info/Public", "/base/QuickConnect/Initiate", "/base/QuickConnect/Connect",
        "/base/QuickConnect/Connect", "/base/QuickConnect/Connect",
        "/base/Users/AuthenticateWithQuickConnect", "/base/Users/Me",
      ])
    XCTAssertEqual(
      requests.compactMap(\.httpMethod), ["GET", "POST", "GET", "GET", "GET", "POST", "GET"])
    for request in requests[2...4] {
      let components = try XCTUnwrap(
        URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
      XCTAssertEqual(components.queryItems, [.init(name: "secret", value: "invented/+&")])
      XCTAssertTrue(components.percentEncodedQuery?.contains("%2B") == true)
    }
    XCTAssertEqual(
      try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests[5].httpBody)),
      ["Secret": "invented/+&"])
    XCTAssertTrue(
      requests.dropLast().allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization")?.contains("Token=") != true
      })
    XCTAssertTrue(
      requests[6].value(forHTTPHeaderField: "Authorization")?.contains("invented-token") == true)
  }

  @MainActor func testDisabledExpiredAndUnverifiedChallengesCannotStartSessions() async throws {
    for (replies, expected) in [
      ([info, HTTPReply(data: Data(), status: 401)], QuickConnectError.disabled),
      ([info, challenge, HTTPReply(data: Data(), status: 404)], QuickConnectError.expired),
    ] {
      let http = ScriptedHTTP(replies: replies)
      let auth = JellyfinAuthentication(server: server, deviceID: "device", transport: http)
      do {
        _ = try await auth.quickConnect(pollInterval: .zero) { _ in }
        XCTFail("Unexpected sign-in")
      } catch { XCTAssertEqual(error as? QuickConnectError, expected) }
      let paths = await http.paths
      XCTAssertFalse(paths.contains("/base/Users/AuthenticateWithQuickConnect"))
    }
    let http = ScriptedHTTP(replies: [
      info, challenge, approved, session, .init(data: Data(#"{"Id":"other"}"#.utf8), status: 200),
    ])
    let auth = JellyfinAuthentication(server: server, deviceID: "device", transport: http)
    do {
      _ = try await auth.quickConnect(pollInterval: .zero) { _ in }
      XCTFail("Accepted a different account")
    } catch { XCTAssertEqual(error as? ClientError, .unauthorized) }
  }

  @MainActor func testUnsecuredServerAndMalformedCodeStopBeforePolling() async throws {
    let http = ScriptedHTTP(replies: [
      info, .init(data: Data(#"{"Code":"short","Secret":"invented"}"#.utf8), status: 200),
    ])
    var auth = JellyfinAuthentication(
      server: try ServerAddress("http://music.invalid"), deviceID: "device", transport: http)
    do {
      _ = try await auth.quickConnect { _ in XCTFail() }
      XCTFail()
    } catch { XCTAssertEqual(error as? ClientError, .secureConnectionRequired) }
    let rejected = await http.paths
    XCTAssertTrue(rejected.isEmpty)
    auth = JellyfinAuthentication(server: server, deviceID: "device", transport: http)
    do {
      _ = try await auth.quickConnect { _ in XCTFail() }
      XCTFail()
    } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
    let paths = await http.paths
    XCTAssertEqual(paths, ["/base/System/Info/Public", "/base/QuickConnect/Initiate"])
  }

  @MainActor func testCancelledPollDiscardsLateApproval() async throws {
    let http = ScriptedHTTP(replies: [info, challenge, approved])
    await http.holdNext("Connect")
    let auth = JellyfinAuthentication(server: server, deviceID: "device", transport: http)
    let attempt = Task { try await auth.quickConnect(pollInterval: .zero) { _ in } }
    for _ in 0..<200 {
      if await http.waiting { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let pending = await http.waiting
    XCTAssertTrue(pending)
    attempt.cancel()
    await http.release()
    do {
      _ = try await attempt.value
      XCTFail("Completed a cancelled sign-in")
    } catch { XCTAssertTrue(error is CancellationError) }
    let paths = await http.paths
    XCTAssertEqual(paths.last, "/base/QuickConnect/Connect")
  }

  @MainActor func testExpiredLocalDeadlineNeverDisplaysCodeOrStartsPolling() async throws {
    let http = ScriptedHTTP(replies: [info, challenge])
    let auth = JellyfinAuthentication(server: server, deviceID: "device", transport: http)
    do {
      _ = try await auth.quickConnect(pollInterval: .zero, lifetime: .zero) { _ in XCTFail() }
      XCTFail()
    } catch { XCTAssertEqual(error as? QuickConnectError, .expired) }
    let paths = await http.paths
    XCTAssertEqual(paths, ["/base/System/Info/Public", "/base/QuickConnect/Initiate"])
  }

  @MainActor func testVerifiedSignInSavesReusableAccountAndToken() async throws {
    let http = ScriptedHTTP(replies: [info, challenge, approved, session, identity, identity])
    let storage = LibraryStorage()
    let vault = MemoryVault()
    let store = PlayerStore(
      storage: storage, vault: vault, driver: DriverSpy(), deviceID: "device",
      authenticationTransport: http,
      factory: {
        try JellyfinClient(connection: $0, token: $1, deviceID: "device", transport: http)
      })
    try await store.signInWithQuickConnect(server: server) { XCTAssertEqual($0.digits, "012345") }
    let account = try XCTUnwrap(store.active)
    let connections = try await storage.connections()
    let stored = await vault.read(account: account.id)
    XCTAssertEqual(connections, [account])
    XCTAssertEqual(stored, "invented-token")
    XCTAssertTrue(store.canApproveQuickConnect)
    XCTAssertFalse(store.busy)
  }

  func testRetiredApprovalSendsNothingAndDisabledServerDoesNotRepeatApproval() async throws {
    let account = Connection(server: server, userID: "listener", username: "Demo")
    let code = try XCTUnwrap(QuickConnectCode("012345"))
    let http = ScriptedHTTP(replies: [
      .init(data: Data(), status: 401), .init(data: Data("false".utf8), status: 200),
    ])
    let client = try JellyfinClient(
      connection: account, token: "invented", deviceID: "device", transport: http)
    do {
      try await client.authorizeQuickConnect(code, isCurrent: { false })
      XCTFail()
    } catch { XCTAssertEqual(error as? QuickConnectError, .accountChanged) }
    let before = await http.requests
    XCTAssertTrue(before.isEmpty)
    do {
      try await client.authorizeQuickConnect(code)
      XCTFail()
    } catch { XCTAssertEqual(error as? QuickConnectError, .disabled) }
    let after = await http.requests
    XCTAssertEqual(
      after.compactMap { $0.url?.path },
      ["/base/QuickConnect/Authorize", "/base/QuickConnect/Enabled"])
    XCTAssertNil(after.last?.value(forHTTPHeaderField: "Authorization"))
  }

  func testApprovalIsAnExplicitAuthenticatedWriteForTheCurrentAccount() async throws {
    let account = Connection(server: server, userID: "listener", username: "Demo")
    let code = try XCTUnwrap(QuickConnectCode("012345"))
    for (reply, expected) in [
      (HTTPReply(data: Data("true".utf8), status: 200), nil as QuickConnectError?),
      (HTTPReply(data: Data("false".utf8), status: 200), .invalidCode),
      (HTTPReply(data: Data(), status: 404), .invalidCode),
      (HTTPReply(data: Data(), status: 403), .denied),
      (HTTPReply(data: Data(), status: 503), .unconfirmed),
      (HTTPReply(data: Data(), status: 200), .unconfirmed),
    ] {
      let http = ScriptedHTTP(replies: [reply])
      let client = try JellyfinClient(
        connection: account, token: "invented-token", deviceID: "device", transport: http)
      do {
        try await client.authorizeQuickConnect(code)
        XCTAssertNil(expected)
      } catch {
        XCTAssertEqual(error as? QuickConnectError, expected)
        XCTAssertNotNil(expected)
      }
      let requests = await http.requests
      XCTAssertEqual(requests.count, 1)
      let request = try XCTUnwrap(requests.first)
      XCTAssertEqual(
        request.url?.absoluteString, "https://music.invalid/base/QuickConnect/Authorize?code=012345"
      )
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertTrue(
        request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"invented-token\"")
          == true)
    }
  }

  @MainActor func testApprovalCannotSwitchAccountsOrPublishAfterRetirement() async throws {
    let account = Connection(server: server, userID: "listener", username: "Demo")
    let other = Connection(server: server, userID: "other", username: "Other")
    let vault = MemoryVault()
    await vault.write("invented", account: account.id)
    let http = ScriptedHTTP(replies: [identity, .init(data: Data("true".utf8), status: 200)])
    let store = PlayerStore(
      storage: LibraryStorage(), vault: vault, driver: DriverSpy(), deviceID: "device",
      factory: {
        try JellyfinClient(connection: $0, token: $1, deviceID: "device", transport: http)
      })
    await store.activate(account)
    let code = try XCTUnwrap(QuickConnectCode("123456"))
    do {
      try await store.approveQuickConnect(code, for: other)
      XCTFail()
    } catch { XCTAssertEqual(error as? QuickConnectError, .accountChanged) }
    let paths = await http.paths
    XCTAssertEqual(paths, ["/base/Users/Me"])
    await http.holdNext("Authorize")
    let action = Task { try await store.approveQuickConnect(code, for: account) }
    for _ in 0..<200 {
      if await http.waiting { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let pending = await http.waiting
    XCTAssertTrue(pending)
    store.addConnection()
    await http.release()
    do {
      try await action.value
      XCTFail()
    } catch { XCTAssertEqual(error as? QuickConnectError, .accountChanged) }
    XCTAssertFalse(store.canApproveQuickConnect)
  }
}
