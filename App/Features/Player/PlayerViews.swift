import AVKit
import SwiftUI

struct MiniPlayer: View {
  @Bindable var store: PlayerStore
  var systemGlass = false
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var body: some View {
    HStack(spacing: 12) {
      Button {
        store.showPlayer = true
      } label: {
        HStack(spacing: 12) {
          CoverArt(data: store.playbackArtwork, demo: store.isFixture).frame(
            width: 36, height: 36)
          VStack(alignment: .leading, spacing: 3) {
            MusicOverflowText(text: store.current?.track.title ?? "", context: .reading).font(
              MusicType.notice.weight(.medium)
            )
            .accessibilityIdentifier("mini-title")
            MusicOverflowText(
              text:
                store.phase.preparationMessage ?? store.current?.track.artist ?? "",
              context: .reading
            ).font(MusicType.support).foregroundStyle(.secondary).lineLimit(1)
              .accessibilityIdentifier("mini-artist")
          }
          Spacer(minLength: 0)
        }.contentShape(.rect)
      }.buttonStyle(MusicButtonStyle()).accessibilityLabel("Open now playing")
        .accessibilityValue(store.current.map { "\($0.track.title), \($0.track.artist)" } ?? "")
      Button {
        store.toggle()
      } label: {
        MusicTransportSymbol(name: store.playbackRequested ? "pause.fill" : "play.fill").frame(
          width: 44, height: 44
        )
        .foregroundStyle(.primary)
      }.buttonStyle(MusicButtonStyle(radius: 22))
        .accessibilityLabel(store.playbackRequested ? "Pause" : "Play").accessibilityIdentifier(
          "mini-toggle")
      Button {
        store.next()
      } label: {
        MusicTransportSymbol(name: "forward.end.fill").frame(width: 44, height: 44)
      }.buttonStyle(MusicButtonStyle(radius: 22)).accessibilityLabel("Next track")
    }.musicTextMotion(allowed: !store.showPlayer && !store.showQueue)
      .padding(.horizontal, 12).padding(.vertical, 4)
      .background(systemGlass && !reduceTransparency ? Color.clear : MusicUI.panel)
      .accessibilityElement(children: .contain).accessibilityIdentifier("mini-player")
      .simultaneousGesture(
        DragGesture(minimumDistance: 24).onEnded { value in
          if value.translation.height < -24,
            abs(value.translation.height) > abs(value.translation.width)
          {
            store.showPlayer = true
          }
        })
  }
}
struct AudioOutputPicker: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let view = AVRoutePickerView()
    view.prioritizesVideoDevices = false
    view.accessibilityLabel = "Choose audio output"
    return view
  }
  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
