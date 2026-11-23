#if DEBUG
  import Foundation
  import SwiftUI

  @MainActor enum CatalogAcceptance {
    static func run(api: JellyfinClient, store: PlayerStore, checkCover: Bool = false) async throws
      -> [String: Any]
    {
      func require(_ value: Bool, _ step: String) throws {
        if !value { throw DevelopmentAcceptance.CheckFailure(step: step) }
      }
      _ = try await DevelopmentAcceptance.readyBrowser(store: store)
      let roots = try await api.musicLibraries(refresh: true)
      try require(roots.count == 2, "catalog-authorized-music-roots")
      var paged = false
      for root in roots {
        let first = try await api.catalog(CatalogQuery(library: root.id))
        let second = try await api.catalog(CatalogQuery(library: root.id, offset: 40))
        guard !second.isEmpty else { continue }
        try require(first.count == 40 && second.count == 6, "catalog-real-second-page")
        try require(Set((first + second).map(\.id)).count == 46, "catalog-page-unique")
        let found = try await api.catalog(
          CatalogQuery(library: root.id, search: "Catalog Album 044"))
        try require(found.count == 1 && found[0].kind == "MusicAlbum", "catalog-album-search")
        if checkCover {
          try require(found[0].imageTag != nil, "catalog-invented-cover-positive-control")
          guard let owner = store.browser else {
            throw DevelopmentAcceptance.CheckFailure(step: "catalog-cover-owner")
          }
          owner.selectLibrary(root.id)
          guard let detail = owner.detail(found[0]) else {
            throw DevelopmentAcceptance.CheckFailure(step: "catalog-cover-detail")
          }
          await detail.load()
          await store.loadCover(found[0])
          try require(
            detail.tracks.count == 1 && store.cover(found[0]) != nil,
            "catalog-shared-cover-displayed-with-tracks")
        }
        let artists = try await api.catalog(
          CatalogQuery(library: root.id, category: .artists, search: "Fixture Ensemble"))
        try require(artists.count == 1 && artists[0].kind == "MusicArtist", "catalog-artist-search")
        let related = try await api.catalog(CatalogQuery(library: root.id, artist: artists[0].id))
        let relatedNext = try await api.catalog(
          CatalogQuery(library: root.id, offset: 40, artist: artists[0].id))
        try require(
          related.count == 40 && relatedNext.count == 5,
          "catalog-artist-relationship-pages-\(related.count)-\(relatedNext.count)")
        let songs = try await api.catalog(
          CatalogQuery(library: root.id, category: .songs, search: "Catalog song 044"))
        try require(
          songs.count == 1 && songs[0].albumID == found[0].id
            && songs[0].artistCredits?.contains(where: { $0.id == artists[0].id }) == true,
          "catalog-song-canonical-relationships")
        let artistSongs = try await api.catalog(
          CatalogQuery(library: root.id, category: .songs, artist: artists[0].id))
        try require(artistSongs.count == 40, "catalog-artist-songs")
        let detailed = try await api.albumDetail(library: root.id, album: found[0])
        try require(
          detailed.album.id == found[0].id && detailed.tracks.count == 1,
          "catalog-stock-album-details")
        let artistDetail = try await api.artistDetail(library: root.id, artist: artists[0])
        try require(
          artistDetail.id == artists[0].id && artistDetail.kind == "MusicArtist",
          "catalog-stock-rooted-artist-detail")
        let tracks = try await api.albumTracks(library: root.id, album: found[0].id)
        try require(
          tracks.count == 1 && tracks[0].id == songs[0].id, "catalog-canonical-album-tracks")
        for shelf in CatalogShelf.allCases {
          let rows = try await api.catalog(
            CatalogQuery(library: root.id, category: shelf.category, shelf: shelf))
          try require(
            rows.count <= 12 && rows.allSatisfy { shelf.accepts($0.kind) }, "catalog-bounded-shelf"
          )
        }
        guard let selection = store.playbackSelection(songs, library: root.id) else {
          throw DevelopmentAcceptance.CheckFailure(step: "catalog-song-origin")
        }
        store.playSelection(selection)
        for _ in 0..<60 {
          if store.playing && store.queue.position > 0.2 { break }
          try await Task.sleep(for: .milliseconds(100))
        }
        try require(
          store.playing && store.current?.track.id == songs[0].id && store.queue.position > 0.2,
          "catalog-song-native-canonical-playback")
        store.pause()
        paged = true
      }
      try require(paged, "catalog-real-paging-not-exercised")
      return [
        "music_roots": roots.count, "first_page": 40, "second_page": 6,
        "album_artist_song_search": true, "artist_album_and_song_relationships": true,
        "bounded_shelves": true, "canonical_song_native_clock": true,
        "stock_album_and_rooted_artist_detail": true,
      ]
    }
  }
  struct MusicTextFixture: View {
    @State private var allowed = true
    @State private var parentAllowed = true
    @State private var reduced = false
    @State private var voiceOver = false
    @State private var inactive = false
    @State private var renamed = false
    @State private var wide = false
    @State private var large = false
    @State private var rtl = false
    @State private var showText = true
    @State private var taps = 0
    var body: some View {
      NavigationStack {
        VStack(spacing: 12) {
          LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
            Button("Eligibility") { allowed.toggle() }
            Button("Parent allowance") { parentAllowed.toggle() }
            Button("Reduce motion") { reduced.toggle() }
            Button("VoiceOver") { voiceOver.toggle() }
            Button("Scene phase") { inactive.toggle() }
            Button("Rename") { renamed.toggle() }
            Button("Width") { wide.toggle() }
            Button("Font") { large.toggle() }
            Button("Direction") { rtl.toggle() }
            Button("Retire") { showText.toggle() }
          }.font(MusicType.support).buttonStyle(.bordered)
          Text("Actions: \(taps)").accessibilityIdentifier("text-action-count")
          ScrollView {
            VStack(alignment: .leading, spacing: 24) {
              if showText {
                HStack(spacing: 8) {
                  MusicOverflowText(
                    text: renamed
                      ? "A different name · Completely revised invented recording"
                      : "An unhurried crossing · Complete invented orchestral soundtrack",
                    context: .reading
                  )
                  .font(large ? MusicType.identity : MusicType.primary)
                  .accessibilityIdentifier("text-motion-reading")
                  Button("More") { taps += 1 }.frame(width: 44, height: 44)
                    .accessibilityIdentifier("text-motion-action")
                }.frame(width: wide ? 290 : 210)
              }
              Rectangle().fill(.white).frame(width: 180, height: 12)
                .mask { MusicTextFade() }.accessibilityElement(children: .ignore)
                .accessibilityLabel("Trailing fade witness").accessibilityIdentifier(
                  "text-fade-witness")
              MusicOverflowText(text: "Short", context: .reading).font(MusicType.primary)
                .frame(width: 210).accessibilityIdentifier("text-motion-short")
              MusicOverflowText(
                text: "A quiet ordinary browse row with a long invented album title",
                context: .browsing
              ).font(MusicType.primary).frame(width: 210)
                .accessibilityIdentifier("text-motion-browse")
              MusicOverflowText(text: "", context: .reading).font(MusicType.primary)
                .frame(width: 210).accessibilityIdentifier("text-motion-empty")
              Color.clear.frame(height: 1000)
              Text("End of invented scroll").accessibilityIdentifier("text-scroll-end")
            }.padding(20)
          }.accessibilityIdentifier("text-motion-scroll")
            .musicTextMotion(allowed: allowed)
            .environment(\.musicTextTestReduceMotion, reduced)
            .environment(\.musicTextTestVoiceOver, voiceOver)
            .environment(\.scenePhase, inactive ? .inactive : .active)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .environment(\.musicTextDiagnostics, true)
        }.musicTextMotion(allowed: parentAllowed).background(MusicUI.canvas).navigationTitle(
          "Invented text motion")
      }
    }
  }
  struct ArtworkSizingFixture: View {
    @State private var index = 0
    @State private var loaded = false
    private let names = ["wide", "portrait", "square", "invalid"]
    private var data: Data? {
      guard loaded else { return nil }
      if names[index] == "invalid" { return Data([0, 1, 2]) }
      return try? Data(
        contentsOf: Bundle.main.resourceURL!.appendingPathComponent(
          "Fixtures/" + names[index] + ".png"))
    }
    var body: some View {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            Text(names[index]).font(.title).accessibilityIdentifier("art-case")
            HStack(spacing: 20) {
              CoverArt(data: data, demo: false).frame(width: 128, height: 128)
              Text("Reserved title and artist").accessibilityIdentifier("art-label")
            }
            CoverArt(data: data, demo: false).frame(width: 260, height: 260)
            HStack {
              CoverArt(data: data, demo: false).frame(width: 48, height: 48)
              Text("Reserved row title")
            }
            Button(loaded ? "Reset artwork" : "Load artwork") { loaded.toggle() }
            Button("Next artwork case") { index = (index + 1) % names.count }
          }.padding(20)
        }.navigationTitle("Invented artwork bounds")
      }
    }
  }
#endif
