import SwiftUI

struct PlaylistLibraryView: View {
  let store: PlayerStore
  @Environment(\.dynamicTypeSize) private var typeSize
  let browser: MusicBrowser
  let scope: UUID
  @Binding var position: MusicPlaylist.ID?
  let insets: EdgeInsets
  let open: (MusicPlaylist) -> Void

  var body: some View {
    let index = browser.playlistIndex
    Group {
      if let message = browser.libraryError, browser.authorizedLibrary == nil {
        RetryNotice(message: message) { Task { await browser.loadLibraries() } }.musicPagePadding()
      } else if !browser.loadingLibraries && browser.libraries.isEmpty {
        MusicEmptyState(
          title: "No music libraries", systemImage: "music.note",
          message: "Check Music library access for this account in Jellyfin.")
      } else if let lists = index.items, browser.scope == scope, browser.authorizedLibrary != nil {
        ScrollView {
          LazyVGrid(
            columns: columns, alignment: .leading, spacing: store.catalogLayout == .grid ? 18 : 4
          ) {
            ForEach(lists) { playlist in
              Button {
                open(playlist)
              } label: {
                PlaylistLabel(
                  store: store, playlist: playlist, library: browser.authorizedLibrary,
                  layout: store.catalogLayout)
              }.buttonStyle(MusicButtonStyle()).accessibilityLabel(playlist.title)
                .accessibilityValue(playlist.countLabel ?? "")
                .accessibilityIdentifier("playlist-" + playlist.id)
            }
          }.scrollTargetLayout().musicPagePadding().padding(.vertical, 8)
          if let message = index.error { retry(message).musicPagePadding() }
          if lists.isEmpty && index.error == nil {
            MusicEmptyState(
              title: "No playlists", systemImage: "music.note.list",
              message: "Your Jellyfin music playlists appear here.")
          }
        }
        .contentMargins(.top, insets.top)
        .contentMargins(.bottom, insets.bottom)
        .scrollPosition(id: $position, anchor: .top)
        .accessibilityIdentifier("playlist-collection")
      } else if let message = index.error {
        retry(message).musicPagePadding()
      } else if index.restoring {
        Color.clear
      } else {
        ProgressView("Loading playlists").accessibilityIdentifier("playlist-index-loading")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity).background(MusicUI.canvas)
    .task(id: browser.authorizedLibrary) { await browser.loadPlaylistIndex(scope: scope) }
    .refreshable { await browser.loadPlaylistIndex(scope: scope, refresh: true) }
  }
  private var columns: [GridItem] {
    store.catalogLayout == .list || typeSize.isAccessibilitySize
      ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 140), spacing: 12)]
  }
  private func retry(_ message: String) -> some View {
    RetryNotice(message: message) {
      Task { await browser.loadPlaylistIndex(scope: scope, refresh: true) }
    }
  }
}

extension MusicPlaylist {
  var countLabel: String? {
    songCount.map { $0 == 1 ? "1 song" : "\($0.formatted()) songs" }
  }
}

struct PlaylistCover: View {
  let store: PlayerStore
  let playlist: MusicPlaylist
  let library: String?
  var body: some View {
    Group {
      if let item = playlist.artworkItem {
        CatalogCover(store: store, item: item, origin: store.playbackOrigin(library: library))
      } else {
        CoverArt(data: nil, demo: false, fallbackTitle: playlist.title)
      }
    }.accessibilityHidden(true)
  }
}

private struct PlaylistLabel: View {
  let store: PlayerStore
  let playlist: MusicPlaylist
  let library: String?
  let layout: CatalogLayout

  var body: some View {
    let cover = PlaylistCover(store: store, playlist: playlist, library: library)
    if layout == .grid {
      VStack(alignment: .leading, spacing: 8) {
        cover
        labels
      }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
    } else {
      HStack(spacing: 12) {
        cover.frame(width: 56, height: 56)
        labels
        Spacer(minLength: 4)
        Image(systemName: "chevron.forward").font(.footnote).foregroundStyle(.tertiary)
      }.frame(minHeight: 68).contentShape(.rect)
    }
  }
  private var labels: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(playlist.title).font(MusicType.primary.weight(.semibold)).foregroundStyle(.primary)
      if let count = playlist.countLabel {
        Text(count).font(MusicType.secondary).foregroundStyle(.secondary)
      }
    }
  }
}

