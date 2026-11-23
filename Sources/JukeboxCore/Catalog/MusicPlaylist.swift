import Foundation

struct MusicPlaylist: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let title: String
  var songCount: Int? = nil
  var primaryImageTag: String? = nil

  var artworkItem: MusicItem? {
    guard let primaryImageTag else { return nil }
    return MusicItem(
      id: id, title: title, artist: "", album: "", duration: 0, number: 0,
      kind: "Playlist", imageID: id, imageTag: primaryImageTag)
  }
}

struct MusicPlaylistIndex {
  var items: [MusicPlaylist]?
  var restoring = false
  var loading = false
  var error: String?
  var revision = 0

  func permitsOpening(_ id: String) -> Bool {
    items?.contains(where: { $0.id == id }) != false
  }
}

typealias PlaylistUpdate = @MainActor @Sendable ([MusicPlaylist]) -> Void
typealias PlaylistSongsUpdate = @MainActor @Sendable (String, [MusicItem]) -> Void

struct PlaylistDetailCache: Sendable {
  static let listLimit = 8
  static let occurrenceLimit = 16_384
  static let freshness: Duration = .seconds(60)
  private struct Entry {
    let contents: PlaylistContents
    var verified: ContinuousClock.Instant?
  }
  private var recent: [Entry] = []

  var verifiedContents: [PlaylistContents] {
    recent.compactMap { $0.verified == nil ? nil : $0.contents }
  }
  func verified(_ id: String, since time: ContinuousClock.Instant) -> Bool {
    recent.contains { $0.contents.source.id == id && $0.verified.map { $0 >= time } == true }
  }
  func contents(for id: String, freshAt time: ContinuousClock.Instant? = nil) -> PlaylistContents? {
    guard let entry = recent.first(where: { $0.contents.source.id == id }) else { return nil }
    if let time, entry.verified.map({ $0.duration(to: time) < Self.freshness }) != true {
      return nil
    }
    return entry.contents
  }
  mutating func insert(_ contents: PlaylistContents, at time: ContinuousClock.Instant? = .now) {
    remove(contents.source.id)
    let count = contents.tracks.count
    guard count <= Self.occurrenceLimit else { return }
    var remaining = Self.occurrenceLimit - count
    recent = Array(
      recent.prefix(Self.listLimit - 1).prefix { entry in
        remaining -= entry.contents.tracks.count
        return remaining >= 0
      })
    recent.insert(Entry(contents: contents, verified: time), at: 0)
  }
  mutating func remove(_ id: String) { recent.removeAll { $0.contents.source.id == id } }
  mutating func finishIndex(_ ids: Set<String>, started: ContinuousClock.Instant) {
    recent.removeAll { !ids.contains($0.contents.source.id) }
    for index in recent.indices where recent[index].verified.map({ $0 < started }) == true {
      recent[index].verified = nil
    }
  }
}

struct PlaylistContents: Sendable {
  struct Source: Sendable {
    let id: String
    let library: String
    let scope: UUID
    let revision = UUID()
  }
  struct Row: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
      let trackID: String
      let occurrence: Int
    }
    let id: ID
    let index: Int
  }
  let tracks: [MusicItem]
  let allAudio: Bool
  let rows: [Row]
  let source: Source
  init(_ tracks: [MusicItem], source: Source) {
    self.source = source
    self.tracks = tracks
    allAudio = !tracks.isEmpty && tracks.allSatisfy { $0.kind == "Audio" }
    var counts: [String: Int] = [:]
    rows = tracks.enumerated().map { index, track in
      let occurrence = counts[track.id, default: 0]
      counts[track.id] = occurrence + 1
      return Row(id: .init(trackID: track.id, occurrence: occurrence), index: index)
    }
  }
}

struct PlaylistSummaryDTO: Decodable {
  static let confirmedMusic = CodingUserInfoKey(rawValue: "confirmed-music-playlists")!
  let id: String?
  private(set) var canDelete = false
  let needsMusicProof: Bool
  let playlist: MusicPlaylist?
  private enum CodingKeys: String, CodingKey {
    case kind = "Type"
    case media = "MediaType"
    case id = "Id"
    case title = "Name"
    case childCount = "ChildCount"
    case canDelete = "CanDelete"
    case images = "ImageTags"
  }
  init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    guard try fields.decodeIfPresent(String.self, forKey: .kind) == "Playlist" else {
      id = nil
      needsMusicProof = false
      playlist = nil
      return
    }
    let media = try fields.decodeIfPresent(String.self, forKey: .media)
    needsMusicProof = media == nil || media == "Unknown"
    guard media == "Audio" || needsMusicProof else {
      id = nil
      playlist = nil
      return
    }
    let id = try fields.decode(String.self, forKey: .id)
    guard Self.validID(id) else { throw ClientError.invalidResponse }
    self.id = id
    canDelete = (try? fields.decode(Bool.self, forKey: .canDelete)) == true
    let verifiedCount = (decoder.userInfo[Self.confirmedMusic] as? [String: Int])?[id]
    guard let verifiedCount else {
      playlist = nil
      return
    }
    let name = try fields.decodeIfPresent(String.self, forKey: .title) ?? ""
    let tag = (try? fields.decode([String: String].self, forKey: .images))?["Primary"]
    playlist = MusicPlaylist(
      id: id, title: name.isEmpty ? "Untitled playlist" : name,
      songCount: verifiedCount,
      primaryImageTag: tag.flatMap { !$0.isEmpty && $0.utf8.count <= 128 ? $0 : nil })
  }
  static func validID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 128
      && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
  }
}

func playlistTrackKey(_ id: String) -> String {
  if id.utf8.count == 36, let uuid = UUID(uuidString: id) {
    return uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
  if id.utf8.count == 32,
    id.utf8.allSatisfy({
      (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
    })
  {
    return id.lowercased()
  }
  return id
}

struct PlaylistManifest: Decodable {
  let itemIDs: [String]
  private enum CodingKeys: String, CodingKey { case itemIDs = "ItemIds" }
}

struct PlaylistEntryDTO: Decodable {
  let trackID: String?
  let parentID: String?
  private enum CodingKeys: String, CodingKey {
    case kind = "Type"
    case id = "Id"
    case parent = "ParentId"
  }
  init(from decoder: any Decoder) throws {
    let f = try decoder.container(keyedBy: CodingKeys.self)
    guard try f.decodeIfPresent(String.self, forKey: .kind) == "Audio" else {
      trackID = nil
      parentID = nil
      return
    }
    let id = try f.decode(String.self, forKey: .id)
    guard PlaylistSummaryDTO.validID(id) else { throw ClientError.invalidResponse }
    trackID = id
    let parent = try? f.decode(String.self, forKey: .parent)
    parentID = parent.flatMap { PlaylistSummaryDTO.validID($0) ? playlistTrackKey($0) : nil }
  }
}

struct PlaylistMusicFolder: Decodable {
  let id: String?
  private enum CodingKeys: String, CodingKey {
    case kind = "Type"
    case id = "Id"
  }
  init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    guard ["Folder", "MusicAlbum"].contains(try fields.decode(String.self, forKey: .kind)) else {
      id = nil
      return
    }
    let value = try fields.decode(String.self, forKey: .id)
    id = PlaylistSummaryDTO.validID(value) ? playlistTrackKey(value) : nil
  }
}

struct PlaylistWirePage<Row: Decodable & Sendable>: Decodable, Sendable {
  let items: [Row]
  let total: Int
  let start: Int?
  private enum CodingKeys: String, CodingKey {
    case items = "Items"
    case total = "TotalRecordCount"
    case start = "StartIndex"
  }
}
