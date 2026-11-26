import XCTest

@testable import JukeboxCore

final class QueuePersistenceTests: XCTestCase {
  private let account = String(repeating: "a", count: 64)
  private var repeatedQueue: QueueState {
    let song = MusicItem.fixtureTracks[0]
    var state = QueueState(
      entries: [QueueEntry(song), QueueEntry(MusicItem.fixtureTracks[1]), QueueEntry(song)],
      index: 2, position: 47.25, quality: .high)
    state.playlistID = "example-playlist"
    return state
  }

  func testLegacyQueueMigratesOnceAndProgressWritesKeepTheExactOccurrence() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LibraryStorage(directory: directory)
    let base = directory.appendingPathComponent(account + ".json")
    let progress = directory.appendingPathComponent(account + ".progress.json")
    let legacy = repeatedQueue
    try JSONEncoder().encode(legacy).write(to: base)
    let loaded = try await store.restore(account: account)
    var active = try XCTUnwrap(loaded)
    XCTAssertEqual(active, legacy)
    try await store.save(active, account: account)
    let snapshot = try Data(contentsOf: base)
    XCTAssertEqual(try JSONDecoder().decode(QueueState.self, from: snapshot), legacy)
    active.index = 0
    active.position = 6.125
    active.quality = .compact
    try await store.save(active, account: account)
    XCTAssertEqual(try Data(contentsOf: base), snapshot)
    XCTAssertLessThan(try Data(contentsOf: progress).count, 300)
    let reopened = try LibraryStorage(directory: directory)
    let first = try await reopened.restore(account: account)
    XCTAssertEqual(first, active)
    var resumed = try XCTUnwrap(first)
    resumed.index = 2
    resumed.position = 63.75
    try await reopened.save(resumed, account: account)
    let second = try await store.restore(account: account)
    XCTAssertEqual(second, resumed)
    XCTAssertEqual(try Data(contentsOf: base), snapshot)
  }

  func testReplacingOrRevertingOrderCannotReplayAnOlderProgressFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try LibraryStorage(directory: directory)
    let progress = directory.appendingPathComponent(account + ".progress.json")
    var original = repeatedQueue
    try await storage.save(original, account: account)
    original.position = 80
    try await storage.save(original, account: account)
    let oldProgress = try Data(contentsOf: progress)
    var moved = original
    moved.move(from: 2, to: 0)
    moved.position = 11
    try await storage.save(moved, account: account)
    let reopened = try LibraryStorage(directory: directory)
    let afterEdit = try await reopened.restore(account: account)
    XCTAssertEqual(afterEdit, moved)
    original.position = 14
    try await storage.save(original, account: account)
    try oldProgress.write(to: progress, options: .atomic)
    let reverted = try await reopened.restore(account: account)
    XCTAssertEqual(reverted, original)
    original.playlistID = "another-playlist"
    try await storage.save(original, account: account)
    let changedPlaylist = try await reopened.restore(account: account)
    XCTAssertEqual(changedPlaylist, original)
  }

  func testMissingCorruptAndMismatchedProgressFallBackToLastQueueEdit() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try LibraryStorage(directory: directory)
    let progress = directory.appendingPathComponent(account + ".progress.json")
    let original = repeatedQueue
    try await storage.save(original, account: account)
    var changed = original
    changed.index = 0
    changed.position = 16
    try await storage.save(changed, account: account)
    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: progress))
    var wrong = try XCTUnwrap(value as? [String: Any])
    wrong["occurrence"] = original.current?.id.uuidString
    for content in [try JSONSerialization.data(withJSONObject: wrong), Data("{".utf8), nil] {
      if let content {
        try content.write(to: progress, options: .atomic)
      } else {
        try FileManager.default.removeItem(at: progress)
      }
      let saved = try await storage.restore(account: account)
      XCTAssertEqual(saved, original)
    }
  }

  func testProgressRebuildsAnExternallyRemovedOrReplacedSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try LibraryStorage(directory: directory)
    let base = directory.appendingPathComponent(account + ".json")
    var state = repeatedQueue
    try await storage.save(state, account: account)
    try FileManager.default.removeItem(at: base)
    state.position = 8
    try await storage.save(state, account: account)
    let other = try LibraryStorage(directory: directory)
    let rebuilt = try await other.restore(account: account)
    XCTAssertEqual(rebuilt, state)
    try await other.save(QueueState(), account: account)
    state.position = 12
    try await storage.save(state, account: account)
    let replaced = try await other.restore(account: account)
    XCTAssertEqual(replaced, state)
  }

  func testFailedProgressWriteCanRetryAndRetiredLeaseCannotResurrectIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try LibraryStorage(directory: directory)
    let progress = directory.appendingPathComponent(account + ".progress.json")
    var state = repeatedQueue
    let lease = await storage.lease(account: account)
    try await storage.saveIfCurrent(state, account: account, lease: lease, revision: 1)
    try FileManager.default.createDirectory(at: progress, withIntermediateDirectories: false)
    state.position = 5.5
    do {
      try await storage.saveIfCurrent(state, account: account, lease: lease, revision: 2)
      XCTFail("Writing a file over a directory should fail")
    } catch {}
    try FileManager.default.removeItem(at: progress)
    try await storage.saveIfCurrent(state, account: account, lease: lease, revision: 2)
    let saved = try await storage.restore(account: account)
    XCTAssertEqual(saved, state)
    let other = String(repeating: "b", count: 64)
    try await storage.save(state, account: other)
    state.position = 9
    try await storage.save(state, account: other)
    try await storage.retire(account: account, erase: true)
    try await storage.saveIfCurrent(state, account: account, lease: lease, revision: 3)
    XCTAssertFalse(FileManager.default.fileExists(atPath: progress.path))
    let removed = try await storage.restore(account: account)
    let retained = try await storage.restore(account: other)
    XCTAssertNil(removed)
    XCTAssertEqual(retained, state)
  }
}
