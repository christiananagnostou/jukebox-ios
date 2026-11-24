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

enum SignInControl {
  static let height: CGFloat = 52
}

struct SignInForward: View {
  let title: LocalizedStringKey
  let busy: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Group {
        if busy {
          ProgressView().tint(MusicUI.onTint)
        } else {
          Image(systemName: "arrow.forward").font(.title3.weight(.semibold))
            .foregroundStyle(MusicUI.onTint)
        }
      }
      .frame(width: SignInControl.height, height: SignInControl.height)
      .background(MusicUI.tint, in: .circle)
      .contentShape(.rect)
    }
    .buttonStyle(MusicButtonStyle()).accessibilityLabel(Text(title))
  }
}

struct SignInActionRow: View {
  let title: LocalizedStringKey
  var symbol = "chevron.forward"
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Text(title).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
        Spacer(minLength: 4)
        Image(systemName: symbol).font(.callout.weight(.semibold)).accessibilityHidden(true)
      }
      .frame(minHeight: MusicUI.target).contentShape(.rect)
    }
    .buttonStyle(MusicButtonStyle()).foregroundStyle(MusicUI.tint)
  }
}

extension View {
  func signInField(focused: Bool, focus: @escaping () -> Void) -> some View {
    textFieldStyle(.plain)
      .padding(.horizontal, 14).padding(.vertical, 12)
      .frame(maxWidth: .infinity, minHeight: SignInControl.height, alignment: .leading)
      .contentShape(.rect)
      .simultaneousGesture(TapGesture().onEnded { focus() })
      .signInFieldSurface(focused: focused)
  }

  fileprivate func signInFieldSurface(focused: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
    return background(MusicUI.panel, in: shape)
      .overlay {
        shape.strokeBorder(focused ? MusicUI.tint : MusicUI.border, lineWidth: focused ? 2 : 1)
          .allowsHitTesting(false).accessibilityHidden(true)
      }
  }

  func signInHelp() -> some View {
    font(.footnote).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
  }
}

private struct CredentialInput: UIViewRepresentable {
  enum Kind { case username, password }
  let kind: Kind
  @Binding var text: String
  @Binding var focused: Kind?
  let submit: () -> Void
  @Environment(\.isEnabled) private var enabled

  init(_ kind: Kind, text: Binding<String>, focused: Binding<Kind?>, submit: @escaping () -> Void) {
    self.kind = kind
    _text = text
    _focused = focused
    self.submit = submit
  }

  final class Input: UITextField {
    override func textRect(forBounds bounds: CGRect) -> CGRect {
      super.textRect(forBounds: bounds.insetBy(dx: 14, dy: 0))
    }
    override func editingRect(forBounds bounds: CGRect) -> CGRect {
      super.editingRect(forBounds: bounds.insetBy(dx: 14, dy: 0))
    }
  }

  final class Coordinator: NSObject, UITextFieldDelegate {
    var input: CredentialInput
    init(_ input: CredentialInput) { self.input = input }
    @objc func changed(_ field: UITextField) { input.text = field.text ?? "" }
    func textFieldDidBeginEditing(_ field: UITextField) {
      if input.focused != input.kind { input.focused = input.kind }
    }
    func textFieldDidEndEditing(_ field: UITextField) {
      if input.focused == input.kind { input.focused = nil }
    }
    func textFieldShouldReturn(_ field: UITextField) -> Bool {
      input.submit()
      return false
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> Input {
    let field = Input()
    field.font = .preferredFont(forTextStyle: .body)
    field.adjustsFontForContentSizeCategory = true
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.spellCheckingType = .no
    field.isSecureTextEntry = kind == .password
    field.textContentType = kind == .password ? .password : .username
    field.returnKeyType = kind == .password ? .go : .next
    field.placeholder =
      kind == .password ? String(localized: "Password") : String(localized: "Username")
    field.accessibilityLabel = field.placeholder
    field.accessibilityIdentifier = kind == .password ? "sign-in-password" : "sign-in-username"
    field.delegate = context.coordinator
    field.addTarget(
      context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
    return field
  }

  func updateUIView(_ field: Input, context: Context) {
    context.coordinator.input = self
    if field.text != text { field.text = text }
    field.isEnabled = enabled
    if focused == kind, enabled, !field.isFirstResponder, field.window != nil {
      field.becomeFirstResponder()
    } else if focused == nil, field.isFirstResponder {
      field.resignFirstResponder()
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: Input, context: Context) -> CGSize? {
    CGSize(
      width: proposal.width ?? max(0, uiView.intrinsicContentSize.width),
      height: max(SignInControl.height, ceil(uiView.font?.lineHeight ?? 0) + 24))
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
      SignInActionRow(title: "Show a sign-in code", action: showCode)
        .accessibilityIdentifier("sign-in-show-code")
      Divider().padding(.vertical, 4)
      VStack(alignment: .leading, spacing: 0) {
        Text("First device?").font(.headline)
        SignInActionRow(title: "Use username and password", action: usePassword)
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
  @State private var field: CredentialInput.Kind?

  var body: some View {
    SignInPage("Sign in with a password") {
      if codesDisabled {
        Text("This server has sign-in codes turned off.").foregroundStyle(.secondary)
          .accessibilityIdentifier("sign-in-codes-disabled")
      }
      Text("Use your Jellyfin account on \(server.url.absoluteString).").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        Text("Username").font(.subheadline.weight(.semibold))
        CredentialInput(.username, text: $username, focused: $field) { field = .password }
          .frame(maxWidth: .infinity).signInFieldSurface(focused: field == .username)
        Text("Password").font(.subheadline.weight(.semibold)).padding(.top, 8)
        HStack(spacing: 4) {
          CredentialInput(.password, text: $password, focused: $field, submit: submit)
            .frame(maxWidth: .infinity).signInFieldSurface(focused: field == .password)
          SignInForward(
            title: submitting ? "Signing in…" : "Sign in", busy: submitting, action: submit
          )
          .disabled(submitting || store.busy || username.isEmpty || store.pendingSignOut != nil)
          .accessibilityIdentifier("sign-in-password-submit")
        }
      }.disabled(submitting)
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
