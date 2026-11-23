#if DEBUG || CATALOG_SCALE_FIXTURE
  import Darwin
  import Foundation

  @MainActor enum CatalogScaleAcceptance {
    struct Point: Codable {
      let cycle: Int
      let elapsed: Double
      let cpu: Double
      let footprint: UInt64?
      let retained: Int
    }
    struct Report: Codable {
      let runID: String
      let songs: Int
      let optimizedFixture: Bool
      var passed = false
      var failure = 0
      var maxPages = 0
      var maxItems = 0
      var backCatalogReads = 0
      var retiredItems = -1
      var retiredPages = -1
      var childItemsBeforeRetirement = 0
      var points: [Point] = []
      var logical: [String: Int] = [:]
      enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case songs, optimizedFixture, passed, failure, maxPages, maxItems, points, logical
        case backCatalogReads, retiredItems, retiredPages, childItemsBeforeRetirement
      }
    }
    private struct Failure: Error { let step: Int }
    private static func reportURL() -> URL {
      FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("catalog-scale-report.json")
    }
    static func cleanup(_ input: IndexedCatalogInput) {
      let files = FileManager.default
      let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      try? files.removeItem(at: support.appendingPathComponent(input.directory, isDirectory: true))
      let path = reportURL()
      if let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_384,
        let bytes = try? Data(contentsOf: path),
        let value = try? JSONDecoder().decode(Report.self, from: bytes),
        UUID(uuidString: value.runID) == input.id
      {
        try? files.removeItem(at: path)
      }
    }
    static func run(
      _ input: IndexedCatalogInput, fresh: Bool, store: PlayerStore, source: URL
    ) async {
      if input.cleanup {
        cleanup(input)
        return
      }
      #if CATALOG_SCALE_FIXTURE && !DEBUG
        let optimized = true
      #else
        let optimized = false
      #endif
      var report = Report(
        runID: input.id.uuidString, songs: input.songCount,
        optimizedFixture: optimized)
      var accepted: MusicBrowser?
      let began = ProcessInfo.processInfo.systemUptime
      func require(_ value: Bool, _ step: Int) throws {
        if !value { throw Failure(step: step) }
      }
      do {
        try require(fresh, 1)
        let catalog = IndexedCatalogFixture(songCount: input.songCount, source: source)
        await store.enterFixture(service: catalog)
        guard let browser = store.browser, store.isFixture else { return }
        accepted = browser
        func current() -> Bool { store.isFixture && store.browser === browser && !Task.isCancelled }
        func settle() async throws {
          while browser.window.loading || !browser.window.loaded {
            try require(current() && ProcessInfo.processInfo.systemUptime - began < 30, 3)
            try await Task.sleep(for: .milliseconds(10))
          }
          try require(current(), 4)
          report.maxPages = max(report.maxPages, browser.window.pages.count)
          report.maxItems = max(report.maxItems, browser.window.items.count)
          try require(
            browser.window.pages.values.allSatisfy { $0.count <= 40 }
              && browser.window.items.count <= input.songCount, 5)
        }
        await browser.start()
        try await settle()
        browser.selectCategory(.songs)
        try await settle()
        let middle = input.songCount / 2 / 40 * 40
        let last = input.songCount - 40
        report.points.append(
          point(
            -1, began: began,
            retained: browser.windows.values.reduce(0) {
              $0 + $1.items.count
            }))
        for cycle in 0..<3 {
          for offset in [
            0, 40, 80, 120, 160, 200, middle, middle + 40, middle + 80,
            last, last - 40, last - 80, middle + 40, 80, 40, 0,
          ] {
            browser.loadListing(offset: offset)
            try await settle()
            try require(browser.window.pages[offset]?.first?.id == "scale-song-\(offset)", 6)
          }
          try require(
            browser.window.items.first?.id == "scale-song-0"
              && browser.window.pages.count == 12 && browser.window.items.count == 480, 7)
          let beforeBack = await catalog.snapshot()["queries"] ?? -1
          for offset in [last, middle + 40, 200, 120, 80, 40, 0] {
            browser.loadListing(offset: offset)
            try await settle()
            try require(browser.window.pages[offset]?.first?.id == "scale-song-\(offset)", 16)
          }
          let afterBack = await catalog.snapshot()["queries"] ?? -2
          report.backCatalogReads += afterBack - beforeBack
          try require(report.backCatalogReads == 0, 17)
          guard let anchor = browser.window.items.dropFirst(5).first else { throw Failure(step: 8) }
          browser.setAnchor(anchor.id)
          guard let album = try await browser.relatedAlbum(anchor), current(),
            let detail = browser.detail(album)
          else { throw Failure(step: 9) }
          await detail.load()
          try require(
            current() && detail.tracks.count == 4 && browser.window.anchor == anchor.id, 10)
          browser.searchText = String(format: "Song %06d", input.songCount - 1)
          browser.searchChanged()
          try await settle()
          try require(browser.window.items.map(\.id) == ["scale-song-\(input.songCount - 1)"], 11)
          browser.searchText = ""
          browser.searchChanged()
          try await settle()
          try await Task.sleep(for: .milliseconds(200))
          try require(current(), 12)
          report.points.append(
            point(
              cycle, began: began,
              retained: browser.windows.values.reduce(0) {
                $0 + $1.items.count
              }))
        }
        browser.selectCategory(.artists)
        try await settle()
        guard let artist = browser.window.items.first, let child = browser.artistBrowser(artist)
        else { throw Failure(step: 18) }
        while child.window.loading || !child.window.loaded {
          try require(current() && ProcessInfo.processInfo.systemUptime - began < 30, 19)
          try await Task.sleep(for: .milliseconds(10))
        }
        try require(current() && child.metadataIsCurrent, 20)
        report.childItemsBeforeRetirement = child.window.items.count
        try require(report.childItemsBeforeRetirement == 40, 21)
        browser.selectCategory(.songs)
        try await settle()
        let logical = await catalog.snapshot()
        try require(current(), 13)
        report.logical = logical
        try require(logical["maximum_batch"] == 40, 14)
        browser.searchText = "Song 000001"
        browser.searchChanged()
        browser.retire()
        try await Task.sleep(for: .milliseconds(350))
        report.retiredItems =
          (browser.windows.values.reduce(0) { $0 + $1.items.count })
          + child.windows.values.reduce(0) { $0 + $1.items.count }
        report.retiredPages =
          (browser.windows.values.reduce(0) { $0 + $1.pages.count })
          + child.windows.values.reduce(0) { $0 + $1.pages.count }
        try require(
          current() && browser.window.items.isEmpty && browser.libraryID == nil
            && report.retiredItems == 0 && report.retiredPages == 0, 15)
        report.passed = true
      } catch {
        report.failure = (error as? Failure)?.step ?? 99
      }
      guard !Task.isCancelled, accepted == nil || (store.isFixture && store.browser === accepted)
      else {
        return
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      if let bytes = try? encoder.encode(report), bytes.count <= 16_384 {
        try? bytes.write(to: reportURL(), options: [.atomic, .completeFileProtectionUnlessOpen])
      }
    }
    private static func point(_ cycle: Int, began: Double, retained: Int) -> Point {
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      let cpu =
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
      let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      return Point(
        cycle: cycle, elapsed: ProcessInfo.processInfo.systemUptime - began, cpu: cpu,
        footprint: result == KERN_SUCCESS ? info.phys_footprint : nil, retained: retained)
    }
  }
#endif
