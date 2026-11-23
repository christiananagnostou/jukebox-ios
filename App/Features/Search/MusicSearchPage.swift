import SwiftUI
import UIKit

struct SearchDestination: View {
  let store: PlayerStore
  let parent: MusicBrowser
  @Binding var model: MusicBrowser?
  let open: (MusicItem, MusicBrowser) -> Void
  let focused: FocusState<Bool>.Binding
  let canvas: CGRect
  let positions: SearchResultPositions
  let isCurrent: () -> Bool
  var body: some View {
    Group {
      if let model {
        MusicSearchPage(
          store: store, model: model, open: open, focused: focused, canvas: canvas,
          positions: positions, isCurrent: isCurrent)
      } else {
        SearchSkeleton()
      }
    }.task(id: parent.scope) { if model == nil { model = parent.searchBrowser() } }
  }
}

struct MusicSearchPage: View {
  @Bindable var store: PlayerStore
  @Bindable var model: MusicBrowser
  let open: (MusicItem, MusicBrowser) -> Void
  let focused: FocusState<Bool>.Binding
  let canvas: CGRect
  let positions: SearchResultPositions
  let isCurrent: () -> Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var body: some View {
    let owner = model.scope
    let query = model.normalizedSearch
    let categories = model.searchCategories
    let focusIsCurrent = { isCurrent() && model.scope == owner }
    let current = {
      focusIsCurrent() && model.normalizedSearch == query && model.metadataIsCurrent
    }
    let context = SearchResultPositions.Context(
      scope: owner, query: query, filter: model.searchCategory)
    BrowseScrollViewport(canvas: canvas) { insets, readableHeight in
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let error = model.libraryError {
            RetryNotice(message: error) { Task { await model.loadLibraries() } }
          } else if query.isEmpty {
            recentSelections(owner: owner, current: focusIsCurrent)
          } else {
            if let category = model.searchCategory {
              if model.visibleSearchCategories.contains(category) {
                LazyVStack(alignment: .leading, spacing: 8) {
                  sectionRows(category, owner: owner, query: query, current: current)
                }.scrollTargetLayout()
              }
            } else {
              ForEach(model.visibleSearchCategories) { category in
                VStack(alignment: .leading, spacing: 8) {
                  HStack {
                    Text(category.rawValue).font(MusicType.section).accessibilityAddTraits(
                      .isHeader)
                    Spacer()
                    Button {
                      focused.wrappedValue = false
                      model.selectSearchCategory(category)
                    } label: {
                      Text("See all").font(MusicType.secondary).frame(minHeight: 44)
                    }.buttonStyle(MusicButtonStyle()).accessibilityLabel(
                      "See all " + category.rawValue.lowercased())
                  }
                  sectionRows(category, owner: owner, query: query, current: current)
                }
              }
            }
            if !categories.isEmpty
              && categories.allSatisfy({
                let state = model.searchWindow($0)
                return state.loaded && !state.loading && state.items.isEmpty && state.error == nil
                  && !state.hasNext && !state.hasEarlier
              })
            {
              MusicEmptyState(
                title: "No matches", systemImage: "magnifyingglass", message: "Try another name.")
            }
            ForEach(categories) { category in
              let state = model.searchWindow(category)
              if state.loaded, state.items.isEmpty, let error = state.error {
                RetryNotice(message: category.rawValue + ": " + error) { model.loadSearch() }
              }
            }
          }
        }.musicPagePadding(
          onMarginTap: focused.wrappedValue
            ? { if focusIsCurrent() { focused.wrappedValue = false } } : nil
        ).padding(.vertical, 8).padding(.bottom, 24)
          .frame(maxWidth: .infinity, minHeight: readableHeight, alignment: .topLeading)
          .modifier(MusicFocusDismissal(focused: focused, isCurrent: focusIsCurrent))
          .padding(.top, insets.top).padding(.bottom, insets.bottom)
      }.modifier(
        CatalogPagingScroll(
          browser: model, scope: owner, category: model.searchCategory, query: query,
          revision: model.searchCategory.map { model.searchWindow($0).revision })
      )
      .contentMargins(0, for: .scrollContent)
      .contentMargins(.top, insets.top, for: .scrollIndicators)
      .contentMargins(.bottom, insets.bottom, for: .scrollIndicators)
      .scrollDismissesKeyboard(.interactively)
      .scrollEdgeEffectStyle(.soft, for: .vertical)
      .modifier(
        SearchScrollRestoration(context: context, positions: positions, isCurrent: focusIsCurrent)
      )
      .id(context)
      .accessibilityIdentifier("music-collection")
      .accessibilityValue(
        categories.contains { model.searchWindow($0).loading } ? "Results updating" : ""
      )
    }
    .contentShape(.interaction, .rect)
    .safeAreaBar(edge: .top, spacing: 0) { header(current: focusIsCurrent) }
    .background(MusicUI.canvas)
    .navigationTitle("").navigationBarTitleDisplayMode(.inline)
    .task(id: model.scope) { _ = model.loadSearchRecents() }
    .onDisappear { if focusIsCurrent() { focused.wrappedValue = false } }
  }
  @ViewBuilder private func sectionRows(
    _ category: MusicCategory, owner: UUID, query: String, current: @escaping () -> Bool
  ) -> some View {
    let state = model.searchWindow(category)
    let items = state.items.prefix(model.searchCategory == nil ? 5 : state.items.count)
    ForEach(items) { item in result(item, current: current).id(item.id) }
    CatalogPageContinuation(
      browser: model, scope: owner, category: category, query: query, revision: state.revision)
    if let error = state.error {
      RetryNotice(message: error) {
        if model.searchCategory == nil { model.loadSearch() } else { model.retryListing() }
      }
    }
    if model.needsSearchSkeleton(category) { SearchSkeleton(category: category) }
  }
  @ViewBuilder private func result(
    _ item: MusicItem, recent: Bool = false, current: @escaping () -> Bool
  ) -> some View {
    switch item.kind {
    case "Audio":
      CatalogSongRow(
        store: store, track: item,
        open: { if current() { open($0, model) } },
        find: { value, category in
          guard current() else { return }
          model.searchText = value
          model.selectSearchCategory(category)
          model.searchChanged()
        }, selection: store.playbackSelection([item], library: model.authorizedLibrary),
        subtitle: recent ? "Song · " + item.artist : nil, actionsAreCurrent: current,
        performAction: { action in select(item, action: action) })
    case "MusicAlbum":
      CatalogAlbumRow(
        store: store, album: item, browser: model, isCurrent: current,
        open: {
          if current() {
            select(item) { open(item, model) }
          }
        }, subtitle: recent ? "Album · " + item.artist : nil,
        performAction: { action in select(item, action: action) })
    case "MusicArtist":
      CatalogArtistRow(
        store: store, artist: item,
        origin: store.playbackOrigin(library: model.authorizedLibrary),
        open: {
          if current() {
            select(item) { open(item, model) }
          }
        }, subtitle: recent ? "Artist" : nil)
    default: EmptyView()
    }
  }
  private func select(_ item: MusicItem, action: @escaping () -> Void) {
    model.performSearchAction(
      scope: model.scope, library: model.authorizedLibrary, query: model.normalizedSearch,
      item: item
    ) {
      focused.wrappedValue = false
      action()
    }
  }
  private func dismissibleBackground(current: @escaping () -> Bool) -> some View {
    Color.clear.modifier(MusicFocusDismissal(focused: focused, isCurrent: current))
  }
  @ViewBuilder private func recentSelections(owner: UUID, current: @escaping () -> Bool)
    -> some View
  {
    let items = model.searchRecents
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Recent searches").font(MusicType.section).accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("search-recents")
        ForEach(items, id: \.self) { item in
          let library = model.authorizedLibrary
          let rowIsCurrent = {
            current() && model.metadataIsCurrent(scope: owner, library: library)
              && model.normalizedSearch.isEmpty
          }
          HStack(spacing: 4) {
            result(item, recent: true, current: rowIsCurrent)
            Button {
              guard rowIsCurrent() else { return }
              model.removeSearchRecent(item, scope: owner, library: library)
            } label: {
              MusicDismissLabel(title: "Remove from recent searches")
            }.buttonStyle(MusicButtonStyle())
              .accessibilityLabel("Remove \(item.title) from recent searches")
              .accessibilityIdentifier("remove-search-recent-" + item.id)
          }.accessibilityElement(children: .contain)
        }
      }
    } else if model.searchRecentsLoading {
      SearchSkeleton(rows: 3)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        Text("Search your music").font(MusicType.section)
        Text("Songs, albums and artists").font(MusicType.secondary).foregroundStyle(.secondary)
      }.padding(.top, 20).contentShape(.rect)
    }
  }
  private func header(current: @escaping () -> Bool) -> some View {
    GlassEffectContainer(spacing: 4) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField(
            "Search music",
            text: Binding(
              get: { model.searchText }, set: { if current() { model.updateSearchText($0) } })
          )
          .font(MusicType.primary).frame(minHeight: MusicUI.target)
          .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
          .onSubmit { if current() { focused.wrappedValue = false } }.focused(focused)
          .accessibilityIdentifier(
            "global-search-field"
          )
          Button {
            guard current() else { return }
            model.updateSearchText("")
            focused.wrappedValue = true
          } label: {
            MusicDismissLabel(title: "Clear search")
          }.buttonStyle(MusicButtonStyle()).opacity(model.searchText.isEmpty ? 0 : 1)
            .disabled(model.searchText.isEmpty).accessibilityHidden(model.searchText.isEmpty)
        }.padding(.leading, 12).frame(minHeight: 44).modifier(
          MusicSearchSurface(focused: focused.wrappedValue))
        ScrollView(.horizontal) {
          HStack(spacing: 4) {
            filter(nil, current: current)
            ForEach([MusicCategory.songs, .artists, .albums]) { category in
              filter(category, current: current)
            }
          }.padding(.horizontal, 3).modifier(BrowseControlGlass())
        }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
          .modifier(MusicFocusDismissal(focused: focused, isCurrent: current))
      }
    }.musicPagePadding().padding(.vertical, 8)
      .background(reduceTransparency ? MusicUI.canvas : .clear)
      .background { dismissibleBackground(current: current) }
      .accessibilityElement(children: .contain).accessibilityIdentifier("search-browse-controls")
  }
  private func filter(_ category: MusicCategory?, current: @escaping () -> Bool) -> some View {
    let title = category?.rawValue ?? "All"
    let selected = model.searchCategory == category
    return Button {
      guard current() else { return }
      focused.wrappedValue = false
      model.selectSearchCategory(category)
    } label: {
      MusicChoiceLabel(title: title, selected: selected)
    }.buttonStyle(MusicButtonStyle(radius: 8))
      .accessibilityAddTraits(selected ? [.isSelected] : [])
      .accessibilityIdentifier("search-filter-" + title)
  }
}

