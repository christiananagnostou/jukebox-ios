import SwiftUI

struct ReleaseYearControl: View {
  let bounds: ClosedRange<Int>
  let selection: CatalogYearRange
  let decades: [ClosedRange<Int>]
  let feedbackEnabled: () -> Bool
  let isCurrent: () -> Bool
  let commit: (CatalogYearRange) -> Void
  @State private var lower: Int
  @State private var upper: Int
  @State private var exactEndpoint: YearEndpoint?
  @State private var feedback = 0
  @State private var feedbackGate = CatalogSelectionFeedback()
  @Environment(\.isEnabled) private var enabled
  @State private var editing = false
  @State private var drag: (endpoint: Bool, origin: CGFloat, combined: Bool)?
  @State private var adjustment: Task<Void, Never>?
  @Environment(\.layoutDirection) private var direction
  init(
    bounds: ClosedRange<Int>, selection: CatalogYearRange, decades: [ClosedRange<Int>],
    feedbackEnabled: @escaping () -> Bool, isCurrent: @escaping () -> Bool,
    commit: @escaping (CatalogYearRange) -> Void
  ) {
    self.bounds = bounds
    self.selection = selection
    self.decades = decades
    self.feedbackEnabled = feedbackEnabled
    self.isCurrent = isCurrent
    self.commit = commit
    let low = min(bounds.upperBound, max(bounds.lowerBound, selection.lower ?? bounds.lowerBound))
    lower = low
    upper = max(low, min(bounds.upperBound, selection.upper ?? bounds.upperBound))
  }
  private var span: Int { bounds.upperBound - bounds.lowerBound }
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(selection.isAll && !editing ? "All release years" : displayedCaption)
        .font(MusicType.secondary.monospacedDigit()).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("browse-years-caption")
      HStack(spacing: 8) {
        endpoint(.from, year: editing ? lower : selection.lower ?? bounds.lowerBound)
        Spacer(minLength: 4)
        endpoint(.to, year: editing ? upper : selection.upper ?? bounds.upperBound)
      }
      if span == 0 {
        HStack(spacing: 12) {
          allNodule
          Rectangle().fill(MusicUI.border).frame(height: 3)
          Button {
            accept(
              CatalogYearRange(lower: bounds.lowerBound, upper: bounds.upperBound)!, tactile: true)
          } label: {
            Circle().fill(
              !selection.isAll && selection.contains(bounds.lowerBound)
                ? MusicUI.tint : MusicUI.border
            )
            .frame(width: 20, height: 20).frame(width: 44, height: 44).contentShape(.rect)
          }
          .accessibilityLabel("Release year " + String(bounds.lowerBound))
          .accessibilityAddTraits(
            !selection.isAll && selection.contains(bounds.lowerBound) ? [.isSelected] : [])
        }.frame(height: 44)
        HStack {
          Text("All").frame(width: 44)
          Spacer()
          Text(String(bounds.lowerBound)).frame(minWidth: 44)
        }.font(MusicType.support.monospacedDigit()).foregroundStyle(.secondary)
          .accessibilityHidden(true)
      } else {
        GeometryReader { geometry in
          let width = max(1, geometry.size.width - 100)
          let railOrigin: CGFloat = direction == .rightToLeft ? 0 : 56
          let allPosition: CGFloat = direction == .rightToLeft ? geometry.size.width - 44 : 0
          let low = x(lower, width: width)
          let high = x(upper, width: width)
          let collision = drag.map { $0.combined } ?? (abs(high - low) < 44)
          ZStack(alignment: .topLeading) {
            Capsule().fill(MusicUI.quiet).frame(width: max(1, geometry.size.width - 44), height: 3)
              .offset(x: 22, y: 21)
            allNodule.offset(x: allPosition)
            Capsule().fill(selection.isAll && !editing ? MusicUI.border : MusicUI.tint)
              .frame(width: abs(high - low), height: 3).offset(
                x: railOrigin + min(low, high) + 22, y: 21)
            handle(lowerBound: true, width: width, railOrigin: railOrigin)
              .allowsHitTesting(!collision).offset(x: railOrigin + low)
            handle(lowerBound: false, width: width, railOrigin: railOrigin)
              .allowsHitTesting(!collision).offset(x: railOrigin + high)
            if collision {
              Circle().fill(MusicUI.tint).frame(width: 20, height: 20)
                .overlay {
                  Image(systemName: "arrow.left.and.right").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MusicUI.onTint)
                }
                .frame(width: 44, height: 44).contentShape(.rect)
                .gesture(dragGesture(lowerBound: nil, width: width, railOrigin: railOrigin))
                .accessibilityHidden(true).offset(x: railOrigin + (low + high) / 2)
            }
          }.frame(width: geometry.size.width, height: 44, alignment: .topLeading)
            .environment(\.layoutDirection, .leftToRight)
            .coordinateSpace(name: "release-year-rail")
        }.frame(height: 44)
        HStack(spacing: 12) {
          Text("All").frame(width: 44)
          HStack {
            Text(String(bounds.lowerBound)).frame(minWidth: 44)
            Spacer()
            Text(String(bounds.upperBound)).frame(minWidth: 44)
          }
        }.font(MusicType.support.monospacedDigit()).foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
    }.buttonStyle(MusicButtonStyle())
      .sensoryFeedback(.selection, trigger: feedback)
      .sheet(item: $exactEndpoint) { endpoint in
        ReleaseYearEditor(
          endpoint: endpoint, selection: selection, bounds: bounds, decades: decades,
          isCurrent: isCurrent
        ) { accept($0, tactile: true) }
        .environment(\.layoutDirection, direction)
      }
      .onChange(of: isCurrent()) { _, current in
        if !current {
          adjustment?.cancel()
          exactEndpoint = nil
          drag = nil
          editing = false
        }
      }
      .onAppear { synchronize() }
      .onChange(of: selection) { _, _ in if !editing { synchronize() } }
      .onChange(of: bounds) { _, _ in
        adjustment?.cancel()
        exactEndpoint = nil
        editing = false
        drag = nil
        synchronize()
      }
      .onDisappear { adjustment?.cancel() }
  }
  private var allNodule: some View {
    Button {
      adjustment?.cancel()
      editing = false
      drag = nil
      lower = bounds.lowerBound
      upper = bounds.upperBound
      accept(.all, tactile: true)
    } label: {
      Circle().fill(selection.isAll && !editing ? MusicUI.tint : MusicUI.border)
        .frame(width: 20, height: 20).frame(width: 44, height: 44).contentShape(.rect)
    }.accessibilityLabel("All release years")
      .accessibilityAddTraits(selection.isAll ? [.isSelected] : [])
      .accessibilityIdentifier("browse-years-all")
  }
  private var displayedCaption: String {
    guard !editing, let low = selection.lower, let high = selection.upper else { return caption }
    return low == high ? String(low) : "\(low)–\(high)"
  }
  private var caption: String { lower == upper ? String(lower) : "\(lower)–\(upper)" }
  private func x(_ value: Int, width: CGFloat) -> CGFloat {
    let fraction = CGFloat(value - bounds.lowerBound) / CGFloat(max(1, span))
    return (direction == .rightToLeft ? 1 - fraction : fraction) * width
  }
  private func handle(lowerBound: Bool, width: CGFloat, railOrigin: CGFloat) -> some View {
    Circle().fill(MusicUI.tint).frame(width: 20, height: 20)
      .frame(width: 44, height: 44).contentShape(.rect)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(lowerBound ? "Earliest release year" : "Latest release year")
      .accessibilityValue(String(lowerBound ? lower : upper))
      .accessibilityAdjustableAction { action in
        adjust(lowerBound: lowerBound, delta: action == .increment ? 1 : -1)
      }
      .focusable()
      .onKeyPress(.leftArrow) {
        adjust(lowerBound: lowerBound, delta: direction == .rightToLeft ? 1 : -1)
        return .handled
      }
      .onKeyPress(.rightArrow) {
        adjust(lowerBound: lowerBound, delta: direction == .rightToLeft ? -1 : 1)
        return .handled
      }
      .gesture(dragGesture(lowerBound: lowerBound, width: width, railOrigin: railOrigin))
      .accessibilityIdentifier(lowerBound ? "browse-years-lower" : "browse-years-upper")
  }
  private func dragGesture(lowerBound: Bool?, width: CGFloat, railOrigin: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named("release-year-rail"))
      .onChanged { value in
        guard enabled, isCurrent() else { return }
        adjustment?.cancel()
        let logicalMovement = value.translation.width * (direction == .rightToLeft ? -1 : 1)
        if drag == nil {
          let endpoint: Bool
          if let lowerBound {
            endpoint = lowerBound
          } else {
            let lowDistance = abs(value.startLocation.x - railOrigin - x(lower, width: width) - 22)
            let highDistance = abs(value.startLocation.x - railOrigin - x(upper, width: width) - 22)
            if lowDistance == highDistance {
              guard abs(logicalMovement) >= 0.5 else { return }
              endpoint = logicalMovement < 0
            } else {
              endpoint = lowDistance < highDistance
            }
          }
          drag = (endpoint, x(endpoint ? lower : upper, width: width), lowerBound == nil)
        }
        guard let drag else { return }
        editing = true
        let fraction = max(0, min(1, (drag.origin + value.translation.width) / width))
        let year =
          bounds.lowerBound
          + Int(((direction == .rightToLeft ? 1 - fraction : fraction) * CGFloat(span)).rounded())
        let previous = drag.endpoint ? lower : upper
        set(year, lowerBound: drag.endpoint)
        let updated = drag.endpoint ? lower : upper
        if updated != previous && updated / 10 != previous / 10 { selectionFeedback() }
      }
      .onEnded { _ in
        guard drag != nil else { return }
        drag = nil
        editing = false
        publish()
      }
  }
  private func synchronize() {
    lower = min(bounds.upperBound, max(bounds.lowerBound, selection.lower ?? bounds.lowerBound))
    upper = max(lower, min(bounds.upperBound, selection.upper ?? bounds.upperBound))
  }
  private func set(_ value: Int, lowerBound: Bool) {
    if lowerBound {
      lower = min(upper, max(bounds.lowerBound, value))
    } else {
      upper = max(lower, min(bounds.upperBound, value))
    }
  }
  private func adjust(lowerBound: Bool, delta: Int) {
    guard enabled, isCurrent() else { return }
    let previous = lowerBound ? lower : upper
    set(previous + delta, lowerBound: lowerBound)
    guard previous != (lowerBound ? lower : upper) else { return }
    editing = true
    adjustment?.cancel()
    adjustment = Task { @MainActor in
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      editing = false
      publish(tactile: true)
    }
  }
  private func publish(tactile: Bool = false) {
    guard let value = CatalogYearRange(lower: lower, upper: upper) else { return }
    accept(value, tactile: tactile)
  }
  private func accept(_ value: CatalogYearRange, tactile: Bool) {
    guard enabled, isCurrent(), value != selection else { return }
    if tactile { selectionFeedback() }
    commit(value)
  }
  private func selectionFeedback() {
    guard enabled, isCurrent(),
      feedbackGate.admit(enabled: feedbackEnabled, at: ProcessInfo.processInfo.systemUptime)
    else { return }
    feedback &+= 1
  }
  private func endpoint(_ endpoint: YearEndpoint, year: Int) -> some View {
    Button {
      guard enabled, isCurrent() else { return }
      adjustment?.cancel()
      editing = false
      drag = nil
      exactEndpoint = endpoint
    } label: {
      HStack(spacing: 5) {
        Text(endpoint == .from ? "From" : "To").foregroundStyle(.secondary)
        Text(String(year)).monospacedDigit().foregroundStyle(MusicUI.tint)
      }.font(MusicType.secondary).frame(minWidth: 88, minHeight: 44).contentShape(.rect)
    }
    .accessibilityLabel(endpoint == .from ? "From release year" : "To release year")
    .accessibilityValue(String(year))
    .accessibilityIdentifier(endpoint == .from ? "browse-years-from" : "browse-years-to")
  }
}

