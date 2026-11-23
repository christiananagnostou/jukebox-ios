import SwiftUI

struct GenreAlbumsView: View {
  let store: PlayerStore
  let browser: MusicBrowser
  let scope: UUID
  let genre: HomeGenre
  let open: (MusicItem) -> Void
  @State private var offset = 0
  @State private var page: CatalogPage?
  @State private var failed = false
  @State private var retry = 0
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: MusicUI.group) {
        if failed {
          RetryNotice(message: "Albums couldn’t load.") { retry += 1 }
        } else if let page {
          if page.items.isEmpty {
            Text("No albums on this page.").font(MusicType.notice).foregroundStyle(.secondary)
          }
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 145))],
            alignment: .leading, spacing: 18
          ) {
            ForEach(page.items) { album in
              AlbumCard(
                store: store, album: album, browser: browser,
                open: { if browser.scope == scope { open(album) } },
                isCurrent: { browser.scope == scope })
            }
          }
        } else {
          ProgressView("Loading albums")
        }
        HStack {
          if offset > 0 { Button("Previous albums") { offset -= 40 } }
          Spacer()
          if page?.rawCount == 40 { Button("More albums") { offset += 40 } }
        }
      }.musicPagePadding().padding(.vertical)
    }
    .id(offset)
    .navigationTitle(genre.name).navigationBarTitleDisplayMode(.inline)
    .task(id: [offset, retry]) {
      page = nil
      failed = false
      do {
        let value = try await browser.genreAlbums(genre, offset: offset, scope: scope)
        if !Task.isCancelled { page = value }
      } catch {
        if !Task.isCancelled, browser.scope == scope { failed = true }
      }
    }
  }
}
