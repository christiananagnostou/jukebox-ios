import AVFoundation
import Darwin
import Foundation

@MainActor final class PlaybackTailFiles {
  let directory: URL
  private(set) var owned: Set<URL> = []
  private var writing: Set<URL> = []
  static func startupDirectory(integration: Bool, support: URL) -> URL? {
    integration
      ? support.appendingPathComponent("JukeboxIntegration", isDirectory: true)
        .appendingPathComponent("PlaybackTails", isDirectory: true)
      : nil
  }
  init(directory: URL? = nil) throws {
    self.directory =
      directory
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("JukeboxPlaybackTails", isDirectory: true)
    try Self.validateIntegrationComponents(self.directory)
    try FileManager.default.createDirectory(
      at: self.directory, withIntermediateDirectories: true,
      attributes: [
        .posixPermissions: 0o700,
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
      ])
    try Self.validateIntegrationComponents(self.directory)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var folder = self.directory
    try folder.setResourceValues(values)
    for file in try FileManager.default.contentsOfDirectory(
      at: self.directory, includingPropertiesForKeys: nil)
    {
      if ownsName(file) { try FileManager.default.removeItem(at: file) }
    }
  }
  private static func validateIntegrationComponents(_ directory: URL) throws {
    let parent = directory.deletingLastPathComponent()
    guard directory.lastPathComponent == "PlaybackTails",
      parent.lastPathComponent == "JukeboxIntegration"
    else { return }
    for component in [parent, directory] {
      var attributes = stat()
      if lstat(component.path, &attributes) == 0 {
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
          throw ClientError.invalidResponse
        }
      } else if errno != ENOENT {
        throw ClientError.invalidResponse
      }
    }
  }
  private func ownsName(_ url: URL) -> Bool {
    guard
      url.deletingLastPathComponent().standardizedFileURL.path
        == directory.standardizedFileURL.path,
      url.pathExtension == "mp3", url.lastPathComponent.hasPrefix("tail-")
    else { return false }
    return UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(5)))
      != nil
  }
  func write(_ data: Data) throws -> URL {
    guard !data.isEmpty, data.count <= 500_000 else { throw ClientError.unavailable }
    let path = try createFile(data)
    owned.insert(path)
    return path
  }
  func prepareQueued(
    _ source: MediaSource, isCurrent: @MainActor @Sendable () -> Bool
  ) async throws -> AVURLAsset? {
    guard QueuedTranscode.canPrepare(source), isCurrent() else { return nil }
    let path = try createFile(Data())
    writing.insert(path)
    defer { writing.remove(path) }
    do {
      let asset = try await QueuedTranscode.write(source, to: path)
      try Task.checkCancellation()
      guard writing.contains(path), isCurrent() else { throw CancellationError() }
      owned.insert(path)
      return asset
    } catch {
      try? FileManager.default.removeItem(at: path)
      throw error
    }
  }
  private func createFile(_ data: Data) throws -> URL {
    let path = directory.appendingPathComponent("tail-" + UUID().uuidString + ".mp3")
    do {
      try data.write(
        to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      try FileManager.default.setAttributes(
        [
          .posixPermissions: 0o600,
          .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ],
        ofItemAtPath: path.path)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var file = path
      try file.setResourceValues(values)
      return path
    } catch {
      try? FileManager.default.removeItem(at: path)
      throw error
    }
  }
  func remove(_ path: URL) {
    guard owned.remove(path) != nil, ownsName(path) else { return }
    try? FileManager.default.removeItem(at: path)
  }
  func retire(keeping: Set<URL>) {
    for path in owned.subtracting(keeping) { remove(path) }
  }
  func clear() {
    for file in writing { try? FileManager.default.removeItem(at: file) }
    writing.removeAll()
    retire(keeping: [])
  }
}
