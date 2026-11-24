import SwiftUI

struct MusicEmptyState: View {
  let title: String
  let systemImage: String
  let message: String
  var body: some View {
    ContentUnavailableView {
      Label {
        Text(title).font(MusicType.section)
      } icon: {
        Image(systemName: systemImage)
      }
    } description: {
      Text(message).font(MusicType.notice)
    }
  }
}

struct MusicTransportSymbol: View {
  let name: String
  var size: CGFloat = 20
  var body: some View {
    Image(systemName: name).resizable().scaledToFit().frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

struct MusicButtonStyle: ButtonStyle {
  var radius: CGFloat = MusicUI.artworkRadius
  @Environment(\.isEnabled) private var enabled
  @State private var hovering = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(enabled ? 1 : 0.5)
      .contentShape(.rect)
      .overlay {
        RoundedRectangle(cornerRadius: radius)
          .fill(Color.primary.opacity(enabled && hovering ? 0.045 : 0))
          .allowsHitTesting(false)
      }
      .onHover { hovering = $0 }
  }
}

struct MusicPagePadding: ViewModifier {
  @Environment(\.horizontalSizeClass) private var sizeClass
  var onMarginTap: (() -> Void)?
  func body(content: Content) -> some View {
    let inset: CGFloat = sizeClass == .regular ? 24 : 16
    content.padding(.horizontal, inset).overlay {
      if let onMarginTap {
        let margin = Color.clear.frame(width: inset).contentShape(.rect)
          .onTapGesture(perform: onMarginTap)
        HStack(spacing: 0) {
          margin
          Spacer(minLength: 0)
          margin
        }.accessibilityHidden(true)
      }
    }
  }
}
extension View {
  func musicPagePadding(onMarginTap: (() -> Void)? = nil) -> some View {
    modifier(MusicPagePadding(onMarginTap: onMarginTap))
  }
}

struct MusicFocusDismissal: ViewModifier {
  let focused: FocusState<Bool>.Binding
  let isCurrent: () -> Bool
  func body(content: Content) -> some View {
    content.contentShape(.rect).gesture(
      TapGesture().onEnded { if isCurrent() { focused.wrappedValue = false } })
  }
}

struct MusicNavigationChrome: ViewModifier {
  var glass = false
  @ViewBuilder func body(content: Content) -> some View {
    if glass {
      content.toolbarBackgroundVisibility(.automatic, for: .navigationBar)
    } else {
      content
        .toolbarBackground(MusicUI.canvas, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .scrollEdgeEffectHidden(true, for: .top)
    }
  }
}

struct BrowseControlGlass: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var solid
  @ViewBuilder func body(content: Content) -> some View {
    if solid {
      content.background(MusicUI.panel, in: .capsule)
    } else {
      content.glassEffect(.regular, in: .capsule)
    }
  }
}

struct BrowseScrollViewport<Content: View>: View {
  let canvas: CGRect
  @ViewBuilder let content: (EdgeInsets, CGFloat) -> Content

  var body: some View {
    GeometryReader { viewport in
      let readable = viewport.frame(in: .global)
      let insets = EdgeInsets(
        top: max(0, readable.minY - canvas.minY), leading: 0,
        bottom: max(0, canvas.maxY - readable.maxY), trailing: 0)
      content(insets, viewport.size.height)
        .frame(
          width: viewport.size.width, height: viewport.size.height + insets.top + insets.bottom
        )
        .offset(y: -insets.top)
    }
  }
}

struct MusicBrowsePage<Controls: View, Content: View>: View {
  @ViewBuilder let controls: Controls
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      controls.fixedSize(horizontal: false, vertical: true)
      content.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }.background(MusicUI.canvas)
  }
}

struct AlbumCardLabels: View {
  static let minimumHeight: CGFloat = 36
  let title: String
  let artist: String
  var context: MusicTextContext = .browsing
  @ScaledMetric(relativeTo: .subheadline) private var reservedHeight = AlbumCardLabels.minimumHeight
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      MusicOverflowText(text: title, context: context).font(MusicType.primary.weight(.medium))
        .foregroundStyle(.primary)
      MusicOverflowText(text: artist, context: context).font(MusicType.secondary)
        .foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, minHeight: reservedHeight, alignment: .topLeading)
  }
}

