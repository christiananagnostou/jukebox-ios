import Foundation

enum CurrentItemRetention: Sendable { case retained, unbound, changed }
enum DriverEvent: Sendable {
  case position(UUID, Double)
  case seekCompleted(UUID, Double, request: UUID? = nil)
  case seekCancelled(UUID, request: UUID)
  case timeline(UUID, duration: Double?, seekableEnd: Double?)
  case sourceDuration(UUID, Double?)
  case advanced(UUID)
  case finished(UUID)
  case state(UUID, NativePlaybackActivity)
  case failure
  case failureDetails(UUID, ConnectionStepError)
}
struct PlaybackOrigin: Equatable, Sendable {
  let account: UUID
  let library: String
  let root: UUID
}
struct PlaybackSelection: Sendable {
  let items: [MusicItem]
  let origin: PlaybackOrigin
  var playlist: PlaylistContents.Source? = nil
}
struct PlaybackAuthority: Equatable, Sendable {
  let account: UUID
  let replacement: UUID
  let library: String
}
struct PlaybackReplacement: Sendable {
  let target: QueueEntry
  let authority: PlaybackAuthority
  let position: Double
  let artwork: Data?
  let diagnostic: DiagnosticContext?
  init(
    target: QueueEntry, authority: PlaybackAuthority, position: Double = 0, artwork: Data? = nil,
    diagnostic: DiagnosticContext? = nil
  ) {
    self.target = target
    self.authority = authority
    self.position = position
    self.artwork = artwork
    self.diagnostic = diagnostic
  }
}
struct PreparedEntry: Sendable {
  let entry: QueueEntry
  let source: MediaSource
  let authority: PlaybackAuthority?
  let artwork: Data?
  let diagnostic: DiagnosticContext?
  init(
    entry: QueueEntry, source: MediaSource, authority: PlaybackAuthority? = nil,
    artwork: Data? = nil, diagnostic: DiagnosticContext? = nil
  ) {
    self.entry = entry
    self.source = source
    self.authority = authority
    self.artwork = artwork
    self.diagnostic = diagnostic
  }
}
@MainActor protocol PlaybackDriving: AnyObject {
  var onEvent: (@MainActor (DriverEvent) -> Void)? { get set }
  func start(_ entries: [PreparedEntry], position: Double) async throws
  func append(
    _ entry: PreparedEntry, isCurrent: @MainActor @Sendable () -> Bool
  ) async throws
  func observeCurrent() -> Bool
  func retainCurrent(occurrence: UUID, keeping successor: UUID?) -> CurrentItemRetention
  func hasPrepared(_ occurrence: UUID) -> Bool
  func hasPending(_ occurrence: UUID) -> Bool
  func requiresSourceReplacementForSeek(occurrence: UUID, position: Double) -> Bool
  func hasCompleteLocalFile(occurrence: UUID) -> Bool
  func advancePrepared(to occurrence: UUID) -> Bool
  func prepareReplacement(_ replacement: PlaybackReplacement) -> Bool
  func renewRemoteIntent()
  func resume(id: UUID) -> Bool
  func pause()
  func stop()
  func seek(_ seconds: Double, request: UUID)
  func updateArtwork(_ data: Data?, occurrence: UUID)
}
extension PlaybackDriving {
  func hasCompleteLocalFile(occurrence: UUID) -> Bool { false }
  func requiresSourceReplacementForSeek(occurrence: UUID, position: Double) -> Bool { false }
  func seek(_ seconds: Double) { seek(seconds, request: UUID()) }
}
