#if DEBUG
  import Foundation

  actor QuickConnectFixtureHTTP: HTTPTransport {
    private let codesEnabled: Bool
    private var issued = 0
    private var polls = 0
    private var secret: String { "invented-challenge-\(issued)" }
    private var offlineOnFirstReconnect: Bool
    init(codesEnabled: Bool, offlineOnFirstReconnect: Bool = false) {
      self.codesEnabled = codesEnabled
      self.offlineOnFirstReconnect = offlineOnFirstReconnect
    }

    static func saveExampleConnections(to storage: LibraryStorage, vault: any TokenVault)
      async throws
    {
      let accounts = try [
        "https://music.invalid/jellyfin", "http://music.invalid/jellyfin",
        "https://offline.invalid/jellyfin",
      ].map {
        Connection(
          server: try ServerAddress($0), userID: "fixture-listener", username: "Demo listener")
      }
      for account in accounts { try await vault.write("invented-session", account: account.id) }
      try await storage.saveConnections(accounts)
    }

    func send(_ request: URLRequest) async throws -> HTTPReply {
      try Task.checkCancellation()
      if request.url?.host == "offline.invalid" { throw URLError(.cannotConnectToHost) }
      guard let url = request.url, url.scheme == "https", url.host == "music.invalid",
        url.path.hasPrefix("/jellyfin/")
      else { throw ClientError.invalidServer }
      let path = String(url.path.dropFirst("/jellyfin/".count))
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let body: Any
      switch (request.httpMethod, path) {
      case ("GET", "System/Info/Public"):
        body = ["Version": "12.1.0", "ServerName": "Sample music server"]
      case ("GET", "QuickConnect/Enabled"):
        body = codesEnabled
      case ("POST", "QuickConnect/Initiate"):
        guard codesEnabled else { return HTTPReply(data: Data(), status: 403) }
        issued += 1
        polls = 0
        body = ["Code": String(120_000 + issued), "Secret": secret]
      case ("GET", "QuickConnect/Connect"):
        guard query == [.init(name: "secret", value: secret)] else {
          throw ClientError.invalidResponse
        }
        polls += 1
        body = ["Authenticated": polls >= 2]
      case ("POST", "Users/AuthenticateWithQuickConnect"):
        guard polls >= 2, let data = request.httpBody,
          try JSONDecoder().decode([String: String].self, from: data)["Secret"] == secret
        else { throw ClientError.unauthorized }
        body = signedInAccount
      case ("POST", "Users/AuthenticateByName"):
        guard let data = request.httpBody,
          try JSONDecoder().decode([String: String].self, from: data) == [
            "Username": "Listener", "Pw": "fixture",
          ]
        else { return HTTPReply(data: Data(), status: 401) }
        body = signedInAccount
      case ("GET", "Users/Me"):
        if offlineOnFirstReconnect {
          offlineOnFirstReconnect = false
          try await Task.sleep(for: .seconds(6))
          throw URLError(.notConnectedToInternet)
        }
        body = ["Id": "fixture-listener", "Name": "Demo listener"]
      case ("POST", "QuickConnect/Authorize"):
        guard
          request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"invented-session\"")
            == true
        else { throw ClientError.unauthorized }
        body = query == [.init(name: "code", value: "246810")]
      case ("GET", "UserViews"):
        body = [
          "Items": [
            ["Id": "music", "Name": "Music", "Type": "CollectionFolder", "CollectionType": "music"]
          ]
        ]
      case ("GET", "Items"), ("GET", "Artists"), ("GET", "Artists/AlbumArtists"),
        ("GET", "Genres"):
        body = ["Items": [], "TotalRecordCount": 0]
      case ("GET", "Items/Filters"):
        body = ["Years": [Int]()]
      default:
        return HTTPReply(data: Data(), status: 404)
      }
      return HTTPReply(
        data: try JSONSerialization.data(withJSONObject: body, options: .fragmentsAllowed),
        status: 200)
    }
    private var signedInAccount: [String: Any] {
      [
        "User": ["Id": "fixture-listener", "Name": "Demo listener"],
        "AccessToken": "invented-session",
      ]
    }
  }
#endif
