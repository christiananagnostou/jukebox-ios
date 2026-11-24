import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct ImportedPlaylistCover: Transferable {
  let jpeg: Data
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { file in
      guard
        let source = CGImageSourceCreateWithURL(
          file.file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
      else { throw ClientError.invalidResponse }
      return try Self(source: source)
    }
  }
  nonisolated init(source: CGImageSource) throws {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1024,
    ]
    let output = NSMutableData()
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
      let encoder = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw ClientError.invalidResponse }
    CGImageDestinationAddImage(
      encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
    guard CGImageDestinationFinalize(encoder), output.length <= 4_000_000 else {
      throw ClientError.invalidResponse
    }
    jpeg = output as Data
  }
  nonisolated static func fromArtwork(_ data: Data) async throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw ClientError.invalidResponse
    }
    return try Self(source: source).jpeg
  }
}

@MainActor @Observable private final class PlaylistEditorModel {
  let browser: MusicBrowser
  let scope: UUID
  let original: MusicPlaylist
  var state: PlaylistEditState?
  var contents: PlaylistContents?
  var busy = false
  var error: String?
  var readOnly = false
  var playlist: MusicPlaylist {
    browser.playlistIndex.items?.first { $0.id == original.id } ?? original
  }

  init(browser: MusicBrowser, scope: UUID, playlist: MusicPlaylist) {
    self.browser = browser
    self.scope = scope
    self.original = playlist
  }
  func load() async {
    do {
      let fresh = try await browser.playlistEditor(playlist, scope: scope)
      var songs = try await browser.playlistContents(playlist, scope: scope)
      if !songs.tracks.elementsEqual(fresh.entries, by: { playlistTrackKey($0.id) == $1.track }) {
        songs = try await browser.playlistContents(playlist, scope: scope, refresh: true)
      }
      guard songs.tracks.elementsEqual(fresh.entries, by: { playlistTrackKey($0.id) == $1.track })
      else { throw PlaylistEditError.changed }
      state = fresh
      contents = songs
      error = nil
      readOnly = false
    } catch {
      state = nil
      contents = nil
      self.error = playlistMessage(error)
      readOnly = error as? PlaylistEditError == .readOnly
    }
  }
  func save(_ change: PlaylistMutation) async -> Bool {
    guard let state, !busy, browser.scope == scope else { return false }
    busy = true
    defer { busy = false }
    do {
      let receipt = try await browser.changePlaylist(change, state: state, scope: scope)
      if case .delete = change { return true }
      if !change.changesTracks {
        error = nil
        return true
      }
      await load()
      if let notice = receipt.notice {
        error = notice
        return false
      }
      return self.state != nil
    } catch {
      let message = playlistMessage(error)
      await load()
      self.error = message
      return false
    }
  }
}

