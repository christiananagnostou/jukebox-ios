import Foundation

struct FixtureCatalog {
  private actor Favorites {
    var values: [String: Bool] = [:]
    func set(_ id: String, _ value: Bool) { values[id] = value }
    func snapshot() -> [String: Bool] { values }
  }
  private let favorites = Favorites()
  private let savedLists: FixturePlaylists
  let source: URL
  let delay: Duration
  let catalogFailure: ClientError?
  let catalogDelay: Duration
  let catalogSongLimit: Int?
  let singleLibrary: Bool
  let longAlbum: Bool
  init(
    source: URL, delay: Duration = .zero, catalogFailure: ClientError? = nil,
    catalogDelay: Duration? = nil, catalogSongLimit: Int? = nil, singleLibrary: Bool = false,
    longAlbum: Bool = false
  ) {
    savedLists = FixturePlaylists(large: longAlbum)
    self.source = source
    self.delay = delay
    self.catalogFailure = catalogFailure
    self.catalogDelay = catalogDelay ?? delay
    self.catalogSongLimit = catalogSongLimit
    self.singleLibrary = singleLibrary
    self.longAlbum = longAlbum
  }
  private var availableLibraryIDs: Set<String> {
    singleLibrary ? ["fixture-music"] : ["fixture-music", "fixture-concerts"]
  }
  func setFavorite(
    library: String, item: MusicItem, value: Bool,
    isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
  ) async throws -> Bool {
    guard await isCurrent() else { throw CancellationError() }
    guard ["MusicAlbum", "Audio"].contains(item.kind),
      try await catalog(
        CatalogQuery(
          library: library,
          category: item.kind == "Audio" ? .songs : .albums, ids: [item.id])
      ).contains(where: {
        $0.id == item.id
      })
    else { throw ClientError.forbidden }
    guard await isCurrent() else { throw CancellationError() }
    await favorites.set(item.id, value)
    return value
  }
  func lyrics(
    library: String, track: MusicItem,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MusicLyrics? {
    guard await isCurrent() else { throw CancellationError() }
    guard track.kind == "Audio", track.hasLyrics == true,
      try await catalog(CatalogQuery(library: library, category: .songs, ids: [track.id])).contains(
        where: {
          $0.id == track.id && $0.hasLyrics == true
        })
    else { return nil }
    guard await isCurrent(), !Task.isCancelled else { throw CancellationError() }
    return MusicLyrics(
      lines: [
        .init(id: 0, text: "An invented morning opens slowly", seconds: 0),
        .init(id: 1, text: "Paper windows catch the light", seconds: 6),
        .init(id: 2, text: "We leave a little room for quiet", seconds: 12),
      ], synchronized: true)
  }
  func trackInformation(library: String, track: MusicItem) async throws -> MusicTechnicalInfo {
    guard track.kind == "Audio",
      try await catalog(CatalogQuery(library: library, category: .songs, ids: [track.id])).contains(
        where: { $0.id == track.id })
    else { throw ClientError.forbidden }
    return MusicTechnicalInfo(codec: "flac", sampleRate: 48000, bitDepth: 16, channels: 2)
  }
  func verifyIdentity() async throws {}
  func validate(ids: [String]) async throws -> [MusicItem] {
    ids.compactMap { CatalogFixtures.song($0, longAlbum: longAlbum) }
  }
  func media(
    library: String, trackID: String, quality: StreamQuality,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> MediaSource {
    try Task.checkCancellation()
    guard await isCurrent() else { throw CancellationError() }
    try Task.checkCancellation()
    guard availableLibraryIDs.contains(library),
      CatalogFixtures.song(trackID, longAlbum: longAlbum) != nil
    else {
      throw ClientError.forbidden
    }
    return MediaSource(url: source, quality: quality)
  }
  func artwork(item: MusicItem) async throws -> Data? {
    if item.kind == "Playlist", let list = try? await savedLists.list(item.id),
      list.summary.primaryImageTag == item.imageTag, let data = list.cover
    {
      return data
    }
    guard let tag = item.imageTag, ["wide", "portrait", "square"].contains(tag) else { return nil }
    try await Task.sleep(for: delay)
    return try? Data(
      contentsOf: source.deletingLastPathComponent().appendingPathComponent(tag + ".png"))
  }
}

enum CatalogFixtures {
  #if DEBUG
    enum Presentation {
      case absent, rejected, rightToLeft
      init(arguments: [String]) {
        guard arguments.contains(where: { $0.hasPrefix("--fixture-rtl") }) else {
          self = .absent
          return
        }
        let allowed: Set<String> = [
          "--fixture", "--muted", "--fixture-rtl", "--appearance-dark", "--large-text",
        ]
        let flags = Set(arguments)
        guard flags.count == arguments.count, flags.isSubset(of: allowed),
          flags.isSuperset(of: ["--fixture", "--muted", "--fixture-rtl"])
        else {
          self = .rejected
          return
        }
        self = .rightToLeft
      }
      var isAttempted: Bool { if case .absent = self { false } else { true } }
      var isRejected: Bool { if case .rejected = self { true } else { false } }
      func rightToLeft(currentFixture: Bool) -> Bool {
        if case .rightToLeft = self { currentFixture } else { false }
      }
      func startup<T>(normal: () -> T, isolated: () -> T) -> T {
        isRejected ? isolated() : normal()
      }
      func diagnosticLaunches(arguments: @autoclosure () -> [String]) -> (
        transport: TransportControlLaunch, profile: ProfilingLaunch, scale: IndexedCatalogLaunch
      ) {
        startup(
          normal: {
            let values = arguments()
            return (
              TransportControlLaunch(arguments: values), ProfilingLaunch(arguments: values),
              IndexedCatalogLaunch(arguments: values)
            )
          }, isolated: { (.rejected, .rejected, .rejected) })
      }
    }
  #endif
  static let albumCount = 126
  static let names = [
    "The quiet hours", "A field guide to distant weather", "Tides and timber",
    "After the last train", "Soft geometry", "The river remembers", "Small hours, wide skies",
    "Portraits of an unhurried city",
  ]
  static let artists = [
    "North Window", "Mira Sol", "The Lantern Quartet", "Étienne Marchand", "Aki Sato",
    "Elena & the Satellites",
  ]
  static let guest = MusicCredit(id: "fixture-track-guest", name: "Juniper Brass")
  static func artist(_ index: Int) -> MusicItem {
    MusicItem(
      id: "fixture-artist-\(index)", title: artists[index], artist: artists[index], album: "",
      duration: 0, number: 0, kind: "MusicArtist",
      imageID: index == 5 ? nil : "fixture-artist-\(index)",
      imageTag: index == 5 ? nil : ["portrait", "square", "wide"][index % 3],
      details: MusicDetails(
        genres: ["Instrumental"],
        overview:
          "An invented artist whose recordings explore quiet spaces, unhurried rhythms and changing light."
      ))
  }
  static func album(_ index: Int) -> MusicItem { album(index, broadYears: false) }
  static func album(_ index: Int, broadYears: Bool, longAlbum: Bool = false) -> MusicItem {
    let artist = index % artists.count
    return MusicItem(
      id: index == 0 ? "fixture-album" : "fixture-album-\(index)",
      title: names[index % names.count]
        + (index == 2 ? " · Complete orchestral soundtrack and extended anniversary edition" : "")
        + (index >= names.count ? " · Volume \(index / names.count + 1)" : ""),
      artist: artists[artist], album: names[index % names.count],
      duration: Double(trackCount(onAlbum: index, longAlbum: longAlbum) * 18), number: 0,
      kind: "MusicAlbum",
      imageID: index % 5 == 4 ? nil : (index == 0 ? "fixture-album" : "fixture-album-\(index)"),
      imageTag: index % 5 == 4 ? nil : ["wide", "portrait", "square"][index % 3],
      artistCredits: index == 2
        ? [
          MusicCredit(id: "fixture-artist-2", name: artists[2]),
          MusicCredit(id: "fixture-artist-3", name: artists[3]),
        ]
        : index == 3
          ? [
            MusicCredit(id: "fixture-artist-3", name: artists[3]),
            MusicCredit(id: "fixture-artist-1", name: artists[1]),
          ]
          : [MusicCredit(id: "fixture-artist-\(artist)", name: artists[artist])],
      details: MusicDetails(
        year: broadYears && index == 124
          ? 1700
          : broadYears && index == 125
            ? 2026
            : index == 1 ? 1951 : index == 2 ? 2025 : index == 3 ? nil : 1998 + index % 20,
        genres: ["Instrumental"],
        overview:
          "An invented album used to verify library details, compact summaries and accessible disclosure."
      ))
  }
  static func albumIndex(_ id: String) -> Int? {
    if id == "fixture-album" { return 0 }
    guard id.hasPrefix("fixture-album-"), let value = Int(id.dropFirst(14)),
      (1..<albumCount).contains(value)
    else { return nil }
    return value
  }
  private static func trackCount(onAlbum index: Int, longAlbum: Bool) -> Int {
    longAlbum && index == 3 ? 18 : 4
  }
  static func tracks(_ album: MusicItem, longAlbum: Bool = false) -> [MusicItem] {
    let titles = ["First light", "A place to return", "Slow current", "Still here"]
    return (0..<trackCount(onAlbum: albumIndex(album.id) ?? 0, longAlbum: longAlbum)).map { index in
      MusicItem(
        id: album.id == "fixture-album" ? "fixture-track-\(index)" : "\(album.id)-track-\(index)",
        title: album.id == "fixture-album-2" && index == 0
          ? "The crossing — Original motion picture soundtrack · Complete orchestral score and extended recording (anniversary remastered edition)"
          : (index < titles.count ? titles[index] : "Night train · Variation \(index - 3)"),
        artist: album.artist, album: album.title, duration: 18, number: index + 1, kind: "Audio",
        imageID: album.imageID, imageTag: album.imageTag, albumID: album.id,
        artistCredits: (album.artistCredits ?? [])
          + (album.id == "fixture-album-1" && index < 2 ? [guest] : []),
        details: MusicDetails(year: album.details?.year, disc: 1),
        favorite: index == 0
          && ["fixture-album-1", "fixture-album-11", "fixture-album-17"].contains(album.id),
        hasLyrics: index == 0 ? true : index == 1 ? false : nil)
    }
  }
  static func song(_ id: String, longAlbum: Bool = false) -> MusicItem? {
    if id.hasPrefix("fixture-track-"), let index = Int(id.dropFirst(14)), (0..<4).contains(index) {
      return tracks(album(0))[index]
    }
    guard let split = id.range(of: "-track-", options: .backwards),
      let albumIndex = albumIndex(String(id[..<split.lowerBound])),
      let index = Int(id[split.upperBound...]),
      (0..<trackCount(onAlbum: albumIndex, longAlbum: longAlbum)).contains(index)
    else { return nil }
    return tracks(album(albumIndex), longAlbum: longAlbum)[index]
  }
}
extension FixtureCatalog: MusicCatalogServing {
  private static let artistPlays = [
    "fixture-track-2": 18, "fixture-album-6-track-1": 14, "fixture-track-0": 9,
    "fixture-album-12-track-3": 6, "fixture-album-18-track-0": 3,
  ]
  func catalogPage(_ query: CatalogQuery) async throws -> CatalogPage {
    let items = try await catalog(query)
    return CatalogPage(
      items: items, rawCount: items.count,
      playedIDs: query.rankArtistSongs
        ? Set(items.lazy.map(\.id).filter { Self.artistPlays[$0] != nil }) : [])
  }
  func playlists(
    library: String, isCurrent: @escaping @MainActor @Sendable () -> Bool,
    onUpdate: PlaylistUpdate?,
    onSongs: PlaylistSongsUpdate?
  )
    async throws -> [MusicPlaylist]
  {
    if let catalogFailure { throw catalogFailure }
    guard availableLibraryIDs.contains(library) else { throw ClientError.forbidden }
    try await Task.sleep(for: catalogDelay)
    guard await isCurrent() else { throw CancellationError() }
    return await savedLists.index()
  }
  func playlistTracks(
    library: String, playlistID: String,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> [MusicItem] {
    guard availableLibraryIDs.contains(library) else { throw ClientError.forbidden }
    let ordered = try await savedLists.list(playlistID).tracks
    let allowed = try await catalog(
      CatalogQuery(library: library, category: .songs, ids: Array(Set(ordered.map(\.id)))))
    guard await isCurrent() else { throw CancellationError() }
    let ids = Set(allowed.map(\.id))
    return ordered.filter { ids.contains($0.id) }
  }
  private func album(_ index: Int) -> MusicItem {
    CatalogFixtures.album(index, broadYears: singleLibrary, longAlbum: longAlbum)
  }
  func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
    let music = MusicLibrary(id: "fixture-music", title: "Music")
    return singleLibrary
      ? [music] : [music, MusicLibrary(id: "fixture-concerts", title: "Live recordings")]
  }
  func catalogYears(library: String) async throws -> CatalogYearFacet {
    guard availableLibraryIDs.contains(library) else { throw ClientError.forbidden }
    try await Task.sleep(for: catalogDelay)
    let albums = (0..<CatalogFixtures.albumCount).map(album).filter {
      library != "fixture-concerts"
        || $0.artistCredits?.contains(where: { $0.id == "fixture-artist-3" }) == true
    }
    return try CatalogYearFacet(albums.compactMap { $0.details?.year })
  }
  func homeGenres(library: String) async throws -> [HomeGenre] {
    let albums = try await catalog(CatalogQuery(library: library, genreID: "fixture-instrumental"))
    return albums.isEmpty
      ? []
      : [
        HomeGenre(id: "fixture-instrumental", name: "Instrumental", covers: Array(albums.prefix(4)))
      ]
  }
  func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
    if let catalogFailure { throw catalogFailure }
    guard availableLibraryIDs.contains(query.library), query.offset >= 0 else {
      throw ClientError.forbidden
    }
    try await Task.sleep(for: catalogDelay)
    var result: [MusicItem]
    switch query.category {
    case .artists:
      result =
        CatalogFixtures.artists.indices.map { CatalogFixtures.artist($0) } + [
          CatalogFixtures.guest.item
        ]
    case .albums:
      result = (0..<CatalogFixtures.albumCount).map { album($0) }
      if let artist = query.artist {
        result = result.filter { $0.artistCredits?.contains(where: { $0.id == artist }) == true }
      }
    case .songs:
      result = (0..<CatalogFixtures.albumCount).flatMap {
        CatalogFixtures.tracks(album($0), longAlbum: longAlbum)
      }
      if let catalogSongLimit { result = Array(result.prefix(max(0, catalogSongLimit))) }
      if let artist = query.artist {
        result = result.filter { $0.artistCredits?.contains(where: { $0.id == artist }) == true }
        if query.appearancesOnly {
          result = result.filter { track in
            guard let id = track.albumID, let index = CatalogFixtures.albumIndex(id) else {
              return false
            }
            return album(index).artistCredits?.contains(where: { $0.id == artist }) != true
          }
        }
      }
    }
    if let genre = query.genreID, genre != "fixture-instrumental" || query.category != .albums {
      return []
    }
    if !query.ids.isEmpty { result = result.filter { query.ids.contains($0.id) } }
    if !query.search.isEmpty {
      result = result.filter {
        ($0.title + " " + $0.artist + " " + $0.album).localizedCaseInsensitiveContains(query.search)
      }
    }
    if let shelf = query.shelf {
      switch shelf {
      case .discover:
        result = (query.library == "fixture-concerts" ? [3, 9, 15] : [0, 2, 4, 6, 10, 16]).map {
          album($0)
        }
      case .favorites:
        result += result.flatMap { CatalogFixtures.tracks($0, longAlbum: longAlbum) }
      case .artists: break
      }
    }
    if query.library == "fixture-concerts" {
      let artists = Set(
        (0..<CatalogFixtures.albumCount).map(album)
          .filter { $0.artistCredits?.contains(where: { $0.id == "fixture-artist-3" }) == true }
          .flatMap { $0.artistCredits?.map(\.id) ?? [] })
      result = result.filter { item in
        item.kind == "MusicArtist"
          ? artists.contains(item.id)
          : item.artistCredits?.contains(where: { $0.id == "fixture-artist-3" }) == true
      }
    }
    guard query.options.isValid(for: query.category) else { throw ClientError.invalidResponse }
    if query.category != .artists, !query.options.years.isAll {
      result = result.filter { query.options.years.contains($0.details?.year) }
    }
    let favoriteValues = await favorites.snapshot()
    result = result.map { item in
      var value = item
      if item.kind == "MusicAlbum" {
        value.favorite =
          favoriteValues[item.id]
          ?? ["fixture-album-1", "fixture-album-11", "fixture-album-17"].contains(item.id)
      } else if item.kind == "Audio" {
        value.favorite = favoriteValues[item.id] ?? item.favorite
      }
      return value
    }
    if query.options.favoritesOnly || query.shelf == .favorites {
      switch query.category {
      case .albums:
        result = result.filter { $0.favorite == true }
      case .artists:
        result = result.filter { ["fixture-artist-0", "fixture-artist-3"].contains($0.id) }
      case .songs:
        result = result.filter { $0.favorite == true }
      }
    }
    if query.shelf == nil {
      switch query.options.sort {
      case .title: break
      case .titleDescending, .recentlyAdded: result.reverse()
      case .artist, .album:
        let sort = query.options.sort
        result = result.enumerated().sorted { a, b in
          let comparison = (sort == .artist ? a.element.artist : a.element.album)
            .localizedStandardCompare(sort == .artist ? b.element.artist : b.element.album)
          return comparison == .orderedSame ? a.offset < b.offset : comparison == .orderedAscending
        }.map(\.element)
      case .year:
        result = result.enumerated().sorted { a, b in
          let left = a.element.details?.year ?? 0
          let right = b.element.details?.year ?? 0
          return left == right ? a.offset < b.offset : left > right
        }.map(\.element)
      }
    }
    if query.rankArtistSongs {
      guard query.category == .songs, query.artist != nil else { throw ClientError.invalidResponse }
      result.sort { lhs, rhs in
        let left = Self.artistPlays[lhs.id, default: 0]
        let right = Self.artistPlays[rhs.id, default: 0]
        if left != right { return left > right }
        let order = lhs.title.localizedStandardCompare(rhs.title)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
      }
    }
    let start = min(query.offset, result.count)
    return Array(result[start..<min(start + (query.shelf == nil ? 40 : 12), result.count)])
  }
  func artistDetail(library: String, artist: MusicItem) async throws -> MusicItem {
    if artist.id == CatalogFixtures.guest.id {
      let songs = try await catalog(
        CatalogQuery(library: library, category: .songs, artist: artist.id))
      guard !songs.isEmpty else { throw ClientError.forbidden }
      return CatalogFixtures.guest.item
    }
    let associated = try await catalog(CatalogQuery(library: library, artist: artist.id))
    guard !associated.isEmpty,
      let index = CatalogFixtures.artists.indices.first(where: {
        "fixture-artist-\($0)" == artist.id
      })
    else {
      throw ClientError.forbidden
    }
    return CatalogFixtures.artist(index)
  }
  func albumDetail(library: String, album: MusicItem) async throws -> MusicAlbumPage {
    guard let fresh = try await catalog(CatalogQuery(library: library, ids: [album.id])).first
    else { throw ClientError.forbidden }
    return MusicAlbumPage(
      album: fresh, tracks: try await albumTracks(library: library, album: fresh.id))
  }
  func albumTracks(library: String, album: String) async throws -> [MusicItem] {
    guard availableLibraryIDs.contains(library),
      library != "fixture-concerts" || album != "fixture-album-1"
    else { throw ClientError.forbidden }
    try await Task.sleep(for: delay)
    guard let index = CatalogFixtures.albumIndex(album) else { throw ClientError.forbidden }
    return CatalogFixtures.tracks(self.album(index), longAlbum: longAlbum)
  }
}

extension FixtureCatalog: MusicPlaylistEditing {
  func playlistEditor(
    library: String, playlist: MusicPlaylist, isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> PlaylistEditState {
    let list = try await savedLists.list(playlist.id)
    let scoped = try await playlistTracks(
      library: library, playlistID: playlist.id, isCurrent: isCurrent)
    guard scoped.count == list.tracks.count else { throw PlaylistEditError.limitedToLibrary }
    return list.state
  }
  func playlistSharing(
    library: String, playlist: MusicPlaylist, isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> PlaylistSharing {
    _ = try await playlistEditor(library: library, playlist: playlist, isCurrent: isCurrent)
    return try await savedLists.sharing(playlist.id)
  }
  func changePlaylist(
    library: String, state: PlaylistEditState?, change: PlaylistMutation,
    isCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> PlaylistSave {
    guard availableLibraryIDs.contains(library) else { throw ClientError.forbidden }
    if let state {
      _ = try await playlistEditor(library: library, playlist: state.playlist, isCurrent: isCurrent)
    }
    switch change {
    case .create(_, let songs), .append(let songs):
      if !songs.isEmpty {
        let ids = Set(songs.map(\.id))
        let allowed = try await catalog(
          CatalogQuery(library: library, category: .songs, ids: Array(ids)))
        guard ids.isSubset(of: Set(allowed.map(\.id))), songs.allSatisfy({ $0.kind == "Audio" })
        else { throw ClientError.forbidden }
      }
    default: break
    }
    guard await isCurrent(), !Task.isCancelled else { throw CancellationError() }
    return PlaylistSave(id: try await savedLists.change(state: state, change))
  }
}
