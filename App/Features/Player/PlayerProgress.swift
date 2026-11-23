import SwiftUI

extension PlayerPhase {
  var accessibilityDescription: String {
    switch self {
    case .paused: "Paused"
    case .preparing: "Preparing playback…"
    case .playing: "Playing"
    case .waiting: "Buffering…"
    case .failed: "Playback stopped"
    }
  }
  var preparationMessage: String? {
    switch self {
    case .preparing, .waiting: accessibilityDescription
    case .paused, .playing, .failed: nil
    }
  }
}

struct PlayerProgress: View {
  let store: PlayerStore
  let occurrence: UUID
  let isCurrent: () -> Bool

  @State private var scrub = PlaybackScrub()

  var body: some View {
    let duration = store.playbackDuration.flatMap(musicTimeText)
    let elapsed = musicClockText(scrub.preview ?? store.playbackPosition)
    VStack(spacing: 6) {
      Slider(
        value: Binding(
          get: { min(scrub.preview ?? store.playbackPosition, store.seekUpperBound) },
          set: { position in
            guard isCurrent() else { return }
            if let target = scrub.change(to: position) { seek(target) }
          }), in: 0...store.seekUpperBound, onEditingChanged: editingChanged
      )
      .accessibilityLabel("Playback position")
      .accessibilityValue(duration.map { elapsed + " of " + $0 } ?? elapsed)
      .accessibilityAdjustableAction { direction in
        guard isCurrent() else { return }
        switch direction {
        case .increment: seek(store.playbackPosition + 10)
        case .decrement: seek(store.playbackPosition - 10)
        @unknown default: break
        }
      }
      HStack {
        Text(elapsed).accessibilityIdentifier("player-elapsed")
        Spacer()
        Text(duration ?? "—").accessibilityLabel(
          duration.map { store.durationAccessibilityLabel + ": " + $0 } ?? "Duration unavailable"
        ).accessibilityIdentifier("player-duration")
      }.font(MusicType.support.monospacedDigit()).foregroundStyle(.secondary)
    }
  }

  private func editingChanged(_ editing: Bool) {
    guard isCurrent() else { return }
    if editing {
      scrub.begin(at: store.playbackPosition)
    } else if let target = scrub.end() {
      seek(target)
    }
  }

  private func seek(_ position: Double) {
    guard isCurrent() else { return }
    store.seek(position, occurrence: occurrence)
  }
}
