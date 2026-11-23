import SwiftUI

struct PlaybackFailureCopyButton: View {
  let store: PlayerStore
  let failureID: UUID
  let accessibilityID: String

  var body: some View {
    Button("Copy playback failure") {
      let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
      let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
      guard
        let report = store.playbackFailureReport(
          id: failureID, appVersion: "\(version)(\(build))")
      else { return }
      UIPasteboard.general.string = report
    }.accessibilityIdentifier(accessibilityID)
  }
}