struct PlaylistEditorView: View {
  let store: PlayerStore
  let deleted: () -> Void
  let copied: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var model: PlaylistEditorModel
  @State private var name: String
  @State private var photo: PhotosPickerItem?
  @State private var importing = false
  @State private var deleteConfirmation = false
  @State private var removeCoverConfirmation = false
  init(
    store: PlayerStore, browser: MusicBrowser, scope: UUID, playlist: MusicPlaylist,
    deleted: @escaping () -> Void, copied: @escaping (String) -> Void
  ) {
    self.store = store
    self.deleted = deleted
    self.copied = copied
    _name = State(initialValue: playlist.title)
    _model = State(
      initialValue: PlaylistEditorModel(browser: browser, scope: scope, playlist: playlist))
  }
  var body: some View {
    NavigationStack {
      Form {
        if let state = model.state {
          Section("Name") {
            TextField("Playlist name", text: $name).accessibilityIdentifier("playlist-name")
            if name != model.playlist.title {
              Button("Save name") {
                Task { if await model.save(.rename(name)) { name = model.playlist.title } }
              }
              .disabled((try? PlaylistMutation.name(name)) == nil)
            }
          }
          Section("Cover") {
            HStack(spacing: 12) {
              PlaylistCover(
                store: store, playlist: model.playlist, library: model.browser.authorizedLibrary
              ).frame(width: 56, height: 56)
              PhotosPicker(selection: $photo, matching: .images) {
                Label("Choose photo", systemImage: "photo")
              }
              .accessibilityIdentifier("playlist-choose-cover")
            }
            if let first = model.contents?.tracks.first, first.imageID != nil {
              Button("Use first song’s artwork") { Task { await useArtwork(first) } }
                .accessibilityIdentifier("playlist-track-cover")
            }
            if model.playlist.primaryImageTag != nil {
              Button("Remove cover", role: .destructive) { removeCoverConfirmation = true }
            }
          }
          Section {
            NavigationLink {
              PlaylistSongSearch(model: model)
            } label: {
              Label("Add songs", systemImage: "plus")
            }
            .accessibilityIdentifier("playlist-add-songs")
            NavigationLink {
              PlaylistTrackEditor(model: model)
            } label: {
              Label("Edit song order", systemImage: "list.bullet")
            }
            .disabled(state.entries.isEmpty).accessibilityIdentifier("playlist-edit-order")
            if state.canShare {
              NavigationLink {
                PlaylistAccessView(model: model)
              } label: {
                Label("Sharing", systemImage: "person.2")
              }
              .accessibilityIdentifier("playlist-sharing")
            }
          }
          if state.canDelete {
            Section { Button("Delete playlist", role: .destructive) { deleteConfirmation = true } }
          }
        } else if model.error == nil {
          ProgressView("Loading playlist editor")
        }
        if model.readOnly {
          Section {
            Text("This playlist is read-only. You can edit a private copy in your account.")
            NavigationLink {
              PlaylistCreateForm(
                browser: model.browser, scope: model.scope, copying: model.playlist, created: copied
              )
            } label: {
              Label("Make an editable copy", systemImage: "plus.square.on.square")
            }.accessibilityIdentifier("playlist-readonly-copy")
          }
        } else if let error = model.error {
          RetryNotice(message: error) { Task { await model.load() } }
        }
      }.navigationTitle("Edit playlist").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }.accessibilityIdentifier("playlist-editor-done")
          }
        }
        .disabled(model.busy || importing)
        .confirmationDialog(
          "Delete “" + model.playlist.title + "”?", isPresented: $deleteConfirmation,
          titleVisibility: .visible
        ) {
          Button("Delete playlist", role: .destructive) {
            Task { if await model.save(.delete) { deleted() } }
          }.accessibilityIdentifier("playlist-confirm-delete")
        } message: {
          Text("This removes the playlist from Jellyfin. Your songs stay in the library.")
        }
        .confirmationDialog(
          "Remove the playlist cover?", isPresented: $removeCoverConfirmation,
          titleVisibility: .visible
        ) {
          Button("Remove cover", role: .destructive) { Task { _ = await model.save(.removeCover) } }
            .accessibilityIdentifier("playlist-confirm-remove-cover")
        }
    }.interactiveDismissDisabled(model.busy || importing).presentationDragIndicator(.visible)
      .task { await model.load() }
      .task(id: photo) {
        guard let photo else { return }
        importing = true
        defer { importing = false }
        do {
          guard let cover = try await photo.loadTransferable(type: ImportedPlaylistCover.self)
          else { throw ClientError.invalidResponse }
          try Task.checkCancellation()
          _ = await model.save(.cover(cover.jpeg))
        } catch {
          if !Task.isCancelled {
            model.error = "The photo couldn’t be imported. Choose another image."
          }
        }
        self.photo = nil
      }
  }
  private func useArtwork(_ track: MusicItem) async {
    guard !importing, let origin = store.playbackOrigin(library: model.browser.authorizedLibrary)
    else { return }
    importing = true
    defer { importing = false }
    await store.loadCover(track, origin: origin)
    do {
      guard let data = store.cover(track, origin: origin) else { throw ClientError.invalidResponse }
      let jpeg = try await ImportedPlaylistCover.fromArtwork(data)
      _ = await model.save(.cover(jpeg))
    } catch { model.error = "This song’s cover couldn’t be loaded." }
  }
}

