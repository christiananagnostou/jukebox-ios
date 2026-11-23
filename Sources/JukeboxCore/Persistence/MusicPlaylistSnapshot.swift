import Foundation

struct MusicPlaylistSnapshot: Codable, Sendable {
  static let byteLimit = 12 * 1024 * 1024
  static let indexLimit = 2_048
  private let version: Int
  private let library: String
  private let playlists: [MusicPlaylist]
  private let songs: [MusicItem]
  private let orders: [String: [Int]]

  init?(library: String, playlists: [MusicPlaylist], details: [PlaylistContents]) {
    let ids = Set(playlists.map(\.id))
    guard playlists.count <= Self.indexLimit, ids.count == playlists.count else { return nil }
    version = 2
    self.library = library
    self.playlists = playlists
    var offsets: [String: Int] = [:]
    var songs: [MusicItem] = []
    var orders: [String: [Int]] = [:]
    var remaining = PlaylistDetailCache.occurrenceLimit
    for detail in details where detail.source.library == library && ids.contains(detail.source.id) {
      guard orders.count < PlaylistDetailCache.listLimit, detail.tracks.count <= remaining,
        detail.tracks.allSatisfy({ $0.kind == "Audio" && PlaylistSummaryDTO.validID($0.id) })
      else { continue }
      orders[detail.source.id] = detail.tracks.map { track in
        if let offset = offsets[track.id] { return offset }
        let offset = songs.count
        var song = track
        song.details = nil
        songs.append(song)
        offsets[song.id] = offset
        return offset
      }
      remaining -= detail.tracks.count
    }
    self.songs = songs
    self.orders = orders
  }

  struct Restored: Sendable {
    let playlists: [MusicPlaylist]
    let details: PlaylistDetailCache
  }

  func restore(library: String, scope: UUID) -> Restored? {
    guard version == 2, self.library == library, playlists.count <= Self.indexLimit,
      orders.count <= PlaylistDetailCache.listLimit,
      songs.count <= PlaylistDetailCache.occurrenceLimit,
      playlists.allSatisfy({ PlaylistSummaryDTO.validID($0.id) }),
      songs.allSatisfy({
        $0.kind == "Audio" && PlaylistSummaryDTO.validID($0.id) && $0.details == nil
      })
    else { return nil }
    let ids = Set(playlists.map(\.id))
    guard ids.count == playlists.count, Set(orders.keys).isSubset(of: ids) else { return nil }
    var cache = PlaylistDetailCache()
    var remaining = PlaylistDetailCache.occurrenceLimit
    for (id, indices) in orders {
      guard indices.count <= remaining, indices.allSatisfy(songs.indices.contains) else {
        return nil
      }
      remaining -= indices.count
      let contents = PlaylistContents(
        indices.map { songs[$0] }, source: .init(id: id, library: library, scope: scope))
      cache.insert(contents, at: nil)
    }
    return Restored(playlists: playlists, details: cache)
  }
}

struct PlaylistSnapshotAccess: Sendable {
  let storage: LibraryStorage
  let account: String
  let lease: UUID
}
