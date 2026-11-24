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
  enum Purpose {
    case username(Binding<String>)
    case password
  }

  final class Fields {
    weak var username: UITextField?
    weak var password: UITextField?
  }

  let purpose: Purpose
  let fields: Fields
  let submit: () -> Void
  @Environment(\.isEnabled) private var enabled

  init(_ purpose: Purpose, fields: Fields, submit: @escaping () -> Void) {
    self.purpose = purpose
    self.fields = fields
    self.submit = submit
  }

  final class Input: UITextField {
    override func textRect(forBounds bounds: CGRect) -> CGRect {
      super.textRect(forBounds: bounds.insetBy(dx: 14, dy: 0))
    }
    override func editingRect(forBounds bounds: CGRect) -> CGRect {
      super.editingRect(forBounds: bounds.insetBy(dx: 14, dy: 0))
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      let color = UIColor(isFirstResponder ? MusicUI.tint : MusicUI.border)
      layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
      layer.borderWidth = isFirstResponder ? 2 : 1
    }
    @objc func focusOnTap() {
      if isEnabled, !isFirstResponder { becomeFirstResponder() }
    }
  }

  final class Coordinator: NSObject, UITextFieldDelegate, UIGestureRecognizerDelegate {
    var input: CredentialInput
    init(_ input: CredentialInput) { self.input = input }
    @objc func changed(_ field: UITextField) {
      if case .username(let binding) = input.purpose { binding.wrappedValue = field.text ?? "" }
    }
    func textFieldDidBeginEditing(_ field: UITextField) { field.setNeedsLayout() }
    func textFieldDidEndEditing(_ field: UITextField) { field.setNeedsLayout() }
    func textFieldShouldReturn(_ field: UITextField) -> Bool {
      switch input.purpose {
      case .username: input.fields.password?.becomeFirstResponder()
      case .password: input.submit()
      }
      return false
    }
    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> Input {
    let field = Input()
    field.font = .preferredFont(forTextStyle: .body)
    field.adjustsFontForContentSizeCategory = true
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.spellCheckingType = .no
    field.backgroundColor = UIColor(MusicUI.panel)
    field.layer.cornerRadius = 13
    field.layer.cornerCurve = .continuous
    switch purpose {
    case .username(let username):
      fields.username = field
      field.text = username.wrappedValue
      field.textContentType = .username
      field.returnKeyType = .next
      field.placeholder = String(localized: "Username")
      field.accessibilityIdentifier = "sign-in-username"
      field.addTarget(
        context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
    case .password:
      fields.password = field
      field.isSecureTextEntry = true
      field.textContentType = .password
      field.returnKeyType = .go
      field.placeholder = String(localized: "Password")
      field.accessibilityIdentifier = "sign-in-password"
    }
    field.accessibilityLabel = field.placeholder
    field.delegate = context.coordinator
    let tap = UITapGestureRecognizer(target: field, action: #selector(Input.focusOnTap))
    tap.cancelsTouchesInView = false
    tap.delegate = context.coordinator
    field.addGestureRecognizer(tap)
    return field
  }

  func updateUIView(_ field: Input, context: Context) {
    context.coordinator.input = self
    field.isEnabled = enabled
    if case .username(let username) = purpose, !field.isFirstResponder,
      field.text != username.wrappedValue
    {
      field.text = username.wrappedValue
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
  private struct Submission {
    let username: String
    let password: String
  }
  @State private var fields = CredentialInput.Fields()
  @State private var submission: Submission?
  private var submitting: Bool { submission != nil }

  var body: some View {
    SignInPage("Sign in with a password") {
      if codesDisabled {
        Text("This server has sign-in codes turned off.").foregroundStyle(.secondary)
          .accessibilityIdentifier("sign-in-codes-disabled")
      }
      Text("Use your Jellyfin account on \(server.url.absoluteString).").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        Text("Username").font(.subheadline.weight(.semibold))
        CredentialInput(.username($username), fields: fields, submit: submit)
          .frame(maxWidth: .infinity)
        Text("Password").font(.subheadline.weight(.semibold)).padding(.top, 8)
        HStack(spacing: 4) {
          CredentialInput(.password, fields: fields, submit: submit)
            .frame(maxWidth: .infinity)
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
      guard let submission else { return }
      await store.signIn(
        address: server.url.absoluteString, username: submission.username,
        password: submission.password)
      self.submission = nil
    }
  }

  private func submit() {
    guard !submitting, !store.busy, store.pendingSignOut == nil,
      let usernameField = fields.username, let name = usernameField.text, !name.isEmpty,
      let passwordField = fields.password
    else { return }
    submission = Submission(username: name, password: passwordField.text ?? "")
    passwordField.text = nil
    if usernameField.isFirstResponder { usernameField.resignFirstResponder() }
    if passwordField.isFirstResponder { passwordField.resignFirstResponder() }
  }
}
