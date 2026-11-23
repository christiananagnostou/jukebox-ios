import Foundation

enum PlaylistEditError: Error, LocalizedError, Equatable {
  case readOnly, changed, ambiguousEntry, limitedToLibrary, invalidName, uncertain,
    coverPermission

  var errorDescription: String? {
    switch self {
    case .readOnly: "You don’t have permission to make this change."
    case .changed: "The playlist changed. Reopen the editor to use its latest order."
    case .ambiguousEntry:
      "Jellyfin gives these copies the same entry ID, so it can’t edit just this copy."
    case .limitedToLibrary: "This playlist includes items outside the selected Music library."
    case .invalidName: "Enter a playlist name of 1 to 128 characters."
    case .uncertain: "The change couldn’t be confirmed. Refresh the playlist before trying again."
    case .coverPermission: "This Jellyfin account can’t change playlist artwork."
    }
  }
}

struct PlaylistPerson: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let canEdit: Bool?
}

struct PlaylistSharing: Sendable {
  let isPublic: Bool
  let people: [PlaylistPerson]
}

struct PlaylistEditEntry: Decodable, Equatable, Sendable {
  let track: String
  let entry: String?
  init(track: String, entry: String?) {
    self.track = playlistTrackKey(track)
    self.entry = entry
  }
  private enum CodingKeys: String, CodingKey {
    case type = "Type"
    case track = "Id"
    case entry = "PlaylistItemId"
  }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard try c.decode(String.self, forKey: .type) == "Audio" else {
      throw PlaylistEditError.limitedToLibrary
    }
    let track = try c.decode(String.self, forKey: .track)
    guard PlaylistSummaryDTO.validID(track) else { throw ClientError.invalidResponse }
    let entry = try c.decodeIfPresent(String.self, forKey: .entry)
    self.init(track: track, entry: entry.flatMap { PlaylistSummaryDTO.validID($0) ? $0 : nil })
  }
}

struct PlaylistEditState: Sendable {
  let playlist: MusicPlaylist
  let entries: [PlaylistEditEntry]
  let canDelete: Bool
  let canShare: Bool
  private let ambiguous: Set<String>
  private let ambiguousDestinations: Set<Int>

  init(playlist: MusicPlaylist, entries: [PlaylistEditEntry], canDelete: Bool, canShare: Bool) {
    self.playlist = playlist
    self.entries = entries
    self.canDelete = canDelete
    self.canShare = canShare
    var seen = Set<String>()
    var duplicates = Set<String>()
    var destinations = Set<Int>()
    for (position, row) in entries.enumerated() {
      guard let id = row.entry.map(playlistTrackKey) else { continue }
      if !seen.insert(id).inserted {
        duplicates.insert(id)
        if position + 1 < entries.count - 1 { destinations.insert(position + 1) }
      }
    }
    ambiguous = duplicates
    ambiguousDestinations = destinations
  }
  func permitsMove(to position: Int) -> Bool {
    entries.indices.contains(position) && !ambiguousDestinations.contains(position)
  }
  func entryID(at index: Int) -> String? {
    guard entries.indices.contains(index), let id = entries[index].entry,
      !ambiguous.contains(playlistTrackKey(id))
    else { return nil }
    return id
  }
}

enum PlaylistMutation: Sendable {
  case rename(String)
  case append([MusicItem])
  case remove(Int)
  case move(Int, Int)
  case delete
  case cover(Data)
  case removeCover
  case visibility(Bool)
  case share(String, Bool?)
  case create(String, [MusicItem])

  var changesSharingOnly: Bool {
    switch self {
    case .share, .visibility: true
    default: false
    }
  }
  var changesTracks: Bool {
    switch self {
    case .append, .remove, .move, .delete: true
    default: false
    }
  }

  static func name(_ raw: String) throws -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 128,
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw PlaylistEditError.invalidName
    }
    return name
  }
}

struct PlaylistSave: Identifiable, Sendable {
  let id: String
  var notice: String? = nil

  static func addition(id: String, previous: [String], requested: [String], saved: [String?])
    -> Self
  {
    let expected = previous + requested
    if saved.elementsEqual(expected, by: { $0 == $1 }) { return Self(id: id) }
    var seen = Set(previous)
    let uniqueAdditions = requested.filter { seen.insert($0).inserted }
    if saved.elementsEqual(previous + uniqueAdditions, by: { $0 == $1 }) {
      let skipped = requested.count - uniqueAdditions.count
      return Self(
        id: id,
        notice: skipped == 1
          ? "Jellyfin skipped one repeated song."
          : "Jellyfin skipped " + String(skipped) + " repeated songs.")
    }
    return Self(
      id: id,
      notice:
        "Jellyfin returned a different song order. Check the saved playlist before adding more songs."
    )
  }
}

protocol MusicPlaylistEditing: Sendable {
  func playlistEditor(
    library: String, playlist: MusicPlaylist, isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> PlaylistEditState
  func playlistSharing(
    library: String, playlist: MusicPlaylist, isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> PlaylistSharing
  func changePlaylist(
    library: String, state: PlaylistEditState?, change: PlaylistMutation,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> PlaylistSave
}
