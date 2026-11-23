import AVFoundation
import Foundation

actor MusicAudioSession {
  private var owner: UUID?
  func activate(owner: UUID) throws {
    try Task.checkCancellation()
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
    guard session.routeSharingPolicy == .longFormAudio else {
      throw PlaybackProblem.audioSessionPolicy
    }
    try session.setActive(true)
    self.owner = owner
    guard session.routeSharingPolicy == .longFormAudio else {
      throw PlaybackProblem.audioSessionPolicy
    }
  }
  func deactivate(owner: UUID) {
    guard self.owner == owner else { return }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    self.owner = nil
  }
}
