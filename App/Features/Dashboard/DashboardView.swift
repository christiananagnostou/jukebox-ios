import SwiftUI

struct DashboardView: View {
  let store: PlayerStore
  let browser: MusicBrowser
  let canvas: CGRect
  let positions: HomeScrollPositions
  let isCurrent: () -> Bool
  let open: (MusicItem) -> Void
  let openPlaylist: (MusicPlaylist) -> Void
  let openGenre: (HomeGenre) -> Void
  let customize: () -> Void

  var body: some View {
    let owner = browser.scope
    let current = { isCurrent() && browser.scope == owner && browser.metadataIsCurrent }
    let layout = browser.homeLayout
    BrowseScrollViewport(canvas: canvas) { insets, _ in
      ScrollView {
        VStack(alignment: .leading, spacing: MusicUI.section) {
          if browser.loadingLibraries || browser.libraryError != nil || browser.libraries.isEmpty {
            LibraryStatus(browser: browser).musicPagePadding()
          }
          if browser.authorizedLibrary != nil {
            ForEach(layout.visible) { section in
              VStack(alignment: .leading, spacing: 12) {
                HStack {
                  Text(section.title).font(MusicType.section).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home-heading-" + section.rawValue)
                  Spacer()
                  if [.discover, .artists, .genres].contains(section) {
                    Button {
                      if current() { load(section, force: true) }
                    } label: {
                      Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                      .accessibilityLabel("Refresh " + section.title)
                  }
                }.musicPagePadding()
                switch section {
                case .recent:
                  RecentlyPlayedView(store: store, browser: browser, open: open, isCurrent: current)
                    .task(id: owner) { await store.loadRecentAlbums() }
                case .playlists:
                  playlists(current: current)
                    .task(id: owner) { await browser.loadPlaylistIndex(scope: owner) }
                case .genres:
                  genres(current: current)
                    .onScrollVisibilityChange(threshold: 0.01) {
                      if $0, current(), browser.homeGenres.error == nil { browser.loadGenres() }
                    }
                case .favorites, .discover, .artists:
                  let shelf: CatalogShelf =
                    section == .artists
                    ? .artists : (section == .favorites ? .favorites : .discover)
                  media(shelf, current: current)
                    .onScrollVisibilityChange(threshold: 0.01) {
                      if $0, current(), browser.shelves[shelf]?.error == nil {
                        browser.loadShelf(shelf)
                      }
                    }
                }
              }
            }
            if layout.visible.isEmpty {
              ContentUnavailableView {
                Label("Your Home is empty", systemImage: "rectangle.stack")
              } actions: {
                Button("Customize Home", action: customize)
              }.padding(.top, 48)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, insets.top + 12).padding(.bottom, insets.bottom + 20)
      }
      .contentMargins(0, for: .scrollContent)
      .contentMargins(.top, insets.top, for: .scrollIndicators)
      .contentMargins(.bottom, insets.bottom, for: .scrollIndicators)
      .scrollEdgeEffectStyle(.soft, for: .vertical)
      .modifier(HomeScrollRestoration(positions: positions, section: nil, isCurrent: current))
      .accessibilityIdentifier("home-scroll")
      .refreshable {
        guard current() else { return }
        browser.loadDashboard(force: true)
        if !layout.hidden.contains(.recent) { await store.loadRecentAlbums() }
        if !layout.hidden.contains(.playlists), current() {
          await browser.loadPlaylistIndex(scope: owner, refresh: true)
        }
      }
    }
    .background(MusicUI.canvas)
    .navigationTitle("").navigationBarTitleDisplayMode(.inline)
  }

  private func load(_ section: HomeSection, force: Bool) {
    switch section {
    case .favorites: browser.loadShelf(.favorites, force: force)
    case .discover: browser.loadShelf(.discover, force: force)
    case .artists: browser.loadShelf(.artists, force: force)
    case .genres: browser.loadGenres(force: force)
    case .recent: Task { await store.loadRecentAlbums() }
    case .playlists:
      let owner = browser.scope
      Task { await browser.loadPlaylistIndex(scope: owner, refresh: force) }
    }
  }

  @ViewBuilder private func media(_ shelf: CatalogShelf, current: @escaping () -> Bool) -> some View
  {
    let state = browser.shelves[shelf] ?? HomeShelfState()
    shelfContent(
      section: shelf.section, items: state.items, loading: state.loading, error: state.error,
      empty: shelf == .favorites
        ? "Songs and albums you favorite in Jellyfin appear here."
        : "There’s no music in this shelf yet.",
      current: current
    ) { item in
      if item.kind == "MusicAlbum" {
        AlbumCard(
          store: store, album: item, browser: browser, open: { if current() { open(item) } },
          isCurrent: current)
      } else if item.kind == "MusicArtist" {
        HomeTile(
          title: item.title, subtitle: nil, actionLabel: "Open " + item.title,
          action: { if current() { open(item) } }
        ) {
          CatalogCover(
            store: store, item: item,
            origin: store.playbackOrigin(library: browser.authorizedLibrary)
          ).clipShape(.circle)
        }
      } else {
        let selection = store.playbackSelection([item], library: browser.authorizedLibrary)
        HomeTile(
          title: item.title, subtitle: item.artist, actionLabel: "Play " + item.title,
          action: {
            if current(), let selection { store.playSelection(selection) }
          }
        ) {
          CatalogCover(store: store, item: item, origin: selection?.origin)
            .overlay(alignment: .bottomTrailing) {
              Image(systemName: "play.fill").frame(width: 44, height: 44)
                .foregroundStyle(MusicUI.onTint).background(MusicUI.tint, in: .circle).padding(8)
            }
        }
      }
    }
  }

  private func playlists(current: @escaping () -> Bool) -> some View {
    let index = browser.playlistIndex
    return shelfContent(
      section: .playlists, items: Array((index.items ?? []).prefix(12)),
      loading: index.items == nil && index.error == nil, error: index.error,
      empty: "Your Jellyfin music playlists appear here.", current: current
    ) { playlist in
      HomeTile(
        title: playlist.title, subtitle: playlist.countLabel,
        actionLabel: "Open playlist " + playlist.title,
        action: { if current() { openPlaylist(playlist) } }
      ) {
        PlaylistCover(store: store, playlist: playlist, library: browser.authorizedLibrary)
      }
    }
  }

  private func genres(current: @escaping () -> Bool) -> some View {
    let state = browser.homeGenres
    return shelfContent(
      section: .genres, items: state.items, loading: !state.loaded && state.error == nil,
      error: state.error,
      empty: "Albums with a genre appear here.", current: current
    ) { genre in
      HomeTile(
        title: genre.name, subtitle: nil, actionLabel: "Open genre " + genre.name,
        action: { if current() { openGenre(genre) } }
      ) {
        HomeGenreCover(
          store: store, genre: genre,
          origin: store.playbackOrigin(library: browser.authorizedLibrary))
      }
    }
  }

  @ViewBuilder private func shelfContent<Item: Identifiable, Card: View>(
    section: HomeSection, items: [Item], loading: Bool, error: String?, empty: String,
    current: @escaping () -> Bool, @ViewBuilder card: @escaping (Item) -> Card
  ) -> some View {
    if let error {
      RetryNotice(message: error) { if current() { load(section, force: true) } }.musicPagePadding()
    }
    if !items.isEmpty || loading {
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: MusicUI.group) {
          if items.isEmpty {
            ForEach(0..<3) { _ in
              VStack(alignment: .leading, spacing: 9) {
                Rectangle().fill(.quaternary).aspectRatio(1, contentMode: .fit)
                  .clipShape(.rect(cornerRadius: section == .artists ? 100 : MusicUI.artworkRadius))
                AlbumCardLabels(title: "Album title", artist: "Artist")
              }.redacted(reason: .placeholder).frame(width: width(section)).accessibilityHidden(
                true)
            }
          } else {
            ForEach(items) { item in card(item).frame(width: width(section)) }
          }
        }.musicPagePadding()
      }.scrollIndicators(.hidden)
        .modifier(HomeScrollRestoration(positions: positions, section: section, isCurrent: current))
        .accessibilityIdentifier("home-rail-" + section.rawValue)
    } else if error == nil {
      HomeShelfNote(text: empty)
    }
  }
  private func width(_ section: HomeSection) -> CGFloat { section == .artists ? 116 : 162 }
}

private struct HomeShelfNote: View {
  let text: String
  var body: some View {
    Text(text).font(MusicType.notice).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true).musicPagePadding()
  }
}

