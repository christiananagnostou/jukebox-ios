import SwiftUI

struct MusicBrowseSheet: Identifiable {
  let owner: UUID
  let category: MusicCategory
  var id: UUID { owner }
}
struct MusicBrowseSheetView: View {
  let store: PlayerStore
  let browser: MusicBrowser
  let input: MusicBrowseSheet
  @Environment(\.dismiss) private var dismiss
  private var current: Bool {
    browser.metadataIsCurrent && browser.scope == input.owner && browser.category == input.category
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if current {
            VStack(alignment: .leading, spacing: 0) {
              sectionTitle("Sort")
              ForEach(CatalogSort.choices(for: input.category)) { sort in
                choice(
                  label: label(sort), selected: browser.options.sort == sort,
                  identifier: "browse-sort-" + sort.rawValue
                ) {
                  var options = browser.options
                  options.sort = sort
                  browser.selectOptions(options)
                }
              }
            }
            VStack(alignment: .leading, spacing: 0) {
              sectionTitle("Show")
              ForEach([false, true], id: \.self) { favorite in
                choice(
                  label: favorite ? "Favorites" : "All",
                  selected: browser.options.favoritesOnly == favorite,
                  identifier: favorite ? "browse-favorites-only" : "browse-favorites-all"
                ) {
                  var options = browser.options
                  options.favoritesOnly = favorite
                  browser.selectOptions(options)
                }
              }
            }
            if input.category != .artists && !browser.isSearch {
              VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Library release years").accessibilityIdentifier(
                  "browse-release-years")
                Group {
                  if let bounds = browser.releaseYearBounds {
                    ReleaseYearControl(
                      bounds: bounds, selection: browser.options.years,
                      decades: browser.releaseYearDecades,
                      feedbackEnabled: { store.catalogSelectionFeedback }, isCurrent: { current }
                    ) { range in
                      guard current, input.category != .artists, !browser.isSearch else { return }
                      var options = browser.options
                      options.years = range
                      browser.selectOptions(options)
                    }
                  } else {
                    VStack(alignment: .leading, spacing: 4) {
                      Button {
                        guard current else { return }
                        var options = browser.options
                        options.years = .all
                        browser.selectOptions(options)
                      } label: {
                        Text("All release years").frame(minHeight: 44).contentShape(.rect)
                      }.accessibilityIdentifier("browse-years-all")
                        .accessibilityAddTraits(browser.options.years.isAll ? [.isSelected] : [])
                      if !browser.options.years.isAll {
                        Text("\(browser.options.years.lower!)–\(browser.options.years.upper!)")
                          .font(MusicType.secondary.monospacedDigit()).foregroundStyle(.secondary)
                      }
                      if !browser.releaseYearsLoaded && !browser.yearsError {
                        RoundedRectangle(cornerRadius: 3).fill(MusicUI.quiet).frame(height: 44)
                          .accessibilityHidden(true).allowsHitTesting(false)
                      } else if browser.yearsError {
                        Button {
                          if current { browser.loadYears(scope: input.owner, force: true) }
                        } label: {
                          Text("Retry release years").frame(minHeight: 44).contentShape(.rect)
                        }.accessibilityIdentifier("browse-years-retry")
                      } else {
                        Text("No dated releases").font(MusicType.secondary).foregroundStyle(
                          .secondary)
                      }
                    }
                  }
                }.frame(minHeight: 128, alignment: .topLeading)
                Toggle(
                  "Selection feedback",
                  isOn: Binding(
                    get: { store.catalogSelectionFeedback },
                    set: { if current { store.setCatalogSelectionFeedback($0) } }
                  )
                ).font(MusicType.control).frame(minHeight: 44)
                  .accessibilityIdentifier("browse-selection-feedback")
              }
            }
            Button("Reset") { if current { browser.selectOptions(CatalogBrowseOptions()) } }
              .frame(minHeight: 44).disabled(browser.options == CatalogBrowseOptions())
              .accessibilityIdentifier("browse-options-reset")

          }
        }.musicPagePadding().padding(.vertical, 16)
      }.accessibilityIdentifier("music-browse-sheet").background(MusicUI.canvas).navigationTitle(
        "Sort & filter"
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Close", systemImage: "xmark") { dismiss() }.accessibilityIdentifier(
            "close-browse-sheet")
        }
      }
    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
      .task(id: input.owner) { if current { browser.loadYears(scope: input.owner) } }
  }
  private func sectionTitle(_ title: String) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(MusicType.section)
      Rectangle().fill(MusicUI.border).frame(height: 0.5)
    }.padding(.bottom, 6)
  }
  private func label(_ sort: CatalogSort) -> String {
    if input.category == .artists {
      return sort == .title ? "Name A–Z" : "Name Z–A"
    }
    return sort.label
  }
  private func choice(
    label: String, selected: Bool, identifier: String, symbol: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      if current { action() }
    } label: {
      HStack(spacing: 12) {
        if let symbol { Image(systemName: symbol).frame(width: 24).accessibilityHidden(true) }
        Text(label).font(MusicType.control).foregroundStyle(.primary)
        Spacer(minLength: 8)
        Image(systemName: "checkmark").opacity(selected ? 1 : 0).accessibilityHidden(true)
      }.frame(minHeight: 48).contentShape(.rect)
    }.buttonStyle(MusicButtonStyle()).accessibilityAddTraits(selected ? [.isSelected] : [])
      .accessibilityIdentifier(identifier)
  }
}
struct MusicBrowseSkeleton: View {
  let category: MusicCategory
  let layout: CatalogLayout
  var body: some View {
    Group {
      if layout == .grid {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12)], spacing: 18
        ) {
          ForEach(0..<9) { _ in
            VStack(alignment: .leading, spacing: 8) {
              shape.aspectRatio(1, contentMode: .fit)
              Rectangle().fill(MusicUI.quiet).frame(height: 12)
              Rectangle().fill(MusicUI.quiet).frame(width: 64, height: 10)
            }
          }
        }
      } else {
        VStack(spacing: 0) {
          ForEach(0..<6) { _ in
            HStack(spacing: 12) {
              shape.frame(width: 48, height: 48)
              VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(MusicUI.quiet).frame(height: 12)
                Rectangle().fill(MusicUI.quiet).frame(width: 100, height: 10)
              }
              Spacer(minLength: 44)
            }.frame(minHeight: 64)
          }
        }
      }
    }.accessibilityHidden(true).allowsHitTesting(false)
  }
  private var shape: some View {
    RoundedRectangle(cornerRadius: category == .artists ? 1000 : MusicUI.artworkRadius).fill(
      MusicUI.quiet)
  }
}

