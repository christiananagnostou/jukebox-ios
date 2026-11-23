import Foundation

enum RemoteAction: Sendable {
  case play, pause, toggle, next, previous
  case seek(Double)
}
struct PlaybackRemoteReceipt: Equatable, Sendable {
  let intent: UUID
  let occurrence: UUID
  let authority: PlaybackAuthority?
  let revision: UUID
  static func sameListeningAuthority(_ first: PlaybackAuthority?, _ second: PlaybackAuthority?)
    -> Bool
  {
    first?.account == second?.account && first?.replacement == second?.replacement
  }
  func admits(_ producer: Self, for action: RemoteAction) -> Bool {
    guard producer.intent == intent, Self.sameListeningAuthority(producer.authority, authority)
    else {
      return false
    }
    switch action {
    case .pause: return true
    case .play, .toggle, .next, .previous, .seek:
      return producer.revision == revision && producer.occurrence == occurrence
    }
  }
}

extension PlayerStore {
  func handleRemote(_ action: RemoteAction) {
    switch action {
    case .play: play()
    case .pause: pause()
    case .toggle: toggle()
    case .next: next()
    case .previous: previous()
    case .seek(let seconds): seek(seconds)
    }
  }
}
