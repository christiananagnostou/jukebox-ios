import UIKit
import Vision
import XCTest

final class JukeboxUITests: XCTestCase {
  #if LIVE_MUSIC_ACCEPTANCE && AUDIO_CLOCK_ACCEPTANCE
    @MainActor func testColdSavedQueueResumeMeasurements() throws {
      executionTimeAllowance = 1200
      let env = ProcessInfo.processInfo.environment
      let run = try XCTUnwrap(env["JUKEBOX_QUEUE_RUN"].flatMap(UUID.init(uuidString:)))
      let deadline = try XCTUnwrap(env["JUKEBOX_QUEUE_DEADLINE"].flatMap(Double.init))
      let app = XCUIApplication()
      app.launchArguments = ["--fixture", "--muted", "--transport-ui=" + run.uuidString]
      app.launchEnvironment["JUKEBOX_QUEUE_DEADLINE"] = String(deadline)
      func invoke(_ step: String, timeout: TimeInterval) throws -> (result: String, observedMS: Int)
      {
        guard deadline - Date.now.timeIntervalSince1970 > timeout + 8 else {
          throw URLError(.timedOut)
        }
        app.launchEnvironment["JUKEBOX_QUEUE_SAMPLE"] = run.uuidString + ":" + step
        let start = ProcessInfo.processInfo.systemUptime
        app.launch()
        defer { app.terminate() }
        let result = app.staticTexts["queue-resume-result"].firstMatch
        guard result.waitForExistence(timeout: timeout) else { throw URLError(.timedOut) }
        let value = result.label
        return (value, Int(((ProcessInfo.processInfo.systemUptime - start) * 1_000).rounded()))
      }
      defer {
        XCTAssertEqual(
          try? invoke("cleanup", timeout: 10).result, "clean", "Queue sample cleanup failed")
      }
      let preparation = try invoke("prepare", timeout: 120).result
      guard preparation == "prepared" else {
        XCTFail(preparation)
        return
      }
      var processes = Set<Int>()
      for pair in 0..<30 {
        let order = pair.isMultiple(of: 2) ? ["one", "many"] : ["many", "one"]
        for size in order {
          let (response, observed) = try invoke(size, timeout: 40)
          let columns = response.split(separator: " ")
          guard columns.count == 5, columns.first == "ok",
            let ready = Int(columns[1]), let decoded = Int(columns[2]), let clock = Int(columns[3]),
            let pid = Int(columns[4]), processes.insert(pid).inserted, ready > 0, ready <= decoded,
            ready <= clock, observed >= max(decoded, clock)
          else {
            XCTFail("Queue sample \(pair) \(size) returned \(response)")
            return
          }
          XCTContext.runActivity(
            named:
              "QueueResume pair=\(pair) size=\(size) ready_ms=\(ready) decoded_ms=\(decoded) clock_ms=\(clock) pid=\(pid) observed_ms=\(observed)"
          ) { _ in }
        }
      }
      XCTAssertEqual(processes.count, 60)
    }
  #endif
  @MainActor private func capture(
    _ name: String, app: XCUIApplication, screen: Bool = false
  ) {
    let attachment = XCTAttachment(
      screenshot: screen ? XCUIScreen.main.screenshot() : app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  @MainActor private func openSearch(_ app: XCUIApplication) {
    app.tabBars.buttons["Search"].tap()
    let field = app.textFields["global-search-field"].firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    field.tap()
  }
  @MainActor private func openPlayerQueue(_ app: XCUIApplication) {
    app.buttons["Open now playing"].tap()
    let queue = app.buttons["player-queue"]
    XCTAssertTrue(queue.waitForExistence(timeout: 3))
    XCTAssertGreaterThanOrEqual(queue.frame.height + 1e-9, 44)
    queue.tap()
  }
  @MainActor private func closePlayerQueue(_ app: XCUIApplication) {
    app.navigationBars["Queue"].buttons.element(boundBy: 0).tap()
    app.buttons["close-player"].tap()
  }
  @MainActor private func selectMusicLibrary(_ app: XCUIApplication, id: String) {
    let picker = app.buttons["music-library-picker"]
    XCTAssertTrue(picker.waitForExistence(timeout: 3))
    XCTAssertGreaterThanOrEqual(picker.frame.height, 44)
    picker.tap()
    let option = app.buttons["music-library-" + id]
    XCTAssertTrue(option.waitForExistence(timeout: 3))
    option.tap()
  }
  @MainActor private func chooseBrowseLayout(_ app: XCUIApplication, _ value: String) {
    let trigger = app.buttons["music-layout"]
    XCTAssertTrue(trigger.isHittable)
    let height = (trigger.frame.height * 1_000_000).rounded() / 1_000_000
    XCTAssertGreaterThanOrEqual(height, 44)
    if trigger.value as? String != value { trigger.tap() }
    XCTAssertEqual(trigger.value as? String, value)
    XCTAssertFalse(app.scrollViews["music-browse-sheet"].exists, "Layout is a direct toggle")
  }
  @MainActor private func replaceYear(_ app: XCUIApplication, id: String, value: String) {
    let field = app.textFields[id]
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    field.tap()
    let previous = field.value as? String ?? ""
    field.typeText(
      String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + value)
    XCTAssertEqual(field.value as? String, value)
  }
  @MainActor private func showYearRail(_ app: XCUIApplication) {
    let sheet = app.scrollViews["music-browse-sheet"]
    let all = app.buttons["browse-years-all"]
    for _ in 0..<3 {
      if all.isHittable { break }
      sheet.swipeUp()
    }
    XCTAssertTrue(all.waitForExistence(timeout: 5))
    XCTAssertTrue(all.isHittable)
  }
  @MainActor private func dismissSearchKeyboard(_ app: XCUIApplication) {
    let keyboard = app.keyboards.firstMatch
    if keyboard.exists {
      app.textFields["global-search-field"].firstMatch.typeText("\n")
      let retired = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == false"), object: keyboard)
      XCTAssertEqual(XCTWaiter.wait(for: [retired], timeout: 3), .completed)
    }
    XCTAssertFalse(keyboard.exists)
  }
  @MainActor private func assertSearchKeyboardDismissed(_ app: XCUIApplication) {
    let retired = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
    XCTAssertEqual(XCTWaiter.wait(for: [retired], timeout: 3), .completed)
    XCTAssertFalse(app.keyboards.firstMatch.exists)
  }
  @MainActor private func tapVisibleSearchGap(
    _ app: XCUIApplication, anchor: XCUIElement, trailing: Bool = false
  ) {
    let collection = app.scrollViews["music-collection"]
    let keyboard = app.keyboards.firstMatch
    let field = app.textFields["global-search-field"].firstMatch
    let controls = app.otherElements["search-browse-controls"].firstMatch
    func usable(_ rect: CGRect) -> Bool {
      [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
        && !rect.isEmpty && !rect.isNull
    }
    guard collection.exists, keyboard.exists, field.exists, controls.exists,
      anchor.exists, anchor.isHittable
    else {
      XCTFail("The current Search viewport, keyboard, input and semantic anchor must exist")
      return
    }
    let appFrame = app.frame
    let collectionFrame = collection.frame
    let keyboardFrame = keyboard.frame
    let fieldFrame = field.frame
    let controlsFrame = controls.frame
    let anchorFrame = anchor.frame
    guard
      [appFrame, collectionFrame, keyboardFrame, fieldFrame, controlsFrame, anchorFrame]
        .allSatisfy(usable)
    else {
      XCTFail("Search gap geometry must be finite and nonempty")
      return
    }
    let intersection = collectionFrame.intersection(appFrame)
    let top = max(intersection.minY, controlsFrame.maxY)
    let bottom = min(intersection.maxY, keyboardFrame.minY)
    let visible = CGRect(
      x: intersection.minX, y: top, width: intersection.width, height: bottom - top)
    let left = trailing ? max(visible.minX, anchorFrame.maxX) : visible.minX
    let gapTop =
      trailing ? max(visible.minY, anchorFrame.minY) : max(visible.minY, anchorFrame.maxY)
    let gapBottom = trailing ? min(visible.maxY, anchorFrame.maxY) : visible.maxY
    let gap = CGRect(x: left, y: gapTop, width: visible.maxX - left, height: gapBottom - gapTop)
    guard usable(visible), visible.intersects(anchorFrame), usable(gap), gap.width > 2,
      gap.height > 2
    else {
      XCTFail("A positive visible nonpressable Search gap must be available")
      return
    }
    let point = CGPoint(x: gap.midX, y: gap.midY)
    let clear = app.buttons["Clear search"]
    guard visible.contains(point), !keyboardFrame.contains(point), !fieldFrame.contains(point),
      !controlsFrame.contains(point), !anchorFrame.contains(point),
      !clear.exists || !clear.frame.contains(point)
    else {
      XCTFail("The blank target must exclude the keyboard, input, clear and known controls")
      return
    }
    app.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: point.x - appFrame.minX, dy: point.y - appFrame.minY)
    ).tap()
  }
  private struct CatalogGeometry {
    let window: CGRect
    let viewport: CGRect
    let row: CGRect
    var offset: CGFloat { row.minY - viewport.minY }
  }
  @MainActor private func catalogGeometry(
    _ app: XCUIApplication, targetID: String, landscape: Bool, timeout: TimeInterval,
    expectedSizes: (window: CGSize, viewport: CGSize)? = nil, requiresPlayer: Bool = false
  ) -> CatalogGeometry? {
    let collection = app.collectionViews["music-collection"]
    let target = collection.buttons[targetID]
    var previous: CatalogGeometry?
    var accepted: CatalogGeometry?
    func same(_ a: CGRect, _ b: CGRect) -> Bool {
      abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
        && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }
    func rowFrame(in snapshot: any XCUIElementSnapshot) -> CGRect? {
      if snapshot.elementType == .button, snapshot.identifier == targetID { return snapshot.frame }
      for child in snapshot.children {
        if let frame = rowFrame(in: child) { return frame }
      }
      return nil
    }
    let predicate = NSPredicate { _, _ in
      MainActor.assumeIsolated {
        guard let list = try? collection.snapshot(), let row = rowFrame(in: list),
          target.isHittable,
          !requiresPlayer || app.buttons["Open now playing"].exists
        else {
          previous = nil
          return false
        }
        let current = CatalogGeometry(window: app.frame, viewport: list.frame, row: row)
        guard current.viewport.width > 0, current.viewport.height > 0,
          current.row.width > 0, current.row.height > 0,
          current.viewport.intersects(current.row),
          landscape
            ? current.window.width > current.window.height
            : current.window.height > current.window.width
        else {
          previous = nil
          return false
        }
        if let expectedSizes {
          guard abs(current.window.width - expectedSizes.window.width) < 0.5,
            abs(current.window.height - expectedSizes.window.height) < 0.5,
            abs(current.viewport.width - expectedSizes.viewport.width) < 0.5,
            abs(current.viewport.height - expectedSizes.viewport.height) < 0.5
          else {
            previous = nil
            return false
          }
        }
        defer { previous = current }
        guard let previous, same(previous.window, current.window),
          same(previous.viewport, current.viewport), same(previous.row, current.row)
        else { return false }
        accepted = current
        return true
      }
    }
    let ready = XCTNSPredicateExpectation(predicate: predicate, object: app)
    return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed ? accepted : nil
  }
  @MainActor private func registerIndexedCleanup(_ app: XCUIApplication, flag: String) {
    print("Owned indexed UI run: \(flag)")
    addTeardownBlock {
      MainActor.assumeIsolated {
        app.terminate()
        app.launchArguments = ["--fixture", "--muted", flag, "--catalog-scale-cleanup"]
        app.launch()
        XCTAssertTrue(app.buttons["Try invented music"].waitForExistence(timeout: 5))
        app.terminate()
      }
    }
  }
  @MainActor func testLongLibraryListScrollingPerformance() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    let fixtureID =
      ProcessInfo.processInfo.environment["JUKEBOX_SCROLL_TEST_ID"]
      .flatMap(UUID.init(uuidString:)) ?? UUID()
    let flag = "--catalog-scale=" + fixtureID.uuidString + ":50000"
    registerIndexedCleanup(app, flag: flag)
    app.launchArguments = ["--fixture", "--muted", flag, "--catalog-scale-ui"]
    app.launch()
    XCTAssertTrue(app.buttons["Open Album 000000"].waitForExistence(timeout: 8))
    app.tabBars.buttons["Library"].tap()
    app.buttons["music-category-Songs"].tap()
    chooseBrowseLayout(app, "List")
    let collection = app.collectionViews["music-collection"]
    let first = collection.buttons["song-scale-song-0"]
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    first.tap()
    let mini = app.buttons["mini-toggle"]
    XCTAssertTrue(mini.waitForExistence(timeout: 5))
    if mini.label == "Pause" { mini.tap() }
    let options = XCTMeasureOptions()
    options.iterationCount = 4
    measure(
      metrics: [
        XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app),
      ], options: options
    ) {
      for _ in 0..<4 { collection.swipeUp(velocity: .fast) }
    }
    let prefix = "song-scale-song-"
    func visiblePositions() -> [Int] {
      collection.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        .allElementsBoundByIndex.compactMap { row in
          guard row.isHittable else { return nil }
          return Int(row.identifier.dropFirst(prefix.count))
        }
    }
    let deepest = try XCTUnwrap(visiblePositions().max())
    XCTAssertGreaterThan(deepest, 80, "Physical swipes must cross multiple 40-song pages")
    collection.swipeDown(velocity: .fast)
    let returned = try XCTUnwrap(visiblePositions().max())
    XCTAssertLessThan(returned, deepest)
    XCTAssertTrue(mini.isHittable)
    XCTContext.runActivity(named: "Library scroll deepest=\(deepest) reverse=\(returned)") { _ in }
  }

  @MainActor func testLibraryAlbumArtworkScrollingPerformance() throws {
    try measureAlbumScrolling(layout: "List")
  }

  @MainActor func testLibraryAlbumArtworkGridScrollingPerformance() throws {
    try measureAlbumScrolling(layout: "Grid")
  }

  @MainActor private func measureAlbumScrolling(layout: String) throws {
    let app = launchMutedPlaylistFixture()
    let play = app.buttons["Play The quiet hours"]
    revealInBrowse(play, app: app)
    XCTAssertTrue(play.waitForExistence(timeout: 8))
    play.tap()
    let mini = app.buttons["mini-toggle"]
    XCTAssertTrue(mini.waitForExistence(timeout: 5))
    if mini.label == "Pause" { mini.tap() }
    app.tabBars.buttons["Library"].tap()
    app.buttons["music-category-Albums"].tap()
    chooseBrowseLayout(app, layout)
    let collection = app.collectionViews["music-collection"]
    let covers = collection.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open "))
    let first = covers.firstMatch
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    let options = XCTMeasureOptions()
    options.iterationCount = 4
    measure(
      metrics: [
        XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app),
      ], options: options
    ) {
      collection.swipeUp(velocity: .fast)
      collection.swipeUp(velocity: .fast)
      collection.swipeDown(velocity: .fast)
      collection.swipeDown(velocity: .fast)
    }
    let before = try XCTUnwrap(covers.allElementsBoundByIndex.first { $0.isHittable }).label
    collection.swipeUp(velocity: .fast)
    let after = try XCTUnwrap(covers.allElementsBoundByIndex.first { $0.isHittable }).label
    XCTAssertNotEqual(before, after)
    try assertAlbumGeometry(collection, layout: layout, window: app.frame)
    collection.swipeDown(velocity: .fast)
    try assertAlbumGeometry(collection, layout: layout, window: app.frame)
    XCTAssertTrue(mini.isHittable)
  }

  @MainActor private func assertAlbumGeometry(
    _ collection: XCUIElement, layout: String, window: CGRect
  ) throws {
    let list = try collection.snapshot()
    let bounds = list.frame
    XCTAssertEqual(bounds.minY, window.minY, accuracy: 1)
    XCTAssertEqual(bounds.maxY, window.maxY, accuracy: 1)
    func albums(_ snapshot: any XCUIElementSnapshot) -> [CGRect] {
      if snapshot.elementType == .button, snapshot.label.hasPrefix("Open ") {
        return [snapshot.frame]
      }
      return snapshot.children.flatMap { albums($0) }
    }
    let frames = albums(list).filter { !$0.isEmpty && $0.intersects(bounds) }
    let left = try XCTUnwrap(frames.map(\.minX).min())
    let column = frames.filter { abs($0.minX - left) < 2 }.sorted { $0.minY < $1.minY }
    XCTAssertGreaterThanOrEqual(column.count, 3)
    let full = column.filter { $0.minY >= bounds.minY + 1 && $0.maxY <= bounds.maxY - 1 }
    let heights = full.map(\.height).sorted()
    let height = try XCTUnwrap(heights.dropFirst(heights.count / 2).first)
    let gaps = zip(column, column.dropFirst()).map { $1.minY - $0.maxY }
    let smallestGap = try XCTUnwrap(gaps.min())
    XCTContext.runActivity(
      named:
        "Library \(layout) covers=\(column.count) height=\(height) min_gap=\(smallestGap) viewport=\(bounds.minY),\(bounds.maxY)"
    ) { _ in }
    for frame in full {
      XCTAssertEqual(frame.height, height, accuracy: 1, "Album target at \(frame) in \(layout)")
      if layout == "Grid" { XCTAssertEqual(frame.width, frame.height, accuracy: 2) }
    }
    XCTAssertGreaterThanOrEqual(smallestGap, -1, "Adjacent album targets overlap in \(column)")
  }

  @MainActor func testIndexedCatalogScrollSearchAndBack() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    let flag = "--catalog-scale=" + UUID().uuidString + ":100000"
    app.launchArguments = ["--fixture", "--muted", flag, "--catalog-scale-ui"]
    registerIndexedCleanup(app, flag: flag)
    app.launch()
    XCTAssertTrue(app.buttons["Open Album 000000"].waitForExistence(timeout: 8))
    app.tabBars.buttons["Library"].tap()
    app.buttons["music-category-Songs"].tap()
    let collection = app.collectionViews["music-collection"]
    XCTAssertTrue(collection.buttons["song-scale-song-0"].waitForExistence(timeout: 5))
    collection.swipeUp()
    let visible = try XCTUnwrap(
      collection.buttons.allElementsBoundByIndex.first {
        $0.identifier.hasPrefix("song-scale-song-") && $0.isHittable
          && collection.frame.contains($0.frame)
      })
    let anchor = visible.identifier
    let before = visible.frame.minY
    XCTAssertNotEqual(
      anchor, "song-scale-song-0", "Actual native scroll must move beyond the first row")
    openSearch(app)
    app.buttons["search-filter-Songs"].tap()
    let search = app.textFields["global-search-field"]
    search.tap()
    search.typeText("Song 099999\n")
    XCTAssertTrue(app.buttons["Actions for Song 099999"].waitForExistence(timeout: 5))
    app.buttons["Actions for Song 099999"].tap()
    app.buttons["Go to album"].tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Album 024999"].exists)
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertEqual(search.value as? String, "Song 099999")
    XCTAssertTrue(app.buttons["search-filter-Songs"].isSelected)
    app.buttons["Clear search"].tap()
    dismissSearchKeyboard(app)
    app.tabBars.buttons["Library"].tap()
    let returned = collection.buttons[anchor]
    XCTAssertTrue(returned.waitForExistence(timeout: 3))
    XCTAssertTrue(returned.isHittable)
    XCTAssertEqual(returned.frame.minY, before, accuracy: 3)
    XCTAssertFalse(
      app.buttons["Open now playing"].exists, "Browse-only workload must not start audio")
    capture("indexed-100000-native-search-back", app: app)
  }

  @MainActor func testRecentlyPlayedIsFirstAndOpensCanonicalAlbum() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted"]
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.staticTexts["Recently added"].exists)
    revealInBrowse(app.buttons["Open The quiet hours"], app: app)
    app.buttons["Open The quiet hours"].tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
    app.buttons["Play album"].tap()
    app.navigationBars.buttons.element(boundBy: 0).tap()
    let recent = app.staticTexts["Recently played"]
    XCTAssertTrue(recent.waitForExistence(timeout: 8))
    XCTAssertLessThan(recent.frame.minY, app.staticTexts["Discover"].frame.minY)
    revealInBrowse(app.buttons["Open recent album The quiet hours"], app: app, up: false)
    XCTAssertTrue(app.buttons["Open recent album The quiet hours"].isHittable)
    XCTAssertTrue(app.buttons["Play recent album The quiet hours"].isHittable)
    capture("home-recently-played", app: app)
    app.buttons["Open recent album The quiet hours"].tap()
    XCTAssertTrue(app.staticTexts["album-heading"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Play album"].exists)
    if app.buttons["mini-toggle"].label == "Pause" { app.buttons["mini-toggle"].tap() }
    app.buttons["North Window"].tap()
    XCTAssertTrue(app.staticTexts["artist-heading"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 5))
    capture("artist-shared-identity", app: app)
  }

  @MainActor func testOverflowTextMotionLifecycleAndStableActions() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = [
      "--fixture", "--muted", "--transport-ui=" + UUID().uuidString, "--text-layout",
      "--appearance-dark",
    ]
    app.launch()
    let title = app.staticTexts["text-motion-reading"]
    let action = app.buttons["text-motion-action"]
    func waitValue(_ value: String, _ selected: XCUIElement? = nil) {
      let element = selected ?? title
      let condition = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", value), object: element)
      XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 4), .completed)
    }
    func pixels() throws -> Data {
      let screenshot = app.screenshot()
      let image = try XCTUnwrap(screenshot.image.cgImage)
      let factor = CGFloat(image.width) / app.frame.width
      let bounds = title.frame.insetBy(dx: 2, dy: 1)
      let crop = CGRect(
        x: bounds.minX * factor, y: bounds.minY * factor,
        width: bounds.width * factor, height: bounds.height * factor)
      return try XCTUnwrap(image.cropping(to: crop)).dataProvider!.data! as Data
    }
    capture("overflow-text-initial", app: app)
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts.matching(identifier: "text-motion-reading").count, 1)
    waitValue("moving")
    let initial = title.frame
    let actionFrame = action.frame
    let first = try pixels()
    Thread.sleep(forTimeInterval: 2.2)
    XCTAssertNotEqual(try pixels(), first, "Actual rendered glyphs must move inside the same slot")
    XCTAssertEqual(title.frame, initial)
    XCTAssertEqual(action.frame, actionFrame)
    waitValue("static", app.staticTexts["text-motion-short"])
    waitValue("static", app.staticTexts["text-motion-browse"])
    capture("overflow-text-moving", app: app)
    for control in ["Eligibility", "Parent allowance", "Reduce motion", "VoiceOver", "Scene phase"]
    {
      app.buttons[control].tap()
      waitValue("static")
      let still = try pixels()
      Thread.sleep(forTimeInterval: 0.35)
      XCTAssertEqual(try pixels(), still, "Suppressed motion must actually stop: " + control)
      XCTAssertEqual(title.frame, initial)
      XCTAssertEqual(action.frame, actionFrame)
      app.buttons[control].tap()
      waitValue("moving")
    }
    app.buttons["Rename"].tap()
    XCTAssertTrue(
      title.label.hasPrefix("A different name"), "Reused identity must expose fresh full text")
    waitValue("moving")
    app.buttons["Width"].tap()
    waitValue("moving")
    XCTAssertGreaterThan(title.frame.width, initial.width)
    app.buttons["Font"].tap()
    waitValue("moving")
    XCTAssertGreaterThan(title.frame.height, initial.height)
    app.buttons["Direction"].tap()
    waitValue("moving")
    let fade = app.descendants(matching: .any)["text-fade-witness"]
    let shot = app.screenshot()
    let bitmap = try XCTUnwrap(shot.image.cgImage)
    let scale = CGFloat(bitmap.width) / app.frame.width
    func brightness(_ point: CGPoint) throws -> Int {
      let crop = try XCTUnwrap(
        bitmap.cropping(
          to: CGRect(
            x: point.x * scale, y: point.y * scale, width: 1, height: 1)))
      var rgba = [UInt8](repeating: 0, count: 4)
      let context = try XCTUnwrap(
        CGContext(
          data: &rgba, width: 1, height: 1,
          bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      return Int(rgba[0]) + Int(rgba[1]) + Int(rgba[2])
    }
    XCTAssertLessThan(
      try brightness(CGPoint(x: fade.frame.minX + 1, y: fade.frame.midY)),
      try brightness(CGPoint(x: fade.frame.maxX - 1, y: fade.frame.midY)) - 300,
      "RTL must fade at trailing/left, retaining the leading/right edge")
    capture("overflow-text-rtl-renamed-resized", app: app)
    action.tap()
    XCTAssertEqual(app.staticTexts["text-action-count"].label, "Actions: 1")
    let scroll = app.scrollViews["text-motion-scroll"]
    scroll.swipeUp()
    XCTAssertFalse(title.isHittable)
    waitValue("static")
    scroll.swipeDown()
    waitValue("moving")
    app.buttons["Retire"].tap()
    XCTAssertFalse(title.exists)
    app.buttons["Retire"].tap()
    waitValue("moving")
    app.terminate()
  }

  @MainActor func testLongSoundtrackRowsKeepCompactIndependentActions() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    let title =
      "The crossing — Original motion picture soundtrack · Complete orchestral score and extended recording (anniversary remastered edition)"
    var normalHeight: CGFloat = 0
    for large in [false, true] {
      app.launchArguments =
        ["--fixture", "--muted"] + (large ? ["--large-text", "--appearance-dark"] : [])
      app.launch()
      XCTAssertTrue(
        app.buttons[
          "Open Tides and timber · Complete orchestral soundtrack and extended anniversary edition"
        ].waitForExistence(timeout: 8))
      app.buttons[
        "Open Tides and timber · Complete orchestral soundtrack and extended anniversary edition"
      ].tap()
      let row = app.buttons["song-fixture-album-2-track-0"]
      XCTAssertTrue(row.waitForExistence(timeout: 5))
      let more = app.buttons["song-actions-fixture-album-2-track-0"]
      if large && !more.isHittable { app.scrollViews.firstMatch.swipeUp() }
      XCTAssertEqual(row.label, "Play " + title)
      XCTAssertGreaterThanOrEqual(row.frame.height, 44)
      XCTAssertGreaterThanOrEqual(more.frame.width, 44)
      XCTAssertLessThanOrEqual(row.frame.maxX, more.frame.minX + 1)
      XCTAssertLessThanOrEqual(more.frame.maxX, app.frame.maxX)
      if large {
        XCTAssertGreaterThan(row.frame.height, normalHeight)
      } else {
        normalHeight = row.frame.height
        XCTAssertLessThanOrEqual(normalHeight, 80)
      }
      capture(large ? "soundtrack-row-accessibility" : "soundtrack-row-compact", app: app)
      more.tap()
      XCTAssertTrue(app.buttons["Play next"].waitForExistence(timeout: 3))
      app.terminate()
    }
  }

  @MainActor func testRecentlyPlayedShowsSixAcceptedAlbumsWithIndependentActions() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--appearance-dark"]
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    app.tabBars.buttons["Library"].tap()
    let albums = [
      ("The quiet hours", "North Window"),
      ("A field guide to distant weather", "Mira Sol"),
      (
        "Tides and timber · Complete orchestral soundtrack and extended anniversary edition",
        "The Lantern Quartet"
      ),
      ("After the last train", "Étienne Marchand"),
      ("Soft geometry", "Aki Sato"),
      ("The river remembers", "Elena & the Satellites"),
      ("Small hours, wide skies", "North Window"),
    ]
    for (title, artist) in albums {
      let play = app.buttons["Play " + title]
      for _ in 0..<6 where !play.isHittable { app.scrollViews["music-collection"].swipeUp() }
      XCTAssertTrue(play.isHittable, title)
      play.tap()
      let accepted = NSPredicate(format: "label == %@", artist)
      expectation(for: accepted, evaluatedWith: app.staticTexts["mini-artist"])
      waitForExpectations(timeout: 8)
      XCTAssertEqual(app.buttons["mini-toggle"].label, "Pause")
      app.buttons["mini-toggle"].tap()
    }
    app.tabBars.buttons["Home"].tap()
    let recent = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Open recent album "))
    expectation(for: NSPredicate(format: "count == 6"), evaluatedWith: recent)
    waitForExpectations(timeout: 5)
    XCTAssertFalse(app.buttons["Open recent album The quiet hours"].exists)
    XCTAssertEqual(recent.element(boundBy: 0).label, "Open recent album Small hours, wide skies")
    for index in 0..<recent.count { XCTAssertTrue(recent.element(boundBy: index).isHittable) }
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Play recent album ")).count,
      6)
    capture("home-six-recent-albums", app: app)
  }

  @MainActor func testMusicMetadataDisclosureAndSharedConnectionSurface() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    for large in [false, true] {
      app.launchArguments =
        ["--fixture", "--muted"]
        + (large ? ["--appearance-dark", "--large-text"] : ["--appearance-light"])
      app.launch()
      XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
      app.buttons["Open The quiet hours"].tap()
      let details = app.buttons["Album details"]
      XCTAssertTrue(details.waitForExistence(timeout: 5))
      XCTAssertEqual(details.value as? String, "Collapsed")
      details.tap()
      XCTAssertTrue(app.staticTexts["Release year"].waitForExistence(timeout: 3))
      XCTAssertTrue(app.staticTexts["1998"].exists)
      XCTAssertTrue(app.staticTexts["Discs"].exists)
      XCTAssertTrue(app.staticTexts["music-overview"].exists)
      capture(large ? "album-metadata-accessibility" : "album-metadata-expanded", app: app)
      details.tap()
      XCTAssertFalse(app.staticTexts["music-overview"].exists)
      app.buttons["North Window"].tap()
      let about = app.buttons["artist-information"]
      XCTAssertTrue(about.waitForExistence(timeout: 5))
      about.tap()
      XCTAssertTrue(app.staticTexts["music-overview"].waitForExistence(timeout: 5))
      capture(large ? "artist-about-accessibility" : "artist-about-expanded", app: app)
      app.buttons["close-artist-information"].tap()
      XCTAssertFalse(app.staticTexts["music-overview"].exists)
      app.buttons["Accounts"].tap()
      app.buttons["Connection details"].tap()
      XCTAssertTrue(app.staticTexts["connection-server-address"].waitForExistence(timeout: 5))
      capture("connection-shared-surface", app: app)
      app.buttons["Done"].tap()
      app.terminate()
      app.launchArguments = ["--connect"]
      app.launch()
      XCTAssertTrue(app.textFields["sign-in-server"].waitForExistence(timeout: 5))
      capture(large ? "connect-shared-accessibility" : "connect-shared-surface", app: app)
      app.terminate()
    }
  }

  @MainActor private func assertContinuousBrowseCanvas(
    _ app: XCUIApplication, controls: XCUIElement, viewport: XCUIElement
  ) throws {
    let media = app.buttons["media-picker"]
    let image = try XCTUnwrap(app.screenshot().image.cgImage)
    func color(_ y: CGFloat) throws -> [Int] {
      try screenColor(image, screen: app.frame, y: y)
    }
    let canvas = try color(max(viewport.frame.minY, controls.frame.maxY) + 18)
    for sample in [try color(media.frame.midY), try color(controls.frame.midY)] {
      for channel in 0..<3 {
        XCTAssertLessThanOrEqual(
          abs(sample[channel] - canvas[channel]), 3,
          "Header and content should share the canvas color")
      }
    }
  }

  @MainActor private func screenColor(
    _ image: CGImage, screen: CGRect, xOffset: CGFloat = 6, y: CGFloat
  )
    throws
    -> [Int]
  {
    let scale = CGFloat(image.width) / screen.width
    let rect = CGRect(
      x: (xOffset - 1) * scale, y: (y - screen.minY - 1) * scale,
      width: 2 * scale, height: 2 * scale
    ).integral
    let sample = try XCTUnwrap(image.cropping(to: rect))
    var rgba = [UInt8](repeating: 0, count: 4)
    try rgba.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(
        CGContext(
          data: bytes.baseAddress, width: 1, height: 1,
          bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return rgba.prefix(3).map(Int.init)
  }

  @MainActor private func showsFixturePlaylistArtwork(_ card: XCUIElement) -> Bool {
    guard let image = card.screenshot().image.cgImage else { return false }
    let side = min(image.width, image.height)
    guard side > 32, let cover = image.cropping(to: CGRect(x: 0, y: 0, width: side, height: side))
    else { return false }
    var rgba = [UInt8](repeating: 0, count: 24 * 24 * 4)
    return rgba.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: 24, height: 24,
          bitsPerComponent: 8, bytesPerRow: 96, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(cover, in: CGRect(x: 0, y: 0, width: 24, height: 24))
      var blue = 0
      var gold = 0
      for i in stride(from: 0, to: buffer.count, by: 4) {
        let r = Int(buffer[i])
        let g = Int(buffer[i + 1])
        let b = Int(buffer[i + 2])
        if r < 120, b > r + 20, g > r + 8 { blue += 1 }
        if r > 165, g > 145, r > b + 30, g > b + 15 { gold += 1 }
      }
      return blue > 100 && gold > 12
    }
  }

  @MainActor private func launchMutedPlaylistFixture(slow: Bool = false, longAlbum: Bool = false)
    -> XCUIApplication
  {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--transport-ui=" + UUID().uuidString]
    if slow { app.launchArguments.append("--slow-fixture") }
    if longAlbum { app.launchArguments.append("--long-album") }
    addTeardownBlock { MainActor.assumeIsolated { app.terminate() } }
    app.launch()
    return app
  }

  @MainActor private func dragBrowsePage(_ app: XCUIApplication, points: CGFloat) {
    let start = app.coordinate(
      withNormalizedOffset: CGVector(dx: 0.48, dy: points < 0 ? 0.71 : 0.34))
    start.press(
      forDuration: 0.10, thenDragTo: start.withOffset(CGVector(dx: 0, dy: points)),
      withVelocity: .slow, thenHoldForDuration: 0.18)
  }

  @MainActor private func revealInBrowse(
    _ element: XCUIElement, app: XCUIApplication, up: Bool = true
  ) {
    let top = app.navigationBars.firstMatch.frame.maxY
    let mini = app.buttons["Open now playing"]
    let bottom = mini.exists ? mini.frame.minY : app.tabBars.firstMatch.frame.minY
    for _ in 0..<12 {
      if element.exists, !element.frame.isEmpty, element.frame.midY > top + 4,
        element.frame.midY < bottom - 4, element.isHittable
      {
        return
      }
      dragBrowsePage(app, points: (up ? -1 : 1) * min(240, app.frame.height * 0.28))
    }
    XCTFail("Scroll view did not reveal " + element.description)
  }

  @MainActor func testHomeGlassShelvesResumeBothAxesAfterAlbumBack() throws {
    let app = launchMutedPlaylistFixture()
    let scroll = app.scrollViews["home-scroll"]
    XCTAssertTrue(scroll.waitForExistence(timeout: 8))
    let play = scroll.buttons["Play The quiet hours"]
    XCTAssertTrue(scroll.staticTexts["home-heading-recent"].waitForExistence(timeout: 5))
    capture("home-glass-overview", app: app)
    revealInBrowse(play, app: app)
    play.tap()
    let mini = app.buttons["Open now playing"]
    XCTAssertTrue(mini.waitForExistence(timeout: 6))
    let toggle = app.buttons["mini-toggle"]
    if toggle.label == "Pause" { toggle.tap() }
    let rail = scroll.scrollViews["home-rail-discover"]
    revealInBrowse(rail, app: app)
    XCTAssertEqual(scroll.frame.minY, app.frame.minY, accuracy: 1)
    XCTAssertEqual(scroll.frame.maxY, app.frame.maxY, accuracy: 1)
    let railCenter = rail.frame.midY
    let start = app.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: app.frame.width * 0.85, dy: railCenter))
    start.press(
      forDuration: 0.10, thenDragTo: start.withOffset(CGVector(dx: -app.frame.width * 0.62, dy: 0)),
      withVelocity: .slow, thenHoldForDuration: 0.25)
    let bounds = app.frame
    let upper = app.navigationBars.firstMatch.frame.maxY
    let lower = mini.frame.minY
    let selected = try XCTUnwrap(
      try browseRows(rail).first { row in
        row.label.hasPrefix("Open ") && row.label != "Open The quiet hours"
          && !row.frame.isEmpty && row.frame.minX >= bounds.minX && row.frame.maxX <= bounds.maxX
          && row.frame.midY > upper && row.frame.midY < lower
      }?.label)
    let open = rail.buttons[selected]
    XCTAssertTrue(open.isHittable)
    let before = open.frame
    open.tap()
    let heading = app.staticTexts["album-heading"]
    XCTAssertTrue(heading.waitForExistence(timeout: 5))
    XCTAssertEqual(heading.label, String(selected.dropFirst(5)))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    let returned = rail.buttons[selected]
    XCTAssertTrue(returned.waitForExistence(timeout: 5))
    let after = returned.frame
    XCTContext.runActivity(
      named: "Home Back x=\(before.minX),\(after.minX) y=\(before.minY),\(after.minY)"
    ) { _ in }
    XCTAssertEqual(before.minX, after.minX, accuracy: 2)
    XCTAssertEqual(before.minY, after.minY, accuracy: 2)
    XCTAssertTrue(returned.isHittable)
    var underHeader = false
    var underPlayer = false
    for step in 0..<12 {
      let rails = ["favorites", "playlists", "discover", "artists", "genres"].map {
        scroll.scrollViews["home-rail-" + $0]
      }
      for visible in rails where visible.exists {
        let rect = visible.frame
        if rect.height > 24 {
          underHeader = underHeader || (rect.minY < upper - 5 && rect.maxY > upper + 5)
          underPlayer = underPlayer || (rect.minY < lower - 5 && rect.maxY > lower + 5)
        }
      }
      if underHeader && underPlayer { break }
      dragBrowsePage(app, points: step < 6 ? -82 : 89)
    }
    XCTAssertTrue(underHeader)
    XCTAssertTrue(underPlayer)
    XCTAssertEqual(toggle.label, "Play")
    capture("home-glass-shelves", app: app)
  }

  @MainActor func testHomeReordersHidesAndRestoresSixSections() throws {
    let app = launchMutedPlaylistFixture()
    let editor = app.buttons["home-customize"]
    XCTAssertTrue(editor.waitForExistence(timeout: 8))
    editor.tap()
    let titles = [
      "Recently played", "Favorites", "Your playlists", "Discover", "Artists", "Genres",
    ]
    let order = titles.map { app.buttons["Move " + $0] }
    XCTAssertTrue(order.last!.waitForExistence(timeout: 5))
    for (earlier, later) in zip(order, order.dropFirst()) {
      XCTAssertLessThan(earlier.frame.midY, later.frame.midY)
    }
    app.buttons["Move Your playlists"].tap()
    app.buttons["Move earlier"].tap()
    app.buttons["Hide Discover"].tap()
    XCTAssertTrue(app.buttons["Show Discover"].exists)
    app.buttons["Done"].tap()
    let favorites = app.staticTexts["home-heading-favorites"]
    let playlists = app.staticTexts["home-heading-playlists"]
    XCTAssertTrue(playlists.waitForExistence(timeout: 5))
    XCTAssertLessThan(playlists.frame.minY, favorites.frame.minY)
    XCTAssertFalse(app.staticTexts["home-heading-discover"].exists)
    app.tabBars.buttons["Library"].tap()
    app.tabBars.buttons["Home"].tap()
    editor.tap()
    XCTAssertTrue(app.buttons["Show Discover"].exists)
    XCTAssertLessThan(
      app.buttons["Move Your playlists"].frame.midY, app.buttons["Move Favorites"].frame.midY)
    app.buttons["Restore default layout"].tap()
    app.buttons["Done"].tap()
    XCTAssertTrue(app.staticTexts["home-heading-discover"].waitForExistence(timeout: 5))
    XCTAssertLessThan(favorites.frame.minY, playlists.frame.minY)
  }

  @MainActor func testHomeOpensPlaylistArtistAndPagedGenreAlbums() throws {
    let app = launchMutedPlaylistFixture()
    let home = app.scrollViews["home-scroll"]
    XCTAssertTrue(home.waitForExistence(timeout: 8))
    let playlists = home.scrollViews["home-rail-playlists"]
    revealInBrowse(playlists, app: app)
    let playlist = playlists.buttons.firstMatch
    XCTAssertTrue(playlist.waitForExistence(timeout: 5))
    let title = String(playlist.label.dropFirst("Open playlist ".count))
    playlist.tap()
    XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    let artist = home.buttons["Open North Window"].firstMatch
    revealInBrowse(artist, app: app)
    artist.tap()
    XCTAssertTrue(app.staticTexts["artist-heading"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["artist-heading"].label, "North Window")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    let genre = home.buttons["Open genre Instrumental"]
    revealInBrowse(genre, app: app)
    genre.tap()
    XCTAssertTrue(app.navigationBars["Instrumental"].waitForExistence(timeout: 5))
    let album = app.buttons["Open The quiet hours"]
    XCTAssertTrue(album.waitForExistence(timeout: 5))
    album.tap()
    XCTAssertTrue(app.staticTexts["album-heading"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["album-heading"].label, "The quiet hours")
  }

  @MainActor private func openNorthWindow(_ app: XCUIApplication) {
    let album = app.buttons["Open The quiet hours"].firstMatch
    XCTAssertTrue(album.waitForExistence(timeout: 8))
    revealInBrowse(album, app: app)
    album.tap()
    let artist = app.buttons["North Window"]
    XCTAssertTrue(artist.waitForExistence(timeout: 6))
    artist.tap()
    let name = app.staticTexts["artist-heading"]
    XCTAssertTrue(name.waitForExistence(timeout: 6))
    XCTAssertEqual(name.label, "North Window")
  }

  @MainActor func testArtistPortraitGlassEdgesAndAlbumBack() throws {
    let app = launchMutedPlaylistFixture()
    openNorthWindow(app)
    let scroll = app.scrollViews["artist-scroll"]
    let heading = app.staticTexts["artist-heading"]
    let highlight = scroll.buttons["artist-highlight-fixture-track-2"]
    XCTAssertTrue(highlight.waitForExistence(timeout: 6))
    let screen = app.frame
    let viewport = scroll.frame
    XCTAssertEqual(viewport.minY, screen.minY, accuracy: 1)
    XCTAssertEqual(viewport.maxY, screen.maxY, accuracy: 1)
    var rgb: [Int] = []
    let y = app.navigationBars.firstMatch.frame.maxY + 34
    for _ in 0..<5 {
      rgb = try screenColor(XCTUnwrap(app.screenshot().image.cgImage), screen: screen, y: y)
      if rgb[0] > rgb[2] + 25 { break }
    }
    XCTAssertGreaterThan(rgb[0], rgb[2] + 25)
    capture("artist-portrait", app: app)
    highlight.tap()
    let toggle = app.buttons["mini-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if toggle.label == "Pause" { toggle.tap() }
    XCTAssertEqual(toggle.label, "Play")
    let mini = app.buttons["Open now playing"]
    let startingTitle = heading.frame
    var behindHeader = false
    var behindMini = false
    for step in 0..<12 {
      let headerY = app.navigationBars.firstMatch.frame.maxY
      let bottomY = mini.frame.minY
      if heading.frame.minY < headerY && heading.frame.midY < startingTitle.midY - 30 {
        behindHeader = true
      }
      for row in try browseRows(scroll)
      where row.id.hasPrefix("artist-highlight-") || row.label.hasPrefix("Open ") {
        if row.frame.minY < bottomY - 1 && row.frame.maxY > bottomY + 1 { behindMini = true }
      }
      if behindHeader && behindMini { break }
      dragBrowsePage(app, points: step.isMultiple(of: 2) ? -78 : -99)
    }
    XCTAssertTrue(behindHeader)
    XCTAssertTrue(behindMini)
    let release = scroll.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open "))
      .firstMatch
    revealInBrowse(release, app: app)
    let anchor = release.frame.midY
    let label = release.label
    capture("artist-discography", app: app)
    release.tap()
    XCTAssertTrue(app.staticTexts["album-heading"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["album-heading"].label, String(label.dropFirst(5)))
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(release.waitForExistence(timeout: 5))
    let restored = release.frame.midY
    XCTAssertEqual(restored, anchor, accuracy: 2)
    XCTAssertEqual(toggle.label, "Play")
    XCTContext.runActivity(
      named:
        "Artist portrait rgb=\(rgb) viewport=\(viewport.minY),\(viewport.maxY) anchor=\(anchor),\(restored)"
    ) { _ in }
  }

  @MainActor func testArtistMostPlayedOrderPlayShuffleAndAllSongs() throws {
    let app = launchMutedPlaylistFixture()
    openNorthWindow(app)
    let scroll = app.scrollViews["artist-scroll"]
    XCTAssertTrue(scroll.staticTexts["Your most played"].waitForExistence(timeout: 6))
    let expected = [
      "fixture-track-2", "fixture-album-6-track-1", "fixture-track-0",
      "fixture-album-12-track-3", "fixture-album-18-track-0",
    ]
    let rows = try browseRows(scroll).filter { $0.id.hasPrefix("artist-highlight-") }
    XCTAssertEqual(rows.map(\.id), expected.map { "artist-highlight-" + $0 })
    let play = app.buttons["artist-play"]
    func waitLabel(_ element: XCUIElement, _ value: String) {
      expectation(for: NSPredicate(format: "label == %@", value), evaluatedWith: element)
      waitForExpectations(timeout: 6)
    }
    play.tap()
    waitLabel(play, "Pause artist")
    waitLabel(app.staticTexts["mini-title"], "Slow current")
    play.tap()
    waitLabel(app.buttons["mini-toggle"], "Play")
    app.buttons["artist-shuffle"].tap()
    waitLabel(play, "Pause artist")
    play.tap()
    waitLabel(app.buttons["mini-toggle"], "Play")
    let song = scroll.buttons["artist-highlight-fixture-track-0"]
    revealInBrowse(song, app: app)
    song.tap()
    waitLabel(app.staticTexts["mini-title"], "First light")
    app.buttons["mini-toggle"].tap()
    let all = app.buttons["artist-all-songs"]
    revealInBrowse(all, app: app, up: false)
    all.tap()
    XCTAssertTrue(app.buttons["song-fixture-track-0"].firstMatch.waitForExistence(timeout: 6))
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(scroll.staticTexts["Your most played"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["mini-toggle"].label, "Play")
  }

  @MainActor func testTrackOnlyArtistInLibraryAndSearchPlaysCreditedAppearance() throws {
    let app = launchMutedPlaylistFixture()
    app.tabBars.buttons["Library"].tap()
    app.buttons["music-category-Artists"].tap()
    let guest = app.buttons["artist-fixture-track-guest"].firstMatch
    for _ in 0..<4 where !guest.isHittable { app.swipeUp() }
    XCTAssertTrue(guest.isHittable)
    guest.tap()
    let songsHeading = app.scrollViews["artist-scroll"].staticTexts["Songs"]
    XCTAssertTrue(songsHeading.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Your most played"].exists)
    let image = try XCTUnwrap(app.screenshot().image.cgImage)
    let fallback = try screenColor(
      image, screen: app.frame, y: app.navigationBars.firstMatch.frame.maxY + 34)
    XCTAssertGreaterThan(fallback[2], fallback[0])
    capture("artist-without-portrait", app: app)
    XCTAssertTrue(app.staticTexts["Appears On"].waitForExistence(timeout: 5))
    let first = app.buttons["song-fixture-album-1-track-0"]
    let second = app.buttons["song-fixture-album-1-track-1"]
    XCTAssertTrue(first.exists)
    XCTAssertTrue(second.exists)
    XCTAssertFalse(app.buttons["song-fixture-album-1-track-2"].exists)
    openSearch(app)
    app.textFields["global-search-field"].firstMatch.typeText("Juniper Brass\n")
    XCTAssertTrue(guest.waitForExistence(timeout: 5))
    guest.tap()
    XCTAssertTrue(second.waitForExistence(timeout: 5))
    revealInBrowse(second, app: app)
    XCTAssertTrue(second.isHittable)
    second.tap()
    let player = app.buttons["Open now playing"]
    XCTAssertTrue(player.waitForExistence(timeout: 6))
    let selected = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH %@", "A place to return,"), object: player)
    XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 6), .completed)
    player.tap()
    let toggle = app.buttons["player-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 6))
    XCTAssertEqual(toggle.label, "Pause")
  }
  @MainActor func testLibraryAndSearchKeepFirstRowsVisibleAndShowPlaylistCovers() throws {
    let app = launchMutedPlaylistFixture()
    let library = app.tabBars.buttons["Library"]
    library.tap()
    let sections = ["Albums", "Artists", "Songs", "Playlists"].map {
      app.buttons["music-category-" + $0]
    }
    let playlists = sections[3]
    XCTAssertTrue(playlists.waitForExistence(timeout: 8))
    for section in sections {
      XCTAssertTrue(section.isHittable)
      XCTAssertGreaterThanOrEqual(section.frame.height, 44)
    }
    for (left, right) in zip(sections, sections.dropFirst()) {
      XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX + 1)
    }
    let filter = app.buttons["music-sort-filter"]
    XCTAssertTrue(filter.exists)
    let collection = app.collectionViews["music-collection"]
    for layout in ["Grid", "List"] {
      chooseBrowseLayout(app, layout)
      for category in ["Albums", "Artists", "Songs"] {
        let tab = app.buttons["music-category-" + category]
        if !tab.isSelected { tab.tap() }
        let predicate: NSPredicate
        switch category {
        case "Albums": predicate = NSPredicate(format: "label BEGINSWITH %@", "Open ")
        case "Artists": predicate = NSPredicate(format: "identifier BEGINSWITH %@", "artist-")
        default:
          predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)", "song-",
            "song-actions-")
        }
        let first = collection.buttons.matching(predicate).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5), category + " " + layout)
        XCTAssertTrue(first.isHittable)
        XCTAssertLessThan(
          collection.frame.minY, playlists.frame.midY,
          "The scroll view must extend beneath Library controls: "
            + String(describing: collection.frame))
        XCTAssertGreaterThanOrEqual(first.frame.minY, playlists.frame.maxY - 1)
      }
    }
    capture("library-categories-at-rest", app: app, screen: true)
    let searchTab = app.tabBars.buttons["Search"]
    searchTab.tap()
    let searchControls = app.descendants(matching: .any)["search-browse-controls"].firstMatch
    let results = app.scrollViews["music-collection"]
    XCTAssertTrue(results.waitForExistence(timeout: 5))
    XCTAssertTrue(searchControls.exists)
    XCTAssertEqual(results.frame.minY, app.frame.minY, accuracy: 1)
    XCTAssertEqual(results.frame.maxY, app.frame.maxY, accuracy: 1)
    XCTAssertGreaterThanOrEqual(
      app.staticTexts["Search your music"].frame.minY, searchControls.frame.maxY - 1)
    try assertContinuousBrowseCanvas(app, controls: searchControls, viewport: results)
    library.tap()
    chooseBrowseLayout(app, "Grid")
    playlists.tap()
    XCTAssertTrue(playlists.isSelected)
    XCTAssertFalse(filter.exists)
    XCTAssertTrue(library.isSelected)
    let morning = app.descendants(matching: .any)["playlist-fixture-playlist-morning"].firstMatch
    XCTAssertTrue(morning.waitForExistence(timeout: 5))
    let playlistScroll = app.scrollViews["playlist-collection"]
    XCTAssertLessThan(playlistScroll.frame.minY, playlists.frame.midY)
    XCTAssertGreaterThanOrEqual(morning.frame.minY, playlists.frame.maxY - 1)
    XCTAssertLessThan(morning.frame.minY - playlists.frame.maxY, 40)
    XCTAssertEqual(morning.label, "Morning rotation")
    XCTAssertEqual(morning.value as? String, "3 songs")
    let deadline = Date().addingTimeInterval(6)
    var hasArtwork = showsFixturePlaylistArtwork(morning)
    while !hasArtwork && Date() < deadline { hasArtwork = showsFixturePlaylistArtwork(morning) }
    XCTAssertTrue(hasArtwork, "The playlist card should display its square cover")
    chooseBrowseLayout(app, "List")
    XCTAssertTrue(morning.isHittable)
    XCTAssertGreaterThan(morning.frame.width, morning.frame.height * 2)
  }

  @MainActor private func browseRows(_ results: XCUIElement) throws
    -> [(label: String, id: String, frame: CGRect)]
  {
    func rows(in node: any XCUIElementSnapshot) -> [(String, String, CGRect)] {
      if node.elementType == .button,
        node.label.hasPrefix("Open ")
          || node.identifier.hasPrefix("artist-highlight-")
          || node.identifier.hasPrefix("playlist-track-")
          || (node.identifier.hasPrefix("song-") && !node.identifier.hasPrefix("song-actions-"))
      {
        return [(node.label, node.identifier, node.frame)]
      }
      return node.children.flatMap { rows(in: $0) }
    }
    return rows(in: try results.snapshot())
  }

  @MainActor func testSearchGlassReturnsToMixedAndFilteredResults() throws {
    let app = launchMutedPlaylistFixture()
    let play = app.buttons["Play The quiet hours"]
    revealInBrowse(play, app: app)
    XCTAssertTrue(play.waitForExistence(timeout: 8))
    play.tap()
    let miniToggle = app.buttons["mini-toggle"]
    XCTAssertTrue(miniToggle.waitForExistence(timeout: 5))
    if miniToggle.label == "Pause" { miniToggle.tap() }
    openSearch(app)
    let field = app.textFields["global-search-field"]
    field.typeText("North Window\n")
    assertSearchKeyboardDismissed(app)
    let results = app.scrollViews["music-collection"]
    let controls = app.otherElements["search-browse-controls"].firstMatch
    let mini = app.buttons["Open now playing"]
    let firstArtist = results.buttons["Open artist North Window"]
    XCTAssertTrue(firstArtist.waitForExistence(timeout: 6))
    XCTAssertGreaterThanOrEqual(firstArtist.frame.minY, controls.frame.maxY - 1)
    XCTAssertGreaterThanOrEqual(firstArtist.frame.minX, 15)
    XCTAssertEqual(results.frame.minY, app.frame.minY, accuracy: 1)
    XCTAssertEqual(results.frame.maxY, app.frame.maxY, accuracy: 1)
    for filter in ["All", "Albums"] {
      let tab = app.buttons["search-filter-" + filter]
      if !tab.isSelected { tab.tap() }
      let upper = controls.frame.maxY
      let lower = mini.frame.minY
      let start = results.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.68))
      let end = results.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
      var albums: [(label: String, id: String, frame: CGRect)] = []
      for _ in 0..<3 {
        start.press(
          forDuration: 0.12, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        let rows = try browseRows(results)
        albums = rows.filter {
          $0.label.hasPrefix("Open ") && !$0.label.hasPrefix("Open artist ")
            && $0.frame.minY >= upper && $0.frame.maxY <= lower
        }
        if !albums.isEmpty { break }
      }
      let label = try XCTUnwrap(albums.first?.label)
      let selected = results.buttons[label].firstMatch
      XCTAssertTrue(selected.isHittable)
      let before = selected.frame.minY
      let rows = try browseRows(results)
      XCTAssertTrue(rows.contains { $0.frame.minY < upper && $0.frame.maxY > results.frame.minY })
      if filter == "Albums" {
        XCTAssertTrue(rows.contains { $0.frame.maxY > lower && $0.frame.minY < results.frame.maxY })
        capture("search-glass-both-edges", app: app)
      }
      selected.tap()
      let detail = app.staticTexts["album-heading"]
      XCTAssertTrue(detail.waitForExistence(timeout: 5))
      XCTAssertEqual(detail.label, String(label.dropFirst("Open ".count)))
      app.navigationBars.buttons["Back"].firstMatch.tap()
      XCTAssertTrue(selected.waitForExistence(timeout: 4))
      XCTAssertTrue(selected.isHittable)
      XCTAssertTrue(tab.isSelected)
      XCTAssertEqual(field.value as? String, "North Window")
      assertSearchKeyboardDismissed(app)
      let after = selected.frame.minY
      XCTContext.runActivity(named: "Search Back \(filter) before=\(before) after=\(after)") { _ in
      }
      XCTAssertEqual(after, before, accuracy: 3)
    }
    XCTAssertEqual(miniToggle.label, "Play")
  }

  @MainActor func testSearchKeyboardScrollingPerformance() throws {
    let app = launchMutedPlaylistFixture()
    openSearch(app)
    app.buttons["search-filter-Songs"].tap()
    let field = app.textFields["global-search-field"]
    field.tap()
    field.typeText("First light")
    let results = app.scrollViews["music-collection"]
    XCTAssertTrue(results.buttons["song-fixture-track-0"].waitForExistence(timeout: 6))
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 4))
    let controls = app.otherElements["search-browse-controls"].firstMatch
    let top = controls.frame.maxY
    let bottom = keyboard.frame.minY
    XCTAssertGreaterThan(bottom - top, 150)
    let firstSongFrame = results.buttons["song-fixture-track-0"].frame
    let origin = app.coordinate(withNormalizedOffset: .zero)
    let x = app.frame.width * 0.45
    let start = origin.withOffset(CGVector(dx: x, dy: top + (bottom - top) * 0.72))
    let end = origin.withOffset(CGVector(dx: x, dy: top + (bottom - top) * 0.12))
    func deepestVisibleSong() throws -> Int {
      try browseRows(results).compactMap { row -> Int? in
        let prefix = "song-fixture-album-"
        guard row.id.hasPrefix(prefix), row.frame.midY >= top,
          row.frame.midY <= top + (bottom - top) * 0.85
        else { return nil }
        return row.id.dropFirst(prefix.count).split(separator: "-").first.flatMap { Int($0) }
      }.max() ?? 0
    }
    let firstPage = try deepestVisibleSong()
    capture("search-glass-keyboard", app: app, screen: true)
    let options = XCTMeasureOptions()
    options.iterationCount = 4
    options.invocationOptions = [.manuallyStart, .manuallyStop]
    measure(
      metrics: [
        XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTHitchMetric(application: app),
      ],
      options: options
    ) {
      if !keyboard.exists { field.tap() }
      XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
      startMeasuring()
      start.press(forDuration: 0.08, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
      stopMeasuring()
    }
    XCTAssertTrue(keyboard.exists)
    var deepest = try deepestVisibleSong()
    XCTAssertGreaterThan(
      deepest, firstPage, "Measured drags must move results with the keyboard up")
    for _ in 0..<8 {
      if deepest >= 45 { break }
      start.press(forDuration: 0.08, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
      XCTAssertTrue(keyboard.exists)
      deepest = max(deepest, try deepestVisibleSong())
    }
    XCTContext.runActivity(named: "Search keyboard top=\(top) bottom=\(bottom) paged=\(deepest)") {
      _ in
    }
    XCTAssertGreaterThanOrEqual(
      deepest, 45, "The search must scroll into the second 40-result page")
    XCTAssertGreaterThanOrEqual(firstSongFrame.minY, top - 1)
    XCTAssertGreaterThanOrEqual(firstSongFrame.minX, 15)
    XCTAssertEqual(field.value as? String, "First light")
  }

  @MainActor func testLibraryScrollsUnderBarsAndRestoresSongAfterGridList() throws {
    let app = launchMutedPlaylistFixture()
    let play = app.buttons["Play The quiet hours"]
    revealInBrowse(play, app: app)
    XCTAssertTrue(play.waitForExistence(timeout: 8))
    play.tap()
    let toggle = app.buttons["mini-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if toggle.label == "Pause" { toggle.tap() }
    app.tabBars.buttons["Library"].tap()
    let songs = app.buttons["music-category-Songs"]
    songs.tap()
    chooseBrowseLayout(app, "List")
    let collection = app.collectionViews["music-collection"]
    let mini = app.buttons["Open now playing"]
    XCTContext.runActivity(
      named:
        "Library geometry header=\(songs.frame.midY) viewport=\(collection.frame.minY),\(collection.frame.maxY) mini=\(mini.frame.midY)"
    ) { _ in }
    XCTAssertEqual(collection.frame.minY, app.frame.minY, accuracy: 1)
    XCTAssertEqual(collection.frame.maxY, app.frame.maxY, accuracy: 1)
    let rows = collection.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)", "song-",
        "song-actions-"))
    XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
    XCTAssertGreaterThanOrEqual(rows.firstMatch.frame.minY, songs.frame.maxY - 1)
    let start = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.72))
    let end = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.40))
    start.press(forDuration: 0.12, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    let visible = rows.allElementsBoundByIndex
    XCTAssertTrue(
      visible.contains { $0.frame.minY < songs.frame.maxY && $0.frame.maxY > collection.frame.minY }
    )
    XCTAssertTrue(
      visible.contains { $0.frame.maxY > mini.frame.minY && $0.frame.minY < collection.frame.maxY })
    let target = try XCTUnwrap(
      visible.first {
        $0.isHittable && $0.frame.minY >= songs.frame.maxY && $0.frame.maxY < mini.frame.minY
      })
    let id = target.identifier
    let baseline = try XCTUnwrap(catalogGeometry(app, targetID: id, landscape: false, timeout: 4))
    capture("library-songs-under-glass", app: app, screen: true)
    for _ in 0..<2 {
      chooseBrowseLayout(app, "Grid")
      XCTAssertTrue(collection.buttons[id].isHittable, "Grid must keep the same song in view")
      chooseBrowseLayout(app, "List")
      let restored = try XCTUnwrap(catalogGeometry(app, targetID: id, landscape: false, timeout: 4))
      XCTContext.runActivity(
        named: "Library anchor before=\(baseline.offset) after=\(restored.offset)"
      ) { _ in }
      XCTAssertEqual(restored.offset, baseline.offset, accuracy: 3)
    }
    XCTAssertTrue(toggle.isHittable)
    XCTAssertEqual(toggle.label, "Play")
  }

  @MainActor func testBrowsePlaylistsAndPlayARepeatedSongOrAnotherList() throws {
    let app = launchMutedPlaylistFixture()
    app.tabBars.buttons["Library"].tap()
    app.buttons["music-category-Playlists"].tap()
    let morning = app.descendants(matching: .any)["playlist-fixture-playlist-morning"].firstMatch
    XCTAssertTrue(morning.waitForExistence(timeout: 5))
    morning.tap()
    let first = app.buttons["playlist-track-1"]
    let third = app.buttons["playlist-track-3"]
    XCTAssertTrue(third.waitForExistence(timeout: 5))
    XCTAssertTrue(third.isHittable)
    XCTAssertEqual(first.label, third.label)
    XCTAssertTrue((third.value as? String)?.hasPrefix("Track 3 of 3") == true)
    let mini = app.buttons["Open now playing"]
    let toggle = app.buttons["mini-toggle"]
    third.tap()
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    XCTAssertEqual(toggle.label, "Pause")
    toggle.tap()
    XCTAssertEqual(toggle.label, "Play")
    XCTAssertTrue(mini.waitForExistence(timeout: 5))
    XCTAssertTrue((mini.value as? String)?.hasPrefix("First light,") == true)
    mini.tap()
    app.buttons["player-queue"].tap()
    let queue = app.descendants(matching: .any).matching(identifier: "queue-list").firstMatch
    let copies = queue.buttons.matching(NSPredicate(format: "label CONTAINS %@", "First light"))
    XCTAssertTrue(copies.element(boundBy: 1).waitForExistence(timeout: 5))
    XCTAssertEqual(copies.count, 2)
    XCTAssertEqual(copies.element(boundBy: 0).value as? String, "Queued")
    XCTAssertEqual(copies.element(boundBy: 1).value as? String, "Paused")
    app.navigationBars["Queue"].buttons.element(boundBy: 0).tap()
    app.buttons["close-player"].tap()
    toggle.tap()
    XCTAssertEqual(toggle.label, "Pause")
    app.navigationBars["Morning rotation"].buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.buttons["music-category-Playlists"].isSelected)
    let evening = app.descendants(matching: .any)["playlist-fixture-playlist-evening"].firstMatch
    XCTAssertTrue(evening.waitForExistence(timeout: 5))
    evening.tap()
    let play = app.buttons["playlist-play"]
    XCTAssertTrue(play.waitForExistence(timeout: 5))
    XCTAssertEqual(play.label, "Play playlist")
    play.tap()
    let playing = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH %@", "A place to return,"), object: mini)
    XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 5), .completed)
    XCTAssertEqual(toggle.label, "Pause")
  }
  @MainActor func testAlbumArtistAndDirectPlayerIdentityJourney() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted"]
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    app.buttons["Open The quiet hours"].tap()
    XCTAssertTrue(app.buttons["Play First light"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["album-track-number-fixture-track-0"].label, "1")
    XCTAssertEqual(app.staticTexts["album-track-duration-fixture-track-0"].label, "Duration: 0:18")
    let first = app.buttons["song-fixture-track-0"]
    let second = app.buttons["song-fixture-track-1"]
    XCTAssertLessThanOrEqual(second.frame.minY - first.frame.minY, 57)
    XCTAssertGreaterThanOrEqual(first.frame.height, 44)
    capture("detail-numbered-album", app: app)
    app.buttons["Play album"].tap()
    let miniToggle = app.buttons["mini-toggle"]
    XCTAssertTrue(miniToggle.waitForExistence(timeout: 5))
    if miniToggle.label == "Pause" { miniToggle.tap() }
    let currentTitle = app.staticTexts["mini-title"].label
    app.buttons["Open now playing"].tap()
    let albumLink = app.buttons["player-open-album"]
    XCTAssertTrue(albumLink.waitForExistence(timeout: 4))
    XCTAssertGreaterThanOrEqual(albumLink.frame.height, 44)
    XCTAssertEqual(app.buttons["player-toggle"].label, "Play")
    capture("detail-linked-player", app: app)
    albumLink.tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["close-player"].exists)
    XCTAssertEqual(app.staticTexts["mini-title"].label, currentTitle)
    XCTAssertEqual(app.buttons["mini-toggle"].label, "Play")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.buttons["Albums"].waitForExistence(timeout: 3))
    app.buttons["Open now playing"].tap()
    let artist = app.buttons["player-artist-fixture-artist-0"]
    XCTAssertTrue(artist.waitForExistence(timeout: 4))
    XCTAssertGreaterThanOrEqual(artist.frame.height, 44)
    artist.tap()
    XCTAssertTrue(app.staticTexts["artist-heading"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["artist-heading"].label, "North Window")
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 5))
    app.buttons["artist-all-songs"].tap()
    XCTAssertTrue(app.buttons["Play First light"].firstMatch.waitForExistence(timeout: 5))
    capture("detail-artist-songs", app: app)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.staticTexts["artist-heading"].waitForExistence(timeout: 3))
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(app.buttons["Artists"].waitForExistence(timeout: 3))
    XCTAssertEqual(app.staticTexts["mini-title"].label, currentTitle)
    XCTAssertEqual(app.buttons["mini-toggle"].label, "Play")
    app.tabBars.buttons["Home"].tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 3))
    XCTAssertEqual(app.staticTexts["album-heading"].label, "The quiet hours")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(
      app.buttons[
        "Open Tides and timber · Complete orchestral soundtrack and extended anniversary edition"
      ].waitForExistence(timeout: 3))
    app.buttons[
      "Open Tides and timber · Complete orchestral soundtrack and extended anniversary edition"
    ].tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
    app.buttons["Play album"].tap()
    XCTAssertTrue(app.buttons["mini-toggle"].waitForExistence(timeout: 5))
    if app.buttons["mini-toggle"].label == "Pause" { app.buttons["mini-toggle"].tap() }
    app.buttons["Open now playing"].tap()
    XCTAssertTrue(app.buttons["player-artist-fixture-artist-2"].waitForExistence(timeout: 4))
    let secondArtist = app.buttons["player-artist-fixture-artist-3"]
    XCTAssertTrue(secondArtist.isHittable)
    XCTAssertTrue(app.buttons["player-queue"].isHittable)
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Streaming quality:"))
        .firstMatch.isHittable)
    capture("detail-multiple-player-artists", app: app)
    secondArtist.tap()
    XCTAssertTrue(app.staticTexts["artist-heading"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["artist-heading"].label, "Étienne Marchand")
    XCTAssertEqual(app.buttons["mini-toggle"].label, "Play")
  }
  @MainActor func testRootHeaderNativeEdgesAndMenus() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--transport-ui=" + UUID().uuidString]
    addTeardownBlock { MainActor.assumeIsolated { app.terminate() } }
    app.launch()
    let tabs = app.tabBars.firstMatch
    XCTAssertTrue(tabs.buttons["Home"].waitForExistence(timeout: 8))
    let media = app.buttons["media-picker"]
    let library = app.buttons["music-library-picker"]
    let account = app.buttons["Accounts"]
    for destination in ["Home", "Search", "Library"] {
      tabs.buttons[destination].tap()
      XCTAssertTrue(tabs.buttons[destination].isSelected)
      for control in [media, library, account] {
        XCTAssertTrue(control.waitForExistence(timeout: 3))
        XCTAssertTrue(control.isHittable)
        XCTAssertGreaterThanOrEqual(control.frame.height + 1e-6, 44)
        XCTAssertGreaterThanOrEqual(control.frame.width + 1e-6, 44)
        XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
      }
      XCTAssertEqual(app.buttons.matching(identifier: "media-picker").count, 1)
      XCTAssertEqual(app.buttons.matching(identifier: "music-library-picker").count, 1)
      XCTAssertLessThanOrEqual(media.frame.minX - app.frame.minX, 24)
      XCTAssertLessThanOrEqual(app.frame.maxX - account.frame.maxX, 24)
      XCTAssertLessThan(media.frame.maxX, library.frame.minX)
      XCTAssertLessThanOrEqual(library.frame.maxX, account.frame.minX + 2)
      XCTAssertEqual(library.frame.midY, account.frame.midY, accuracy: 2)
      let bounds: [String: Any] = [
        "destination": destination, "appWidth": app.frame.width,
        "mediaX": media.frame.minX, "mediaWidth": media.frame.width,
        "libraryX": library.frame.minX, "libraryWidth": library.frame.width,
        "accountX": account.frame.minX, "accountWidth": account.frame.width,
        "mediaHittable": media.isHittable, "libraryHittable": library.isHittable,
        "accountHittable": account.isHittable,
      ]
      let data = try JSONSerialization.data(withJSONObject: bounds, options: [.sortedKeys])
      let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
      attachment.name = "Header33-" + destination
      attachment.lifetime = .keepAlways
      add(attachment)
      media.tap()
      let selectedMusic = app.buttons["media-Music"]
      XCTAssertTrue(selectedMusic.waitForExistence(timeout: 3))
      XCTAssertTrue(selectedMusic.isSelected)
      selectedMusic.tap()
      XCTAssertTrue(selectedMusic.waitForNonExistence(timeout: 3))
      library.tap()
      let selectedLibrary = app.buttons["music-library-fixture-music"]
      XCTAssertTrue(selectedLibrary.waitForExistence(timeout: 3))
      XCTAssertTrue(selectedLibrary.isSelected)
      selectedLibrary.tap()
      XCTAssertTrue(selectedLibrary.waitForNonExistence(timeout: 3))
      account.tap()
      let details = app.buttons["Connection details"]
      XCTAssertTrue(details.waitForExistence(timeout: 3))
      XCTAssertTrue(details.isHittable)
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.82)).tap()
      XCTAssertTrue(details.waitForNonExistence(timeout: 3))
      XCTAssertTrue(tabs.buttons[destination].isSelected)
      if destination == "Search" {
        let field = app.textFields["global-search-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        let query = "header-fixture-no-match"
        let root = library.value as? String
        field.tap()
        field.typeText(query)
        let empty = app.staticTexts["No matches"]
        XCTAssertTrue(empty.waitForExistence(timeout: 6))
        media.tap()
        XCTAssertTrue(selectedMusic.waitForExistence(timeout: 3))
        selectedMusic.tap()
        XCTAssertTrue(selectedMusic.waitForNonExistence(timeout: 3))
        library.tap()
        XCTAssertTrue(selectedLibrary.waitForExistence(timeout: 3))
        selectedLibrary.tap()
        XCTAssertTrue(selectedLibrary.waitForNonExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, query)
        XCTAssertEqual(library.value as? String, root)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        tapVisibleSearchGap(app, anchor: empty)
        assertSearchKeyboardDismissed(app)
        XCTAssertEqual(field.value as? String, query)
        XCTAssertEqual(library.value as? String, root)
      }
    }
  }
  @MainActor func testLibraryHubHeaderMenusAndIndependentScopes() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    let run = UUID().uuidString
    app.launchArguments = ["--fixture", "--muted", "--transport-ui=" + run]
    addTeardownBlock { MainActor.assumeIsolated { app.terminate() } }
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    let tabs = app.tabBars.firstMatch
    XCTAssertEqual(tabs.buttons.count, 3)
    XCTAssertLessThan(tabs.buttons["Home"].frame.midX, tabs.buttons["Search"].frame.midX)
    XCTAssertLessThan(tabs.buttons["Search"].frame.midX, tabs.buttons["Library"].frame.midX)
    let media = app.buttons["media-picker"]
    let library = app.buttons["music-library-picker"]
    let account = app.buttons["Accounts"]
    for control in [media, library, account] {
      XCTAssertTrue(control.isHittable)
      XCTAssertGreaterThanOrEqual(control.frame.height + 1e-9, 44)
    }
    let titleFont = UIFont.preferredFont(
      forTextStyle: .title3,
      compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
    let titleWidth = ("Music" as NSString).size(
      withAttributes: [.font: UIFont.systemFont(ofSize: titleFont.pointSize, weight: .semibold)]
    ).width
    XCTAssertGreaterThanOrEqual(
      media.frame.width + 1e-6, titleWidth + 6,
      "The selector must fit the rendered Music label and spacing, not just its AX value")
    capture("library-hub-visible-title", app: app)
    XCTAssertEqual(app.buttons.matching(identifier: "media-picker").count, 1)
    XCTAssertEqual(app.buttons.matching(identifier: "music-library-picker").count, 1)
    XCTAssertEqual(library.frame.midY, account.frame.midY, accuracy: 2)
    XCTAssertLessThanOrEqual(library.frame.maxX, account.frame.minX + 2)
    XCTAssertLessThanOrEqual(
      media.frame.minX - app.frame.minX, 24, "The media title stays at the leading edge")
    XCTAssertLessThanOrEqual(
      app.frame.maxX - account.frame.maxX, 24, "Library/account stay at the trailing edge")
    XCTAssertEqual(
      app.buttons.matching(
        NSPredicate(
          format: "label == %@ AND identifier != %@", "Music library", "music-library-picker")
      ).count, 0)
    media.tap()
    let selectedMusic = app.buttons["media-Music"]
    XCTAssertTrue(selectedMusic.waitForExistence(timeout: 3))
    XCTAssertTrue(selectedMusic.isSelected)
    XCTAssertFalse(app.buttons["Done"].exists, "Menus have no Done footer")
    for title in ["Movies", "Photos", "Books", "Games"] {
      let future = app.buttons["media-future-" + title]
      XCTAssertTrue(future.exists)
      XCTAssertFalse(future.isEnabled, "Future media never admit a workflow or data request")
    }
    selectedMusic.tap()
    XCTAssertTrue(selectedMusic.waitForNonExistence(timeout: 3))
    library.tap()
    XCTAssertTrue(app.buttons["music-library-fixture-music"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["music-library-fixture-music"].isSelected)
    XCTAssertFalse(app.buttons["Done"].exists)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.82)).tap()
    XCTAssertTrue(app.buttons["music-library-fixture-music"].waitForNonExistence(timeout: 3))
    XCTAssertFalse(app.buttons["Play album"].exists, "Outside dismissal does not activate a card")
    account.tap()
    XCTAssertTrue(app.buttons["Connection details"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["Done"].exists)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.82)).tap()
    XCTAssertTrue(app.buttons["Connection details"].waitForNonExistence(timeout: 3))
    tabs.buttons["Library"].tap()
    XCTAssertTrue(app.buttons["music-category-Albums"].isSelected)
    XCTAssertEqual(app.buttons.matching(identifier: "music-sort-filter").count, 1)
    XCTAssertEqual(app.buttons.matching(identifier: "music-layout").count, 1)
    selectMusicLibrary(app, id: "fixture-concerts")
    openSearch(app)
    let field = app.textFields["global-search-field"].firstMatch
    field.typeText("Mira Sol")
    XCTAssertFalse(app.buttons["search-done"].exists)
    let searchLibraryBeforeMenu = try XCTUnwrap(library.value as? String)
    media.tap()
    XCTAssertTrue(selectedMusic.waitForExistence(timeout: 3))
    XCTAssertTrue(selectedMusic.isSelected)
    XCTAssertFalse(app.buttons["Done"].exists)
    selectedMusic.tap()
    XCTAssertTrue(selectedMusic.waitForNonExistence(timeout: 3))
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    XCTAssertTrue(field.isHittable)
    XCTAssertEqual(field.value as? String, "Mira Sol")
    XCTAssertEqual(library.value as? String, searchLibraryBeforeMenu)
    selectMusicLibrary(app, id: "fixture-music")
    XCTAssertEqual(field.value as? String, "Mira Sol")
    dismissSearchKeyboard(app)
    XCTAssertTrue(tabs.buttons["Library"].isHittable)
    tabs.buttons["Library"].tap()
    XCTAssertTrue(tabs.buttons["Library"].isSelected)
    XCTAssertEqual(library.value as? String, "Live recordings")
    tabs.buttons["Search"].tap()
    XCTAssertEqual(library.value as? String, "Music")
    XCTAssertEqual(field.value as? String, "Mira Sol")
    assertSearchKeyboardDismissed(app)
    capture("library-hub-header-menus", app: app)
  }
  @MainActor func testVisibleLibraryTabsCompactHomeAndSingleRoot() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted"]
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.navigationBars.staticTexts["Dashboard"].exists)
    let heading = app.staticTexts["Discover"]
    let defaultHeadingHeight = heading.frame.height
    XCTAssertLessThanOrEqual(defaultHeadingHeight, 24)
    let library = app.buttons["music-library-picker"]
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "music-library-picker").firstMatch.exists
    )
    XCTAssertTrue(library.value as? String == "Music")
    XCTAssertGreaterThanOrEqual(library.frame.height, 44)
    app.buttons["Play The quiet hours"].tap()
    XCTAssertTrue(app.buttons["mini-toggle"].waitForExistence(timeout: 5))
    if app.buttons["mini-toggle"].label == "Pause" { app.buttons["mini-toggle"].tap() }
    let currentTitle = app.staticTexts["mini-title"].label
    capture("home-compact", app: app)
    selectMusicLibrary(app, id: "fixture-concerts")
    XCTAssertTrue(library.value as? String == "Live recordings")
    XCTAssertTrue(app.buttons["Open After the last train"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Open The quiet hours"].exists)
    XCTAssertEqual(app.buttons["mini-toggle"].label, "Play")
    XCTAssertEqual(app.staticTexts["mini-title"].label, currentTitle)
    for title in ["Discover", "Favorites"] {
      XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 3))
    }
    XCTAssertTrue(app.staticTexts["Discover"].isHittable)
    XCTAssertFalse(app.staticTexts["Recently added"].exists)
    capture("home-live-root", app: app)
    openSearch(app)
    XCTAssertTrue(app.textFields["global-search-field"].firstMatch.waitForExistence(timeout: 3))
    XCTAssertTrue(library.value as? String == "Live recordings")
    XCTAssertFalse(app.navigationBars.staticTexts["Search music"].exists)
    dismissSearchKeyboard(app)
    app.tabBars.buttons["Home"].tap()
    selectMusicLibrary(app, id: "fixture-music")
    selectMusicLibrary(app, id: "fixture-concerts")
    selectMusicLibrary(app, id: "fixture-music")
    XCTAssertTrue(library.value as? String == "Music")
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["mini-toggle"].label, "Play")
    XCTAssertEqual(app.staticTexts["mini-title"].label, currentTitle)
    app.tabBars.buttons["Library"].tap()
    XCTAssertEqual(app.buttons["media-picker"].value as? String, "Music")
    let albums = app.buttons["music-category-Albums"]
    let songs = app.buttons["music-category-Songs"]
    XCTAssertTrue(albums.isSelected)
    XCTAssertGreaterThanOrEqual(songs.frame.height, 44)
    songs.tap()
    XCTAssertTrue(songs.isSelected)
    XCTAssertFalse(albums.isSelected)
    XCTAssertTrue(app.buttons["Play First light"].firstMatch.waitForExistence(timeout: 5))
    albums.tap()
    XCTAssertTrue(albums.isSelected)
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["mini-title"].label, currentTitle)
    XCTAssertEqual(app.buttons["mini-toggle"].label, "Play")
    app.terminate()
    app.launchArguments = ["--fixture", "--muted", "--single-library"]
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["music-library-picker"].exists)
    capture("home-single-root", app: app)
    app.terminate()
    app.launchArguments = [
      "--fixture", "--muted", "--single-library", "--large-text", "--appearance-dark",
    ]
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    XCTAssertGreaterThan(app.staticTexts["Discover"].frame.height, defaultHeadingHeight * 1.5)
    capture("home-accessibility-growth", app: app)
    app.tabBars.buttons["Library"].tap()
    let categoryStrip = app.descendants(matching: .any).matching(
      identifier: "music-category-tabs"
    ).firstMatch
    XCTAssertTrue(categoryStrip.waitForExistence(timeout: 3))
    let largeSongs = app.buttons["music-category-Songs"]
    if !largeSongs.isHittable { categoryStrip.swipeLeft() }
    XCTAssertTrue(largeSongs.isHittable)
    XCTAssertGreaterThanOrEqual(largeSongs.frame.height, 44)
    largeSongs.tap()
    XCTAssertTrue(largeSongs.isSelected)
    XCTAssertTrue(app.buttons["Play First light"].firstMatch.waitForExistence(timeout: 5))
    capture("music-categories-accessibility", app: app)
  }
  @MainActor func testDashboardLoadingCardGeometry() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    for large in [false, true] {
      app.launchArguments =
        ["--fixture", "--muted", "--slow-catalog"]
        + (large ? ["--large-text", "--appearance-dark"] : [])
      app.launch()
      let nextShelf = app.staticTexts["home-heading-playlists"]
      XCTAssertTrue(nextShelf.waitForExistence(timeout: 3))
      XCTAssertFalse(app.buttons["Open The quiet hours"].exists)
      let before = nextShelf.frame.minY
      capture(large ? "dashboard-loading-accessibility" : "dashboard-loading", app: app)
      XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
      let delta = nextShelf.frame.minY - before
      XCTAssertEqual(delta, 0, accuracy: 0)
      let shortCaption = app.buttons["album-caption-fixture-album"]
      let longCaption = app.buttons["album-caption-fixture-album-2"]
      XCTAssertTrue(shortCaption.exists)
      XCTAssertTrue(longCaption.exists)
      XCTAssertEqual(shortCaption.frame.height, longCaption.frame.height, accuracy: 0)
      capture(large ? "dashboard-ready-accessibility" : "dashboard-ready", app: app)
      app.terminate()
    }
  }
  @MainActor func testMusicSearchLinksAndPersistentPlayer() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted"]
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    capture("dashboard", app: app)
    let header = app.tabBars.buttons["Search"]
    XCTAssertTrue(header.isHittable)
    openSearch(app)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    app.buttons["Songs"].tap()
    let search = app.textFields["global-search-field"].firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 3))
    search.tap()
    search.typeText("Mira Sol")
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    let searchSurface = app.otherElements["music-search-surface"].firstMatch
    XCTAssertTrue(searchSurface.exists)
    XCTAssertGreaterThanOrEqual(searchSurface.frame.height + 1e-9, 44)
    capture("search-phone-keyboard", app: app, screen: true)
    search.typeText("\n")
    searchSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.1)).tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    search.typeText("\n")
    let song = app.buttons["Play First light"].firstMatch
    XCTAssertTrue(song.waitForExistence(timeout: 5))
    XCTAssertEqual(song.value as? String, "Mira Sol, A field guide to distant weather")
    capture("music-search", app: app)
    song.tap()
    XCTAssertTrue(app.buttons["Open now playing"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["Open now playing"].value as? String, "First light, Mira Sol")
    app.buttons["Actions for First light"].firstMatch.tap()
    let albumAction = app.buttons["Go to album"]
    XCTAssertTrue(albumAction.waitForExistence(timeout: 3))
    XCTAssertTrue(albumAction.isHittable)
    albumAction.tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
    let artist = app.buttons["Mira Sol"].firstMatch
    XCTAssertTrue(artist.waitForExistence(timeout: 3))
    artist.tap()
    XCTAssertTrue(app.buttons["Open A field guide to distant weather"].waitForExistence(timeout: 5))
    capture("artist-discography", app: app)
    XCTAssertTrue(app.navigationBars.buttons["Back"].firstMatch.isHittable)
    app.navigationBars.buttons["Back"].firstMatch.tap()
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(app.textFields["global-search-field"].firstMatch.waitForExistence(timeout: 3))
    XCTAssertEqual(app.textFields["global-search-field"].firstMatch.value as? String, "Mira Sol")
    XCTAssertTrue(app.buttons["search-filter-Songs"].isSelected)
    app.buttons["Clear search"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    dismissSearchKeyboard(app)
    app.tabBars.buttons["Home"].tap()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 3))
    app.tabBars.buttons["Library"].tap()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["Open now playing"].exists)
    app.tabBars.buttons["Home"].tap()
    XCTAssertTrue(app.buttons["Open The quiet hours"].exists)
    app.buttons["Open now playing"].tap()
    XCTAssertTrue(app.buttons["Related music"].waitForExistence(timeout: 3))
    app.buttons["Related music"].tap()
    app.buttons["Go to album"].tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
  }
  @MainActor func testMusicBrowseLayoutsSortFilterAndRetention() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted"]
    app.launch()
    XCTAssertTrue(app.buttons["Play The quiet hours"].waitForExistence(timeout: 8))
    app.buttons["Play The quiet hours"].tap()
    let mini = app.buttons["mini-toggle"]
    XCTAssertTrue(mini.waitForExistence(timeout: 5))
    if mini.label == "Pause" { mini.tap() }
    let playing = app.staticTexts["mini-title"].label
    let music = app.tabBars.buttons["Library"]
    music.tap()
    XCTAssertEqual(app.buttons["music-layout"].value as? String, "Grid")
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 5))
    let layout = app.buttons["music-layout"]
    let filters = app.buttons["music-sort-filter"]
    let category = app.buttons["music-category-Albums"]
    XCTAssertEqual(layout.frame.midY, filters.frame.midY, accuracy: 2)
    XCTAssertEqual(filters.frame.midY, category.frame.midY, accuracy: 2)
    XCTAssertGreaterThanOrEqual(filters.frame.height, 44)
    let collection = app.collectionViews["music-collection"]
    XCTAssertLessThan(collection.frame.minY, category.frame.minY)
    XCTAssertGreaterThan(collection.frame.maxY, music.frame.minY)
    XCTAssertGreaterThanOrEqual(
      app.buttons["Open The quiet hours"].frame.minY, filters.frame.maxY - 1)
    capture("music-browse-album-grid", app: app, screen: true)
    chooseBrowseLayout(app, "List")
    XCTAssertGreaterThanOrEqual(app.buttons["Open The quiet hours"].frame.height, 44)
    capture("music-browse-album-list", app: app, screen: true)
    chooseBrowseLayout(app, "Grid")
    XCTAssertFalse(app.buttons["browse-layout-Compact"].exists)
    chooseBrowseLayout(app, "List")
    app.buttons["music-sort-filter"].tap()
    XCTAssertFalse(app.buttons["browse-sort-album"].exists)
    app.buttons["browse-sort-year"].tap()
    XCTAssertTrue(app.buttons["browse-sort-year"].isSelected)
    app.buttons["browse-favorites-only"].tap()
    XCTAssertTrue(app.buttons["browse-favorites-only"].isSelected)
    capture("music-browse-sort-filter-sheet", app: app, screen: true)
    app.buttons["close-browse-sheet"].tap()
    XCTAssertTrue(app.buttons["Open A field guide to distant weather"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Open The quiet hours"].exists)
    XCTAssertEqual(app.buttons["music-layout"].value as? String, "List")
    XCTAssertTrue((app.buttons["music-sort-filter"].value as? String ?? "").contains("Favorites"))
    app.tabBars.buttons["Home"].tap()
    music.tap()
    XCTAssertEqual(app.buttons["music-layout"].value as? String, "List")
    XCTAssertFalse(app.buttons["Open The quiet hours"].exists)
    app.buttons["music-sort-filter"].tap()
    let reset = app.buttons["browse-options-reset"]
    let options = app.scrollViews["music-browse-sheet"]
    for _ in 0..<3 {
      if reset.isHittable { break }
      options.swipeUp()
    }
    XCTAssertTrue(reset.isHittable)
    reset.tap()
    app.buttons["close-browse-sheet"].tap()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 5))
    XCTAssertEqual(mini.label, "Play")
    XCTAssertEqual(app.staticTexts["mini-title"].label, playing)
    app.buttons["music-category-Artists"].tap()
    XCTAssertTrue(app.buttons["artist-fixture-artist-0"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["music-layout"].value as? String, "List")
    chooseBrowseLayout(app, "Grid")
    capture("music-browse-artist-grid", app: app, screen: true)
    app.buttons["music-sort-filter"].tap()
    XCTAssertFalse(app.buttons["browse-sort-year"].exists)
    XCTAssertFalse(app.buttons["browse-sort-artist"].exists)
    app.buttons["browse-favorites-only"].tap()
    app.buttons["close-browse-sheet"].tap()
    let artist = app.buttons["artist-fixture-artist-0"]
    XCTAssertTrue(artist.waitForExistence(timeout: 5))
    artist.tap()
    XCTAssertTrue(app.staticTexts["artist-heading"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["artist-heading"].label, "North Window")
    revealInBrowse(app.buttons["artist-all-albums"], app: app)
    app.buttons["artist-all-albums"].tap()
    XCTAssertEqual(app.buttons["music-layout"].value as? String, "Grid")
    chooseBrowseLayout(app, "List")
    app.buttons["music-sort-filter"].tap()
    XCTAssertTrue(app.buttons["browse-favorites-only"].isSelected)
    app.buttons["browse-favorites-all"].tap()
    app.buttons["close-browse-sheet"].tap()
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["artist-heading"].waitForExistence(timeout: 3))
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(app.buttons["music-category-Artists"].isSelected)
    XCTAssertEqual(app.buttons["music-layout"].value as? String, "List")
    app.buttons["music-category-Songs"].tap()
    XCTAssertTrue(app.buttons["song-fixture-track-0"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["music-layout"].value as? String, "List")
    chooseBrowseLayout(app, "Grid")
    XCTAssertGreaterThanOrEqual(app.buttons["song-fixture-track-0"].frame.height, 44)
    capture("music-browse-song-grid", app: app, screen: true)
    app.buttons["music-sort-filter"].tap()
    XCTAssertFalse(app.buttons["browse-sort-year"].exists)
    app.buttons["browse-sort-album"].tap()
    app.buttons["browse-favorites-only"].tap()
    app.buttons["close-browse-sheet"].tap()
    XCTAssertTrue(app.buttons["song-fixture-album-1-track-0"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["song-fixture-track-0"].exists)
    app.tabBars.buttons["Search"].tap()
    XCTAssertTrue(app.buttons["search-filter-All"].isSelected)
    dismissSearchKeyboard(app)
    music.tap()
    XCTAssertTrue(app.buttons["music-category-Songs"].isSelected)
    XCTAssertEqual(app.buttons["music-layout"].value as? String, "Grid")
    XCTAssertEqual(app.buttons["music-library-picker"].value as? String, "Music")
    XCTAssertEqual(app.staticTexts["mini-title"].label, playing)
    XCTAssertEqual(mini.label, "Play")
    app.terminate()
    app.launchArguments = [
      "--fixture", "--muted", "--single-library", "--appearance-dark", "--large-text",
    ]
    app.launch()
    XCTAssertTrue(music.waitForExistence(timeout: 8))
    music.tap()
    XCTAssertEqual(app.buttons["music-layout"].value as? String, "Grid")
    XCTAssertTrue((app.buttons["music-sort-filter"].value as? String ?? "").contains("Favorites"))
    app.buttons["music-sort-filter"].tap()
    XCTAssertTrue(app.buttons["browse-favorites-only"].isSelected)
    app.buttons["browse-favorites-all"].tap()
    app.buttons["close-browse-sheet"].tap()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["music-library-picker"].exists)
    let categoryStrip = app.descendants(matching: .any).matching(identifier: "music-category-tabs")
      .firstMatch
    XCTAssertTrue(categoryStrip.isHittable)
    let artistCategory = app.buttons["music-category-Artists"]
    if !artistCategory.isHittable { categoryStrip.swipeLeft() }
    XCTAssertGreaterThanOrEqual(artistCategory.frame.height, 44)
    XCTAssertEqual(artistCategory.frame.midY, app.buttons["music-layout"].frame.midY, accuracy: 2)
    artistCategory.tap()
    XCTAssertTrue(app.buttons["artist-fixture-artist-0"].waitForExistence(timeout: 5))
    let albumCategory = app.buttons["music-category-Albums"]
    if !albumCategory.isHittable { categoryStrip.swipeRight() }
    albumCategory.tap()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 5))
    capture("music-browse-grid-dark-large", app: app, screen: true)
    chooseBrowseLayout(app, "List")
    XCTAssertGreaterThanOrEqual(app.buttons["Open The quiet hours"].frame.height, 44)
    capture("music-browse-dark-large", app: app, screen: true)
    app.terminate()
    app.launchArguments = ["--fixture", "--muted", "--slow-catalog"]
    app.launch()
    XCTAssertTrue(music.waitForExistence(timeout: 8))
    music.tap()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    app.buttons["music-category-Artists"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "music-loading").firstMatch
        .waitForExistence(timeout: 3))
    XCTAssertFalse(app.staticTexts["Loading artists…"].exists)
    capture("music-browse-reserved-skeleton", app: app, screen: true)
    XCTAssertTrue(app.buttons["artist-fixture-artist-0"].waitForExistence(timeout: 8))
    app.terminate()
    app.launchArguments = ["--fixture", "--muted", "--catalog-error"]
    app.launch()
    XCTAssertTrue(music.waitForExistence(timeout: 8))
    music.tap()
    XCTAssertTrue(app.buttons["Retry"].firstMatch.waitForExistence(timeout: 5))
    XCTAssertGreaterThanOrEqual(app.buttons["Retry"].firstMatch.frame.height, 44)
    capture("music-browse-retry", app: app, screen: true)
  }
  @MainActor func testReleaseYearsSharedRangeAllAndArtistExclusion() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted"]
    app.launch()
    let music = app.tabBars.buttons["Library"]
    XCTAssertTrue(music.waitForExistence(timeout: 8))
    music.tap()
    app.buttons["music-category-Albums"].tap()
    chooseBrowseLayout(app, "List")
    app.buttons["music-sort-filter"].tap()
    app.buttons["browse-sort-title"].tap()
    app.buttons["browse-favorites-all"].tap()
    let sheet = app.scrollViews["music-browse-sheet"]
    let all = app.buttons["browse-years-all"]
    for _ in 0..<3 {
      if all.isHittable { break }
      sheet.swipeUp()
    }
    XCTAssertTrue(all.waitForExistence(timeout: 5))
    XCTAssertTrue(all.isHittable)
    all.tap()
    XCTAssertTrue(all.isSelected)
    let lower = app.descendants(matching: .any).matching(identifier: "browse-years-lower")
      .firstMatch
    let upper = app.descendants(matching: .any).matching(identifier: "browse-years-upper")
      .firstMatch
    XCTAssertTrue(lower.waitForExistence(timeout: 5))
    XCTAssertEqual(lower.value as? String, "1951")
    XCTAssertEqual(upper.value as? String, "2025")
    XCTAssertGreaterThanOrEqual(lower.frame.height, 44)
    XCTAssertGreaterThanOrEqual(upper.frame.width, 44)
    XCTAssertGreaterThanOrEqual(all.frame.height, 44)
    XCTAssertEqual(all.frame.midY, lower.frame.midY, accuracy: 2)
    XCTAssertEqual(lower.frame.midY, upper.frame.midY, accuracy: 2)
    XCTAssertLessThan(all.frame.midX, lower.frame.midX)
    XCTAssertLessThan(lower.frame.midX, upper.frame.midX)
    let feedback = app.switches["browse-selection-feedback"]
    for _ in 0..<2 {
      if feedback.isHittable { break }
      sheet.swipeUp()
    }
    XCTAssertEqual(feedback.value as? String, "1")
    feedback.tap()
    XCTAssertEqual(feedback.value as? String, "0")
    capture("music-release-years-all", app: app, screen: true)
    app.buttons["close-browse-sheet"].tap()
    XCTAssertTrue(app.buttons["Open After the last train"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Open A field guide to distant weather"].exists)
    app.buttons["music-sort-filter"].tap()
    for _ in 0..<3 {
      if lower.isHittable && upper.isHittable { break }
      sheet.swipeUp()
    }
    XCTAssertTrue(lower.isHittable && upper.isHittable)
    let origin = lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let railWidth = upper.frame.midX - lower.frame.midX
    let shift = railWidth * 47 / 74
    origin.press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: shift, dy: 0)))
    XCTAssertEqual(lower.value as? String, "1998")
    XCTAssertEqual(upper.value as? String, "2025")
    XCTAssertFalse(all.isSelected)
    XCTAssertEqual(app.staticTexts["browse-years-caption"].label, "1998–2025")
    let upperStart = upper.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    upperStart.press(
      forDuration: 0.1, thenDragTo: upperStart.withOffset(CGVector(dx: -railWidth * 26 / 74, dy: 0))
    )
    XCTAssertEqual(lower.value as? String, "1998")
    XCTAssertEqual(upper.value as? String, "1999")
    let inwardUpper = upper.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    inwardUpper.press(
      forDuration: 0.1, thenDragTo: inwardUpper.withOffset(CGVector(dx: -railWidth / 74, dy: 0)))
    XCTAssertEqual(lower.value as? String, "1998")
    XCTAssertEqual(upper.value as? String, "1998")
    let earlier = lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    earlier.press(
      forDuration: 0.1, thenDragTo: earlier.withOffset(CGVector(dx: -railWidth * 47 / 74, dy: 0)))
    XCTAssertEqual(lower.value as? String, "1951")
    XCTAssertEqual(upper.value as? String, "1998")
    let recollapse = lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    recollapse.press(
      forDuration: 0.1, thenDragTo: recollapse.withOffset(CGVector(dx: railWidth * 46 / 74, dy: 0)))
    XCTAssertEqual(lower.value as? String, "1997")
    XCTAssertEqual(upper.value as? String, "1998")
    let inwardLower = lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    inwardLower.press(
      forDuration: 0.1, thenDragTo: inwardLower.withOffset(CGVector(dx: railWidth / 74, dy: 0)))
    XCTAssertEqual(lower.value as? String, "1998")
    XCTAssertEqual(upper.value as? String, "1998")
    let later = upper.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    later.press(
      forDuration: 0.1, thenDragTo: later.withOffset(CGVector(dx: railWidth * 27 / 74, dy: 0)))
    XCTAssertEqual(lower.value as? String, "1998")
    XCTAssertEqual(upper.value as? String, "2025")
    capture("music-release-years-range", app: app, screen: true)
    for _ in 0..<3 {
      if app.buttons["browse-favorites-only"].isHittable { break }
      sheet.swipeDown()
    }
    XCTAssertTrue(app.buttons["browse-favorites-only"].isHittable)
    app.buttons["browse-favorites-only"].tap()
    XCTAssertEqual(lower.value as? String, "1998", "Favorites must not shrink library bounds")
    XCTAssertEqual(upper.value as? String, "2025")
    app.buttons["browse-favorites-all"].tap()
    app.buttons["close-browse-sheet"].tap()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 5))
    XCTAssertFalse(
      app.buttons["Open After the last train"].exists, "Numeric ranges exclude undated")
    XCTAssertFalse(app.buttons["Open A field guide to distant weather"].exists)
    app.buttons["music-category-Artists"].tap()
    let artist = app.buttons["artist-fixture-artist-0"]
    XCTAssertTrue(artist.waitForExistence(timeout: 5))
    app.buttons["music-sort-filter"].tap()
    XCTAssertFalse(
      app.descendants(matching: .any).matching(identifier: "browse-release-years").firstMatch.exists
    )
    XCTAssertFalse(lower.exists)
    app.buttons["close-browse-sheet"].tap()
    artist.tap()
    XCTAssertTrue(app.staticTexts["artist-heading"].waitForExistence(timeout: 5))
    revealInBrowse(app.buttons["artist-all-albums"], app: app)
    app.buttons["artist-all-albums"].tap()
    app.buttons["music-sort-filter"].tap()
    for _ in 0..<3 {
      if lower.isHittable { break }
      sheet.swipeUp()
    }
    XCTAssertTrue(lower.waitForExistence(timeout: 5))
    XCTAssertEqual(lower.value as? String, "1998")
    XCTAssertEqual(upper.value as? String, "2025")
    app.buttons["close-browse-sheet"].tap()
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["artist-heading"].waitForExistence(timeout: 3))
    app.navigationBars.buttons["Back"].firstMatch.tap()
    app.buttons["music-category-Songs"].tap()
    XCTAssertTrue(app.buttons["song-fixture-track-0"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["song-fixture-album-1-track-0"].exists)
    app.terminate()
    app.launchArguments = [
      "--fixture", "--muted", "--appearance-dark", "--large-text", "--fixture-rtl",
    ]
    app.launch()
    XCTAssertTrue(music.waitForExistence(timeout: 8))
    music.tap()
    app.buttons["music-sort-filter"].tap()
    for _ in 0..<3 {
      if lower.isHittable && upper.isHittable { break }
      sheet.swipeUp()
    }
    XCTAssertTrue(lower.waitForExistence(timeout: 5))
    XCTAssertEqual(lower.value as? String, "1998")
    XCTAssertEqual(upper.value as? String, "2025")
    XCTAssertFalse(all.isSelected)
    XCTAssertEqual(feedback.value as? String, "0")
    XCTAssertTrue(sheet.frame.contains(all.frame))
    XCTAssertTrue(sheet.frame.contains(lower.frame))
    XCTAssertTrue(sheet.frame.contains(upper.frame))
    XCTAssertEqual(all.frame.midY, lower.frame.midY, accuracy: 2)
    XCTAssertEqual(lower.frame.midY, upper.frame.midY, accuracy: 2)
    XCTAssertGreaterThan(all.frame.midX, lower.frame.midX)
    XCTAssertGreaterThan(
      lower.frame.midX, upper.frame.midX, "The actual RTL rail must be mirrored within bounds")
    all.tap()
    XCTAssertEqual(lower.value as? String, "1951")
    XCTAssertEqual(upper.value as? String, "2025")
    let rtlOrigin = lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let rtlShift = (upper.frame.midX - lower.frame.midX) * 47 / 74
    XCTAssertLessThan(rtlShift, 0)
    rtlOrigin.press(
      forDuration: 0.1, thenDragTo: rtlOrigin.withOffset(CGVector(dx: rtlShift, dy: 0)))
    XCTAssertEqual(lower.value as? String, "1998", "Physical left increases the lower year in RTL")
    XCTAssertEqual(upper.value as? String, "2025")
    XCTAssertFalse(all.isSelected)
    capture("music-release-years-dark-large-rtl", app: app, screen: true)
    all.tap()
    XCTAssertTrue(all.isSelected)
    app.buttons["close-browse-sheet"].tap()
    XCTAssertTrue(app.buttons["Open After the last train"].waitForExistence(timeout: 5))
    app.tabBars.buttons["Search"].tap()
    XCTAssertTrue(app.buttons["search-filter-All"].isSelected)
    XCTAssertTrue(app.staticTexts["Search your music"].exists)
    dismissSearchKeyboard(app)
    app.terminate()
    app.launchArguments = ["--fixture", "--muted", "--single-library"]
    app.launch()
    XCTAssertTrue(music.waitForExistence(timeout: 8))
    music.tap()
    app.buttons["music-category-Albums"].tap()
    chooseBrowseLayout(app, "List")
    app.buttons["music-sort-filter"].tap()
    showYearRail(app)
    all.tap()
    XCTAssertEqual(lower.value as? String, "1700")
    XCTAssertEqual(upper.value as? String, "2026")
    app.buttons["browse-years-from"].tap()
    replaceYear(app, id: "year-editor-from", value: "0")
    XCTAssertFalse(app.buttons["year-editor-done"].isEnabled)
    app.buttons["year-editor-cancel"].tap()
    XCTAssertTrue(all.isSelected, "Invalid and cancelled local drafts cannot change accepted All")
    app.buttons["browse-years-from"].tap()
    replaceYear(app, id: "year-editor-from", value: "1970")
    replaceYear(app, id: "year-editor-to", value: "1980")
    XCTAssertTrue(app.buttons["year-editor-done"].isEnabled)
    app.buttons["year-editor-done"].tap()
    XCTAssertEqual(app.staticTexts["browse-years-caption"].label, "1970–1980")
    XCTAssertFalse(all.isSelected)
    app.buttons["close-browse-sheet"].tap()
    XCTAssertTrue(app.staticTexts["No albums yet"].waitForExistence(timeout: 5))
    app.buttons["music-sort-filter"].tap()
    showYearRail(app)
    app.buttons["browse-years-to"].tap()
    XCTAssertTrue(app.buttons["year-editor-keyboard"].waitForExistence(timeout: 3))
    app.buttons["year-editor-keyboard"].tap()
    app.buttons["year-editor-decade"].tap()
    XCTAssertFalse(app.buttons["1800–1809"].exists, "No invented empty-decade choices")
    XCTAssertTrue(app.buttons["2020–2029"].exists)
    app.buttons["1700–1709"].tap()
    app.buttons["year-editor-done"].tap()
    XCTAssertEqual(app.staticTexts["browse-years-caption"].label, "1700–1709")
    app.buttons["close-browse-sheet"].tap()
    XCTAssertTrue(app.buttons["Open Soft geometry · Volume 16"].waitForExistence(timeout: 5))
    app.buttons["music-sort-filter"].tap()
    showYearRail(app)
    XCTAssertEqual(feedback.value as? String, "0")
    for _ in 0..<2 {
      if feedback.isHittable { break }
      sheet.swipeUp()
    }
    feedback.tap()
    XCTAssertEqual(feedback.value as? String, "1")
    capture("music-release-years-wide-exact", app: app, screen: true)
    all.tap()
    XCTAssertTrue(all.isSelected)
    app.buttons["close-browse-sheet"].tap()
    XCTAssertTrue(app.buttons["Open After the last train"].waitForExistence(timeout: 5))
  }
  @MainActor func testAlbumGradientFollowsOpenedCoverWhileAnotherAlbumIsPaused() throws {
    let app = launchMutedPlaylistFixture()
    let home = app.scrollViews["home-scroll"]
    let play = home.buttons["Play The quiet hours"]
    XCTAssertTrue(play.waitForExistence(timeout: 8))
    revealInBrowse(play, app: app)
    play.tap()
    let toggle = app.buttons["mini-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if toggle.label == "Pause" { toggle.tap() }
    let playingTitle = app.staticTexts["mini-title"].label
    let cool = home.buttons["Open The quiet hours"]
    revealInBrowse(cool, app: app)
    cool.tap()

    func check(_ title: String, color: String, accepts: (Int) -> Bool) throws {
      let heading = app.staticTexts["album-heading"]
      XCTAssertTrue(heading.waitForExistence(timeout: 5))
      XCTAssertEqual(heading.label, title)
      let screen = app.frame
      let upper = app.navigationBars.firstMatch.frame.maxY + 25
      let lower = app.buttons["album-play"].frame.maxY + 8
      let deadline = Date().addingTimeInterval(5)
      var hero = [Int]()
      var tracks = [Int]()
      repeat {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        hero = try screenColor(image, screen: screen, y: upper)
        tracks = try screenColor(image, screen: screen, y: lower)
      } while !accepts(hero[0] - hero[2]) && Date() < deadline
      XCTContext.runActivity(named: "Album palette \(color) hero=\(hero) tracks=\(tracks)") { _ in }
      XCTAssertTrue(accepts(hero[0] - hero[2]), "Unexpected album color \(hero)")
      XCTAssertLessThanOrEqual((tracks.max() ?? 255) - (tracks.min() ?? 0), 3)
      XCTAssertEqual(app.staticTexts["mini-title"].label, playingTitle)
      XCTAssertEqual(toggle.label, "Play")
      capture("album-gradient-" + color, app: app)
    }

    try check("The quiet hours", color: "cool") { $0 <= -5 }
    openSearch(app)
    let field = app.textFields["global-search-field"]
    field.typeText("A field guide\n")
    let albums = app.buttons["search-filter-Albums"]
    XCTAssertTrue(albums.waitForExistence(timeout: 5))
    albums.tap()
    let warm = app.buttons["Open A field guide to distant weather"].firstMatch
    XCTAssertTrue(warm.waitForExistence(timeout: 5))
    warm.tap()
    try check("A field guide to distant weather", color: "warm") { $0 >= 10 }
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.buttons["Clear search"].tap()
    field.typeText("Soft geometry\n")
    let missing = app.buttons["Open Soft geometry"].firstMatch
    XCTAssertTrue(missing.waitForExistence(timeout: 5))
    missing.tap()
    try check("Soft geometry", color: "neutral") { abs($0) <= 2 }
  }

  @MainActor func testAlbumTracksScrollBehindBothBarsAndLastTrackPlays() throws {
    let app = launchMutedPlaylistFixture(longAlbum: true)
    openSearch(app)
    app.textFields["global-search-field"].typeText("After the last train\n")
    app.buttons["search-filter-Albums"].tap()
    let album = app.buttons["Open After the last train"].firstMatch
    XCTAssertTrue(album.waitForExistence(timeout: 6))
    album.tap()
    let scroll = app.scrollViews["album-scroll"]
    let first = scroll.buttons["song-fixture-album-3-track-0"]
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    XCTAssertTrue(first.isHittable)
    first.tap()
    let toggle = app.buttons["mini-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if toggle.label == "Pause" { toggle.tap() }
    let viewport = scroll.frame
    XCTAssertEqual(viewport.minY, app.frame.minY, accuracy: 1)
    XCTAssertEqual(viewport.maxY, app.frame.maxY, accuracy: 1)
    let header = app.navigationBars.firstMatch.frame.maxY
    let mini = app.buttons["Open now playing"].frame.minY
    var topRow: String?
    var bottomRow: String?
    for step in 0..<12 {
      for row in try browseRows(scroll) where row.id.hasPrefix("song-fixture-album-3-track-") {
        if row.frame.minY < header - 2 && row.frame.maxY > header + 2 { topRow = row.id }
        if row.frame.minY < mini - 2 && row.frame.maxY > mini + 2 { bottomRow = row.id }
      }
      if topRow != nil && bottomRow != nil { break }
      dragBrowsePage(app, points: step.isMultiple(of: 2) ? -137 : -159)
    }
    let top = try XCTUnwrap(topRow)
    let bottom = try XCTUnwrap(bottomRow)
    XCTContext.runActivity(
      named:
        "Album edges viewport=\(viewport.minY),\(viewport.maxY) header=\(header) mini=\(mini) upper=\(top) lower=\(bottom)"
    ) { _ in }
    capture("album-tracks-glass", app: app)
    let last = scroll.buttons["song-fixture-album-3-track-17"]
    for _ in 0..<10 {
      if last.exists, !last.frame.isEmpty, last.frame.midY > header, last.frame.maxY <= mini,
        last.isHittable
      {
        break
      }
      dragBrowsePage(app, points: -220)
    }
    XCTAssertTrue(last.isHittable)
    XCTAssertLessThanOrEqual(last.frame.maxY, mini)
    last.tap()
    let title = app.staticTexts["mini-title"]
    expectation(
      for: NSPredicate(format: "label == %@", "Night train · Variation 14"), evaluatedWith: title)
    waitForExpectations(timeout: 5)
    XCTAssertEqual(toggle.label, "Pause")
    toggle.tap()
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(album.waitForExistence(timeout: 5))
    XCTAssertEqual(toggle.label, "Play")
  }

  @MainActor func testCompactAlbumActionsAndEntityMetadata() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--transport-ui=" + UUID().uuidString]
    addTeardownBlock { MainActor.assumeIsolated { app.terminate() } }
    app.launch()
    let album = app.buttons["Open The quiet hours"]
    XCTAssertTrue(album.waitForExistence(timeout: 8))
    album.tap()
    let first = app.buttons["song-fixture-track-0"]
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    XCTAssertTrue(first.isHittable, "Compact default keeps the first track reachable immediately")
    let play = app.buttons["album-play"]
    let favorite = app.buttons["album-favorite"]
    let shuffle = app.buttons["album-shuffle"]
    let actions = app.buttons["album-actions"]
    for control in [play, favorite, shuffle, actions] {
      XCTAssertTrue(control.isHittable)
      XCTAssertGreaterThanOrEqual(control.frame.height + 0.000001, 44)
      XCTAssertGreaterThanOrEqual(control.frame.width + 0.000001, 44)
    }
    XCTAssertEqual(favorite.label, "Add to favorites")
    favorite.tap()
    let saved = NSPredicate(
      format: "label == %@ AND value != %@", "Remove from favorites", "Saving")
    expectation(for: saved, evaluatedWith: favorite)
    waitForExpectations(timeout: 5)
    favorite.tap()
    expectation(
      for: NSPredicate(format: "label == %@ AND value != %@", "Add to favorites", "Saving"),
      evaluatedWith: favorite)
    waitForExpectations(timeout: 5)
    app.buttons["Album details"].tap()
    XCTAssertTrue(app.staticTexts["Release year"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["1998"].exists)
    XCTAssertTrue(app.staticTexts["music-overview"].exists)
    XCTAssertFalse(app.staticTexts["Born"].exists)
    capture("album-compact-details", app: app, screen: true)
    app.buttons["Album details"].tap()
    app.buttons["song-actions-fixture-track-0"].tap()
    app.buttons["Track information"].tap()
    XCTAssertTrue(app.staticTexts["FLAC"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Original file"].exists)
    XCTAssertTrue(app.staticTexts["48.0 kHz"].exists)
    app.buttons["close-track-information"].tap()
    shuffle.tap()
    let mini = app.buttons["Open now playing"]
    XCTAssertTrue(mini.waitForExistence(timeout: 5))
    expectation(for: NSPredicate(format: "label == %@", "Pause album"), evaluatedWith: play)
    waitForExpectations(timeout: 5)
    play.tap()
    XCTAssertEqual(play.label, "Play album")
    let title = app.staticTexts["mini-title"].label
    actions.tap()
    app.buttons["Play next"].tap()
    XCTAssertEqual(app.staticTexts["mini-title"].label, title)
    XCTAssertEqual(app.buttons["mini-toggle"].label, "Play", "Enqueue preserves explicit pause")
    openPlayerQueue(app)
    let queue = app.descendants(matching: .any).matching(identifier: "queue-list").firstMatch
    XCTAssertTrue(queue.waitForExistence(timeout: 3))
    for track in ["First light", "A place to return", "Slow current", "Still here"] {
      XCTAssertGreaterThanOrEqual(
        queue.buttons.matching(NSPredicate(format: "label CONTAINS %@", track)).count, 2)
    }
    closePlayerQueue(app)
    app.buttons["North Window"].tap()
    let information = app.buttons["artist-information"]
    XCTAssertTrue(information.waitForExistence(timeout: 5))
    information.tap()
    XCTAssertTrue(app.staticTexts["music-overview"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Release year"].exists)
    XCTAssertFalse(app.staticTexts["Released"].exists)
    XCTAssertFalse(app.staticTexts["Born"].exists)
    XCTAssertFalse(app.staticTexts["Formed"].exists)
    capture("artist-entity-information", app: app, screen: true)
    app.buttons["close-artist-information"].tap()
  }
  @MainActor func testInfiniteAlbumsBeyondRetentionAndSearchEmptyRecovery() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    let run = UUID().uuidString
    app.launchArguments = ["--fixture", "--muted", "--transport-ui=" + run]
    addTeardownBlock { MainActor.assumeIsolated { app.terminate() } }
    app.launch()
    XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 8))
    app.tabBars.buttons["Library"].tap()
    let collection = app.collectionViews["music-collection"]
    XCTAssertTrue(collection.buttons["Open The quiet hours"].waitForExistence(timeout: 5))
    let last = app.buttons["Open The river remembers · Volume 16"]
    for _ in 0..<36 {
      if last.exists && last.isHittable
        && last.frame.maxY <= app.tabBars.buttons["Library"].frame.minY
      {
        break
      }
      collection.swipeUp(velocity: .fast)
    }
    XCTAssertTrue(
      last.isHittable, "Infinite scroll must append beyond120 visited records")
    XCTAssertLessThan(
      collection.cells.count, 48, "Native cells stay bounded while visited metadata grows")
    XCTAssertLessThanOrEqual(last.frame.maxY, app.tabBars.buttons["Library"].frame.minY)
    XCTAssertGreaterThan(collection.frame.maxY, app.tabBars.buttons["Library"].frame.minY)
    capture("music-infinite-end", app: app, screen: true)
    for _ in 0..<36 {
      if app.buttons["Open The quiet hours"].exists
        && app.buttons["Open The quiet hours"].isHittable
      {
        break
      }
      collection.swipeDown(velocity: .fast)
    }
    XCTAssertTrue(
      app.buttons["Open The quiet hours"].isHittable,
      "Visited first records remain reachable without metadata reload")
    openSearch(app)
    let search = app.textFields["global-search-field"].firstMatch
    search.tap()
    search.typeText("no-invented-match")
    XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5))
    capture("music-search-empty", app: app)
    app.buttons["Clear search"].tap()
    XCTAssertTrue(app.staticTexts["Search your music"].waitForExistence(timeout: 5))
    XCTAssertFalse(
      app.buttons["Open The quiet hours"].exists, "Empty Search is quiet, not an album listing")
  }
  @MainActor func testSongWindowEvictionAndDetailBackAnchor() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--window-fixture"]
    app.launch()
    XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 8))
    app.tabBars.buttons["Library"].tap()
    app.buttons["Songs"].tap()
    chooseBrowseLayout(app, "List")
    app.buttons["music-sort-filter"].tap()
    app.buttons["browse-sort-title"].tap()
    app.buttons["browse-favorites-all"].tap()
    XCTAssertTrue(app.buttons["browse-sort-title"].isSelected)
    XCTAssertTrue(app.buttons["browse-favorites-all"].isSelected)
    let sheet = app.scrollViews["music-browse-sheet"]
    let allYears = app.buttons["browse-years-all"]
    for _ in 0..<3 {
      if allYears.isHittable { break }
      sheet.swipeUp()
    }
    XCTAssertTrue(allYears.waitForExistence(timeout: 5))
    XCTAssertTrue(allYears.isHittable)
    allYears.tap()
    XCTAssertTrue(allYears.isSelected)
    app.buttons["close-browse-sheet"].tap()
    let collection = app.collectionViews["music-collection"]
    let firstSong = collection.buttons["song-fixture-track-0"]
    XCTAssertTrue(firstSong.waitForExistence(timeout: 5))
    XCTAssertTrue(firstSong.isHittable, "Offscreen boundaries must not drain the initial window")
    var selected: XCUIElement?
    for _ in 0..<28 {
      selected = app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "song-fixture-album-")
      ).allElementsBoundByIndex.first { element in
        let parts = element.identifier.split(separator: "-")
        return parts.count == 6 && (Int(parts[3]) ?? 0) >= 30 && element.isHittable
          && element.frame.midY > app.frame.height * 0.3
          && element.frame.midY < app.frame.height * 0.65
      }
      if selected != nil { break }
      collection.swipeUp(velocity: .slow)
    }
    let targetID = try XCTUnwrap(
      selected, "Songs must remain reachable beyond the old eviction boundary"
    ).identifier
    var target = collection.buttons[targetID]
    target.tap()
    let baseline = try XCTUnwrap(
      catalogGeometry(
        app, targetID: targetID, landscape: false, timeout: 5, requiresPlayer: true))
    XCTAssertTrue(app.buttons["Open now playing"].exists)
    let before = baseline.offset
    let portraitSizes = (window: baseline.window.size, viewport: baseline.viewport.size)
    chooseBrowseLayout(app, "Grid")
    target = collection.buttons[targetID]
    XCTAssertTrue(target.waitForExistence(timeout: 3))
    chooseBrowseLayout(app, "List")
    let listed = try XCTUnwrap(
      catalogGeometry(
        app, targetID: targetID, landscape: false, timeout: 3, expectedSizes: portraitSizes))
    XCTAssertTrue(collection.buttons[targetID].isHittable)
    XCTAssertEqual(listed.offset, before, accuracy: 3)
    XCUIDevice.shared.orientation = .landscapeLeft
    let landscape = catalogGeometry(app, targetID: targetID, landscape: true, timeout: 3)
    if landscape == nil { capture("songs-landscape-failure", app: app, screen: true) }
    XCTAssertNotNil(landscape)
    XCUIDevice.shared.orientation = .portrait
    let portrait = catalogGeometry(
      app, targetID: targetID, landscape: false, timeout: 3, expectedSizes: portraitSizes)
    if portrait == nil { capture("songs-portrait-readiness-failure", app: app, screen: true) }
    let returned = try XCTUnwrap(portrait)
    XCTAssertTrue(collection.buttons[targetID].isHittable)
    let portraitOffset = returned.offset
    let portraitPositionMatches = abs(portraitOffset - before) <= 3
    if !portraitPositionMatches { capture("songs-portrait-return-failure", app: app, screen: true) }
    XCTAssertEqual(portraitOffset, before, accuracy: 3)
    XCTAssertLessThan(collection.cells.count, 48)
    let action = collection.buttons["song-actions-" + targetID.dropFirst("song-".count)]
    XCTAssertTrue(action.isHittable)
    action.tap()
    app.buttons["Go to album"].tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    let back = try XCTUnwrap(
      catalogGeometry(
        app, targetID: targetID, landscape: false, timeout: 3, expectedSizes: portraitSizes))
    XCTAssertTrue(collection.buttons[targetID].isHittable)
    XCTAssertEqual(back.offset, before, accuracy: 2)
    for _ in 0..<48 {
      let first = app.buttons["song-fixture-track-0"]
      if first.exists && first.isHittable { break }
      collection.swipeDown(velocity: .fast)
    }
    XCTAssertTrue(app.buttons["song-fixture-track-0"].isHittable)
    capture("songs-reverse-and-return", app: app)
  }
  @MainActor func testDecodedWidePortraitAndFailedArtRemainContained() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted"]
    app.launch()
    let wide = app.buttons["Open The quiet hours"]
    XCTAssertTrue(wide.waitForExistence(timeout: 8))
    XCTAssertEqual(wide.frame.width, wide.frame.height, accuracy: 0.5)
    XCTAssertGreaterThanOrEqual(wide.frame.minX, 16)
    capture("decoded-wide-dashboard", app: app)
    wide.tap()
    XCTAssertTrue(app.buttons["Play First light"].waitForExistence(timeout: 5))
    capture("decoded-wide-album-rows", app: app)
    app.buttons["Play album"].tap()
    XCTAssertTrue(app.buttons["Open now playing"].waitForExistence(timeout: 5))
    capture("decoded-wide-mini", app: app)
    app.buttons["Open now playing"].tap()
    XCTAssertTrue(app.buttons["player-toggle"].waitForExistence(timeout: 4))
    XCTAssertTrue(app.buttons["player-queue"].isHittable)
    capture("decoded-wide-player", app: app)
  }
  @MainActor func testDecodedArtworkPlaceholderLoadedFailureGeometry() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--art-layout"]
    app.launch()
    let load = app.buttons["Load artwork"]
    XCTAssertTrue(load.waitForExistence(timeout: 8))
    let label = app.staticTexts["art-label"]
    let before = label.frame
    capture("art-placeholder", app: app)
    load.tap()
    for name in ["wide", "portrait", "square", "invalid"] {
      XCTAssertEqual(app.staticTexts["art-case"].label, name)
      XCTAssertEqual(label.frame, before)
      let covers = app.descendants(matching: .any).matching(identifier: "cover-art")
      XCTAssertEqual(covers.count, 3)
      for element in covers.allElementsBoundByIndex {
        XCTAssertEqual(element.frame.width, element.frame.height, accuracy: 0.5)
      }
      capture("art-" + name, app: app)
      app.buttons["Next artwork case"].tap()
    }
  }
  @MainActor func testCatalogErrorHasTruthfulRetry() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--catalog-error"]
    app.launch()
    XCTAssertTrue(app.buttons["Retry"].firstMatch.waitForExistence(timeout: 8))
    capture("dashboard-error", app: app)
    app.tabBars.buttons["Library"].tap()
    XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
    app.buttons["Retry"].tap()
    XCTAssertTrue(
      app.staticTexts["This music couldn’t load. Try again."].waitForExistence(timeout: 5))
    capture("music-error-retry", app: app)
    openSearch(app)
    let field = app.textFields["global-search-field"].firstMatch
    field.typeText("North Window")
    XCTAssertTrue(
      app.staticTexts["This music couldn’t load. Try again."].firstMatch.waitForExistence(
        timeout: 5))
    app.scrollViews["music-collection"].coordinate(
      withNormalizedOffset: CGVector(dx: 0.985, dy: 0.6)
    ).tap()
    assertSearchKeyboardDismissed(app)
    XCTAssertEqual(field.value as? String, "North Window")
  }
  @MainActor func testTabletGlobalSearchAlbumPlayer() throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires an actual iPad idiom")
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted"]
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    let musicTab = app.tabBars.buttons["Library"]
    XCTAssertTrue(musicTab.isHittable)
    musicTab.tap()
    XCTAssertTrue(app.buttons["Artists"].waitForExistence(timeout: 3))
    app.tabBars.buttons["Home"].tap()
    XCTAssertFalse(app.textFields["global-search-field"].exists)
    let search = app.textFields["global-search-field"].firstMatch
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "music-library-picker").count, 1)
    let library = app.buttons["music-library-picker"]
    XCTAssertGreaterThanOrEqual(library.frame.height, 44)
    selectMusicLibrary(app, id: "fixture-concerts")
    XCTAssertTrue(library.value as? String == "Live recordings")
    XCTAssertTrue(app.buttons["Open After the last train"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Open The quiet hours"].exists)
    selectMusicLibrary(app, id: "fixture-music")
    XCTAssertTrue(library.value as? String == "Music")
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 5))
    capture("tablet-dashboard", app: app)
    openSearch(app)
    search.typeText("Mira Sol")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    let searchSurface = app.otherElements["music-search-surface"].firstMatch
    XCTAssertTrue(searchSurface.exists)
    XCTAssertGreaterThanOrEqual(searchSurface.frame.height + 1e-9, 44)
    XCTAssertLessThanOrEqual(search.frame.width, 360)
    XCTAssertLessThanOrEqual(search.frame.maxX, app.buttons["Accounts"].frame.minX)
    capture("search-tablet-keyboard", app: app, screen: true)
    search.typeText("\n")
    searchSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.1)).tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    search.typeText("\n")
    XCTAssertTrue(app.buttons["Songs"].firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(app.textFields.matching(identifier: "global-search-field").count, 1)
    app.buttons["Songs"].firstMatch.tap()
    XCTAssertTrue(app.buttons["Play First light"].firstMatch.waitForExistence(timeout: 5))
    capture("tablet-search", app: app)
    app.buttons["Play First light"].firstMatch.tap()
    app.buttons["Actions for First light"].firstMatch.tap()
    app.buttons["Go to album"].tap()
    let reachedAlbum = app.buttons["Play album"].waitForExistence(timeout: 5)
    XCTAssertTrue(reachedAlbum)
    capture("tablet-album", app: app)
    app.buttons["Open now playing"].tap()
    XCTAssertTrue(app.buttons["player-toggle"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["player-queue"].isHittable)
    capture("tablet-player", app: app)
    let toggle = app.buttons["player-toggle"]
    if toggle.label == "Pause" { toggle.tap() }
    let current = app.staticTexts["player-title"].label
    app.buttons["close-player"].tap()
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(app.tabBars.buttons["Search"].isSelected)
    XCTAssertEqual(search.value as? String, "Mira Sol")
    XCTAssertTrue(app.buttons["search-filter-Songs"].isSelected)
    app.buttons["Clear search"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    dismissSearchKeyboard(app)
    app.tabBars.buttons["Home"].tap()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 3))
    XCTAssertEqual(app.staticTexts["mini-title"].label, current)
    XCTAssertEqual(app.buttons["mini-toggle"].label, "Play")
  }
  @MainActor func testSearchBrowsingFocusAndSelectedEntityRecents() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--transport-ui=" + UUID().uuidString]
    addTeardownBlock { MainActor.assumeIsolated { app.terminate() } }
    app.launch()
    let tabs = app.tabBars.firstMatch
    XCTAssertTrue(tabs.buttons["Search"].waitForExistence(timeout: 8))
    let firstStart = ProcessInfo.processInfo.systemUptime
    tabs.buttons["Search"].tap()
    let field = app.textFields["global-search-field"].firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    XCTAssertTrue(field.isHittable)
    let firstEntry = ProcessInfo.processInfo.systemUptime - firstStart
    XCTAssertTrue(app.staticTexts["Search your music"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.keyboards.firstMatch.exists, "A tab opens browsing, not forced editing")
    XCTAssertTrue(tabs.buttons["Search"].isHittable)
    tabs.buttons["Search"].tap()
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 3), "Re-tapping selected Search focuses")
    let focusedTab = tabs.buttons["Search"]
    let focusedRetapExposed =
      focusedTab.isHittable && app.frame.contains(focusedTab.frame)
      && !app.keyboards.firstMatch.frame.intersects(focusedTab.frame)
    if focusedRetapExposed { focusedTab.tap() }
    XCTAssertTrue(
      app.keyboards.firstMatch.exists,
      focusedRetapExposed
        ? "A visible focused Search re-tap does not toggle focus off"
        : "The keyboard remains; no covered native tab tap is synthesized")
    let retapCoverage = XCTAttachment(
      string: "focusedSearchRetapExposed=\(focusedRetapExposed)")
    retapCoverage.name = "search-focused-tab-exposure"
    retapCoverage.lifetime = .keepAlways
    add(retapCoverage)
    XCTAssertFalse(app.buttons["search-done"].exists, "Search has no Done control")
    app.staticTexts["Search your music"].tap()
    assertSearchKeyboardDismissed(app)
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    app.buttons["media-picker"].tap()
    let mediaMusic = app.buttons["media-Music"]
    XCTAssertTrue(mediaMusic.waitForExistence(timeout: 3), "First tap opens the header menu")
    mediaMusic.tap()
    XCTAssertTrue(mediaMusic.waitForNonExistence(timeout: 3))
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    XCTAssertTrue(field.isHittable)
    XCTAssertEqual(field.placeholderValue, "Search music")
    XCTAssertTrue(app.staticTexts["Search your music"].exists)
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    field.typeText("\n")
    assertSearchKeyboardDismissed(app)
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    let collection = app.scrollViews["music-collection"]
    tapVisibleSearchGap(app, anchor: app.staticTexts["Songs, albums and artists"])
    assertSearchKeyboardDismissed(app)
    field.tap()
    let typedStart = ProcessInfo.processInfo.systemUptime
    field.typeText("North Window")
    let artist = app.buttons["Open artist North Window"].firstMatch
    XCTAssertTrue(artist.waitForExistence(timeout: 5), "Live results do not require Return")
    let typedResults = ProcessInfo.processInfo.systemUptime - typedStart
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    tapVisibleSearchGap(app, anchor: artist, trailing: true)
    assertSearchKeyboardDismissed(app)
    XCTAssertEqual(field.value as? String, "North Window")
    XCTAssertTrue(tabs.buttons["Search"].isHittable)
    tabs.buttons["Search"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    let media = app.buttons["media-picker"]
    let library = app.buttons["music-library-picker"]
    let account = app.buttons["Accounts"]
    let headerLibrary = try XCTUnwrap(library.value as? String)
    let headerControls = [media, library, account]
    for control in headerControls {
      XCTAssertTrue(control.isHittable, "The existing controls remain exposed, not in overflow")
      XCTAssertGreaterThanOrEqual(control.frame.width + 1e-6, 44)
      XCTAssertGreaterThanOrEqual(control.frame.height + 1e-6, 44)
      XCTAssertTrue(app.frame.contains(control.frame))
    }
    let titleFont = UIFont.preferredFont(
      forTextStyle: .title3,
      compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
    let titleWidth = ("Music" as NSString).size(
      withAttributes: [.font: UIFont.systemFont(ofSize: titleFont.pointSize, weight: .semibold)]
    ).width
    XCTAssertGreaterThanOrEqual(media.frame.width + 1e-6, titleWidth + 6)
    XCTAssertEqual(library.frame.midY, account.frame.midY, accuracy: 2)
    XCTAssertLessThanOrEqual(library.frame.maxX, account.frame.minX + 2)
    XCTAssertLessThanOrEqual(
      media.frame.minX - app.frame.minX, 24, "The media title stays at the leading edge")
    XCTAssertLessThanOrEqual(
      app.frame.maxX - account.frame.maxX, 24, "Library/account stay at the trailing edge")
    let headerFrames = headerControls.map(\.frame)
    let gapTop = try XCTUnwrap(headerFrames.map(\.minY).max())
    let gapBottom = try XCTUnwrap(headerFrames.map(\.maxY).min())
    let headerGap = CGRect(
      x: media.frame.maxX, y: gapTop, width: library.frame.minX - media.frame.maxX,
      height: gapBottom - gapTop)
    let headerPoint = try XCTUnwrap(
      headerGap.minX.isFinite && headerGap.minY.isFinite && headerGap.width.isFinite
        && headerGap.height.isFinite && headerGap.width > 2
        && headerGap.height > 2 ? CGPoint(x: headerGap.midX, y: headerGap.midY) : nil,
      "The existing root toolbar must expose a real internal nonpressable gap")
    XCTAssertTrue(app.frame.contains(headerPoint))
    XCTAssertFalse(headerFrames.contains { $0.contains(headerPoint) })
    XCTAssertFalse(field.frame.contains(headerPoint))
    XCTAssertFalse(app.keyboards.firstMatch.frame.contains(headerPoint))
    app.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: headerPoint.x - app.frame.minX, dy: headerPoint.y - app.frame.minY)
    ).tap()
    assertSearchKeyboardDismissed(app)
    XCTAssertEqual(field.value as? String, "North Window")
    XCTAssertEqual(library.value as? String, headerLibrary)
    XCTAssertTrue(tabs.buttons["Search"].isHittable)
    tabs.buttons["Search"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    app.buttons["search-filter-Artists"].tap()
    assertSearchKeyboardDismissed(app)
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    artist.tap()
    XCTAssertTrue(app.staticTexts["artist-heading"].waitForExistence(timeout: 5))
    let backStart = ProcessInfo.processInfo.systemUptime
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    let backEntry = ProcessInfo.processInfo.systemUptime - backStart
    assertSearchKeyboardDismissed(app)
    XCTAssertEqual(field.value as? String, "North Window")
    let clear = app.buttons["Clear search"]
    XCTAssertGreaterThanOrEqual(clear.frame.width + 1e-6, 44)
    XCTAssertGreaterThanOrEqual(clear.frame.height + 1e-6, 44)
    clear.tap()
    XCTAssertTrue(app.staticTexts["Recent searches"].waitForExistence(timeout: 5))
    XCTAssertTrue(artist.exists)
    XCTAssertTrue(app.keyboards.firstMatch.exists, "Clear allows continued typing")
    app.buttons["search-filter-Albums"].tap()
    assertSearchKeyboardDismissed(app)
    XCTAssertFalse(artist.exists, "The existing type filter also filters recents")
    app.buttons["search-filter-All"].tap()
    XCTAssertTrue(artist.exists)
    field.tap()
    field.typeText("North Window")
    app.buttons["search-filter-Albums"].tap()
    let album = app.buttons["Open The quiet hours"].firstMatch
    XCTAssertTrue(album.waitForExistence(timeout: 5))
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    album.tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5), "First tap opens the row")
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    assertSearchKeyboardDismissed(app)
    clear.tap()
    app.buttons["search-filter-All"].tap()
    assertSearchKeyboardDismissed(app)
    XCTAssertTrue(artist.exists)
    XCTAssertTrue(album.exists)
    field.tap()
    field.typeText("First light")
    app.buttons["search-filter-Songs"].tap()
    let song = app.buttons["Play First light"].firstMatch
    XCTAssertTrue(song.waitForExistence(timeout: 5))
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    let menu = app.buttons["Actions for First light"].firstMatch
    let menuSearchLibrary = try XCTUnwrap(app.buttons["music-library-picker"].value as? String)
    menu.tap()
    XCTAssertTrue(
      app.buttons["Go to album"].waitForExistence(timeout: 3), "The first tap opens the menu")
    app.buttons["Go to album"].tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    XCTAssertTrue(field.isHittable)
    XCTAssertEqual(field.value as? String, "First light")
    XCTAssertTrue(app.buttons["search-filter-Songs"].isSelected)
    XCTAssertEqual(app.buttons["music-library-picker"].value as? String, menuSearchLibrary)
    assertSearchKeyboardDismissed(app)
    clear.tap()
    app.buttons["search-filter-All"].tap()
    assertSearchKeyboardDismissed(app)
    XCTAssertTrue(song.exists)
    let remove = app.buttons["remove-search-recent-fixture-artist-0"]
    XCTAssertTrue(remove.isHittable)
    XCTAssertGreaterThanOrEqual(remove.frame.height + 1e-6, 44)
    XCTAssertGreaterThanOrEqual(remove.frame.width + 1e-6, 44)
    XCTAssertFalse(app.buttons["Open now playing"].exists)
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    remove.tap()
    XCTAssertFalse(artist.exists)
    XCTAssertFalse(app.buttons["Open now playing"].exists, "Remove never invokes a row/play action")
    XCTAssertTrue(app.keyboards.firstMatch.exists, "Remove keeps its own action and editing focus")
    XCTAssertEqual(field.placeholderValue, "Search music")
    XCTAssertTrue(app.staticTexts["Recent searches"].exists)
    dismissSearchKeyboard(app)
    XCTAssertTrue(tabs.buttons["Library"].isHittable)
    tabs.buttons["Library"].tap()
    XCTAssertTrue(tabs.buttons["Library"].isSelected)
    let warmStart = ProcessInfo.processInfo.systemUptime
    XCTAssertTrue(tabs.buttons["Search"].isHittable)
    tabs.buttons["Search"].tap()
    XCTAssertTrue(tabs.buttons["Search"].isSelected)
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    XCTAssertTrue(field.isHittable)
    let warmEntry = ProcessInfo.processInfo.systemUptime - warmStart
    assertSearchKeyboardDismissed(app)
    XCTAssertTrue(song.exists)
    XCTAssertTrue(album.exists)
    XCTAssertFalse(artist.exists)
    XCTAssertTrue(tabs.buttons["Search"].isHittable)
    tabs.buttons["Search"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    XCTAssertEqual(field.placeholderValue, "Search music")
    XCTAssertTrue(app.staticTexts["Recent searches"].exists)
    app.buttons["search-filter-Songs"].tap()
    XCTAssertTrue(song.exists)
    XCTAssertFalse(album.exists)
    field.tap()
    field.typeText("North Window")
    XCTAssertTrue(song.waitForExistence(timeout: 5))
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.exists)
    let controlsBottom = app.buttons["search-filter-Songs"].frame.maxY
    let startY = (controlsBottom + keyboard.frame.minY) / 2
    let origin = app.coordinate(withNormalizedOffset: .zero)
    let start = origin.withOffset(CGVector(dx: collection.frame.midX, dy: startY))
    let end = origin.withOffset(CGVector(dx: collection.frame.midX, dy: app.frame.maxY - 28))
    start.press(forDuration: 0.08, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    assertSearchKeyboardDismissed(app)
    XCTAssertEqual(field.value as? String, "North Window")
    let timing = XCTAttachment(
      string:
        "firstSearchEntry=\(firstEntry)\nwarmSearchReturn=\(warmEntry)\ndetailBack=\(backEntry)\ntypingThroughResults=\(typedResults)"
    )
    timing.name = "search-interaction-seconds"
    timing.lifetime = .keepAlways
    add(timing)
    capture("search-selected-recents", app: app, screen: true)
  }
  @MainActor func testCenterSearchTabRetainsPathsScopeScrollAndPlayback() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--transport-ui=" + UUID().uuidString]
    addTeardownBlock { MainActor.assumeIsolated { app.terminate() } }
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    let tabs = app.tabBars.firstMatch
    let dashboard = tabs.buttons["Home"]
    let searchTab = tabs.buttons["Search"]
    let music = tabs.buttons["Library"]
    XCTAssertEqual(tabs.buttons.count, 3)
    XCTAssertLessThan(dashboard.frame.midX, searchTab.frame.midX)
    XCTAssertLessThan(searchTab.frame.midX, music.frame.midX)
    XCTAssertEqual(searchTab.frame.midX, (dashboard.frame.midX + music.frame.midX) / 2, accuracy: 3)
    XCTAssertGreaterThanOrEqual(searchTab.frame.height, 44)
    app.buttons["Open The quiet hours"].tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
    app.buttons["Play album"].tap()
    let toggle = app.buttons["mini-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if toggle.label == "Pause" { toggle.tap() }
    let current = app.staticTexts["mini-title"].label
    searchTab.tap()
    XCTAssertTrue(searchTab.isSelected)
    let field = app.textFields["global-search-field"].firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Search your music"].exists)
    XCTAssertFalse(app.buttons["Close search"].exists)
    app.buttons["search-filter-Songs"].tap()
    field.tap()
    field.typeText("Marchand\n")
    selectMusicLibrary(app, id: "fixture-concerts")
    XCTAssertTrue(app.buttons["Play First light"].firstMatch.waitForExistence(timeout: 5))
    let collection = app.scrollViews["music-collection"]
    collection.swipeUp()
    collection.swipeUp()
    XCTAssertLessThan(collection.frame.minY, field.frame.minY)
    XCTAssertGreaterThan(collection.frame.maxY, searchTab.frame.minY)
    let headerBottom = app.buttons["search-filter-Songs"].frame.maxY
    let contentBottom = app.buttons["Open now playing"].frame.minY
    let row = try XCTUnwrap(
      collection.buttons.allElementsBoundByIndex.first { element in
        guard element.identifier.hasPrefix("song-fixture-"), element.isHittable,
          element.frame.minY >= headerBottom, element.frame.maxY <= contentBottom
        else { return false }
        let menu = app.buttons[
          "song-actions-" + String(element.identifier.dropFirst("song-".count))]
        return menu.isHittable && menu.frame.minY >= headerBottom
          && menu.frame.maxY <= contentBottom
      })
    let anchor = row.identifier
    let before = row.frame.minY
    capture("search-center-tab-before-leaving", app: app, screen: true)
    music.tap()
    XCTAssertTrue(music.isSelected)
    XCTAssertTrue(app.buttons["Open A field guide to distant weather"].waitForExistence(timeout: 3))
    let firstCover = app.buttons["Open A field guide to distant weather"]
    XCTAssertGreaterThanOrEqual(
      firstCover.frame.minY, app.buttons["music-category-Playlists"].frame.maxY - 1)
    firstCover.tap()
    XCTAssertTrue(app.buttons["Play First light"].firstMatch.waitForExistence(timeout: 5))
    dashboard.tap()
    XCTAssertEqual(app.staticTexts["album-heading"].label, "The quiet hours")
    XCTAssertEqual(app.staticTexts["mini-title"].label, current)
    searchTab.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    assertSearchKeyboardDismissed(app)
    XCTAssertEqual(field.value as? String, "Marchand")
    XCTAssertTrue(app.buttons["search-filter-Songs"].isSelected)
    XCTAssertTrue(app.buttons["music-library-picker"].value as? String == "Live recordings")
    let retained = collection.buttons[anchor]
    XCTAssertTrue(retained.waitForExistence(timeout: 3))
    XCTAssertTrue(retained.isHittable)
    XCTAssertEqual(retained.frame.minY, before, accuracy: 3)
    XCTAssertEqual(app.staticTexts["mini-title"].label, current)
    capture("search-center-tab-retained-results", app: app, screen: true)
    let menu = app.buttons["song-actions-" + String(anchor.dropFirst("song-".count))]
    XCTAssertTrue(menu.isHittable)
    XCTAssertGreaterThanOrEqual(menu.frame.minY, app.buttons["search-filter-Songs"].frame.maxY)
    XCTAssertLessThanOrEqual(menu.frame.maxY, app.buttons["Open now playing"].frame.minY)
    menu.tap()
    let goToAlbum = app.buttons["Go to album"]
    XCTAssertTrue(goToAlbum.exists)
    XCTAssertTrue(goToAlbum.isHittable)
    goToAlbum.tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
    let album = app.staticTexts["album-heading"].label
    music.tap()
    XCTAssertEqual(app.staticTexts["album-heading"].label, "A field guide to distant weather")
    searchTab.tap()
    XCTAssertTrue(searchTab.isSelected)
    XCTAssertEqual(app.staticTexts["album-heading"].label, album)
    dashboard.tap()
    XCTAssertEqual(app.staticTexts["album-heading"].label, "The quiet hours")
    searchTab.tap()
    XCTAssertEqual(app.staticTexts["album-heading"].label, album)
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertEqual(field.value as? String, "Marchand")
    XCTAssertTrue(app.buttons["search-filter-Songs"].isSelected)
    XCTAssertTrue(app.buttons["music-library-picker"].value as? String == "Live recordings")
    XCTAssertEqual(app.staticTexts["mini-title"].label, current)
    assertSearchKeyboardDismissed(app)
    capture("search-center-tab-after-back", app: app, screen: true)
    app.buttons["Open now playing"].tap()
    XCTAssertTrue(app.buttons["player-toggle"].waitForExistence(timeout: 3))
    XCTAssertEqual(app.buttons["player-open-album"].label, "Open album for " + current)
    app.buttons["close-player"].tap()
    openPlayerQueue(app)
    XCTAssertTrue(
      app.navigationBars["Queue"].buttons.element(boundBy: 0).waitForExistence(timeout: 3))
    closePlayerQueue(app)
    XCTAssertTrue(searchTab.isSelected)
    XCTAssertEqual(field.value as? String, "Marchand")
    XCTAssertEqual(toggle.label, "Play")
  }
  @MainActor func testLiveMixedSearchAndScopedArtistNavigation() throws {
    let app = launchMutedPlaylistFixture(slow: true)
    XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 8))
    openSearch(app)
    let field = app.textFields["global-search-field"].firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Search your music"].exists)
    field.typeText("North Window")
    XCTAssertEqual(app.scrollViews["music-collection"].value as? String, "Results updating")
    capture("search-live-reserved-loading", app: app, screen: true)
    let artist = app.buttons["Open artist North Window"]
    XCTAssertTrue(artist.waitForExistence(timeout: 6), "Results must arrive without Return")
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    XCTAssertTrue(app.buttons["search-filter-All"].isSelected)
    tapVisibleSearchGap(app, anchor: artist, trailing: true)
    assertSearchKeyboardDismissed(app)
    XCTAssertEqual(field.value as? String, "North Window")
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    XCTAssertFalse(app.staticTexts["Loading albums…"].exists)
    XCTAssertTrue(artist.exists)
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    XCTAssertTrue(app.buttons["search-filter-All"].isSelected)
    capture("search-live-mixed-keyboard", app: app, screen: true)
    app.buttons["search-filter-Artists"].tap()
    XCTAssertGreaterThanOrEqual(artist.frame.height, 44)
    capture("search-own-artist-portraits", app: app, screen: true)
    artist.tap()
    XCTAssertTrue(app.staticTexts["artist-heading"].waitForExistence(timeout: 4))
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    app.buttons["Clear search"].tap()
    field.typeText("Lantern")
    app.buttons["search-filter-Songs"].tap()
    let longLabel =
      "Play The crossing — Original motion picture soundtrack · Complete orchestral score and extended recording (anniversary remastered edition)"
    let longSong = app.buttons.matching(NSPredicate(format: "label == %@", longLabel)).firstMatch
    XCTAssertTrue(longSong.waitForExistence(timeout: 6))
    XCTAssertEqual(longSong.label, longLabel)
    XCTAssertGreaterThanOrEqual(longSong.frame.height, 44)
    capture("search-live-long-soundtrack", app: app, screen: true)
    app.buttons["Clear search"].tap()
    app.buttons["search-filter-Artists"].tap()
    field.tap()
    field.typeText("Mira Sol")
    XCTAssertTrue(app.buttons["Open artist Mira Sol"].waitForExistence(timeout: 6))
    selectMusicLibrary(app, id: "fixture-concerts")
    XCTAssertTrue(app.buttons["Open artist Mira Sol"].waitForExistence(timeout: 6))
    app.buttons["Open artist Mira Sol"].tap()
    XCTAssertTrue(app.staticTexts["artist-heading"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Open After the last train"].firstMatch.waitForExistence(timeout: 6))
    let aOnly = "Open A field guide to distant weather"
    XCTAssertFalse(app.buttons[aOnly].exists, "This album must be absent from accepted root B")
    selectMusicLibrary(app, id: "fixture-music")
    XCTAssertTrue(app.buttons["music-library-picker"].value as? String == "Music")
    let openAlbum = app.buttons[aOnly].firstMatch
    XCTAssertTrue(openAlbum.waitForExistence(timeout: 6))
    capture("search-artist-child-root-a", app: app, screen: true)
    XCTAssertTrue(
      openAlbum.waitForExistence(timeout: 6),
      "The accepted artist child A must expose its A-only album")
    openAlbum.tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 6))
    XCTAssertTrue(
      app.buttons["Play First light"].firstMatch.waitForExistence(timeout: 6),
      "The A-only album must actually load tracks; an old-parent B callback is denied")
    XCTAssertTrue(app.buttons["Play album"].isEnabled)
    capture("search-child-a-only-album", app: app, screen: true)
    app.navigationBars.buttons["Back"].firstMatch.tap()
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    app.buttons["Clear search"].tap()
    field.typeText("no-invented-match")
    XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 6))
    capture("search-live-no-matches", app: app, screen: true)
    app.buttons["Clear search"].tap()
    XCTAssertTrue(app.staticTexts["Recent searches"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Open artist Mira Sol"].exists)
    dismissSearchKeyboard(app)
    capture("search-center-empty-tabs", app: app, screen: true)
    app.tabBars.buttons["Home"].tap()
    XCTAssertTrue(
      app.buttons["music-library-picker"].value as? String == "Music",
      "Back preserves the independent main root")
  }
  @MainActor func testSearchDarkLargeFocusAndOrigin() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--appearance-dark", "--large-text"]
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    app.buttons["Open The quiet hours"].tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
    app.buttons["Play album"].tap()
    let toggle = app.buttons["mini-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if toggle.label == "Pause" { toggle.tap() }
    let current = app.staticTexts["mini-title"].label
    openSearch(app)
    let search = app.textFields["global-search-field"].firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 3))
    let searchSurface = app.otherElements["music-search-surface"].firstMatch
    XCTAssertTrue(searchSurface.exists)
    XCTAssertGreaterThanOrEqual(searchSurface.frame.height + 1e-9, 44)
    search.typeText("Mira Sol")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    capture("search-dark-large-keyboard", app: app, screen: true)
    let clear = app.buttons["Clear search"]
    XCTAssertTrue(clear.isHittable)
    XCTAssertGreaterThanOrEqual(clear.frame.height + 1e-9, 44)
    clear.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    dismissSearchKeyboard(app)
    capture("search-center-dark-large-tabs", app: app, screen: true)
    let close = app.tabBars.buttons["Home"]
    XCTAssertTrue(close.isHittable)
    XCTAssertGreaterThanOrEqual(close.frame.height + 1e-9, 44)
    close.tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 3))
    XCTAssertEqual(app.staticTexts["mini-title"].label, current)
    XCTAssertEqual(toggle.label, "Play")
    openPlayerQueue(app)
    XCTAssertTrue(
      app.navigationBars["Queue"].buttons.element(boundBy: 0).waitForExistence(timeout: 3))
    let currentRow = app.buttons.matching(
      NSPredicate(format: "value == %@", "Paused")
    ).firstMatch
    XCTAssertTrue(currentRow.exists)
    closePlayerQueue(app)
    XCTAssertEqual(app.staticTexts["mini-title"].label, current)
    let accounts = app.buttons["Accounts"].firstMatch
    XCTAssertTrue(accounts.isHittable)
    XCTAssertGreaterThanOrEqual(accounts.frame.height + 1e-9, 44)
    accounts.tap()
    app.buttons["Connection details"].tap()
    XCTAssertTrue(app.staticTexts["connection-server-address"].waitForExistence(timeout: 3))
    app.buttons["Done"].tap()
    app.navigationBars.buttons["Back"].firstMatch.tap()
    app.scrollViews.firstMatch.swipeDown()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["mini-title"].label, current)
    XCTAssertEqual(toggle.label, "Play")
  }
  @MainActor func testTabletDarkLargeArtworkPlayer() throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires an actual iPad idiom")
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--appearance-dark", "--large-text"]
    app.launch()
    let open = app.buttons["Open The quiet hours"]
    XCTAssertTrue(open.waitForExistence(timeout: 8))
    let emptyTitle = app.staticTexts["Find your next album"]
    XCTAssertLessThanOrEqual(emptyTitle.frame.maxX, app.frame.maxX)
    capture("tablet-dashboard-dark-large", app: app)
    open.tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
    capture("tablet-album-dark-large", app: app)
    app.buttons["Play album"].tap()
    XCTAssertTrue(app.buttons["Open now playing"].waitForExistence(timeout: 5))
    let miniBounds = app.otherElements["mini-player"].frame
    XCTAssertLessThanOrEqual(app.staticTexts["mini-artist"].frame.maxY, miniBounds.maxY)
    app.buttons["Open now playing"].tap()
    XCTAssertTrue(app.buttons["player-toggle"].waitForExistence(timeout: 5))
    capture("tablet-player-dark-large", app: app)
    let queue = app.buttons["player-queue"]
    let quality = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Streaming quality:")
    ).firstMatch
    let playerScroll = app.scrollViews.containing(.button, identifier: "player-toggle").firstMatch
    XCTAssertTrue(playerScroll.waitForExistence(timeout: 3))
    for _ in 0..<5 {
      if queue.isHittable && playerScroll.frame.contains(queue.frame)
        && playerScroll.frame.contains(quality.frame)
      {
        break
      }
      playerScroll.swipeUp()
    }
    XCTAssertTrue(queue.isHittable)
    XCTAssertTrue(quality.isHittable)
    XCTAssertTrue(playerScroll.frame.contains(queue.frame))
    XCTAssertTrue(playerScroll.frame.contains(quality.frame))
    XCTAssertLessThanOrEqual(app.staticTexts["player-title"].frame.maxX, app.frame.maxX)
    capture("tablet-player-dark-large-controls", app: app)
    let toggle = app.buttons["player-toggle"]
    if toggle.label == "Pause" { toggle.tap() }
    let title = app.staticTexts["player-title"].label
    queue.tap()
    let list = app.descendants(matching: .any).matching(identifier: "queue-list").firstMatch
    let current = list.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    XCTAssertTrue(current.waitForExistence(timeout: 3))
    XCTAssertEqual(current.value as? String, "Paused")
    XCTAssertTrue(current.isHittable)
    XCTAssertTrue(app.frame.contains(current.frame))
    XCTAssertGreaterThanOrEqual(current.frame.height, 44)
    capture("tablet-queue-dark-large", app: app)
    app.navigationBars["Queue"].buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.buttons["close-player"].waitForExistence(timeout: 3))
    XCTAssertEqual(toggle.label, "Play")
  }
  @MainActor func testGuestReduceMotionPlayerInputAndRestoration() throws {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.launch()
    let reduce = settings.switches["Reduce Motion"]
    if !reduce.waitForExistence(timeout: 1) {
      let accessibility = settings.staticTexts["Accessibility"].firstMatch
      for _ in 0..<6 {
        if accessibility.exists && accessibility.isHittable { break }
        settings.swipeUp()
      }
      guard accessibility.exists && accessibility.isHittable else {
        capture("guest-motion-route-unavailable", app: settings, screen: true)
        throw XCTSkip("Owned guest Settings Accessibility route is unavailable")
      }
      accessibility.tap()
      let motion = settings.staticTexts["Motion"].firstMatch
      guard motion.waitForExistence(timeout: 3), motion.isHittable else {
        capture("guest-motion-route-unavailable", app: settings, screen: true)
        throw XCTSkip("Owned guest Motion route is unavailable")
      }
      motion.tap()
    }
    XCTAssertTrue(reduce.waitForExistence(timeout: 3))
    let prior = try XCTUnwrap(reduce.value as? String)
    guard prior == "0" || prior == "1" else {
      throw XCTSkip("Owned guest Reduce Motion does not expose a Boolean state")
    }
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    let flag = "--catalog-scale=" + UUID().uuidString + ":50000"
    registerIndexedCleanup(app, flag: flag)
    print("Guest Reduce Motion prior: \(prior)")
    addTeardownBlock {
      MainActor.assumeIsolated {
        settings.activate()
        guard reduce.waitForExistence(timeout: 3) else {
          XCTFail("Owned guest Motion panel must remain available for restoration")
          return
        }
        if reduce.value as? String != prior {
          reduce.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        let restored = XCTWaiter.wait(
          for: [
            XCTNSPredicateExpectation(
              predicate: NSPredicate(format: "value == %@", prior), object: reduce)
          ], timeout: 3)
        XCTAssertEqual(restored, .completed, "Restore the exact prior guest OS setting")
        if restored == .completed { print("Guest Reduce Motion restored: \(prior)") }
        self.capture("guest-reduce-motion-restored", app: settings, screen: true)
      }
    }
    if prior == "0" {
      reduce.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }
    let on = XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: reduce)
      ], timeout: 3)
    XCTAssertEqual(on, .completed)
    guard on == .completed else { return }
    print("Guest Reduce Motion enabled: 1")
    capture("guest-reduce-motion-on", app: settings, screen: true)
    app.launchArguments = ["--fixture", "--muted", "--text-layout"]
    app.launch()
    let motionTitle = app.staticTexts["text-motion-reading"]
    XCTAssertTrue(motionTitle.waitForExistence(timeout: 5))
    XCTAssertEqual(motionTitle.value as? String, "static")
    let still = motionTitle.screenshot().pngRepresentation
    Thread.sleep(forTimeInterval: 2.2)
    XCTAssertEqual(motionTitle.screenshot().pngRepresentation, still)
    capture("guest-reduce-motion-overflow-static", app: app)
    app.terminate()
    app.launchArguments = ["--fixture", "--muted", flag, "--catalog-scale-ui"]
    app.launch()
    XCTAssertTrue(app.buttons["Play Album 000000"].waitForExistence(timeout: 8))
    app.buttons["Play Album 000000"].firstMatch.tap()
    let mini = app.otherElements["mini-player"]
    let toggle = app.buttons["mini-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if toggle.label == "Pause" { toggle.tap() }
    XCTAssertEqual(toggle.label, "Play")
    let identity = app.staticTexts["mini-title"].label
    let start = mini.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -180)))
    let player = app.buttons["player-toggle"]
    XCTAssertTrue(player.waitForExistence(timeout: 3))
    XCTAssertEqual(player.label, "Play")
    XCTAssertEqual(app.staticTexts["player-title"].label, identity)
    XCTAssertGreaterThanOrEqual(player.frame.height, 44)
    player.tap()
    XCTAssertEqual(player.label, "Pause")
    player.tap()
    XCTAssertEqual(player.label, "Play")
    capture("reduce-motion-player-paused", app: app, screen: true)
    let handle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
    handle.press(forDuration: 0.05, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: 450)))
    XCTAssertTrue(app.buttons["Open now playing"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["close-player"].exists)
    XCTAssertEqual(app.staticTexts["mini-title"].label, identity)
    XCTAssertEqual(toggle.label, "Play")
    capture("reduce-motion-mini-return", app: app, screen: true)
  }
  @MainActor func testPlaybackPresenceStartsAndClears() throws {
    try playbackPresence(large: false)
  }
  @MainActor func testLargePlaybackPresenceStartsAndClears() throws {
    try playbackPresence(large: true)
  }
  @MainActor private func playbackPresence(large: Bool) throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    let flag = "--catalog-scale=" + UUID().uuidString + ":50000"
    app.launchArguments = ["--fixture", "--muted", flag, "--catalog-scale-ui"]
    if large { app.launchArguments += ["--large-text", "--appearance-dark"] }
    registerIndexedCleanup(app, flag: flag)
    app.launch()
    XCTAssertTrue(app.buttons["Open Album 000000"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["Open now playing"].exists)
    capture(large ? "presence-large-empty" : "presence-empty", app: app, screen: true)
    openSearch(app)
    app.buttons["search-filter-Songs"].tap()
    let search = app.textFields["global-search-field"]
    XCTAssertTrue(search.waitForExistence(timeout: 3))
    search.tap()
    search.typeText("Song 000000\n")
    let song = app.buttons["Play Song 000000"]
    XCTAssertTrue(song.waitForExistence(timeout: 5))
    song.tap()
    let mini = app.buttons["Open now playing"]
    XCTAssertTrue(mini.waitForExistence(timeout: 5))
    XCTAssertEqual(search.value as? String, "Song 000000")
    app.buttons["Clear search"].tap()
    dismissSearchKeyboard(app)
    app.tabBars.buttons["Home"].tap()
    let toggle = app.buttons["mini-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 3))
    if toggle.label == "Pause" { toggle.tap() }
    XCTAssertEqual(toggle.label, "Play")
    XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
    capture(large ? "presence-large-current" : "presence-current", app: app, screen: true)
    openPlayerQueue(app)
    let list = app.descendants(matching: .any).matching(identifier: "queue-list").firstMatch
    let current = list.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Song 000000"))
      .firstMatch
    XCTAssertTrue(current.waitForExistence(timeout: 3))
    XCTAssertEqual(current.value as? String, "Paused")
    current.swipeLeft()
    let delete = app.buttons["Delete"]
    XCTAssertTrue(delete.waitForExistence(timeout: 3))
    delete.tap()
    XCTAssertTrue(app.staticTexts["The queue is open"].waitForExistence(timeout: 3))
    XCTAssertFalse(current.exists)
    closePlayerQueue(app)
    XCTAssertTrue(mini.waitForNonExistence(timeout: 3))
    XCTAssertFalse(toggle.exists)
    XCTAssertTrue(app.tabBars.buttons["Search"].isHittable)
    XCTAssertTrue(app.tabBars.buttons["Library"].isHittable)
    capture(large ? "presence-large-cleared" : "presence-cleared", app: app, screen: true)
  }
  @MainActor func testAlbumPlayerQueue() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--slow-fixture"]
    app.launch()
    let open = app.buttons["Open The quiet hours"]
    XCTAssertTrue(open.waitForExistence(timeout: 8))
    capture("library", app: app)
    open.tap()
    let playAlbum = app.buttons["Play album"]
    XCTAssertTrue(playAlbum.waitForExistence(timeout: 5))
    let before = playAlbum.frame
    capture("album-loading", app: app)
    let first = app.buttons["Play First light"]
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    let delta = playAlbum.frame.minY - before.minY
    print("Loading geometry delta: \(delta) pt")
    XCTAssertEqual(delta, 0, accuracy: 0)
    capture("album-ready", app: app)
    playAlbum.tap()
    let mini = app.buttons["Open now playing"]
    XCTAssertTrue(mini.waitForExistence(timeout: 8))
    XCTAssertGreaterThanOrEqual(app.buttons["mini-toggle"].frame.height, 44)
    capture("mini-player-ready", app: app)
    mini.tap()
    let pause = app.buttons["player-toggle"]
    XCTAssertTrue(pause.waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["player-queue"].isHittable)
    capture("player-playing", app: app)
    pause.tap()
    XCTAssertEqual(pause.label, "Play")
    capture("player-paused", app: app)
    app.buttons["player-queue"].tap()
    XCTAssertTrue(app.staticTexts["A place to return"].waitForExistence(timeout: 5))
    let current = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "First light")
    ).firstMatch
    XCTAssertEqual(current.value as? String, "Paused")
    XCTAssertGreaterThanOrEqual(current.frame.height, 44)
    XCTAssertTrue(current.label.contains("Duration: 0:18"))
    capture("queue", app: app)
  }
  @MainActor func testPlayerSheetReturnQualityAndQueueActions() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted"]
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    app.buttons["Open The quiet hours"].tap()
    XCTAssertTrue(app.buttons["Play First light"].waitForExistence(timeout: 5))
    app.buttons["Play album"].tap()
    XCTAssertTrue(app.buttons["Open now playing"].waitForExistence(timeout: 5))
    app.buttons["Open now playing"].tap()
    let toggle = app.buttons["player-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if toggle.label == "Pause" { toggle.tap() }
    XCTAssertEqual(toggle.label, "Play")
    let close = app.buttons["close-player"]
    XCTAssertTrue(close.isHittable)
    XCTAssertGreaterThanOrEqual(close.frame.height + 1e-9, 44)
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Streaming quality:"))
      .firstMatch.tap()
    app.buttons["Original"].tap()
    XCTAssertTrue(app.buttons["Streaming quality: Original"].waitForExistence(timeout: 3))
    app.buttons["Streaming quality: Original"].tap()
    app.buttons["High · 192 kbps"].tap()
    XCTAssertTrue(app.buttons["Streaming quality: High · 192 kbps"].waitForExistence(timeout: 5))
    XCTAssertEqual(toggle.label, "Play", "Quality choice must preserve paused intent")
    let title = app.staticTexts["player-title"].label
    capture("player-high-before-queue", app: app)
    let queueAction = app.buttons["player-queue"]
    let hittable = NSPredicate(format: "hittable == true")
    expectation(for: hittable, evaluatedWith: queueAction)
    waitForExpectations(timeout: 3)
    XCTAssertTrue(
      app.frame.contains(queueAction.frame), "Queue must be inside the presented player")
    queueAction.tap()
    let queueList = app.descendants(matching: .any).matching(identifier: "queue-list").firstMatch
    let queued = queueList.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "A place to return")
    ).firstMatch
    XCTAssertTrue(queued.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["close-queue"].exists, "Pushed Queue uses native Back")
    app.navigationBars["Queue"].buttons.element(boundBy: 0).tap()
    XCTAssertTrue(close.waitForExistence(timeout: 3))
    XCTAssertEqual(app.staticTexts["player-title"].label, title)
    XCTAssertEqual(toggle.label, "Play")
    close.tap()
    XCTAssertTrue(app.buttons["Open now playing"].waitForExistence(timeout: 3))
    openPlayerQueue(app)
    let queueClose = app.navigationBars["Queue"].buttons.element(boundBy: 0)
    XCTAssertTrue(queueClose.waitForExistence(timeout: 3))
    XCTAssertTrue(queueClose.isHittable)
    XCTAssertGreaterThanOrEqual(queueClose.frame.height, 44)
    queued.swipeLeft()
    let delete = app.buttons["Delete"]
    XCTAssertTrue(delete.waitForExistence(timeout: 3))
    delete.tap()
    XCTAssertTrue(queued.waitForNonExistence(timeout: 3))
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.exists)
    queueClose.tap()
    app.buttons["close-player"].tap()
    XCTAssertTrue(app.buttons["Open now playing"].waitForExistence(timeout: 3))
    XCTAssertEqual(app.buttons["mini-toggle"].label, "Play")
    app.buttons["Open now playing"].tap()
    XCTAssertTrue(app.buttons["Streaming quality: High · 192 kbps"].waitForExistence(timeout: 3))
    XCTAssertEqual(app.staticTexts["player-title"].label, title)
    capture("player-quality-queue-return", app: app)
  }
  @MainActor func testMiniPlayerUpwardGestureAndSheetDismissal() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted"]
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    app.buttons["Play The quiet hours"].tap()
    let mini = app.otherElements["mini-player"]
    XCTAssertTrue(mini.waitForExistence(timeout: 5))
    if app.buttons["mini-toggle"].label == "Pause" { app.buttons["mini-toggle"].tap() }
    let start = mini.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -180)))
    XCTAssertTrue(app.buttons["close-player"].waitForExistence(timeout: 3))
    XCTAssertEqual(app.buttons["player-toggle"].label, "Play")
    let title = app.staticTexts["player-title"].label
    let handle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
    handle.press(forDuration: 0.05, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: 450)))
    XCTAssertTrue(app.buttons["Open now playing"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["close-player"].exists)
    XCTAssertEqual(app.staticTexts["mini-title"].label, title)
    XCTAssertEqual(app.buttons["mini-toggle"].label, "Play")
  }
  @MainActor func testShortLandscapePlayerControlsAndReturn() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted"]
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    app.launch()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 8))
    app.buttons["Play The quiet hours"].tap()
    XCTAssertTrue(app.buttons["Open now playing"].waitForExistence(timeout: 5))
    app.buttons["Open now playing"].tap()
    let toggle = app.buttons["player-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if toggle.label == "Pause" { toggle.tap() }
    let title = app.staticTexts["player-title"].label
    expectation(
      for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
    waitForExpectations(timeout: 3)
    capture("player-short-landscape-top", app: app, screen: true)
    XCTAssertTrue(toggle.isHittable)
    XCTAssertTrue(app.buttons["player-queue"].isHittable)
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Streaming quality:"))
        .firstMatch.isHittable)
    XCTAssertEqual(toggle.label, "Play")
    capture("player-short-landscape-controls", app: app, screen: true)
    app.buttons["player-queue"].tap()
    XCTAssertTrue(app.staticTexts["A place to return"].waitForExistence(timeout: 5))
    app.navigationBars["Queue"].buttons.element(boundBy: 0).tap()
    let close = app.buttons["close-player"]
    XCTAssertTrue(close.waitForExistence(timeout: 3))
    XCTAssertTrue(close.isHittable)
    XCTAssertGreaterThanOrEqual(close.frame.height + 1e-9, 44)
    close.tap()
    XCTAssertTrue(app.buttons["Open now playing"].waitForExistence(timeout: 3))
    XCTAssertEqual(app.staticTexts["mini-title"].label, title)
    XCTAssertEqual(app.buttons["mini-toggle"].label, "Play")
  }
  @MainActor func testNearEndScrubKeepsOccurrenceTiming() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted"]
    app.launch()
    let album = app.buttons["Open The quiet hours"]
    XCTAssertTrue(album.waitForExistence(timeout: 8))
    album.tap()
    let play = app.buttons["Play album"]
    XCTAssertTrue(play.waitForExistence(timeout: 5))
    play.tap()
    let mini = app.buttons["Open now playing"]
    XCTAssertTrue(mini.waitForExistence(timeout: 8))
    mini.tap()
    let toggle = app.buttons["player-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    toggle.tap()
    XCTAssertEqual(toggle.label, "Play")
    let slider = app.sliders["Playback position"]
    XCTAssertTrue(slider.isHittable)
    slider.adjust(toNormalizedSliderPosition: 0.9)
    let elapsed = app.staticTexts["player-elapsed"]
    XCTAssertTrue(
      NSPredicate(format: "label == %@", "0:16").evaluate(with: elapsed)
        || XCTWaiter.wait(
          for: [
            XCTNSPredicateExpectation(
              predicate: NSPredicate(format: "label == %@", "0:16"), object: elapsed)
          ], timeout: 3) == .completed
    )
    XCTAssertEqual(toggle.label, "Play")
    toggle.tap()
    let title = app.staticTexts["player-title"]
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "A place to return"), object: title)
        ], timeout: 6), .completed)
    XCTAssertTrue(elapsed.label.hasPrefix("0:0"))
    XCTAssertTrue(app.staticTexts["player-duration"].label.contains("0:18"))
    toggle.tap()
  }
  @MainActor func testExplicitTransportCaptureAndRootRetirement() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted"]
    app.launch()
    let accounts = app.buttons["Accounts"]
    XCTAssertTrue(accounts.waitForExistence(timeout: 8))
    accounts.tap()
    app.buttons["Connection details"].tap()
    let start = app.buttons["transport-start"]
    XCTAssertTrue(start.waitForExistence(timeout: 4))
    XCTAssertEqual(app.staticTexts["transport-state"].label, "State: idle")
    start.tap()
    XCTAssertEqual(app.staticTexts["transport-state"].label, "State: recording")
    app.buttons["transport-copy"].tap()
    XCTAssertTrue(app.staticTexts["Copied numeric diagnostics."].waitForExistence(timeout: 3))
    app.buttons["Done"].tap()
    selectMusicLibrary(app, id: "fixture-concerts")
    XCTAssertTrue(app.buttons["Open After the last train"].waitForExistence(timeout: 5))
    accounts.tap()
    app.buttons["Connection details"].tap()
    XCTAssertEqual(app.staticTexts["transport-state"].label, "State: idle")
    start.tap()
    app.buttons["transport-clear"].tap()
    XCTAssertEqual(app.staticTexts["transport-state"].label, "State: idle")
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["Open After the last train"].waitForExistence(timeout: 3))
  }
  @MainActor func testAccountMenuReopensConnectionDetailsAcrossTabs() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--transport-ui=" + UUID().uuidString]
    app.launch()
    defer { app.terminate() }
    let tabs = app.tabBars.firstMatch
    for title in ["Home", "Library", "Search"] {
      let tab = tabs.buttons[title]
      XCTAssertTrue(tab.waitForExistence(timeout: 8))
      tab.tap()
      openAccountAction("Connection details", in: app)
      let address = app.staticTexts["connection-server-address"]
      XCTAssertTrue(address.waitForExistence(timeout: 4))
      XCTAssertEqual(address.label, "https://fixture.invalid")
      XCTAssertEqual(app.staticTexts["connection-username"].label, "Demo listener")
      app.buttons["Done"].tap()
      XCTAssertTrue(address.waitForNonExistence(timeout: 4))
      XCTAssertTrue(tab.isSelected)
    }
  }
  @MainActor private func openAccountAction(_ title: String, in app: XCUIApplication) {
    let accounts = app.descendants(matching: .any).matching(identifier: "Accounts").firstMatch
    let action = app.buttons[title]
    XCTAssertTrue(accounts.waitForExistence(timeout: 8))
    for _ in 0..<2 {
      accounts.tap()
      if action.waitForExistence(timeout: 5) {
        action.tap()
        return
      }
    }
    XCTFail("The Accounts menu did not present \(title)")
  }
  @MainActor private func checkForwardField(_ field: XCUIElement, arrow: XCUIElement) {
    let input = field.frame
    let button = arrow.frame
    XCTContext.runActivity(named: "Input and forward arrow \(input) \(button)") { _ in
      XCTAssertGreaterThanOrEqual(button.width, 44)
      XCTAssertLessThanOrEqual(button.width, 64)
      XCTAssertGreaterThanOrEqual(button.height, 48)
      XCTAssertEqual(button.midY, input.midY, accuracy: 2)
      XCTAssertGreaterThanOrEqual(button.minX, input.maxX - 1)
      XCTAssertGreaterThan(input.width, button.width * 2)
    }
  }

  @MainActor private func typeAccountText(
    _ text: String, into field: XCUIElement, in app: XCUIApplication,
    expecting value: String? = nil,
    verticalOffset: CGFloat = 0
  ) async throws {
    try await tapAccountField(field, in: app, verticalOffset: verticalOffset)
    app.typeText(text)
    if let value { XCTAssertEqual(field.value as? String, value) }
  }

  @MainActor private func tapAccountField(
    _ field: XCUIElement, in app: XCUIApplication, verticalOffset: CGFloat
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    var previousFrame = CGRect.null
    while clock.now < deadline {
      let frame = field.frame
      if field.isHittable, !frame.isEmpty, app.frame.contains(frame), frame == previousFrame {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
          .withOffset(CGVector(dx: 0, dy: verticalOffset)).tap()
        return
      }
      previousFrame = frame
      try await Task.sleep(for: .milliseconds(180))
    }
    XCTFail("The text field did not settle inside the app window")
  }
  @MainActor func testQuickConnectSignInCancellationAndDeviceApproval() async throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = [
      "--fixture", "--muted", "--transport-ui=" + UUID().uuidString, "--quick-connect-fixture",
    ]
    app.launch()
    defer { app.terminate() }
    let address = app.textFields["sign-in-server"]
    let next = app.buttons["sign-in-continue"]
    let start = app.buttons["sign-in-show-code"]
    XCTAssertTrue(address.waitForExistence(timeout: 8))
    XCTAssertFalse(next.isEnabled)
    XCTAssertFalse(start.exists)
    XCTAssertFalse(app.secureTextFields.firstMatch.exists)
    checkForwardField(address, arrow: next)
    let url = "https://music.invalid/jellyfin"
    try await typeAccountText(url, into: address, in: app, expecting: url, verticalOffset: -22)
    next.tap()
    XCTAssertTrue(start.waitForExistence(timeout: 8))
    XCTAssertEqual(start.label, "Show a sign-in code")
    XCTAssertGreaterThanOrEqual(start.frame.height, 44)
    XCTAssertTrue(app.buttons["sign-in-password-method"].exists)
    start.tap()
    let code = app.staticTexts["quick-connect-code"]
    XCTAssertTrue(code.waitForExistence(timeout: 5))
    XCTAssertEqual(code.value as? String, "1 2 0 0 0 1")
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: 5))
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "sign-in-method-server").firstMatch
        .label, url)
    start.tap()
    XCTAssertTrue(code.waitForExistence(timeout: 5))
    XCTAssertEqual(code.value as? String, "1 2 0 0 0 2")
    let accounts = app.descendants(matching: .any).matching(identifier: "Accounts").firstMatch
    XCTAssertTrue(accounts.waitForExistence(timeout: 22))
    XCTAssertTrue(accounts.isHittable)
    openAccountAction("Quick Connect", in: app)
    let field = app.textFields["quick-connect-input"]
    let approve = app.buttons["quick-connect-submit"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertEqual(approve.label, "Approve")
    XCTAssertGreaterThanOrEqual(approve.frame.height, 44)
    XCTAssertTrue(
      app.descendants(matching: .any).matching(
        NSPredicate(format: "label CONTAINS %@ OR value == %@", "Demo listener", "Demo listener")
      ).firstMatch.exists)
    XCTAssertFalse(approve.isEnabled)
    try await typeAccountText("999999", into: field, in: app, expecting: "999999")
    XCTAssertTrue(approve.isEnabled)
    approve.tap()
    let error = app.descendants(matching: .any).matching(identifier: "quick-connect-approval-error")
      .firstMatch
    XCTAssertTrue(error.waitForExistence(timeout: 5))
    XCTAssertTrue(error.label.contains("invalid or has expired"))
    let clear = String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6)
    try await typeAccountText(clear + "246810", into: field, in: app, expecting: "246810")
    XCTAssertTrue(approve.isEnabled)
    let success = app.descendants(matching: .any).matching(identifier: "quick-connect-approved")
      .firstMatch
    XCTAssertFalse(success.exists)
    approve.tap()
    XCTAssertTrue(success.waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    XCTAssertTrue(accounts.waitForExistence(timeout: 5))
  }
  @MainActor private func openPasswordFixture(in app: XCUIApplication) async throws -> String {
    app.launchArguments = [
      "--fixture", "--muted", "--transport-ui=" + UUID().uuidString,
      "--quick-connect-fixture", "--codes-disabled",
    ]
    app.launch()
    let address = app.textFields["sign-in-server"]
    XCTAssertTrue(address.waitForExistence(timeout: 8))
    XCTAssertFalse(app.textFields["Username"].exists)
    let url = "https://music.invalid/jellyfin"
    try await typeAccountText(url, into: address, in: app, expecting: url, verticalOffset: 22)
    app.buttons["sign-in-continue"].tap()
    XCTAssertTrue(app.staticTexts["sign-in-codes-disabled"].waitForExistence(timeout: 6))
    XCTAssertFalse(app.buttons["sign-in-show-code"].exists)
    return url
  }

  @MainActor func testFirstDeviceSignsInWithPasswordWhenCodesAreDisabled() async throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    defer { app.terminate() }
    let url = try await openPasswordFixture(in: app)
    let username = app.textFields["sign-in-username"]
    let password = app.secureTextFields["sign-in-password"]
    let submit = app.buttons["sign-in-password-submit"]
    checkForwardField(password, arrow: submit)
    let fieldFrame = password.frame
    let arrowFrame = submit.frame
    XCTAssertEqual(fieldFrame.height, arrowFrame.height, accuracy: 1)
    let screen = app.frame
    let image = try XCTUnwrap(app.screenshot().image.cgImage)
    for y in [arrowFrame.minY + 2, arrowFrame.maxY - 2] {
      let color = try screenColor(
        image, screen: screen, xOffset: arrowFrame.midX - screen.minX, y: y)
      XCTAssertGreaterThan(color[2] - color[0], 12, "The circle must reach both field edges")
    }
    try await typeAccountText(
      "Listener", into: username, in: app, expecting: "Listener", verticalOffset: 22)
    dismissCredentialSuggestions(in: app)
    password.tap()
    try recordPasswordFocus(password, in: app)
    password.typeText("fixture")
    XCTAssertTrue((username.value as? String) == "Listener", "Password input changed Username")
    submit.tap()
    assertPasswordFixtureAccount(in: app, server: url)
  }

  @MainActor private func recordPasswordFocus(
    _ password: XCUIElement, in app: XCUIApplication
  ) throws {
    let screen = app.frame
    let frame = password.frame
    let image = try XCTUnwrap(app.screenshot().image.cgImage)
    let border = try screenColor(
      image, screen: screen, xOffset: frame.midX - screen.minX, y: frame.minY + 1)
    XCTContext.runActivity(named: "Password focus border \(border)") { _ in }
  }

  @MainActor private func dismissCredentialSuggestions(in app: XCUIApplication) {
    let bar = app.navigationBars.firstMatch
    XCTAssertTrue(bar.waitForExistence(timeout: 5))
    bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
  }

  @MainActor private func passwordEdgeColors(
    _ password: XCUIElement, in app: XCUIApplication
  ) throws -> [Int] {
    let screen = app.frame
    let frame = password.frame
    let image = try XCTUnwrap(app.screenshot().image.cgImage)
    let fractions: [CGFloat] = [0.25, 0.5, 0.75]
    return try fractions.flatMap { fraction in
      try screenColor(
        image, screen: screen, xOffset: frame.minX - screen.minX + frame.width * fraction,
        y: frame.minY + 4)
    }
  }

  @MainActor func testPasswordCenterEdgeWithKeyboardAlreadyOpen() async throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    defer { app.terminate() }
    let url = try await openPasswordFixture(in: app)
    let username = app.textFields["sign-in-username"]
    let password = app.secureTextFields["sign-in-password"]
    try await tapAccountField(username, in: app, verticalOffset: 0)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    let baseline = try passwordEdgeColors(password, in: app)
    username.typeText("Listener")
    XCTAssertEqual(username.value as? String, "Listener")
    dismissCredentialSuggestions(in: app)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(4))
    var clearSamples = 0
    while clearSamples < 2, clock.now < deadline {
      let current = try passwordEdgeColors(password, in: app)
      clearSamples =
        zip(baseline, current).allSatisfy { abs($0.0 - $0.1) <= 3 } ? clearSamples + 1 : 0
      if clearSamples < 2 { try await Task.sleep(for: .milliseconds(150)) }
    }
    XCTAssertEqual(
      clearSamples, 2, "The upper edge stayed covered after dismissing the username suggestion")
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    try await tapAccountField(password, in: app, verticalOffset: 4 - password.frame.height / 2)
    try recordPasswordFocus(password, in: app)
    password.typeText("fixture")
    dismissCredentialSuggestions(in: app)
    app.buttons["sign-in-password-submit"].tap()
    assertPasswordFixtureAccount(in: app, server: url)
  }

  @MainActor func testPasswordArrowSubmitsAfterDismissingSuggestions() async throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    defer { app.terminate() }
    let url = try await openPasswordFixture(in: app)
    let username = app.textFields["sign-in-username"]
    try await typeAccountText("Listener", into: username, in: app, expecting: "Listener")
    username.typeText("\n")
    app.secureTextFields["sign-in-password"].typeText("fixture")
    dismissCredentialSuggestions(in: app)
    app.buttons["sign-in-password-submit"].tap()
    assertPasswordFixtureAccount(in: app, server: url)
  }

  @MainActor private func assertPasswordFixtureAccount(
    in app: XCUIApplication, server: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let accounts = app.descendants(matching: .any).matching(identifier: "Accounts").firstMatch
    XCTAssertTrue(accounts.waitForExistence(timeout: 10), file: file, line: line)
    openAccountAction("Connection details", in: app)
    XCTAssertEqual(
      app.staticTexts["connection-username"].label, "Demo listener", file: file, line: line)
    XCTAssertEqual(
      app.staticTexts["connection-server-address"].label, server, file: file, line: line)
  }

  @MainActor func testPasswordSignInWithKeyboardNextAndGo() async throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    defer { app.terminate() }
    let url = try await openPasswordFixture(in: app)
    let username = app.textFields["sign-in-username"]
    try await typeAccountText("Listener", into: username, in: app, expecting: "Listener")
    username.typeText("\n")
    app.secureTextFields["sign-in-password"].typeText("fixture\n")
    assertPasswordFixtureAccount(in: app, server: url)
  }

  @MainActor func testQuickConnectSignsInAndOutOfAnIsolatedLiveAccount() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let input = environment["JUKEBOX_ACCOUNT_TEST_SERVER"] else {
      throw XCTSkip("Requires a designated HTTPS test server and disposable account")
    }
    continueAfterFailure = false
    let server = try XCTUnwrap(URLComponents(string: input))
    XCTAssertEqual(server.scheme, "https")
    XCTAssertNotNil(server.host)
    XCTAssertNil(server.user)
    XCTAssertNil(server.password)
    XCTAssertNil(server.query)
    XCTAssertNil(server.fragment)
    let expected = try XCTUnwrap(environment["JUKEBOX_ACCOUNT_TEST_USER"])
    let run = try XCTUnwrap(environment["JUKEBOX_ACCOUNT_TEST_RUN"].flatMap(UUID.init(uuidString:)))
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--transport-account-sign-in=" + run.uuidString, "--muted"]
    app.launch()
    defer { app.terminate() }
    let address = app.textFields["sign-in-server"]
    XCTAssertTrue(address.waitForExistence(timeout: 8))
    try await typeAccountText(input, into: address, in: app, expecting: input)
    app.buttons["sign-in-continue"].tap()
    let show = app.buttons["sign-in-show-code"]
    XCTAssertTrue(show.waitForExistence(timeout: 15))
    show.tap()
    let display = app.staticTexts["quick-connect-code"]
    XCTAssertTrue(display.waitForExistence(timeout: 15))
    let digits = try XCTUnwrap(display.value as? String).filter { !$0.isWhitespace }
    XCTAssertEqual(digits.count, 6)
    XCTAssertTrue(digits.utf8.allSatisfy { (48...57).contains($0) })
    XCTContext.runActivity(named: "Approve Jukebox account check \(run.uuidString) \(digits)") {
      _ in
    }
    let accounts = app.descendants(matching: .any).matching(identifier: "Accounts").firstMatch
    XCTAssertTrue(accounts.waitForExistence(timeout: 70))
    openAccountAction("Connection details", in: app)
    let name = app.staticTexts["connection-username"]
    XCTAssertTrue(name.waitForExistence(timeout: 6))
    XCTAssertEqual(name.label, expected)
    XCTAssertEqual(app.staticTexts["connection-server-address"].label, input)
    app.buttons["Done"].tap()
    openAccountAction("Sign out", in: app)
    XCTAssertTrue(address.waitForExistence(timeout: 15))
    XCTAssertFalse(accounts.exists)
    XCTAssertFalse(app.buttons[expected].exists)
  }

  @MainActor func testSavedAccountLaunchToResponsive() throws {
    continueAfterFailure = false
    let options = XCTMeasureOptions()
    options.iterationCount = 8
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    defer { app.terminate() }
    measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
      let launched = launchSavedConnections()
      let accounts = launched.descendants(matching: .any).matching(identifier: "Accounts")
        .firstMatch
      XCTAssertTrue(accounts.waitForExistence(timeout: 10))
      XCTAssertFalse(launched.textFields["sign-in-server"].exists)
    }
  }

  @MainActor func testReturningAccountShowsOpeningThenRetriesOfflineWithoutSignIn() throws {
    continueAfterFailure = false
    let app = launchSavedConnections(extraArguments: ["--offline-first-reconnect"])
    defer { app.terminate() }
    let opening = app.descendants(matching: .any).matching(identifier: "account-opening").firstMatch
    XCTAssertTrue(opening.waitForExistence(timeout: 4))
    XCTAssertFalse(app.textFields["sign-in-server"].exists)
    let retry = app.buttons["Try again"]
    XCTAssertTrue(retry.waitForExistence(timeout: 12))
    XCTAssertTrue(app.staticTexts["Couldn’t reconnect"].exists)
    XCTAssertFalse(app.textFields["sign-in-server"].exists)
    retry.tap()
    let account = app.descendants(matching: .any).matching(identifier: "Accounts").firstMatch
    XCTAssertTrue(account.waitForExistence(timeout: 10))
    XCTAssertFalse(retry.exists)
    XCTAssertFalse(app.textFields["sign-in-server"].exists)
  }

  @MainActor private func launchSavedConnections(extraArguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments =
      [
        "--fixture", "--muted", "--transport-ui=" + UUID().uuidString,
        "--quick-connect-fixture", "--example-saved-connections",
      ] + extraArguments
    app.launch()
    return app
  }

  @MainActor func testInspectCancelAndRemoveOneOfThreeSameNameConnections() throws {
    continueAfterFailure = false
    let app = launchSavedConnections()
    defer { app.terminate() }
    let menu = app.descendants(matching: .any).matching(identifier: "Accounts").firstMatch
    let rows = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ OR label BEGINSWITH %@", "saved-connection-",
        "Demo listener"))
    XCTAssertTrue(menu.waitForExistence(timeout: 12))
    menu.tap()
    XCTAssertTrue(rows.element(boundBy: 2).waitForExistence(timeout: 5))
    for (index, origin) in [
      "https://music.invalid/jellyfin", "http://music.invalid/jellyfin",
      "https://offline.invalid/jellyfin",
    ].enumerated() {
      try assertMenuAddress(origin, on: rows.element(boundBy: index))
    }
    rows.element(boundBy: 1).tap()
    let address = app.staticTexts["connection-server-address"]
    XCTAssertTrue(address.waitForExistence(timeout: 5))
    XCTAssertEqual(address.label, "http://music.invalid/jellyfin")
    XCTAssertFalse(app.buttons["Switch to this account"].exists)
    let remove = app.buttons["remove-saved-connection"]
    remove.tap()
    let confirmation = app.alerts["Remove this saved connection?"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    XCTAssertTrue(
      confirmation.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "http://music.invalid/jellyfin")
      ).firstMatch.exists)
    confirmation.buttons["Cancel"].tap()
    XCTAssertTrue(remove.waitForExistence(timeout: 4))
    remove.tap()
    confirmation.buttons["Remove"].tap()
    XCTAssertTrue(address.waitForNonExistence(timeout: 5))
    menu.tap()
    XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 4))
    XCTAssertEqual(rows.count, 2)
    rows.element(boundBy: 1).tap()
    XCTAssertTrue(address.waitForExistence(timeout: 4))
    XCTAssertEqual(address.label, "https://offline.invalid/jellyfin")
    app.buttons["Switch to this account"].tap()
    XCTAssertTrue(app.staticTexts["connection-action-error"].waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    openAccountAction("Connection details", in: app)
    XCTAssertTrue(address.waitForExistence(timeout: 4))
    XCTAssertEqual(address.label, "https://music.invalid/jellyfin")
    XCTAssertTrue(app.staticTexts["Current account"].exists)
    XCTAssertFalse(remove.exists)
    for fact in ["Sample music server", "12.1.0"] {
      XCTAssertTrue(
        app.descendants(matching: .any).matching(
          NSPredicate(format: "label CONTAINS %@ OR value == %@", fact, fact)
        ).firstMatch.waitForExistence(timeout: 4))
    }
  }

  @MainActor private func assertMenuAddress(_ address: String, on row: XCUIElement) throws {
    let combined = [row.label, row.value as? String ?? ""].joined(separator: " ")
    if combined.contains(address) { return }
    let text = row.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@ OR value == %@", address, address))
    if text.firstMatch.exists { return }
    let screenshot = row.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "Sample saved connection row"
    add(attachment)
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = .accurate
    recognition.usesLanguageCorrection = false
    let image = try XCTUnwrap(screenshot.image.cgImage)
    try VNImageRequestHandler(cgImage: image).perform([recognition])
    let visible = recognition.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    XCTAssertTrue(visible.joined().replacingOccurrences(of: " ", with: "").contains(address))
  }

  @MainActor func testAccountMenuQuickConnectAndSignOutAppearance() throws {
    continueAfterFailure = false
    let app = launchSavedConnections()
    defer { app.terminate() }
    let account = app.descendants(matching: .any).matching(identifier: "Accounts").firstMatch
    XCTAssertTrue(account.waitForExistence(timeout: 12))
    account.tap()
    let approve = app.buttons["Quick Connect"]
    let signOut = app.buttons["Sign out"]
    XCTAssertTrue(approve.waitForExistence(timeout: 5))
    XCTAssertTrue(signOut.isHittable)
    let signOutInk = try menuIconPosition(in: signOut, destructive: true)
    let regularInk = try menuIconPosition(in: approve, destructive: false)
    XCTAssertEqual(signOutInk, regularInk, accuracy: 3, "Menu symbols should share a center column")
    approve.tap()
    XCTAssertTrue(app.textFields["quick-connect-input"].waitForExistence(timeout: 6))
    app.buttons["Done"].tap()
    XCTAssertTrue(account.waitForExistence(timeout: 4))
    openAccountAction("Sign out", in: app)
    XCTAssertTrue(app.textFields["sign-in-server"].waitForExistence(timeout: 8))
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "label == %@", "Demo listener")).count, 2)
  }

  @MainActor private func menuIconPosition(in row: XCUIElement, destructive: Bool) throws -> CGFloat
  {
    let image = try XCTUnwrap(row.screenshot().image.cgImage)
    let width = Int(row.frame.width.rounded())
    let height = Int(row.frame.height.rounded())
    XCTAssertTrue((60...700).contains(width) && (20...200).contains(height))
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    try rgba.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(
        CGContext(
          data: bytes.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    var iconColumns = IndexSet()
    var titlePixels = 0
    for y in 2..<(height - 2) {
      for x in 2..<(width - 2) {
        let i = (y * width + x) * 4
        let red = Int(rgba[i])
        let green = Int(rgba[i + 1])
        let blue = Int(rgba[i + 2])
        let matches =
          destructive
          ? red > 145 && red - green > 55 && red - blue > 40
          : blue > 150 && blue - red > 25 && green > red
        guard matches else { continue }
        if x < 45 { iconColumns.insert(x) } else if x > 48 { titlePixels += 1 }
      }
    }
    if destructive { XCTAssertGreaterThan(titlePixels, 8, "The Sign out text should be red") }
    let first = try XCTUnwrap(iconColumns.first, "Missing colored menu symbol")
    let last = try XCTUnwrap(iconColumns.last)
    XCTAssertGreaterThan(last - first, 6)
    return row.frame.minX + CGFloat(first + last) / 2
  }

  @MainActor func testSavedAccountDetailsOpenOffline() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = [
      "--fixture", "--muted", "--transport-ui=" + UUID().uuidString, "--saved-account-fixture",
    ]
    app.launch()
    defer { app.terminate() }
    let details = app.buttons["Connection details for Offline listener"]
    XCTAssertTrue(details.waitForExistence(timeout: 8))
    details.tap()
    let address = app.staticTexts["connection-server-address"]
    XCTAssertTrue(address.waitForExistence(timeout: 4))
    XCTAssertEqual(address.label, "http://offline.invalid/music")
    XCTAssertEqual(app.staticTexts["connection-username"].label, "Offline listener")
    XCTAssertTrue(
      app.staticTexts["This saved address uses HTTP. Use your server’s HTTPS address to sign in."]
        .exists)
    XCTAssertTrue(app.buttons["Copy server address"].isHittable)
    XCTAssertFalse(app.buttons["transport-start"].exists)
    app.buttons["Done"].tap()
    XCTAssertTrue(details.waitForExistence(timeout: 4))
    app.buttons["Offline listener"].tap()
    let field = app.textFields["sign-in-server"]
    XCTAssertTrue(app.staticTexts["sign-in-insecure-address"].waitForExistence(timeout: 5))
    let prefilled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "http://offline.invalid/music"), object: field)
    XCTAssertEqual(XCTWaiter.wait(for: [prefilled], timeout: 5), .completed)
    XCTAssertFalse(address.exists)
    XCTAssertFalse(app.textFields["Username"].exists)
    XCTAssertFalse(app.buttons["sign-in-continue"].isEnabled)
  }
  @MainActor func testActiveConnectionDetailsAtLargeText() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--large-text"]
    app.launch()
    let accounts = app.buttons["Accounts"]
    XCTAssertTrue(accounts.waitForExistence(timeout: 8))
    accounts.tap()
    app.buttons["Connection details"].tap()
    let address = app.staticTexts["connection-server-address"]
    XCTAssertTrue(address.waitForExistence(timeout: 3))
    XCTAssertEqual(address.label, "https://fixture.invalid")
    XCTAssertEqual(app.staticTexts["connection-username"].label, "Demo listener")
    XCTAssertLessThanOrEqual(address.frame.maxX, app.frame.maxX)
    XCTAssertTrue(app.buttons["Copy server address"].isHittable)
    capture("connection-large-text", app: app)
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["Open The quiet hours"].waitForExistence(timeout: 3))
  }
  @MainActor func testDarkLargeTextAlbum() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--appearance-dark", "--large-text"]
    app.launch()
    let open = app.buttons["Open The quiet hours"]
    XCTAssertTrue(open.waitForExistence(timeout: 8))
    open.tap()
    XCTAssertTrue(app.buttons["Play First light"].waitForExistence(timeout: 5))
    capture("album-dark-large-text", app: app)
    let frame = app.buttons["Play album"].frame
    XCTAssertGreaterThanOrEqual(frame.height, 44)
    XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX)
  }
  @MainActor func testLargeTextPlayerAndMiniPlayer() throws {
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--large-text", "--appearance-dark"]
    app.launch()
    let open = app.buttons["Open The quiet hours"]
    XCTAssertTrue(open.waitForExistence(timeout: 8))
    open.tap()
    XCTAssertTrue(app.buttons["Play First light"].waitForExistence(timeout: 5))
    app.buttons["Play album"].tap()
    let mini = app.buttons["mini-toggle"]
    XCTAssertTrue(mini.waitForExistence(timeout: 8))
    XCTAssertEqual(app.buttons["Open now playing"].value as? String, "First light, North Window")
    XCTAssertGreaterThanOrEqual(mini.frame.height, 44)
    XCTAssertLessThanOrEqual(mini.frame.maxX, app.frame.maxX)
    let miniBounds = app.otherElements["mini-player"].frame
    for identifier in ["mini-title", "mini-artist"] {
      let frame = app.staticTexts[identifier].frame
      XCTAssertGreaterThan(frame.height, 0)
      XCTAssertGreaterThanOrEqual(frame.minY, miniBounds.minY)
      XCTAssertLessThanOrEqual(frame.maxY, miniBounds.maxY)
    }
    capture("mini-dark-large-text", app: app)
    app.buttons["Open now playing"].tap()
    XCTAssertGreaterThan(app.staticTexts["player-title"].frame.height, 40)
    capture("player-dark-large-text-top", app: app)
    let toggle = app.buttons["player-toggle"]
    for _ in 0..<3 {
      if toggle.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(toggle.isHittable)
    XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
    toggle.tap()
    XCTAssertEqual(toggle.label, "Play")
    let queue = app.buttons["player-queue"]
    let quality = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Streaming quality:")
    ).firstMatch
    let playerScroll = app.scrollViews.containing(.button, identifier: "player-toggle").firstMatch
    XCTAssertTrue(playerScroll.waitForExistence(timeout: 3))
    for _ in 0..<5 {
      if queue.isHittable && playerScroll.frame.contains(queue.frame)
        && playerScroll.frame.contains(quality.frame)
      {
        break
      }
      playerScroll.swipeUp()
    }
    XCTAssertTrue(queue.isHittable)
    XCTAssertTrue(quality.isHittable)
    XCTAssertTrue(playerScroll.frame.contains(queue.frame))
    XCTAssertTrue(playerScroll.frame.contains(quality.frame))
    capture("player-dark-large-text-controls", app: app)
  }

}

