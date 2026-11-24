import SwiftUI

extension EnvironmentValues {
  @Entry var playlistPicker: PlaylistPicker? = nil
}

private struct PlaylistAddition: Identifiable {
  let id = UUID()
  let tracks: [MusicItem]
  let origin: PlaybackOrigin
  let browser: MusicBrowser
  let scope: UUID
}

@MainActor @Observable final class PlaylistPicker {
  fileprivate var addition: PlaylistAddition?
  func present(_ tracks: [MusicItem], from origin: PlaybackOrigin?, store: PlayerStore) {
    guard let origin, store.playbackOrigin(library: origin.library) == origin, !tracks.isEmpty,
      let browser = store.browser?.playlistActionBrowser(library: origin.library)
    else { return }
    addition = PlaylistAddition(
      tracks: tracks, origin: origin, browser: browser, scope: browser.scope)
  }
}

private struct PlaylistActionPresenter: ViewModifier {
  let store: PlayerStore
  @State private var picker = PlaylistPicker()
  func body(content: Content) -> some View {
    @Bindable var picker = picker
    content.environment(\.playlistPicker, picker)
      .sheet(item: $picker.addition) { input in
        if store.playbackOrigin(library: input.origin.library) == input.origin,
          input.browser.metadataIsCurrent(scope: input.scope, library: input.origin.library)
        {
          PlaylistDestinationPicker(
            store: store, browser: input.browser, scope: input.scope, tracks: input.tracks,
            finished: { picker.addition = nil })
        }
      }
  }
}

extension View {
  func playlistActions(store: PlayerStore) -> some View {
    modifier(PlaylistActionPresenter(store: store))
  }
}

func playlistMessage(_ error: any Error) -> String {
  if let error = error as? PlaylistEditError { return error.localizedDescription }
  if let error = error as? ClientError { return error.localizedDescription }
  return "Couldn’t confirm the playlist update. Check the playlist before trying again."
}

private struct PlaylistDestinationPicker: View {
  let store: PlayerStore
  let browser: MusicBrowser
  let scope: UUID
  let tracks: [MusicItem]
  let finished: () -> Void
  @State private var savedWithNotice: PlaylistSave?
  @State private var busy = false
  @State private var error: String?
  var body: some View {
    NavigationStack {
      List {
        NavigationLink {
          PlaylistCreateForm(
            browser: browser, scope: scope, tracks: tracks, created: { _ in finished() })
        } label: {
          Label("New playlist", systemImage: "plus")
        }
        if let error {
          Text(error).foregroundStyle(.secondary).accessibilityIdentifier("playlist-add-error")
        }
        if let lists = browser.playlistIndex.items {
          ForEach(lists) { list in
            Button {
              guard !busy else { return }
              busy = true
              Task {
                defer { busy = false }
                do {
                  let state = try await browser.playlistEditor(list, scope: scope)
                  let saved = try await browser.changePlaylist(
                    .append(tracks), state: state, scope: scope)
                  if saved.notice == nil { finished() } else { savedWithNotice = saved }
                } catch { self.error = playlistMessage(error) }
              }
            } label: {
              HStack {
                PlaylistCover(store: store, playlist: list, library: browser.authorizedLibrary)
                  .frame(width: 44, height: 44)
                Text(list.title).foregroundStyle(.primary)
              }
            }.accessibilityIdentifier("playlist-destination-" + list.id)
          }
        } else if let message = browser.playlistIndex.error {
          RetryNotice(message: message) {
            Task { await browser.loadPlaylistIndex(scope: scope, refresh: true) }
          }
        } else {
          ProgressView("Loading playlists")
        }
      }.navigationTitle("Add to playlist")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: finished) }
        }
        .disabled(busy).interactiveDismissDisabled(busy)
        .task { await browser.loadPlaylistIndex(scope: scope) }
        .alert(item: $savedWithNotice) { saved in
          Alert(
            title: Text("Playlist updated"), message: Text(saved.notice ?? ""),
            dismissButton: .default(Text("Done"), action: finished))
        }
    }.presentationDragIndicator(.visible)
  }
}

struct PlaylistCreateForm: View {
  let browser: MusicBrowser
  let scope: UUID
  let tracks: [MusicItem]
  let source: MusicPlaylist?
  let created: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var error: String?
  @State private var savedWithNotice: PlaylistSave?
  @State private var busy = false
  @State private var creationUnknown = false

  init(
    browser: MusicBrowser, scope: UUID, tracks: [MusicItem] = [],
    copying source: MusicPlaylist? = nil, created: @escaping (String) -> Void
  ) {
    self.browser = browser
    self.scope = scope
    self.tracks = tracks
    self.source = source
    self.created = created
    let suffix = String(localized: " (Editable copy)")
    _name = State(
      initialValue: source.map { String($0.title.prefix(max(0, 128 - suffix.count))) + suffix }
        ?? "")
  }

  var body: some View {
    Form {
      Section {
        TextField("Playlist name", text: $name).accessibilityIdentifier("playlist-name")
      } footer: {
        if source != nil {
          Text(
            "Create a private playlist in your account with the songs in their saved order, including repeats."
          )
        } else {
          Text("Only you can see this playlist until you share it.")
        }
      }
      if let error {
        Text(error).foregroundStyle(.secondary).accessibilityIdentifier("playlist-create-error")
      }
      if busy && source != nil { ProgressView("Copying playlist…") }
    }.navigationTitle(source == nil ? "New playlist" : "Make an editable copy")
      .navigationBarTitleDisplayMode(.inline)
      .navigationBarBackButtonHidden(busy || source != nil)
      .toolbar {
        if source != nil {
          ToolbarItem(placement: .cancellationAction) {
            Button(creationUnknown ? "Done" : "Cancel") { dismiss() }.disabled(busy)
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(source == nil ? "Create" : "Create copy") {
            guard !busy, !creationUnknown else { return }
            busy = true
            Task {
              defer { busy = false }
              do {
                let mutation =
                  source.map { PlaylistMutation.copy($0, name: name) } ?? .create(name, tracks)
                let saved = try await browser.changePlaylist(
                  mutation, state: nil, scope: scope)
                guard browser.scope == scope, browser.metadataIsCurrent else { return }
                if saved.notice == nil { created(saved.id) } else { savedWithNotice = saved }
              } catch {
                guard browser.scope == scope, browser.metadataIsCurrent else { return }
                creationUnknown = error as? PlaylistEditError == .copyUnconfirmed
                self.error = playlistMessage(error)
              }
            }
          }.disabled(
            busy || creationUnknown || savedWithNotice != nil
              || (try? PlaylistMutation.name(name)) == nil
          )
          .accessibilityIdentifier("playlist-create-save")
        }
      }.disabled(busy).interactiveDismissDisabled(busy)
      .alert(item: $savedWithNotice) { saved in
        Alert(
          title: Text("Playlist created"), message: Text(saved.notice ?? ""),
          dismissButton: .default(Text("Done")) { created(saved.id) })
      }
  }
}
