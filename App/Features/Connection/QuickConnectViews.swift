import SwiftUI

enum AccountSheet: Hashable, Identifiable {
  case details(Connection)
  case quickConnect(Connection)

  var id: Self { self }
}

struct QuickConnectSignIn: View {
  let store: PlayerStore
  let server: ServerAddress
  let usePassword: (Bool) -> Void
  @State private var attempt = UUID()
  @State private var phase = Phase.starting

  private enum Phase {
    case starting
    case waiting(QuickConnectCode)
    case failed(String)
  }

  var body: some View {
    SignInPage("Use your other device") {
      switch phase {
      case .starting:
        ProgressView("Getting a sign-in code…")
      case .waiting(let code):
        Text(
          "In a browser already signed in to this Jellyfin server, open **Settings → Quick Connect** and enter this code."
        )
        .foregroundStyle(.secondary)
        VStack(spacing: 6) {
          Text("Sign-in code").font(.subheadline).foregroundStyle(.secondary)
          Text(verbatim: "\(code.digits.prefix(3)) \(code.digits.suffix(3))")
            .font(.largeTitle.weight(.semibold).monospacedDigit())
            .accessibilityLabel("Sign-in code")
            .accessibilityValue(code.digits.map(String.init).joined(separator: " "))
            .accessibilityIdentifier("quick-connect-code").privacySensitive()
          Label("Waiting for approval", systemImage: "clock").font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding().frame(maxWidth: .infinity)
        .background(MusicUI.panel, in: .rect(cornerRadius: 16))
        Text("Keep this screen open. Jukebox signs in automatically after approval.").signInHelp()
        DisclosureGroup("Approving from Jukebox?") {
          Text(
            "On the signed-in device, open Accounts → Quick Connect and enter this code."
          )
          .signInHelp()
        }
      case .failed(let message):
        Label(message, systemImage: "exclamationmark.circle")
        SignInActionRow(title: "Get a new code", symbol: "arrow.clockwise") {
          phase = .starting
          attempt = UUID()
        }
      }
      SignInActionRow(title: "Use my password instead") { usePassword(false) }
    }
    .task(id: attempt) {
      let current = attempt
      do {
        try await store.signInWithQuickConnect(server: server) { code in
          if !Task.isCancelled, current == attempt { phase = .waiting(code) }
        }
      } catch {
        guard !Task.isCancelled, current == attempt else { return }
        if error as? QuickConnectError == .disabled {
          usePassword(true)
        } else {
          phase = .failed(QuickConnectError.message(for: error))
        }
      }
    }
  }
}

struct QuickConnectApproval: View {
  let store: PlayerStore
  let account: Connection
  @Environment(\.dismiss) private var dismiss
  @FocusState private var editing: Bool
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var input = ""
  @State private var phase = Phase.entry

  private enum Phase: Equatable {
    case entry
    case submitting(QuickConnectCode)
    case approved
    case failed(String)
  }

  private var submitting: Bool {
    if case .submitting = phase { return true }
    return false
  }

  var body: some View {
    NavigationStack {
      SignInPage(phase == .approved ? "Device approved" : "Quick Connect") {
        if phase == .approved {
          Label(
            "Return to the other device to use your Jellyfin account.",
            systemImage: "checkmark.circle.fill"
          )
          .accessibilityIdentifier("quick-connect-approved")
        } else {
          Text("Enter the code shown on the device you want to sign in.").foregroundStyle(
            .secondary)
          Text(
            "Approving signs that device in as **\(account.username)** on \(account.server.url.absoluteString)."
          )
          .font(.footnote).accessibilityIdentifier("quick-connect-grant")
          VStack(alignment: .leading, spacing: 6) {
            Text("Code from the other device").font(.subheadline.weight(.semibold))
            let layout =
              typeSize.isAccessibilitySize
              ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
              : AnyLayout(HStackLayout(spacing: 8))
            layout {
              TextField("Six-digit code", text: $input, prompt: Text("000 000"))
                .keyboardType(.numberPad).textContentType(.oneTimeCode).focused($editing)
                .font(.title2.monospacedDigit())
                .signInField(focused: editing) { editing = true }.disabled(submitting)
                .accessibilityIdentifier("quick-connect-input").autocorrectionDisabled()
                .privacySensitive()
                .onChange(of: input) { if case .failed = phase { phase = .entry } }
              Button {
                guard !submitting, let code = QuickConnectCode(input) else { return }
                editing = false
                phase = .submitting(code)
              } label: {
                Text(submitting ? "Approving…" : "Approve")
                  .font(.headline).padding(.horizontal, 6)
                  .frame(minWidth: MusicUI.target, minHeight: SignInControl.height)
                  .contentShape(.rect)
              }
              .buttonStyle(MusicButtonStyle()).foregroundStyle(MusicUI.tint)
              .disabled(submitting || QuickConnectCode(input) == nil)
              .accessibilityIdentifier("quick-connect-submit")
            }
          }
          if case .failed(let message) = phase {
            Label(message, systemImage: "exclamationmark.circle")
              .accessibilityIdentifier("quick-connect-approval-error")
          }
        }
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.disabled(submitting)
        }
      }
    }
    .presentationDragIndicator(.visible).interactiveDismissDisabled(submitting)
    .task(id: phase) {
      guard case .submitting(let code) = phase else { return }
      do {
        try await store.approveQuickConnect(code, for: account)
        guard !Task.isCancelled else { return }
        input = ""
        phase = .approved
      } catch {
        if !Task.isCancelled { phase = .failed(QuickConnectError.message(for: error)) }
      }
    }
  }
}