extension JukeboxUITests {
  @MainActor func testFocusPlayerConditionalLyricsArtistShelfAndQueue() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--transport-ui=" + UUID().uuidString]
    addTeardownBlock { MainActor.assumeIsolated { app.terminate() } }
    app.launch()
    let album = app.buttons["Open The quiet hours"]
    XCTAssertTrue(album.waitForExistence(timeout: 8))
    album.tap()
    XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
    app.buttons["Play album"].tap()
    let mini = app.buttons["mini-toggle"]
    XCTAssertTrue(mini.waitForExistence(timeout: 5))
    if mini.label == "Pause" { mini.tap() }
    app.tabBars.buttons["Library"].tap()
    selectMusicLibrary(app, id: "fixture-concerts")
    XCTAssertEqual(app.buttons["music-library-picker"].value as? String, "Live recordings")
    app.buttons["Open now playing"].tap()
    let scroll = app.scrollViews["player-scroll"]
    let lyrics = app.buttons["player-lyrics"]
    XCTAssertTrue(lyrics.waitForExistence(timeout: 3))
    let utilities = app.otherElements["player-utilities"]
    let firstShelfAlbum = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "player-album-open-")
    ).firstMatch
    XCTAssertTrue(firstShelfAlbum.waitForExistence(timeout: 3))
    let shelfHeading = app.staticTexts["player-artist-shelf-heading"]
    XCTAssertTrue(shelfHeading.exists)
    XCTAssertFalse(shelfHeading.isHittable)
    XCTAssertGreaterThanOrEqual(shelfHeading.frame.minY + 2, scroll.frame.maxY)
    XCTAssertTrue(app.buttons["player-queue"].isHittable)
    XCTAssertFalse(
      firstShelfAlbum.isHittable, "More from the artist starts below the first viewport")
    XCTAssertLessThanOrEqual(utilities.frame.maxY, scroll.frame.maxY + 2)
    XCTAssertEqual(scroll.frame.minX, app.frame.minX, accuracy: 2)
    XCTAssertEqual(scroll.frame.width, app.frame.width, accuracy: 2)
    let openingHeight = scroll.frame.height
    for _ in 0..<3 {
      if app.buttons["player-queue"].isHittable { break }
      scroll.swipeUp()
    }
    let route = app.otherElements["player-route"].firstMatch
    let quality = app.buttons["player-quality"]
    let queue = app.buttons["player-queue"]
    XCTAssertTrue(route.exists)
    let centers = [route.frame.midX, quality.frame.midX, lyrics.frame.midX, queue.frame.midX]
    XCTAssertEqual(centers[1] - centers[0], centers[2] - centers[1], accuracy: 3)
    XCTAssertEqual(centers[2] - centers[1], centers[3] - centers[2], accuracy: 3)
    for control in [
      quality, lyrics, queue, app.buttons["player-shuffle"], app.buttons["player-repeat"],
    ] {
      XCTAssertTrue(control.isHittable)
      XCTAssertGreaterThanOrEqual(control.frame.height + 1e-9, 44)
    }
    app.buttons["player-shuffle"].tap()
    XCTAssertEqual(app.buttons["player-shuffle"].value as? String, "On")
    app.buttons["player-shuffle"].tap()
    XCTAssertEqual(app.buttons["player-shuffle"].value as? String, "Off")
    app.buttons["player-repeat"].tap()
    XCTAssertEqual(app.buttons["player-repeat"].value as? String, "all")
    app.buttons["player-repeat"].tap()
    XCTAssertEqual(app.buttons["player-repeat"].value as? String, "one")
    app.buttons["player-repeat"].tap()
    XCTAssertEqual(app.buttons["player-repeat"].value as? String, "off")
    XCTAssertEqual(app.buttons["player-toggle"].label, "Play", "Mode edits retain Pause")
    lyrics.tap()
    let line = app.buttons["Seek to Paper windows catch the light"]
    XCTAssertTrue(line.waitForExistence(timeout: 3))
    line.tap()
    app.buttons["close-player-lyrics"].tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "0:06"),
            object: app.staticTexts["player-elapsed"]
          )
        ], timeout: 3), .completed)
    quality.tap()
    XCTAssertTrue(app.buttons["Original"].waitForExistence(timeout: 3))
    app.buttons["Original"].tap()
    app.buttons["player-more"].tap()
    app.buttons["Track information"].tap()
    XCTAssertTrue(app.staticTexts["Original file"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["FLAC"].waitForExistence(timeout: 3))
    app.buttons["close-player-information"].tap()
    queue.tap()
    XCTAssertTrue(
      app.otherElements["queue-list"].waitForExistence(timeout: 3)
        || app.collectionViews["queue-list"].exists || app.tables["queue-list"].exists)
    app.navigationBars["Queue"].buttons.element(boundBy: 0).tap()
    let openAlbum = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "player-album-open-")
    ).firstMatch
    for _ in 0..<4 {
      if openAlbum.isHittable { break }
      scroll.swipeUp()
    }
    XCTAssertTrue(openAlbum.isHittable)
    XCTAssertGreaterThanOrEqual(scroll.frame.height + 2, openingHeight)
    XCTAssertLessThanOrEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player-album-open-"))
        .count, 8)
    XCTAssertFalse(app.buttons["player-album-open-fixture-album"].exists)
    let title = String(openAlbum.label.dropFirst("Open ".count))
    openAlbum.tap()
    XCTAssertTrue(app.staticTexts["album-heading"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["album-heading"].label, title)
    XCTAssertEqual(
      app.buttons["music-library-picker"].value as? String, "Music", "Open uses the queue root")
    XCTAssertEqual(mini.label, "Play")
    app.buttons["Open now playing"].tap()
    let playAlbum = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "player-album-play-")
    ).firstMatch
    XCTAssertTrue(app.buttons["player-queue"].waitForExistence(timeout: 3))
    XCTAssertFalse(
      playAlbum.isHittable, "A fresh sheet opening returns to the primary first viewport")
    XCTAssertEqual(scroll.frame.height, openingHeight, accuracy: 2)
    for _ in 0..<4 {
      if playAlbum.isHittable { break }
      scroll.swipeUp()
    }
    XCTAssertTrue(playAlbum.isHittable)
    let playedTitle = String(playAlbum.label.dropFirst("Play ".count))
    playAlbum.tap()
    let toggle = app.buttons["player-toggle"]
    for _ in 0..<4 {
      if toggle.isHittable { break }
      scroll.swipeDown()
    }
    XCTAssertTrue(toggle.isHittable)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", playedTitle),
            object: app.staticTexts["player-album-context"]
          )
        ], timeout: 5), .completed)
    if toggle.label == "Pause" { toggle.tap() }
    let expandedHeight = scroll.frame.height
    app.buttons["player-next"].tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: lyrics
          )
        ], timeout: 3), .completed)
    if toggle.label == "Pause" { toggle.tap() }
    let three = [route.frame.midX, quality.frame.midX, queue.frame.midX]
    XCTAssertEqual(three[1] - three[0], three[2] - three[1], accuracy: 3)
    XCTAssertTrue(quality.isHittable)
    XCTAssertTrue(queue.isHittable)
    XCTAssertEqual(
      scroll.frame.height, expandedHeight, accuracy: 2, "Track/Lyrics changes retain expansion")
    XCTAssertFalse(app.buttons["Done"].exists)
    app.buttons["close-player"].tap()
    XCTAssertTrue(mini.exists)
  }
}

