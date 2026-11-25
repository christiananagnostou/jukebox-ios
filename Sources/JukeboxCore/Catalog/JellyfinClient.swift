import Foundation

private let musicDetailKey = CodingUserInfoKey(rawValue: "music-details")!

private typealias ItemPage = CatalogWirePage<ItemDTO>

private struct CatalogWirePage<Row: Decodable>: Decodable {
  let items: [Row]
  enum CodingKeys: String, CodingKey { case items = "Items" }
}
private struct GenreRow: Decodable {
  let genre: HomeGenre?
  enum CodingKeys: String, CodingKey {
    case type = "Type"
    case id = "Id"
    case name = "Name"
  }
  init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    guard try fields.decodeIfPresent(String.self, forKey: .type) == "MusicGenre" else {
      genre = nil
      return
    }
    let id = try fields.decode(String.self, forKey: .id)
    let name = try fields.decode(String.self, forKey: .name).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard PlaylistSummaryDTO.validID(id), !name.isEmpty else { throw ClientError.invalidResponse }
    genre = HomeGenre(id: id, name: name)
  }
}
private struct ItemDTO: Decodable {
  let id: String
  let name: String?
  let kind: String?
  let sortName: String?
  let guestIDs: Set<String>
  let artists: [String]?
  let albumArtist: String?
  let album: String?
  let runTimeTicks: Double?
  let indexNumber: Int?
  let imageTags: [String: String]?
  let albumID: String?
  let albumPrimaryImageTag: String?
  let credits: [MusicCredit]?
  let details: MusicDetails?
  let favorite: Bool?
  let hasPlayHistory: Bool
  let hasLyrics: Bool?
  enum CodingKeys: String, CodingKey {
    case id = "Id"
    case name = "Name"
    case kind = "Type"
    case sortName = "SortName"
    case artists = "Artists"
    case albumArtist = "AlbumArtist"
    case album = "Album"
    case runTimeTicks = "RunTimeTicks"
    case indexNumber = "IndexNumber"
    case imageTags = "ImageTags"
    case albumID = "AlbumId"
    case albumPrimaryImageTag = "AlbumPrimaryImageTag"
    case albumArtists = "AlbumArtists"
    case artistItems = "ArtistItems"
    case year = "ProductionYear"
    case genres = "Genres"
    case overview = "Overview"
    case disc = "ParentIndexNumber"
    case studios = "Studios"
    case people = "People"
    case providerIDs = "ProviderIds"
    case externalURLs = "ExternalUrls"
    case userData = "UserData"
    case hasLyrics = "HasLyrics"
  }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    kind = try c.decodeIfPresent(String.self, forKey: .kind)
    guard ["MusicAlbum", "MusicArtist", "Audio"].contains(kind ?? "") else {
      id = ""
      sortName = nil
      guestIDs = []
      name = nil
      artists = nil
      albumArtist = nil
      album = nil
      runTimeTicks = nil
      indexNumber = nil
      imageTags = nil
      albumID = nil
      albumPrimaryImageTag = nil
      credits = nil
      details = nil
      favorite = nil
      hasPlayHistory = false
      hasLyrics = nil
      return
    }
    struct Named: Decodable {
      let name: String
      enum CodingKeys: String, CodingKey { case name = "Name" }
    }
    struct Person: Decodable {
      let name: String
      let type: String
      enum CodingKeys: String, CodingKey {
        case name = "Name"
        case type = "Type"
      }
    }
    struct External: Decodable {
      let url: URL
      enum CodingKeys: String, CodingKey { case url = "Url" }
    }
    struct User: Decodable {
      let isFavorite: Bool?
      enum CodingKeys: String, CodingKey { case isFavorite = "IsFavorite" }
    }
    var links: [MusicProviderLink] = []
    var labels: [String] = []
    var roleCredits: [MusicRoleCredit] = []
    if decoder.userInfo[musicDetailKey] as? Bool == true {
      links = ((try? c.decodeIfPresent([External].self, forKey: .externalURLs)) ?? []).compactMap {
        MusicProviderLink(title: "", url: $0.url)
      }
      let providers = (try? c.decodeIfPresent([String: String].self, forKey: .providerIDs)) ?? [:]
      for (key, path) in [
        ("MusicBrainzArtist", "artist"), ("MusicBrainzAlbum", "release"),
        ("MusicBrainzReleaseGroup", "release-group"), ("MusicBrainzTrack", "recording"),
      ] {
        if let value = providers[key], let id = UUID(uuidString: value),
          let url = URL(
            string: "https://musicbrainz.org/" + path + "/" + id.uuidString.lowercased()),
          let link = MusicProviderLink(title: "", url: url)
        {
          links.append(link)
        }
      }
      labels =
        kind == "MusicAlbum"
        ? ((try? c.decodeIfPresent([Named].self, forKey: .studios)) ?? []).map(\.name) : []
      roleCredits = ((try? c.decodeIfPresent([Person].self, forKey: .people)) ?? []).compactMap {
        MusicRoleCredit(name: $0.name, role: $0.type)
      }
    }
    favorite = (try? c.decodeIfPresent(User.self, forKey: .userData))?.isFavorite
    if kind == "Audio", decoder.userInfo[artistPlaysKey] as? Bool == true {
      struct Plays: Decodable {
        let playCount: Int?
        enum CodingKeys: String, CodingKey { case playCount = "PlayCount" }
      }
      hasPlayHistory = ((try? c.decodeIfPresent(Plays.self, forKey: .userData))?.playCount ?? 0) > 0
    } else {
      hasPlayHistory = false
    }
    hasLyrics = kind == "Audio" ? (try? c.decodeIfPresent(Bool.self, forKey: .hasLyrics)) : nil
    details = MusicDetails(
      year: try? c.decodeIfPresent(Int.self, forKey: .year),
      genres: (try? c.decodeIfPresent([String].self, forKey: .genres)) ?? [],
      overview: try? c.decodeIfPresent(String.self, forKey: .overview),
      disc: try? c.decodeIfPresent(Int.self, forKey: .disc),
      labels: labels, credits: roleCredits, links: links)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name)
    artists = try c.decodeIfPresent([String].self, forKey: .artists)
    albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist)
    album = try c.decodeIfPresent(String.self, forKey: .album)
    runTimeTicks = try c.decodeIfPresent(Double.self, forKey: .runTimeTicks)
    indexNumber = try c.decodeIfPresent(Int.self, forKey: .indexNumber)
    imageTags = try c.decodeIfPresent([String: String].self, forKey: .imageTags)
    albumID = try c.decodeIfPresent(String.self, forKey: .albumID)
    albumPrimaryImageTag = try c.decodeIfPresent(String.self, forKey: .albumPrimaryImageTag)
    struct Credit: Decodable {
      let id: String
      let name: String
      enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
      }
    }
    sortName = try? c.decodeIfPresent(String.self, forKey: .sortName)
    let albumCredits = try c.decodeIfPresent([Credit].self, forKey: .albumArtists) ?? []
    let trackCredits = try c.decodeIfPresent([Credit].self, forKey: .artistItems) ?? []
    guestIDs = Set(trackCredits.map(\.id)).subtracting(albumCredits.map(\.id))
    let references = albumCredits + trackCredits
    var seen = Set<String>()
    credits = references.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }.map {
      MusicCredit(id: $0.id, name: $0.name)
    }

  }
  var item: MusicItem {
    MusicItem(
      id: id, title: name ?? "Untitled", artist: artists?.first ?? albumArtist ?? "Unknown artist",
      album: album ?? name ?? "", duration: max(0, (runTimeTicks ?? 0) / 10_000_000),
      number: indexNumber ?? 0,
      kind: kind ?? "",
      imageID: imageTags?["Primary"] != nil ? id : (kind == "MusicArtist" ? nil : albumID),
      imageTag: imageTags?["Primary"] ?? (kind == "MusicArtist" ? nil : albumPrimaryImageTag),
      albumID: albumID,
      artistCredits: credits, details: details, favorite: favorite, hasLyrics: hasLyrics)
  }
}
private let playlistDetailsKey = CodingUserInfoKey(rawValue: "playlist-track-details")!
private let artistPlaysKey = CodingUserInfoKey(rawValue: "artist-song-plays")!

private struct ArtistDirectoryCursor {
  struct Stream {
    var rows: ArraySlice<ItemDTO> = []
    var offset = 0
    var finished = false
    var lastFullPage: [String]?
    var needsPage: Bool { rows.isEmpty && !finished }
    mutating func accept(_ page: [ItemDTO], limit: Int) throws {
      finished = page.count < limit
      let ids = page.map(\.id)
      guard finished || ids != lastFullPage else { throw ClientError.invalidResponse }
      lastFullPage = finished ? nil : ids
      offset += page.count
      rows = page.filter { $0.kind == "MusicArtist" && !$0.id.isEmpty }[...]
    }
  }
  var streams = [Stream(), Stream()]
  var position = 0
  var seen: Set<String> = []
  mutating func pop(descending: Bool) -> ItemDTO? {
    guard let album = streams[0].rows.first else { return streams[1].rows.popFirst() }
    guard let track = streams[1].rows.first else { return streams[0].rows.popFirst() }
    if album.id == track.id {
      streams[1].rows.removeFirst()
      return streams[0].rows.popFirst()
    }
    let order = (album.sortName ?? album.name ?? "").localizedCaseInsensitiveCompare(
      track.sortName ?? track.name ?? "")
    let albumFirst = order == .orderedSame ? album.id < track.id : order == .orderedAscending
    return streams[albumFirst != descending ? 0 : 1].rows.popFirst()
  }
}
private struct PlaylistFolderIndex {
  struct Location {
    let offset: Int
    let album: String?
  }
  var total: Int
  var locations: [String: Location]

