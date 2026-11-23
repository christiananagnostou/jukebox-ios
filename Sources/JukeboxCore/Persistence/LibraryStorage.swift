import Darwin
import Foundation

actor LibraryStorage {
  private var revisions: [String: UInt64] = [:]
  private var leases: [String: UUID] = [:]
  private var browseRevisions: [String: UInt64] = [:]
  private var searchRevisions: [String: UInt64] = [:]
  private var devicePreferenceRevision: UInt64 = 0
  private var recentOrder: [String: [String: UInt64]] = [:]
  private var memory: [URL: Data]?
  let directory: URL
  init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  init() {
    directory = URL(fileURLWithPath: "/preview-only")
    memory = [:]
  }
  private func read(_ url: URL) throws -> Data? {
    if let memory { return memory[url] }
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }
  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    try writeData(JSONEncoder().encode(value), to: url)
  }
  private func writeData(_ data: Data, to url: URL) throws {
    if memory != nil {
      memory![url] = data
      return
    }
    #if os(iOS)
      try data.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: url, options: .atomic)
    #endif
  }
  private func path(_ account: String) throws -> URL {
    guard account.count == 64, account.allSatisfy({ $0.isHexDigit }) else {
      throw ClientError.invalidResponse
    }
    return directory.appendingPathComponent(account + ".json")
  }
  func lease(account: String) -> UUID {
    let id = UUID()
    leases[account] = id
    revisions[account] = nil
    browseRevisions[account] = nil
    searchRevisions[account] = nil
    recentOrder[account] = [:]
    return id
  }
  func retire(account: String, erase: Bool) throws {
    leases[account] = nil
    revisions[account] = nil
    browseRevisions[account] = nil
    searchRevisions[account] = nil
    recentOrder[account] = nil
    if erase { try self.erase(account: account) }
  }
  func saveIfCurrent(_ state: QueueState, account: String, lease: UUID, revision: UInt64 = 0) throws
  {
    guard leases[account] == lease, revisions[account].map({ revision > $0 }) ?? true else {
      return
    }
    try save(state, account: account)
    revisions[account] = revision
  }
  func save(_ state: QueueState, account: String) throws {
    var clean = state
    clean.normalize()
    try write(clean, to: path(account))
  }
  func restore(account: String) throws -> QueueState? {
    guard let data = try read(path(account)) else { return nil }
    var state = try JSONDecoder().decode(QueueState.self, from: data)
    state.normalize()
    return state
  }
  func erase(account: String) throws {
    let playlistDirectory = try playlistDirectory(account)
    if let memory {
      for url in memory.keys where url.deletingLastPathComponent() == playlistDirectory {
        self.memory?[url] = nil
      }
    }
    var failure: Error?
    for url in [
      try path(account), try browsePath(account), try searchPath(account), try recentPath(account),
      playlistDirectory,
    ] {
      if memory != nil {
        memory![url] = nil
      } else if FileManager.default.fileExists(atPath: url.path) {
        do { try FileManager.default.removeItem(at: url) } catch { failure = error }
      }
    }
    if let failure { throw failure }
  }
  private struct RecentAlbum: Codable {
    let library: String
    let album: String
  }
  private func recentPath(_ account: String) throws -> URL {
    try path(account).deletingPathExtension().appendingPathExtension("recent.json")
  }
  private func recentRows(account: String) throws -> [RecentAlbum] {
    let url = try recentPath(account)
    let data: Data
    if let memory {
      guard let saved = memory[url] else { return [] }
      data = saved
    } else {
      guard FileManager.default.fileExists(atPath: url.path) else { return [] }
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      data = try file.read(upToCount: 32_769) ?? Data()
    }
    guard data.count <= 32_768 else { return [] }
    return (try? JSONDecoder().decode([RecentAlbum].self, from: data)) ?? []
  }
  private func musicIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 128
      && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
  }
  func recentAlbums(account: String, library: String) throws -> [String] {
    guard musicIdentifier(library) else { return [] }
    var seen = Set<String>()
    return Array(
      try recentRows(account: account).filter {
        $0.library == library && musicIdentifier($0.album) && seen.insert($0.album).inserted
      }.prefix(24).map(\.album))
  }
  func acceptRecentAlbum(
    account: String, lease: UUID, library: String, album: String,
    revision: UInt64? = nil
  ) throws {
    guard leases[account] == lease, musicIdentifier(library), musicIdentifier(album) else { return }
    var rows = try recentRows(account: account).filter {
      musicIdentifier($0.library) && musicIdentifier($0.album)
        && !($0.library == library && $0.album == album)
    }
    let key = library + "/" + album
    var order = recentOrder[account] ?? [:]
    if let revision, let accepted = order[key], revision <= accepted { return }
    let insertion: Int
    if let revision {
      order[key] = revision
      insertion =
        rows.firstIndex { (order[$0.library + "/" + $0.album] ?? 0) < revision }
        ?? rows.endIndex
    } else {
      insertion = 0
    }
    rows.insert(RecentAlbum(library: library, album: album), at: insertion)
    var counts: [String: Int] = [:]
    rows = rows.filter { row in
      counts[row.library, default: 0] += 1
      return counts[row.library, default: 0] <= 24
    }
    while try JSONEncoder().encode(rows).count > 32_768 { rows.removeLast() }
    let retained = Set(rows.map { $0.library + "/" + $0.album })
    recentOrder[account] = order.filter { retained.contains($0.key) }
    try write(rows, to: recentPath(account))
  }
  private func searchPath(_ account: String) throws -> URL {
    try path(account).deletingPathExtension().appendingPathExtension("search-recents.json")
  }
  private func searchRows(account: String) throws -> [RecentSearchIdentity] {
    let url = try searchPath(account)
    guard let data = try boundedData(url, maximum: 8192),
      let decoded = try? JSONDecoder().decode([RecentSearchIdentity].self, from: data),
      decoded.count <= RecentSearchIdentity.limit
    else { return [] }
    var seen = Set<RecentSearchIdentity>()
    return decoded.filter { seen.insert($0).inserted }
  }
  func searchRecents(account: String, lease: UUID, library: String) throws -> [RecentSearchIdentity]
  {
    guard leases[account] == lease else { return [] }
    return try searchRows(account: account).filter { $0.library == library }
  }
  func changeSearchRecent(
    _ value: RecentSearchIdentity, removing: Bool, account: String, lease: UUID, revision: UInt64
  ) throws {
    guard leases[account] == lease,
      searchRevisions[account].map({ revision > $0 }) ?? true
    else { return }
    var rows = try searchRows(account: account).filter { $0 != value }
    if !removing { rows.insert(value, at: 0) }
    rows = Array(rows.prefix(RecentSearchIdentity.limit))
    try write(rows, to: searchPath(account))
    searchRevisions[account] = revision
  }
  private func boundedData(_ url: URL, maximum: Int) throws -> Data? {
    if let memory {
      guard let data = memory[url], data.count <= maximum else { return nil }
      return data
    }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_size > 0, info.st_size <= maximum
    else { return nil }
    let data = try handle.read(upToCount: maximum + 1) ?? Data()
    return data.count <= maximum ? data : nil
  }
  func catalogDevicePreferences() throws -> CatalogDevicePreferences {
    let url = directory.appendingPathComponent("music-layout.json")
    guard let data = try boundedData(url, maximum: 128) else { return .init() }
    if let value = try? JSONDecoder().decode(CatalogDevicePreferences.self, from: data) {
      return value
    }
    if let layout = try? JSONDecoder().decode(CatalogLayout.self, from: data) {
      return CatalogDevicePreferences(layout: layout)
    }
    return .init()
  }
  func saveCatalogDevicePreferences(_ value: CatalogDevicePreferences, revision: UInt64) throws {
    guard revision > devicePreferenceRevision else { return }
    try write(value, to: directory.appendingPathComponent("music-layout.json"))
    devicePreferenceRevision = revision
  }
  private func browsePath(_ account: String) throws -> URL {
    try path(account).deletingPathExtension().appendingPathExtension("browse.json")
  }
  func catalogPreferences(account: String) throws -> CatalogBrowsePreferences {
    guard let data = try boundedData(browsePath(account), maximum: 8192) else {
      return CatalogBrowsePreferences()
    }
    return (try? JSONDecoder().decode(CatalogBrowsePreferences.self, from: data))
      ?? CatalogBrowsePreferences()
  }
  func saveCatalogPreferencesIfCurrent(
    _ value: CatalogBrowsePreferences, account: String, lease: UUID, revision: UInt64
  ) throws {
    guard leases[account] == lease,
      browseRevisions[account].map({ revision > $0 }) ?? true
    else { return }
    guard try JSONEncoder().encode(value).count <= 8192 else { throw ClientError.invalidResponse }
    try write(value, to: browsePath(account))
    browseRevisions[account] = revision
  }
  private func playlistDirectory(_ account: String) throws -> URL {
    try path(account).deletingPathExtension().appendingPathExtension("playlists")
      .appendingPathComponent("", isDirectory: true)
  }
  private func playlistFile(_ access: PlaylistSnapshotAccess, library: String) throws -> URL? {
    guard leases[access.account] == access.lease, musicIdentifier(library) else { return nil }
    return try playlistDirectory(access.account).appendingPathComponent(library + ".plist")
  }
  func savedPlaylists(_ access: PlaylistSnapshotAccess, library: String, scope: UUID) throws
    -> MusicPlaylistSnapshot.Restored?
  {
    guard let url = try playlistFile(access, library: library),
      let data = try boundedData(url, maximum: MusicPlaylistSnapshot.byteLimit)
    else { return nil }
    let snapshot = try PropertyListDecoder().decode(MusicPlaylistSnapshot.self, from: data)
    return snapshot.restore(library: library, scope: scope)
  }
  func savePlaylists(
    _ playlists: [MusicPlaylist], details: [PlaylistContents],
    access: PlaylistSnapshotAccess, library: String
  ) throws {
    guard let url = try playlistFile(access, library: library) else { return }
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    func encoded(_ details: [PlaylistContents]) throws -> Data? {
      guard
        let snapshot = MusicPlaylistSnapshot(
          library: library, playlists: playlists, details: details)
      else { return nil }
      let data = try encoder.encode(snapshot)
      return data.count <= MusicPlaylistSnapshot.byteLimit ? data : nil
    }
    guard let data = try encoded(details) ?? (details.isEmpty ? nil : encoded([])) else {
      try removePlaylistFile(url)
      return
    }
    if memory == nil {
      var folder = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      var attributes = URLResourceValues()
      attributes.isExcludedFromBackup = true
      try folder.setResourceValues(attributes)
    }
    try writeData(data, to: url)
  }
  private func removePlaylistFile(_ url: URL) throws {
    if memory != nil {
      memory?[url] = nil
    } else if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
  func clearPlaylists(_ access: PlaylistSnapshotAccess, library: String) throws {
    if let url = try playlistFile(access, library: library) { try removePlaylistFile(url) }
  }
  func retainPlaylistLibraries(_ ids: Set<String>, access: PlaylistSnapshotAccess) throws {
    guard leases[access.account] == access.lease else { return }
    let folder = try playlistDirectory(access.account)
    let urls: [URL]
    if let memory {
      urls = memory.keys.filter { $0.deletingLastPathComponent() == folder }
    } else {
      guard FileManager.default.fileExists(atPath: folder.path) else { return }
      urls = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil)
    }
    for url in urls
    where url.pathExtension == "plist"
      && !ids.contains(url.deletingPathExtension().lastPathComponent)
    {
      try removePlaylistFile(url)
    }
  }
  func connections() throws -> [Connection] {
    let url = directory.appendingPathComponent("connections.json")
    guard let data = try read(url) else { return [] }
    return try JSONDecoder().decode([Connection].self, from: data)
  }
  func saveConnections(_ connections: [Connection]) throws {
    try write(connections, to: directory.appendingPathComponent("connections.json"))
  }
}
