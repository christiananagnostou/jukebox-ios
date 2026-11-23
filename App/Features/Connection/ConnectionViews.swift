import SwiftUI

struct LoginScreen: View {
  @Bindable var store: PlayerStore
  let fixture: FixtureCatalog
  @State private var address = ""
  @State private var username = ""
  @State private var password = ""
  @State private var selectedConnection: Connection?
  private var server: ServerAddress? { try? ServerAddress(address) }
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("Your music. Your server.").font(MusicType.section).padding(.vertical, 12)
          TextField("Server address", text: $address).keyboardType(.URL).textContentType(.URL)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          TextField("Username", text: $username).textContentType(.username)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          SecureField("Password", text: $password).textContentType(.password)
          Button {
            let secret = password
            password = ""
            Task { await store.signIn(address: address, username: username, password: secret) }
          } label: {
            HStack {
              Text(store.busy ? "Connecting…" : "Connect")
              Spacer()
              if store.busy { ProgressView() } else { Image(systemName: "arrow.right") }
            }
          }
          .disabled(
            store.busy || store.pendingSignOut != nil || address.isEmpty || username.isEmpty
              || server?.url.scheme == "http")
        } footer: {
          Text(
            "Sign in with your Jellyfin HTTPS address. For Tailscale, use the HTTPS address for your server."
          )
        }
        if !store.connections.isEmpty {
          Section("Saved accounts") {
            ForEach(store.connections) { connection in
              HStack {
                Button {
                  if connection.server.url.scheme == "http" {
                    address = connection.server.url.absoluteString
                    username = connection.username
                  } else {
                    Task { await store.activate(connection) }
                  }
                } label: {
                  Label(connection.username, systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                Button {
                  selectedConnection = connection
                } label: {
                  Image(systemName: "info.circle")
                    .frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                }
                .accessibilityLabel("Connection details for \(connection.username)")
              }.buttonStyle(.borderless)
            }
          }
        }
        if store.pendingSignOut != nil {
          Button("Retry sign-out") { Task { await store.finishSignOut() } }.disabled(store.busy)
        }
        Section {
          Button("Try invented music") { Task { await store.enterFixture(service: fixture) } }
            .disabled(store.busy)
        } footer: {
          Text("Browse invented albums, artists and songs without connecting a server.")
        }
      }.modifier(MusicFormSurface()).navigationTitle("Connect").navigationBarTitleDisplayMode(
        .inline)
    }.sheet(item: $selectedConnection) { connection in
      ConnectionDetails(store: store, connection: connection)
    }
  }
}
struct ConnectionDetails: View {
  @Bindable var store: PlayerStore
  let connection: Connection
  @Environment(\.dismiss) private var dismiss
  #if DEBUG
    @State private var captureState = TransportCapture.State.idle
    @State private var captureNotice = ""
    @Environment(\.scenePhase) private var capturePhase
  #endif
  var body: some View {
    NavigationStack {
      Form {
        Section("Username") {
          Text(connection.username).accessibilityIdentifier("connection-username")
        }
        Section {
          Text(connection.server.url.absoluteString).font(MusicType.primary.monospaced())
            .textSelection(.enabled).accessibilityIdentifier("connection-server-address")
          Button("Copy server address", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = connection.server.url.absoluteString
          }
        } header: {
          Text("Server address")
        }
        Section("App build") {
          Text(
            Bundle.main.object(forInfoDictionaryKey: "JukeboxBuildMarker") as? String ?? "Unknown"
          )
          .font(MusicType.secondary.monospaced())
          .accessibilityIdentifier("app-build-marker")
        }
        if store.active?.id == connection.id, let failure = store.lastPlaybackFailure {
          Section("Latest playback failure") {
            Text(failure.detail.step.rawValue)
            PlaybackFailureCopyButton(
              store: store, failureID: failure.id,
              accessibilityID: "copy-latest-playback-diagnostics"
            )
          }
        }
        #if DEBUG
          if store.active?.id == connection.id {
            Section {
              Text("State: " + captureState.rawValue).accessibilityIdentifier("transport-state")
              Button("Start capture") {
                TransportCapture.shared.start(policyBits: TransportCapture.bundledPolicyBits())
                captureState = .recording
                captureNotice = ""
              }.accessibilityIdentifier("transport-start")
              Button("Copy request capture") {
                let capture = TransportCapture.shared
                if let snapshot = capture.export() {
                  capture.withCurrentExport(snapshot) {
                    UIPasteboard.general.string = snapshot.text
                    captureNotice = "Copied numeric diagnostics."
                  }
                }
                captureState = capture.currentState()
              }.disabled(captureState == .idle || captureState == .expired)
                .accessibilityIdentifier("transport-copy")
              Button("Stop and Clear", role: .destructive) {
                TransportCapture.shared.clear()
                captureState = .idle
                captureNotice = "Capture cleared."
              }.accessibilityIdentifier("transport-clear")
              if !captureNotice.isEmpty { Text(captureNotice) }
            } header: {
              Text("Debug track preparation capture")
            } footer: {
              Text(
                "Start, reproduce a track start or switch, then return here and Copy before Stop and Clear. Captures current/successor preparation only, not general browsing or sign-in. Memory only: up to 32 completed requests and 90 seconds. No addresses, accounts, music identities, credentials or response contents. Starting makes no request. Account or Music-library changes clear the capture; expiry discards it."
              )
            }
            .onAppear { captureState = TransportCapture.shared.currentState() }
            .onChange(of: capturePhase) { _, phase in
              if phase == .active { captureState = TransportCapture.shared.currentState() }
            }
          }
        #endif
      }.modifier(MusicFormSurface())
        .navigationTitle("Connection")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    .presentationDragIndicator(.visible)
  }
}
