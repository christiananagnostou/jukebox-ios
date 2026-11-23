import SwiftUI

struct CatalogAlbumView: View {
  let store: PlayerStore
  let canvas: CGRect
  @State private var content: AlbumContent
  @State private var informationTrack: MusicItem?
  let open: (MusicItem) -> Void
  let find: (String, MusicCategory) -> Void
  init(
    store: PlayerStore, content: AlbumContent, canvas: CGRect,
    open: @escaping (MusicItem) -> Void, find: @escaping (String, MusicCategory) -> Void
  ) {
    self.store = store
    self.canvas = canvas
    _content = State(initialValue: content)
    self.open = open
    self.find = find
  }
  var body: some View {
    let accepted = content
    let library = accepted.authorizedLibrary
    let current = { library != nil && accepted.authorizedLibrary == library }
    BrowseScrollViewport(canvas: canvas) { insets, _ in
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          header(library: library, current: current)
            .albumColumn()
            .padding(.top, insets.top + 16)
            .background {
              MusicArtworkBackdrop(
                store: store, item: content.album, origin: store.playbackOrigin(library: library),
                startPoint: UnitPoint(x: 0.5, y: 0.25))
            }
          VStack(alignment: .leading, spacing: 12) {
            details(current: current)
            trackList(library: library, current: current)
          }.albumColumn()
        }.padding(.bottom, insets.bottom + 16)
      }
      .contentMargins(0, for: .scrollContent)
      .contentMargins(.top, insets.top, for: .scrollIndicators)
      .contentMargins(.bottom, insets.bottom, for: .scrollIndicators)
      .scrollEdgeEffectStyle(.soft, for: .vertical)
      .accessibilityIdentifier("album-scroll")
    }
    .background(MusicUI.canvas)
    .navigationTitle("").navigationBarTitleDisplayMode(.inline)
    .task {
      await content.load()
      await content.loadArtistPortrait()
    }
    .sheet(item: $informationTrack) { track in
      MusicInformationSheet(title: "Track information", closeID: "close-track-information") {
        if current() {
          MusicHeroTitle(text: track.title)
          Text("Original file").font(MusicType.control).foregroundStyle(.secondary)
          if content.trackInformationLoading {
            ProgressView().frame(minHeight: 80).accessibilityLabel("Loading track information")
          } else if let value = content.trackInformation, value.hasContent {
            MusicMetadataContent(details: nil, kind: "Audio", facts: musicTechnicalFacts(value))
          } else if let error = content.trackInformationError {
            RetryNotice(message: error) {
              Task { await content.loadTrackInformation(id: track.id) }
            }
          } else {
            Text("Jellyfin hasn’t supplied technical details for this track.")
              .font(MusicType.notice).foregroundStyle(.secondary)
          }
        }
      }.task(id: track.id) { await content.loadTrackInformation(id: track.id) }
    }
  }
  private func header(library: String?, current: @escaping () -> Bool) -> some View {
    MusicDetailHeader(
      store: store, item: content.album,
      origin: store.playbackOrigin(library: library)
    ) {
      VStack(alignment: .leading, spacing: 6) {
        MusicHeroTitle(text: content.album.title).accessibilityIdentifier("album-heading")
        artistIdentity(current: current)
        Text(content.loading ? " " : albumSummary).font(MusicType.secondary)
          .foregroundStyle(.secondary).frame(minHeight: 20)
          .accessibilityHidden(content.loading)
        AlbumDetailActions(store: store, content: content)
      }
    }
  }
  @ViewBuilder private func details(current: @escaping () -> Bool) -> some View {
    if let error = content.favoriteError {
      Text(error).font(MusicType.notice).foregroundStyle(.secondary)
        .accessibilityIdentifier("album-favorite-error")
    }
    if !content.loading {
      MusicDetailsDisclosure(
        title: "Album details", details: content.album.details,
        facts: albumFacts, isCurrent: current)
    } else {
      Text("Album details").font(MusicType.control).frame(minHeight: MusicUI.target)
        .redacted(reason: .placeholder).accessibilityHidden(true)
    }
    if let error = content.error {
      RetryNotice(message: error) { Task { await content.load() } }
    }
  }
  private func trackList(library: String?, current: @escaping () -> Bool) -> some View {
    let selection = store.playbackSelection(content.tracks, library: library)
    return LazyVStack(spacing: 0) {
      if content.loading && content.tracks.isEmpty {
        ForEach(0..<4) { _ in
          HStack(spacing: 12) {
            Rectangle().fill(.quaternary).frame(width: 24, height: 16)
            MusicIdentityLabel(title: "Track title", subtitle: "Artist").redacted(
              reason: .placeholder)
            MusicDurationLabel(seconds: 180).redacted(reason: .placeholder)
            Color.clear.frame(width: 44, height: 44)
          }.frame(minHeight: 56).accessibilityHidden(true)
        }
      } else {
        ForEach(content.tracks.enumerated(), id: \.element.id) { index, track in
          CatalogSongRow(
            store: store, track: track, open: open, find: find, selection: selection,
            play: {
              guard current(), let selection else { return }
              store.playSelection(selection, startAt: index)
            }, albumRow: true,
            information: {
              guard current() else { return }
              informationTrack = track
            }, actionsAreCurrent: current)
        }
        if content.tracks.isEmpty && !content.loading && content.error == nil {
          MusicEmptyState(
            title: "No tracks", systemImage: "music.note",
            message: "This album has no available music tracks.")
        }
      }
    }
  }
  private func artistIdentity(current: @escaping () -> Bool) -> some View {
    let credits = content.album.artistCredits ?? []
    return HStack(spacing: 6) {
      if let credit = credits.first {
        Button {
          guard current() else { return }
          open(credit.item)
        } label: {
          HStack(spacing: 8) {
            CatalogCover(
              store: store, item: content.artistPortrait ?? credit.item,
              origin: store.playbackOrigin(library: content.authorizedLibrary)
            ).frame(width: 28, height: 28)
            Text(credit.name).font(MusicType.primary).foregroundStyle(.primary)
              .multilineTextAlignment(.leading)
          }.frame(minHeight: MusicUI.target).contentShape(.rect)
        }.buttonStyle(MusicButtonStyle()).accessibilityLabel(credit.name).accessibilityHint(
          "Opens artist")
        if credits.count > 1 {
          Menu {
            ForEach(credits.dropFirst()) { other in
              Button(other.name) {
                guard current() else { return }
                open(other.item)
              }
            }
          } label: {
            Text("+\(credits.count - 1)").font(MusicType.secondary).frame(
              minWidth: 44, minHeight: 44)
          }.buttonStyle(MusicButtonStyle()).accessibilityLabel("More album artists")
        }
      } else {
        Button {
          guard current() else { return }
          find(content.album.artist, .artists)
        } label: {
          Label(content.album.artist, systemImage: "person.crop.circle")
            .font(MusicType.primary).frame(minHeight: MusicUI.target)
        }.buttonStyle(MusicButtonStyle()).accessibilityLabel("Find artist: " + content.album.artist)
      }
      Spacer(minLength: 0)
    }
  }
  private var albumFacts: [MusicFact] {
    var result = [MusicFact(title: "Tracks", value: String(content.tracks.count))]
    let duration = content.tracks.reduce(0) { $0 + max(0, $1.duration.isFinite ? $1.duration : 0) }
    if duration > 0 { result.append(MusicFact(title: "Length", value: musicClockText(duration))) }
    let discs = Set(content.tracks.compactMap { $0.details?.disc })
    if !discs.isEmpty { result.append(MusicFact(title: "Discs", value: String(discs.count))) }
    return result
  }
  private var albumSummary: String {
    let count = content.tracks.count
    let seconds = content.tracks.reduce(0) { $0 + max(0, $1.duration.isFinite ? $1.duration : 0) }
    return [
      content.album.details?.releaseYear(for: "MusicAlbum").map(String.init),
      "\(count) \(count == 1 ? "track" : "tracks")", seconds > 0 ? musicClockText(seconds) : nil,
    ]
    .compactMap { $0 }.joined(separator: " · ")
  }

}

