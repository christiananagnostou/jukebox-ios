import SwiftUI

extension MusicCategory {
  var listRowHeight: CGFloat { self == .songs ? 56 : 64 }
}

struct AlbumPlaybackControl: View {
  let store: PlayerStore
  let browser: MusicBrowser?
  let album: MusicItem
  var compact = false
  var acceptedOrigin: PlaybackOrigin? = nil
  var isCurrent: () -> Bool = { true }
  var performAction: ((@escaping () -> Void) -> Void)? = nil
  var body: some View {
    let origin = acceptedOrigin ?? store.playbackOrigin(library: browser?.authorizedLibrary)
    let preparing = store.isPreparingAlbum(album.id, origin: origin)
    Button {
      guard isCurrent() else { return }
      if let performAction {
        performAction { store.playAlbum(album, origin: origin) }
      } else {
        store.playAlbum(album, origin: origin)
      }
    } label: {
      Group {
        if preparing {
          ProgressView()
        } else {
          MusicTransportSymbol(name: "play.fill", size: compact ? 13 : 20)
        }
      }.frame(width: 44, height: compact ? 48 : 44)
        .background { if !compact { Circle().fill(MusicUI.tint) } }
        .foregroundStyle(compact ? MusicUI.tint : MusicUI.onTint)
        .tint(compact ? MusicUI.tint : MusicUI.onTint)
    }.buttonStyle(MusicButtonStyle(radius: compact ? MusicUI.artworkRadius : 22))
      .disabled(preparing).accessibilityLabel(
        (compact ? "Play recent album " : "Play ") + album.title)
  }
}

struct AlbumCard: View {
  @Bindable var store: PlayerStore
  let album: MusicItem
  let browser: MusicBrowser
  let open: () -> Void
  var isCurrent: () -> Bool = { true }
  var body: some View {
    let origin = store.playbackOrigin(library: browser.authorizedLibrary)
    VStack(alignment: .leading, spacing: 9) {
      ZStack(alignment: .bottomTrailing) {
        Button(action: open) { CatalogCover(store: store, item: album, origin: origin) }
          .buttonStyle(
            MusicButtonStyle()
          )
          .accessibilityLabel("Open \(album.title)")
        AlbumPlaybackControl(store: store, browser: browser, album: album, isCurrent: isCurrent)
          .padding(8)
      }
      Button(action: open) {
        AlbumCardLabels(title: album.title, artist: album.artist, context: .album(album.id))
      }.buttonStyle(MusicButtonStyle()).accessibilityIdentifier("album-caption-" + album.id)
    }
  }
}
struct CatalogCover: View {
  let store: PlayerStore
  let item: MusicItem
  let origin: PlaybackOrigin?
  init(store: PlayerStore, item: MusicItem, origin: PlaybackOrigin?) {
    self.store = store
    self.item = item
    self.origin = origin
  }
  #if DEBUG
    private var measuresPlayerSurface = false
    func measuredPlayerArtwork() -> Self {
      var copy = self
      copy.measuresPlayerSurface = true
      return copy
    }
  #endif
  private func artwork(_ data: Data?) -> CoverArt {
    var result = CoverArt(
      data: data,
      demo: store.isFixture && item.imageTag != nil && item.kind != "Playlist"
        && !item.id.hasSuffix("5"),
      fallbackTitle: item.title)
    #if DEBUG
      if measuresPlayerSurface { result = result.measuredPlayerArtwork() }
    #endif
    return result
  }
  private struct Input: Equatable {
    let item: MusicItem
    let origin: PlaybackOrigin?
  }
  var body: some View {
    let input = Input(item: item, origin: origin)
    let data = origin.flatMap { store.cover(item, origin: $0) }
    Group {
      if item.kind == "MusicArtist" {
        Circle().fill(MusicUI.quiet).aspectRatio(1, contentMode: .fit)
          .overlay {
            if let data {
              CoverArt(data: data, demo: false).clipShape(.circle)
            } else {
              Image(systemName: "person.fill").font(.system(size: 28)).foregroundStyle(.secondary)
            }
          }.clipShape(.circle).accessibilityHidden(true)
      } else {
        artwork(data)
          .hueRotation(
            .degrees(
              data == nil && store.isFixture && item.kind != "Playlist"
                ? Double(item.id.utf8.reduce(0) { ($0 + Int($1)) % 90 }) : 0)
          )
          .overlay {
            RoundedRectangle(cornerRadius: MusicUI.artworkRadius)
              .strokeBorder(MusicUI.border, lineWidth: 1).allowsHitTesting(false)
          }
      }
    }.task(id: input) {
      guard let origin = input.origin else { return }
      await store.loadCover(input.item, origin: origin)
    }
  }
}
struct LibraryStatus: View {
  @Bindable var browser: MusicBrowser
  var body: some View {
    if let error = browser.libraryError {
      RetryNotice(message: error) { Task { await browser.loadLibraries() } }
    } else if browser.loadingLibraries {
      ProgressView("Loading music libraries…").font(MusicType.notice).frame(minHeight: 80)
    } else if browser.libraries.isEmpty {
      MusicEmptyState(
        title: "No music libraries", systemImage: "music.note",
        message: "Check Music library access for this account in Jellyfin.")
    }
  }
}
struct CatalogSongRow: View {
  @Bindable var store: PlayerStore
  let track: MusicItem
  let open: (MusicItem) -> Void
  let find: (String, MusicCategory) -> Void
  var selection: PlaybackSelection? = nil
  var play: (() -> Void)? = nil
  var albumRow = false
  var subtitle: String? = nil
  var information: (() -> Void)? = nil
  var actionsAreCurrent: () -> Bool = { true }
  var performAction: ((@escaping () -> Void) -> Void)? = nil
  @Environment(\.dynamicTypeSize) private var typeSize
  var body: some View {
    HStack(spacing: 12) {
      Button {
        guard actionsAreCurrent() else { return }
        if let play {
          if let performAction { performAction(play) } else { play() }
        } else if let selection {
          if let performAction {
            performAction { store.playSelection(selection) }
          } else {
            store.playSelection(selection)
          }
        }
      } label: {
        HStack(spacing: 12) {
          if albumRow {
            Text(track.number > 0 ? String(track.number) : "—")
              .font(MusicType.support.monospacedDigit()).foregroundStyle(.secondary)
              .frame(width: 24).accessibilityIdentifier("album-track-number-" + track.id)
          } else {
            CatalogCover(store: store, item: track, origin: selection?.origin).frame(
              width: 40, height: 40)
          }
          VStack(alignment: .leading, spacing: 3) {
            MusicIdentityLabel(
              title: track.title,
              subtitle: subtitle ?? (albumRow ? track.artist : track.artist + " · " + track.album),
              context: .track(track.id))
            if albumRow && typeSize.isAccessibilitySize {
              MusicDurationLabel(seconds: track.duration)
                .accessibilityIdentifier("album-track-duration-" + track.id)
            }
          }.layoutPriority(1)
          Spacer(minLength: 4)
          if albumRow && !typeSize.isAccessibilitySize {
            MusicDurationLabel(seconds: track.duration).fixedSize().accessibilityIdentifier(
              "album-track-duration-" + track.id)
          }
        }.frame(minHeight: MusicCategory.songs.listRowHeight).contentShape(.rect)
      }.buttonStyle(MusicButtonStyle()).accessibilityLabel("Play \(track.title)")
        .accessibilityValue(
          [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: ", ")
        )
        .accessibilityIdentifier("song-" + track.id)
      CatalogSongActions(
        store: store, track: track, open: open, find: find,
        origin: selection?.origin, actionsAreCurrent: actionsAreCurrent, information: information,
        performAction: performAction)

    }
  }
}

