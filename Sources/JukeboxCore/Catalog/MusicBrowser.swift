import Foundation
import Observation

@MainActor @Observable final class MusicBrowser {
  private(set) var libraries: [MusicLibrary] = []
  private(set) var libraryID: String?
  private(set) var category: MusicCategory = .albums
  private(set) var windows: [MusicCategory: CatalogWindow] = [:]
  private var browsePreferences = CatalogBrowsePreferences()
  @ObservationIgnored private weak var preferenceOwner: MusicBrowser?
  private final class Child {
    weak var browser: MusicBrowser?
    init(_ browser: MusicBrowser) { self.browser = browser }
  }
  @ObservationIgnored private var preferenceChildren: [Child] = []
  @ObservationIgnored private var scopedChildren: [Child] = []
  private func retireChildren() {
    let children = scopedChildren
    scopedChildren = []
    for child in children { child.browser?.retire() }
  }
  @ObservationIgnored var preferencesChanged: (@MainActor (CatalogBrowsePreferences) -> Void)?
  private var preferenceRoot: MusicBrowser { preferenceOwner ?? self }
  var homeLayout: HomeLayout { preferenceRoot.browsePreferences.home ?? HomeLayout() }
  func setHomeLayout(_ value: HomeLayout, scope expected: UUID) {
    guard scope == expected, metadataIsCurrent, self === preferenceRoot, value != homeLayout else {
      return
    }
    var updated = browsePreferences
    updated.home = value == HomeLayout() ? nil : value
    applyPreferences(updated)
    preferencesChanged?(updated)
  }
  var options: CatalogBrowseOptions {
    isSearch ? CatalogBrowseOptions() : preferenceRoot.browsePreferences.options(for: category)
  }
  func selectOptions(_ value: CatalogBrowseOptions) {
    guard ownerIsCurrent(), !isSearch, value.isValid(for: category), value != options,
      preferenceRoot.ownerIsCurrent()
    else { return }
    let root = preferenceRoot
    var updated = root.browsePreferences
    updated.accept(value, for: category)
    root.applyPreferences(updated)
    root.preferencesChanged?(updated)
  }
  private func applyPreferences(_ value: CatalogBrowsePreferences) {
    guard browsePreferences != value else { return }
    let previous = browsePreferences
    browsePreferences = value
    invalidatePreferences(from: previous, to: value)
    preferenceChildren.removeAll { $0.browser == nil }
    for child in preferenceChildren {
      child.browser?.invalidatePreferences(from: previous, to: value)
    }
  }
  private func invalidatePreferences(
    from old: CatalogBrowsePreferences, to new: CatalogBrowsePreferences
  ) {
    guard !isSearch, ownerIsCurrent() else { return }
    for category in MusicCategory.allCases
    where old.options(for: category) != new.options(for: category) {
      windows[category] = nil
    }
    if old.options(for: category) != new.options(for: category) {
      listingTask?.cancel()
      request = UUID()
      loadListing()
    }
  }
  private var acceptedYears: (scope: UUID, library: String, value: CatalogYearFacet)?
  private(set) var yearsLoading = false
  private(set) var yearsError = false
  @ObservationIgnored private var yearsRequest = UUID()
  @ObservationIgnored private var yearsTask: Task<Void, Never>?
  var releaseYearBounds: ClosedRange<Int>? {
    guard !isSearch, category != .artists, metadataIsCurrent,
      let acceptedYears, acceptedYears.scope == scope,
      acceptedYears.library == authorizedLibrary
    else { return nil }
    return acceptedYears.value.bounds
  }
  var releaseYearDecades: [ClosedRange<Int>] {
    guard releaseYearBounds != nil, let acceptedYears else { return [] }
    return acceptedYears.value.decades
  }
  var releaseYearsLoaded: Bool {
    guard !isSearch, category != .artists, metadataIsCurrent,
      let acceptedYears
    else { return false }
    return acceptedYears.scope == scope && acceptedYears.library == authorizedLibrary
  }
  func loadYears(scope expected: UUID, force: Bool = false) {
    guard scope == expected, ownerIsCurrent(), !isSearch, category != .artists,
      let service, let library = authorizedLibrary
    else { return }
    if !force && (releaseYearsLoaded || yearsLoading) { return }
    yearsTask?.cancel()
    let token = UUID()
    yearsRequest = token
    yearsLoading = true
    yearsError = false
    yearsTask = Task { [weak self] in
      do {
        try Task.checkCancellation()
        let value = try await service.catalogYears(library: library)
        guard let self, self.scope == expected, self.yearsRequest == token,
          self.ownerIsCurrent(), self.authorizedLibrary == library, !Task.isCancelled
        else { return }
        self.acceptedYears = (expected, library, value)
        self.yearsLoading = false
      } catch {
        guard let self, self.scope == expected, self.yearsRequest == token,
          self.ownerIsCurrent(), !Task.isCancelled
        else { return }
        self.yearsLoading = false
        if self.rejectAuthorization(error) { return }
        self.yearsError = true
      }
    }
  }
  private func retireYears() {
    yearsTask?.cancel()
    yearsRequest = UUID()
    yearsLoading = false
    yearsError = false
    acceptedYears = nil
  }
  private var acceptedArtistMetadata: MusicItem?
  var metadataIsCurrent: Bool { service != nil && ownerIsCurrent() }
  func metadataIsCurrent(scope expected: UUID, library: String?) -> Bool {
    guard scope == expected, metadataIsCurrent, let library else { return false }
    return authorizedLibrary == library
  }
  var artistMetadata: MusicItem? { metadataIsCurrent ? acceptedArtistMetadata : nil }
  private(set) var artistMetadataState = ArtistMetadataState.loading
  private(set) var appearancePage: ArtistAppearancePage?
  private(set) var appearanceFailure: Int?
  private(set) var appearancesLoading = false
  @ObservationIgnored private var appearanceRequest = UUID()
  func loadAppearances(at offset: Int = 0) async {
    guard offset >= 0, category == .albums, let artistID, let service,
      let library = authorizedLibrary, metadataIsCurrent
    else { return }
    let owner = scope
    let token = UUID()
    appearanceRequest = token
    appearancesLoading = true
    appearanceFailure = nil
    defer { if appearanceRequest == token { appearancesLoading = false } }
    do {
      let page = try await service.catalogPage(
        CatalogQuery(
          library: library, category: .songs, offset: offset, artist: artistID,
          appearancesOnly: true))
      guard appearanceRequest == token, metadataIsCurrent(scope: owner, library: library),
        !Task.isCancelled
      else { return }
      appearancePage = ArtistAppearancePage(page, offset: offset)
    } catch {
      guard appearanceRequest == token, metadataIsCurrent(scope: owner, library: library),
        !Task.isCancelled
      else { return }
      if !rejectAuthorization(error) { appearanceFailure = offset }
    }
  }
  private(set) var recentLoadingCount = 0
  private(set) var recentAlbums: [MusicItem] = []
  private(set) var recentError: String?
  @ObservationIgnored private var recentRequest = UUID()
  private(set) var shelves: [CatalogShelf: HomeShelfState<MusicItem>] = [:]
  private(set) var homeGenres = HomeShelfState<HomeGenre>(loading: false)
  @ObservationIgnored private var genreTask: Task<Void, Never>?
  @ObservationIgnored private var genreRequest = UUID()
  private(set) var playlistIndex = MusicPlaylistIndex()
  private var playlistDetails = PlaylistDetailCache()
  private let playlistSnapshot: PlaylistSnapshotAccess?
  @ObservationIgnored private var playlistMutation: UUID?
  @ObservationIgnored private var playlistRestore: Task<Void, Never>?
  @ObservationIgnored private var playlistWrite: Task<Void, Never>?
  @ObservationIgnored private var playlistDetailLoads: [String: Task<PlaylistContents, Error>] = [:]
  @ObservationIgnored private var playlistLoad: Task<Void, Never>?
  @ObservationIgnored private var playlistsUpdated: ContinuousClock.Instant?
  private(set) var scope = UUID() {
    didSet {
      appearanceRequest = UUID()
      appearancesLoading = false
      appearancePage = nil
      appearanceFailure = nil
      playlistMutation = nil
      playlistRestore?.cancel()
      playlistRestore = nil
      playlistLoad?.cancel()
      playlistLoad = nil
      playlistsUpdated = nil
      playlistIndex = MusicPlaylistIndex()
      for load in playlistDetailLoads.values { load.cancel() }
      playlistDetailLoads.removeAll()
      playlistDetails = PlaylistDetailCache()
    }
  }
  private(set) var loadingLibraries = false
  private(set) var libraryError: String?
  var searchText = ""
  private(set) var isSearch = false
  private(set) var searchCategory: MusicCategory?
  private var searchOrder: [MusicCategory] = [.songs, .albums, .artists]
  private var searchOrderQuery: String?
  private var service: (any MusicCatalogServing)?
  @ObservationIgnored private var request = UUID()
  @ObservationIgnored private var listingTask: Task<Void, Never>?
  @ObservationIgnored private var dashboardTasks: [CatalogShelf: Task<Void, Never>] = [:]
  @ObservationIgnored private var dashboardRequests: [CatalogShelf: UUID] = [:]
  private func retireDashboard() {
    genreTask?.cancel()
    genreTask = nil
    genreRequest = UUID()
    homeGenres = HomeShelfState(loading: false)
    for task in dashboardTasks.values { task.cancel() }
    dashboardTasks = [:]
    dashboardRequests = [:]
  }
  @ObservationIgnored var readSearchHistory: (@MainActor (String) async -> [RecentSearchIdentity])?
  @ObservationIgnored var changeSearchHistory: (@MainActor (RecentSearchIdentity, Bool) -> Void)?
  private var searchRecentIDs: [RecentSearchIdentity] = []
  private var searchRecentItems: [RecentSearchIdentity: MusicItem] = [:]
  private var searchRecentScope: UUID?
  private(set) var searchRecentsLoading = false
  @ObservationIgnored private var searchRecentTask: Task<Void, Never>?
  @ObservationIgnored private var searchRecentRequest = UUID()
  var searchRecents: [MusicItem] {
    guard isSearch, metadataIsCurrent, let library = authorizedLibrary else { return [] }
    return searchRecentIDs.filter {
      $0.library == library
        && (searchCategory == nil || $0.category == searchCategory)
    }.compactMap { searchRecentItems[$0] }
  }
  @discardableResult func performSearchAction(
    scope owner: UUID, library: String?, query: String, item: @autoclosure () -> MusicItem,
    action: () -> Void
  ) -> Bool {
    guard !Task.isCancelled, isSearch, metadataIsCurrent(scope: owner, library: library),
      normalizedSearch == query, let library
    else { return false }
    let value = item()
    guard let category = MusicCategory.allCases.first(where: { $0.itemType == value.kind }),
      let identity = RecentSearchIdentity(library: library, category: category, id: value.id),
      query.isEmpty
        ? searchRecentItems[identity] == value
        : searchWindow(category).items.contains(value)
    else { return false }
    searchRecentTask?.cancel()
    searchRecentRequest = UUID()
    searchRecentScope = nil
    searchRecentsLoading = false
    searchRecentIDs.removeAll { $0 == identity }
    searchRecentIDs.insert(identity, at: 0)
    searchRecentIDs = Array(searchRecentIDs.prefix(RecentSearchIdentity.limit))
    searchRecentItems[identity] = value
    let retained = Set(searchRecentIDs)
    searchRecentItems = searchRecentItems.filter { retained.contains($0.key) }
    changeSearchHistory?(identity, false)
    action()
    return true
  }
  func removeSearchRecent(_ item: @autoclosure () -> MusicItem, scope owner: UUID, library: String?)
  {
    guard !Task.isCancelled, isSearch, metadataIsCurrent(scope: owner, library: library),
      let library
    else { return }
    let item = item()
    guard let category = MusicCategory.allCases.first(where: { $0.itemType == item.kind }),
      let identity = RecentSearchIdentity(library: library, category: category, id: item.id),
      searchRecentIDs.contains(identity)
    else { return }
    searchRecentTask?.cancel()
    searchRecentRequest = UUID()
    searchRecentScope = nil
    searchRecentsLoading = false
    searchRecentIDs.removeAll { $0 == identity }
    searchRecentItems[identity] = nil
    changeSearchHistory?(identity, true)
    loadSearchRecents()
  }
  @discardableResult func loadSearchRecents() -> Task<Void, Never>? {
    guard isSearch, normalizedSearch.isEmpty, metadataIsCurrent, !Task.isCancelled,
      !searchRecentsLoading, searchRecentScope != scope, let library = authorizedLibrary,
      let service,
      let readSearchHistory
    else { return nil }
    searchRecentTask?.cancel()
    let owner = scope
    let token = UUID()
    searchRecentRequest = token
    searchRecentsLoading = true
    searchRecentTask = Task { [weak self] in
      guard let self, self.metadataIsCurrent(scope: owner, library: library),
        self.searchRecentRequest == token, !Task.isCancelled
      else { return }
      let ids = await readSearchHistory(library)
      guard self.metadataIsCurrent(scope: owner, library: library),
        self.searchRecentRequest == token, !Task.isCancelled
      else { return }
      self.searchRecentIDs = Array(
        ids.filter { $0.library == library }.prefix(RecentSearchIdentity.limit))
      let retained = Set(self.searchRecentIDs)
      self.searchRecentItems = self.searchRecentItems.filter { retained.contains($0.key) }
      for category in MusicCategory.allCases {
        let missing = self.searchRecentIDs.filter {
          $0.category == category && self.searchRecentItems[$0] == nil
        }
        guard !missing.isEmpty else { continue }
        if category == .artists {
          for identity in missing {
            guard self.metadataIsCurrent(scope: owner, library: library),
              self.searchRecentRequest == token, !Task.isCancelled
            else { return }
            let seed = MusicItem(
              id: identity.id, title: "", artist: "", album: "", duration: 0, number: 0,
              kind: "MusicArtist", imageID: nil, imageTag: nil)
            do {
              let row = try await service.artistDetail(library: library, artist: seed)
              guard self.metadataIsCurrent(scope: owner, library: library),
                self.searchRecentRequest == token, !Task.isCancelled
              else { return }
              if row.id == identity.id && row.kind == "MusicArtist" {
                self.searchRecentItems[identity] = row
              }
            } catch {
              guard self.metadataIsCurrent(scope: owner, library: library),
                self.searchRecentRequest == token, !Task.isCancelled
              else { return }
              if error as? ClientError == .unauthorized {
                _ = self.rejectAuthorization(error)
                return
              }
            }
          }
        } else {
          do {
            let rows = try await service.catalog(
              CatalogQuery(library: library, category: category, ids: missing.map(\.id)))
            guard self.metadataIsCurrent(scope: owner, library: library),
              self.searchRecentRequest == token, !Task.isCancelled
            else { return }
            for row in rows where row.kind == category.itemType {
              if let identity = missing.first(where: { $0.id == row.id }) {
                self.searchRecentItems[identity] = row
              }
            }
          } catch {
            guard self.metadataIsCurrent(scope: owner, library: library),
              self.searchRecentRequest == token, !Task.isCancelled
            else { return }
            if self.rejectAuthorization(error) { return }
          }
        }
      }
      self.searchRecentScope = owner
      self.searchRecentsLoading = false
    }
    return searchRecentTask
  }
  private func retireSearchRecents() {
    searchRecentTask?.cancel()
    searchRecentRequest = UUID()
    searchRecentScope = nil
    searchRecentsLoading = false
    searchRecentIDs = []
    searchRecentItems = [:]
  }
  private var started = false
  private struct RootAdmission: Sendable {
    let parentScope: UUID
    let acceptedScope: UUID
    let removed: Set<String>
  }
  @ObservationIgnored private var rootLoad: Task<RootAdmission?, Never>?
  private var artistID: String?
  private var ownerIsCurrent: @MainActor () -> Bool = { true }
  var authorizationFailed: (@MainActor (ClientError) -> Void)?
  init(
    service: any MusicCatalogServing,
    isCurrent: @escaping @MainActor () -> Bool = { true },
    preferences: CatalogBrowsePreferences = CatalogBrowsePreferences(),
    playlistSnapshot: PlaylistSnapshotAccess? = nil
  ) {
    self.service = service
    self.playlistSnapshot = playlistSnapshot
    ownerIsCurrent = isCurrent
    browsePreferences = preferences
  }
  var window: CatalogWindow {
    guard service != nil, ownerIsCurrent() else { return CatalogWindow() }
    return windows[category] ?? CatalogWindow()
  }
  var normalizedSearch: String {
    String(searchText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
  }
  var authorizedLibrary: String? {
    guard ownerIsCurrent(), let libraryID, libraries.contains(where: { $0.id == libraryID }) else {
      return nil
    }
    return libraryID
  }
  var resultsAreCurrent: Bool {
    window.loaded && window.query == normalizedSearch && window.options == options
  }
  func start() async {
    guard ownerIsCurrent() else {
      retire()
      return
    }
    let owner = scope
    if started {
      let admission = await rootLoad?.value
      guard ownerIsCurrent(), !Task.isCancelled,
        scope == owner || (admission?.parentScope == owner && admission?.acceptedScope == scope)
      else { return }
      if started { return }
    }
    await loadBrowseLibraries(refresh: false, owner: owner)
  }
  func admitPlaybackLibrary(_ library: String) async -> Bool {
    guard !library.isEmpty, await loadRoots(refresh: false) != nil,
      !Task.isCancelled, ownerIsCurrent()
    else { return false }
    return libraries.contains { $0.id == library }
  }
  private func loadRoots(refresh: Bool) async -> RootAdmission? {
    guard let service, ownerIsCurrent(), !Task.isCancelled else { return nil }
    if let rootLoad, loadingLibraries || (!refresh && libraryError == nil) {
      return await rootLoad.value
    }
    retireYears()
    loadingLibraries = true
    libraryError = nil
    let work = Task { [weak self] () -> RootAdmission? in
      do {
        let roots = try await service.musicLibraries(refresh: true)
        guard let self, self.ownerIsCurrent(), !Task.isCancelled else {
          return nil
        }
        let removed = Set(self.libraries.map(\.id)).subtracting(roots.map(\.id))
        let parentScope = self.scope
        if !removed.isEmpty {
          self.scope = UUID()
          self.request = UUID()
          self.listingTask?.cancel()
          self.retireChildren()
          self.retireYears()
          self.retireSearchRecents()
          self.retireDashboard()
          for key in self.windows.keys { self.windows[key]?.loading = false }
          if !roots.contains(where: { $0.id == self.libraryID }) {
            self.started = false
            self.libraryID = nil
            self.windows = [:]
            self.shelves = [:]
            self.recentRequest = UUID()
            self.recentAlbums = []
            self.recentLoadingCount = 0
            self.acceptedArtistMetadata = nil
            self.recentError = nil
          }
        }
        let admission = RootAdmission(
          parentScope: parentScope, acceptedScope: self.scope, removed: removed)
        self.libraries = roots
        let authorized = Set(roots.map(\.id))
        self.updatePlaylistStorage {
          try await $0.storage.retainPlaylistLibraries(authorized, access: $0)
        }
        if !removed.isEmpty, let library = self.authorizedLibrary {
          self.restoreSavedPlaylists(library)
        }
        self.loadingLibraries = false
        if !removed.isEmpty {
          self.libraryRetired?()
          self.librariesRevoked?(removed)
        }
        return admission
      } catch {
        guard let self, self.ownerIsCurrent(), !Task.isCancelled else {
          return nil
        }
        self.loadingLibraries = false
        if !self.rejectAuthorization(error) {
          self.libraryError = "Music libraries couldn’t load. Try again."
        }
        return nil
      }
    }
    rootLoad = work
    return await work.value
  }
  func loadLibraries(refresh: Bool = true) async {
    await loadBrowseLibraries(refresh: refresh, owner: scope)
  }
  private func loadBrowseLibraries(refresh: Bool, owner: UUID) async {
    guard let admission = await loadRoots(refresh: refresh),
      scope == owner || (admission.parentScope == owner && admission.acceptedScope == scope),
      ownerIsCurrent(), !Task.isCancelled
    else { return }
    started = true
    if !admission.removed.isEmpty, libraries.contains(where: { $0.id == libraryID }) {
      loadListing()
      if !isSearch { loadDashboard(force: true) }
    }
    if !libraries.contains(where: { $0.id == libraryID }), let first = libraries.first {
      selectLibrary(first.id)
    }
  }
  @ObservationIgnored var libraryRetired: (@MainActor () -> Void)?
  @ObservationIgnored var librariesRevoked: (@MainActor (Set<String>) -> Void)?
  var diagnosticScope: UUID { scope }
  func selectLibrary(_ id: String) {
    guard ownerIsCurrent(), libraries.contains(where: { $0.id == id }), libraryID != id else {
      return
    }
    let owner = scope
    libraryRetired?()
    guard ownerIsCurrent(), scope == owner,
      libraries.contains(where: { $0.id == id }), libraryID != id
    else { return }
    #if DEBUG
      TransportCapture.shared.clear(retire: true)
    #endif
    listingTask?.cancel()
    retireDashboard()
    request = UUID()
    retireChildren()
    retireYears()
    retireSearchRecents()
    scope = UUID()
    libraryID = id
    restoreSavedPlaylists(id)
    started = true
    windows = [:]
    shelves = [:]
    recentRequest = UUID()
    recentAlbums = []
    recentLoadingCount = 0
    acceptedArtistMetadata = nil
    recentError = nil
    loadListing()
    if !isSearch { loadDashboard() }
  }
  func selectCategory(_ value: MusicCategory) {
    if isSearch {
      selectSearchCategory(value)
      return
    }
    guard value != category else { return }
    listingTask?.cancel()
    request = UUID()
    category = value
    if value == .artists {
      yearsTask?.cancel()
      yearsRequest = UUID()
      yearsLoading = false
    }
    for key in windows.keys { windows[key]?.loading = false }
    loadListing()
  }
  func updateSearchText(_ value: String) {
    guard searchText != value else { return }
    searchText = value
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { loadSearchRecents() }
    searchChanged()
  }
  func searchChanged() {
    if isSearch { loadSearch(debounce: true) } else { loadListing(debounce: true) }
  }
  func selectSearchCategory(_ value: MusicCategory?) {
    guard isSearch, searchCategory != value else { return }
    searchCategory = value
    if let value { category = value }
    loadSearch()
  }
  func seedSearch(
    _ value: String, category: MusicCategory, from source: MusicBrowser, scope owner: UUID
  ) -> Bool {
    guard !Task.isCancelled, isSearch, service != nil, ownerIsCurrent(),
      source.scope == owner, source.metadataIsCurrent,
      let library = source.authorizedLibrary, libraries.contains(where: { $0.id == library })
    else { return false }
    selectLibrary(library)
    searchText = value
    selectSearchCategory(category)
    searchChanged()
    return true
  }
  func searchWindow(_ category: MusicCategory) -> CatalogWindow {
    guard isSearch, service != nil, ownerIsCurrent(), authorizedLibrary != nil else {
      return CatalogWindow()
    }
    let value = windows[category] ?? CatalogWindow()
    return value.query == normalizedSearch ? value : CatalogWindow()
  }
  var searchCategories: [MusicCategory] {
    guard isSearch, service != nil, ownerIsCurrent(), !normalizedSearch.isEmpty else { return [] }
    if let searchCategory { return [searchCategory] }
    return searchOrderQuery == normalizedSearch ? searchOrder : [.songs, .albums, .artists]
  }

  var visibleSearchCategories: [MusicCategory] {
    searchCategories.filter {
      let state = searchWindow($0)
      return !state.items.isEmpty || state.needsExplicitContinuation
        || (!state.loaded && (state.loading || state.error != nil))
    }
  }
  func needsSearchSkeleton(_ category: MusicCategory) -> Bool {
    let state = searchWindow(category)
    return !state.loaded && state.loading
  }
  private struct SearchPage: Sendable {
    let category: MusicCategory
    let result: Result<CatalogPage, ClientError>
  }
  func loadSearch(debounce: Bool = false, force: Bool = false) {
    guard isSearch else { return }
    guard ownerIsCurrent() else {
      retire()
      return
    }
    guard let service, let libraryID = authorizedLibrary else { return }
    listingTask?.cancel()
    let token = UUID()
    request = token
    let owner = scope
    let query = normalizedSearch
    if searchOrderQuery != query { searchOrderQuery = nil }
    for key in windows.keys {
      if windows[key]?.query != query { windows[key] = nil } else { windows[key]?.loading = false }
    }
    guard !query.isEmpty else {
      windows = [:]
      return
    }
    let categories = searchCategory.map { [$0] } ?? [.songs, .albums, .artists]
    let needed = categories.filter {
      force || windows[$0]?.loaded != true || windows[$0]?.error != nil
    }
    guard !needed.isEmpty else { return }
    for selected in needed {
      let state = windows[selected] ?? CatalogWindow()
      state.query = query
      state.loading = true
      state.error = nil
      state.requestedOffset = 0
      windows[selected] = state
    }
    listingTask = Task { [weak self] in
      do {
        if debounce { try await Task.sleep(for: .milliseconds(300)) }
        try Task.checkCancellation()
        await withTaskGroup(of: SearchPage.self) { group in
          for selected in needed {
            group.addTask {
              do {
                try Task.checkCancellation()
                let items = try await service.catalogPage(
                  CatalogQuery(library: libraryID, category: selected, search: query))
                return SearchPage(category: selected, result: .success(items))
              } catch {
                return SearchPage(
                  category: selected, result: .failure(error as? ClientError ?? .unavailable))
              }
            }
          }
          var completed: [SearchPage] = []
          for await result in group {
            guard let self, self.scope == owner, self.request == token, self.ownerIsCurrent(),
              self.normalizedSearch == query, !Task.isCancelled
            else {
              group.cancelAll()
              return
            }
            if case .failure(let error) = result.result, self.rejectAuthorization(error) {
              group.cancelAll()
              return
            }
            completed.append(result)
          }
          guard let self, self.scope == owner, self.request == token, self.ownerIsCurrent(),
            self.normalizedSearch == query, !Task.isCancelled
          else { return }
          var accepted = self.windows
          for result in completed {
            switch result.result {
            case .success(let items):
              let page = accepted[result.category] ?? CatalogWindow()
              page.accept(
                items.items, at: 0, query: query, rawCount: items.rawCount, replacing: force)
              accepted[result.category] = page
            case .failure:
              accepted[result.category]?.loading = false
              accepted[result.category]?.error = "Couldn’t load results. Try again."
            }
          }
          if self.searchOrderQuery != query {
            let order: [MusicCategory] = [.songs, .albums, .artists]
            let exact = order.filter { category in
              accepted[category]?.items.contains {
                $0.title.compare(query, options: [.caseInsensitive, .diacriticInsensitive])
                  == .orderedSame
              } == true
            }
            self.searchOrder = exact + order.filter { !exact.contains($0) }
            self.searchOrderQuery = query
          }
          self.windows = accepted

        }
      } catch {
      }
    }
  }
  func setAnchor(_ id: String?, fraction: Double = 0, revision: UUID? = nil) {
    guard ownerIsCurrent(), revision == nil || revision == window.revision,
      window.anchor != id || window.anchorFraction != fraction, fraction.isFinite
    else { return }
    let state = window
    state.anchor = id
    state.anchorFraction = max(0, min(1, fraction))
    windows[category] = state
  }
  @discardableResult func boundaryVisibilityChanged(
    id: String, visible: Bool, scope: UUID, category: MusicCategory, query: String, revision: UUID,
    direction: CatalogPagingDirection
  ) -> Bool {
    guard ownerIsCurrent(), visible, self.scope == scope, self.category == category,
      window.query == query, window.revision == revision, resultsAreCurrent,
      direction != .stationary, window.loaded, !window.loading, window.error == nil,
      let index = window.index(of: id)
    else { return false }
    if direction == .earlier, index < 8, window.hasEarlier {
      loadEarlier()
      return true
    } else if direction == .later, index >= window.items.count - 8, window.hasNext {
      loadMore()
      return true
    }
    return false
  }
  func continueListing(
    _ direction: CatalogPagingDirection, scope: UUID, category: MusicCategory, query: String,
    revision: UUID
  ) {
    guard ownerIsCurrent(), !Task.isCancelled, self.scope == scope, normalizedSearch == query,
      let state = windows[category], state.query == query, state.revision == revision,
      state.loaded, !state.loading, state.error == nil, direction != .stationary
    else { return }
    if isSearch {
      guard searchCategory == nil || searchCategory == category else { return }
      if searchCategory == nil { selectSearchCategory(category) }
    } else {
      guard self.category == category, state.options == options else { return }
    }
    if direction == .earlier { loadEarlier() } else { loadMore() }
  }
  func loadMore() {
    guard window.loaded, window.hasNext, !window.loading, window.error == nil else { return }
    loadListing(offset: window.nextOffset)
  }
  func loadEarlier() {
    guard window.hasEarlier, !window.loading, window.error == nil else { return }
    loadListing(offset: max(0, window.firstOffset - 40))
  }
  func retryListing() { loadListing(offset: window.requestedOffset, force: true) }
  func loadListing(offset: Int? = nil, debounce: Bool = false, force: Bool = false) {
    if isSearch, offset == nil {
      loadSearch(debounce: debounce, force: force)
      return
    }
    guard let service, let libraryID, ownerIsCurrent() else { return }
    let selected = category
    let options = self.options
    let query = normalizedSearch
    let state = windows[selected] ?? CatalogWindow()
    if !force, !debounce, offset == nil, state.query == query, state.options == options,
      state.loaded
    {
      return
    }
    listingTask?.cancel()
    let token = UUID()
    request = token
    let owner = scope
    let target = offset ?? 0
    if !force, state.query == query, state.options == options, let cached = state.pages[target] {
      state.accept(
        cached, at: target, query: query, options: options, rawCount: state.rawCounts[target])
      windows[selected] = state
      return
    }
    state.options = options
    state.loading = true
    state.error = nil
    state.requestedOffset = target
    windows[selected] = state
    listingTask = Task { [weak self] in
      do {
        if debounce { try await Task.sleep(for: .milliseconds(300)) }
        try Task.checkCancellation()
        let result = try await service.catalogPage(
          CatalogQuery(
            library: libraryID, category: selected, offset: target, search: query,
            artist: self?.artistID, options: options))
        guard let self, self.scope == owner, self.request == token, self.ownerIsCurrent(),
          self.options == options,
          !Task.isCancelled
        else {
          return
        }
        let page = self.windows[selected] ?? CatalogWindow()
        page.accept(
          result.items, at: target, query: query, options: options, rawCount: result.rawCount,
          replacing: force && target == 0)
        self.windows[selected] = page
      } catch {
        guard let self, self.scope == owner, self.request == token, self.ownerIsCurrent(),
          self.options == options,
          !Task.isCancelled
        else {
          return
        }
        if self.rejectAuthorization(error) { return }
        let page = self.windows[selected] ?? CatalogWindow()
        page.loading = false
        page.error = "This music couldn’t load. Try again."
        self.windows[selected] = page
      }
    }
  }
  @discardableResult func rejectAuthorization(_ error: Error) -> Bool {
    guard let reason = error as? ClientError, [.unauthorized, .forbidden].contains(reason) else {
      return false
    }
    updatePlaylistStorage { try await $0.storage.retainPlaylistLibraries([], access: $0) }
    rootLoad?.cancel()
    rootLoad = nil
    loadingLibraries = false
    retireChildren()
    retireYears()
    retireSearchRecents()
    scope = UUID()
    request = UUID()
    listingTask?.cancel()
    retireDashboard()
    windows = [:]
    shelves = [:]
    recentRequest = UUID()
    recentAlbums = []
    recentLoadingCount = 0
    acceptedArtistMetadata = nil
    recentError = nil
    let removed = Set(libraries.map(\.id))
    libraries = []
    libraryID = nil
    libraryError = "Your account can no longer access this music. Refresh libraries to continue."
    libraryRetired?()
    librariesRevoked?(removed)
    authorizationFailed?(reason)
    return true
  }
  func loadRecentAlbums(_ ids: [String], scope expectedScope: UUID) async {
    guard scope == expectedScope, let service, let libraryID, ownerIsCurrent() else { return }
    let token = UUID()
    recentRequest = token
    recentLoadingCount = min(6, Set(ids.prefix(24)).count)
    guard !ids.isEmpty else {
      recentAlbums = []
      recentLoadingCount = 0
      acceptedArtistMetadata = nil
      recentError = nil
      return
    }
    do {
      let rows = try await service.catalog(
        CatalogQuery(library: libraryID, ids: Array(ids.prefix(24))))
      guard scope == expectedScope, recentRequest == token, ownerIsCurrent(), !Task.isCancelled
      else { return }
      let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      recentAlbums = Array(ids.compactMap { byID[$0] }.prefix(6))
      recentLoadingCount = 0
      recentError = nil
    } catch {
      guard scope == expectedScope, recentRequest == token, ownerIsCurrent(), !Task.isCancelled
      else { return }
      if rejectAuthorization(error) { return }
      recentLoadingCount = 0
      recentError = "Recently played couldn’t refresh. Try again."
    }
  }
  func loadDashboard(force: Bool = false) {
    for shelf in CatalogShelf.allCases
    where !homeLayout.hidden.contains(shelf.section) && (shelf != .artists || shelves[shelf] != nil)
    {
      loadShelf(shelf, force: force)
    }
    if force, !homeLayout.hidden.contains(.genres),
      homeGenres.loaded || homeGenres.loading || homeGenres.error != nil
    {
      loadGenres(force: true)
    }
  }
  func loadShelf(_ shelf: CatalogShelf, force: Bool = false) {
    guard let service, let library = authorizedLibrary, ownerIsCurrent() else { return }
    guard force || (shelves[shelf]?.loaded != true && shelves[shelf]?.loading != true) else {
      return
    }
    dashboardTasks[shelf]?.cancel()
    let owner = scope
    let ticket = UUID()
    dashboardRequests[shelf] = ticket
    var value = shelves[shelf] ?? HomeShelfState<MusicItem>()
    value.loading = true
    value.error = nil
    shelves[shelf] = value
    dashboardTasks[shelf] = Task { [weak self] in
      let items: [MusicItem]?
      let failure: ClientError?
      do {
        items = try await service.catalog(
          CatalogQuery(library: library, category: shelf.category, shelf: shelf))
        failure = nil
      } catch {
        items = nil
        failure = error as? ClientError ?? .unavailable
      }
      guard let self, self.scope == owner, self.ownerIsCurrent(),
        self.authorizedLibrary == library, self.dashboardRequests[shelf] == ticket,
        !Task.isCancelled
      else { return }
      self.dashboardTasks[shelf] = nil
      if let failure, self.rejectAuthorization(failure) { return }
      var state = self.shelves[shelf] ?? HomeShelfState<MusicItem>()
      state.loading = false
      if let items {
        state.items = items
        state.loaded = true
      }
      state.error = failure != nil ? "Couldn’t refresh this shelf." : nil
      self.shelves[shelf] = state
    }
  }
  func loadGenres(force: Bool = false) {
    guard let library = authorizedLibrary, let service, metadataIsCurrent,
      force || (!homeGenres.loading && !homeGenres.loaded)
    else { return }
    genreTask?.cancel()
    let token = UUID()
    let owner = scope
    genreRequest = token
    homeGenres.loading = true
    homeGenres.error = nil
    genreTask = Task { [weak self] in
      do {
        let genres = try await service.homeGenres(library: library)
        guard let self, genreRequest == token, metadataIsCurrent(scope: owner, library: library),
          !Task.isCancelled
        else { return }
        homeGenres = HomeShelfState(items: genres, loading: false, loaded: true)
      } catch {
        guard let self, genreRequest == token, metadataIsCurrent(scope: owner, library: library),
          !Task.isCancelled, !rejectAuthorization(error)
        else { return }
        homeGenres.loading = false
        homeGenres.error = "Genres couldn’t refresh."
      }
    }
  }
  func genreAlbums(_ genre: HomeGenre, offset: Int, scope owner: UUID) async throws -> CatalogPage {
    guard let service, let library = authorizedLibrary,
      metadataIsCurrent(scope: owner, library: library),
      offset >= 0
    else { throw CancellationError() }
    do {
      let page = try await service.catalogPage(
        CatalogQuery(library: library, offset: offset, genreID: genre.id))
      guard metadataIsCurrent(scope: owner, library: library), !Task.isCancelled else {
        throw CancellationError()
      }
      return page
    } catch {
      guard metadataIsCurrent(scope: owner, library: library), !Task.isCancelled else {
        throw CancellationError()
      }
      _ = rejectAuthorization(error)
      throw error
    }
  }
  private func updatePlaylistStorage(
    _ change: @escaping @Sendable (PlaylistSnapshotAccess) async throws -> Void
  ) {
    guard let playlistSnapshot else { return }
    let previous = playlistWrite
    playlistWrite = Task {
      await previous?.value
      try? await change(playlistSnapshot)
    }
  }
  private func savePlaylistSnapshot(library: String) {
    guard playlistSnapshot != nil, playlistsUpdated != nil, let items = playlistIndex.items else {
      return
    }
    let details = playlistDetails.verifiedContents
    updatePlaylistStorage {
      try await $0.storage.savePlaylists(items, details: details, access: $0, library: library)
    }
  }
  private func restoreSavedPlaylists(_ library: String) {
    guard let playlistSnapshot else { return }
    let owner = scope
    let pendingWrite = playlistWrite
    playlistIndex.restoring = true
    playlistRestore = Task { [weak self] in
      await pendingWrite?.value
      guard !Task.isCancelled else { return }
      let saved = try? await playlistSnapshot.storage.savedPlaylists(
        playlistSnapshot, library: library, scope: owner)
      guard let self, self.metadataIsCurrent(scope: owner, library: library), !Task.isCancelled
      else { return }
      if let saved, self.playlistIndex.items == nil {
        self.playlistIndex.items = saved.playlists
        self.playlistDetails = saved.details
      }
      self.playlistIndex.restoring = false
      self.playlistRestore = nil
    }
  }
  func loadPlaylistIndex(scope owner: UUID, refresh: Bool = false) async {
    await playlistRestore?.value
    guard let library = authorizedLibrary, metadataIsCurrent(scope: owner, library: library),
      !Task.isCancelled
    else { return }
    if let playlistLoad {
      await playlistLoad.value
      return
    }
    if !refresh, let playlistsUpdated, playlistsUpdated.duration(to: .now) < .seconds(60) { return }
    let keepPrevious = playlistIndex.items != nil
    let started = ContinuousClock.now
    playlistIndex.loading = true
    playlistIndex.error = nil
    let work = Task { [weak self] in
      guard let self, self.metadataIsCurrent(scope: owner, library: library), !Task.isCancelled
      else { return }
      defer {
        if self.scope == owner && !Task.isCancelled {
          self.playlistIndex.loading = false
          self.playlistLoad = nil
        }
      }
      do {
        let items = try await self.playlists(
          scope: owner,
          onSongs: { [weak self] id, tracks in
            guard let self, self.metadataIsCurrent(scope: owner, library: library),
              !Task.isCancelled, self.playlistDetailLoads[id] == nil,
              !self.playlistDetails.verified(id, since: started)
            else { return }
            self.playlistDetails.insert(
              PlaylistContents(tracks, source: .init(id: id, library: library, scope: owner)))
          }
        ) { [weak self] partial in
          guard let self, !keepPrevious, self.metadataIsCurrent(scope: owner, library: library),
            !Task.isCancelled
          else { return }
          if self.playlistIndex.items != partial { self.playlistIndex.items = partial }
        }
        guard self.metadataIsCurrent(scope: owner, library: library), !Task.isCancelled else {
          return
        }
        self.playlistIndex.items = items
        let ids = Set(items.map(\.id))
        self.playlistDetails.finishIndex(ids, started: started)
        self.playlistIndex.revision += 1
        for id in self.playlistDetailLoads.keys where !ids.contains(id) {
          self.playlistDetailLoads.removeValue(forKey: id)?.cancel()
        }
        self.playlistsUpdated = .now
        self.savePlaylistSnapshot(library: library)
      } catch {
        guard self.metadataIsCurrent(scope: owner, library: library), !Task.isCancelled,
          !(error is CancellationError)
        else { return }
        if error as? ClientError == .forbidden {
          self.playlistIndex.items = []
          self.updatePlaylistStorage { try await $0.storage.clearPlaylists($0, library: library) }
          self.playlistDetails = PlaylistDetailCache()
          for load in self.playlistDetailLoads.values { load.cancel() }
          self.playlistDetailLoads.removeAll()
        }
        self.playlistsUpdated = nil
        self.playlistIndex.error =
          (error as? ClientError)?.localizedDescription ?? "Couldn’t refresh playlists."
      }
    }
    playlistLoad = work
    await work.value
    await playlistWrite?.value
  }
  func playlists(scope: UUID, onSongs: PlaylistSongsUpdate? = nil, onUpdate: PlaylistUpdate? = nil)
    async throws -> [MusicPlaylist]
  {
    try await readPlaylist(scope: scope) { service, library, current in
      let publish: PlaylistUpdate?
      if let onUpdate {
        publish = { @MainActor lists in
          guard current(), !Task.isCancelled else { return }
          onUpdate(lists)
        }
      } else {
        publish = nil
      }
      return try await service.playlists(
        library: library, isCurrent: current, onUpdate: publish, onSongs: onSongs)
    }
  }
  func cachedPlaylistContents(_ playlist: MusicPlaylist, scope: UUID) -> PlaylistContents? {
    guard metadataIsCurrent(scope: scope, library: authorizedLibrary) else { return nil }
    return playlistDetails.contents(for: playlist.id)
  }
  func acceptsPlaylist(_ source: PlaylistContents.Source) -> Bool {
    guard metadataIsCurrent(scope: source.scope, library: source.library),
      playlistIndex.permitsOpening(source.id)
    else { return false }
    let cached = playlistDetails.contents(for: source.id)
    return cached == nil || cached?.source.revision == source.revision
  }
  func playlistContents(_ playlist: MusicPlaylist, scope: UUID, refresh: Bool = false) async throws
    -> PlaylistContents
  {
    guard metadataIsCurrent(scope: scope, library: authorizedLibrary), !Task.isCancelled
    else { throw CancellationError() }
    if !refresh, let cached = playlistDetails.contents(for: playlist.id) {
      if playlistLoad != nil || playlistDetails.contents(for: playlist.id, freshAt: .now) != nil {
        return cached
      }
      if playlistsUpdated == nil, playlistIndex.items != nil {
        if playlistIndex.error == nil {
          Task { await loadPlaylistIndex(scope: scope) }
        }
        return cached
      }
    }
    let work: Task<PlaylistContents, Error>
    if let pending = playlistDetailLoads[playlist.id] {
      work = pending
    } else {
      work = Task {
        defer {
          if self.scope == scope && !Task.isCancelled { playlistDetailLoads[playlist.id] = nil }
        }
        let contents = try await readPlaylistContents(playlist, scope: scope)
        guard metadataIsCurrent(scope: scope, library: contents.source.library), !Task.isCancelled
        else {
          throw CancellationError()
        }
        playlistDetails.insert(contents)
        savePlaylistSnapshot(library: contents.source.library)
        return contents
      }
      playlistDetailLoads[playlist.id] = work
    }
    let contents = try await work.value
    try Task.checkCancellation()
    guard metadataIsCurrent(scope: scope, library: contents.source.library) else {
      throw CancellationError()
    }
    return contents
  }
  private func readPlaylistContents(_ playlist: MusicPlaylist, scope: UUID) async throws
    -> PlaylistContents
  {
    do {
      let (tracks, library) = try await readPlaylist(scope: scope) { service, library, current in
        let tracks = try await service.playlistTracks(
          library: library, playlistID: playlist.id, isCurrent: current)
        return (tracks, library)
      }
      return PlaylistContents(
        tracks, source: .init(id: playlist.id, library: library, scope: scope))
    } catch ClientError.forbidden {
      if self.scope == scope {
        playlistDetails.remove(playlist.id)
        if let library = authorizedLibrary {
          updatePlaylistStorage { try await $0.storage.clearPlaylists($0, library: library) }
        }
        playlistLoad?.cancel()
        playlistLoad = nil
        playlistIndex.loading = false
        playlistIndex.items?.removeAll { $0.id == playlist.id }
        playlistsUpdated = nil
      }
      throw ClientError.forbidden
    }

  }
  private func readPlaylist<Value: Sendable>(
    scope owner: UUID,
    _ read: (any MusicCatalogServing, String, @escaping @MainActor @Sendable () -> Bool)
      async throws -> Value
  ) async throws -> Value {
    guard let service, let library = authorizedLibrary else { throw CancellationError() }
    let current: @MainActor @Sendable () -> Bool = { [weak self] in
      self?.metadataIsCurrent(scope: owner, library: library) == true
    }
    guard current(), !Task.isCancelled else { throw CancellationError() }
    do {
      let value = try await read(service, library, current)
      guard current(), !Task.isCancelled else { throw CancellationError() }
      return value
    } catch {
      guard current(), !Task.isCancelled else { throw CancellationError() }
      if error as? ClientError == .unauthorized { rejectAuthorization(error) }
      throw error
    }
  }
  func playlistActionBrowser(library: String) -> MusicBrowser? {
    guard metadataIsCurrent, libraries.contains(where: { $0.id == library }) else { return nil }
    if library == authorizedLibrary { return self }
    guard let child = searchBrowser() else { return nil }
    child.selectLibrary(library)
    return child
  }
  func playlistEditor(_ playlist: MusicPlaylist, scope: UUID) async throws -> PlaylistEditState {
    try await readPlaylist(scope: scope) { service, library, current in
      guard let editor = service as? any MusicPlaylistEditing else {
        throw PlaylistEditError.readOnly
      }
      return try await editor.playlistEditor(
        library: library, playlist: playlist, isCurrent: current)
    }
  }
  func playlistSharing(_ playlist: MusicPlaylist, scope: UUID) async throws -> PlaylistSharing {
    try await readPlaylist(scope: scope) { service, library, current in
      guard let editor = service as? any MusicPlaylistEditing else {
        throw PlaylistEditError.readOnly
      }
      return try await editor.playlistSharing(
        library: library, playlist: playlist, isCurrent: current)
    }
  }
  func playlistSongSearch(_ query: String, offset: Int, scope: UUID) async throws -> CatalogPage {
    try await readPlaylist(scope: scope) { service, library, _ in
      try await service.catalogPage(
        CatalogQuery(library: library, category: .songs, offset: offset, search: query))
    }
  }
  func changePlaylist(_ change: PlaylistMutation, state: PlaylistEditState?, scope owner: UUID)
    async throws -> PlaylistSave
  {
    let root = preferenceRoot
    guard let library = authorizedLibrary, metadataIsCurrent(scope: owner, library: library),
      root.playlistMutation == nil
    else { throw PlaylistEditError.changed }
    let token = UUID()
    root.playlistMutation = token
    defer { if root.playlistMutation == token { root.playlistMutation = nil } }
    do {
      let saved = try await readPlaylist(scope: owner) { service, library, current in
        guard let editor = service as? any MusicPlaylistEditing else {
          throw PlaylistEditError.readOnly
        }
        return try await editor.changePlaylist(
          library: library, state: state, change: change, isCurrent: current)
      }
      if !change.changesSharingOnly {
        root.playlistChanged(id: saved.id, tracks: change.changesTracks, refreshing: self)
        await loadPlaylistIndex(scope: owner, refresh: true)
      }
      return saved
    } catch {
      if metadataIsCurrent(scope: owner, library: library), !(error is CancellationError),
        !change.changesSharingOnly,
        (error as? PlaylistEditError).map({
          $0 == .changed || $0 == .uncertain || $0 == .copyUnconfirmed
        }) != false
      {
        root.playlistChanged(id: state?.playlist.id, tracks: true, refreshing: self)
        Task { await self.loadPlaylistIndex(scope: owner, refresh: true) }
      }
      throw error
    }
  }
  private func playlistChanged(id: String?, tracks: Bool, refreshing caller: MusicBrowser) {
    guard metadataIsCurrent, let library = authorizedLibrary else { return }
    playlistRestore?.cancel()
    playlistRestore = nil
    playlistIndex.restoring = false
    playlistLoad?.cancel()
    playlistLoad = nil
    playlistIndex.loading = false
    if tracks, let id {
      playlistDetailLoads.removeValue(forKey: id)?.cancel()
      playlistDetails.remove(id)
    }
    playlistsUpdated = nil
    playlistIndex.revision += 1
    updatePlaylistStorage { try await $0.storage.clearPlaylists($0, library: library) }
    if self !== caller, playlistIndex.items != nil {
      let owner = scope
      Task { await loadPlaylistIndex(scope: owner, refresh: true) }
    }
    for child in scopedChildren {
      child.browser?.playlistChanged(id: id, tracks: tracks, refreshing: caller)
    }
  }
  func detail(_ album: MusicItem) -> AlbumContent? {
    guard ownerIsCurrent(), let service, let libraryID = authorizedLibrary else { return nil }
    let owner = scope
    return AlbumContent(
      album: album, library: libraryID, service: service,
      isCurrent: { [weak self] in
        self?.scope == owner && self?.service != nil && self?.ownerIsCurrent() == true
      },
      rejected: { [weak self] reason in _ = self?.rejectAuthorization(reason) },
      favoriteChanged: { [weak self] in
        guard let self, self.scope == owner, self.ownerIsCurrent() else { return }
        self.preferenceRoot.favoriteChanged(library: libraryID)
      })
  }
  func favoriteChanged(library: String) {
    guard ownerIsCurrent(), service != nil else { return }
    if authorizedLibrary == library {
      let reload = windows[category]?.options.favoritesOnly == true
      for key in windows.keys where windows[key]?.options.favoritesOnly == true {
        windows[key] = nil
      }
      if reload {
        listingTask?.cancel()
        request = UUID()
        loadListing()
      }
      if !isSearch, artistID == nil, !homeLayout.hidden.contains(.favorites) {
        loadShelf(.favorites, force: true)
      }
    }
    for child in scopedChildren { child.browser?.favoriteChanged(library: library) }
  }
  func artistItems(_ artist: MusicItem, category: MusicCategory = .albums, offset: Int) async throws
    -> [MusicItem]
  {
    guard ownerIsCurrent(), let service, let libraryID = authorizedLibrary else {
      throw CancellationError()
    }
    let owner = scope
    let items = try await service.catalog(
      CatalogQuery(library: libraryID, category: category, offset: offset, artist: artist.id))
    guard scope == owner, !Task.isCancelled else { throw CancellationError() }
    return items
  }
  func loadArtistMetadata(_ artist: MusicItem) async {
    guard ownerIsCurrent(), let service, let libraryID = authorizedLibrary,
      artist.kind == "MusicArtist", artistID == artist.id
    else { return }
    let owner = scope
    artistMetadataState = .loading
    do {
      let fresh = try await service.artistDetail(library: libraryID, artist: artist)
      guard scope == owner, ownerIsCurrent(), !Task.isCancelled else { return }
      acceptedArtistMetadata = fresh
      artistMetadataState =
        fresh.details?.hasContent(for: "MusicArtist") == true ? .available : .empty
    } catch {
      guard scope == owner, ownerIsCurrent(), !Task.isCancelled else { return }
      if error as? ClientError == .unauthorized { _ = rejectAuthorization(error) }
      if error as? ClientError == .forbidden { acceptedArtistMetadata = nil }
      artistMetadataState =
        artistMetadata?.details?.hasContent(for: "MusicArtist") == true ? .available : .unavailable
    }
  }
  func artistBrowser(_ artist: MusicItem, category: MusicCategory = .albums) -> MusicBrowser? {
    guard artist.kind == "MusicArtist", category != .artists, ownerIsCurrent(),
      authorizedLibrary != nil
    else { return nil }
    return scopedBrowser(artist: artist.id, category: category)
  }
  func songsForArtist(_ artist: MusicItem) -> ArtistSongs? {
    guard artist.kind == "MusicArtist", artistID == artist.id, let service,
      let library = authorizedLibrary
    else { return nil }
    let owner = scope
    return ArtistSongs(
      service: service, library: library, artist: artist.id,
      isCurrent: { [weak self] in self?.metadataIsCurrent(scope: owner, library: library) == true },
      rejected: { [weak self] error in _ = self?.rejectAuthorization(error) })
  }
  func searchBrowser() -> MusicBrowser? { scopedBrowser(artist: nil, search: true) }
  private func scopedBrowser(
    artist: String?, search: Bool = false, category: MusicCategory = .albums
  ) -> MusicBrowser? {
    guard ownerIsCurrent(), let service, let libraryID = authorizedLibrary else { return nil }
    let owner = scope
    let child = MusicBrowser(service: service)
    child.libraries = libraries
    child.libraryID = libraryID
    child.readSearchHistory = readSearchHistory
    child.changeSearchHistory = changeSearchHistory
    child.started = true
    child.isSearch = search
    child.artistID = artist
    child.category = category
    let root = preferenceRoot
    child.preferenceOwner = root
    root.preferenceChildren.removeAll { $0.browser == nil }
    root.preferenceChildren.append(Child(child))
    scopedChildren.removeAll { $0.browser == nil }
    scopedChildren.append(Child(child))
    child.ownerIsCurrent = { [weak self] in
      self?.scope == owner && self?.service != nil && self?.ownerIsCurrent() == true
    }
    child.authorizationFailed = { [weak self] reason in _ = self?.rejectAuthorization(reason) }
    if !search { child.loadListing() }
    return child
  }
  func relatedArtist(_ artist: MusicItem) async throws -> MusicItem {
    guard let service else { throw CancellationError() }
    let owner = scope
    for root in libraries {
      let albums = try await service.catalog(CatalogQuery(library: root.id, artist: artist.id))
      let songs =
        albums.isEmpty
        ? try await service.catalog(
          CatalogQuery(library: root.id, category: .songs, artist: artist.id)) : []
      guard scope == owner, !Task.isCancelled else { throw CancellationError() }
      if !albums.isEmpty || !songs.isEmpty {
        selectLibrary(root.id)
        return artist
      }
    }
    throw ClientError.forbidden
  }
  func relatedAlbum(_ track: MusicItem) async throws -> MusicItem? {
    guard let service, let id = track.albumID else { return nil }
    let owner = scope
    for root in libraries {
      let result = try await service.catalog(CatalogQuery(library: root.id, ids: [id]))
      guard scope == owner, !Task.isCancelled else { throw CancellationError() }
      if let album = result.first(where: { $0.id == id }) {
        selectLibrary(root.id)
        return album
      }
    }
    throw ClientError.forbidden
  }
  func retire() {
    rootLoad?.cancel()
    rootLoad = nil
    loadingLibraries = false
    libraryRetired?()
    #if DEBUG
      TransportCapture.shared.clear(retire: true)
    #endif
    retireChildren()
    retireYears()
    retireSearchRecents()
    scope = UUID()
    request = UUID()
    listingTask?.cancel()
    retireDashboard()
    service = nil
    libraries = []
    libraryID = nil
    windows = [:]
    shelves = [:]
    recentRequest = UUID()
    recentAlbums = []
    recentLoadingCount = 0
    acceptedArtistMetadata = nil
    recentError = nil
    searchText = ""
  }
}
