import SwiftUI

private enum MainTab: Hashable { case dashboard, search, music }

private struct ShellMenuIdentity: Hashable {
  let account: String?
  let scope: UUID?
  let tab: MainTab
}

private enum BrowseRoute: Hashable {
  case item(MusicItem)
  case scopedItem(CatalogResultRoute)
  case artistCatalog(CatalogResultRoute, MusicCategory)
  case playlist(MusicPlaylist, scope: UUID)
  case genre(HomeGenre, scope: UUID)

  var usesGlass: Bool {
    switch self {
    case .item(let item): item.kind == "MusicAlbum" || item.kind == "MusicArtist"
    case .scopedItem(let route): route.item.kind == "MusicAlbum" || route.item.kind == "MusicArtist"
    case .artistCatalog, .playlist: true
    case .genre: false
    }
  }
}

private struct CatalogResultRoute: Hashable {
  let item: MusicItem
  let browser: MusicBrowser
  let scope: UUID
  let library: String
  @MainActor var isCurrent: Bool {
    browser.metadataIsCurrent && browser.scope == scope && browser.authorizedLibrary == library
  }
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.scope == rhs.scope && lhs.item == rhs.item && lhs.browser === rhs.browser
  }
  func hash(into hasher: inout Hasher) {
    hasher.combine(scope)
    hasher.combine(item)
    hasher.combine(ObjectIdentifier(browser))
  }
}