private struct PlayerPresentation {
  let entry: QueueEntry
  let origin: PlaybackOrigin
  let revision: UUID
  let content: AlbumContent
  @MainActor func isCurrent(_ store: PlayerStore) -> Bool {
    store.playerContentRevision == revision
      && store.playbackOrigin(library: origin.library) == origin
  }
}
struct PlayerScreen: View {
  let store: PlayerStore
  var related: ((MusicItem, PlaybackOrigin) -> Void)? = nil
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var presentation: PlayerPresentation?
  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        let horizontal = geometry.size.width > 540 && !typeSize.isAccessibilitySize
        let contentInset: CGFloat = 24
        let artSize = horizontal ? 200 : min(300, geometry.size.width - 2 * contentInset)
        ScrollView {
          if let presentation, presentation.isCurrent(store) {
            let content = presentation.content
            let current = { presentation.isCurrent(store) }
            let open: (MusicItem) -> Void = { item in
              guard current() else { return }
              related?(item, presentation.origin)
            }
            VStack(alignment: .leading, spacing: MusicUI.section) {
              let arrangement =
                horizontal
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 24))
                : AnyLayout(VStackLayout(spacing: 18))
              arrangement {
                CatalogCover(store: store, item: content.album, origin: presentation.origin)
                  #if DEBUG
                    .measuredPlayerArtwork()
                  #endif
                  .frame(width: max(96, artSize), height: max(96, artSize))
                  .frame(maxWidth: .infinity)
                  .accessibilityIdentifier("player-artwork")
                VStack(spacing: 12) {
                  HStack(alignment: .top, spacing: 8) {
                    PlayerIdentity(
                      track: content.album, related: related == nil ? nil : open, isCurrent: current
                    )
                    MusicFavoriteAction(
                      content: content, identifier: "player-favorite", isCurrent: current)
                  }
                  if let error = content.favoriteError {
                    Text(error).font(MusicType.notice).foregroundStyle(.secondary)
                  }
                  PlayerProgress(
                    store: store, occurrence: presentation.entry.id, isCurrent: current
                  )
                  .id(presentation.revision)
                  PlayerTransport(store: store, isCurrent: current)
                  PlayerPreparationStatus(store: store, isCurrent: current)
                  PlayerUtilities(store: store, presentation: presentation)
                }.frame(maxWidth: .infinity)
              }
              .frame(minHeight: max(0, geometry.size.height - 2 * contentInset), alignment: .top)
              PlayerArtistShelf(
                store: store, presentation: presentation, open: related == nil ? nil : open
              )
              .padding(.top, 12)
              PlayerQueuePreview(store: store, isCurrent: current)
            }.id(presentation.revision).padding(contentInset).frame(
              maxWidth: horizontal ? 900 : 540
            )
            .frame(maxWidth: .infinity)
          } else {
            MusicEmptyState(
              title: "Nothing queued", systemImage: "music.note",
              message: "Choose music to start listening."
            )
            .padding(24)
          }
        }.accessibilityIdentifier("player-scroll")
      }.toolbarBackground(.hidden, for: .navigationBar).navigationTitle("Now playing")
        .navigationBarTitleDisplayMode(.inline).toolbar {
          ToolbarItem(placement: .cancellationAction) {
            MusicSheetClose(
              title: "Close now playing", symbol: "chevron.down", identifier: "close-player")
          }.sharedBackgroundVisibility(.hidden)
          ToolbarItem(placement: .topBarTrailing) {
            if let presentation, presentation.isCurrent(store) {
              PlayerMore(store: store, presentation: presentation, related: related)
                .id(presentation.revision)
            }
          }.sharedBackgroundVisibility(.hidden)
        }.symbolEffectsRemoved(reduceMotion)
        .task(id: store.playerContentRevision) {
          let revision = store.playerContentRevision
          guard !Task.isCancelled, let entry = store.current,
            let origin = store.playbackOrigin(library: entry.libraryID),
            let content = store.playerContent(occurrence: entry.id)
          else {
            presentation = nil
            return
          }
          let value = PlayerPresentation(
            entry: entry, origin: origin, revision: revision, content: content)
          guard value.isCurrent(store) else { return }
          presentation = value
          await content.load()
          guard !Task.isCancelled, value.isCurrent(store) else { return }
          await content.loadRelatedAlbums()
        }
    }
    .presentationDetents([.large])
    .presentationContentInteraction(.resizes)
    .presentationDragIndicator(.visible)
    .presentationBackground {
      ZStack {
        MusicUI.canvas
        if let presentation, presentation.isCurrent(store) {
          MusicArtworkBackdrop(
            store: store, item: presentation.content.album, origin: presentation.origin)
        }
      }
    }
  }
}
private struct PlayerTransport: View {
  let store: PlayerStore
  let isCurrent: () -> Bool
  var body: some View {
    HStack(spacing: 0) {
      Button {
        guard isCurrent() else { return }
        store.toggleShuffle()
      } label: {
        MusicTransportSymbol(name: "shuffle", size: 18).frame(maxWidth: .infinity, minHeight: 44)
          .foregroundStyle(store.shuffleEnabled ? MusicUI.tint : .secondary)
      }.accessibilityLabel("Shuffle queue").accessibilityValue(store.shuffleEnabled ? "On" : "Off")
        .accessibilityIdentifier("player-shuffle")
      Button {
        guard isCurrent() else { return }
        store.previous()
      } label: {
        MusicTransportSymbol(name: "backward.end.fill").frame(maxWidth: .infinity, minHeight: 44)
      }.accessibilityLabel("Previous track").accessibilityIdentifier("player-previous")
      Button {
        guard isCurrent() else { return }
        store.toggle()
      } label: {
        MusicTransportSymbol(name: store.playbackRequested ? "pause.fill" : "play.fill", size: 24)
          .frame(width: 56, height: 56).foregroundStyle(MusicUI.onTint)
          .background(MusicUI.tint, in: .circle).frame(maxWidth: .infinity)
      }.accessibilityLabel(store.playbackRequested ? "Pause" : "Play")
        .accessibilityIdentifier("player-toggle")
      Button {
        guard isCurrent() else { return }
        store.next()
      } label: {
        MusicTransportSymbol(name: "forward.end.fill").frame(maxWidth: .infinity, minHeight: 44)
      }.accessibilityLabel("Next track").accessibilityIdentifier("player-next")
      Button {
        guard isCurrent() else { return }
        store.setRepeatMode(
          store.repeatMode == .off ? .all : store.repeatMode == .all ? .one : .off)
      } label: {
        MusicTransportSymbol(name: store.repeatMode == .one ? "repeat.1" : "repeat", size: 18)
          .frame(maxWidth: .infinity, minHeight: 44)
          .foregroundStyle(store.repeatMode == .off ? .secondary : MusicUI.tint)
      }.accessibilityLabel("Repeat").accessibilityValue(store.repeatMode.rawValue)
        .accessibilityIdentifier("player-repeat")
    }.foregroundStyle(.primary).buttonStyle(MusicButtonStyle(radius: 28))
  }
}
private struct PlayerPreparationStatus: View {
  let store: PlayerStore
  let isCurrent: () -> Bool
  var body: some View {
    if isCurrent(), store.phase == .failed {
      RetryNotice(message: "Playback stopped. Try this track again.") {
        guard isCurrent(), store.phase == .failed else { return }
        store.play()
      }.accessibilityIdentifier("player-playback-retry")
    } else {
      Text(store.phase.preparationMessage ?? PlayerPhase.preparing.accessibilityDescription)
        .font(MusicType.support).foregroundStyle(.secondary)
        .opacity(store.phase.preparationMessage == nil ? 0 : 1)
        .accessibilityHidden(store.phase.preparationMessage == nil)
        .accessibilityIdentifier("player-preparation-status")
    }
  }
}
private enum PlayerUtility: String, Identifiable {
  case route, quality, lyrics, queue
  var id: Self { self }
}
private struct PlayerUtilityLabel: View {
  let title: String
  let symbol: String
  var body: some View {
    VStack(spacing: 5) {
      Image(systemName: symbol).font(.system(size: 19)).frame(height: 28)
      Text(title).font(MusicType.support).fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, minHeight: 60).contentShape(.rect)
  }
}
private struct PlayerUtilities: View {
  let store: PlayerStore
  let presentation: PlayerPresentation
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showLyrics = false
  private var utilities: [PlayerUtility] {
    presentation.content.lyricsAvailable
      ? [.route, .quality, .lyrics, .queue] : [.route, .quality, .queue]
  }
  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(utilities) { utility in
        Group {
          switch utility {
          case .route:
            VStack(spacing: 0) {
              AudioOutputPicker().frame(width: 44, height: 44)
              Text("Route").font(MusicType.support)
            }.frame(maxWidth: .infinity, minHeight: 60)
              .accessibilityElement(children: .contain).accessibilityIdentifier("player-route")
          case .quality:
            QualityMenu(store: store, compact: true, isCurrent: { presentation.isCurrent(store) })
          case .lyrics:
            Button {
              guard presentation.isCurrent(store) else { return }
              showLyrics = true
            } label: {
              PlayerUtilityLabel(title: "Lyrics", symbol: "quote.bubble")
            }
            .accessibilityIdentifier("player-lyrics")
          case .queue:
            NavigationLink {
              if presentation.isCurrent(store) { QueueScreen(store: store) }
            } label: {
              PlayerUtilityLabel(title: "Queue", symbol: "list.bullet")
            }
            .accessibilityIdentifier("player-queue")
          }
        }.frame(maxWidth: .infinity).transition(.opacity)
      }
    }.buttonStyle(MusicButtonStyle()).foregroundStyle(.primary)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: utilities)
      .accessibilityElement(children: .contain).accessibilityIdentifier("player-utilities")
      .sheet(isPresented: $showLyrics) {
        PlayerLyricsSheet(store: store, presentation: presentation)
      }
  }
}
struct QualityMenu: View {
  let store: PlayerStore
  var compact = false
  var isCurrent: () -> Bool = { true }
  var body: some View {
    Menu {
      Picker(
        "Streaming quality",
        selection: Binding(
          get: { store.queue.quality },
          set: {
            guard isCurrent() else { return }
            store.quality($0)
          })
      ) { ForEach(StreamQuality.allCases) { Text($0.title).tag($0) } }
    } label: {
      if compact {
        PlayerUtilityLabel(title: "Quality", symbol: "waveform.path")
      } else {
        HStack(spacing: 6) {
          Label(store.queue.quality.title, systemImage: "waveform.path")
          Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }.font(MusicType.control).frame(minHeight: 44).padding(.horizontal, 10)
      }
    }.buttonStyle(MusicButtonStyle(radius: 8))
      .accessibilityLabel("Streaming quality: \(store.queue.quality.title)")
      .accessibilityIdentifier("player-quality")
  }
}
private struct PlayerArtistShelf: View {
  let store: PlayerStore
  let presentation: PlayerPresentation
  let open: ((MusicItem) -> Void)?
  var body: some View {
    let content = presentation.content
    if let artist = content.relatedArtist, !content.relatedAlbums.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        Text("More from " + artist.name).font(MusicType.section)
          .accessibilityIdentifier("player-artist-shelf-heading")
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: 12) {
            ForEach(content.relatedAlbums) { album in
              VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                  Button {
                    guard presentation.isCurrent(store) else { return }
                    open?(album)
                  } label: {
                    CatalogCover(store: store, item: album, origin: presentation.origin)
                  }
                  .buttonStyle(MusicButtonStyle()).disabled(open == nil)
                  .accessibilityLabel("Open " + album.title)
                  .accessibilityIdentifier("player-album-open-" + album.id)
                  AlbumPlaybackControl(
                    store: store, browser: nil, album: album,
                    acceptedOrigin: presentation.origin,
                    isCurrent: { presentation.isCurrent(store) }
                  )
                  .padding(6).accessibilityIdentifier("player-album-play-" + album.id)
                }.frame(width: 120, height: 120)
                Text(album.title).font(MusicType.secondary.weight(.medium)).lineLimit(2)
                  .frame(maxWidth: .infinity, alignment: .leading)
                if let year = album.details?.releaseYear(for: "MusicAlbum") {
                  Text(String(year)).font(MusicType.support).foregroundStyle(.secondary)
                }
              }.frame(width: 120).accessibilityElement(children: .contain)
            }
          }
        }.scrollIndicators(.hidden).accessibilityIdentifier("player-artist-albums")
      }
    }
  }
}
private struct PlayerQueuePreview: View {
  let store: PlayerStore
  let isCurrent: () -> Bool
  var body: some View {
    let upcoming = Array(store.queue.entries.dropFirst(store.queue.index + 1).prefix(2))
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Up next").font(MusicType.section)
        Spacer(minLength: 8)
        NavigationLink("View queue") {
          if isCurrent() { QueueScreen(store: store) }
        }.font(MusicType.control)
          .frame(minHeight: 44).accessibilityIdentifier("player-view-queue")
      }
      if store.repeatMode == .one {
        Text("Repeating this track").font(MusicType.notice).foregroundStyle(.secondary)
      } else if upcoming.isEmpty {
        Text(store.repeatMode == .all ? "The queue repeats at the end" : "End of queue")
          .font(MusicType.notice).foregroundStyle(.secondary)
      } else {
        ForEach(upcoming) { entry in
          Button {
            guard isCurrent() else { return }
            store.select(entry.id)
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "music.note").foregroundStyle(.secondary).frame(width: 24)
              MusicIdentityLabel(
                title: entry.track.title, subtitle: entry.track.artist,
                context: .occurrence(entry.id))
              MusicDurationLabel(seconds: entry.track.duration)
            }.frame(minHeight: 56).contentShape(.rect)
          }.buttonStyle(MusicButtonStyle()).accessibilityIdentifier(
            "player-up-next-" + entry.id.uuidString)
        }
      }
      if store.nextRequiresRetry {
        Button("Retry next track") {
          guard isCurrent() else { return }
          store.retryNext()
        }
        .font(MusicType.control).frame(minHeight: 44)
      }
    }.buttonStyle(MusicButtonStyle()).accessibilityIdentifier("player-queue-preview")
  }
}
private struct PlayerLyricsSheet: View {
  let store: PlayerStore
  let presentation: PlayerPresentation
  var body: some View {
    MusicInformationSheet(title: "Lyrics", closeID: "close-player-lyrics") {
      if presentation.isCurrent(store) {
        let content = presentation.content
        if content.lyricsLoading
          || (content.lyrics == nil && content.lyricsError == nil && content.lyricsAvailable)
        {
          ProgressView("Loading lyrics…").frame(minHeight: 80)
        } else if let lyrics = content.lyrics {
          PlayerLyricLines(
            store: store, lyrics: lyrics, isCurrent: { presentation.isCurrent(store) })
        } else if let error = content.lyricsError {
          RetryNotice(message: error) { Task { await content.loadLyrics() } }
        } else {
          Text("No lyrics available").font(MusicType.notice).foregroundStyle(.secondary)
        }
      }
    }.task {
      guard presentation.isCurrent(store) else { return }
      await presentation.content.loadLyrics()
    }
  }
}
private struct PlayerLyricLines: View {
  let store: PlayerStore
  let lyrics: MusicLyrics
  let isCurrent: () -> Bool
  var body: some View {
    let position = store.queue.position
    let active =
      lyrics.synchronized
      ? lyrics.lines.last(where: { ($0.seconds ?? .infinity) <= position })?.id : nil
    VStack(alignment: .leading, spacing: 18) {
      ForEach(lyrics.lines) { line in
        if lyrics.synchronized, let seconds = line.seconds {
          Button {
            guard isCurrent() else { return }
            store.seek(seconds)
          } label: {
            Text(line.text).font(MusicType.identity).foregroundStyle(
              active == line.id ? .primary : .secondary
            )
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
          }.accessibilityLabel("Seek to " + line.text)
            .accessibilityAddTraits(active == line.id ? [.isSelected] : [])
        } else {
          Text(line.text).font(MusicType.primary).textSelection(.enabled)
        }
      }
    }.buttonStyle(MusicButtonStyle()).accessibilityIdentifier("player-lyric-lines")
  }
}
private struct PlayerMore: View {
  @Environment(\.playlistPicker) private var playlistPicker
  let store: PlayerStore
  let presentation: PlayerPresentation
  let related: ((MusicItem, PlaybackOrigin) -> Void)?
  @State private var showInformation = false
  var body: some View {
    let current = { presentation.isCurrent(store) }
    Menu {
      Button("Track information", systemImage: "info.circle") {
        guard current() else { return }
        showInformation = true
      }
      Button("Add to playlist", systemImage: "music.note.list") {
        if current() {
          playlistPicker?.present(
            [presentation.entry.track], from: presentation.origin, store: store)
        }
      }
      Menu {
        ForEach([15, 30, 60], id: \.self) { minutes in
          Button("\(minutes) minutes") {
            guard current() else { return }
            store.setSleepTimer(minutes: minutes)
          }
        }
        Button("Off") {
          guard current() else { return }
          store.setSleepTimer(minutes: nil)
        }
      } label: {
        Label(
          store.sleepTimerDeadline.map {
            "Sleep timer · " + musicClockText(max(0, $0.timeIntervalSinceNow))
          } ?? "Sleep timer", systemImage: "moon.zzz")
      }
      if let related {
        Button("Go to album", systemImage: "opticaldisc") {
          guard current() else { return }
          related(presentation.content.album, presentation.origin)
        }
        ForEach(presentation.content.album.artistCredits ?? []) { credit in
          Button("Artist: " + credit.name) {
            guard current() else { return }
            related(credit.item, presentation.origin)
          }
        }
      }
    } label: {
      MusicUtilityLabel(title: "More player actions", symbol: "ellipsis", secondary: true)
    }
    .buttonStyle(MusicButtonStyle()).accessibilityIdentifier("player-more")
    .sheet(isPresented: $showInformation) {
      MusicInformationSheet(title: "Track information", closeID: "close-player-information") {
        if current() {
          let content = presentation.content
          MusicHeroTitle(text: content.album.title)
          Text("Original file").font(MusicType.control).foregroundStyle(.secondary)
          if content.trackInformationLoading {
            ProgressView().frame(minHeight: 80)
          } else if let info = content.trackInformation, info.hasContent {
            MusicMetadataContent(details: nil, kind: "Audio", facts: musicTechnicalFacts(info))
          } else if let error = content.trackInformationError {
            RetryNotice(message: error) {
              Task {
                guard !Task.isCancelled, current() else { return }
                await content.loadTrackInformation(id: presentation.entry.track.id)
              }
            }
          } else {
            Text("Jellyfin hasn’t supplied technical details for this track.").font(
              MusicType.notice)
          }
          MusicMetadataContent(details: content.album.details, kind: "Audio", isCurrent: current)
        }
      }.task {
        guard !Task.isCancelled, current() else { return }
        await presentation.content.loadTrackInformation(id: presentation.entry.track.id)
      }
    }
  }
}
private struct PlayerIdentity: View {
  let track: MusicItem?
  let related: ((MusicItem) -> Void)?
  let isCurrent: () -> Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let track, let related {
        Button {
          guard isCurrent() else { return }
          related(track)
        } label: {
          title.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
        }.buttonStyle(MusicButtonStyle()).accessibilityLabel(
          (track.albumID == nil ? "Find album for " : "Open album for ") + track.title
        ).accessibilityIdentifier("player-open-album")
        if let credits = track.artistCredits, !credits.isEmpty {
          ForEach(credits) { credit in
            Button {
              guard isCurrent() else { return }
              related(credit.item)
            } label: {
              MusicOverflowText(text: credit.name, context: .reading).font(MusicType.primary)
                .foregroundStyle(MusicUI.tint).frame(
                  maxWidth: .infinity, minHeight: 44, alignment: .leading
                ).contentShape(.rect)
            }.buttonStyle(MusicButtonStyle()).accessibilityLabel("Open artist " + credit.name)
              .accessibilityIdentifier("player-artist-" + credit.id)
          }
        } else if !track.artist.isEmpty {
          Button {
            guard isCurrent() else { return }
            related(
              MusicItem(
                id: "", title: track.artist, artist: track.artist, album: "", duration: 0,
                number: 0, kind: "MusicArtist", imageID: nil, imageTag: nil))
          } label: {
            MusicOverflowText(text: track.artist, context: .reading).font(MusicType.primary)
              .foregroundStyle(MusicUI.tint).frame(
                maxWidth: .infinity, minHeight: 44, alignment: .leading
              ).contentShape(.rect)
          }.buttonStyle(MusicButtonStyle()).accessibilityLabel("Find artist " + track.artist)
            .accessibilityIdentifier("player-find-artist")
        }
      } else {
        title
        MusicOverflowText(text: track?.artist ?? "", context: .reading).font(MusicType.primary)
          .foregroundStyle(.secondary)
      }
      if let album = track?.album, !album.isEmpty {
        Text(album).font(MusicType.support).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
            "player-album-context")
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private var title: some View {
    MusicHeroTitle(text: track?.title ?? "Nothing queued").foregroundStyle(.primary)
      .accessibilityIdentifier("player-title")
  }
}
