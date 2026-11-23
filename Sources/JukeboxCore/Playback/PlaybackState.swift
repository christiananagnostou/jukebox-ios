import Foundation

enum PlayerPhase: String, Sendable {
  case paused, preparing, playing, waiting, failed

  var requestsPlayback: Bool {
    switch self {
    case .preparing, .playing, .waiting: true
    case .paused, .failed: false
    }
  }
}
enum NativePlaybackActivity: Sendable { case playing, waiting }

enum PlaybackPreparation {
  struct AlbumRequest {
    let id = UUID()
    let origin: PlaybackOrigin
    let albumID: String
    let diagnostic: DiagnosticContext?
  }

  case idle
  case album(AlbumRequest, Task<Void, Never>)
  case source(Task<Void, Never>, deadline: Task<Void, Never>)
  case nativeStart(Task<Void, Never>)

  var pendingAlbum: AlbumRequest? {
    if case .album(let request, _) = self { request } else { nil }
  }
  var task: Task<Void, Never>? {
    switch self {
    case .idle: nil
    case .album(_, let task), .source(let task, _), .nativeStart(let task): task
    }
  }
  mutating func handOffToNative() -> Bool {
    guard case .source(let task, let deadline) = self else { return false }
    deadline.cancel()
    self = .nativeStart(task)
    return true
  }
  mutating func finish() {
    if case .source(_, let deadline) = self { deadline.cancel() }
    self = .idle
  }
  mutating func cancel() {
    task?.cancel()
    finish()
  }
}

@MainActor final class PlaybackAudioSessionState {
  private enum Phase: Equatable {
    case inactive
    case activating(UUID)
    case active(UUID)
    case interruptedDuringActivation(UUID)
  }
  private var phase = Phase.inactive

  var isActive: Bool {
    if case .active = phase { true } else { false }
  }
  func activate(
    _ request: UUID, using activateHardware: () async throws -> Void,
    replacingExpiredPlayer: () -> Void
  ) async throws {
    phase = .activating(request)
    var replacedPlayer = false
    while true {
      try requireCurrentActivation(request)
      do {
        try await activateHardware()
      } catch {
        try requireCurrentActivation(request)
        let failure = ConnectionStepError(step: .audioSession, error: error)
        guard !replacedPlayer, failure.step == .audioSession,
          failure.category == .expiredAudioSession
        else { throw error }
        replacingExpiredPlayer()
        replacedPlayer = true
        continue
      }
      try requireCurrentActivation(request)
      phase = .active(request)
      return
    }
  }
  private func requireCurrentActivation(_ request: UUID) throws {
    guard phase == .activating(request), !Task.isCancelled else { throw CancellationError() }
  }
  func interrupt() -> Bool {
    switch phase {
    case .activating(let owner):
      phase = .interruptedDuringActivation(owner)
      return true
    case .active:
      phase = .inactive
      return true
    case .interruptedDuringActivation, .inactive: return false
    }
  }
  func retire() -> UUID? {
    defer { phase = .inactive }
    switch phase {
    case .activating(let owner), .active(let owner), .interruptedDuringActivation(let owner):
      return owner
    case .inactive: return nil
    }
  }
}

struct SuccessorPreparation {
  enum Phase {
    case loading(Task<Void, Never>)
    case awaitingTurn
    case failed
  }

  let id: UUID
  let occurrence: UUID
  let diagnostic: DiagnosticContext?
  var phase: Phase

  var task: Task<Void, Never>? {
    if case .loading(let task) = phase { task } else { nil }
  }
}

struct PlaybackScrub {
  private struct Drag {
    let start: Double
    var position: Double
  }
  private var drag: Drag?
  var preview: Double? { drag?.position }

  mutating func begin(at position: Double) {
    guard drag == nil else { return }
    drag = Drag(start: position, position: position)
  }
  mutating func change(to position: Double) -> Double? {
    guard drag != nil else { return position }
    drag?.position = position
    return nil
  }
  mutating func end() -> Double? {
    defer { drag = nil }
    guard let drag, drag.position != drag.start else { return nil }
    return drag.position
  }
}
