import ImageIO
import SwiftUI

struct ArtistHero: View {
  let store: PlayerStore
  let artist: MusicItem?
  let name: String
  let origin: PlaybackOrigin?
  let topInset: CGFloat
  let readableHeight: CGFloat
  @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 48.0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var solid
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let motionDisabled = reduceMotion
    return ZStack(alignment: .bottomLeading) {
      Color.clear.aspectRatio(1.04, contentMode: .fit)
        .frame(maxHeight: max(160, min(480, readableHeight * 0.76)))
      Text(name).font(.system(size: titleSize, weight: .heavy))
        .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14).musicPagePadding()
        .background(solid || contrast == .increased ? Color.black : .clear)
        .padding(.top, topInset + 16)
        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("artist-heading")
    }.frame(maxWidth: .infinity, alignment: .bottomLeading)
      .background {
        ArtistPortrait(store: store, item: artist, origin: origin)
          .overlay {
            if !solid {
              LinearGradient(
                stops: [
                  .init(color: .black.opacity(0.32), location: 0),
                  .init(color: .clear, location: 0.36),
                  .init(color: .black.opacity(0.14), location: 0.56),
                  .init(color: .black.opacity(0.86), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
          }
          .visualEffect { content, geometry in
            let pull =
              motionDisabled ? 0 : max(0, geometry.frame(in: .scrollView(axis: .vertical)).minY)
            return content.scaleEffect(1 + pull / max(geometry.size.height, 1), anchor: .bottom)
          }
          .allowsHitTesting(false).accessibilityHidden(true)
      }
  }
}

private struct ArtistPortrait: View {
  struct Request: Equatable {
    let id: String
    let image: String
    let tag: String
    let origin: PlaybackOrigin
  }
  let store: PlayerStore
  let item: MusicItem?
  let origin: PlaybackOrigin?
  @State private var loaded: (Request, CGImage)?
  private var request: Request? {
    guard let origin, let item, item.kind == "MusicArtist", let image = item.imageID,
      image == item.id, let tag = item.imageTag, !tag.isEmpty
    else { return nil }
    return Request(id: item.id, image: image, tag: tag, origin: origin)
  }

  var body: some View {
    let key = request
    GeometryReader { geometry in
      ZStack {
        Color(red: 0.13, green: 0.16, blue: 0.20)
        if let key, let loaded, key == loaded.0 {
          Image(decorative: loaded.1, scale: 1).resizable().scaledToFill()
        } else {
          Image(systemName: "person.fill").resizable().scaledToFit()
            .foregroundStyle(.white.opacity(0.16)).padding(.top, geometry.size.height * 0.19)
        }
      }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
    }
    .task(id: key) {
      guard let key, let item else {
        loaded = nil
        return
      }
      if loaded?.0 == key { return }
      loaded = nil
      await store.loadCover(item, origin: key.origin)
      guard !Task.isCancelled, let data = store.cover(item, origin: key.origin) else { return }
      let image = await Task.detached(priority: .utility) { Self.decode(data) }.value
      if !Task.isCancelled, let image, store.cover(item, origin: key.origin) != nil {
        loaded = (key, image)
      }
    }
  }

  nonisolated private static func decode(_ data: Data) -> CGImage? {
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: 1200,
      ] as CFDictionary)
  }
}

struct ArtistProfileActions: View {
  let store: PlayerStore
  let songs: ArtistSongs?
  let library: String?
  let isCurrent: () -> Bool
  let about: () -> Void
  @State private var pending: Task<Void, Never>?
  @State private var failed = false

  var body: some View {
    let selection = (songs?.allLoadedTracks).flatMap {
      store.playbackSelection($0, library: library)
    }
    let playing = selection.map(store.selectionIsCurrent) == true && store.playbackRequested
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Button {
          if isCurrent() { about() }
        } label: {
          Label("About", systemImage: "info.circle").font(MusicType.control)
            .padding(.horizontal, 14).frame(minHeight: 44)
            .overlay { Capsule().strokeBorder(MusicUI.border) }
        }.accessibilityLabel("Artist information").accessibilityIdentifier("artist-information")
        Spacer(minLength: 4)
        Button {
          play(shuffled: true)
        } label: {
          Image(systemName: "shuffle").font(.title3).frame(width: 44, height: 44)
        }.accessibilityLabel("Shuffle artist").accessibilityIdentifier("artist-shuffle")
          .disabled(songs?.highlights.isEmpty != false || pending != nil)
        Button {
          if let selection, store.selectionIsCurrent(selection), isCurrent() {
            store.toggle()
          } else {
            play(shuffled: false)
          }
        } label: {
          ZStack {
            Circle().fill(MusicUI.tint)
            if pending != nil {
              ProgressView().tint(MusicUI.onTint)
            } else {
              Image(systemName: playing ? "pause.fill" : "play.fill").font(.title3.bold())
                .foregroundStyle(MusicUI.onTint)
            }
          }.frame(width: 52, height: 52)
        }.accessibilityLabel(playing ? "Pause artist" : "Play artist").accessibilityIdentifier(
          "artist-play"
        )
        .disabled(songs?.highlights.isEmpty != false || pending != nil)
      }.buttonStyle(MusicButtonStyle())
      if failed {
        Text("The artist’s songs couldn’t load. Tap Play or Shuffle to retry.").font(
          MusicType.notice
        ).foregroundStyle(.secondary)
      }
    }
    .onDisappear {
      pending?.cancel()
      pending = nil
    }
  }

  private func play(shuffled: Bool) {
    guard isCurrent(), pending == nil, let songs else { return }
    let command = store.playbackCommandIsCurrent()
    failed = false
    pending = Task {
      defer { if !Task.isCancelled { pending = nil } }
      do {
        let tracks = try await songs.tracksForPlayback { isCurrent() && command() }
        guard isCurrent(), command(), !Task.isCancelled,
          let selection = store.playbackSelection(tracks, library: library)
        else { return }
        if shuffled { store.shuffleSelection(selection) } else { store.playSelection(selection) }
      } catch {
        if isCurrent(), command(), !Task.isCancelled, !(error is CancellationError) {
          failed = true
        }
      }
    }
  }
}

struct ArtistHighlightRow: View {
  let store: PlayerStore
  let track: MusicItem
  let rank: Int
  let selection: PlaybackSelection?
  let isCurrent: () -> Bool
  let open: (MusicItem) -> Void
  let search: (String, MusicCategory) -> Void

  var body: some View {
    HStack(spacing: 6) {
      Button {
        guard isCurrent(), let selection else { return }
        store.playSelection(selection, startAt: rank - 1)
      } label: {
        HStack(spacing: 10) {
          Text(String(rank)).font(MusicType.secondary.monospacedDigit())
            .foregroundStyle(.secondary).frame(minWidth: 16)
          CatalogCover(store: store, item: track, origin: selection?.origin).frame(
            width: 46, height: 46)
          MusicIdentityLabel(title: track.title, subtitle: track.album, context: .track(track.id))
          Spacer(minLength: 0)
        }.frame(minHeight: 56).contentShape(.rect)
      }.buttonStyle(MusicButtonStyle()).accessibilityLabel("Play " + track.title)
        .accessibilityValue(track.album).accessibilityIdentifier("artist-highlight-" + track.id)
      CatalogSongActions(
        store: store, track: track, open: open, find: search,
        origin: selection?.origin, actionsAreCurrent: isCurrent)
    }
  }
}
