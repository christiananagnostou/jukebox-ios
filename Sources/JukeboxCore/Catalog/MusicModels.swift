import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

struct MusicCredit: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let name: String
  var item: MusicItem {
    MusicItem(
      id: id, title: name, artist: name, album: "", duration: 0, number: 0,
      kind: "MusicArtist", imageID: nil, imageTag: nil)
  }
}
struct MusicProviderLink: Codable, Hashable, Sendable, Identifiable {
  let title: String
  let url: URL
  var id: String { url.absoluteString }
  init?(title: String, url: URL) {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil,
      parts.query == nil, parts.fragment == nil, url.absoluteString.utf8.count <= 512
    else { return nil }
    let host = (parts.host ?? "").lowercased()
    let path = parts.path
    let provider: String
    if host == "musicbrainz.org" {
      let fields = path.split(separator: "/")
      guard fields.count == 2,
        ["artist", "release", "release-group", "recording"].contains(String(fields[0])),
        UUID(uuidString: String(fields[1])) != nil
      else { return nil }
      provider = "MusicBrainz"
    } else if ["en.wikipedia.org", "wikipedia.org"].contains(host), path.hasPrefix("/wiki/"),
      path.count > 6, !path.contains(":")
    {
      provider = "Wikipedia"
    } else if ["www.discogs.com", "discogs.com"].contains(host) {
      let fields = path.split(separator: "/")
      guard fields.count == 2, ["artist", "release", "master"].contains(String(fields[0])),
        fields[1].first?.isNumber == true,
        fields[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
      else { return nil }
      provider = "Discogs"
    } else {
      return nil
    }
    self.title = provider
    self.url = url
  }
}
struct MusicRoleCredit: Codable, Hashable, Sendable {
  let name: String
  let role: String
  init?(name: String, role: String) {
    guard
      [
        "Artist", "AlbumArtist", "Composer", "Lyricist", "Conductor", "Producer", "Performer",
        "Engineer",
      ].contains(role)
    else { return nil }
    let name = MusicDetails.plain(name, limit: 96)
    guard !name.isEmpty else { return nil }
    self.name = name
    self.role = role == "AlbumArtist" ? "Album artist" : role
  }
}

struct MusicDetails: Codable, Hashable, Sendable {
  let year: Int?
  let genres: [String]
  let overview: String?
  let disc: Int?
  var labels: [String] = []
  var credits: [MusicRoleCredit] = []
  var links: [MusicProviderLink] = []
  static func plain(_ value: String, limit: Int) -> String {
    String(value.prefix(limit * 2))
      .replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit).description
  }
  func releaseYear(for kind: String) -> Int? {
    ["MusicAlbum", "Audio"].contains(kind) ? year : nil
  }
  func hasContent(for kind: String) -> Bool {
    releaseYear(for: kind) != nil || !genres.isEmpty || overview != nil || !labels.isEmpty
      || !credits.isEmpty || !links.isEmpty
  }
  init(
    year: Int? = nil, genres: [String] = [], overview: String? = nil, disc: Int? = nil,
    labels: [String] = [], credits: [MusicRoleCredit] = [], links: [MusicProviderLink] = []
  ) {
    self.year = year.flatMap { (1...9999).contains($0) ? $0 : nil }
    self.disc = disc.flatMap { (1...999).contains($0) ? $0 : nil }
    var seen = Set<String>()
    self.genres = Array(
      genres.prefix(32).compactMap { value in
        let clean = String(value.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && seen.insert(clean.lowercased()).inserted ? clean : nil
      }.prefix(8))
    let plain = String((overview ?? "").prefix(8192))
      .replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    self.overview = plain.isEmpty ? nil : String(plain.prefix(4096))
    self.labels = Array(
      Set(labels.prefix(16).map { Self.plain($0, limit: 96) }.filter { !$0.isEmpty })
    ).sorted().prefix(8).map { $0 }
    self.credits = Array(credits.prefix(24))
    var destinations = Set<URL>()
    self.links = Array(links.prefix(24).filter { destinations.insert($0.url).inserted }.prefix(8))
  }
  enum CodingKeys: String, CodingKey { case year, genres, overview, disc, labels, credits, links }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      year: try? c.decodeIfPresent(Int.self, forKey: .year),
      genres: (try? c.decodeIfPresent([String].self, forKey: .genres)) ?? [],
      overview: try? c.decodeIfPresent(String.self, forKey: .overview),
      disc: try? c.decodeIfPresent(Int.self, forKey: .disc),
      labels: (try? c.decodeIfPresent([String].self, forKey: .labels)) ?? [],
      credits: (try? c.decodeIfPresent([MusicRoleCredit].self, forKey: .credits)) ?? [],
      links: ((try? c.decodeIfPresent([MusicProviderLink].self, forKey: .links)) ?? []).compactMap {
        MusicProviderLink(title: $0.title, url: $0.url)
      })
  }
  var hasContent: Bool { hasContent(for: "MusicAlbum") }
}
struct MusicTechnicalInfo: Hashable, Sendable {
  let codec: String?
  let sampleRate: Int?
  let bitDepth: Int?
  let channels: Int?
  let bitRate: Int?
  init(
    codec: String? = nil, sampleRate: Int? = nil, bitDepth: Int? = nil, channels: Int? = nil,
    bitRate: Int? = nil
  ) {
    let name = String((codec ?? "").prefix(16)).uppercased()
    self.codec =
      !name.isEmpty && name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? name : nil
    self.sampleRate = sampleRate.flatMap { (8_000...768_000).contains($0) ? $0 : nil }
    self.bitDepth = bitDepth.flatMap { (1...64).contains($0) ? $0 : nil }
    self.channels = channels.flatMap { (1...32).contains($0) ? $0 : nil }
    self.bitRate = bitRate.flatMap { (1...50_000_000).contains($0) ? $0 : nil }
  }
  var hasContent: Bool {
    codec != nil || sampleRate != nil || bitDepth != nil || channels != nil || bitRate != nil
  }
}
struct MusicLyrics: Equatable, Sendable {
  struct Line: Equatable, Identifiable, Sendable {
    let id: Int
    let text: String
    let seconds: Double?
  }
  let lines: [Line]
  let synchronized: Bool
  static func decode(_ data: Data) throws -> Self? {
    guard data.count <= 512_000 else { throw ClientError.invalidResponse }
    struct Reply: Decodable {
      struct Metadata: Decodable {
        let offset: Double?
        enum CodingKeys: String, CodingKey { case offset = "Offset" }
      }
      struct Row: Decodable {
        let text: String
        let start: Double?
        enum CodingKeys: String, CodingKey {
          case text = "Text"
          case start = "Start"
        }
      }
      let metadata: Metadata?
      let rows: [Row]
      enum CodingKeys: String, CodingKey {
        case metadata = "Metadata"
        case rows = "Lyrics"
      }
    }
    let reply = try JSONDecoder().decode(Reply.self, from: data)
    guard reply.rows.count <= 1_000 else { throw ClientError.invalidResponse }
    let offset = reply.metadata?.offset ?? 0
    guard offset.isFinite, abs(offset) <= 36_000_000_000 else { throw ClientError.invalidResponse }
    var length = 0
    let lines = reply.rows.enumerated().compactMap { index, row -> Line? in
      let text = MusicDetails.plain(row.text, limit: 512)
      guard !text.isEmpty else { return nil }
      length += text.utf8.count
      let time = row.start.flatMap { ticks -> Double? in
        let value = ticks / 10_000_000
        return value.isFinite && (0...86_400).contains(value) ? value : nil
      }
      return Line(id: index, text: text, seconds: time)
    }
    guard length <= 100_000 else { throw ClientError.invalidResponse }
    guard !lines.isEmpty else { return nil }
    let times = lines.compactMap(\.seconds)
    let synchronized =
      offset == 0 && !times.isEmpty && times.count == lines.count
      && zip(times, times.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 }
    return Self(lines: lines, synchronized: synchronized)
  }
}
enum MusicCoverThumbnail {
  nonisolated static func make(_ data: Data) -> Data? {
    guard data.count <= 3_000_000,
      let source = CGImageSourceCreateWithData(
        data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
      width.doubleValue > 0, height.doubleValue > 0,
      width.doubleValue * height.doubleValue <= 100_000_000
    else { return nil }
    let type = CGImageSourceGetType(source) as String?
    if [UTType.jpeg.identifier, UTType.png.identifier].contains(type ?? ""),
      CGImageSourceGetCount(source) == 1, max(width.doubleValue, height.doubleValue) <= 600,
      CGImageSourceGetStatus(source) == .statusComplete
    {
      return data
    }
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
          kCGImageSourceThumbnailMaxPixelSize: 600,
        ] as CFDictionary)
    else { return nil }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }
}