private struct RecentlyPlayedView: View {
  let store: PlayerStore
  let browser: MusicBrowser
  let open: (MusicItem) -> Void
  let isCurrent: () -> Bool
  @Environment(\.dynamicTypeSize) private var typeSize
  var body: some View {
    if !browser.recentAlbums.isEmpty || browser.recentLoadingCount > 0 || browser.recentError != nil
    {
      VStack(alignment: .leading, spacing: 12) {
        if let error = browser.recentError {
          RetryNotice(message: error) { Task { await store.loadRecentAlbums() } }
        }
        LazyVGrid(
          columns: typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 155, maximum: 320), spacing: 10)], spacing: 10
        ) {
          if browser.recentAlbums.isEmpty && browser.recentLoadingCount > 0 {
            ForEach(0..<browser.recentLoadingCount, id: \.self) { _ in
              HStack(spacing: 0) {
                HStack(spacing: 8) {
                  Rectangle().fill(.quaternary).frame(width: 40, height: 40)
                  MusicOverflowText(text: "Album title", context: .inactive).font(
                    MusicType.secondary.weight(.semibold)
                  ).frame(
                    maxWidth: .infinity, alignment: .leading)
                }.padding(6)
                Color.clear.frame(width: 44, height: 48)
              }.background(MusicUI.quiet, in: .rect(cornerRadius: MusicUI.artworkRadius))
                .redacted(reason: .placeholder).accessibilityHidden(true)
            }
          }
          ForEach(browser.recentAlbums) { album in
            RecentAlbumButton(
              store: store, browser: browser, album: album, open: { open(album) },
              isCurrent: isCurrent)
          }
        }
      }.musicPagePadding().accessibilityIdentifier("recently-played")
    } else {
      HomeShelfNote(text: "Albums you play on this iPhone appear here.")
    }
  }
}
private struct RecentAlbumButton: View {
  let store: PlayerStore
  let browser: MusicBrowser
  let album: MusicItem
  let open: () -> Void
  let isCurrent: () -> Bool
  var body: some View {
    let origin = store.playbackOrigin(library: browser.authorizedLibrary)
    HStack(spacing: 0) {
      Button {
        if isCurrent() { open() }
      } label: {
        HStack(spacing: 8) {
          CatalogCover(store: store, item: album, origin: origin).frame(width: 40, height: 40)
          MusicOverflowText(text: album.title, context: .album(album.id)).font(
            MusicType.secondary.weight(.semibold)
          ).foregroundStyle(.primary)
        }.padding(6).contentShape(.rect)
      }.buttonStyle(MusicButtonStyle()).accessibilityLabel("Open recent album \(album.title)")
      AlbumPlaybackControl(
        store: store, browser: browser, album: album, compact: true, isCurrent: isCurrent)
    }.background(MusicUI.quiet, in: .rect(cornerRadius: MusicUI.artworkRadius))

  }
}
