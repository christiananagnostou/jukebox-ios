import SwiftUI

struct ArtistAppearanceSection: View {
  let store: PlayerStore
  let browser: MusicBrowser
  let open: (MusicItem) -> Void
  let search: (String, MusicCategory) -> Void

  var body: some View {
    let page = browser.appearancePage
    let owner = browser.scope
    let library = browser.authorizedLibrary
    let current = {
      browser.metadataIsCurrent(scope: owner, library: library) && browser.category == .albums
        && browser.appearancePage?.id == page?.id
    }
    if let page, !page.albums.isEmpty || page.offset > 0 || page.hasMore {
      VStack(alignment: .leading, spacing: 12) {
        Text("Appears On").font(MusicType.section).accessibilityAddTraits(.isHeader)
        ForEach(page.albums) { album in
          VStack(alignment: .leading, spacing: 0) {
            Text(album.title).font(MusicType.primary.weight(.semibold)).accessibilityAddTraits(
              .isHeader)
            ForEach(album.tracks) { track in
              CatalogSongRow(
                store: store, track: track, open: open, find: search,
                selection: store.playbackSelection([track], library: library), albumRow: true,
                actionsAreCurrent: current)
            }
          }
        }
        if page.offset > 0 || page.hasMore {
          HStack {
            if page.offset > 0 {
              Button("Earlier appearances") {
                if current() { Task { await browser.loadAppearances(at: page.offset - 40) } }
              }
            }
            Spacer()
            if page.hasMore {
              Button("More appearances") {
                if current() { Task { await browser.loadAppearances(at: page.offset + 40) } }
              }
            }
          }.font(MusicType.control).frame(minHeight: 44).disabled(browser.appearancesLoading)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 24)
    }
    if browser.appearancesLoading {
      ProgressView("Loading appearances…").font(MusicType.notice).padding(.vertical, 12)
    } else if let offset = browser.appearanceFailure {
      RetryNotice(message: "Appearances couldn’t load.") {
        if current() { Task { await browser.loadAppearances(at: offset) } }
      }
    }
  }
}

struct ArtistDetailView: View {
  let store: PlayerStore
  let parent: MusicBrowser
  let artist: MusicItem
  let canvas: CGRect
  let open: (MusicItem, MusicBrowser) -> Void
  let browse: (MusicCategory, MusicBrowser) -> Void
  @Binding var connection: Connection?
  let isCurrent: () -> Bool
  let search: (String, MusicCategory, MusicBrowser) -> Void
  @State private var model: MusicBrowser?
  @State private var showInformation = false

  var body: some View {
    Group {
      if let model {
        let owner = model.scope
        ArtistOverview(
          store: store, model: model, artist: artist, canvas: canvas,
          isCurrent: { isCurrent() && model.metadataIsCurrent && model.scope == owner },
          open: { open($0, model) }, browse: { browse($0, model) },
          search: { search($0, $1, model) }, about: { showInformation = true }
        )
        .id(owner)
        .musicTextMotion(allowed: !showInformation)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            MusicHeaderActions(
              store: store, browser: model, context: owner,
              isCurrent: { isCurrent() && model.scope == owner && model.metadataIsCurrent },
              connection: $connection)
          }.sharedBackgroundVisibility(.hidden)
        }
      } else {
        ProgressView("Loading artist…")
      }
    }.task {
      if model == nil { model = parent.artistBrowser(artist) }
    }.sheet(isPresented: $showInformation) {
      MusicInformationSheet(title: "Artist information", closeID: "close-artist-information") {
        if let model, model.metadataIsCurrent {
          let owner = model.scope
          let library = model.authorizedLibrary
          MusicHeroTitle(text: artist.title)
          if let details = model.artistMetadata?.details, details.hasContent(for: "MusicArtist") {
            MusicMetadataContent(
              details: details, kind: "MusicArtist",
              isCurrent: {
                model.metadataIsCurrent(scope: owner, library: library)
              })
          } else {
            switch model.artistMetadataState {
            case .loading: ProgressView("Loading artist details…").font(MusicType.notice)
            case .empty:
              Text("Jellyfin hasn’t supplied additional details for this artist.").font(
                MusicType.notice
              ).foregroundStyle(.secondary)
            case .unavailable, .available:
              RetryNotice(message: "Artist details couldn’t load.") {
                Task { await model.loadArtistMetadata(artist) }
              }
            }
          }
        }
      }
    }
  }
}

private struct ArtistOverview: View {
  let store: PlayerStore
  let model: MusicBrowser
  let artist: MusicItem
  let canvas: CGRect
  let isCurrent: () -> Bool
  let open: (MusicItem) -> Void
  let browse: (MusicCategory) -> Void
  let search: (String, MusicCategory) -> Void
  let about: () -> Void
  @State private var songs: ArtistSongs?
  @State private var position = ScrollPosition()
  @State private var distance: CGFloat = 0