struct MusicIdentityLabel: View {
  let title: String
  let subtitle: String
  var current = false
  var context: MusicTextContext = .browsing
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      MusicOverflowText(text: title, context: context).font(MusicType.primary)
        .foregroundStyle(current ? MusicUI.tint : .primary)
      MusicOverflowText(text: subtitle, context: context).font(MusicType.support).foregroundStyle(
        .secondary)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct MusicPrimaryActionLabel: View {
  let title: String
  let symbol: String
  var body: some View {
    Label(title, systemImage: symbol).labelStyle(.iconOnly).font(
      .system(size: 20, weight: .semibold)
    )
    .frame(width: 52, height: 52).foregroundStyle(MusicUI.onTint)
    .background(MusicUI.tint, in: .circle).accessibilityLabel(title)
  }
}

struct MusicUtilityLabel: View {
  let title: String
  let symbol: String
  var secondary = false
  var body: some View {
    Label {
      Text(title)
    } icon: {
      MusicTransportSymbol(name: symbol, size: 18)
    }.labelStyle(.iconOnly).font(MusicType.control)
      .foregroundStyle(secondary ? Color.secondary : MusicUI.tint)
      .frame(minWidth: MusicUI.target, minHeight: MusicUI.target).contentShape(.rect)
      .accessibilityElement(children: .ignore).accessibilityLabel(title)
  }
}

struct MusicDismissLabel: View {
  let title: String
  var body: some View {
    Image(systemName: "xmark").font(MusicType.support.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(minWidth: MusicUI.target, minHeight: MusicUI.target).contentShape(.rect)
      .accessibilityLabel(title)
  }
}

struct MusicSearchSurface: ViewModifier {
  let focused: Bool
  func body(content: Content) -> some View {
    content.accessibilityElement(children: .contain).accessibilityIdentifier("music-search-surface")
      .modifier(BrowseControlGlass())
      .overlay {
        if focused {
          Capsule().strokeBorder(MusicUI.tint, lineWidth: 2).allowsHitTesting(false)
        }
      }
  }
}

struct MusicChoiceLabel: View {
  let title: String
  let selected: Bool
  var body: some View {
    Text(title).font(MusicType.control).fontWeight(selected ? .semibold : .regular)
      .foregroundStyle(selected ? .primary : .secondary)
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, 12).padding(.vertical, 6)
      .background(selected ? MusicUI.quiet : .clear, in: .capsule)
      .frame(minHeight: MusicUI.target).contentShape(.rect)
  }
}

struct MusicCategoryTabs: View {
  let selection: MusicCategory
  let categories: [MusicCategory]
  let select: (MusicCategory) -> Void
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: 4) {
          ForEach(categories) { category in
            Button {
              select(category)
            } label: {
              MusicChoiceLabel(title: category.rawValue, selected: category == selection)
            }.buttonStyle(MusicButtonStyle(radius: 8))
              .accessibilityAddTraits(category == selection ? [.isSelected] : [])
              .accessibilityIdentifier("music-category-" + category.rawValue).id(category)
          }
        }
      }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
        .onChange(of: selection, initial: true) { _, value in
          proxy.scrollTo(value, anchor: .center)
        }
    }.accessibilityElement(children: .contain).accessibilityLabel("Browse music")
      .accessibilityIdentifier("music-category-tabs")
  }
}

private struct MusicMenuPresentation: Identifiable {
  let id = UUID()
  let owner: AnyHashable
}

struct MusicPopover<Label: View, Content: View>: View {
  let title: String
  let identity: AnyHashable
  let identifier: String
  let isCurrent: () -> Bool
  let label: Label
  let content: (@escaping () -> Bool, @escaping () -> Void) -> Content
  @State private var presentation: MusicMenuPresentation?
  init(
    _ title: String, identity: AnyHashable, identifier: String,
    isCurrent: @escaping () -> Bool,
    @ViewBuilder content: @escaping (@escaping () -> Bool, @escaping () -> Void) -> Content,
    @ViewBuilder label: () -> Label
  ) {
    self.title = title
    self.identity = identity
    self.identifier = identifier
    self.isCurrent = isCurrent
    self.content = content
    self.label = label()
  }
  var body: some View {
    let receipt = CatalogPresentationReceipt(owner: identity, presentation: presentation?.id)
    Button {
      guard receipt.admits(owner: identity, presentation: presentation?.id, isCurrent: isCurrent)
      else { return }
      presentation = presentation == nil ? MusicMenuPresentation(owner: identity) : nil
    } label: {
      label
    }
    .buttonStyle(MusicButtonStyle()).accessibilityIdentifier(identifier)
    .popover(
      item: Binding(
        get: {
          receipt.admits(owner: identity, presentation: presentation?.id, isCurrent: isCurrent)
            ? presentation : nil
        },
        set: { value in
          if receipt.admits(owner: identity, presentation: presentation?.id, isCurrent: isCurrent) {
            presentation = value
          }
        }
      ), arrowEdge: .top
    ) { input in
      let inputReceipt = CatalogPresentationReceipt(owner: input.owner, presentation: input.id)
      let current = {
        inputReceipt.admits(owner: identity, presentation: presentation?.id, isCurrent: isCurrent)
      }
      let close = { if current() { presentation = nil } }
      Group {
        if current() {
          MusicMenuPanel(title: title) { content(current, close) }
        }
      }.accessibilityAction(.escape, close)
        .onKeyPress(.escape) {
          close()
          return .handled
        }
        .presentationCompactAdaptation(.popover).presentationBackground(MusicUI.panel)
        .presentationCornerRadius(14)
    }
    .onChange(of: identity) { old, _ in
      if presentation?.id == receipt.presentation && presentation?.owner == old {
        presentation = nil
      }
    }
    .onDisappear {
      if presentation?.id == receipt.presentation { presentation = nil }
    }
  }
}

