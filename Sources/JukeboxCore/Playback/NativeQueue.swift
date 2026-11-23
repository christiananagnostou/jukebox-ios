import AVFoundation

extension AVQueuePlayer {
  @MainActor func retainFuture(
    after current: AVPlayerItem, keeping keep: (AVPlayerItem) -> Bool,
    didRemove: (AVPlayerItem) -> Void
  ) -> Bool {
    for item in items().reversed() where item !== current {
      guard currentItem === current, currentItem !== item else { return false }
      if keep(item) { continue }
      remove(item)
      guard currentItem === current else { return false }
      didRemove(item)
    }
    return currentItem === current
  }
}
