import Foundation
import Observation

@MainActor @Observable final class AlbumContent {
  private(set) var album: MusicItem
  private(set) var tracks: [MusicItem] = []
  private(set) var loading = false
  private(set) var error: String?
  private let library: String
  var authorizedLibrary: String? { isCurrent() ? library : nil }
  private let service: any MusicCatalogServing
  private let isCurrent: @MainActor () -> Bool
  private let rejected: @MainActor (ClientError) -> Void
  private var request = UUID()
  private(set) var favoritePending = false
  private(set) var favoriteError: String?
  private var favoriteTarget: Bool?
  private var favoriteRequest = UUID()
  private var favoriteRevision: UInt64 = 0
  private let favoriteChanged: @MainActor () -> Void
  var favoriteValue: Bool? { isCurrent() ? favoriteTarget ?? album.favorite : nil }
  func toggleFavorite() {
    guard isCurrent(), let current = favoriteTarget ?? album.favorite else { return }
    favoriteTarget = !current
    favoriteError = nil
    guard !favoritePending else { return }
    favoritePending = true
    let token = UUID()
    favoriteRequest = token
    Task { [weak self] in await self?.writeFavorite(token: token) }
  }
  private func writeFavorite(token: UUID) async {
    while isCurrent(), favoriteRequest == token, let target = favoriteTarget {
      do {
        let value = try await service.setFavorite(
          library: library, item: album, value: target,
          isCurrent: { [weak self] in
            self?.isCurrent() == true && self?.favoriteRequest == token
          })
        guard isCurrent(), favoriteRequest == token, !Task.isCancelled else { return }
        album.favorite = value
        favoriteRevision += 1
        favoriteChanged()
        if favoriteTarget == value {
          favoriteTarget = nil
          break
        }
      } catch {
        guard isCurrent(), favoriteRequest == token, !Task.isCancelled else { return }
        if let reason = error as? ClientError, [.unauthorized, .forbidden].contains(reason) {
          favoriteTarget = nil
          favoritePending = false
          rejected(reason)
          return
        }
        if favoriteTarget != target { continue }
        favoriteTarget = nil
        favoriteError = "Favorite couldn’t save. Try again."
        break
      }
    }
    if favoriteRequest == token { favoritePending = false }
  }
  private var acceptedLyrics: MusicLyrics?
  private var lyricAvailability: Bool?
  private var lyricsRequest = UUID()
  private(set) var lyricsLoading = false
  private(set) var lyricsError: String?
  var lyricsAvailable: Bool { isCurrent() && lyricAvailability == true }
  var lyrics: MusicLyrics? { isCurrent() ? acceptedLyrics : nil }
  private var acceptedRelatedAlbums: [MusicItem] = []
  private var acceptedRelatedArtist: MusicCredit?
  private var relatedRequest = UUID()
  private var relatedLoading = false
  private var relatedLoaded = false
  var relatedAlbums: [MusicItem] { isCurrent() ? acceptedRelatedAlbums : [] }
  var relatedArtist: MusicCredit? { isCurrent() ? acceptedRelatedArtist : nil }
  func loadLyrics() async {
    guard !Task.isCancelled, isCurrent(), album.kind == "Audio", album.hasLyrics == true,
      !lyricsLoading, acceptedLyrics == nil
    else { return }
    let token = UUID()
    lyricsRequest = token
    lyricsLoading = true
    lyricsError = nil
    defer { if lyricsRequest == token { lyricsLoading = false } }
    do {
      let value = try await service.lyrics(
        library: library, track: album,
        isCurrent: { [weak self] in
          self?.isCurrent() == true && self?.lyricsRequest == token
        })
      guard isCurrent(), lyricsRequest == token, !Task.isCancelled else { return }
      acceptedLyrics = value
      lyricAvailability = value != nil
    } catch {
      guard isCurrent(), lyricsRequest == token, !Task.isCancelled else { return }
      lyricAvailability = nil
      lyricsError = "Lyrics couldn’t load. Try again."
      if let reason = error as? ClientError, reason == .unauthorized { rejected(reason) }
    }
  }
  func loadRelatedAlbums() async {
    guard !Task.isCancelled, isCurrent(), !relatedLoading, !relatedLoaded,
      let artist = album.artistCredits?.first(where: {
        !$0.id.isEmpty && $0.id.count <= 128
          && $0.id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
          }
      })
    else { return }
    let token = UUID()
    relatedRequest = token
    relatedLoading = true
    defer { if relatedRequest == token { relatedLoading = false } }
    do {
      let items = try await service.catalog(
        CatalogQuery(library: library, category: .albums, artist: artist.id))
      guard isCurrent(), relatedRequest == token, !Task.isCancelled else { return }
      var seen = Set<String>()
      let currentAlbum = album.kind == "MusicAlbum" ? album.id : album.albumID
      acceptedRelatedAlbums = Array(
        items.filter {
          $0.kind == "MusicAlbum" && !$0.id.isEmpty && $0.id != currentAlbum
            && seen.insert($0.id).inserted
        }.prefix(8))
      acceptedRelatedArtist = artist
      relatedLoaded = true
    } catch {
      guard isCurrent(), relatedRequest == token, !Task.isCancelled else { return }
      if error as? ClientError == .unauthorized { rejected(.unauthorized) }
    }
  }
  private var acceptedArtistPortrait: MusicItem?
  private var portraitRequest = UUID()
  private var portraitLoading = false
  var artistPortrait: MusicItem? { isCurrent() ? acceptedArtistPortrait : nil }
  func loadArtistPortrait() async {
    guard !Task.isCancelled, isCurrent(), !portraitLoading,
      let credit = album.artistCredits?.first,
      acceptedArtistPortrait?.id != credit.id
    else { return }
    let ticket = UUID()
    portraitRequest = ticket
    portraitLoading = true
    defer { if portraitRequest == ticket { portraitLoading = false } }
    let item = MusicItem(
      id: credit.id, title: credit.name, artist: credit.name, album: "",
      duration: 0, number: 0, kind: "MusicArtist", imageID: nil, imageTag: nil)
    do {
      let fresh = try await service.artistDetail(library: library, artist: item)
      guard isCurrent(), portraitRequest == ticket, !Task.isCancelled,
        fresh.id == credit.id, fresh.kind == "MusicArtist"
      else { return }
      acceptedArtistPortrait = MusicItem(
        id: fresh.id, title: fresh.title, artist: fresh.artist,
        album: "", duration: 0, number: 0, kind: "MusicArtist", imageID: fresh.imageID,
        imageTag: fresh.imageTag)
    } catch {
    }
  }
  private(set) var trackInformation: MusicTechnicalInfo?
  private(set) var trackInformationLoading = false
  private(set) var trackInformationError: String?
  private var informationRequest = UUID()
  func loadTrackInformation(id: String) async {
    guard isCurrent(), let track = tracks.first(where: { $0.id == id }) else { return }
    let token = UUID()
    informationRequest = token
    trackInformation = nil
    trackInformationLoading = true
    trackInformationError = nil
    defer { if informationRequest == token { trackInformationLoading = false } }
    do {
      let value = try await service.trackInformation(library: library, track: track)
      guard isCurrent(), informationRequest == token, !Task.isCancelled else { return }
      trackInformation = value
    } catch {
      guard isCurrent(), informationRequest == token, !Task.isCancelled else { return }
      trackInformationError = "Track information couldn’t load. Try again."
    }
  }
  init(
    album: MusicItem, library: String, service: any MusicCatalogServing,
    isCurrent: @escaping @MainActor () -> Bool,
    rejected: @escaping @MainActor (ClientError) -> Void = { _ in },
    favoriteChanged: @escaping @MainActor () -> Void = {}
  ) {
    self.favoriteChanged = favoriteChanged
    self.album = album
    self.library = library
    self.service = service
    self.isCurrent = isCurrent
    self.rejected = rejected
  }
  func load() async {
    guard !Task.isCancelled, isCurrent(), !loading, !favoritePending else { return }
    let token = UUID()
    let favoriteVersion = favoriteRevision
    request = token
    informationRequest = UUID()
    trackInformation = nil
    lyricsRequest = UUID()
    acceptedLyrics = nil
    lyricAvailability = nil
    lyricsLoading = false
    lyricsError = nil
    relatedRequest = UUID()
    acceptedRelatedAlbums = []
    acceptedRelatedArtist = nil
    relatedLoading = false
    relatedLoaded = false
    portraitRequest = UUID()
    portraitLoading = false
    acceptedArtistPortrait = nil
    loading = true
    error = nil
    defer { if request == token, isCurrent() { loading = false } }
    do {
      let page: MusicAlbumPage
      if album.kind == "Audio" {
        let items = try await service.catalog(
          CatalogQuery(library: library, category: .songs, ids: [album.id], includeDetails: true))
        guard request == token, isCurrent(), !Task.isCancelled else { return }
        guard let track = items.first(where: { $0.id == album.id && $0.kind == "Audio" }) else {
          throw ClientError.forbidden
        }
        page = MusicAlbumPage(album: track, tracks: [track])
      } else {
        page = try await service.albumDetail(library: library, album: album)
      }
      guard request == token, isCurrent(), !Task.isCancelled else { return }
      var fresh = page.album
      if favoriteVersion != favoriteRevision { fresh.favorite = album.favorite }
      album = fresh
      lyricAvailability = fresh.hasLyrics
      tracks =
        fresh.kind == "Audio" ? [fresh] : page.tracks.map { $0.inheritingArtwork(from: page.album) }
      loading = false
    } catch {
      guard request == token, isCurrent(), !Task.isCancelled else { return }
      loading = false
      if let reason = error as? ClientError, [.unauthorized, .forbidden].contains(reason) {
        tracks = []
        rejected(reason)
      }
      self.error =
        album.kind == "Audio"
        ? "Track details couldn’t load. Try again." : "This album couldn’t load. Try again."
    }
  }
}
