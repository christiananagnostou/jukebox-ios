import Foundation
import Observation

@MainActor @Observable final class ArtistSongs {
  private let service: any MusicCatalogServing
  private let library: String
  private let artist: String
  private let isCurrent: @MainActor () -> Bool
  private let rejected: @MainActor (Error) -> Void
  private var first: CatalogPage?
  private var complete: [MusicItem]?
  private var loadID: UUID?
  var loading: Bool { loadID != nil }
  private(set) var failed = false

  init(
    service: any MusicCatalogServing, library: String, artist: String,
    isCurrent: @escaping @MainActor () -> Bool, rejected: @escaping @MainActor (Error) -> Void
  ) {
    self.service = service
    self.library = library
    self.artist = artist
    self.isCurrent = isCurrent
    self.rejected = rejected
  }

  var hasHistory: Bool { isCurrent() && first?.playedIDs.isEmpty == false }
  var highlights: [MusicItem] {
    guard isCurrent(), let first else { return [] }
    let played = first.playedIDs
    return Array(first.items.lazy.filter { played.isEmpty || played.contains($0.id) }.prefix(5))
  }
  var allLoadedTracks: [MusicItem]? { isCurrent() ? complete : nil }

  func load() async {
    guard isCurrent(), first == nil, !Task.isCancelled else { return }
    let id = UUID()
    loadID = id
    failed = false
    defer { if loadID == id { loadID = nil } }
    do {
      let result = try await page(at: 0)
      guard loadID == id else { return }
      first = result
      if result.rawCount < 40 { complete = result.items }
    } catch {
      guard loadID == id, isCurrent(), !Task.isCancelled else { return }
      failed = true
      rejected(error)
    }
  }

  func tracksForPlayback(whileCurrent: @MainActor () -> Bool) async throws -> [MusicItem] {
    guard isCurrent(), whileCurrent(), !Task.isCancelled, let first else {
      throw CancellationError()
    }
    if let complete { return complete }
    var tracks = first.items
    var seen = Set(tracks.map(\.id))
    var offset = first.rawCount
    var rawCount = first.rawCount
    do {
      while rawCount == 40 {
        guard whileCurrent() else { throw CancellationError() }
        let result = try await page(at: offset)
        guard whileCurrent() else { throw CancellationError() }
        let next = result.items.filter { seen.insert($0.id).inserted }
        guard result.rawCount < 40 || !next.isEmpty else { throw ClientError.invalidResponse }
        tracks += next
        rawCount = result.rawCount
        offset += rawCount
      }
      complete = tracks
      return tracks
    } catch {
      if isCurrent(), whileCurrent(), !Task.isCancelled { rejected(error) }
      throw error
    }
  }

  private func page(at offset: Int) async throws -> CatalogPage {
    guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
    let page = try await service.catalogPage(
      CatalogQuery(
        library: library, category: .songs, offset: offset, artist: artist, rankArtistSongs: true))
    guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
    guard (0...40).contains(page.rawCount), page.items.count <= page.rawCount,
      page.items.allSatisfy({ $0.kind == "Audio" && !$0.id.isEmpty })
    else { throw ClientError.invalidResponse }
    return page
  }
}
