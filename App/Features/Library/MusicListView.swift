import SwiftUI

struct MusicListView: View {
  @Bindable var store: PlayerStore
  @Bindable var browser: MusicBrowser
  let open: (MusicItem) -> Void
  var title = "Music"
  var artist = false
  let libraryBounds: CGRect
  var openPlaylist: ((MusicPlaylist, UUID) -> Void)? = nil
  let search: (String, MusicCategory) -> Void
  @State private var sheet: MusicBrowseSheet?
  @Environment(\.layoutDirection) private var direction
  @State private var showingPlaylists = false
  @State private var createPlaylist = false
  @State private var createdPlaylist: MusicPlaylist?
  @State private var playlistPosition: MusicPlaylist.ID?

  var body: some View {
    BrowseScrollViewport(canvas: libraryBounds) { insets, _ in
      if let openPlaylist, showingPlaylists {
        let owner = browser.scope
        PlaylistLibraryView(
          store: store, browser: browser, scope: owner, position: $playlistPosition,
          insets: insets
        ) { playlist in
          guard browser.scope == owner, browser.metadataIsCurrent else { return }
          openPlaylist(playlist, owner)
        }.id(owner).scrollEdgeEffectStyle(.soft, for: .vertical)
      } else {
        catalog(insets: insets)
      }
    }
    .safeAreaBar(edge: .top, spacing: 0) {
      if artist {
        browseControls
      } else {
        LibraryBrowseControls(
          category: browser.category, showingPlaylists: showingPlaylists,
          select: { category in
            showingPlaylists = category == nil
            if let category { browser.selectCategory(category) }
            sheet = nil
          }
        ) {
          if showingPlaylists {
            Button {
              createPlaylist = true
            } label: {
              MusicUtilityLabel(title: "New playlist", symbol: "plus")
            }
            .accessibilityIdentifier("playlist-create").disabled(browser.authorizedLibrary == nil)
          } else {
            filterButton
          }
          CatalogLayoutButton(store: store, library: true)
        }
      }
    }
    .background(MusicUI.canvas)
    .navigationTitle(artist ? title : "").navigationBarTitleDisplayMode(.inline)
    .task(id: artist && browser.category == .albums ? browser.scope : nil) {
      if artist, browser.category == .albums, browser.appearancePage == nil {
        await browser.loadAppearances()
      }
    }
    .onChange(of: browser.scope) { _, _ in
      sheet = nil
      showingPlaylists = false
      createPlaylist = false
      createdPlaylist = nil
      playlistPosition = nil
    }
    .onChange(of: browser.category) { _, _ in sheet = nil }
    .sheet(
      isPresented: $createPlaylist,
      onDismiss: {
        if let playlist = createdPlaylist, let openPlaylist {
          openPlaylist(playlist, browser.scope)
        }
        createdPlaylist = nil
      }
    ) {
      NavigationStack {
        PlaylistCreateForm(browser: browser, scope: browser.scope) { id in
          createdPlaylist = browser.playlistIndex.items?.first { $0.id == id }
          createPlaylist = false
        }.toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { createPlaylist = false }
          }
        }
      }.presentationDragIndicator(.visible)
    }
    .sheet(item: $sheet) { input in
      MusicBrowseSheetView(store: store, browser: browser, input: input)
        .environment(\.layoutDirection, direction)
    }
  }
  private func catalog(insets: EdgeInsets) -> some View {
    let owner = browser.scope
    let category = browser.category
    let layout = store.catalogLayout
    let query = browser.window.query
    let revision = browser.window.revision
    let emptyLibrary = !browser.loadingLibraries && browser.libraries.isEmpty
    let artistAlbums = artist && category == .albums && browser.metadataIsCurrent
    let emptyResults =
      browser.resultsAreCurrent && browser.window.items.isEmpty
      && (!artistAlbums || browser.appearancePage?.isEmpty == true)
    let headerVisible = browser.libraryError != nil || emptyLibrary
    let footerVisible =
      browser.window.error != nil || browser.window.loading
      || browser.loadingLibraries || browser.window.needsExplicitContinuation || emptyResults
      || artistAlbums
    let current = {
      browser.scope == owner && browser.metadataIsCurrent && browser.category == category
        && browser.normalizedSearch == query && browser.window.revision == revision
        && browser.resultsAreCurrent
    }
    return CatalogCollection(
      browser: browser, layout: layout, insets: insets, showsHeader: headerVisible,
      showsFooter: footerVisible
    ) {
      VStack(alignment: .leading, spacing: 0) {
        if let error = browser.libraryError {
          RetryNotice(message: error) { Task { await browser.loadLibraries() } }
        } else if emptyLibrary {
          MusicEmptyState(
            title: "No music libraries", systemImage: "music.note",
            message: "Check Music library access for this account in Jellyfin.")
        }
      }
    } footer: {
      VStack(alignment: .leading, spacing: 0) {
        if let error = browser.window.error {
          RetryNotice(message: error) { browser.retryListing() }.padding(.vertical, 16)
        }
        if browser.window.loading || browser.loadingLibraries {
          if browser.window.items.isEmpty {
            MusicBrowseSkeleton(category: category, layout: layout)
          }
          Color.clear.frame(height: browser.window.items.isEmpty ? 1 : MusicUI.target)
            .accessibilityLabel("Updating music")
            .accessibilityIdentifier("music-loading")
        } else if browser.window.needsExplicitContinuation {
          CatalogPageContinuation(
            browser: browser, scope: owner, category: category,
            query: query, revision: revision)
        } else if emptyResults {
          MusicEmptyState(
            title: "No \(category.rawValue.lowercased()) yet",
            systemImage: "magnifyingglass", message: "Try another filter or music library.")
        }
        if artistAlbums {
          ArtistAppearanceSection(store: store, browser: browser, open: open, search: search)
        }
      }
    } row: { item, bindingIsCurrent in
      let actionsAreCurrent = { bindingIsCurrent() && current() }
      if layout == .grid {
        if category == .artists {
          Button {
            if actionsAreCurrent() { open(item) }
          } label: {
            VStack(alignment: .leading, spacing: 8) {
              CatalogCover(
                store: store, item: item,
                origin: store.playbackOrigin(library: browser.authorizedLibrary))
              MusicOverflowText(text: item.title, context: .artist(item.id))
                .font(MusicType.primary.weight(.medium)).foregroundStyle(.primary)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.buttonStyle(MusicButtonStyle()).accessibilityLabel("Open artist " + item.title)
            .accessibilityIdentifier("artist-" + item.id)
        } else if category == .songs {
          CatalogSongCard(
            store: store, track: item, open: open, find: search,
            selection: store.playbackSelection([item], library: browser.authorizedLibrary),
            actionsAreCurrent: actionsAreCurrent)
        } else {
          AlbumCard(
            store: store, album: item, browser: browser,
            open: { if actionsAreCurrent() { open(item) } }, isCurrent: actionsAreCurrent)
        }
      } else if category == .artists {
        CatalogArtistRow(
          store: store, artist: item,
          origin: store.playbackOrigin(library: browser.authorizedLibrary),
          open: { if actionsAreCurrent() { open(item) } })
      } else if category == .albums {
        CatalogAlbumRow(
          store: store, album: item, browser: browser, isCurrent: actionsAreCurrent,
          open: { if actionsAreCurrent() { open(item) } })
      } else {
        CatalogSongRow(
          store: store, track: item, open: open, find: search,
          selection: store.playbackSelection([item], library: browser.authorizedLibrary),
          actionsAreCurrent: actionsAreCurrent)
      }
    }
  }
  private var categories: [MusicCategory] {
    MusicCategory.allCases.filter { !artist || $0 != .artists }
  }
  private var browseControls: some View {
    HStack(spacing: 4) {
      MusicCategoryTabs(
        selection: browser.category, categories: categories, select: browser.selectCategory)
      Spacer(minLength: 4)
      filterButton
      CatalogLayoutButton(store: store)
    }.buttonStyle(MusicButtonStyle()).musicPagePadding().padding(.vertical, 4)
      .accessibilityElement(children: .contain).accessibilityIdentifier("music-browse-controls")
  }
  private var filterButton: some View {
    Button {
      sheet = MusicBrowseSheet(owner: browser.scope, category: browser.category)
    } label: {
      MusicUtilityLabel(title: "Sort & filter", symbol: "slider.horizontal.3")
        .overlay(alignment: .topTrailing) {
          if browser.options != CatalogBrowseOptions() {
            Circle().fill(MusicUI.tint).frame(width: 5, height: 5).padding(5)
              .allowsHitTesting(false).accessibilityHidden(true)
          }
        }
    }.accessibilityIdentifier("music-sort-filter").accessibilityValue(
      browser.options.sort.label + (browser.options.favoritesOnly ? ", Favorites" : ", All")
    ).accessibilityAddTraits(browser.options != CatalogBrowseOptions() ? [.isSelected] : [])
  }
}

struct CatalogLayoutButton: View {
  let store: PlayerStore
  var library = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    Button {
      store.toggleCatalogLayout()
    } label: {
      MusicUtilityLabel(
        title: store.catalogLayout == .grid ? "Grid" : "List",
        symbol: store.catalogLayout == .grid ? "square.grid.2x2" : "list.bullet"
      )
      .contentTransition(library && !reduceMotion ? .symbolEffect(.replace) : .identity)
      .animation(
        library && !reduceMotion ? .easeOut(duration: 0.16) : nil, value: store.catalogLayout)
    }.accessibilityLabel("Layout").accessibilityValue(
      store.catalogLayout == .grid ? "Grid" : "List"
    )
    .accessibilityHint("Switch between grid and list").accessibilityIdentifier("music-layout")
  }
}
