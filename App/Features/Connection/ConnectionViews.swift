import SwiftUI

private enum SignInDestination: Hashable {
  case methods(ServerAddress)
  case password(ServerAddress, codesDisabled: Bool)
  case code(ServerAddress)
}

struct LoginScreen: View {
  @Bindable var store: PlayerStore
  let fixture: FixtureCatalog
  @State private var address = ""
  @State private var username = ""
  @State private var checking: ServerAddress?
  @State private var problem: String?
  @State private var path: [SignInDestination] = []
  @State private var selectedConnection: Connection?
  @FocusState private var editingAddress: Bool

  private var server: ServerAddress? { try? ServerAddress(address) }
  private var mayContinue: Bool {
    server?.url.scheme == "https" && checking == nil && !store.busy && store.pendingSignOut == nil
  }

  var body: some View {
    NavigationStack(path: $path) {
      SignInPage("Connect to Jellyfin") {
        Text("Your music and account live on your Jellyfin server. Enter its address to connect.")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 8) {
          Text("Server address").font(.subheadline.weight(.semibold))
          HStack(spacing: 4) {
            TextField("Server address", text: $address, prompt: Text("https://music.example.org"))
              .textContentType(.URL).keyboardType(.URL).autocorrectionDisabled()
              .textInputAutocapitalization(.never).focused($editingAddress)
              .submitLabel(.continue).onSubmit(beginCheck)
              .signInField(focused: editingAddress) { editingAddress = true }
              .accessibilityIdentifier("sign-in-server")
            SignInForward(
              title: checking == nil ? "Continue" : "Checking server…", busy: checking != nil,
              action: beginCheck
            )
            .disabled(!mayContinue).accessibilityIdentifier("sign-in-continue")
          }
          if let problem {
            Text(problem).foregroundStyle(.secondary).accessibilityIdentifier(
              "sign-in-server-error")
          } else if server?.url.scheme == "http" {
            Text("Enter your server’s HTTPS address.").font(.footnote).foregroundStyle(.secondary)
              .accessibilityIdentifier("sign-in-insecure-address")
          } else if !address.isEmpty && server == nil && !editingAddress {
            Text("Use the full HTTPS address, including any path before /web.").font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        DisclosureGroup("Where do I find this address?") {
          Text(
            "In Jukebox on a signed-in device, open Accounts → Connection details. In a browser, use the HTTPS address before /web, including any path such as /jellyfin. If someone invited you, ask them for the address."
          )
          .signInHelp()
        }
        if !store.connections.isEmpty { savedAccounts }
        if store.pendingSignOut != nil {
          Button("Retry sign-out") { Task { await store.finishSignOut() } }
        }
        Button("Try invented music") { Task { await store.enterFixture(service: fixture) } }
          .font(.subheadline).frame(minHeight: MusicUI.target)
          .disabled(store.busy || checking != nil || store.pendingSignOut != nil)
      }
      .onChange(of: address) {
        checking = nil
        problem = nil
      }
      .task(id: checking) {
        guard let checking else { return }
        do {
          let codes = try await store.signInCodeAvailability(on: checking)
          try Task.checkCancellation()
          guard self.checking == checking, self.server == checking, path.isEmpty else { return }
          self.checking = nil
          path.append(
            codes == false ? .password(checking, codesDisabled: true) : .methods(checking))
        } catch {
          guard !Task.isCancelled, self.checking == checking else { return }
          self.checking = nil
          problem = QuickConnectError.message(for: error)
        }
      }
      .navigationDestination(for: SignInDestination.self) { destination in
        switch destination {
        case .methods(let server):
          SignInMethods(server: server, showCode: { path.append(.code(server)) }) {
            path.append(.password(server, codesDisabled: false))
          }.disabled(store.busy || store.pendingSignOut != nil)
        case .password(let server, let disabled):
          PasswordSignIn(store: store, server: server, codesDisabled: disabled, username: $username)
        case .code(let server):
          QuickConnectSignIn(store: store, server: server) { disabled in
            guard path.last == .code(server) else { return }
            path[path.count - 1] = .password(server, codesDisabled: disabled)
          }
        }
      }
    }
    .sheet(item: $selectedConnection) { ConnectionDetails(store: store, connection: $0) }
  }

  private func beginCheck() {
    if server?.url.scheme != "https" {
      editingAddress = false
      problem = "Enter the HTTPS address of your Jellyfin server."
      return
    }
    guard mayContinue, let server else { return }
    editingAddress = false
    problem = nil
    checking = server
  }

  private var savedAccounts: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Saved accounts").font(.headline)
      ForEach(store.connections) { connection in
        HStack {
          Button {
            if connection.server.url.scheme == "http" {
              address = connection.server.url.absoluteString
              username = connection.username
              editingAddress = true
            } else {
              Task { await store.activate(connection) }
            }
          } label: {
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: connection.username)
                Text(verbatim: connection.server.url.absoluteString).font(.footnote)
                  .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "person.crop.circle")
            }
            .frame(maxWidth: .infinity, minHeight: MusicUI.target, alignment: .leading)
            .contentShape(.rect)
            .accessibilityLabel(Text(verbatim: connection.username))
            .accessibilityValue(Text(verbatim: connection.server.url.absoluteString))
          }
          Button {
            selectedConnection = connection
          } label: {
            Image(systemName: "info.circle").frame(
              minWidth: MusicUI.target, minHeight: MusicUI.target)
          }
          .accessibilityLabel("Connection details for \(connection.username)")
        }
      }
    }.disabled(store.busy || checking != nil)
  }
}
struct ConnectionDetails: View {
  @Bindable var store: PlayerStore
  let connection: Connection
  @Environment(\.dismiss) private var dismiss
  @State private var serverInfo: JellyfinServerInfo?
  @State private var confirmingRemoval = false
  @State private var actionError: String?
  private var isCurrent: Bool { store.active?.id == connection.id }
  private var removeTitle: LocalizedStringKey {
    UIDevice.current.userInterfaceIdiom == .pad
      ? "Remove from this iPad" : "Remove from this iPhone"
  }
  private var selectedMusicLibrary: MusicLibrary? {
    guard isCurrent, let browser = store.browser, browser.metadataIsCurrent else { return nil }
    return browser.libraries.first { $0.id == browser.libraryID }
  }
  #if DEBUG
    @State private var captureState = TransportCapture.State.idle
    @State private var captureNotice = ""
    @Environment(\.scenePhase) private var capturePhase
  #endif
  var body: some View {
    NavigationStack {
      Form {
        Section("Account") {
          VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: connection.username).font(.headline).accessibilityIdentifier(
              "connection-username")
            Text(isCurrent ? "Current account" : "Saved on this device").font(.subheadline)
              .foregroundStyle(.secondary)
          }.accessibilityElement(children: .contain)
          if let library = selectedMusicLibrary {
            LabeledContent("Music library") { Text(verbatim: library.title) }
          }
        }
        Section {
          Text(verbatim: connection.server.url.absoluteString).font(MusicType.primary.monospaced())
            .textSelection(.enabled).accessibilityIdentifier("connection-server-address")
          if let info = serverInfo ?? connection.serverInfo {
            if let name = info.name, !name.isEmpty {
              LabeledContent("Server name") { Text(verbatim: name) }
            }
            LabeledContent("Jellyfin version") { Text(verbatim: info.version) }
          }
          LabeledContent("Transport") {
            Text(verbatim: connection.server.url.scheme?.uppercased() ?? "")
          }
          Button("Copy server address", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = connection.server.url.absoluteString
          }
        } header: {
          Text("Server")
        } footer: {
          if !connection.server.supportsCredentials {
            Text("This saved address uses HTTP. Use your server’s HTTPS address to sign in.")
          } else if serverInfo == nil, connection.serverInfo != nil {
            Text("Server information from the last sign-in.")
          }
        }
        if !isCurrent {
          Section {
            if connection.server.supportsCredentials {
              Button("Switch to this account", systemImage: "arrow.triangle.2.circlepath") {
                Task {
                  actionError = nil
                  await store.activate(connection)
                  if isCurrent || !store.connections.contains(where: { $0.id == connection.id }) {
                    dismiss()
                  } else if let error = store.error {
                    actionError = error
                    store.dismissError()
                  }
                }
              }
            }
            Button(role: .destructive) {
              confirmingRemoval = true
            } label: {
              Label(removeTitle, systemImage: "trash")
            }
            .accessibilityIdentifier("remove-saved-connection")
            if let actionError {
              Text(actionError).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("connection-action-error")
            }
          }.disabled(store.busy || store.pendingSignOut != nil)
        }
        Section("About") {
          LabeledContent("Jukebox version") {
            Text(
              verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "—")
          }
          LabeledContent("Build") {
            Text(
              verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "—"
            )
            .accessibilityIdentifier("app-build-marker")
          }
          DisclosureGroup("Jellyfin user ID") {
            Text(verbatim: connection.userID).font(.footnote.monospaced()).textSelection(.enabled)
          }
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
        .navigationTitle("Connection details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: connection.id) {
          guard isCurrent, !store.isFixture else { return }
          serverInfo = try? await store.serverInfo(for: connection)
        }
        .alert("Remove this saved connection?", isPresented: $confirmingRemoval) {
          Button("Remove", role: .destructive) {
            Task {
              do {
                try await store.removeSavedConnection(connection)
                dismiss()
              } catch {
                actionError =
                  "Some saved data couldn’t be removed. Try removing this connection again."
              }
            }
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(
            "This removes the saved sign-in, queue, and preferences for \(connection.username) at \(connection.server.url.absoluteString) from this device. Your Jellyfin account and music stay on the server."
          )
        }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    .presentationDragIndicator(.visible)
  }
}