struct PlaylistDetailView: View {
  let store: PlayerStore
  let browser: MusicBrowser
  let scope: UUID
  let playlist: MusicPlaylist
  let canvas: CGRect
  let openCopy: (MusicPlaylist) -> Void
  @State private var uncachedContents: PlaylistContents?
  @State private var failure: String?
  @Environment(\.playlistPicker) private var playlistPicker
  private enum ActionSheet: Identifiable {
    case edit, copy
    var id: Self { self }
  }
  @State private var actionSheet: ActionSheet?
  @State private var createdCopyID: String?
  @State private var copyOutsideIndex = false
  @Environment(\.dismiss) private var dismiss
  private var current: MusicPlaylist {
    browser.playlistIndex.items?.first { $0.id == playlist.id } ?? playlist
  }
  var body: some View {
    let contents = browser.cachedPlaylistContents(playlist, scope: scope) ?? uncachedContents
    let available =
      browser.scope == scope && browser.metadataIsCurrent
      && browser.playlistIndex.permitsOpening(playlist.id)
    let selection = available ? contents.flatMap { store.playbackSelection($0) } : nil
    BrowseScrollViewport(canvas: canvas) { insets, _ in
      List {
        if available {
          header(selection: selection, count: contents?.rows.count)
            .padding(.top, insets.top + 12)
            .background {
              if let item = current.artworkItem {
                MusicArtworkBackdrop(
                  store: store, item: item,
                  origin: store.playbackOrigin(library: browser.authorizedLibrary),
                  startPoint: UnitPoint(x: 0.5, y: 0.25))
              }
            }
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
          if let contents, let selection {
            ForEach(contents.rows) { row in
              trackRow(
                contents.tracks[row.index], row: row, count: contents.rows.count,
                selection: selection)
            }.listRowSeparator(.hidden).listRowBackground(Color.clear)
              .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
          } else if contents?.tracks.isEmpty == true {
            MusicEmptyState(
              title: "No songs in this library", systemImage: "music.note",
              message: "Add songs from the playlist editor."
            ).listRowSeparator(.hidden)
          } else if failure == nil {
            ProgressView("Loading songs").accessibilityIdentifier("playlist-detail-loading")
              .listRowSeparator(.hidden)
          }
          if let failure {
            RetryNotice(message: failure) { Task { await load(refresh: true) } }
              .listRowSeparator(.hidden)
          }
        } else {
          Text("This playlist is no longer available.").padding(.top, insets.top).listRowSeparator(
            .hidden)
        }
      }.listStyle(.plain).listRowSpacing(0).scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, insets.bottom + 12, for: .scrollContent)
        .contentMargins(.top, insets.top, for: .scrollIndicators)
        .contentMargins(.bottom, insets.bottom, for: .scrollIndicators)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .accessibilityIdentifier("playlist-detail-songs")
    }.background(MusicUI.canvas)
      .navigationTitle(current.title).navigationBarTitleDisplayMode(.inline)
      .task(id: browser.playlistIndex.revision) { await load() }
      .refreshable { await load(refresh: true) }
      .sheet(item: $actionSheet, onDismiss: openCreatedCopy) { action in
        switch action {
        case .edit:
          PlaylistEditorView(
            store: store, browser: browser, scope: scope, playlist: current,
            deleted: {
              actionSheet = nil
              dismiss()
            }, copied: showCopy)
        case .copy:
          NavigationStack {
            PlaylistCreateForm(browser: browser, scope: scope, copying: current, created: showCopy)
          }.presentationDragIndicator(.visible)
        }
      }
      .alert("Copy created", isPresented: $copyOutsideIndex) {
        Button("Done", role: .cancel) {}
      } message: {
        Text("Refresh Playlists to open the new copy.")
      }
  }
  private func showCopy(_ id: String) {
    guard browser.scope == scope, browser.metadataIsCurrent else { return }
    createdCopyID = id
    actionSheet = nil
  }
  private func openCreatedCopy() {
    guard let id = createdCopyID else { return }
    createdCopyID = nil
    guard browser.scope == scope, browser.metadataIsCurrent else { return }
    if let copy = browser.playlistIndex.items?.first(where: { $0.id == id }) {
      openCopy(copy)
    } else {
      copyOutsideIndex = true
    }
  }
  private func header(selection: PlaybackSelection?, count: Int?) -> some View {
    VStack(spacing: 12) {
      PlaylistCover(store: store, playlist: current, library: browser.authorizedLibrary)
        .frame(width: 168, height: 168)
      MusicHeroTitle(text: current.title).multilineTextAlignment(.center).accessibilityIdentifier(
        "playlist-heading")
      let library = browser.libraries.first { $0.id == browser.authorizedLibrary }?.title
      let subtitle = [
        count.map { $0 == 1 ? "1 song" : "\($0.formatted()) songs" } ?? current.countLabel, library,
      ].compactMap { $0 }.joined(separator: " · ")
      if !subtitle.isEmpty { Text(subtitle).font(MusicType.secondary).foregroundStyle(.secondary) }
      HStack(spacing: 12) {
        if let selection {
          PlaylistPlaybackButton(store: store, selection: selection)
          Button {
            store.shuffleSelection(selection)
          } label: {
            Image(systemName: "shuffle").frame(width: 44, height: 44)
          }
          .accessibilityLabel("Shuffle playlist")
        }
        Menu {
          Button("Edit playlist", systemImage: "pencil") { actionSheet = .edit }
            .accessibilityIdentifier("playlist-edit")
          Button("Make an editable copy", systemImage: "plus.square.on.square") {
            actionSheet = .copy
          }
          .accessibilityIdentifier("playlist-copy")
        } label: {
          Image(systemName: "ellipsis.circle").frame(
            minWidth: MusicUI.target, minHeight: MusicUI.target)
        }
        .accessibilityLabel("Playlist actions").accessibilityIdentifier("playlist-actions")
      }.buttonStyle(MusicButtonStyle())
    }.musicPagePadding().padding(.bottom, 12).frame(maxWidth: .infinity)
  }
  private func load(refresh: Bool = false) async {
    guard browser.playlistIndex.permitsOpening(playlist.id) else { return }
    do {
      let contents = try await browser.playlistContents(playlist, scope: scope, refresh: refresh)
      try Task.checkCancellation()
      uncachedContents =
        contents.tracks.count > PlaylistDetailCache.occurrenceLimit ? contents : nil
      failure = nil
    } catch {
      guard !Task.isCancelled, !(error is CancellationError) else { return }
      if error as? ClientError == .forbidden || error as? ClientError == .unauthorized {
        uncachedContents = nil
      }
      failure =
        (error as? ClientError)?.localizedDescription ?? "Couldn’t load the songs. Try again."
    }
  }

  private func trackRow(
    _ track: MusicItem, row: PlaylistContents.Row, count: Int, selection: PlaybackSelection
  ) -> some View {
    Button {
      store.playSelection(selection, startAt: row.index)
    } label: {
      HStack(spacing: 12) {
        CatalogCover(store: store, item: track, origin: selection.origin).frame(
          width: 44, height: 44)
        MusicIdentityLabel(title: track.title, subtitle: track.artist, context: .track(track.id))
          .layoutPriority(1)
        Spacer(minLength: 4)
        MusicDurationLabel(seconds: track.duration)
      }.frame(minHeight: 60).contentShape(.rect)
    }.buttonStyle(MusicButtonStyle()).accessibilityLabel("Play " + track.title)
      .accessibilityValue("Track \(row.index + 1) of \(count), \(track.artist)")
      .accessibilityIdentifier("playlist-track-\(row.index + 1)")
      .contextMenu {
        Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") {
          store.enqueue(track, next: true, origin: selection.origin)
        }
        Button("Add to playlist", systemImage: "text.badge.plus") {
          guard let source = selection.playlist, browser.acceptsPlaylist(source) else { return }
          playlistPicker?.present([track], from: selection.origin, store: store)
        }
      }
  }
}

private struct PlaylistPlaybackButton: View {
  let store: PlayerStore
  let selection: PlaybackSelection
  var body: some View {
    let playing = store.selectionIsCurrent(selection) && store.playbackRequested
    Button {
      store.toggleSelection(selection)
    } label: {
      Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
        .font(MusicType.control).padding(.horizontal, 18).frame(minHeight: MusicUI.target)
        .background(MusicUI.tint, in: .capsule).foregroundStyle(MusicUI.onTint)
    }.buttonStyle(MusicButtonStyle()).accessibilityLabel(
      playing ? "Pause playlist" : "Play playlist"
    )
    .accessibilityIdentifier("playlist-play")
  }
}