struct ArtworkTone: Equatable, Sendable {
  let red: Double
  let green: Double
  let blue: Double
}
struct MusicItem: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let title: String
  let artist: String
  let album: String
  let duration: Double
  let number: Int
  let kind: String
  let imageID: String?
  let imageTag: String?
  var albumID: String? = nil
  var artistCredits: [MusicCredit]? = nil
  var details: MusicDetails? = nil
  var favorite: Bool? = nil
  var hasLyrics: Bool? = nil
  func inheritingArtwork(from album: MusicItem) -> MusicItem {
    return MusicItem(
      id: id, title: title, artist: artist, album: self.album, duration: duration,
      number: number, kind: kind, imageID: imageID ?? album.imageID,
      imageTag: imageTag ?? album.imageTag,
      albumID: albumID ?? album.id,
      artistCredits: artistCredits?.isEmpty == false ? artistCredits : album.artistCredits,
      details: details, favorite: favorite, hasLyrics: hasLyrics)
  }
  static let fixtureAlbum = MusicItem(
    id: "fixture-album", title: "The quiet hours", artist: "North Window", album: "The quiet hours",
    duration: 72, number: 0, kind: "MusicAlbum", imageID: nil, imageTag: nil)
  static var fixtureTracks: [MusicItem] {
    ["First light", "A place to return", "Slow current", "Still here"].enumerated().map {
      MusicItem(
        id: "fixture-track-\($0.offset)", title: $0.element, artist: "North Window",
        album: "The quiet hours", duration: 18, number: $0.offset + 1, kind: "Audio", imageID: nil,
        imageTag: nil)
    }
  }
}

