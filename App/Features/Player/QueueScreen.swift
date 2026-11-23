import SwiftUI

struct QueueScreen: View {
  @Environment(\.playlistPicker) private var playlistPicker
  @Bindable var store: PlayerStore
  var standalone = false
  var body: some View {
    List {
      if store.nextRequiresRetry {
        Section {
          Text("The next track couldn’t prepare. Your current track can keep playing.")
            .font(MusicType.notice).foregroundStyle(.secondary)
          Button("Retry next track") { store.retryNext() }
        }
      }

      if store.queue.entries.isEmpty {
        MusicEmptyState(
          title: "The queue is open", systemImage: "list.bullet",
          message: "Play an album or add a track to begin.")
      }
      ForEach(store.queue.entries) { entry in
        Button {
          store.select(entry.id)
        } label: {
          HStack(spacing: 12) {
            Image(
              systemName: entry.id == store.current?.id
                ? (store.playbackRequested ? "waveform" : "pause.fill") : "music.note"
            )
            .frame(width: 24).foregroundStyle(
              entry.id == store.current?.id ? MusicUI.tint : .secondary)
            MusicIdentityLabel(
              title: entry.track.title, subtitle: entry.track.artist,
              current: entry.id == store.current?.id, context: .occurrence(entry.id))
            MusicDurationLabel(seconds: entry.track.duration)
          }.frame(minHeight: 56).padding(.horizontal, 8)
            .background(
              entry.id == store.current?.id ? MusicUI.quiet : .clear,
              in: .rect(cornerRadius: 8)
            ).contentShape(.rect)
        }.buttonStyle(MusicButtonStyle(radius: 8))
          .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
          .listRowBackground(MusicUI.canvas).listRowSeparator(.hidden)
          .accessibilityValue(
            entry.id == store.current?.id ? store.phase.accessibilityDescription : "Queued")
      }.onDelete { offsets in store.remove(Set(offsets.map { store.queue.entries[$0].id })) }.onMove
      { offsets, destination in
        if let first = offsets.first { store.move(from: first, to: destination) }
      }
    }.accessibilityIdentifier("queue-list").listStyle(.plain)
      .scrollContentBackground(.hidden).background(MusicUI.canvas)
      .toolbarBackground(MusicUI.canvas, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar).navigationTitle("Queue")
      .navigationBarTitleDisplayMode(.inline).toolbar {
        if standalone {
          ToolbarItem(placement: .cancellationAction) {
            MusicSheetClose(title: "Close queue", symbol: "xmark", identifier: "close-queue")
          }.sharedBackgroundVisibility(.hidden)
        }
        if let library = store.queue.entries.first?.libraryID,
          store.queue.entries.allSatisfy({ $0.libraryID == library })
        {
          ToolbarItem(placement: .secondaryAction) {
            Button("Save to playlist", systemImage: "music.note.list") {
              playlistPicker?.present(
                store.queue.entries.map(\.track), from: store.playbackOrigin(library: library),
                store: store)
            }
          }
        }
        ToolbarItem(placement: .primaryAction) {
          EditButton().font(MusicType.control).frame(minWidth: 44, minHeight: 44)
            .buttonStyle(MusicButtonStyle())
        }.sharedBackgroundVisibility(.hidden)
      }
  }
}