extension JukeboxUITests {
  @MainActor func testPlayerSheetWidthAndInterruptedDrag() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = ["--fixture", "--muted", "--transport-ui=" + UUID().uuidString]
    addTeardownBlock { MainActor.assumeIsolated { app.terminate() } }
    app.launch()
    let album = app.buttons["Open The quiet hours"]
    XCTAssertTrue(album.waitForExistence(timeout: 8))
    album.tap()
    let play = app.buttons["Play album"]
    XCTAssertTrue(play.waitForExistence(timeout: 5))
    play.tap()
    let mini = app.buttons["mini-toggle"]
    XCTAssertTrue(mini.waitForExistence(timeout: 5))
    if mini.label == "Pause" { mini.tap() }
    app.buttons["Open now playing"].tap()
    let scroll = app.scrollViews["player-scroll"]
    let queue = app.buttons["player-queue"]
    XCTAssertTrue(queue.waitForExistence(timeout: 3))
    XCTAssertTrue(queue.isHittable)
    let before = scroll.frame
    XCTAssertGreaterThan(before.height, 0)
    print("PLAYER_SHEET_BEFORE app=\(app.frame) scroll=\(before)")
    XCTAssertEqual(before.minX, app.frame.minX, accuracy: 2)
    XCTAssertEqual(before.width, app.frame.width, accuracy: 2)
    let bar = app.navigationBars["Now playing"]
    XCTAssertTrue(bar.exists)
    let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
    let end = start.withOffset(CGVector(dx: 0, dy: min(24, bar.frame.height / 2)))
    start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    let settled = NSPredicate { _, _ in
      scroll.exists && queue.isHittable && abs(scroll.frame.minY - before.minY) <= 2
        && abs(scroll.frame.height - before.height) <= 2
    }
    XCTAssertEqual(
      XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 3),
      .completed, "An interrupted downward drag returns to the same resting sheet")
    print("PLAYER_SHEET_AFTER app=\(app.frame) scroll=\(scroll.frame)")
    let shelf = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "player-album-open-")
    ).firstMatch
    XCTAssertTrue(shelf.waitForExistence(timeout: 3))
    let shelfHeading = app.staticTexts["player-artist-shelf-heading"]
    XCTAssertTrue(shelfHeading.exists)
    XCTAssertFalse(shelfHeading.isHittable)
    XCTAssertGreaterThanOrEqual(shelfHeading.frame.minY + 2, scroll.frame.maxY)
    XCTAssertFalse(shelf.isHittable)
    XCTAssertGreaterThanOrEqual(shelf.frame.minY + 2, scroll.frame.maxY)
    for _ in 0..<4 {
      if shelf.isHittable { break }
      scroll.swipeUp()
    }
    XCTAssertTrue(shelf.isHittable, "Upward scrolling reveals More from the artist")
    XCTAssertTrue(shelfHeading.isHittable)
    print("PLAYER_SHEET_SCROLLED scroll=\(scroll.frame)")
    XCTAssertEqual(scroll.frame.height, before.height, accuracy: 2)
    app.buttons["close-player"].tap()
    XCTAssertTrue(mini.exists)
  }
}

