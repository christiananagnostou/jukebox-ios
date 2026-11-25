import SwiftUI

struct AppRoot: View {
  let store: PlayerStore
  let fixture: FixtureCatalog
  private var bannerError: String? {
    if case .ending = store.session { return nil }
    return store.error
  }
  var body: some View {
    Group {
      switch store.session {
      case .opening, .reconnecting:
        ZStack {
          MusicUI.canvas.ignoresSafeArea()
          ProgressView("Opening your music…")
            .accessibilityIdentifier("account-opening")
        }
      case .ending:
        if store.busy {
          ProgressView("Signing out…").frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MusicUI.canvas)
        } else {
          ContentUnavailableView {
            Label("Finish signing out", systemImage: "person.crop.circle")
          } description: {
            Text("Retry to finish removing this sign-in from your device.")
          } actions: {
            Button("Retry sign-out") { Task { await store.finishSignOut() } }
          }
        }
      case .recovery(let recovery):
        AccountRecoveryScreen(store: store, reason: recovery)
      case .signedOut(let suggested):
        LoginScreen(store: store, fixture: fixture, suggested: suggested)
      case .signedIn(_, let browser):
        BrowserShell(store: store, browser: browser).id(ObjectIdentifier(browser))
      }
    }
    .tint(MusicUI.tint)
    .overlay(alignment: .top) {
      if let error = bannerError {
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

private struct AccountRecoveryScreen: View {
  let store: PlayerStore
  let reason: AccountRecovery

  var body: some View {
    NavigationStack {
      switch reason {
      case .savedAccounts:
        SignInPage("Couldn’t open saved accounts") {
          Text("Try again to open the accounts saved on this device.").foregroundStyle(.secondary)
          action("Try again")
        }
      case .reconnect(let account, let problem):
        SignInPage("Couldn’t reconnect") {
          accountLabel(account)
          Text(verbatim: problem.reason).foregroundStyle(.secondary)
          action("Try again")
          otherAccount
        }
      case .expired(let account):
        SignInPage("Sign in again") {
          accountLabel(account)
          Text("Jukebox needs a new sign-in for this account.").foregroundStyle(.secondary)
          action("Continue to sign-in")
          otherAccount
        }
      case .requiresHTTPS(let account):
        SignInPage("Update your server address") {
          accountLabel(account)
          Text("Enter this server’s HTTPS address to reconnect.").foregroundStyle(.secondary)
          action("Edit address")
          otherAccount
        }
      }
    }
  }

  private func accountLabel(_ account: Connection) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: account.username).font(.headline)
      Text(verbatim: account.server.url.absoluteString).font(.subheadline).foregroundStyle(
        .secondary)
    }.accessibilityElement(children: .combine).privacySensitive()
  }

  private func action(_ title: LocalizedStringKey) -> some View {
    Button(title) { Task { await store.retryAccountStartup() } }
      .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.busy)
  }

  private var otherAccount: some View {
    Button("Use another account") { store.addConnection() }.frame(minHeight: MusicUI.target)
  }
}