struct MusicMenuPanel<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content
  var body: some View {
    ViewThatFits(in: .vertical) {
      rows.fixedSize(horizontal: false, vertical: true)
      ScrollView { rows }
    }.frame(idealWidth: 280, maxWidth: 340).background(MusicUI.panel)
      .accessibilityElement(children: .contain).accessibilityLabel(title)
      .accessibilityIdentifier("music-menu-panel")
  }
  private var rows: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title).font(MusicType.secondary).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 8)
        .accessibilityAddTraits(.isHeader)
      content
    }.padding(8).buttonStyle(MusicButtonStyle())
  }
}

struct MusicMenuRow: View {
  let title: String
  let symbol: String
  var subtitle: String? = nil
  var selected = false
  var destructive = false
  var body: some View {
    HStack(spacing: 10) {
      MusicTransportSymbol(name: symbol, size: 18)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(MusicType.primary)
        if let subtitle { Text(subtitle).font(MusicType.support).foregroundStyle(.secondary) }
      }.frame(maxWidth: .infinity, alignment: .leading)
      if selected {
        Image(systemName: "checkmark").foregroundStyle(MusicUI.tint).accessibilityHidden(true)
      }
    }.foregroundStyle(destructive ? Color.red : .primary)
      .padding(.horizontal, 10).padding(.vertical, 8)
      .frame(maxWidth: .infinity, minHeight: MusicUI.target, alignment: .leading)
      .contentShape(.rect).accessibilityElement(children: .combine)
      .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

struct MusicMediaPicker: View {
  let identity: AnyHashable
  let isCurrent: () -> Bool
  let search: () -> Void
  var body: some View {
    MusicPopover(
      "Media type", identity: identity, identifier: "media-picker", isCurrent: isCurrent
    ) { current, close in
      Button {
        if current() { close() }
      } label: {
        MusicMenuRow(title: "Music", symbol: "music.note", selected: true)
      }.accessibilityIdentifier("media-Music")
      ForEach(["Movies", "Photos", "Books", "Games"], id: \.self) { title in
        Button {
        } label: {
          MusicMenuRow(title: title, symbol: symbol(title), subtitle: "Coming later")
        }.disabled(true).accessibilityLabel(title + ", coming later")
          .accessibilityIdentifier("media-future-" + title)
      }
    } label: {
      HStack(spacing: 6) {
        Text("Music").font(MusicType.identity)
        Image(systemName: "chevron.down").font(MusicType.support)
      }.fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(.primary).frame(minHeight: MusicUI.target).contentShape(.rect)
    }.accessibilityLabel("Media type").accessibilityValue("Music")
      .contextMenu {
        Button("Search music", systemImage: "magnifyingglass") { if isCurrent() { search() } }
          .keyboardShortcut("f", modifiers: .command)
      }
  }
  private func symbol(_ title: String) -> String {
    switch title {
    case "Movies": "film"
    case "Photos": "photo.on.rectangle"
    case "Books": "book"
    default: "gamecontroller"
    }
  }
}

private struct MusicLibraryPicker: View {
  let browser: MusicBrowser
  let identity: AnyHashable
  let isCurrent: () -> Bool
  var body: some View {
    let owner = browser.scope
    let selected = browser.libraries.first { $0.id == browser.libraryID }
    MusicPopover(
      "Music libraries", identity: identity, identifier: "music-library-picker",
      isCurrent: { isCurrent() && browser.scope == owner && browser.metadataIsCurrent }
    ) { current, close in
      ForEach(browser.libraries) { library in
        Button {
          guard current(), browser.scope == owner, browser.metadataIsCurrent else { return }
          close()
          browser.selectLibrary(library.id)
        } label: {
          MusicMenuRow(
            title: library.title, symbol: "folder", selected: library.id == browser.libraryID)
        }.accessibilityIdentifier("music-library-" + library.id)
      }
    } label: {
      MusicUtilityLabel(title: "Music library", symbol: "folder", secondary: true)
    }.accessibilityLabel("Music library").accessibilityValue(selected?.title ?? "Library")
  }
}

private struct MusicHeaderIdentity: Hashable {
  let account: String?
  let root: UUID?
  let source: UUID?
  let context: AnyHashable
}

struct MusicHeaderActions: ToolbarContent {
  let store: PlayerStore
  let browser: MusicBrowser?
  let context: AnyHashable
  let isCurrent: () -> Bool
  @Binding var accountSheet: AccountSheet?
  var backgroundVisibility: Visibility = .hidden
  private var identity: MusicHeaderIdentity {
    MusicHeaderIdentity(
      account: store.active?.id, root: store.browser?.scope, source: browser?.scope,
      context: context
    )
  }
  var body: some ToolbarContent {
    let owner = identity
    let current = { isCurrent() && identity == owner }
    if let browser, browser.metadataIsCurrent, !browser.libraries.isEmpty {
      ToolbarItem(placement: .topBarTrailing) {
        MusicLibraryPicker(browser: browser, identity: owner, isCurrent: current)
      }.sharedBackgroundVisibility(backgroundVisibility)
    }
    ToolbarItem(placement: .topBarTrailing) {
      Menu {
        Button("Connection details", systemImage: "network") {
          if current(), let account = store.active { accountSheet = .details(account) }
        }
        if store.canApproveQuickConnect {
          Button("Quick Connect", systemImage: "number.square") {
            if current(), let account = store.active { accountSheet = .quickConnect(account) }
          }
        }
        Section {
          ForEach(store.connections) { account in
            Button(
              account.username, systemImage: account.id == owner.account ? "checkmark" : "person"
            ) {
              Task { if current() { await store.activate(account) } }
            }
          }
          Button("Add account", systemImage: "person.badge.plus") {
            if current() { store.addConnection() }
          }
        }
        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
          Task { if current() { await store.logout() } }
        }
      } label: {
        Label("Accounts", systemImage: "person.crop.circle").labelStyle(.iconOnly)
      }.accessibilityLabel("Accounts").accessibilityIdentifier("Accounts")
    }.sharedBackgroundVisibility(backgroundVisibility)
  }
}

