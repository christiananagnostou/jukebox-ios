#if DEBUG
  import SwiftUI

  private struct CatalogPreview: View {
    @State private var store = PlayerStore(
      storage: LibraryStorage(), vault: MemoryVault(),
      driver: NativePlayer(muted: true, tailsEnabled: false), deviceID: "preview")
    private let fixture = FixtureCatalog(
      source: Bundle.main.resourceURL!.appendingPathComponent("Fixtures/tone.wav"))
    var body: some View {
      AppRoot(store: store, fixture: fixture).task { await store.enterFixture(service: fixture) }
    }
  }
  private struct MusicComponentGallery: View {
    private let details = MusicDetails(
      year: 2014, genres: ["Instrumental"],
      overview: "An invented album used to review compact typography and progressive details.")
    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: MusicUI.section) {
          MusicHeroTitle(text: "A Long Invented Album Title for Readable Wrapping")
          MusicIdentityLabel(title: "Example Artist", subtitle: "Album artist")
          HStack(spacing: MusicUI.group) {
            MusicChoiceLabel(title: "Albums", selected: true)
            MusicChoiceLabel(title: "Artists", selected: false)
            Spacer(minLength: 0)
          }
          HStack(spacing: MusicUI.group) {
            Button {
            } label: {
              MusicUtilityLabel(title: "Favorite", symbol: "heart")
            }
            Button {
            } label: {
              MusicUtilityLabel(title: "More", symbol: "ellipsis")
            }
            Spacer(minLength: 0)
            Button {
            } label: {
              MusicPrimaryActionLabel(title: "Play", symbol: "play.fill")
            }
          }.buttonStyle(MusicButtonStyle())
          MusicDetailsDisclosure(
            title: "Album details", details: details,
            facts: [
              MusicFact(title: "Tracks", value: "12"),
              MusicFact(title: "Length", value: "48:12"),
            ])
          MusicMetadataContent(
            details: MusicDetails(year: 1947, overview: "An invented artist biography."),
            kind: "MusicArtist")
          MusicEmptyState(
            title: "No matching music", systemImage: "music.note",
            message: "Try another filter.")
        }.musicPagePadding().padding(.vertical, MusicUI.section)
      }.background(MusicUI.canvas).tint(MusicUI.tint)
    }
  }
  #Preview("Invented catalog — memory only") { CatalogPreview() }
  #Preview("Shared components — light") {
    MusicComponentGallery().preferredColorScheme(.light)
  }
  #Preview("Shared components — dark") {
    MusicComponentGallery().preferredColorScheme(.dark)
  }
  #Preview("Shared components — accessible RTL") {
    MusicComponentGallery().environment(\.dynamicTypeSize, .accessibility3)
      .environment(\.layoutDirection, .rightToLeft)
  }
#endif
