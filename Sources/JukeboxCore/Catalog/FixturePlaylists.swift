import Foundation

actor FixturePlaylists {
  struct List {
    var summary: MusicPlaylist
    var tracks: [MusicItem]
    var entries: [PlaylistEditEntry]
    var cover: Data?
    var isPublic = false
    var shares: [String: Bool] = [:]

    init(_ id: String, _ title: String, tracks: [MusicItem], tag: String? = nil) {
      summary = MusicPlaylist(id: id, title: title, songCount: tracks.count, primaryImageTag: tag)
      self.tracks = tracks
      entries = tracks.enumerated().map {
        PlaylistEditEntry(track: $1.id, entry: "entry-" + String($0))
      }
    }
    var state: PlaylistEditState {
      PlaylistEditState(playlist: summary, entries: entries, canDelete: true, canShare: true)
    }
  }
  private var lists: [String: List]
  init(large: Bool) {
    let tracks = CatalogFixtures.tracks(CatalogFixtures.album(0, broadYears: false))
    let first = List(
      "fixture-playlist-morning", "Morning rotation", tracks: [tracks[0], tracks[1], tracks[0]],
      tag: "square")
    let second = List(
      "fixture-playlist-evening", "Evening rotation", tracks: [tracks[1], tracks[0], tracks[0]])
    lists = [first.summary.id: first, second.summary.id: second]
    if large {
      let list = List(
        "fixture-playlist-long", "Long rotation",
        tracks: (0..<7790).map { tracks[$0 % tracks.count] }, tag: "wide")
      lists[list.summary.id] = list
    }
  }
  func index() -> [MusicPlaylist] { lists.values.map(\.summary).sorted { $0.title < $1.title } }
  func list(_ id: String) throws -> List {
    guard let list = lists[id] else { throw ClientError.forbidden }
    return list
  }
  func sharing(_ id: String) throws -> PlaylistSharing {
    let list = try list(id)
    return PlaylistSharing(
      isPublic: list.isPublic,
      people: [
        PlaylistPerson(
          id: "fixture-listener", name: "Alex", canEdit: list.shares["fixture-listener"])
      ])
  }
  func change(state: PlaylistEditState?, _ change: PlaylistMutation) throws -> String {
    if case .create(let raw, let songs) = change {
      let id = UUID().uuidString
      lists[id] = List(id, try PlaylistMutation.name(raw), tracks: songs)
      return id
    }
    guard let state else { throw ClientError.invalidResponse }
    let id = state.playlist.id
    var list = try list(id)
    switch change {
    case .create: throw ClientError.invalidResponse
    case .rename(let name):
      list.summary = MusicPlaylist(
        id: id, title: try PlaylistMutation.name(name), songCount: list.tracks.count,
        primaryImageTag: list.summary.primaryImageTag)
    case .append(let songs):
      list.tracks += songs
      list.entries += songs.map { PlaylistEditEntry(track: $0.id, entry: UUID().uuidString) }
    case .remove(let i), .move(let i, _):
      guard list.entries == state.entries, list.tracks.indices.contains(i) else {
        throw PlaylistEditError.changed
      }
      if case .move(_, let to) = change {
        guard list.tracks.indices.contains(to) else { throw PlaylistEditError.changed }
        let track = list.tracks.remove(at: i)
        let entry = list.entries.remove(at: i)
        list.tracks.insert(track, at: to)
        list.entries.insert(entry, at: to)
      } else {
        list.tracks.remove(at: i)
        list.entries.remove(at: i)
      }
    case .cover(let data):
      list.cover = data
      list.summary.primaryImageTag = UUID().uuidString
    case .removeCover:
      list.cover = nil
      list.summary.primaryImageTag = nil
    case .visibility(let value): list.isPublic = value
    case .share(let person, let role):
      guard person == "fixture-listener" else { throw ClientError.forbidden }
      list.shares[person] = role
    case .delete:
      guard list.entries == state.entries else { throw PlaylistEditError.changed }
      lists[id] = nil
      return id
    }
    list.summary.songCount = list.tracks.count
    lists[id] = list
    return id
  }
}