struct MusicSheetClose: View {
  let title: String
  let symbol: String
  let identifier: String
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    Button {
      dismiss()
    } label: {
      Image(systemName: symbol).frame(width: MusicUI.target, height: MusicUI.target)
        .contentShape(.circle)
    }.buttonStyle(MusicButtonStyle(radius: MusicUI.target / 2))
      .accessibilityLabel(title).accessibilityIdentifier(identifier)
  }
}

struct MusicDurationLabel: View {
  let seconds: Double
  var body: some View {
    let text = seconds > 0 ? musicTimeText(seconds) : nil
    Text(text ?? "—")
      .font(MusicType.support.monospacedDigit()).foregroundStyle(.secondary)
      .accessibilityLabel(text.map { "Duration: " + $0 } ?? "Duration unavailable")
  }
}

func musicClockText(_ seconds: Double) -> String {
  musicTimeText(seconds) ?? "0:00"
}

struct MusicFormSurface: ViewModifier {
  func body(content: Content) -> some View {
    content.font(MusicType.primary).tint(MusicUI.tint).buttonStyle(MusicButtonStyle())
      .environment(\.defaultMinListRowHeight, MusicUI.target)
      .listSectionSpacing(MusicUI.section).scrollContentBackground(.hidden).background(
        MusicUI.canvas
      )
      .toolbarBackground(MusicUI.canvas, for: .navigationBar).toolbarBackground(
        .visible, for: .navigationBar)
  }
}

struct RetryNotice: View {
  let message: String
  let retry: () -> Void
  var body: some View {
    HStack {
      Text(message).font(MusicType.notice)
      Spacer()
      Button(action: retry) {
        Text("Retry").frame(minHeight: 44).contentShape(.rect)
      }
    }.accessibilityElement(children: .contain)
  }
}
