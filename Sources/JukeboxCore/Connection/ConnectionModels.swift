import CryptoKit
import Foundation

enum ClientError: Error, Equatable, LocalizedError {
  case notJellyfinServer, invalidServer, invalidResponse, unauthorized, forbidden,
    unsupportedVersion, unavailable, secureConnectionRequired, secureConnectionFailed,
    serverNameNotFound, secureStorage
  var errorDescription: String? {
    switch self {
    case .invalidServer: "Enter a server address without a username, password or query."
    case .unauthorized: "Your session expired. Sign in again."
    case .forbidden: "This music is no longer available to your account."
    case .notJellyfinServer:
      "That address didn’t return Jellyfin server information. Use the direct Jellyfin address, including its port or base path."
    case .unsupportedVersion:
      "This development build supports Jellyfin \(ServerCompatibility.supportedVersions). Other versions have not been verified."
    case .invalidResponse: "The server returned an unexpected response. Try again."
    case .secureStorage:
      "Secure sign-in storage isn’t available. Rebuild the app with normal signing, then try again."
    case .secureConnectionRequired:
      "iOS blocked this insecure connection. Use the server’s HTTPS address."
    case .secureConnectionFailed:
      "The server’s secure connection couldn’t be verified. Check its HTTPS address and certificate."
    case .serverNameNotFound:
      "The server name couldn’t be found. Check the address and that Tailscale is connected if required."
    case .unavailable: "Couldn’t reach your server. Check your connection and try again."
    }
  }
  static func transport(_ error: URLError) -> ClientError {
    switch error.code {
    case .appTransportSecurityRequiresSecureConnection: .secureConnectionRequired
    case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
      .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
      .clientCertificateRejected, .clientCertificateRequired:
      .secureConnectionFailed
    case .cannotFindHost, .dnsLookupFailed: .serverNameNotFound
    default: .unavailable
    }
  }
}
enum PlaybackProblem: Error, LocalizedError, Sendable {
  case httpStatus(Int)
  case noSource, audioSessionPolicy, nativeStart, seek, stalled
  var errorDescription: String? {
    switch self {
    case .httpStatus(let code): "Jellyfin rejected this request (HTTP \(code)). Try again."
    case .noSource: "Jellyfin didn’t offer a playable source for this quality."
    case .audioSessionPolicy: "The audio session couldn’t activate for music. Try again."
    case .nativeStart: "The audio player couldn’t start this source. Try again."
    case .seek: "The audio player couldn’t reach that position. Try again."
    case .stalled: "Audio stopped making progress. Tap Play to retry."
    }
  }
}
struct PlaybackFailure: Sendable {
  let id = UUID()
  var detail: ConnectionStepError
  let time: Date
  var diagnostic: DiagnosticRecord? = nil
  func report(appVersion: String) -> String {
    let version =
      appVersion.count <= 24 && appVersion.allSatisfy({ $0.isNumber || ".()-".contains($0) })
      ? appVersion : "unknown"
    return
      "Jukebox playback PB-3\nApp: \(version)\nTime: \(time.ISO8601Format())\nStage: \(detail.step.rawValue)\nKind: \(detail.category.rawValue)\nCode: \(detail.code.map(String.init) ?? "unavailable")\nHTTP: \(detail.status.map(String.init) ?? "unavailable")\nNative log code: \(detail.nativeLogCode.map(String.init) ?? "unavailable (not collected)")"
      + (detail.playbackEvidence.map { "\nPlayback: " + $0.fields } ?? "")
      + (diagnostic.map { "\n" + $0.line } ?? "")
  }
}
struct ConnectionStepError: Error, LocalizedError, Sendable {
  enum Step: String, Sendable {
    case serverInfo = "Checking server"
    case authentication = "Signing in"
    case secureStorage = "Saving secure sign-in"
    case savedConnection = "Saving connection"
    case savingQueue = "Saving queue"
    case identity = "Checking account"
    case restoration = "Restoring saved queue"
    case albums = "Loading albums"
    case playbackValidation = "Validating track"
    case playbackInfo = "Requesting playback source"
    case audioSession = "Activating audio session"
    case preparationDeadline = "Playback preparation deadline"
    case playbackSource = "Preparing track"
    case playbackItem = "Creating audio item"
    case playbackAudio = "Loading audio"
    case playbackProgress = "Playing audio"
  }
  enum Category: String, Equatable, Sendable {
    case network, http, noSource, audioSession, nativeStart, seek, stalled, client, decoding,
      nativeCode, expiredAudioSession, unknown
  }
  let step: Step
  let reason: String
  let status: Int?
  let code: Int?
  let category: Category
  private(set) var nativeLogCode: Int?
  var playbackEvidence: PlaybackEvidence?
  var nativeDiagnostic: DiagnosticRecord?
  let diagnosticDomain: DiagnosticCode.Domain
  init(step: Step, error: Error, status: Int? = nil, nativeLogCode: Int? = nil) {
    if let existing = error as? ConnectionStepError {
      self = existing
      return
    }
    self.step = step
    var observedStatus = status
    var observedCode: Int?
    var kind = Category.unknown
    var domain = DiagnosticCode.Domain.unknown
    if let error = error as? PlaybackProblem {
      domain = .client
      reason = error.errorDescription!
      switch error {
      case .httpStatus(let value):
        observedStatus = value
        kind = .http
      case .noSource: kind = .noSource
      case .audioSessionPolicy: kind = .audioSession
      case .nativeStart: kind = .nativeStart
      case .seek: kind = .seek
      case .stalled: kind = .stalled
      }
    } else if let error = error as? ClientError {
      domain = .client
      kind = .client
      reason = error.errorDescription!
    } else if let error = error as? URLError {
      domain = .url
      kind = .network
      observedCode = error.errorCode
      reason = ClientError.transport(error).errorDescription!
    } else if error is DecodingError {
      kind = .decoding
      reason = "This build couldn’t read the returned data."
    } else {
      let native = error as NSError
      if ["AVFoundationErrorDomain", NSOSStatusErrorDomain].contains(native.domain) {
        domain = native.domain == "AVFoundationErrorDomain" ? .avFoundation : .osStatus
        kind = .nativeCode
        observedCode = native.code
      }
      if native.domain == NSOSStatusErrorDomain && native.code == 0x2173_6573 {
        kind = .expiredAudioSession
        reason = "The iOS audio session expired. Tap Play to resume this track."
      } else if native.domain == "AVFoundationErrorDomain" && native.code == -11819 {
        reason = "Audio services restarted. Tap Play to retry."
      } else {
        reason = "This step couldn’t complete. Please try again."
      }
    }
    diagnosticDomain = domain
    self.status = observedStatus
    self.nativeLogCode = nativeLogCode
    self.code = observedCode
    self.category = kind
  }
  var errorDescription: String? {
    if let status { return "\(step.rawValue) (HTTP \(status)): Jellyfin rejected this request." }
    return "\(step.rawValue): \(reason)"
  }
}
struct ServerAddress: Codable, Hashable, Sendable {
  let url: URL
  init(_ text: String) throws {
    guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      ["https", "http"].contains(c.scheme?.lowercased() ?? ""), c.host?.isEmpty == false,
      c.user == nil, c.password == nil, c.query == nil, c.fragment == nil
    else { throw ClientError.invalidServer }
    c.scheme = c.scheme?.lowercased()
    c.host = c.host?.lowercased()
    while c.path.hasSuffix("/") { c.path.removeLast() }
    guard let url = c.url else { throw ClientError.invalidServer }
    self.url = url
  }
  func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
    guard !path.contains(".."), !path.contains("://"), !path.hasPrefix("//") else {
      throw ClientError.invalidResponse
    }
    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw ClientError.invalidResponse
    }
    c.path += "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if !query.isEmpty {
      c.queryItems = query
      c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
    guard let result = c.url else { throw ClientError.invalidResponse }
    return result
  }
  var supportsCredentials: Bool {
    url.scheme == "https"
      || (url.scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(url.host ?? ""))
  }
  func requireCredentialTransport() throws {
    guard supportsCredentials else { throw ClientError.secureConnectionRequired }
  }
  func acceptMediaPath(_ path: String) throws -> URL {
    let candidate: URL
    if let absolute = URL(string: path), absolute.scheme != nil {
      candidate = absolute
    } else {
      guard !path.hasPrefix("//"), !path.contains("..") else { throw ClientError.invalidResponse }
      guard let base = URL(string: url.absoluteString + "/"),
        let relative = URL(string: path, relativeTo: base)
      else { throw ClientError.invalidResponse }
      candidate = relative.absoluteURL
    }
    guard candidate.scheme == url.scheme, candidate.host == url.host, candidate.port == url.port,
      candidate.user == nil, candidate.password == nil, candidate.fragment == nil
    else { throw ClientError.invalidResponse }
    let basePath = url.path == "/" ? "" : url.path
    guard candidate.path.hasPrefix(basePath + "/"),
      candidate.path.dropFirst(basePath.count).lowercased().hasPrefix("/audio/"),
      !candidate.path.split(separator: "/").contains("..")
    else { throw ClientError.invalidResponse }
    guard var c = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else {
      throw ClientError.invalidResponse
    }
    c.queryItems =
      (c.queryItems ?? []).filter {
        ![
          "api_key", "apikey", "token", "access_token", "x-emby-token", "x-mediabrowser-token",
          "authorization",
        ].contains($0.name.lowercased())
      }
    guard let result = c.url else { throw ClientError.invalidResponse }
    return result
  }
}
struct JellyfinServerInfo: Codable, Hashable, Sendable {
  let name: String?
  let version: String

  enum CodingKeys: String, CodingKey {
    case name = "ServerName"
    case version = "Version"
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(String.self, forKey: .version)
    let label = try? values.decode(String.self, forKey: .name).trimmingCharacters(
      in: .whitespacesAndNewlines)
    name = label.flatMap { (1...256).contains($0.count) ? $0 : nil }
  }
}
struct Connection: Identifiable, Codable, Hashable, Sendable {
  let server: ServerAddress
  let userID: String
  let username: String
  var serverInfo: JellyfinServerInfo? = nil
  var id: String {
    SHA256.hash(data: Data((server.url.absoluteString + "\n" + userID).utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }
}
enum ServerCompatibility {
  static let verifiedFamilies: Set<String> = ["12.1", "12.2", "12.4"]
  static var supportedVersions: String {
    verifiedFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.formatted(
      .list(type: .and))
  }
  static func accepts(_ version: String, families: Set<String> = verifiedFamilies) -> Bool {
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    guard (2...3).contains(parts.count),
      parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) })
    else { return false }
    return families.contains(parts[0] + "." + parts[1])
  }
}
