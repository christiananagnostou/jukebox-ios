import SwiftUI

struct LibraryBrowseControls<Utilities: View>: View {
  let category: MusicCategory
  let showingPlaylists: Bool
  let select: (MusicCategory?) -> Void
  @ViewBuilder let utilities: Utilities
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    GlassEffectContainer(spacing: 4) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          tabs.fixedSize(horizontal: true, vertical: false)
          Spacer(minLength: 0)
          actions
        }
        VStack(alignment: .leading, spacing: 4) {
          ViewThatFits(in: .horizontal) {
            tabs.fixedSize(horizontal: true, vertical: false)
            ScrollViewReader { proxy in
              ScrollView(.horizontal) { tabs }
                .scrollIndicators(.hidden)
                .onChange(of: selectedTitle, initial: true) { _, title in
                  proxy.scrollTo(title, anchor: .center)
                }
            }
          }
          actions.frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
    }
    .musicPagePadding().padding(.vertical, 4)
    .background(reduceTransparency ? MusicUI.canvas : .clear)
    .accessibilityElement(children: .contain).accessibilityIdentifier("music-browse-controls")
  }

  private var selectedTitle: String { showingPlaylists ? "Playlists" : category.rawValue }

  private var tabs: some View {
    HStack(spacing: 0) {
      ForEach(MusicCategory.allCases) { category in
        tab(category.rawValue, category: category)
      }
      tab("Playlists", category: nil)
    }
    .padding(.horizontal, 3)
    .modifier(BrowseControlGlass())
    .accessibilityElement(children: .contain).accessibilityIdentifier("music-category-tabs")
  }

  private func tab(_ title: String, category: MusicCategory?) -> some View {
    let selected = title == selectedTitle
    return Button {
      select(category)
    } label: {
      Text(title).font(MusicType.control).fontWeight(selected ? .semibold : .regular)
        .foregroundStyle(selected ? .primary : .secondary)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? MusicUI.quiet : .clear, in: .capsule)
        .frame(minWidth: MusicUI.target, minHeight: MusicUI.target).contentShape(.rect)
    }.buttonStyle(MusicButtonStyle(radius: 22))
      .accessibilityAddTraits(selected ? [.isSelected] : [])
      .accessibilityIdentifier("music-category-" + title).id(title)
  }

  private var actions: some View {
    HStack(spacing: 0) { utilities }
      .buttonStyle(MusicButtonStyle(radius: 22))
      .fixedSize(horizontal: true, vertical: false)
      .modifier(BrowseControlGlass())
  }
}
