import SwiftUI

enum AccountSheet: Hashable, Identifiable {
  case details(Connection)
  case quickConnect(Connection)

  var id: Self { self }
  var account: Connection {
    switch self {
    case .details(let account), .quickConnect(let account): account
    }
  }
}

struct QuickConnectSignIn: View {
  let store: PlayerStore
  let server: ServerAddress
  @State private var attempt = UUID()
  @State private var phase = Phase.starting

  private enum Phase {
    case starting
    case waiting(QuickConnectCode)
    case failed(String)
  }

  var body: some View {
    Form {
      Section {
        switch phase {
        case .starting:
          ProgressView("Getting a sign-in code…")
        case .waiting(let code):
          VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "\(code.digits.prefix(3)) \(code.digits.suffix(3))")
              .font(.largeTitle.weight(.semibold).monospacedDigit())
              .accessibilityLabel("Sign-in code")
              .accessibilityValue(code.digits.map(String.init).joined(separator: " "))
              .accessibilityIdentifier("quick-connect-code").privacySensitive()
            Label("Waiting for approval", systemImage: "clock")
              .font(.subheadline).foregroundStyle(.secondary)
          }.padding(.vertical, 4)
        case .failed(let message):
          Label(message, systemImage: "exclamationmark.circle")
          Button("Get a new code", systemImage: "arrow.clockwise") {
            phase = .starting
            attempt = UUID()
          }
        }
      } header: {
        Text("Sign in to Jukebox")
      } footer: {
        Text(
          "On a device signed in to this Jellyfin server, open Quick Connect and enter the six-digit code shown here."
        )
      }
      Section("Server") { Text(server.url.absoluteString) }
    }
    .modifier(MusicFormSurface())
    .navigationTitle("Quick Connect").navigationBarTitleDisplayMode(.inline)
    .task(id: attempt) {
      let current = attempt
      do {
        try await store.signInWithQuickConnect(server: server) { code in
          if !Task.isCancelled, current == attempt { phase = .waiting(code) }
        }
      } catch {
        if !Task.isCancelled, current == attempt {
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
      Form {
        if phase == .approved {
          Section {
            Label("Device approved", systemImage: "checkmark.circle.fill").font(.headline)
              .accessibilityIdentifier("quick-connect-approved")
            Text("Finish signing in on the other device.")
          }
        } else {
          Section {
            TextField("Six-digit code", text: $input)
              .keyboardType(.numberPad).textContentType(.oneTimeCode).focused($editing)
              .font(.title2.monospacedDigit()).disabled(submitting)
              .accessibilityIdentifier("quick-connect-input")
              .autocorrectionDisabled().privacySensitive()
              .onChange(of: input) { if case .failed = phase { phase = .entry } }
            if case .failed(let message) = phase {
              Label(message, systemImage: "exclamationmark.circle")
                .accessibilityIdentifier("quick-connect-approval-error")
            }
            Button {
              guard !submitting, let code = QuickConnectCode(input) else { return }
              editing = false
              phase = .submitting(code)
            } label: {
              if submitting {
                ProgressView("Approving…")
              } else {
                Label("Approve sign-in", systemImage: "checkmark")
              }
            }
            .disabled(submitting || QuickConnectCode(input) == nil)
          } header: {
            Text("Approve a device")
          } footer: {
            Text("Enter the code shown on the device you want to sign in to your account.")
          }
        }
        Section("Account") {
          LabeledContent("Username", value: account.username)
          LabeledContent("Server", value: account.server.url.absoluteString)
        }
      }
      .modifier(MusicFormSurface())
      .navigationTitle("Quick Connect").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
    .presentationDragIndicator(.visible)
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