struct MusicDetailHeader<Identity: View>: View {
  let store: PlayerStore
  let item: MusicItem
  let origin: PlaybackOrigin?
  let identity: Identity
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dynamicTypeSize) private var typeSize
  init(
    store: PlayerStore, item: MusicItem, origin: PlaybackOrigin?,
    @ViewBuilder identity: () -> Identity
  ) {
    self.store = store
    self.item = item
    self.origin = origin
    self.identity = identity()
  }
  var body: some View {
    Group {
      if sizeClass == .regular && !typeSize.isAccessibilitySize {
        HStack(alignment: .center, spacing: 24) {
          artwork.frame(width: 216)
          identity.frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        VStack(alignment: .leading, spacing: 16) {
          artwork.frame(width: 216)
            .frame(maxWidth: .infinity)
          identity.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }.padding(.top, 4)
  }
  private var artwork: some View { CatalogCover(store: store, item: item, origin: origin) }
}

struct MusicHeroTitle: View {
  let text: String
  @ScaledMetric(relativeTo: .title3) private var size = 22.0
  var body: some View {
    Text(text).font(.system(size: size, weight: .semibold))
      .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
  }
}

struct MusicArtworkBackdrop: View {
  let store: PlayerStore
  let item: MusicItem
  let origin: PlaybackOrigin?
  var startPoint: UnitPoint = .top
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var body: some View {
    let tone = store.coverTone(item, origin: origin)
    let color = tone.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? MusicUI.canvas
    Group {
      if reduceTransparency {
        MusicUI.canvas
      } else {
        LinearGradient(
          colors: [color.opacity(scheme == .dark ? 0.38 : 0.18), .clear],
          startPoint: startPoint, endPoint: .bottom)
      }
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
}

struct CatalogArtistRow: View {
  let store: PlayerStore
  let artist: MusicItem
  let origin: PlaybackOrigin?
  let open: () -> Void
  var subtitle: String? = nil
  var body: some View {
    Button(action: open) {
      HStack(spacing: 12) {
        CatalogCover(store: store, item: artist, origin: origin).frame(
          width: 48, height: 48)
        VStack(alignment: .leading, spacing: 3) {
          MusicOverflowText(text: artist.title, context: .artist(artist.id))
            .font(MusicType.primary.weight(.medium)).foregroundStyle(.primary)
          if let subtitle { Text(subtitle).font(MusicType.support).foregroundStyle(.secondary) }
        }
        Spacer(minLength: 4)
      }.frame(minHeight: MusicCategory.artists.listRowHeight).contentShape(.rect)
    }.buttonStyle(MusicButtonStyle()).accessibilityLabel("Open artist \(artist.title)")
      .accessibilityIdentifier("artist-" + artist.id)
  }
}

struct CatalogAlbumRow: View {
  let store: PlayerStore
  let album: MusicItem
  let browser: MusicBrowser
  let isCurrent: () -> Bool
  let open: () -> Void
  var subtitle: String? = nil
  var performAction: ((@escaping () -> Void) -> Void)? = nil
  var body: some View {
    HStack(spacing: 8) {
      Button(action: open) {
        HStack(spacing: 12) {
          CatalogCover(
            store: store, item: album,
            origin: store.playbackOrigin(library: browser.authorizedLibrary)
          )
          .frame(width: 48, height: 48)
          MusicIdentityLabel(
            title: album.title, subtitle: subtitle ?? album.artist, context: .album(album.id))
          Spacer(minLength: 4)
        }.frame(minHeight: MusicCategory.albums.listRowHeight).contentShape(.rect)
      }.buttonStyle(MusicButtonStyle()).accessibilityLabel("Open \(album.title)")
      AlbumPlaybackControl(
        store: store, browser: browser, album: album, isCurrent: isCurrent,
        performAction: performAction)
    }
  }
}

struct CatalogSongActions: View {
  @Environment(\.playlistPicker) private var playlistPicker
  let store: PlayerStore
  let track: MusicItem
  let open: (MusicItem) -> Void
  let find: (String, MusicCategory) -> Void
  let origin: PlaybackOrigin?
  let actionsAreCurrent: () -> Bool
  var information: (() -> Void)? = nil
  var performAction: ((@escaping () -> Void) -> Void)? = nil
  private func perform(_ action: @escaping () -> Void) {
    guard actionsAreCurrent() else { return }
    if let performAction { performAction(action) } else { action() }
  }
  var body: some View {
    Menu {
      Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") {
        guard actionsAreCurrent() else { return }
        perform { store.enqueue(track, next: true, origin: origin) }
      }
      Button("Add to queue", systemImage: "text.badge.plus") {
        guard actionsAreCurrent() else { return }
        perform { store.enqueue(track, next: false, origin: origin) }
      }
      Button("Add to playlist", systemImage: "music.note.list") {
        perform { playlistPicker?.present([track], from: origin, store: store) }
      }
      if let information {
        Button("Track information", systemImage: "info.circle") {
          guard actionsAreCurrent() else { return }
          perform { information() }
        }
      }
      if let albumID = track.albumID {
        Button("Go to album", systemImage: "opticaldisc") {
          guard actionsAreCurrent() else { return }
          perform {
            open(
              MusicItem(
                id: albumID, title: track.album, artist: track.artist, album: track.album,
                duration: 0, number: 0, kind: "MusicAlbum", imageID: track.imageID,
                imageTag: track.imageTag, artistCredits: track.artistCredits))
          }
        }
      } else {
        Button("Find album", systemImage: "magnifyingglass") {
          perform { find(track.album, .albums) }
        }
      }
      ForEach(track.artistCredits ?? []) { credit in
        Button("Artist: \(credit.name)") { perform { open(credit.item) } }
      }
      if track.artistCredits?.isEmpty != false {
        Button("Find artist") { perform { find(track.artist, .artists) } }
      }
    } label: {
      Image(systemName: "ellipsis").frame(width: 44, height: 44)
    }.accessibilityLabel("Actions for \(track.title)")
      .accessibilityIdentifier("song-actions-" + track.id).buttonStyle(MusicButtonStyle())
  }
}
struct CatalogSongCard: View {
  let store: PlayerStore
  let track: MusicItem
  let open: (MusicItem) -> Void
  let find: (String, MusicCategory) -> Void
  let selection: PlaybackSelection?
  let actionsAreCurrent: () -> Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        guard actionsAreCurrent(), let selection else { return }
        store.playSelection(selection)
      } label: {
        VStack(alignment: .leading, spacing: 8) {
          CatalogCover(store: store, item: track, origin: selection?.origin)
          MusicIdentityLabel(title: track.title, subtitle: track.artist, context: .track(track.id))
        }.contentShape(.rect)
      }.buttonStyle(MusicButtonStyle()).accessibilityLabel("Play " + track.title)
        .accessibilityValue(track.artist + ", " + track.album).accessibilityIdentifier(
          "song-" + track.id)
      HStack {
        MusicDurationLabel(seconds: track.duration)
        Spacer(minLength: 0)
        CatalogSongActions(
          store: store, track: track, open: open, find: find,
          origin: selection?.origin, actionsAreCurrent: actionsAreCurrent)
      }
    }
  }
}
