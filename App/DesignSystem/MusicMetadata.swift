import SwiftUI

struct MusicFact: Identifiable {
  let title: String
  let value: String
  var id: String { title }
}
struct MusicMetadataContent: View {
  let details: MusicDetails?
  var kind = "MusicAlbum"
  var facts: [MusicFact] = []
  var isCurrent: () -> Bool = { true }
  @State private var expandedAbout = false
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.openURL) private var openURL
  private var fields: [MusicFact] {
    var result = facts
    if let year = details?.releaseYear(for: kind) {
      result.insert(MusicFact(title: "Release year", value: String(year)), at: 0)
    }
    return result
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if !fields.isEmpty {
        LazyVGrid(
          columns: Array(
            repeating: GridItem(.flexible(), alignment: .topLeading),
            count: typeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 14
        ) {
          ForEach(fields) { fact in
            VStack(alignment: .leading, spacing: 3) {
              Text(fact.title).font(MusicType.support).foregroundStyle(.secondary)
              Text(fact.value).font(MusicType.primary).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      if let overview = details?.overview {
        let collapsible = overview.count > 240
        VStack(alignment: .leading, spacing: 6) {
          sectionTitle("About")
          Text(overview).font(MusicType.primary).lineSpacing(3)
            .lineLimit(collapsible && !expandedAbout ? 5 : nil)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled).accessibilityIdentifier("music-overview")
          if collapsible {
            Button(expandedAbout ? "Show less" : "Read more") { expandedAbout.toggle() }
              .font(MusicType.control).frame(minHeight: MusicUI.target)
              .buttonStyle(MusicButtonStyle())
          }
        }
      }
      if let genres = details?.genres, !genres.isEmpty {
        textSection("Genres", value: genres.joined(separator: ", "))
      }
      if let labels = details?.labels, !labels.isEmpty {
        textSection(labels.count == 1 ? "Label" : "Labels", value: labels.joined(separator: ", "))
      }
      if let credits = details?.credits, !credits.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          sectionTitle("Credits")
          ForEach(uniqueCredits(credits), id: \.self) { credit in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text(credit.name).font(MusicType.primary).frame(
                maxWidth: .infinity, alignment: .leading)
              Text(credit.role).font(MusicType.secondary).foregroundStyle(.secondary)
            }.textSelection(.enabled)
          }
        }
      }
      if let links = details?.links, !links.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          sectionTitle("Links")
          ForEach(links) { link in
            Button {
              guard isCurrent() else { return }
              openURL(link.url)
            } label: {
              HStack {
                Text(link.title).font(MusicType.primary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(MusicType.support)
              }.frame(minHeight: MusicUI.target).contentShape(.rect)
            }.buttonStyle(MusicButtonStyle()).accessibilityHint("Opens a public website")
          }
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func uniqueCredits(_ credits: [MusicRoleCredit]) -> [MusicRoleCredit] {
    var seen = Set<MusicRoleCredit>()
    return credits.filter { seen.insert($0).inserted }
  }
  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(MusicType.control).foregroundStyle(.secondary)
  }
  private func textSection(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      sectionTitle(title)
      Text(value).font(MusicType.primary).textSelection(.enabled)
    }
  }
}
struct MusicDetailsDisclosure: View {
  let title: String
  let details: MusicDetails?
  var kind = "MusicAlbum"
  var facts: [MusicFact] = []
  var isCurrent: () -> Bool = { true }
  @State private var expanded = false
  var body: some View {
    if !facts.isEmpty || details?.hasContent(for: kind) == true {
      DisclosureGroup(isExpanded: $expanded) {
        MusicMetadataContent(details: details, kind: kind, facts: facts, isCurrent: isCurrent)
      } label: {
        Text(title).font(MusicType.control)
      }.disclosureGroupStyle(MusicDisclosureStyle())
    }
  }
}
struct MusicInformationSheet<Content: View>: View {
  let title: String
  let closeID: String
  @ViewBuilder let content: Content
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: MusicUI.section) { content }
          .musicPagePadding().padding(.vertical, MusicUI.section).frame(
            maxWidth: 700, alignment: .leading
          )
          .frame(maxWidth: .infinity)
      }
      .background(MusicUI.canvas).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          MusicSheetClose(
            title: "Close " + title.lowercased(), symbol: "xmark", identifier: closeID)
        }.sharedBackgroundVisibility(.hidden)
      }
    }.presentationDragIndicator(.visible)
  }
}
private struct MusicDisclosureStyle: DisclosureGroupStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
          configuration.isExpanded.toggle()
        }
      } label: {
        HStack {
          configuration.label
          Spacer(minLength: 12)
          Image(systemName: configuration.isExpanded ? "chevron.up" : "chevron.down")
            .font(MusicType.support).foregroundStyle(.secondary)
        }.foregroundStyle(.primary).frame(minHeight: MusicUI.target).contentShape(.rect)
      }.buttonStyle(MusicButtonStyle()).accessibilityValue(
        configuration.isExpanded ? "Expanded" : "Collapsed")
      if configuration.isExpanded { configuration.content.padding(.top, 4).padding(.bottom, 12) }
    }
  }
}

func musicTechnicalFacts(_ value: MusicTechnicalInfo) -> [MusicFact] {
  [
    value.codec.map { MusicFact(title: "Format", value: $0) },
    value.sampleRate.map {
      MusicFact(title: "Sample rate", value: String(Double($0) / 1000) + " kHz")
    },
    value.bitDepth.map { MusicFact(title: "Bit depth", value: "\($0) bit") },
    value.channels.map { MusicFact(title: "Channels", value: String($0)) },
    value.bitRate.map { MusicFact(title: "Bit rate", value: "\($0 / 1000) kbps") },
  ].compactMap { $0 }
}
struct MusicFavoriteAction: View {
  let content: AlbumContent
  let identifier: String
  var isCurrent: () -> Bool = { true }
  var body: some View {
    Button {
      guard isCurrent() else { return }
      content.toggleFavorite()
    } label: {
      Image(systemName: content.favoriteValue == true ? "heart.fill" : "heart")
        .frame(width: 44, height: 44)
        .foregroundStyle(content.favoriteValue == true ? MusicUI.tint : .primary)
        .overlay(alignment: .bottomTrailing) {
          if content.favoritePending { ProgressView().controlSize(.mini).accessibilityHidden(true) }
        }
    }.buttonStyle(MusicButtonStyle()).disabled(content.favoriteValue == nil)
      .accessibilityLabel(
        content.favoriteValue == true ? "Remove from favorites" : "Add to favorites"
      )
      .accessibilityValue(
        content.favoritePending ? "Saving" : (content.favoriteValue == nil ? "Unavailable" : "")
      )
      .accessibilityIdentifier(identifier)
  }
}