struct BrowserShell: View {
  @Bindable var store: PlayerStore
  @Bindable var browser: MusicBrowser
  @State private var tab = MainTab.dashboard
  @State private var hasPlayback = false
  @State private var dashboardPath: [BrowseRoute] = []
  @State private var musicPath: [BrowseRoute] = []
  @State private var searchPath: [BrowseRoute] = []
  @State private var accountSheet: AccountSheet?
  @State private var pendingRoute: MusicItem?
  @State private var relatedError: String?
  @State private var searchModel: MusicBrowser?
  @State private var homePositions = HomeScrollPositions()
  @State private var homeEditor: UUID?
  @State private var searchPositions = SearchResultPositions()
  @FocusState private var headerSearchFocused: Bool
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.horizontalSizeClass) private var sizeClass
  var body: some View {
    GeometryReader { shell in
      let bounds = shell.frame(in: .global)
      let safe = shell.safeAreaInsets
      let browseBounds = CGRect(
        x: bounds.minX, y: bounds.minY - safe.top, width: bounds.width,
        height: bounds.height + safe.top + safe.bottom)
      TabView(selection: tabSelection) {
        Tab("Home", systemImage: "house", value: MainTab.dashboard) {
          navigation(path: $dashboardPath, canvas: browseBounds) {
            let owner = browser.scope
            DashboardView(
              store: store, browser: browser, canvas: browseBounds, positions: homePositions,
              isCurrent: {
                tab == .dashboard && (dashboardPath.isEmpty || sizeClass == .regular)
                  && browser.scope == owner
              },
              open: open, openPlaylist: { append(.playlist($0, scope: owner)) },
              openGenre: { append(.genre($0, scope: owner)) }, customize: { homeEditor = owner }
            )
            .id(owner)
          }
        }
        Tab("Search", systemImage: "magnifyingglass", value: MainTab.search) {
          let account = store.active?.id
          let owner = browser.scope
          navigation(path: $searchPath, canvas: browseBounds) {
            SearchDestination(
              store: store, parent: browser, model: $searchModel, open: openScopedItem,
              focused: $headerSearchFocused, canvas: browseBounds, positions: searchPositions,
              isCurrent: {
                tab == .search && searchRootIsVisible && store.active?.id == account
                  && browser.scope == owner
              })
          }
        }
        Tab("Library", systemImage: "folder", value: MainTab.music) {
          navigation(path: $musicPath, canvas: browseBounds) {
            let owner = browser.scope
            MusicListView(
              store: store, browser: browser, open: open,
              libraryBounds: browseBounds,
              openPlaylist: { playlist, visibleScope in
                guard tab == .music, browser.scope == visibleScope else { return }
                append(.playlist(playlist, scope: visibleScope))
              },
              search: { find($0, $1, source: browser, owner: owner) })
          }
        }
      }
      .tabViewStyle(.tabBarOnly)
      .tabViewBottomAccessory(isEnabled: hasPlayback && !typeSize.isAccessibilitySize) {
        PlaybackAccessory(
          store: store,
          systemGlass: sizeClass == .regular || (activePath.wrappedValue.last?.usesGlass ?? true))
      }
    }
    .playlistActions(store: store)
    .musicTextMotion(allowed: accountSheet == nil && !store.showPlayer && !store.showQueue)
    .background { PlaybackPresenceObserver(store: store, present: $hasPlayback) }
    .task { await browser.start() }
    .onReceive(NotificationCenter.default.publisher(for: ProfilingRun.browseNotification)) { _ in
      guard ProfilingRun.isEnabled, store.isFixture else { return }
      Task { await profilingBrowse() }
    }
    .onChange(of: browser.scope) { _, _ in
      headerSearchFocused = false
      searchModel?.retire()
      searchModel = nil
      searchPositions = SearchResultPositions()
      homePositions = HomeScrollPositions()
      homeEditor = nil
      dashboardPath = []
      musicPath = []
      searchPath = []
      accountSheet = nil
      if let pendingRoute {
        musicPath = [.item(pendingRoute)]
        self.pendingRoute = nil
      }
    }
    .onChange(of: searchModel?.scope) { _, _ in searchPath = [] }
    .onChange(of: tab) { _, value in
      if value != .search { headerSearchFocused = false }
    }
    .sheet(isPresented: Binding(get: { homeEditor != nil }, set: { if !$0 { homeEditor = nil } })) {
      if let owner = homeEditor, owner == browser.scope {
        HomeLayoutEditor(browser: browser, scope: owner)
      }
    }
    .sheet(item: $accountSheet) { sheet in
      switch sheet {
      case .details(let account):
        if store.active?.id == account.id
          || store.connections.contains(where: { $0.id == account.id })
        {
          ConnectionDetails(store: store, connection: account)
        }
      case .quickConnect(let account):
        if store.active?.id == account.id { QuickConnectApproval(store: store, account: account) }
      }
    }
    .sheet(isPresented: $store.showPlayer) {
      PlayerScreen(
        store: store,
        related: { item, origin in related(item, origin: origin) }
      )
      .playlistActions(store: store)
      .environment(\.musicTextMotionAllowed, true).environment(\.dynamicTypeSize, typeSize)
    }
    .sheet(isPresented: $store.showQueue) {
      NavigationStack { QueueScreen(store: store, standalone: true) }.playlistActions(store: store)
        .environment(
          \.musicTextMotionAllowed, true
        ).environment(
          \.dynamicTypeSize, typeSize
        )
        .presentationDragIndicator(.visible)
    }
    .alert(
      "Music couldn’t open",
      isPresented: Binding(get: { relatedError != nil }, set: { if !$0 { relatedError = nil } })
    ) {
      Button("OK") { relatedError = nil }
    } message: {
      Text(relatedError ?? "")
    }
  }
  private var searchRootIsVisible: Bool { sizeClass == .regular || searchPath.isEmpty }
  private var activePath: Binding<[BrowseRoute]> {
    switch tab {
    case .dashboard: $dashboardPath
    case .search: $searchPath
    case .music: $musicPath
    }
  }
  private var tabSelection: Binding<MainTab> {
    Binding(
      get: { tab },
      set: { value in
        if value == tab {
          if value == .search, searchRootIsVisible, searchModel != nil {
            headerSearchFocused = true
          }
        } else {
          headerSearchFocused = false
          tab = value
        }
      })
  }
  private func profilingBrowse() async {
    guard ProfilingRun.isEnabled, store.isFixture else { return }
    func settle() async { try? await Task.sleep(for: .seconds(1)) }
    for _ in 0..<3 {
      guard !Task.isCancelled, store.isFixture else { return }
      tab = .music
      musicPath = []
      browser.selectCategory(.albums)
      await settle()
      if let item = browser.window.items.dropFirst(12).first { browser.setAnchor(item.id) }
      await settle()
      if let item = browser.window.items.last { browser.setAnchor(item.id) }
      await settle()
      if ProcessInfo.processInfo.arguments.contains("--profile-albums"),
        let album = browser.window.items.first
      {
        open(album)
        await settle()
        musicPath = []
        await settle()
      }
      browser.selectCategory(.artists)
      await settle()
      if let artist = browser.window.items.first { open(artist) }
      await settle()
      musicPath = []
      browser.selectCategory(.songs)
      await settle()
      if let item = browser.window.items.dropFirst(16).first { browser.setAnchor(item.id) }
      await settle()
      find("quiet", .albums)
      await settle()
      searchModel?.selectCategory(.songs)
      await settle()
      musicPath = []
      tab = .dashboard
      await settle()
    }
  }
  private func navigation<Content: View>(
    path: Binding<[BrowseRoute]>, canvas: CGRect, @ViewBuilder content: () -> Content
  ) -> some View {
    Group {
      if sizeClass == .regular {
        NavigationSplitView {
          content().toolbar { controls() }.modifier(MusicNavigationChrome(glass: true))
            .navigationSplitViewColumnWidth(
              min: 360, ideal: 460, max: 600)
        } detail: {
          NavigationStack(path: path) {
            VStack(spacing: 16) {
              Image(systemName: "opticaldisc").font(.largeTitle).foregroundStyle(.secondary)
              Text("Find your next album").font(MusicType.section)
              Text("Choose an album or artist to explore your music.").font(MusicType.primary)
                .foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
              .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
              .navigationDestination(for: BrowseRoute.self) { destination($0, canvas: canvas) }
              .modifier(MusicNavigationChrome())
          }
        }
      } else {
        NavigationStack(path: path) {
          content().toolbar { controls() }.modifier(MusicNavigationChrome(glass: true))
            .navigationDestination(for: BrowseRoute.self) { destination($0, canvas: canvas) }
        }
      }
    }.safeAreaInset(edge: .bottom, spacing: 0) {
      if typeSize.isAccessibilitySize { PlaybackAccessory(store: store) }
    }
  }
  private var representedBrowser: MusicBrowser? {
    tab == .search ? searchModel : browser
  }
  private var menuIdentity: ShellMenuIdentity {
    ShellMenuIdentity(account: store.active?.id, scope: representedBrowser?.scope, tab: tab)
  }
  @ToolbarContentBuilder private func controls() -> some ToolbarContent {
    let context = menuIdentity
    let source = representedBrowser
    let background: Visibility = tab == .dashboard ? .automatic : .hidden
    ToolbarItem(placement: .topBarLeading) {
      MusicMediaPicker(
        identity: context, isCurrent: { menuIdentity == context },
        search: { if menuIdentity == context { openSearch() } }
      )
      .background {
        if tab == .search, searchRootIsVisible, headerSearchFocused {
          SearchToolbarDismissal { headerSearchFocused = false }
            .allowsHitTesting(false).accessibilityHidden(true)
        }
      }
    }.sharedBackgroundVisibility(background)
    if let source, tab == .dashboard, dashboardPath.isEmpty || sizeClass == .regular {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          if menuIdentity == context { homeEditor = source.scope }
        } label: {
          Label("Customize Home", systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
        }.accessibilityIdentifier("home-customize")
      }.sharedBackgroundVisibility(background)
    }
    MusicHeaderActions(
      store: store, browser: source, context: context,
      isCurrent: { menuIdentity == context && representedBrowser === source },
      accountSheet: $accountSheet, backgroundVisibility: background)
  }
  @ViewBuilder private func destination(_ route: BrowseRoute, canvas: CGRect) -> some View {
    let selectedTab = tab
    let sourceScope = browser.scope
    Group {
      switch route {
      case .genre(let genre, let owner):
        if browser.scope == owner, browser.metadataIsCurrent {
          GenreAlbumsView(store: store, browser: browser, scope: owner, genre: genre, open: open)
            .id(route)
        }
      case .playlist(let playlist, let owner):
        if browser.scope == owner, browser.metadataIsCurrent {
          PlaylistDetailView(
            store: store, browser: browser, scope: owner, playlist: playlist, canvas: canvas
          ) { copy in
            guard tab == selectedTab, activePath.wrappedValue.last == route,
              browser.scope == owner, browser.playlistIndex.permitsOpening(copy.id)
            else { return }
            append(.playlist(copy, scope: owner))
          }
          .id(route)
        }
      case .artistCatalog(let route, let category):
        if route.isCurrent {
          ArtistCatalogView(
            store: store, parent: route.browser, artist: route.item,
            category: category, canvas: canvas, accountSheet: $accountSheet, open: openScopedItem,
            search: { value, category, child in
              find(value, category, source: child, owner: child.scope)
            }
          ).id(route)
        }
      case .item(let item):
        itemDestination(
          item, source: browser, canvas: canvas, openItem: open,
          isCurrent: {
            tab == selectedTab && browser.scope == sourceScope && browser.metadataIsCurrent
          })
      case .scopedItem(let route):
        if route.isCurrent {
          itemDestination(
            route.item, source: route.browser, canvas: canvas,
            openItem: { item in
              guard route.isCurrent else { return }
              openScopedItem(item, source: route.browser)
            }, isCurrent: { tab == selectedTab && route.isCurrent })
        }

      }
    }.modifier(MusicNavigationChrome(glass: route.usesGlass))
  }
  @ViewBuilder private func itemDestination(
    _ item: MusicItem, source: MusicBrowser, canvas: CGRect,
    openItem: @escaping (MusicItem) -> Void,
    isCurrent: @escaping () -> Bool
  ) -> some View {
    if item.kind == "MusicArtist" {
      ArtistDetailView(
        store: store, parent: source, artist: item, canvas: canvas, open: openScopedItem,
        browse: { category, child in
          guard child.metadataIsCurrent, let library = child.authorizedLibrary else { return }
          append(
            .artistCatalog(
              CatalogResultRoute(
                item: item, browser: child, scope: child.scope,
                library: library), category))
        }, accountSheet: $accountSheet,
        isCurrent: isCurrent,
        search: { value, category, child in
          find(value, category, source: child, owner: child.scope)
        }
      ).id(item.id + source.scope.uuidString)
    } else if let detail = source.detail(item) {
      let owner = source.scope
      CatalogAlbumView(
        store: store, content: detail, canvas: canvas, open: openItem,
        find: { find($0, $1, source: source, owner: owner) }
      ).id(item.id + source.scope.uuidString)
    }
  }
  private func openScopedItem(_ item: MusicItem, source: MusicBrowser) {
    guard source.metadataIsCurrent, let library = source.authorizedLibrary else { return }
    headerSearchFocused = false
    append(
      .scopedItem(
        CatalogResultRoute(item: item, browser: source, scope: source.scope, library: library)))
  }
  private func append(_ route: BrowseRoute) {
    var path = activePath.wrappedValue
    if let index = path.firstIndex(of: route) {
      path = Array(path.prefix(index + 1))
    } else {
      if path.count >= 8 { path.removeFirst() }
      path.append(route)
    }
    activePath.wrappedValue = path
  }
  private func open(_ item: MusicItem) {
    headerSearchFocused = false
    append(.item(item))
  }
  private func ensureSearch() -> MusicBrowser? {
    if let searchModel { return searchModel }
    let model = browser.searchBrowser()
    searchModel = model
    return model
  }
  private func openSearch() {
    guard ensureSearch() != nil else { return }
    tab = .search
    headerSearchFocused = searchPath.isEmpty
  }
  private func find(_ value: String, _ category: MusicCategory) {
    find(value, category, source: browser, owner: browser.scope)
  }
  private func find(
    _ value: String, _ category: MusicCategory, source: MusicBrowser, owner: UUID
  ) {
    guard source.scope == owner, source.metadataIsCurrent,
      let model = ensureSearch(),
      model.seedSearch(value, category: category, from: source, scope: owner)
    else { return }
    searchPath = []
    openSearch()
  }
  private func related(_ item: MusicItem, origin: PlaybackOrigin) {
    guard store.playbackOrigin(library: origin.library) == origin else { return }
    let owner = browser.scope
    browser.selectLibrary(origin.library)
    store.showPlayer = false
    tab = .music
    let target: MusicItem
    if item.kind == "Audio" {
      guard let id = item.albumID else {
        find(item.album, .albums)
        return
      }
      target = MusicItem(
        id: id, title: item.album, artist: item.artist, album: item.album,
        duration: 0, number: 0, kind: "MusicAlbum", imageID: nil, imageTag: nil)
    } else if item.kind == "MusicArtist", item.id.isEmpty {
      find(item.artist, .artists)
      return
    } else {
      target = item
    }
    if browser.scope != owner { pendingRoute = target }
    open(target)
  }
}

private struct PlaybackPresenceObserver: View {
  let store: PlayerStore
  @Binding var present: Bool
  var body: some View {
    Color.clear.frame(width: 0, height: 0).accessibilityHidden(true).allowsHitTesting(false)
      .onChange(of: store.current != nil, initial: true) { _, exists in
        if present != exists { present = exists }
      }
  }
}

private struct PlaybackAccessory: View {
  let store: PlayerStore
  var systemGlass = false
  var body: some View {
    if store.current != nil { MiniPlayer(store: store, systemGlass: systemGlass) }
  }
}
