import SwiftUI

@MainActor final class HomeScrollPositions {
  var offsets: [HomeSection?: CGFloat] = [:]
}

struct HomeScrollRestoration: ViewModifier {
  let positions: HomeScrollPositions
  let section: HomeSection?
  let isCurrent: () -> Bool
  @State private var position = ScrollPosition()

  func body(content: Content) -> some View {
    content.scrollPosition($position)
      .onAppear {
        if let distance = positions.offsets[section], distance > 0 {
          if section == nil {
            position.scrollTo(y: distance)
          } else {
            position.scrollTo(x: distance)
          }
        }
      }
      .onScrollPhaseChange { old, new, change in
        guard new == .idle, old != .tracking, isCurrent() else { return }
        let geometry = change.geometry
        let distance =
          section == nil
          ? geometry.contentOffset.y + geometry.contentInsets.top
          : geometry.contentOffset.x + geometry.contentInsets.leading
        if distance.isFinite { positions.offsets[section] = max(0, distance) }
      }
  }
}

struct HomeTile<Artwork: View>: View {
  let title: String
  let subtitle: String?
  let actionLabel: String
  let action: () -> Void
  @ViewBuilder let artwork: () -> Artwork

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 9) {
        artwork().accessibilityHidden(true)
        if let subtitle {
          AlbumCardLabels(title: title, artist: subtitle)
        } else {
          Text(title).font(MusicType.primary.weight(.medium)).lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }.contentShape(.rect)
    }.buttonStyle(MusicButtonStyle()).accessibilityLabel(actionLabel)
      .accessibilityValue(subtitle ?? "")
  }
}

struct HomeGenreCover: View {
  let store: PlayerStore
  let genre: HomeGenre
  let origin: PlaybackOrigin?
  var body: some View {
    Rectangle().fill(MusicUI.quiet).aspectRatio(1, contentMode: .fit).overlay {
      if genre.covers.count >= 4 {
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
          ForEach(0..<2) { row in
            GridRow {
              ForEach(0..<2) { column in
                CatalogCover(store: store, item: genre.covers[row * 2 + column], origin: origin)
              }
            }
          }
        }
      } else if let item = genre.covers.first {
        CatalogCover(store: store, item: item, origin: origin)
      } else {
        Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
      }
    }.clipShape(.rect(cornerRadius: MusicUI.artworkRadius))
  }
}

struct HomeLayoutEditor: View {
  let browser: MusicBrowser
  let scope: UUID
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    let layout = browser.homeLayout
    NavigationStack {
      List {
        Section {
          ForEach(layout.order) { section in
            let visible = !layout.hidden.contains(section)
            HStack {
              Text(section.title).font(MusicType.primary)
              Spacer()
              Button {
                change { $0.setVisible(!visible, section: section) }
              } label: {
                Image(systemName: visible ? "eye" : "eye.slash").frame(width: 44, height: 44)
              }.buttonStyle(.borderless).accessibilityLabel(
                (visible ? "Hide " : "Show ") + section.title)
              Menu {
                Button("Move earlier", systemImage: "arrow.up") { move(section, by: -1) }
                  .disabled(section == layout.order.first)
                Button("Move later", systemImage: "arrow.down") { move(section, by: 1) }
                  .disabled(section == layout.order.last)
              } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
              }.accessibilityLabel("Move " + section.title)
            }.accessibilityIdentifier("edit-home-" + section.rawValue)
          }
          .onMove { source, destination in change { $0.move(from: source, to: destination) } }
        }
        Button("Restore default layout") { browser.setHomeLayout(HomeLayout(), scope: scope) }
          .disabled(layout == HomeLayout())
      }
      .environment(\.editMode, .constant(.active))
      .navigationTitle("Customize Home").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }.presentationDragIndicator(.visible)
  }

  private func move(_ section: HomeSection, by delta: Int) {
    guard let index = browser.homeLayout.order.firstIndex(of: section),
      browser.homeLayout.order.indices.contains(index + delta)
    else { return }
    change { $0.move(from: IndexSet(integer: index), to: delta < 0 ? index - 1 : index + 2) }
  }
  private func change(_ update: (inout HomeLayout) -> Void) {
    var layout = browser.homeLayout
    update(&layout)
    browser.setHomeLayout(layout, scope: scope)
  }
}
