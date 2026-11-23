import SwiftUI

struct AppRoot: View {
  let store: PlayerStore
  let fixture: FixtureCatalog
  var body: some View {
    Group {
      if store.active != nil, let browser = store.browser {
        BrowserShell(store: store, browser: browser)
      } else {
        LoginScreen(store: store, fixture: fixture)
      }
    }
    .tint(MusicUI.tint)
    .overlay(alignment: .top) {
      if let error = store.error {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.circle")
          VStack(alignment: .leading, spacing: 4) {
            Text(error).font(MusicType.notice)
            if let failure = store.lastPlaybackFailure {
              HStack {
                if store.current != nil { Button("Retry") { store.play() } }
                PlaybackFailureCopyButton(
                  store: store, failureID: failure.id,
                  accessibilityID: "copy-playback-diagnostics"
                )
              }.font(MusicType.secondary).buttonStyle(MusicButtonStyle())
            }
          }
          Spacer(minLength: 0)
          Button("Dismiss", systemImage: "xmark") { store.dismissError() }.labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.leading, 12).padding(.vertical, 8).background(
          MusicUI.panel, in: .rect(cornerRadius: 8)
        ).padding().accessibilityElement(children: .contain)
      }
    }
    .buttonStyle(MusicButtonStyle())
  }
}