  func windows(for ids: Set<String>) -> [Range<Int>]? {
    guard total > 500, !ids.isEmpty, ids.count <= 256 else { return nil }
    let offsets = ids.compactMap { locations[$0]?.offset }.sorted()
    guard offsets.count == ids.count else { return nil }
    var windows: [Range<Int>] = []
    for offset in offsets {
      if let last = windows.last, offset - last.upperBound <= 40, offset - last.lowerBound < 500 {
        windows[windows.count - 1] = last.lowerBound..<(offset + 1)
      } else {
        windows.append(offset..<(offset + 1))
      }
    }
    guard windows.count <= 32, windows.reduce(0, { $0 + $1.count }) < min(total / 2, 2_000)
    else { return nil }
    return windows
  }
}
private struct RootedPlaylistSong: Decodable, Sendable {
  let id: String
  let album: String?
  let track: MusicItem?
  private enum CodingKeys: String, CodingKey {
    case kind = "Type"
    case id = "Id"
    case album = "AlbumId"
  }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard try c.decode(String.self, forKey: .kind) == "Audio" else {
      throw ClientError.invalidResponse
    }
    let raw = try c.decode(String.self, forKey: .id)
    guard PlaylistSummaryDTO.validID(raw) else { throw ClientError.invalidResponse }
    id = playlistTrackKey(raw)
    album = try c.decodeIfPresent(String.self, forKey: .album).flatMap {
      PlaylistSummaryDTO.validID($0) ? $0 : nil
    }
    if let wanted = decoder.userInfo[playlistDetailsKey] as? Set<String>, wanted.contains(id) {
      track = try ItemDTO(from: decoder).item
    } else if decoder.userInfo[playlistDetailsKey] as? Bool == true {
      track = try? ItemDTO(from: decoder).item
    } else {
      track = nil
    }
  }
}
actor JellyfinClient {
  let connection: Connection
  private let token: String
  private let transport: any HTTPTransport
  private let deviceID: String
  private var firstVerifiedPlaylist: (library: String, id: String)?
  private var playlistFolderIndexes: [String: PlaylistFolderIndex] = [:]
  private var musicRoots: [MusicLibrary]?
  private var artistCursors: [Bool: (query: CatalogQuery, cursor: ArtistDirectoryCursor)] = [:]
  private var musicRootRequest = UUID()
  private var yearGeneration = UUID()
  private var yearFacet: (library: String, generation: UUID, value: CatalogYearFacet)?
  init(
    connection: Connection, token: String, deviceID: String,
    transport: any HTTPTransport = LiveHTTP()
  ) throws {
    try connection.server.requireCredentialTransport()
    guard !token.isEmpty, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 34 && $0 != 92 })
    else { throw ClientError.invalidResponse }
    self.connection = connection
    self.token = token
    self.deviceID = deviceID
    self.transport = transport
  }
  static func login(
    server: ServerAddress, username: String, password: String, deviceID: String,
    transport: any HTTPTransport = LiveHTTP(),
    allowedFamilies: Set<String> = ServerCompatibility.verifiedFamilies
  ) async throws -> (Connection, String) {
    try await JellyfinAuthentication(
      server: server, deviceID: deviceID, transport: transport, allowedFamilies: allowedFamilies
    ).password(username: username, password: password)
  }
  static func authorization(device: String) -> String {
    let safe = device.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    return
      "MediaBrowser Client=\"Jukebox iOS\", Device=\"Jukebox\", DeviceId=\"\(safe)\", Version=\"0.1\""
  }
  private var authenticatedHeader: String {
    Self.authorization(device: deviceID) + ", Token=\"\(token)\""
  }
  func endSession() async throws {
    _ = try await request("Sessions/Logout", method: "POST")
  }
  private static func status(_ code: Int) throws {
    if code == 401 { throw ClientError.unauthorized }
    if [403, 404].contains(code) { throw ClientError.forbidden }
    guard (200..<300).contains(code) else { throw PlaybackProblem.httpStatus(code) }
  }
  private func request(
    _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil, method: String? = nil,
    allowMissing: Bool = false, jpeg: Data? = nil
  )
    async throws -> Data
  {
    var request = URLRequest(url: try connection.server.endpoint(path, query: query))
    request.setValue(authenticatedHeader, forHTTPHeaderField: "Authorization")
    if let body {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    if let jpeg {
      request.httpMethod = "POST"
      request.httpBody = jpeg.base64EncodedData()
      request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
    }
    if let method { request.httpMethod = method }
    let response = try await transport.send(request)
    try Task.checkCancellation()
    if allowMissing, response.status == 404 { return Data() }
    try Self.status(response.status)
    return response.data
  }
  func verifyIdentity() async throws {
    let data = try await request("Users/Me")
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = object["Id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw ClientError.invalidResponse }
    guard id == connection.userID else { throw ClientError.unauthorized }
  }
  private func page(_ query: [URLQueryItem]) async throws -> [MusicItem] {
    let data = try await request(
      "Items",
      query: query + [
        .init(name: "UserId", value: connection.userID),
        .init(name: "Fields", value: "PrimaryImageAspectRatio,Artists,AlbumArtist,AlbumId"),
        .init(name: "EnableTotalRecordCount", value: "false"),
      ])
    return try JSONDecoder().decode(ItemPage.self, from: data).items.filter { !$0.id.isEmpty }.map(
      \.item)
  }
  private func tracksInVerifiedAlbum(_ albumID: String) async throws -> [MusicItem] {
    var result: [MusicItem] = []
    var seen = Set<String>()
    let start = ContinuousClock.now
    while true {
      try Task.checkCancellation()
      guard start.duration(to: .now) < .seconds(25) else { throw ClientError.unavailable }
      let batch = try await page([
        .init(name: "ParentId", value: albumID), .init(name: "IncludeItemTypes", value: "Audio"),
        .init(name: "Recursive", value: "true"),
        .init(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
        .init(name: "StartIndex", value: String(result.count)), .init(name: "Limit", value: "200"),
      ])
      guard batch.allSatisfy({ $0.kind == "Audio" && seen.insert($0.id).inserted }) else {
        throw ClientError.invalidResponse
      }
      result += batch
      if batch.count < 200 { return result }
    }
  }
  func validate(ids: [String]) async throws -> [MusicItem] {
    var requested = Set<String>()
    let ids = ids.filter { requested.insert($0).inserted }
    var result: [MusicItem] = []
    var seen = Set<String>()
    guard !ids.isEmpty else { return [] }
    let batchSize = 40
    let windowSize = batchSize * 4
    let roots = try await musicLibraries(refresh: false)
    let generation = musicRootRequest
    for root in roots {
      for start in stride(from: 0, to: ids.count, by: windowSize) {
        try Task.checkCancellation()
        let end = min(start + windowSize, ids.count)
        let pages = try await withThrowingTaskGroup(of: (Int, [MusicItem]).self) { group in
          for offset in stride(from: start, to: end, by: batchSize) {
            let batch = Array(ids[offset..<min(offset + batchSize, end)])
            group.addTask {
              let query = CatalogQuery(library: root.id, category: .songs, ids: batch)
              return (offset, try await self.catalog(query))
            }
          }
          var pages: [(Int, [MusicItem])] = []
          for try await page in group { pages.append(page) }
          return pages.sorted { $0.0 < $1.0 }
        }
        try Task.checkCancellation()
        guard generation == musicRootRequest else { throw CancellationError() }
        for (_, items) in pages {
          for item in items where requested.contains(item.id) && seen.insert(item.id).inserted {
            result.append(item)
          }
        }
      }
    }
    return result
  }
  private func requireMediaCurrent(
    library: String, generation: UUID?, isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws {
    try Task.checkCancellation()
    guard await isCurrent() else { throw CancellationError() }
    try Task.checkCancellation()
    if let generation {
      guard musicRootRequest == generation,
        musicRoots?.contains(where: { $0.id == library }) == true
      else { throw CancellationError() }
    }
  }
  func rejectMediaError(
    library: String, generation: UUID?, step: ConnectionStepError.Step,
    isCurrent: @escaping @MainActor @Sendable () -> Bool,
    lazyError: @Sendable () -> any Error
  ) async throws -> Never {
    try await requireMediaCurrent(library: library, generation: generation, isCurrent: isCurrent)
    let error = lazyError()
    if error is CancellationError { throw error }
    if error as? ClientError == .unauthorized || error as? ClientError == .forbidden
      || error as? ClientError == .invalidResponse
    {
      throw error
    }
    throw ConnectionStepError(step: step, error: error)
  }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    var step = ConnectionStepError.Step.playbackValidation
    var generation: UUID?
    do {
      try await requireMediaCurrent(library: library, generation: nil, isCurrent: isCurrent)
      guard !library.isEmpty, !trackID.isEmpty else { throw ClientError.forbidden }
      let roots = try await loadMusicLibraries(refresh: false, isCurrent: isCurrent)
      try await requireMediaCurrent(library: library, generation: nil, isCurrent: isCurrent)
      guard roots.contains(where: { $0.id == library }),
        musicRoots?.contains(where: { $0.id == library }) == true
      else { throw ClientError.forbidden }
      generation = musicRootRequest
      try await requireMediaCurrent(library: library, generation: generation, isCurrent: isCurrent)
      let proof = try await request(
        "Items",
        query: [
          .init(name: "ParentId", value: library), .init(name: "UserId", value: connection.userID),
          .init(name: "Ids", value: trackID), .init(name: "IncludeItemTypes", value: "Audio"),
          .init(name: "Recursive", value: "true"), .init(name: "Limit", value: "1"),
          .init(name: "EnableTotalRecordCount", value: "false"),
        ])
      try await requireMediaCurrent(library: library, generation: generation, isCurrent: isCurrent)
      let rows = try JSONDecoder().decode(ItemPage.self, from: proof).items
      guard rows.count == 1, rows[0].kind == "Audio", rows[0].id == trackID else {
        throw ClientError.forbidden
      }
      step = .playbackInfo
      let data = try await request(
        "Items/\(trackID)/PlaybackInfo",
        body: JellyfinPlaybackSource.requestBody(userID: connection.userID, quality: quality))
      try await requireMediaCurrent(library: library, generation: generation, isCurrent: isCurrent)
      step = .playbackSource
      return try JellyfinPlaybackSource.parse(
        data, connection: connection, authorization: authenticatedHeader, trackID: trackID,
        quality: quality)
    } catch let caughtError {
      try await rejectMediaError(
        library: library, generation: generation, step: step, isCurrent: isCurrent,
        lazyError: { caughtError })
    }
  }
  func artwork(item: MusicItem) async throws -> Data? {
    guard let id = item.imageID, item.imageTag != nil else { return nil }
    return try await request(
      "Items/\(id)/Images/Primary",
      query: [.init(name: "maxWidth", value: "600"), .init(name: "tag", value: item.imageTag)])
  }
}

enum JellyfinPlaybackSource {
  static func requestBody(userID: String, quality: StreamQuality) -> [String: Any] {
    let reduced = quality != .original
    let profile: [String: Any] = [
      "Name": "Jukebox iOS", "MaxStreamingBitrate": quality.bitrate,
      "MusicStreamingTranscodingBitrate": quality.bitrate,
      "DirectPlayProfiles": reduced
        ? [] : [["Container": "flac,mp3,aac,m4a,wav,alac,aiff", "Type": "Audio"]],
      "TranscodingProfiles": [
        [
          "Container": "mp3", "AudioCodec": "mp3", "Type": "Audio", "Context": "Streaming",
          "Protocol": "http", "EstimateContentLength": true, "TranscodeSeekInfo": "Bytes",
          "EnableAudioVbrEncoding": false,
        ]
      ],
    ]
    return [
      "UserId": userID, "DeviceProfile": profile,
      "MaxStreamingBitrate": quality.bitrate, "EnableDirectPlay": !reduced,
      "EnableDirectStream": false, "EnableTranscoding": reduced,
      "AllowAudioStreamCopy": !reduced,
    ]
  }
  static func parse(
    _ data: Data, connection: Connection, authorization: String, trackID: String,
    quality: StreamQuality
  ) throws -> MediaSource {
    let reduced = quality != .original
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let sources = root["MediaSources"] as? [[String: Any]], !sources.isEmpty
    else { throw ClientError.invalidResponse }
    let support = reduced ? "SupportsTranscoding" : "SupportsDirectPlay"
    guard
      let source = try sources.first(where: {
        guard let id = $0["Id"] as? String, !id.isEmpty else { throw ClientError.invalidResponse }
        return $0[support] as? Bool == true
      })
    else { throw PlaybackProblem.noSource }
    let url: URL
    if reduced {
      guard let path = source["TranscodingUrl"] as? String
      else { throw PlaybackProblem.noSource }
      url = try connection.server.acceptMediaPath(path)
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      guard
        items.contains(where: {
          $0.name.lowercased() == "audiobitrate" && $0.value == String(quality.bitrate)
        })
      else { throw ClientError.invalidResponse }
    } else {
      guard let sourceID = source["Id"] as? String else { throw ClientError.invalidResponse }
      url = try connection.server.endpoint(
        "Audio/\(trackID)/stream",
        query: [
          .init(name: "static", value: "true"), .init(name: "UserId", value: connection.userID),
          .init(name: "MediaSourceId", value: sourceID),
        ])
    }
    let container = (source["Container"] as? String)?.lowercased()
    let streams = source["MediaStreams"] as? [[String: Any]] ?? []
    let flac =
      container == "flac"
      || streams.contains {
        ($0["Type"] as? String)?.lowercased() == "audio"
          && ($0["Codec"] as? String)?.lowercased() == "flac"
      }
    let runtime = (source["RunTimeTicks"] as? Double).map { $0 / 10_000_000 }
    let maximumOrigin = runtime.flatMap { $0.isFinite && $0 > 0 ? max(0, $0 - 5) : nil }
    return try MediaSource(
      url: url, quality: quality, preciseSeekingRequired: !reduced && flac, serverTimeSeek: reduced,
      maximumTimeOrigin: maximumOrigin, serverDuration: runtime, authorization: authorization
    )
    .starting(at: 0)
  }
}

private struct MusicViews: Decodable {
  let items: [View]
  enum CodingKeys: String, CodingKey { case items = "Items" }
  struct View: Decodable {
    let library: MusicLibrary?
    enum CodingKeys: String, CodingKey {
      case collection = "CollectionType"
      case id = "Id"
      case name = "Name"
      case type = "Type"
    }
    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      guard try c.decodeIfPresent(String.self, forKey: .collection) == "music" else {
        library = nil
        return
      }
      guard ["CollectionFolder", "UserView"].contains(try c.decode(String.self, forKey: .type))
      else {
        library = nil
        return
      }
      library = MusicLibrary(
        id: try c.decode(String.self, forKey: .id), title: try c.decode(String.self, forKey: .name))
    }
  }
}
extension JellyfinClient: QuickConnectAuthorizing {
  func authorizeQuickConnect(
    _ code: QuickConnectCode, isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
  ) async throws {
    try Task.checkCancellation()
    var approval = URLRequest(
      url: try connection.server.endpoint(
        "QuickConnect/Authorize", query: [.init(name: "code", value: code.digits)]))
    approval.httpMethod = "POST"
    approval.cachePolicy = .reloadIgnoringLocalCacheData
    approval.setValue(authenticatedHeader, forHTTPHeaderField: "Authorization")
    approval.setValue("application/json", forHTTPHeaderField: "Accept")
    guard await isCurrent() else { throw QuickConnectError.accountChanged }
    try Task.checkCancellation()
    let reply: HTTPReply
    do { reply = try await transport.send(approval) } catch {
      try Task.checkCancellation()
      throw QuickConnectError.unconfirmed
    }
    try Task.checkCancellation()
    switch reply.status {
    case 200:
      guard let accepted = try? JSONDecoder().decode(Bool.self, from: reply.data) else {
        throw QuickConnectError.unconfirmed
      }
      guard accepted else { throw QuickConnectError.invalidCode }
    case 400, 404: throw QuickConnectError.invalidCode
    case 401:
      let enabled = try await transport.send(
        URLRequest(url: try connection.server.endpoint("QuickConnect/Enabled")))
      try Task.checkCancellation()
      if enabled.status == 200, (try? JSONDecoder().decode(Bool.self, from: enabled.data)) == false
      {
        throw QuickConnectError.disabled
      }
      throw ClientError.unauthorized
    case 403: throw QuickConnectError.denied
    default: throw QuickConnectError.unconfirmed
    }
  }
}

extension JellyfinClient: MusicCatalogServing {
  func musicLibraries(refresh: Bool = false) async throws -> [MusicLibrary] {
    try await loadMusicLibraries(refresh: refresh, isCurrent: { true })
  }
  private func loadMusicLibraries(
    refresh: Bool, isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> [MusicLibrary] {
    try Task.checkCancellation()
    guard await isCurrent() else { throw CancellationError() }
    try Task.checkCancellation()
    if !refresh, let musicRoots { return musicRoots }
    let ticket = UUID()
    musicRootRequest = ticket
    playlistFolderIndexes.removeAll()
    artistCursors.removeAll()
    firstVerifiedPlaylist = nil
    yearGeneration = UUID()
    yearFacet = nil
    defer {
      if musicRootRequest == ticket {
        yearGeneration = UUID()
        yearFacet = nil
      }
    }
    do {
      let data = try await request(
        "UserViews",
        query: [
          .init(name: "UserId", value: connection.userID),
          .init(name: "IncludeExternalContent", value: "false"),
        ])
      try Task.checkCancellation()
      guard await isCurrent() else { throw CancellationError() }
      try Task.checkCancellation()
      guard musicRootRequest == ticket else { throw CancellationError() }
      let views = try JSONDecoder().decode(MusicViews.self, from: data).items
      guard views.count <= 128 else { throw ClientError.invalidResponse }
      let roots = views.compactMap(\.library)
      guard Set(roots.map(\.id)).count == roots.count else { throw ClientError.invalidResponse }
      musicRoots = roots
      return roots
    } catch {
      try Task.checkCancellation()
      guard await isCurrent() else { throw CancellationError() }
      try Task.checkCancellation()
      guard musicRootRequest == ticket else { throw CancellationError() }
      throw error
    }
  }
  func catalogYears(library: String) async throws -> CatalogYearFacet {
    guard try await musicLibraries(refresh: false).contains(where: { $0.id == library })
    else { throw ClientError.forbidden }
    let generation = yearGeneration
    if let cached = yearFacet, cached.library == library, cached.generation == generation {
      return cached.value
    }
    let data = try await request(
      "Items/Filters",
      query: [
        .init(name: "UserId", value: connection.userID),
        .init(name: "ParentId", value: library),
        .init(name: "IncludeItemTypes", value: "MusicAlbum,Audio"),
      ])
    guard !Task.isCancelled, generation == yearGeneration,
      musicRoots?.contains(where: { $0.id == library }) == true
    else { throw CancellationError() }
    struct Facets: Decodable {
      let years: [Int]?
      enum CodingKeys: String, CodingKey { case years = "Years" }
    }
    let value = try CatalogYearFacet(JSONDecoder().decode(Facets.self, from: data).years ?? [])
    yearFacet = (library, generation, value)
    return value
  }
  func homeGenres(library: String) async throws -> [HomeGenre] {
    guard try await musicLibraries(refresh: false).contains(where: { $0.id == library })
    else { throw ClientError.forbidden }
    let generation = musicRootRequest
    let query: [URLQueryItem] = [
      .init(name: "ParentId", value: library), .init(name: "UserId", value: connection.userID),
      .init(name: "IncludeItemTypes", value: "MusicAlbum"), .init(name: "Recursive", value: "true"),
      .init(name: "Limit", value: "6"), .init(name: "SortBy", value: "Random"),
      .init(name: "EnableImages", value: "false"), .init(name: "EnableUserData", value: "false"),
      .init(name: "EnableTotalRecordCount", value: "false"),
    ]
    let data = try await request("Genres", query: query)
    try Task.checkCancellation()
    guard generation == musicRootRequest else { throw CancellationError() }
    let rows = try JSONDecoder().decode(CatalogWirePage<GenreRow>.self, from: data).items
    guard rows.count <= 6 else { throw ClientError.invalidResponse }
    var seen = Set<String>()
    let genres = rows.compactMap(\.genre).filter { seen.insert($0.id).inserted }
    var result: [HomeGenre] = []
    for var genre in genres {
      try Task.checkCancellation()
      guard generation == musicRootRequest else { throw CancellationError() }
      do {
        genre.covers = try await readCatalogPage(
          CatalogQuery(library: library, shelf: .discover, genreID: genre.id), limit: 4
        ).items
      } catch let error as ClientError where error == .forbidden || error == .unauthorized {
        throw error
      } catch {
        try Task.checkCancellation()
      }
      result.append(genre)
    }
    guard generation == musicRootRequest else { throw CancellationError() }
    return result
  }
  func catalog(_ input: CatalogQuery) async throws -> [MusicItem] {
    try await catalogPage(input).items
  }
  func catalogPage(_ input: CatalogQuery) async throws -> CatalogPage {
    guard input.ids.count <= 40 else { throw ClientError.forbidden }
    return try await readCatalogPage(input, limit: input.shelf == nil ? 40 : 12)
  }
  private func readCatalogPage(_ input: CatalogQuery, limit: Int) async throws -> CatalogPage {
    guard input.offset >= 0, input.search.count <= 128,
      !input.rankArtistSongs
        || (input.category == .songs && input.artist?.isEmpty == false && !input.appearancesOnly
          && input.shelf == nil),
      !input.appearancesOnly || (input.category == .songs && input.artist?.isEmpty == false),
      input.options.isValid(for: input.category),
      try await musicLibraries(refresh: false).contains(where: { $0.id == input.library })
    else { throw ClientError.forbidden }
    if let genre = input.genreID {
      guard input.category == .albums, PlaylistSummaryDTO.validID(genre) else {
        throw ClientError.forbidden
      }
    }
    guard input.shelf == nil || input.category == input.shelf?.category else {
      throw ClientError.forbidden
    }
    let itemTypes: String
    switch input.shelf {
    case .artists: itemTypes = "Audio,MusicAlbum"
    case .favorites: itemTypes = "MusicAlbum,Audio"
    default: itemTypes = input.category == .artists ? "MusicAlbum" : input.category.itemType
    }
    var query: [URLQueryItem] = [
      .init(name: "ParentId", value: input.library),
      .init(name: "UserId", value: connection.userID),
      .init(name: "Recursive", value: "true"),
      .init(name: "StartIndex", value: String(input.offset)),
      .init(name: "Limit", value: String(limit)),
      .init(
        name: "IncludeItemTypes",
        value: itemTypes),
      .init(
        name: "SortBy",
        value: input.appearancesOnly
          ? "Album,ParentIndexNumber,IndexNumber,SortName" : input.options.sort.field),
      .init(name: "SortOrder", value: input.options.sort.order),
      .init(name: "Fields", value: "Artists,AlbumArtist,AlbumId,PrimaryImageAspectRatio"),
      .init(name: "EnableTotalRecordCount", value: "false"),
    ]
    if input.category != .artists, !input.options.years.isAll {
      let facet = try await catalogYears(library: input.library)
      guard let years = try facet.wireYears(for: input.options.years), !years.isEmpty
      else { return CatalogPage(items: [], rawCount: 0) }
      query.append(.init(name: "Years", value: years))
    }
    if input.includeDetails {
      query.removeAll { $0.name == "Fields" }
      query.append(
        .init(
          name: "Fields",
          value:
            "Artists,AlbumArtist,AlbumId,PrimaryImageAspectRatio,Overview,Genres,Studios,People,ProviderIds,ExternalUrls"
        ))
    }
    if input.options.favoritesOnly {
      query.append(
        .init(
          name: input.category == .artists ? "IsFavorite" : "Filters",
          value: input.category == .artists ? "true" : "IsFavorite"))
    }
    if !input.search.isEmpty { query.append(.init(name: "SearchTerm", value: input.search)) }
    if !input.ids.isEmpty {
      query.append(.init(name: "Ids", value: input.ids.joined(separator: ",")))
    }
    if let artist = input.artist {
      let field =
        input.appearancesOnly
        ? "ContributingArtistIds" : (input.category == .songs ? "ArtistIds" : "AlbumArtistIds")
      query.append(.init(name: field, value: artist))
    }
    if input.rankArtistSongs {
      query.removeAll { $0.name == "SortBy" || $0.name == "SortOrder" }
      query += [
        .init(name: "SortBy", value: "PlayCount,SortName"),
        .init(name: "SortOrder", value: "Descending,Ascending"),
        .init(name: "EnableUserData", value: "true"),
      ]
    }
    if let genre = input.genreID { query.append(.init(name: "GenreIds", value: genre)) }
    if let shelf = input.shelf {
      query.removeAll { $0.name == "SortBy" || $0.name == "SortOrder" }
      query += [
        .init(
          name: "SortBy",
          value: shelf == .favorites ? "SortName" : "Random"),
        .init(name: "SortOrder", value: "Ascending"),
      ]
      if shelf == .favorites { query.append(.init(name: "Filters", value: "IsFavorite")) }
    }
    if input.category == .artists && input.shelf != .artists {
      return try await directoryPage(input, query: query, limit: limit)
    }
    let data = try await request(input.shelf == .artists ? "Artists" : "Items", query: query)
    let decoder = JSONDecoder()
    decoder.userInfo[musicDetailKey] = input.includeDetails
    decoder.userInfo[artistPlaysKey] = input.rankArtistSongs
    let rows = try decoder.decode(ItemPage.self, from: data).items
    guard rows.count <= limit else { throw ClientError.invalidResponse }
    var seen = Set<String>()
    let items = rows.filter {
      (input.shelf?.accepts($0.kind) ?? ($0.kind == input.category.itemType)) && !$0.id.isEmpty
        && (!input.appearancesOnly || input.artist.map($0.guestIDs.contains) == true)
        && seen.insert($0.id).inserted
    }
    return CatalogPage(
      items: items.map(\.item), rawCount: rows.count,
      playedIDs: input.rankArtistSongs ? Set(items.lazy.filter(\.hasPlayHistory).map(\.id)) : [])
  }
  private func directoryPage(_ input: CatalogQuery, query: [URLQueryItem], limit: Int) async throws
    -> CatalogPage
  {
    var key = input
    key.offset = 0
    let search = !input.search.isEmpty
    let saved = artistCursors[search]
    var cursor = ArtistDirectoryCursor()
    if let saved, saved.query == key, saved.cursor.position == input.offset, input.offset > 0 {
      cursor = saved.cursor
    }
    let generation = yearGeneration
    var result: [MusicItem] = []
    while result.count < limit {
      for index in cursor.streams.indices where cursor.streams[index].needsPage {
        try Task.checkCancellation()
        let performers = index == 1
        var fields = query.filter {
          !["StartIndex", "IncludeItemTypes", "Fields"].contains($0.name)
        }
        let requested = query.first { $0.name == "Fields" }?.value ?? ""
        fields += [
          .init(name: "StartIndex", value: String(cursor.streams[index].offset)),
          .init(name: "IncludeItemTypes", value: performers ? "Audio" : "MusicAlbum"),
          .init(name: "Fields", value: requested + ",SortName"),
        ]
        let data = try await request(performers ? "Artists" : "Artists/AlbumArtists", query: fields)
        try Task.checkCancellation()
        guard generation == yearGeneration else { throw CancellationError() }
        let decoder = JSONDecoder()
        decoder.userInfo[musicDetailKey] = input.includeDetails
        let rows = try decoder.decode(ItemPage.self, from: data).items
        guard rows.count <= limit else { throw ClientError.invalidResponse }
        try cursor.streams[index].accept(rows, limit: limit)
      }
      if cursor.streams.contains(where: \.needsPage) { continue }
      guard let artist = cursor.pop(descending: input.options.sort == .titleDescending) else {
        break
      }
      if cursor.seen.insert(artist.id).inserted {
        if cursor.position >= input.offset { result.append(artist.item) }
        cursor.position += 1
      }
    }
    artistCursors[search] = (key, cursor)
    return CatalogPage(items: result, rawCount: result.count)
  }
  private struct PlaylistRead {
    let library: String
    let generation: UUID
    let isCurrent: @MainActor @Sendable () -> Bool
  }
  private func playlistRead(
    library: String, isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> PlaylistRead {
    let roots = try await loadMusicLibraries(refresh: false, isCurrent: isCurrent)
    guard roots.contains(where: { $0.id == library }) else { throw ClientError.forbidden }
    return PlaylistRead(library: library, generation: musicRootRequest, isCurrent: isCurrent)
  }
  private func readPlaylistValue<Value: Sendable>(
    _ read: PlaylistRead, _ load: () async throws -> Value
  ) async throws -> Value {
    func validate() async throws {
      try await requireMediaCurrent(
        library: read.library, generation: read.generation, isCurrent: read.isCurrent)
    }
    try await validate()
    let value: Value
    do {
      value = try await load()
    } catch {
      try await validate()
      throw error
    }
    try await validate()
    return value
  }
  private func playlistPages<Row: Decodable & Sendable>(
    _ type: Row.Type, path: String, query: [URLQueryItem], read: PlaylistRead, limit: Int = 200,
    primaryImages: Bool = false, maximum: Int = 100_000,
    project: ((Data, [Row]) async throws -> [Row])? = nil
  ) async throws -> [Row] {
    var rows: [Row] = []
    var offset = 0
    var total: Int?
    var pageCount = 0
    while true {
      pageCount += 1
      guard pageCount <= 1_024 else { throw ClientError.unavailable }
      let data = try await readPlaylistValue(read) {
        try await request(
          path,
          query: query + [
            .init(name: "UserId", value: connection.userID),
            .init(name: "StartIndex", value: String(offset)),
            .init(name: "Limit", value: String(limit)),
            .init(name: "EnableImages", value: primaryImages ? "true" : "false"),
            .init(name: "EnableUserData", value: "false"),
          ])
      }
      let page = try JSONDecoder().decode(PlaylistWirePage<Row>.self, from: data)
      guard (0...maximum).contains(page.total), total == nil || total == page.total,
        page.start == nil || page.start == offset,
        page.items.count <= limit, offset + page.items.count <= page.total,
        !page.items.isEmpty || offset == page.total
      else { throw ClientError.invalidResponse }
      total = page.total
      offset += page.items.count
      if let project {
        rows += try await project(data, page.items)
      } else {
        rows += page.items
      }
      if offset == page.total { return rows }
    }
  }
  private func playlistIndex(
    _ read: PlaylistRead, id: String? = nil, editing: Bool = false, onUpdate: PlaylistUpdate? = nil,
    onSongs: PlaylistSongsUpdate? = nil
  ) async throws
    -> [PlaylistSummaryDTO]
  {
    var query = [
      URLQueryItem(name: "Recursive", value: "true"),
      .init(name: "IncludeItemTypes", value: "Playlist"),
      .init(name: "SortBy", value: "SortName"),
      .init(name: "SortOrder", value: "Ascending"),
      .init(name: "EnableTotalRecordCount", value: "true"),
    ]
    if editing { query.append(.init(name: "Fields", value: "CanDelete")) }
    if let id {
      query.append(.init(name: "Ids", value: id))
    } else {
      query += [
        .init(name: "EnableImageTypes", value: "Primary"),
        .init(name: "ImageTypeLimit", value: "1"),
      ]
    }
    var seen = Set<String>()
    var previousPages: [MusicPlaylist] = []
    return try await playlistPages(
      PlaylistSummaryDTO.self, path: "Items", query: query, read: read, primaryImages: id == nil,
      maximum: MusicPlaylistSnapshot.indexLimit
    ) { data, page in
      for row in page {
        if let id = row.id, !seen.insert(id).inserted { throw ClientError.invalidResponse }
      }
      guard id == nil else { return page }
      func summaries(_ confirmed: [String: Int]) throws -> [PlaylistSummaryDTO] {
        guard !confirmed.isEmpty else { return page }
        let decoder = JSONDecoder()
        decoder.userInfo[PlaylistSummaryDTO.confirmedMusic] = confirmed
        return try decoder.decode(PlaylistWirePage<PlaylistSummaryDTO>.self, from: data).items
      }
      let earlier = previousPages
      func publish(_ rows: [PlaylistSummaryDTO]) async throws {
        guard let onUpdate else { return }
        let new = rows.compactMap(\.playlist)
        guard !new.isEmpty else { return }
        let visible = earlier + new
        try await self.requireMediaCurrent(
          library: read.library, generation: read.generation, isCurrent: read.isCurrent)
        try await MainActor.run {
          guard !Task.isCancelled, read.isCurrent() else { throw CancellationError() }
          onUpdate(visible)
        }
      }
      var result = page
      try await publish(page)
      let confirmed = try await self.confirmMusicPlaylists(
        page, read: read, onSongs: onSongs,
        prioritizeFirst: onUpdate != nil && earlier.isEmpty && !page.contains { $0.playlist != nil }
      ) { confirmed in
        if onUpdate != nil {
          result = try summaries(confirmed)
          try await publish(result)
        }
      }
      try await self.requireMediaCurrent(
        library: read.library, generation: read.generation, isCurrent: read.isCurrent)
      if onUpdate == nil {
        result = try summaries(confirmed)
      } else {
        previousPages += result.compactMap(\.playlist)
      }
      return result
    }
  }
  private func compactPlaylist(_ id: String, read: PlaylistRead) async throws -> [String]? {
    do {
      let data = try await readPlaylistValue(read) {
        try await request("Playlists/" + id, allowMissing: true)
      }
      guard !data.isEmpty else { return nil }
      let ids = try JSONDecoder().decode(PlaylistManifest.self, from: data).itemIDs
      guard ids.count <= 100_000, ids.allSatisfy(PlaylistSummaryDTO.validID) else {
        throw ClientError.invalidResponse
      }
      return ids.map(playlistTrackKey)
    } catch let error as URLError where error.code == .dataLengthExceedsMaximum { return nil }
  }
  private func pagedPlaylist(_ id: String, read: PlaylistRead) async throws -> [String?] {
    try await playlistPages(
      PlaylistEntryDTO.self, path: "Playlists/" + id + "/Items", query: [], read: read, limit: 500
    ).map { $0.trackID.map(playlistTrackKey) }
  }
  private func playlistReferences(_ id: String, read: PlaylistRead) async throws -> [String?] {
    if let ids = try await compactPlaylist(id, read: read) { return ids }
    return try await pagedPlaylist(id, read: read)
  }
  private static let smallPlaylistLimit = 64
  private func smallPlaylistPage(_ id: String, read: PlaylistRead, details: Bool = false)
    async throws -> (Data, PlaylistWirePage<PlaylistEntryDTO>)?
  {
    do {
      let data = try await readPlaylistValue(read) {
        try await request(
          "Playlists/" + id + "/Items",
          query: [
            .init(name: "UserId", value: connection.userID), .init(name: "StartIndex", value: "0"),
            .init(name: "Limit", value: String(Self.smallPlaylistLimit)),
            .init(
              name: "Fields",
              value: details
                ? "ParentId,Artists,AlbumArtist,AlbumId,PrimaryImageAspectRatio" : "ParentId"),
            .init(name: "EnableImages", value: details ? "true" : "false"),
            .init(name: "EnableUserData", value: details ? "true" : "false"),
          ])
      }
      let page = try JSONDecoder().decode(PlaylistWirePage<PlaylistEntryDTO>.self, from: data)
      guard page.start == nil || page.start == 0, page.total >= page.items.count,
        page.items.count <= Self.smallPlaylistLimit
      else { throw ClientError.invalidResponse }
      return (data, page)
    } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
      return nil
    } catch ClientError.forbidden { return nil } catch PlaybackProblem.httpStatus(400) {
      return nil
    }
  }
  private func parentsInMusic(_ page: PlaylistWirePage<PlaylistEntryDTO>, read: PlaylistRead)
    async throws -> Bool
  {
    guard !page.items.isEmpty, page.items.count == page.total,
      page.items.allSatisfy({ $0.trackID != nil && $0.parentID != nil })
    else { return false }
    let wanted = Set(page.items.compactMap(\.parentID)).subtracting([playlistTrackKey(read.library)]
    )
    if wanted.isEmpty { return true }
    do {
      let data = try await readPlaylistValue(read) {
        try await request(
          "Items",
          query: [
            .init(name: "UserId", value: connection.userID),
            .init(name: "ParentId", value: read.library),
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Folder,MusicAlbum"),
            .init(name: "StartIndex", value: "0"), .init(name: "Limit", value: "2048"),
            .init(name: "EnableTotalRecordCount", value: "false"),
            .init(name: "EnableImages", value: "false"),
            .init(name: "EnableUserData", value: "false"),
          ])
      }
      struct Folders: Decodable {
        let items: [PlaylistMusicFolder]
        enum CodingKeys: String, CodingKey { case items = "Items" }
      }
      let found = try JSONDecoder().decode(Folders.self, from: data).items
      return wanted.isSubset(of: Set(found.compactMap(\.id)))
    } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
      return false
    } catch is DecodingError { return false } catch ClientError.forbidden {
      return false
    } catch PlaybackProblem.httpStatus(400) { return false }
  }
  private func firstPlaylist(_ id: String, read: PlaylistRead, emptyAudio: Bool) async throws -> (
    links: [String?], verified: Bool
  ) {
    async let compact = compactPlaylist(id, read: read)
    guard let (_, page) = try await smallPlaylistPage(id, read: read) else {
      if let compact = try await compact { return (compact, emptyAudio && compact.isEmpty) }
      return (try await pagedPlaylist(id, read: read), false)
    }
    let ids = page.items.map { $0.trackID.map(playlistTrackKey) }
    if !ids.isEmpty, page.total == ids.count, page.items.allSatisfy({ $0.parentID != nil }) {
      async let rooted = parentsInMusic(page, read: read)
      let links: [String?] = try await compact.map { $0.map(Optional.some) } ?? ids
      return (links, try await rooted && links == ids)
    }
    if let compact = try await compact { return (compact, emptyAudio && compact.isEmpty) }
    if page.items.count == page.total { return (ids, false) }
    return (try await pagedPlaylist(id, read: read), false)
  }
  private func playlistMembership(
    in library: String, read: PlaylistRead, cache: inout [String: Set<String>]
  ) async throws -> Set<String> {
    if let existing = cache[library] { return existing }
    let ids = Set(try await playlistRoot(library, read: read).keys)
    cache[library] = ids
    return ids
  }
  private func confirmMusicPlaylists(
    _ page: [PlaylistSummaryDTO], read: PlaylistRead, onSongs: PlaylistSongsUpdate?,
    prioritizeFirst: Bool,
    onConfirm: ([String: Int]) async throws -> Void
  ) async throws -> [String: Int] {
    let candidates = page.compactMap(\.id)
    let typedAudio = Set(page.filter { !$0.needsMusicProof }.compactMap(\.id))
    var catalogs: [String: Set<String>] = [:]
    var selectedSongs: [String: RootedPlaylistSong]?
    var confirmed: [String: Int] = [:]
    typealias Membership = (links: [String?], confirmedEmpty: Bool)
    var nextLinks: Membership?
    func visibleReferences(_ id: String) async throws -> Membership {
      do {
        if let manifest = try await self.compactPlaylist(id, read: read) {
          return (manifest, manifest.isEmpty && typedAudio.contains(id))
        }
        return (try await self.pagedPlaylist(id, read: read), false)
      } catch ClientError.forbidden {
        return ([], false)
      }
    }
    for (index, id) in candidates.enumerated() {
      let membership: Membership
      if index == 0 && prioritizeFirst {
        let first: (links: [String?], verified: Bool)
        do {
          first = try await firstPlaylist(id, read: read, emptyAudio: typedAudio.contains(id))
        } catch ClientError.forbidden {
          continue
        }
        if first.verified {
          try await requireMediaCurrent(
            library: read.library, generation: read.generation, isCurrent: read.isCurrent)
          firstVerifiedPlaylist = (read.library, id)
          confirmed[id] = first.links.count
          try await onConfirm(confirmed)
          if candidates.count > 1 {
            async let root = playlistRoot(read.library, read: read, prepareDetails: onSongs != nil)
            nextLinks = try await visibleReferences(candidates[1])
            selectedSongs = try await root
          }
          continue
        }
        membership = (first.links, false)
      } else if let prefetched = nextLinks {
        nextLinks = nil
        membership = prefetched
      } else {
        membership = try await visibleReferences(id)
      }
      let entries = membership.links
      let ids = Set(entries.compactMap { $0 })
      if membership.confirmedEmpty {
        confirmed[id] = 0
        try await onConfirm(confirmed)
        continue
      }
      guard !ids.isEmpty, entries.allSatisfy({ $0 != nil }) else { continue }
      if selectedSongs == nil {
        selectedSongs = try await playlistRoot(
          read.library, read: read, prepareDetails: onSongs != nil)
      }
      guard let selectedSongs else { continue }
      var missing = ids.filter { selectedSongs[$0] == nil }
      guard missing.count < ids.count else { continue }
      for root in musicRoots ?? [] where root.id != read.library && !missing.isEmpty {
        missing.subtract(try await playlistMembership(in: root.id, read: read, cache: &catalogs))
      }
      if missing.isEmpty {
        try await requireMediaCurrent(
          library: read.library, generation: read.generation, isCurrent: read.isCurrent)
        if let onSongs, entries.count <= PlaylistDetailCache.occurrenceLimit {
          let selected = entries.compactMap { $0.flatMap { selectedSongs[$0] } }
          let tracks = selected.compactMap(\.track)
          if !tracks.isEmpty, tracks.count == selected.count {
            try await MainActor.run {
              guard read.isCurrent(), !Task.isCancelled else { throw CancellationError() }
              onSongs(id, tracks)
            }
          }
        }
        confirmed[id] = entries.count
        try await onConfirm(confirmed)
      }
    }
    return confirmed
  }
  private func playlistRoot(
    _ library: String, read: PlaylistRead, albums: Set<String> = [],
    windows: [Range<Int>]? = nil, wanted: Set<String>? = nil, hydrate: Bool = false,
    prepareDetails: Bool = false
  ) async throws -> [String: RootedPlaylistSong] {
    let limit = 500
    var fields = [
      URLQueryItem(name: "UserId", value: connection.userID),
      .init(name: "ParentId", value: library),
      .init(name: "Recursive", value: "true"), .init(name: "IncludeItemTypes", value: "Audio"),
      .init(name: "SortBy", value: "SortName"), .init(name: "SortOrder", value: "Ascending"),
      .init(name: "EnableTotalRecordCount", value: "true"),
    ]
    if !albums.isEmpty {
      fields.append(.init(name: "AlbumIds", value: albums.sorted().joined(separator: ",")))
    }
    let query = fields
    @Sendable func page(_ offset: Int, _ count: Int, prepare: Bool) async throws
      -> PlaylistWirePage<
        RootedPlaylistSong
      >
    {
      let details = hydrate || prepare
      let data: Data
      do {
        data = try await self.readPlaylistValue(read) {
          try await self.request(
            "Items",
            query: query + [
              .init(
                name: "Fields",
                value: details ? "Artists,AlbumArtist,AlbumId,PrimaryImageAspectRatio" : "AlbumId"),
              .init(name: "EnableImages", value: details ? "true" : "false"),
              .init(name: "EnableImageTypes", value: "Primary"),
              .init(name: "EnableUserData", value: details ? "true" : "false"),
              .init(name: "StartIndex", value: String(offset)),
              .init(name: "Limit", value: String(count)),
            ])
        }
      } catch let error as URLError where prepare && error.code == .dataLengthExceedsMaximum {
        return try await page(offset, count, prepare: false)
      } catch PlaybackProblem.httpStatus(400) where prepare {
        return try await page(offset, count, prepare: false)
      }
      let decoder = JSONDecoder()
      if hydrate { decoder.userInfo[playlistDetailsKey] = wanted }
      if prepare { decoder.userInfo[playlistDetailsKey] = true }
      let result = try decoder.decode(PlaylistWirePage<RootedPlaylistSong>.self, from: data)
      guard (0...250_000).contains(result.total),
        result.start == offset || (offset == 0 && result.start == nil),
        result.items.count <= min(count, max(0, result.total - offset))
      else { throw ClientError.invalidResponse }
      return result
    }
    let firstOffset = windows?.first?.lowerBound ?? 0
    let first = try await page(firstOffset, windows?.first?.count ?? limit, prepare: prepareDetails)
    let prepareRemaining = prepareDetails && first.total <= PlaylistDetailCache.occurrenceLimit
    let pageSize = first.items.count
    let remaining: AnySequence<(Int, Int)>
    if let windows {
      remaining = AnySequence(windows.dropFirst().lazy.map { ($0.lowerBound, $0.count) })
    } else {
      guard first.total == 0 || (pageSize > 0 && (first.total - 1) / pageSize < 1_024) else {
        throw ClientError.invalidResponse
      }
      remaining = AnySequence(
        stride(from: pageSize, to: first.total, by: max(1, pageSize)).lazy.map { ($0, limit) })
    }
    var rows: [String: RootedPlaylistSong] = [:]
    var seen = Set<String>()
    var locations: [String: PlaylistFolderIndex.Location] = [:]
    let indexesFolder = albums.isEmpty && windows == nil
    func accept(_ page: PlaylistWirePage<RootedPlaylistSong>, at offset: Int) throws {
      if windows == nil
        && (page.total != first.total || page.items.count != min(pageSize, first.total - offset))
      {
        throw ClientError.invalidResponse
      }
      for (index, song) in page.items.enumerated() {
        if windows == nil && !seen.insert(song.id).inserted { throw ClientError.invalidResponse }
        let position = offset + index
        if indexesFolder && position < 16_384 {
          locations[song.id] = .init(offset: position, album: song.album)
        }
        if wanted?.contains(song.id) != false { rows[song.id] = song }
      }
    }
    try accept(first, at: firstOffset)
    if windows != nil || pageSize < first.total {
      try await withThrowingTaskGroup(of: (Int, PlaylistWirePage<RootedPlaylistSong>).self) {
        group in
        let pages = remaining.makeIterator()
        for _ in 0..<4 {
          if let (offset, count) = pages.next() {
            group.addTask { (offset, try await page(offset, count, prepare: prepareRemaining)) }
          }
        }
        while let (offset, value) = try await group.next() {
          try Task.checkCancellation()
          try accept(value, at: offset)
          if let (next, count) = pages.next() {
            group.addTask { (next, try await page(next, count, prepare: prepareRemaining)) }
          }
        }
      }
    }
    try await requireMediaCurrent(
      library: read.library, generation: read.generation, isCurrent: read.isCurrent)
    if indexesFolder {
      playlistFolderIndexes[library] = .init(total: first.total, locations: locations)
    }
    return rows
  }
  private func selectedPlaylistSongs(
    _ ids: Set<String>, library: String, read: PlaylistRead, hydrate: Bool
  ) async throws -> [String: RootedPlaylistSong] {
    guard !ids.isEmpty else { return [:] }
    if let index = playlistFolderIndexes[library] {
      var matches: [String: RootedPlaylistSong] = [:]
      let albums = Set(ids.compactMap { index.locations[$0]?.album })
      if !albums.isEmpty, albums.count <= 128, albums.reduce(0, { $0 + $1.utf8.count + 1 }) <= 5_000
      {
        matches = try await playlistRoot(
          library, read: read, albums: albums, wanted: ids, hydrate: hydrate)
        if matches.count == ids.count { return matches }
      }
      let missing = ids.subtracting(matches.keys)
      if let windows = index.windows(for: missing) {
        let found = try await playlistRoot(
          library, read: read, windows: windows, wanted: missing, hydrate: hydrate)
        matches.merge(found) { _, new in new }
        if matches.count == ids.count { return matches }
      }
    }
    return try await playlistRoot(library, read: read, wanted: ids, hydrate: hydrate)
  }
  func playlists(
    library: String, isCurrent: @escaping @MainActor @Sendable () -> Bool,
    onUpdate: PlaylistUpdate?,
    onSongs: PlaylistSongsUpdate?
  ) async throws -> [MusicPlaylist] {
    let read = try await playlistRead(library: library, isCurrent: isCurrent)
    return try await playlistIndex(read, onUpdate: onUpdate, onSongs: onSongs).compactMap(
      \.playlist)
  }
  func playlistTracks(
    library: String, playlistID: String, isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> [MusicItem] {
    guard PlaylistSummaryDTO.validID(playlistID) else { throw ClientError.invalidResponse }
    let read = try await playlistRead(library: library, isCurrent: isCurrent)
    guard
      let candidate = try await playlistIndex(read, id: playlistID).first(where: {
        $0.id == playlistID
      })
    else { throw ClientError.forbidden }
    let links = try await playlistReferences(playlistID, read: read)
    let ordered = links.compactMap { $0 }
    guard !candidate.needsMusicProof || ordered.count == links.count else {
      return []
    }
    if firstVerifiedPlaylist?.library == library, firstVerifiedPlaylist?.id == playlistID,
      playlistFolderIndexes[library] == nil, !ordered.isEmpty,
      links.count <= Self.smallPlaylistLimit
    {
      if let (data, page) = try await smallPlaylistPage(playlistID, read: read, details: true),
        links == page.items.map({ $0.trackID.map(playlistTrackKey) }),
        try await parentsInMusic(page, read: read)
      {
        try await requireMediaCurrent(
          library: read.library, generation: read.generation, isCurrent: read.isCurrent)
        return try JSONDecoder().decode(PlaylistWirePage<ItemDTO>.self, from: data).items.map(
          \.item)
      }
    }
    let ids = Set(ordered)
    let rows = try await selectedPlaylistSongs(
      ids, library: read.library, read: read, hydrate: true)
    if candidate.needsMusicProof {
      guard !rows.isEmpty else { return [] }
      var missing = ids.subtracting(rows.keys)
      for root in musicRoots ?? [] where root.id != library && !missing.isEmpty {
        let other = try await selectedPlaylistSongs(
          missing, library: root.id, read: read, hydrate: false)
        missing.subtract(other.keys)
      }
      guard missing.isEmpty else { return [] }
    }
    return ordered.compactMap { rows[$0]?.track }
  }
  func albumTracks(library: String, album: String) async throws -> [MusicItem] {
    guard
      try await catalog(CatalogQuery(library: library, ids: [album])).contains(where: {
        $0.id == album
      })
    else { throw ClientError.forbidden }
    return try await tracksInVerifiedAlbum(album)
  }
  func albumDetail(library: String, album: MusicItem) async throws -> MusicAlbumPage {
    guard album.kind == "MusicAlbum",
      let fresh = try await catalog(
        CatalogQuery(library: library, ids: [album.id], includeDetails: true)
      )
      .first(where: { $0.id == album.id })
    else { throw ClientError.forbidden }
    return MusicAlbumPage(album: fresh, tracks: try await tracksInVerifiedAlbum(album.id))
  }
  func setFavorite(
    library: String, item: MusicItem, value: Bool,
    isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
  ) async throws -> Bool {
    try Task.checkCancellation()
    guard await isCurrent() else { throw CancellationError() }
    guard try await musicLibraries(refresh: false).contains(where: { $0.id == library }) else {
      throw ClientError.forbidden
    }
    try Task.checkCancellation()
    guard await isCurrent() else { throw CancellationError() }
    let rootRequest = musicRootRequest
    guard ["MusicAlbum", "MusicArtist", "Audio"].contains(item.kind), !item.id.isEmpty else {
      throw ClientError.forbidden
    }
    if item.kind == "MusicArtist" {
      _ = try await artistDetail(library: library, artist: item)
    } else {
      let category: MusicCategory = item.kind == "Audio" ? .songs : .albums
      guard
        try await catalog(CatalogQuery(library: library, category: category, ids: [item.id]))
          .contains(where: { $0.id == item.id && $0.kind == item.kind })
      else { throw ClientError.forbidden }
    }
    try Task.checkCancellation()
    guard await isCurrent(), musicRootRequest == rootRequest,
      musicRoots?.contains(where: { $0.id == library }) == true
    else { throw CancellationError() }
    let data = try await request(
      "UserFavoriteItems/" + item.id,
      query: [.init(name: "UserId", value: connection.userID)], method: value ? "POST" : "DELETE")
    guard await isCurrent(), musicRootRequest == rootRequest else { throw CancellationError() }
    struct Result: Decodable {
      let isFavorite: Bool
      enum CodingKeys: String, CodingKey { case isFavorite = "IsFavorite" }
    }
    let accepted = try JSONDecoder().decode(Result.self, from: data).isFavorite
    guard accepted == value else { throw ClientError.invalidResponse }
    return accepted
  }
  func lyrics(
    library: String, track: MusicItem,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MusicLyrics? {
    try Task.checkCancellation()
    guard await isCurrent() else { throw CancellationError() }
    let roots = try await musicLibraries(refresh: false)
    try Task.checkCancellation()
    guard await isCurrent(), roots.contains(where: { $0.id == library }) else {
      throw CancellationError()
    }
    let rootRequest = musicRootRequest
    guard track.kind == "Audio", track.hasLyrics == true else { return nil }
    let items = try await catalog(CatalogQuery(library: library, category: .songs, ids: [track.id]))
    try Task.checkCancellation()
    guard await isCurrent(), musicRootRequest == rootRequest else { throw CancellationError() }
    guard let fresh = items.first(where: { $0.id == track.id && $0.kind == "Audio" }) else {
      throw ClientError.forbidden
    }
    guard fresh.hasLyrics == true else { return nil }
    let data = try await request("Audio/" + track.id + "/Lyrics", allowMissing: true)
    try Task.checkCancellation()
    guard await isCurrent(), musicRootRequest == rootRequest else { throw CancellationError() }
    return data.isEmpty ? nil : try MusicLyrics.decode(data)
  }
  func trackInformation(library: String, track: MusicItem) async throws -> MusicTechnicalInfo {
    guard track.kind == "Audio",
      try await catalog(CatalogQuery(library: library, category: .songs, ids: [track.id])).contains(
        where: { $0.id == track.id && $0.kind == "Audio" })
    else { throw ClientError.forbidden }
    let data = try await request(
      "Items/" + track.id,
      query: [
        .init(name: "UserId", value: connection.userID),
        .init(name: "Fields", value: "MediaStreams"),
      ])
    struct Stream: Decodable {
      let type: String?
      let codec: String?
      let sampleRate: Int?
      let bitDepth: Int?
      let channels: Int?
      let bitRate: Int?
      enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case sampleRate = "SampleRate"
        case bitDepth = "BitDepth"
        case channels = "Channels"
        case bitRate = "BitRate"
      }
    }
    struct Result: Decodable {
      let id: String
      let type: String
      let mediaStreams: [Stream]?
      enum CodingKeys: String, CodingKey {
        case id = "Id"
        case type = "Type"
        case mediaStreams = "MediaStreams"
      }
    }
    let result = try JSONDecoder().decode(Result.self, from: data)
    guard result.id == track.id, result.type == "Audio" else { throw ClientError.forbidden }
    let audio = result.mediaStreams?.first { $0.type == "Audio" }
    return MusicTechnicalInfo(
      codec: audio?.codec, sampleRate: audio?.sampleRate, bitDepth: audio?.bitDepth,
      channels: audio?.channels, bitRate: audio?.bitRate)
  }

  func artistDetail(library: String, artist: MusicItem) async throws -> MusicItem {
    guard artist.kind == "MusicArtist", !artist.id.isEmpty, artist.id.count <= 128,
      artist.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
      ),
      try await musicLibraries(refresh: false).contains(where: { $0.id == library })
    else {
      throw ClientError.forbidden
    }
    let evidence = try await page([
      .init(name: "ParentId", value: library), .init(name: "IncludeItemTypes", value: "Audio"),
      .init(name: "ArtistIds", value: artist.id), .init(name: "Recursive", value: "true"),
      .init(name: "Limit", value: "1"),
    ])
    guard
      evidence.contains(where: {
        $0.kind == "Audio" && $0.artistCredits?.contains(where: { $0.id == artist.id }) == true
      })
    else {
      throw ClientError.forbidden
    }
    let data = try await request(
      "Items/" + artist.id, query: [.init(name: "UserId", value: connection.userID)])
    let decoder = JSONDecoder()
    decoder.userInfo[musicDetailKey] = true
    let fresh = try decoder.decode(ItemDTO.self, from: data)
    guard fresh.kind == "MusicArtist", fresh.id == artist.id else { throw ClientError.forbidden }
    return fresh.item
  }
}

extension JellyfinClient: MusicPlaylistEditing {
  private struct SharePermission: Decodable {
    let user: String
    let canEdit: Bool
    enum CodingKeys: String, CodingKey {
      case user = "UserId"
      case canEdit = "CanEdit"
    }
  }

  func playlistEditor(
    library: String, playlist: MusicPlaylist, isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> PlaylistEditState {
    let read = try await playlistRead(library: library, isCurrent: isCurrent)
    return try await editState(playlist, read: read)
  }

  private func editState(_ playlist: MusicPlaylist, read: PlaylistRead) async throws
    -> PlaylistEditState
  {
    let id = playlist.id
    guard PlaylistSummaryDTO.validID(id), PlaylistSummaryDTO.validID(connection.userID),
      let candidate = try await playlistIndex(read, id: id, editing: true).first(where: {
        $0.id == id
      })
    else { throw PlaylistEditError.readOnly }
    let path = "Playlists/" + id
    guard try await canEditPlaylist(id, read: read) else { throw PlaylistEditError.readOnly }
    let entries = try await playlistPages(
      PlaylistEditEntry.self, path: path + "/Items", query: [], read: read, limit: 500)
    let order = try await verifiedPlaylistOrder(id, candidate: candidate, read: read)
    guard entries.elementsEqual(order, by: { $0.track == $1 }) else {
      throw PlaylistEditError.limitedToLibrary
    }
    let owner: Bool
    do {
      _ = try await readPlaylistValue(read) { try await request(path + "/Users") }
      owner = true
    } catch ClientError.forbidden { owner = false }
    return PlaylistEditState(
      playlist: playlist, entries: entries, canDelete: candidate.canDelete, canShare: owner)
  }

  private func verifiedPlaylistOrder(
    _ id: String, candidate: PlaylistSummaryDTO, read: PlaylistRead
  ) async throws -> [String] {
    guard let order = try await compactPlaylist(id, read: read),
      !order.isEmpty || !candidate.needsMusicProof
    else { throw PlaylistEditError.limitedToLibrary }
    let ids = Set(order)
    let selected = try await selectedPlaylistSongs(
      ids, library: read.library, read: read, hydrate: false)
    guard ids.count == selected.count else { throw PlaylistEditError.limitedToLibrary }
    return order
  }

  private func canEditPlaylist(_ id: String, read: PlaylistRead) async throws -> Bool {
    let permission = try await readPlaylistValue(read) {
      try await request("Playlists/" + id + "/Users/" + connection.userID, allowMissing: true)
    }
    guard let grant = try? JSONDecoder().decode(SharePermission.self, from: permission)
    else { return false }
    return grant.canEdit && playlistTrackKey(grant.user) == playlistTrackKey(connection.userID)
  }

  func playlistSharing(
    library: String, playlist: MusicPlaylist, isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> PlaylistSharing {
    let read = try await playlistRead(library: library, isCurrent: isCurrent)
    guard try await editState(playlist, read: read).canShare else {
      throw PlaylistEditError.readOnly
    }
    struct Details: Decodable {
      let openAccess: Bool
      let shares: [SharePermission]
      enum CodingKeys: String, CodingKey {
        case openAccess = "OpenAccess"
        case shares = "Shares"
      }
    }
    struct Person: Decodable {
      let id: String
      let name: String
      enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
      }
    }
    let data = try await readPlaylistValue(read) { try await request("Playlists/" + playlist.id) }
    let details = try JSONDecoder().decode(Details.self, from: data)
    let directory: Data
    do {
      directory = try await readPlaylistValue(read) { try await request("Users") }
    } catch ClientError.forbidden {
      directory = try await readPlaylistValue(read) { try await request("Users/Public") }
    }
    let people = try JSONDecoder().decode([Person].self, from: directory)
    var names: [String: String] = [:]
    for person in people where PlaylistSummaryDTO.validID(person.id) {
      names[playlistTrackKey(person.id)] = person.name
    }
    var grants: [String: Bool] = [:]
    for person in details.shares where PlaylistSummaryDTO.validID(person.user) {
      grants[playlistTrackKey(person.user)] = person.canEdit
    }
    let all = Set(names.keys).union(grants.keys).subtracting([playlistTrackKey(connection.userID)])
    return PlaylistSharing(
      isPublic: details.openAccess,
      people: all.map {
        PlaylistPerson(id: $0, name: names[$0] ?? $0, canEdit: grants[$0])
      }.sorted { ($0.name, $0.id) < ($1.name, $1.id) })
  }

  private func verifiedSongs(_ songs: [MusicItem], read: PlaylistRead) async throws -> [String] {
    guard songs.allSatisfy({ $0.kind == "Audio" && PlaylistSummaryDTO.validID($0.id) }) else {
      throw ClientError.forbidden
    }
    let ids = songs.map { playlistTrackKey($0.id) }
    let unique = Set(ids)
    guard
      try await selectedPlaylistSongs(unique, library: read.library, read: read, hydrate: false)
        .count == unique.count
    else { throw ClientError.forbidden }
    return ids
  }

  func changePlaylist(
    library: String, state: PlaylistEditState?, change: PlaylistMutation,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> PlaylistSave {
    let read = try await playlistRead(library: library, isCurrent: isCurrent)
    if case .copy(let source, let name) = change {
      guard state == nil else { throw ClientError.invalidResponse }
      return try await copyPlaylist(source, name: name, read: read)
    }
    if case .create(let rawName, let songs) = change {
      guard state == nil else { throw ClientError.invalidResponse }
      let name = try PlaylistMutation.name(rawName)
      let ids = try await verifiedSongs(songs, read: read)
      let id = try await createPrivatePlaylist(name: name, ids: ids, read: read)
      return try await confirmPlaylistAddition(id, previous: [], requested: ids, read: read)
    }
    guard let state else { throw ClientError.invalidResponse }
    let fresh = try await editState(state.playlist, read: read)
    let id = state.playlist.id
    let path = "Playlists/" + id
    var expected = fresh.entries.map(\.track)
    var checkOrder = false
    switch change {
    case .create, .copy: throw ClientError.invalidResponse
    case .rename(let raw):
      let name = try PlaylistMutation.name(raw)
      _ = try await readPlaylistValue(read) { try await request(path, body: ["Name": name]) }
    case .append(let songs):
      let ids = try await verifiedSongs(songs, read: read)
      guard !ids.isEmpty else { throw ClientError.invalidResponse }
      for start in stride(from: 0, to: ids.count, by: 40) {
        let batch = ids[start..<min(start + 40, ids.count)].joined(separator: ",")
        _ = try await readPlaylistValue(read) {
          try await request(
            path + "/Items",
            query: [
              .init(name: "Ids", value: batch), .init(name: "UserId", value: connection.userID),
            ], method: "POST")
        }
      }
      return try await confirmPlaylistAddition(id, previous: expected, requested: ids, read: read)
    case .remove(let index), .move(let index, _):
      guard state.entries == fresh.entries, expected.indices.contains(index) else {
        throw PlaylistEditError.changed
      }
      guard let entry = fresh.entryID(at: index) else { throw PlaylistEditError.ambiguousEntry }
      if case .move(_, let target) = change {
        guard expected.indices.contains(target) else { throw PlaylistEditError.changed }
        if target == index { return PlaylistSave(id: id) }
        guard fresh.permitsMove(to: target) else { throw PlaylistEditError.ambiguousEntry }
        let moved = expected.remove(at: index)
        expected.insert(moved, at: target)
        _ = try await readPlaylistValue(read) {
          try await request(path + "/Items/" + entry + "/Move/" + String(target), method: "POST")
        }
      } else {
        expected.remove(at: index)
        _ = try await readPlaylistValue(read) {
          try await request(
            path + "/Items", query: [.init(name: "EntryIds", value: entry)], method: "DELETE")
        }
      }
      checkOrder = true
    case .delete:
      guard fresh.canDelete, fresh.entries == state.entries else { throw PlaylistEditError.changed }
      _ = try await readPlaylistValue(read) { try await request("Items/" + id, method: "DELETE") }
    case .cover(let data):
      guard !data.isEmpty, data.count <= 4_000_000, data.starts(with: [0xff, 0xd8]) else {
        throw ClientError.invalidResponse
      }
      do {
        _ = try await readPlaylistValue(read) {
          try await request("Items/" + id + "/Images/Primary", jpeg: data)
        }
      } catch ClientError.forbidden { throw PlaylistEditError.coverPermission }
    case .removeCover:
      do {
        _ = try await readPlaylistValue(read) {
          try await request("Items/" + id + "/Images/Primary", method: "DELETE")
        }
      } catch ClientError.forbidden { throw PlaylistEditError.coverPermission }
    case .visibility(let value):
      guard fresh.canShare else { throw PlaylistEditError.readOnly }
      _ = try await readPlaylistValue(read) { try await request(path, body: ["IsPublic": value]) }
    case .share(let person, let edit):
      guard fresh.canShare, PlaylistSummaryDTO.validID(person),
        playlistTrackKey(person) != playlistTrackKey(connection.userID)
      else { throw PlaylistEditError.readOnly }
      let target = path + "/Users/" + person
      _ = try await readPlaylistValue(read) {
        if let edit { return try await request(target, body: ["CanEdit": edit]) }
        return try await request(target, method: "DELETE")
      }
    }
    if checkOrder, try await playlistReferences(id, read: read) != expected.map(Optional.some) {
      throw PlaylistEditError.changed
    }
    return PlaylistSave(id: id)
  }
  private func copyPlaylist(_ source: MusicPlaylist, name: String, read: PlaylistRead) async throws
    -> PlaylistSave
  {
    let name = try PlaylistMutation.name(name)
    guard PlaylistSummaryDTO.validID(source.id), PlaylistSummaryDTO.validID(connection.userID),
      let candidate = try await playlistIndex(read, id: source.id).first(where: {
        $0.id == source.id
      })
    else { throw ClientError.forbidden }
    let order = try await verifiedPlaylistOrder(source.id, candidate: candidate, read: read)
    let id: String
    do {
      id = try await createPrivatePlaylist(name: name, ids: order, read: read)
    } catch ClientError.forbidden { throw ClientError.forbidden } catch ClientError.unauthorized {
      throw ClientError.unauthorized
    } catch is CancellationError { throw CancellationError() } catch {
      throw PlaylistEditError.copyUnconfirmed
    }
    guard playlistTrackKey(id) != playlistTrackKey(source.id) else {
      throw PlaylistEditError.copyUnconfirmed
    }

    struct CopyDetails: Decodable {
      let itemIDs: [String]
      let isPublic: Bool
      let shares: [SharePermission]
      enum CodingKeys: String, CodingKey {
        case itemIDs = "ItemIds"
        case isPublic = "OpenAccess"
        case shares = "Shares"
      }
    }
    do {
      let data = try await readPlaylistValue(read) { try await request("Playlists/" + id) }
      let copy = try JSONDecoder().decode(CopyDetails.self, from: data)
      guard !copy.isPublic, copy.shares.isEmpty else {
        return PlaylistSave(
          id: id,
          notice:
            "Jellyfin created the copy with different sharing settings. Review Sharing on the new playlist."
        )
      }
      guard copy.itemIDs.elementsEqual(order, by: { playlistTrackKey($0) == $1 }) else {
        return PlaylistSave(
          id: id,
          notice:
            "Jellyfin created the copy, but the saved songs don’t match the original order and repeats."
        )
      }
      guard try await canEditPlaylist(id, read: read) else {
        return PlaylistSave(
          id: id, notice: "Jellyfin created the copy, but editing access couldn’t be confirmed.")
      }
      return PlaylistSave(id: id)
    } catch ClientError.unauthorized { throw ClientError.unauthorized } catch is CancellationError {
      throw CancellationError()
    } catch {
      return PlaylistSave(
        id: id,
        notice: "Jellyfin created the copy. Its songs and access settings couldn’t be verified.")
    }
  }

  private func createPrivatePlaylist(name: String, ids: [String], read: PlaylistRead) async throws
    -> String
  {
    let data = try await readPlaylistValue(read) {
      try await request(
        "Playlists",
        body: [
          "Name": name, "UserId": connection.userID, "MediaType": "Audio", "IsPublic": false,
          "Ids": ids,
        ])
    }
    struct Created: Decodable {
      let id: String
      enum CodingKeys: String, CodingKey { case id = "Id" }
    }
    guard let id = try? JSONDecoder().decode(Created.self, from: data).id,
      PlaylistSummaryDTO.validID(id)
    else { throw PlaylistEditError.uncertain }
    return id
  }
  private func confirmPlaylistAddition(
    _ id: String, previous: [String], requested: [String], read: PlaylistRead
  ) async throws -> PlaylistSave {
    do {
      let saved = try await playlistReferences(id, read: read)
      return .addition(id: id, previous: previous, requested: requested, saved: saved)
    } catch ClientError.unauthorized { throw ClientError.unauthorized } catch is CancellationError {
      throw CancellationError()
    } catch {
      return PlaylistSave(
        id: id,
        notice:
          "Jellyfin accepted the change. Its saved order couldn’t be checked. Refresh the playlist before trying again."
      )
    }
  }
}