private enum YearEndpoint: String, Identifiable, Hashable {
  case from, to
  var id: String { rawValue }
}

private struct ReleaseYearEditor: View {
  let decades: [ClosedRange<Int>]
  let isCurrent: () -> Bool
  let accept: (CatalogYearRange) -> Void
  @State private var draft: CatalogYearDraft
  @FocusState private var focused: YearEndpoint?
  let endpoint: YearEndpoint
  @Environment(\.dismiss) private var dismiss
  init(
    endpoint: YearEndpoint, selection: CatalogYearRange, bounds: ClosedRange<Int>,
    decades: [ClosedRange<Int>], isCurrent: @escaping () -> Bool,
    accept: @escaping (CatalogYearRange) -> Void
  ) {
    self.endpoint = endpoint
    self.decades = decades
    self.isCurrent = isCurrent
    self.accept = accept
    _draft = State(initialValue: CatalogYearDraft(selection: selection, bounds: bounds))
  }
  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("From") {
            TextField("Year", text: $draft.from).focused($focused, equals: .from)
              .multilineTextAlignment(.trailing).accessibilityLabel("From release year")
              .accessibilityIdentifier("year-editor-from")
          }
          LabeledContent("To") {
            TextField("Year", text: $draft.to).focused($focused, equals: .to)
              .multilineTextAlignment(.trailing).accessibilityLabel("To release year")
              .accessibilityIdentifier("year-editor-to")
          }
        } footer: {
          if draft.accepted == nil { Text("Enter years 1–9999, earliest first.") }
        }
        if !decades.isEmpty {
          Section {
            Menu {
              ForEach(decades, id: \.self) { decade in
                Button("\(decade.lowerBound)–\(decade.upperBound)") {
                  guard isCurrent() else { return }
                  draft.from = String(decade.lowerBound)
                  draft.to = String(decade.upperBound)
                  focused = nil
                }
              }
            } label: {
              Label("Choose decade", systemImage: "calendar").frame(minHeight: 44)
            }.accessibilityIdentifier("year-editor-decade")
          }
        }
      }
      .keyboardType(.numberPad).monospacedDigit()
      .navigationTitle("Release years").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") { focused = nil }
            .accessibilityIdentifier("year-editor-keyboard")
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.accessibilityIdentifier("year-editor-cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            guard isCurrent(), let value = draft.accepted else { return }
            accept(value)
            dismiss()
          }.disabled(draft.accepted == nil).accessibilityIdentifier("year-editor-done")
        }
      }
    }
    .onAppear { focused = endpoint }
    .onChange(of: isCurrent()) { _, current in if !current { dismiss() } }
    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
  }
}