struct SearchToolbarDismissal: UIViewRepresentable {
  let dismiss: () -> Void

  func makeUIView(context: Context) -> ToolbarView { ToolbarView() }
  func updateUIView(_ view: ToolbarView, context: Context) { view.dismiss = dismiss }
  static func dismantleUIView(_ view: ToolbarView, coordinator: ()) { view.detach() }

  final class ToolbarView: UIView, UIGestureRecognizerDelegate {
    var dismiss: (() -> Void)?
    private lazy var tap: UITapGestureRecognizer = {
      let gesture = UITapGestureRecognizer(target: self, action: #selector(didTap))
      gesture.cancelsTouchesInView = false
      gesture.delegate = self
      return gesture
    }()

    override func didMoveToWindow() {
      super.didMoveToWindow()
      detach()
      window?.addGestureRecognizer(tap)
    }
    func detach() { tap.view?.removeGestureRecognizer(tap) }
    @objc private func didTap() { dismiss?() }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard let bar = navigationBar, bar.window === window,
        bar.bounds.contains(touch.location(in: bar))
      else { return false }
      var target = touch.view
      while let item = target, item !== bar {
        if item is UIControl || item.accessibilityTraits.contains(.button) { return false }
        target = item.superview
      }
      return true
    }
    private var navigationBar: UINavigationBar? {
      var responder: UIResponder? = self
      while let owner = responder {
        if let bar = owner as? UINavigationBar { return bar }
        if let bar = (owner as? UIViewController)?.navigationController?.navigationBar {
          return bar
        }
        responder = owner.next
      }
      return nil
    }
    func gestureRecognizer(
      _ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
  }
}

private struct SearchScrollRestoration: ViewModifier {
  let context: SearchResultPositions.Context
  let positions: SearchResultPositions
  let isCurrent: () -> Bool
  @State private var position = ScrollPosition()