  var body: some View {
    let library = model.authorizedLibrary
    let owner = model.scope
    let current = { isCurrent() && model.metadataIsCurrent(scope: owner, library: library) }
    BrowseScrollViewport(canvas: canvas) { insets, height in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ArtistHero(
            store: store, artist: model.artistMetadata, name: artist.title,
            origin: store.playbackOrigin(library: library), topInset: insets.top,
            readableHeight: height)
          VStack(alignment: .leading, spacing: MusicUI.section) {
            ArtistProfileActions(
              store: store, songs: songs, library: library, isCurrent: current, about: about)
            VStack(alignment: .leading, spacing: 4) {
              sectionHeading(
                songs?.hasHistory == true ? "Your most played" : "Songs",
                link: "All songs", category: .songs, current: current)
              if let songs, !songs.highlights.isEmpty {
                let highlights = songs.highlights
                let selection = store.playbackSelection(highlights, library: library)
                ForEach(highlights.enumerated(), id: \.element.id) { index, track in
                  ArtistHighlightRow(
                    store: store, track: track, rank: index + 1, selection: selection,
                    isCurrent: current, open: open, search: search)
                }
              } else if songs?.failed == true {
                RetryNotice(message: "Songs couldn’t load.") {
                  if current() { Task { await songs?.load() } }
                }
              } else if songs == nil || songs?.loading == true {
                ProgressView().accessibilityLabel("Loading artist songs")
              } else {
                Text("No songs in this library.").font(MusicType.primary).foregroundStyle(
                  .secondary)
              }
            }
            VStack(alignment: .leading, spacing: 4) {
              sectionHeading("Discography", link: "All albums", category: .albums, current: current)
              if let error = model.window.error {
                RetryNotice(message: error) { if current() { model.retryListing() } }
              } else if model.window.items.isEmpty && model.window.loading {
                ProgressView().accessibilityLabel("Loading releases")
              } else if model.window.items.isEmpty {
                Text("No albums in this view.").font(MusicType.primary).foregroundStyle(.secondary)
              }
              ForEach(model.window.items.prefix(3)) { album in
                CatalogAlbumRow(
                  store: store, album: album, browser: model, isCurrent: current,
                  open: { if current() { open(album) } },
                  subtitle: album.details?.releaseYear(for: "MusicAlbum").map(String.init))
              }
            }
            ArtistAppearanceSection(store: store, browser: model, open: open, search: search)
          }.musicPagePadding().frame(maxWidth: 960).frame(maxWidth: .infinity)
            .padding(.top, 10).padding(.bottom, insets.bottom + 20)
        }
      }
      .contentMargins(0, for: .scrollContent)
      .contentMargins(.top, insets.top, for: .scrollIndicators)
      .contentMargins(.bottom, insets.bottom, for: .scrollIndicators)
      .scrollEdgeEffectStyle(.soft, for: .vertical)
      .scrollPosition($position)
      .onAppear { if distance > 0 { position.scrollTo(y: distance) } }
      .onScrollPhaseChange { old, new, context in
        guard new == .idle, old != .tracking, current() else { return }
        let value = context.geometry.contentOffset.y + context.geometry.contentInsets.top
        if value.isFinite { distance = max(0, value) }
      }
      .accessibilityIdentifier("artist-scroll")
    }
    .background(MusicUI.canvas).navigationTitle("").navigationBarTitleDisplayMode(.inline)
    .task {
      if songs == nil { songs = model.songsForArtist(artist) }
      async let tracks: Void? = songs?.load()
      async let metadata: Void = loadMetadata()
      if model.appearancePage == nil { await model.loadAppearances() }
      _ = await (tracks, metadata)
    }
  }

  private func loadMetadata() async {
    if model.artistMetadata == nil { await model.loadArtistMetadata(artist) }
  }

  private func sectionHeading(
    _ title: String, link: String, category: MusicCategory,
    current: @escaping () -> Bool
  ) -> some View {
    HStack {
      Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      Button(link) { if current() { browse(category) } }
        .font(MusicType.control).foregroundStyle(.secondary).frame(minHeight: 44)
        .accessibilityIdentifier(category == .songs ? "artist-all-songs" : "artist-all-albums")
    }
  }
}

struct ArtistCatalogView: View {
  let store: PlayerStore
  let parent: MusicBrowser
  let artist: MusicItem
  let category: MusicCategory
  let canvas: CGRect
  @Binding var connection: Connection?
  let open: (MusicItem, MusicBrowser) -> Void
  let search: (String, MusicCategory, MusicBrowser) -> Void
  @State private var model: MusicBrowser?

  var body: some View {
    Group {
      if let model {
        let owner = model.scope
        MusicListView(
          store: store, browser: model,
          open: { if model.scope == owner && model.metadataIsCurrent { open($0, model) } },
          title: artist.title, artist: true, libraryBounds: canvas,
          search: { if model.scope == owner && model.metadataIsCurrent { search($0, $1, model) } }
        )
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            MusicHeaderActions(
              store: store, browser: model, context: owner,
              isCurrent: { model.scope == owner && model.metadataIsCurrent },
              connection: $connection)
          }.sharedBackgroundVisibility(.hidden)
        }
      } else {
        ProgressView("Loading music…")
      }
    }.task { if model == nil { model = parent.artistBrowser(artist, category: category) } }
  }
}