struct CatalogPagingScroll: ViewModifier {
  let browser: MusicBrowser
  let scope: UUID
  let category: MusicCategory?
  let query: String
  let revision: UUID?
  @State private var visibleIDs = Set<String>()
  @State private var gesture = CatalogPagingGesture()
  func body(content: Content) -> some View {
    content
      .onScrollPhaseChange { _, phase in
        gesture.phase(active: phase == .interacting || phase == .decelerating)
      }
      .onScrollGeometryChange(for: Int.self) {
        Int(($0.contentOffset.y / 32).rounded(.down))
      } action: { old, new in
        gesture.movement(from: old, to: new)
        admit()
      }
      .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.1) { ids in
        visibleIDs = Set(ids)
        admit()
      }
      .onChange(of: revision) { _, _ in
        gesture = CatalogPagingGesture()
        visibleIDs = []
      }
  }
  private func admit() {
    guard browser.metadataIsCurrent, browser.scope == scope, browser.normalizedSearch == query,
      let category, browser.category == category, browser.window.revision == revision,
      gesture.direction != .stationary
    else { return }
    let window = browser.window
    let visible = visibleIDs.lazy.compactMap { window.index(of: $0) }
    let target = gesture.direction == .later ? visible.max() : visible.min()
    if let target,
      browser.boundaryVisibilityChanged(
        id: window.items[target].id, visible: true, scope: scope, category: category, query: query,
        revision: window.revision, direction: gesture.direction)
    {
      gesture.admitted()
    }
  }
}
struct CatalogPageContinuation: View {
  let browser: MusicBrowser
  let scope: UUID
  let category: MusicCategory
  let query: String
  let revision: UUID
  var body: some View {
    let state = browser.isSearch ? browser.searchWindow(category) : browser.window
    if browser.metadataIsCurrent && browser.scope == scope && browser.normalizedSearch == query
      && state.revision == revision && state.needsExplicitContinuation
      && (!browser.isSearch || browser.searchCategory != nil || state.currentPageHasOmittedRows)
    {
      HStack {
        if state.hasEarlier { button("Earlier", direction: .earlier) }
        Spacer(minLength: 16)
        if state.hasNext { button("Continue", direction: .later) }
      }.buttonStyle(MusicButtonStyle())
    }
  }
  private func button(_ label: String, direction: CatalogPagingDirection) -> some View {
    Button {
      browser.continueListing(
        direction, scope: scope, category: category, query: query, revision: revision)
    } label: {
      Text(label).font(MusicType.control).frame(minHeight: 44)
    }.accessibilityLabel(label + " " + category.rawValue.lowercased())
  }
}