  func body(content: Content) -> some View {
    content.scrollPosition($position)
      .onAppear {
        if let distance = positions.activate(context), distance > 0 {
          position.scrollTo(point: CGPoint(x: 0, y: distance))
        }
      }
      .onScrollPhaseChange { old, new, change in
        if new == .idle, old != .tracking, isCurrent() {
          let geometry = change.geometry
          positions.save(
            max(0, geometry.contentOffset.y + geometry.contentInsets.top), for: context)
        }
      }
  }
}

@MainActor final class SearchResultPositions {
  struct Context: Hashable {
    let scope: UUID
    let query: String
    let filter: MusicCategory?
  }
  private var active: Context?
  private var offsets: [MusicCategory?: CGFloat] = [:]

  func activate(_ context: Context) -> CGFloat? {
    if active?.scope != context.scope || active?.query != context.query { offsets.removeAll() }
    active = context
    return offsets[context.filter]
  }

  func save(_ offset: CGFloat, for context: Context) {
    guard active == context, offset.isFinite else { return }
    offsets[context.filter] = offset
  }
}

private struct SearchSkeleton: View {
  var category: MusicCategory = .songs
  var rows = 4
  var body: some View {
    VStack(spacing: 8) {
      ForEach(0..<rows, id: \.self) { _ in
        HStack(spacing: 12) {
          RoundedRectangle(cornerRadius: category == .artists ? 24 : MusicUI.artworkRadius)
            .fill(MusicUI.quiet).frame(
              width: category == .songs ? 40 : 48, height: category == .songs ? 40 : 48)
          VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(MusicUI.quiet).frame(maxWidth: 190).frame(
              height: 12)
            RoundedRectangle(cornerRadius: 3).fill(MusicUI.quiet.opacity(0.65)).frame(maxWidth: 130)
              .frame(height: 10)
          }.frame(maxWidth: .infinity, alignment: .leading)
          Spacer(minLength: 20)
        }.frame(minHeight: category == .songs ? 56 : 64)
      }
    }.accessibilityHidden(true).accessibilityIdentifier("search-skeleton")
  }
}