extension JukeboxUITests {
  @MainActor func testPlaylistDetailGlassAndLongList() throws {
    let app = launchMutedPlaylistFixture(longAlbum: true)
    app.tabBars.buttons["Library"].tap()
    app.buttons["music-category-Playlists"].tap()
    let card = app.buttons["playlist-fixture-playlist-long"]
    XCTAssertTrue(card.waitForExistence(timeout: 7))
    card.tap()
    let list = app.descendants(matching: .any)["playlist-detail-songs"].firstMatch
    let row = app.buttons["playlist-track-1"]
    XCTAssertTrue(row.waitForExistence(timeout: 6))
    XCTAssertTrue(
      (row.value as? String)?.hasPrefix("Track 1 of 7790") == true
        || (row.value as? String)?.hasPrefix("Track 1 of 7,790") == true)
    let screen = app.frame
    let viewport = list.frame
    XCTAssertEqual(viewport.minY, screen.minY, accuracy: 1)
    XCTAssertEqual(viewport.maxY, screen.maxY, accuracy: 1)
    let y = app.navigationBars.firstMatch.frame.maxY + 28
    var rgb: [Int] = []
    for _ in 0..<6 {
      rgb = try screenColor(XCTUnwrap(app.screenshot().image.cgImage), screen: screen, y: y)
      if rgb.max()! - rgb.min()! >= 15 { break }
    }
    XCTAssertGreaterThanOrEqual(rgb.max()! - rgb.min()!, 10)
    capture("playlist-gradient", app: app)
    row.tap()
    let toggle = app.buttons["mini-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if toggle.label == "Pause" { toggle.tap() }
    let mini = app.buttons["Open now playing"]
    XCTAssertTrue(mini.exists)
    var top = false
    var bottom = false
    for _ in 0..<12 {
      let upper = app.navigationBars.firstMatch.frame.maxY
      let lower = mini.frame.minY
      let visible = try browseRows(list).filter { $0.id.hasPrefix("playlist-track-") }
      top = top || visible.contains { $0.frame.minY < upper - 1 && $0.frame.maxY > upper + 1 }
      bottom = bottom || visible.contains { $0.frame.minY < lower - 1 && $0.frame.maxY > lower + 1 }
      if top && bottom { break }
      dragBrowsePage(app, points: -113)
    }
    XCTAssertTrue(top)
    XCTAssertTrue(bottom)
    XCTAssertEqual(toggle.label, "Play")
    XCTContext.runActivity(
      named: "Playlist glass rgb=\(rgb) viewport=\(viewport.minY),\(viewport.maxY)"
    ) { _ in }
  }

  @MainActor func testReadOnlyPlaylistOpensEditableCopyWithOriginalOrderAndRepeats() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.jukebox.ios")
    app.launchArguments = [
      "--fixture", "--muted", "--transport-ui=" + UUID().uuidString,
      "--read-only-mix",
    ]
    app.launch()
    defer { app.terminate() }
    let library = app.tabBars.buttons["Library"]
    XCTAssertTrue(library.waitForExistence(timeout: 8))
    library.tap()
    app.buttons["music-category-Playlists"].tap()
    let list = app.buttons["playlist-fixture-playlist-morning"]
    XCTAssertTrue(list.waitForExistence(timeout: 6))
    list.tap()
    let heading = app.staticTexts["playlist-heading"]
    let actions = app.buttons["playlist-actions"]
    let rows = (1...3).map { app.buttons["playlist-track-" + String($0)] }
    XCTAssertTrue(rows[2].waitForExistence(timeout: 6))
    let original = rows.map(\.label)
    XCTAssertEqual(original[0], original[2])
    XCTAssertNotEqual(original[0], original[1])
    actions.tap()
    app.buttons["Make an editable copy"].tap()
    let name = app.textFields["playlist-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    XCTAssertEqual(name.value as? String, "Morning rotation (Editable copy)")
    app.buttons["Cancel"].tap()
    XCTAssertTrue(actions.waitForExistence(timeout: 5))
    actions.tap()
    app.buttons["Edit playlist"].tap()
    let copy = app.buttons["playlist-readonly-copy"]
    XCTAssertTrue(copy.waitForExistence(timeout: 5))
    copy.tap()
    app.buttons["playlist-create-save"].tap()
    XCTAssertTrue(
      heading.wait(for: \.label, toEqual: "Morning rotation (Editable copy)", timeout: 10))
    XCTAssertTrue(rows[2].waitForExistence(timeout: 5))
    XCTAssertEqual(rows.map(\.label), original)
    actions.tap()
    app.buttons["Edit playlist"].tap()
    let sharing = app.buttons["playlist-sharing"]
    XCTAssertTrue(sharing.waitForExistence(timeout: 5))
    sharing.tap()
    let visibility = app.switches["playlist-public"].firstMatch
    XCTAssertTrue(visibility.waitForExistence(timeout: 5))
    XCTAssertEqual(visibility.value as? String, "0")
    app.navigationBars["Sharing"].buttons["BackButton"].tap()
    app.buttons["playlist-edit-order"].tap()
    app.buttons["playlist-entry-3"].tap()
    app.buttons["Move up"].firstMatch.tap()
    app.navigationBars["Song order"].buttons["BackButton"].tap()
    app.buttons["playlist-editor-done"].tap()
    XCTAssertTrue(rows[2].waitForExistence(timeout: 5))
    XCTAssertTrue(rows[1].wait(for: \.label, toEqual: original[2], timeout: 5))
    XCTAssertEqual(rows.map(\.label), [original[0], original[2], original[1]])
    app.navigationBars["Morning rotation (Editable copy)"].buttons["BackButton"].tap()
    XCTAssertTrue(heading.wait(for: \.label, toEqual: "Morning rotation", timeout: 5))
    XCTAssertEqual(rows.map(\.label), original)
  }

  @MainActor func testPlaylistCreateAddRenameAndDelete() throws {
    let app = launchMutedPlaylistFixture()
    app.tabBars.buttons["Library"].tap()
    app.buttons["music-category-Playlists"].tap()
    app.buttons["playlist-create"].tap()
    let name = app.textFields["playlist-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 4))
    name.tap()
    name.typeText("Road mix")
    app.buttons["playlist-create-save"].tap()
    let actions = app.buttons["playlist-actions"]
    let edit = app.buttons["Edit playlist"]
    XCTAssertTrue(actions.waitForExistence(timeout: 6))
    XCTAssertEqual(app.staticTexts["playlist-heading"].label, "Road mix")
    actions.tap()
    edit.tap()
    let add = app.buttons["playlist-add-songs"]
    XCTAssertTrue(add.waitForExistence(timeout: 6))
    add.tap()
    let song = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "playlist-add-fixture")
    ).firstMatch
    XCTAssertTrue(song.waitForExistence(timeout: 6))
    song.tap()
    let saved = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@ AND enabled == true", "Added 1"), object: song)
    XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 6), .completed)
    song.tap()
    let repeated = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@ AND enabled == true", "Added 2"), object: song)
    XCTAssertEqual(XCTWaiter.wait(for: [repeated], timeout: 6), .completed)
    app.navigationBars.buttons["Back"].firstMatch.tap()
    name.tap()
    name.typeText(" two")
    app.buttons["Save name"].tap()
    app.buttons["playlist-editor-done"].tap()
    XCTAssertTrue(app.buttons["playlist-track-1"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["playlist-track-1"].label, app.buttons["playlist-track-2"].label)
    XCTAssertEqual(app.staticTexts["playlist-heading"].label, "Road mix two")
    actions.tap()
    edit.tap()
    app.buttons["playlist-edit-order"].tap()
    app.buttons["playlist-entry-2"].tap()
    app.buttons["Remove song"].firstMatch.tap()
    let removal = app.sheets["Remove this copy from the playlist?"]
      .buttons["Remove song"].firstMatch
    XCTAssertTrue(removal.waitForExistence(timeout: 5))
    removal.tap()
    XCTAssertTrue(app.buttons["playlist-entry-1"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["playlist-entry-2"].waitForNonExistence(timeout: 5))
    app.navigationBars.buttons["Back"].firstMatch.tap()
    let delete = app.buttons["Delete playlist"].firstMatch
    XCTAssertTrue(delete.waitForExistence(timeout: 5))
    if !delete.isHittable { app.swipeUp() }
    delete.tap()
    let confirm = app.sheets["Delete “Road mix two”?"].buttons["playlist-confirm-delete"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    confirm.tap()
    XCTAssertTrue(app.buttons["playlist-create"].waitForExistence(timeout: 5))
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "label == %@", "Road mix two")).count, 0)
  }

  @MainActor func testPlaylistCoverSharingAndRepeatedEntryEdit() throws {
    let app = launchMutedPlaylistFixture()
    app.tabBars.buttons["Library"].tap()
    app.buttons["music-category-Playlists"].tap()
    let card = app.buttons["playlist-fixture-playlist-morning"]
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    card.tap()
    app.buttons["playlist-actions"].tap()
    app.buttons["Edit playlist"].tap()
    let cover = app.buttons["playlist-track-cover"]
    XCTAssertTrue(cover.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["playlist-choose-cover"].exists)
    let removeCover = app.buttons["Remove cover"].firstMatch
    removeCover.tap()
    let removeConfirmation = app.sheets["Remove the playlist cover?"]
      .buttons["playlist-confirm-remove-cover"].firstMatch
    XCTAssertTrue(removeConfirmation.waitForExistence(timeout: 5))
    removeConfirmation.tap()
    XCTAssertTrue(removeCover.waitForNonExistence(timeout: 6))
    cover.tap()
    XCTAssertTrue(removeCover.waitForExistence(timeout: 6))
    let sharing = app.buttons["playlist-sharing"]
    XCTAssertTrue(sharing.waitForExistence(timeout: 5))
    sharing.tap()
    let access = app.switches["playlist-public"].firstMatch
    XCTAssertTrue(access.waitForExistence(timeout: 5))
    XCTAssertEqual(access.value as? String, "0")
    let control = access.switches.firstMatch
    (control.exists ? control : access).tap()
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == '1'"), object: access)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
    let person = app.buttons["playlist-person-fixture-listener"].firstMatch
    person.tap()
    app.buttons["Can edit"].firstMatch.tap()
    app.navigationBars.buttons["Back"].firstMatch.tap()
    sharing.tap()
    XCTAssertTrue(person.waitForExistence(timeout: 5))
    XCTAssertEqual(access.value as? String, "1")
    XCTAssertTrue(
      app.descendants(matching: .any).matching(
        NSPredicate(format: "label CONTAINS %@ OR value == %@", "Can edit", "Can edit")
      ).firstMatch.waitForExistence(timeout: 5))
    app.navigationBars.buttons["Back"].firstMatch.tap()
    app.buttons["playlist-edit-order"].tap()
    let entry = app.buttons["playlist-entry-3"]
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    entry.tap()
    app.buttons["Move up"].firstMatch.tap()
    app.navigationBars.buttons["Back"].firstMatch.tap()
    app.buttons["playlist-editor-done"].tap()
    XCTAssertEqual(app.buttons["playlist-track-1"].label, app.buttons["playlist-track-2"].label)
    XCTAssertNotEqual(app.buttons["playlist-track-1"].label, app.buttons["playlist-track-3"].label)
  }
}
