import MediaPlayer

@MainActor final class SystemPlaybackCommands {
  private struct Registration {
    let receipt: PlaybackRemoteReceipt
    let targets: [(MPRemoteCommand, Any)]
  }

  private var registration: Registration?
  var receipt: PlaybackRemoteReceipt? { registration?.receipt }

  func install(
    occurrence: UUID, authority: PlaybackAuthority?, revision: UUID, renewIntent: Bool,
    deliver: @escaping @MainActor @Sendable (RemoteAction, PlaybackRemoteReceipt) -> Void
  ) {
    let previous = receipt
    if !renewIntent, let previous, previous.occurrence == occurrence,
      previous.authority == authority, previous.revision == revision
    {
      return
    }
    let intent: UUID
    if !renewIntent, let previous,
      PlaybackRemoteReceipt.sameListeningAuthority(previous.authority, authority)
    {
      intent = previous.intent
    } else {
      intent = UUID()
    }
    let receipt = PlaybackRemoteReceipt(
      intent: intent, occurrence: occurrence, authority: authority, revision: revision)
    for (command, target) in registration?.targets ?? [] { command.removeTarget(target) }
    let center = MPRemoteCommandCenter.shared()
    var targets: [(MPRemoteCommand, Any)] = []
    func add(_ command: MPRemoteCommand, _ action: RemoteAction) {
      command.isEnabled = true
      let target = command.addTarget { _ in
        Task { @MainActor in deliver(action, receipt) }
        return .success
      }
      targets.append((command, target))
    }
    add(center.playCommand, .play)
    add(center.pauseCommand, .pause)
    add(center.togglePlayPauseCommand, .toggle)
    add(center.nextTrackCommand, .next)
    add(center.previousTrackCommand, .previous)
    let position = center.changePlaybackPositionCommand
    position.isEnabled = true
    let target = position.addTarget { event in
      guard let seconds = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime,
        seconds.isFinite
      else { return .commandFailed }
      Task { @MainActor in deliver(.seek(seconds), receipt) }
      return .success
    }
    targets.append((position, target))
    registration = Registration(receipt: receipt, targets: targets)
  }

  func clear() {
    guard let registered = registration else { return }
    registration = nil
    for (command, target) in registered.targets {
      command.isEnabled = false
      command.removeTarget(target)
    }
  }
}
