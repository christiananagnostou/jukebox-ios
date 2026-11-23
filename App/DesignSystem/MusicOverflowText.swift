import SwiftUI

struct MusicTextActivity: Equatable {
  var occurrence: UUID?
  var track: String?
  var album: String?
  var artists: Set<String> = []
  var playing = false
}
extension EnvironmentValues {
  @Entry var musicTextActivity = MusicTextActivity()
  @Entry var musicTextMotionAllowed = true
  #if DEBUG
    @Entry var musicTextDiagnostics = false
    @Entry var musicTextTestReduceMotion = false
    @Entry var musicTextTestVoiceOver = false
  #endif
}
private struct MusicTextActivityObserver: View {
  let store: PlayerStore
  @Binding var value: MusicTextActivity
  private var accepted: MusicTextActivity {
    MusicTextActivity(
      occurrence: store.current?.id, track: store.current?.track.id,
      album: store.current?.track.albumID,
      artists: Set(store.current?.track.artistCredits?.map(\.id) ?? []), playing: store.playing)
  }
  var body: some View {
    Color.clear.frame(width: 0, height: 0).accessibilityHidden(true).allowsHitTesting(false)
      .onChange(of: accepted, initial: true) { _, next in
        if value != next { value = next }
      }
  }
}
private struct MusicTextActivityScope: ViewModifier {
  let store: PlayerStore
  @State private var activity = MusicTextActivity()
  func body(content: Content) -> some View {
    content.environment(\.musicTextActivity, activity)
      .background { MusicTextActivityObserver(store: store, value: $activity) }
  }
}
extension View {
  func musicTextActivity(store: PlayerStore) -> some View {
    modifier(MusicTextActivityScope(store: store))
  }
  func musicTextMotion(allowed: Bool) -> some View {
    modifier(MusicTextMotionGate(allowed: allowed))
  }
}

private struct MusicTextMotionGate: ViewModifier {
  let allowed: Bool
  @Environment(\.musicTextMotionAllowed) private var inherited
  func body(content: Content) -> some View {
    content.environment(\.musicTextMotionAllowed, inherited && allowed)
  }
}

enum MusicTextContext {
  case browsing, reading, inactive
  case track(String)
  case album(String)
  case artist(String)
  case occurrence(UUID)
  fileprivate func isCurrent(_ activity: MusicTextActivity) -> Bool {
    guard activity.playing else { return false }
    switch self {
    case .track(let id): return activity.track == id
    case .album(let id): return activity.album == id
    case .artist(let id): return activity.artists.contains(id)
    case .occurrence(let id): return activity.occurrence == id
    default: return false
    }
  }
}

struct MusicOverflowText: View {
  let text: String
  var context: MusicTextContext = .browsing
  @Environment(\.musicTextActivity) private var activity
  @Environment(\.musicTextMotionAllowed) private var allowed
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.scenePhase) private var scene
  @Environment(\.layoutDirection) private var direction
  @Environment(\.font) private var font
  #if DEBUG
    @Environment(\.musicTextDiagnostics) private var diagnostics
    @Environment(\.musicTextTestReduceMotion) private var testReduceMotion
    @Environment(\.musicTextTestVoiceOver) private var testVoiceOver
  #endif
  @Environment(\.isFocused) private var focused
  @State private var measured = CGSize.zero
  @State private var width: CGFloat = 0
  @State private var appeared = false
  @State private var visible = true
  @State private var hovered = false
  private var distance: CGFloat { max(0, measured.width - width) }
  private var eligibleForMotion: Bool {
    guard allowed, scene == .active, !reduceMotion, !voiceOver else { return false }
    #if DEBUG
      if diagnostics && (testReduceMotion || testVoiceOver) { return false }
    #endif
    switch context {
    case .inactive: return false
    case .reading: return true
    default: return hovered || focused || context.isCurrent(activity)
    }
  }
  private var moving: Bool {
    appeared && visible && width > 0 && distance > 1 && measured.width.isFinite
  }
  private var label: some View {
    Text(text.isEmpty ? " " : text).lineLimit(1, reservesSpace: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
  var body: some View {
    let eligible = eligibleForMotion
    Group {
      if eligible { measuredLabel } else { label }
    }
    .clipped().accessibilityElement(children: .ignore).accessibilityLabel(text)
    .accessibilityAddTraits(.isStaticText)
    .contentShape([.interaction, .accessibility], .rect)
    .modifier(TextMotionDiagnostic(enabled: diagnosticEnabled, moving: eligible && moving))
    .onHover { hovered = $0 }
    .onDisappear { hovered = false }
  }
  private var measuredLabel: some View {
    label.opacity(moving ? 0 : 1)
      .background {
        Text(text).fixedSize(horizontal: true, vertical: false).hidden()
          .onGeometryChange(for: CGSize.self) {
            $0.size
          } action: {
            measured = $0
          }
          .accessibilityHidden(true).allowsHitTesting(false)
      }
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        width = $0
      }
      .overlay(alignment: .leading) {
        if moving {
          MusicTextTravel(text: text, distance: distance, rightToLeft: direction == .rightToLeft)
            .id(
              MotionIdentity(
                text: text, measured: measured, width: width, font: font,
                rightToLeft: direction == .rightToLeft)
            )
            .accessibilityHidden(true).allowsHitTesting(false)
        }
      }
      .onScrollVisibilityChange(threshold: 0.8) { visible = $0 }
      .onAppear { appeared = true }
      .onDisappear { appeared = false }
  }
  private var diagnosticEnabled: Bool {
    #if DEBUG
      diagnostics
    #else
      false
    #endif
  }
  private struct TextMotionDiagnostic: ViewModifier {
    let enabled: Bool
    let moving: Bool
    @ViewBuilder func body(content: Content) -> some View {
      if enabled { content.accessibilityValue(moving ? "moving" : "static") } else { content }
    }
  }
  private struct MotionIdentity: Hashable {
    let text: String
    let measured: CGSize
    let width: CGFloat
    let font: Font?
    let rightToLeft: Bool
    func hash(into hasher: inout Hasher) {
      hasher.combine(text)
      hasher.combine(measured.width)
      hasher.combine(measured.height)
      hasher.combine(width)
      hasher.combine(font)
      hasher.combine(rightToLeft)
    }
  }
}
private struct MusicTextTravel: View {
  let text: String
  let distance: CGFloat
  let rightToLeft: Bool
  var body: some View {
    Text(text).fixedSize(horizontal: true, vertical: false)
      .keyframeAnimator(initialValue: CGFloat.zero, repeating: true) { content, offset in
        content.offset(x: rightToLeft ? offset : -offset)
      } keyframes: { _ in
        LinearKeyframe(0, duration: 1.6)
        LinearKeyframe(distance, duration: Double(distance) / 24)
        LinearKeyframe(distance, duration: 1.6)
        LinearKeyframe(0, duration: Double(distance) / 24)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .mask { MusicTextFade() }
  }
}

struct MusicTextFade: View {
  var body: some View {
    GeometryReader { geometry in
      let fade = min(12 / max(geometry.size.width, 1), 0.25)
      LinearGradient(
        stops: [
          .init(color: .black, location: 0),
          .init(color: .black, location: 1 - fade),
          .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }
  }
}