enum MusicCategory: String, CaseIterable, Identifiable, Codable, Sendable {
  case albums = "Albums"
  case artists = "Artists"
  case songs = "Songs"
  var id: Self { self }
  var itemType: String {
    switch self {
    case .albums: "MusicAlbum"
    case .artists: "MusicArtist"
    case .songs: "Audio"
    }
  }
}
struct MusicLibrary: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
}
enum ArtistMetadataState: Sendable { case loading, available, empty, unavailable }

enum CatalogShelf: CaseIterable, Sendable {
  case discover, favorites, artists
  var section: HomeSection {
    switch self {
    case .discover: .discover
    case .favorites: .favorites
    case .artists: .artists
    }
  }
  var category: MusicCategory { self == .artists ? .artists : .albums }
  func accepts(_ kind: String?) -> Bool {
    kind == category.itemType || (self == .favorites && kind == "Audio")
  }
}
enum CatalogSort: String, CaseIterable, Identifiable, Codable, Sendable {
  case title, titleDescending, artist, album, year, recentlyAdded
  var id: Self { self }
  static func choices(for category: MusicCategory) -> [Self] {
    switch category {
    case .albums: [.title, .titleDescending, .artist, .year, .recentlyAdded]
    case .artists: [.title, .titleDescending]
    case .songs: [.title, .titleDescending, .artist, .album, .recentlyAdded]
    }
  }
  var label: String {
    switch self {
    case .title: "Title A–Z"
    case .titleDescending: "Title Z–A"
    case .artist: "Artist A–Z"
    case .album: "Album A–Z"
    case .year: "Newest year"
    case .recentlyAdded: "Recently added"
    }
  }
  var field: String {
    switch self {
    case .title, .titleDescending: "SortName"
    case .artist: "Artist,SortName"
    case .album: "Album,SortName"
    case .year: "ProductionYear,SortName"
    case .recentlyAdded: "DateCreated,SortName"
    }
  }
  var order: String {
    [.titleDescending, .year, .recentlyAdded].contains(self) ? "Descending" : "Ascending"
  }
}
struct CatalogBrowseOptions: Equatable, Sendable {
  var sort = CatalogSort.title
  var favoritesOnly = false
  var years = CatalogYearRange.all
  func isValid(for category: MusicCategory) -> Bool {
    CatalogSort.choices(for: category).contains(sort)
  }
}
struct CatalogPage: Sendable {
  let items: [MusicItem]
  let rawCount: Int
  var playedIDs: Set<String> = []
}
struct CatalogQuery: Equatable, Sendable {
  let library: String
  var category: MusicCategory = .albums
  var offset = 0
  var search = ""
  var artist: String?
  var appearancesOnly = false
  var rankArtistSongs = false
  var shelf: CatalogShelf?
  var genreID: String?
  var ids: [String] = []
  var includeDetails = false
  var options = CatalogBrowseOptions()
}
struct ArtistAppearancePage {
  struct Album: Identifiable {
    let id: String?
    let title: String
    var tracks: [MusicItem]
  }
  let id = UUID()
  let offset: Int
  let hasMore: Bool
  let albums: [Album]
  var isEmpty: Bool { offset == 0 && !hasMore && albums.isEmpty }
  init(_ page: CatalogPage, offset: Int) {
    self.offset = offset
    hasMore = page.rawCount == 40
    var indices: [String?: Int] = [:]
    var groups: [Album] = []
    for track in page.items {
      if let index = indices[track.albumID] {
        groups[index].tracks.append(track)
      } else {
        indices[track.albumID] = groups.count
        groups.append(
          Album(
            id: track.albumID, title: track.albumID == nil ? "Other songs" : track.album,
            tracks: [track]))
      }
    }
    albums = groups
  }
}
protocol MusicCatalogServing: Sendable {
  func endSession() async throws
  func verifyIdentity() async throws
  func validate(ids: [String]) async throws -> [MusicItem]
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource
  func artwork(item: MusicItem) async throws -> Data?
  func musicLibraries(refresh: Bool) async throws -> [MusicLibrary]
  func catalogYears(library: String) async throws -> CatalogYearFacet
  func homeGenres(library: String) async throws -> [HomeGenre]
  func catalog(_ query: CatalogQuery) async throws -> [MusicItem]
  func catalogPage(_ query: CatalogQuery) async throws -> CatalogPage
  func albumTracks(library: String, album: String) async throws -> [MusicItem]
  func playlists(
    library: String, isCurrent: @escaping @MainActor @Sendable () -> Bool,
    onUpdate: PlaylistUpdate?,
    onSongs: PlaylistSongsUpdate?
  )
    async throws -> [MusicPlaylist]
  func playlistTracks(
    library: String, playlistID: String, isCurrent: @escaping @MainActor @Sendable () -> Bool
  )
    async throws -> [MusicItem]
  func albumDetail(library: String, album: MusicItem) async throws -> MusicAlbumPage
  func artistDetail(library: String, artist: MusicItem) async throws -> MusicItem
  func setFavorite(
    library: String, item: MusicItem, value: Bool,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> Bool
  func trackInformation(library: String, track: MusicItem) async throws -> MusicTechnicalInfo
  func lyrics(
    library: String, track: MusicItem,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MusicLyrics?
}
struct MusicAlbumPage: Sendable {
  let album: MusicItem
  let tracks: [MusicItem]
}
extension MusicCatalogServing {
  func endSession() async throws {}
  func homeGenres(library: String) async throws -> [HomeGenre] { throw ClientError.unavailable }
  func playlists(
    library: String, isCurrent: @escaping @MainActor @Sendable () -> Bool,
    onUpdate: PlaylistUpdate? = nil
  )
    async throws -> [MusicPlaylist]
  { try await playlists(library: library, isCurrent: isCurrent, onUpdate: onUpdate, onSongs: nil) }
  func playlists(
    library: String, isCurrent: @escaping @MainActor @Sendable () -> Bool,
    onUpdate: PlaylistUpdate?,
    onSongs: PlaylistSongsUpdate?
  ) async throws -> [MusicPlaylist] { throw ClientError.unavailable }
  func playlistTracks(
    library: String, playlistID: String, isCurrent: @escaping @MainActor @Sendable () -> Bool
  )
    async throws -> [MusicItem]
  { throw ClientError.unavailable }
  func lyrics(
    library: String, track: MusicItem,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MusicLyrics? { nil }
  func setFavorite(
    library: String, item: MusicItem, value: Bool,
    isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
  ) async throws -> Bool {
    throw ClientError.unavailable
  }
  func trackInformation(library: String, track: MusicItem) async throws -> MusicTechnicalInfo {
    throw ClientError.unavailable
  }

  func catalogYears(library: String) async throws -> CatalogYearFacet {
    throw ClientError.unavailable
  }
  func catalogPage(_ query: CatalogQuery) async throws -> CatalogPage {
    let items = try await catalog(query)
    return CatalogPage(items: items, rawCount: items.count)
  }
  func albumDetail(library: String, album: MusicItem) async throws -> MusicAlbumPage {
    MusicAlbumPage(album: album, tracks: try await albumTracks(library: library, album: album.id))
  }
  func artistDetail(library: String, artist: MusicItem) async throws -> MusicItem { artist }
}
enum CatalogPagingDirection: Sendable { case stationary, earlier, later }
struct CatalogPagingGesture: Sendable {
  private var active = false
  private var intent = CatalogPagingDirection.stationary
  private var progress = 0
  private var lastAdmission: Int?
  var direction: CatalogPagingDirection {
    active && (lastAdmission == nil || progress - (lastAdmission ?? 0) >= 4) ? intent : .stationary
  }
  mutating func phase(active: Bool) {
    if active && !self.active {
      intent = .stationary
      progress = 0
      lastAdmission = nil
    }
    self.active = active
  }
  mutating func movement(from old: Int, to new: Int) {
    guard active, old != new else { return }
    let direction: CatalogPagingDirection = new > old ? .later : .earlier
    if intent == .stationary { intent = direction }
    if intent == direction { progress += abs(new - old) }
  }
  mutating func admitted() { lastAdmission = progress }
}
enum CatalogViewportOffset {
  static func clamp(
    _ proposed: Double, content: Double, viewport: Double,
    topInset: Double, bottomInset: Double
  ) -> Double {
    let minimum = -max(0, topInset)
    let maximum = max(minimum, content - viewport + max(0, bottomInset))
    return min(maximum, max(minimum, proposed))
  }
}

struct CatalogReflowAnchor: Sendable {
  struct Value: Equatable, Sendable {
    let id: String?
    let fraction: Double
  }
  struct Owner: Equatable, Sendable {
    let scope: UUID
    let revision: UUID
  }
  struct Transaction: Sendable {
    fileprivate enum Kind: Sendable { case native, restoration }
    fileprivate let receipt: UUID
    fileprivate let id: UUID
    fileprivate let owner: Owner
    fileprivate let kind: Kind
  }
  private enum Phase { case pending, delivering, restored }
  private struct Receipt {
    let id: UUID
    let value: Value?
    let owner: Owner
    var viewport: Double
    var phase: Phase
    let attachment: Bool
    var transaction: UUID?
  }
  private var receipt: Receipt?
  mutating func resolve(measured: Value?, viewport: Double) -> Value? {
    viewportChanged(to: viewport)
    guard let receipt else { return measured }
    return receipt.phase != .pending || receipt.attachment ? receipt.value ?? measured : measured
  }
  mutating func attach(_ value: Value, viewport: Double, owner: Owner) {
    receipt = Receipt(
      id: UUID(), value: value, owner: owner, viewport: viewport,
      phase: .pending, attachment: true)
  }
  mutating func prepare(measured: Value?, viewport: Double, owner: Owner) {
    viewportChanged(to: viewport)
    if let receipt, receipt.owner != owner { reset() }
    if let receipt, receipt.phase == .pending, receipt.attachment { return }
    let value = resolve(measured: measured, viewport: viewport)
    receipt = Receipt(
      id: UUID(), value: value, owner: owner, viewport: viewport,
      phase: .pending, attachment: false)
  }
  mutating func beginOwnedMutation(owner: Owner, viewport: Double) -> Transaction? {
    viewportChanged(to: viewport)
    guard var current = receipt else { return nil }
    guard current.owner == owner else {
      reset()
      return nil
    }
    guard current.value != nil, current.phase != .delivering, current.transaction == nil
    else { return nil }
    let ticket = Transaction(receipt: current.id, id: UUID(), owner: owner, kind: .native)
    current.transaction = ticket.id
    receipt = current
    return ticket
  }
  @discardableResult
  mutating func rebase(
    _ transaction: Transaction, owner: Owner, viewport: Double, refined: Bool = true
  ) -> Bool {
    guard transaction.kind == .native, var current = receipt,
      transaction.receipt == current.id, transaction.id == current.transaction,
      transaction.owner == current.owner, transaction.owner == owner
    else { return false }
    current.transaction = nil
    if current.phase == .restored && !refined {
      guard viewport == current.viewport else {
        reset()
        return false
      }
      receipt = current
      return true
    }
    current.viewport = viewport
    current.phase = .pending
    receipt = current
    return true
  }
  mutating func finish(
    owner: Owner, viewport: Double, mutationInProgress: Bool, geometryIsUsable: Bool = true
  ) -> Value? {
    guard !mutationInProgress else { return nil }
    viewportChanged(to: viewport)
    guard var current = receipt else { return nil }
    guard current.owner == owner else {
      reset()
      return nil
    }
    guard current.phase == .pending, current.transaction == nil, geometryIsUsable else {
      return nil
    }
    guard let value = current.value else {
      reset()
      return nil
    }
    current.phase = .delivering
    receipt = current
    return value
  }
  mutating func restoration(owner: Owner, viewport: Double) -> Transaction? {
    viewportChanged(to: viewport)
    guard var current = receipt else { return nil }
    guard current.owner == owner else {
      reset()
      return nil
    }
    guard current.phase == .delivering, current.transaction == nil else { return nil }
    let ticket = Transaction(receipt: current.id, id: UUID(), owner: owner, kind: .restoration)
    current.transaction = ticket.id
    receipt = current
    return ticket
  }
  func permits(_ transaction: Transaction, owner: Owner) -> Bool {
    guard transaction.kind == .restoration, let current = receipt else { return false }
    return current.id == transaction.receipt && current.transaction == transaction.id
      && current.owner == owner && transaction.owner == owner && current.phase == .delivering
  }
  @discardableResult
  mutating func didRestore(_ transaction: Transaction, viewport: Double, owner: Owner) -> Bool {
    guard permits(transaction, owner: owner), var current = receipt else { return false }
    current.phase = .restored
    current.viewport = viewport
    current.transaction = nil
    receipt = current
    return true
  }
  mutating func viewportChanged(to value: Double) {
    if let current = receipt, value != current.viewport { reset() }
  }
  mutating func reset() { receipt = nil }
}

@MainActor final class CatalogActionBinding {
  let scope: UUID
  let revision: UUID
  let category: MusicCategory
  let id: String
  private var live = true
  private let isRenderedCurrent: @MainActor () -> Bool
  init(
    scope: UUID, revision: UUID, category: MusicCategory, id: String,
    isRenderedCurrent: @escaping @MainActor () -> Bool = { true }
  ) {
    self.scope = scope
    self.revision = revision
    self.category = category
    self.id = id
    self.isRenderedCurrent = isRenderedCurrent
  }
  func retire() { live = false }
  func isCurrent(in browser: MusicBrowser) -> Bool {
    guard live, isRenderedCurrent(), browser.metadataIsCurrent, browser.scope == scope,
      browser.category == category, browser.resultsAreCurrent,
      browser.window.revision == revision
    else { return false }
    return browser.window.index(of: id) != nil
  }
}

@MainActor @Observable final class CatalogWindow {
  private(set) var revision = UUID()
  var options = CatalogBrowseOptions()
  var query = ""
  private(set) var items = CatalogRows()
  var loading = false
  var error: String?
  var loaded = false
  var anchor: String?
  var anchorFraction = 0.0
  var requestedOffset = 0
  var endOffset: Int?
  @ObservationIgnored private(set) var pages: [Int: [MusicItem]] = [:]
  @ObservationIgnored private(set) var rawCounts: [Int: Int] = [:]
  @ObservationIgnored private var positions: [String: Int] = [:]
  private(set) var firstOffset = 0
  private(set) var nextOffset = 0
  var hasNext: Bool { endOffset.map { nextOffset < $0 } ?? true }
  var hasEarlier: Bool { firstOffset > 0 }
  var needsExplicitContinuation: Bool {
    loaded && !loading && error == nil && (hasEarlier || hasNext)
  }
  var currentPageHasOmittedRows: Bool {
    (rawCounts[requestedOffset] ?? 0) > (pages[requestedOffset]?.count ?? 0)
  }
  func index(of id: String) -> Int? { positions[id] }
  func accept(
    _ batch: [MusicItem], at offset: Int, query: String,
    options: CatalogBrowseOptions = CatalogBrowseOptions(), rawCount: Int? = nil,
    replacing: Bool = false
  ) {
    if replacing || self.query != query || self.options != options {
      pages = [:]
      rawCounts = [:]
      positions = [:]
      items = CatalogRows()
      firstOffset = 0
      nextOffset = 0
      endOffset = nil
      anchor = nil
      anchorFraction = 0
      revision = UUID()
    }
    self.query = query
    self.options = options
    requestedOffset = offset
    loaded = true
    loading = false
    error = nil
    guard pages[offset] == nil else { return }
    let consumed = rawCount ?? batch.count
    if consumed < 40 { endOffset = offset + consumed }
    rawCounts[offset] = consumed
    var accepted: [MusicItem] = []
    let appending = offset >= nextOffset
    for item in batch where positions[item.id] == nil {
      positions[item.id] = items.count + accepted.count
      accepted.append(item)
    }
    pages[offset] = accepted
    items.insert(accepted, at: offset)
    if !appending {
      positions = Dictionary(
        uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
    }
    firstOffset = pages.keys.min() ?? 0
    nextOffset = max(nextOffset, offset + 40)
  }
}
struct HomeShelfState<Item: Sendable>: Sendable {
  var items: [Item] = []
  var loading = true
  var error: String?
  var loaded = false
}
