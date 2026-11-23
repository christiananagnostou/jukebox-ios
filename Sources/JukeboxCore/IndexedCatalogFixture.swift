#if DEBUG || CATALOG_SCALE_FIXTURE
  import Foundation

  struct IndexedCatalogInput: Sendable {
    let id: UUID
    let songCount: Int
    let interactive: Bool
    let cleanup: Bool
    init?(arguments: [String]) {
      let values = arguments.filter { $0.hasPrefix("--catalog-scale=") }
      let controls = ["--catalog-scale-ui", "--catalog-scale-cleanup"]
      guard arguments.contains("--fixture"), values.count == 1,
        !arguments.contains(where: { $0.hasPrefix("--integration") || $0.hasPrefix("--profile-") }),
        arguments.filter({ $0 == "--catalog-scale-ui" }).count <= 1,
        arguments.filter({ $0 == "--catalog-scale-cleanup" }).count <= 1,
        !arguments.contains(where: {
          $0.hasPrefix("--catalog-scale") && !$0.hasPrefix("--catalog-scale=")
            && !controls.contains($0)
        }),
        !(arguments.contains("--catalog-scale-ui") && arguments.contains("--catalog-scale-cleanup"))
      else { return nil }
      let parts = values[0].dropFirst("--catalog-scale=".count).split(
        separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
        let count = Int(parts[1]), [50_000, 100_000].contains(count)
      else { return nil }
      self.id = id
      songCount = count
      interactive = arguments.contains("--catalog-scale-ui")
      cleanup = arguments.contains("--catalog-scale-cleanup")
    }
    var directory: String { "JukeboxScale/" + id.uuidString }
  }

  enum IndexedCatalogLaunch {
    case absent
    case rejected
    case accepted(IndexedCatalogInput)
    init(arguments: [String]) {
      guard arguments.contains(where: { $0.hasPrefix("--catalog-scale") }) else {
        self = .absent
        return
      }
      self = IndexedCatalogInput(arguments: arguments).map(Self.accepted) ?? .rejected
    }
    var input: IndexedCatalogInput? {
      if case .accepted(let input) = self { return input }
      return nil
    }
    var isRejected: Bool {
      if case .rejected = self { return true }
      return false
    }
    var isAttempted: Bool {
      if case .absent = self { return false }
      return true
    }
    func startup<Value>(
      normal: () -> Value, accepted: (IndexedCatalogInput) -> Value,
      rejected: () -> Value
    ) -> Value {
      switch self {
      case .absent: normal()
      case .accepted(let input): accepted(input)
      case .rejected:
        rejected()
      }
    }
  }

  actor IndexedCatalogFixture: MusicCatalogServing {
    static let library = "scale-music"
    let songCount: Int
    private let source: URL
    private var queries = 0
    private var constructed = 0
    private var maximumBatch = 0
    init(songCount: Int, source: URL) {
      precondition([50_000, 100_000].contains(songCount))
      self.songCount = songCount
      self.source = source
    }
    func snapshot() -> [String: Int] {
      ["queries": queries, "constructed_rows": constructed, "maximum_batch": maximumBatch]
    }
    func verifyIdentity() async throws {}
    func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
      [MusicLibrary(id: Self.library, title: "Indexed invented music")]
    }
    private func total(_ category: MusicCategory) -> Int {
      switch category {
      case .albums: songCount / 4
      case .artists: 100
      case .songs: songCount
      }
    }
    private func prefix(_ category: MusicCategory) -> String {
      switch category {
      case .albums: "Album"
      case .artists: "Artist"
      case .songs: "Song"
      }
    }
    private func identity(_ category: MusicCategory, _ index: Int) -> String {
      "scale-" + prefix(category).lowercased() + "-" + String(index)
    }
    private func index(_ id: String, _ category: MusicCategory) -> Int? {
      let head = "scale-" + prefix(category).lowercased() + "-"
      guard id.hasPrefix(head), let value = Int(id.dropFirst(head.count)),
        (0..<total(category)).contains(value), identity(category, value) == id
      else { return nil }
      return value
    }
    private func item(_ category: MusicCategory, _ index: Int) -> MusicItem {
      constructed += 1
      let album = category == .songs ? index / 4 : index
      let artist = category == .artists ? index : album % 100
      let title = String(format: "%@ %06d", prefix(category), index)
      let artistName = String(format: "Artist %06d", artist)
      return MusicItem(
        id: identity(category, index), title: title, artist: artistName,
        album: category == .artists ? "" : String(format: "Album %06d", album),
        duration: category == .songs ? 18 : 0,
        number: category == .songs ? index % 4 + 1 : 0, kind: category.itemType,
        imageID: nil, imageTag: nil,
        albumID: category == .songs ? identity(.albums, album) : nil,
        artistCredits: [MusicCredit(id: identity(.artists, artist), name: artistName)])
    }
    func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
      guard query.library == Self.library, query.offset >= 0, query.ids.count <= 40 else {
        throw ClientError.forbidden
      }
      guard query.options == CatalogBrowseOptions() else { throw ClientError.invalidResponse }
      try Task.checkCancellation()
      queries += 1
      let category = query.shelf?.category ?? query.category
      let artist: Int?
      if let value = query.artist {
        guard category != .artists, let parsed = index(value, .artists) else {
          throw ClientError.forbidden
        }
        artist = parsed
      } else {
        artist = nil
      }
      func belongs(_ value: Int) -> Bool {
        artist == nil || (category == .songs ? value / 4 : value) % 100 == artist
      }
      var selected: [Int]
      let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
      if !query.ids.isEmpty {
        selected = query.ids.compactMap { index($0, category) }.filter(belongs)
        selected = Array(selected.dropFirst(query.offset).prefix(40))
      } else if !search.isEmpty {
        let parts = search.split(separator: " ")
        guard query.offset == 0, parts.count == 2,
          parts[0].caseInsensitiveCompare(prefix(category)) == .orderedSame,
          let value = Int(parts[1]), (0..<total(category)).contains(value), belongs(value)
        else { return [] }
        selected = [value]
      } else {
        let count = total(category) / (artist == nil ? 1 : 100)
        let limit = query.shelf == nil ? 40 : 12
        let start = min(query.offset, count)
        selected = (start..<min(start + limit, count)).map { position in
          guard let artist else { return position }
          return category == .songs
            ? (position / 4 * 100 + artist) * 4 + position % 4 : position * 100 + artist
        }
      }
      maximumBatch = max(maximumBatch, selected.count)
      return selected.map { item(category, $0) }
    }
    func albumTracks(library: String, album: String) async throws -> [MusicItem] {
      guard library == Self.library, let album = index(album, .albums) else {
        throw ClientError.forbidden
      }
      return (0..<4).map { item(.songs, album * 4 + $0) }
    }
    func validate(ids: [String]) async throws -> [MusicItem] {
      guard ids.count <= 120 else { throw ClientError.forbidden }
      return ids.compactMap { id in index(id, .songs).map { item(.songs, $0) } }
    }
    func media(
      library: String, trackID: String, quality: StreamQuality,
      isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> MediaSource {
      try Task.checkCancellation()
      guard await isCurrent() else { throw CancellationError() }
      try Task.checkCancellation()
      guard library == Self.library, index(trackID, .songs) != nil else {
        throw ClientError.forbidden
      }
      return MediaSource(url: source, quality: quality)
    }
    func artwork(item: MusicItem) async throws -> Data? { nil }
  }
#endif