private struct PlaylistTrackEditor: View {
  let model: PlaylistEditorModel
  @State private var removal: PlaylistContents.Row?
  var body: some View {
    List {
      if let error = model.error { Text(error).foregroundStyle(.secondary) }
      if let contents = model.contents, let state = model.state {
        ForEach(contents.rows) { row in
          let track = contents.tracks[row.index]
          let editable = state.entryID(at: row.index) != nil
          HStack {
            Text((row.index + 1).formatted()).font(.caption.monospacedDigit()).foregroundStyle(
              .secondary)
            VStack(alignment: .leading) {
              Text(track.title)
              Text(track.artist).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
              Button("Move up") { move(row.index, row.index - 1) }.disabled(
                !editable || !state.permitsMove(to: row.index - 1))
              Button("Move down") { move(row.index, row.index + 1) }.disabled(
                !editable || !state.permitsMove(to: row.index + 1))
              Button("Remove song", role: .destructive) { removal = row }.disabled(!editable)
              if !editable { Text("Jellyfin can’t distinguish this entry.") }
            } label: {
              Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Actions for song " + String(row.index + 1))
            .accessibilityIdentifier("playlist-entry-" + String(row.index + 1))
          }.moveDisabled(!editable)
        }.onMove { offsets, to in
          guard offsets.count == 1, let from = offsets.first else { return }
          move(from, to > from ? to - 1 : to)
        }
      }
    }.navigationTitle("Song order").toolbar { EditButton() }.disabled(model.busy)
      .confirmationDialog(
        "Remove this copy from the playlist?",
        isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
        titleVisibility: .visible, presenting: removal
      ) { row in
        Button("Remove song", role: .destructive) {
          Task { _ = await model.save(.remove(row.index)) }
        }
      }
  }
  private func move(_ from: Int, _ to: Int) { Task { _ = await model.save(.move(from, to)) } }
}

private struct PlaylistSongSearch: View {
  let model: PlaylistEditorModel
  @State private var query = ""
  @State private var songs: [MusicItem] = []
  @State private var offset = 0
  @State private var hasMore = false
  @State private var error: String?
  @State private var loading = false
  @State private var added: [String: Int] = [:]
  var body: some View {
    List {
      if let message = error ?? model.error { Text(message).foregroundStyle(.secondary) }
      ForEach(songs) { song in
        Button {
          Task { if await model.save(.append([song])) { added[song.id, default: 0] += 1 } }
        } label: {
          HStack {
            MusicIdentityLabel(title: song.title, subtitle: song.artist, context: .track(song.id))
            Spacer()
            if added[song.id] != nil { Image(systemName: "checkmark").accessibilityHidden(true) }
            Image(systemName: "plus")
          }
        }.disabled(model.busy).accessibilityValue(
          added[song.id].map { "Added " + String($0) } ?? ""
        )
        .accessibilityIdentifier(
          "playlist-add-" + song.id)
      }
      if !loading, songs.isEmpty, error == nil {
        Text("No matching songs").foregroundStyle(.secondary)
      }
      if loading { ProgressView("Loading songs") }
      if hasMore && !loading { Button("More songs") { offset += 40 } }
    }.navigationTitle("Add songs").searchable(text: $query, prompt: "Search this library")
      .task(id: query) {
        offset = 0
        songs = []
        hasMore = false
        await load(at: 0)
      }
      .onChange(of: offset) { _, value in if value > 0 { Task { await load(at: value) } } }
  }
  private func load(at start: Int) async {
    let requested = query
    loading = true
    do {
      if !requested.isEmpty && start == 0 { try await Task.sleep(for: .milliseconds(220)) }
      let page = try await model.browser.playlistSongSearch(
        requested, offset: start, scope: model.scope)
      guard !Task.isCancelled, query == requested, offset == start else { return }
      if start == 0 { songs = page.items } else { songs += page.items }
      hasMore = page.rawCount == 40
      error = nil
    } catch {
      guard !Task.isCancelled, query == requested, offset == start else { return }
      self.error = "Couldn’t load songs."
    }
    loading = false
  }
}

private struct PlaylistAccessView: View {
  let model: PlaylistEditorModel
  @State private var sharing: PlaylistSharing?
  @State private var error: String?
  var body: some View {
    Form {
      if let sharing {
        Section {
          Toggle(
            "Public playlist",
            isOn: Binding(get: { sharing.isPublic }, set: { change(.visibility($0)) })
          )
          .accessibilityIdentifier("playlist-public")
        } footer: {
          Text("Public playlists are visible to everyone on this Jellyfin server.")
        }
        Section("People") {
          ForEach(sharing.people) { person in
            Menu {
              Button(sharing.isPublic ? "Use public access" : "No access") {
                change(.share(person.id, nil))
              }
              Button("Can view") { change(.share(person.id, false)) }
              Button("Can edit") { change(.share(person.id, true)) }
            } label: {
              LabeledContent(
                person.name,
                value: person.canEdit.map { $0 ? "Can edit" : "Can view" }
                  ?? (sharing.isPublic ? "Public access" : "No access"))
            }.accessibilityIdentifier("playlist-person-" + person.id)
          }
          if sharing.people.isEmpty {
            Text("No other visible accounts").foregroundStyle(.secondary)
          }
        }
      } else if error == nil {
        ProgressView("Loading sharing")
      }
      if let message = error ?? model.error {
        RetryNotice(message: message) { Task { await load() } }
      }
    }.navigationTitle("Sharing").disabled(model.busy).task { await load() }
  }
  private func change(_ change: PlaylistMutation) {
    Task { if await model.save(change) { await load() } }
  }
  private func load() async {
    do {
      sharing = try await model.browser.playlistSharing(model.playlist, scope: model.scope)
      error = nil
    } catch {
      self.error = playlistMessage(error)
      sharing = nil
    }
  }
}