extension View {
  fileprivate func albumColumn() -> some View {
    musicPagePadding().frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
  }
}

private struct AlbumDetailActions: View {
  @Environment(\.playlistPicker) private var playlistPicker
  let store: PlayerStore
  let content: AlbumContent
  var body: some View {
    let library = content.authorizedLibrary
    let selection = store.playbackSelection(content.tracks, library: library)
    let current = selection.map { store.selectionIsCurrent($0) } == true
    let requested = current && store.playbackRequested
    let preparing = store.isPreparingAlbum(content.album.id, origin: selection?.origin)
    HStack(spacing: 4) {
      MusicFavoriteAction(content: content, identifier: "album-favorite")
      Button {
        guard library != nil, content.authorizedLibrary == library, let selection else { return }
        store.shuffleSelection(selection)
      } label: {
        Image(systemName: "shuffle").frame(width: 44, height: 44)
      }.disabled(selection == nil || content.loading).accessibilityLabel("Shuffle album")
        .accessibilityIdentifier("album-shuffle")
      Menu {
        Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") {
          guard library != nil, content.authorizedLibrary == library, let selection else { return }
          store.enqueueSelection(selection, next: true)
        }
        Button("Add to playlist", systemImage: "music.note.list") {
          guard let selection, content.authorizedLibrary == library else { return }
          playlistPicker?.present(selection.items, from: selection.origin, store: store)
        }
        Button("Add to queue", systemImage: "text.badge.plus") {
          guard library != nil, content.authorizedLibrary == library, let selection else { return }
          store.enqueueSelection(selection, next: false)
        }
      } label: {
        Image(systemName: "ellipsis").frame(width: 44, height: 44)
      }.disabled(selection == nil || content.loading).accessibilityLabel("Album actions")
        .accessibilityIdentifier("album-actions")
      Spacer(minLength: 4)
      Button {
        guard library != nil, content.authorizedLibrary == library, let selection else { return }
        store.toggleSelection(selection)
      } label: {
        HStack(spacing: 8) {
          if preparing {
            ProgressView().tint(MusicUI.onTint)
          } else {
            Image(systemName: requested ? "pause.fill" : "play.fill")
          }
          Text(requested ? "Pause" : "Play").font(MusicType.control)
        }.padding(.horizontal, 18).frame(minHeight: 44)
          .background(MusicUI.tint, in: .capsule).foregroundStyle(MusicUI.onTint)
      }.disabled(selection == nil || content.loading).accessibilityLabel(
        requested ? "Pause album" : "Play album"
      )
      .accessibilityIdentifier("album-play")
    }.buttonStyle(MusicButtonStyle())
  }
}
