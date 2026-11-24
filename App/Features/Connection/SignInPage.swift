import SwiftUI

struct SignInPage<Content: View>: View {
  let title: LocalizedStringKey
  let content: Content

  init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: MusicUI.group) {
        Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
        content
      }
      .padding(.horizontal, 24).padding(.vertical, 18)
      .frame(maxWidth: 490, alignment: .leading).frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively).background(MusicUI.canvas)
    .navigationTitle("Jukebox").navigationBarTitleDisplayMode(.inline)
  }
}

struct SignInButton: View {
  let title: LocalizedStringKey
  let action: () -> Void

  init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title).font(.headline)
        .frame(maxWidth: .infinity, minHeight: MusicUI.target)
    }
    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
    .tint(MusicUI.tint).foregroundStyle(MusicUI.onTint)
  }
}

extension View {
  func signInHelp() -> some View {
    font(.footnote).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
  }
}

struct SignInMethods: View {
  let server: ServerAddress
  let showCode: () -> Void
  let usePassword: () -> Void

  var body: some View {
    SignInPage(
      UIDevice.current.userInterfaceIdiom == .pad
        ? "Sign in on this iPad" : "Sign in on this iPhone"
    ) {
      Label(server.url.absoluteString, systemImage: "server.rack")
        .font(.subheadline).foregroundStyle(.secondary)
        .accessibilityIdentifier("sign-in-method-server")
      VStack(alignment: .leading, spacing: 4) {
        Text("Already signed in elsewhere?").font(.headline)
        Text("Use that browser or device to approve this sign-in.").foregroundStyle(.secondary)
      }.padding(.top, 8)
      SignInButton("Show a sign-in code", action: showCode)
        .accessibilityIdentifier("sign-in-show-code")
      Divider().padding(.vertical, 4)
      VStack(alignment: .leading, spacing: 0) {
        Text("First device?").font(.headline)
        Button("Use username and password", action: usePassword).frame(minHeight: MusicUI.target)
          .accessibilityIdentifier("sign-in-password-method")
      }
    }
  }
}

struct PasswordSignIn: View {
  let store: PlayerStore
  let server: ServerAddress
  let codesDisabled: Bool
  @Binding var username: String
  @State private var password = ""
  @State private var submitting = false
  @FocusState private var field: Field?
  private enum Field { case username, password }

  var body: some View {
    SignInPage("Sign in with a password") {
      if codesDisabled {
        Text("This server has sign-in codes turned off.").foregroundStyle(.secondary)
          .accessibilityIdentifier("sign-in-codes-disabled")
      }
      Text("Use your Jellyfin account on \(server.url.absoluteString).").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        Text("Username").font(.subheadline.weight(.semibold))
        TextField("Username", text: $username).textContentType(.username)
          .textInputAutocapitalization(.never).autocorrectionDisabled().focused(
            $field, equals: .username
          )
          .submitLabel(.next).onSubmit { field = .password }
        Text("Password").font(.subheadline.weight(.semibold)).padding(.top, 8)
        SecureField("Password", text: $password).textContentType(.password)
          .focused($field, equals: .password).submitLabel(.go).onSubmit(submit)
      }.textFieldStyle(.roundedBorder).disabled(submitting)
      SignInButton(submitting ? "Signing in…" : "Sign in", action: submit)
        .disabled(submitting || store.busy || username.isEmpty || store.pendingSignOut != nil)
        .accessibilityIdentifier("sign-in-password-submit")
      DisclosureGroup("Need an account or password?") {
        Text(
          "Ask the person who manages this Jellyfin server to create an account for you or help you reset your password."
        )
        .signInHelp()
      }
    }
    .task(id: submitting) {
      guard submitting else { return }
      let secret = password
      password = ""
      await store.signIn(address: server.url.absoluteString, username: username, password: secret)
      submitting = false
    }
  }

  private func submit() {
    guard !submitting, !store.busy, !username.isEmpty, store.pendingSignOut == nil else { return }
    field = nil
    submitting = true
  }
}
