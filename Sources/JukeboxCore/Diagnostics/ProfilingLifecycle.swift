import Darwin
import Foundation

enum ProfilingLaunch {
  case absent, rejected
  case run(UUID)
  case cleanup(UUID)
  case retirement(UUID)
  case inspectReport(UUID)
  case clearInspection(UUID)
  init(arguments: [String]) {
    let flags = arguments.filter { $0.hasPrefix("--profile") }
    guard !flags.isEmpty else {
      self = .absent
      return
    }
    guard arguments.filter({ $0 == "--fixture" }).count == 1,
      !arguments.contains(where: {
        $0 == "--integration" || $0 == "--connect" || $0.hasPrefix("--catalog-scale")
          || $0.hasPrefix("--transport-")
      })
    else {
      self = .rejected
      return
    }
    if flags.count == 1 {
      for (prefix, cleanup) in [
        ("--profile-inspect-report=", false), ("--profile-inspect-cleanup=", true),
      ] {
        if flags[0].hasPrefix(prefix),
          let id = UUID(uuidString: String(flags[0].dropFirst(prefix.count)))
        {
          self = cleanup ? .clearInspection(id) : .inspectReport(id)
          return
        }
      }
    }
    #if DEBUG
      if flags.count == 1, flags[0].hasPrefix("--profile-retirement-check="),
        let id = UUID(uuidString: String(flags[0].dropFirst("--profile-retirement-check=".count)))
      {
        self = .retirement(id)
        return
      }
    #endif
    let ids = flags.filter { $0.hasPrefix("--profile-fixture=") }
    guard ids.count == 1,
      let id = UUID(uuidString: String(ids[0].dropFirst("--profile-fixture=".count))),
      flags.allSatisfy({
        $0 == ids[0] || $0 == "--profile-cleanup" || $0 == "--profile-albums"
          || $0 == "--profile-background-settings"
      }),
      flags.filter({ $0 == "--profile-cleanup" }).count <= 1,
      flags.filter({ $0 == "--profile-albums" }).count <= 1,
      flags.filter({ $0 == "--profile-background-settings" }).count <= 1,
      !(flags.contains("--profile-cleanup")
        && (flags.contains("--profile-albums") || flags.contains("--profile-background-settings")))
    else {
      self = .rejected
      return
    }
    self = flags.contains("--profile-cleanup") ? .cleanup(id) : .run(id)
  }
  var isAttempted: Bool { if case .absent = self { false } else { true } }
  var isRejected: Bool { if case .rejected = self { true } else { false } }
  var runID: UUID? { if case .run(let id) = self { id } else { nil } }
  func startup<T>(normal: () -> T, fixture: (UUID) -> T, isolated: () -> T) -> T {
    switch self {
    case .absent: normal()
    case .run(let id): fixture(id)
    case .cleanup, .retirement, .inspectReport, .clearInspection: isolated()
    case .rejected:
      isolated()
    }
  }
}

enum ProfilingFixtureFiles {
  private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
    do { return try FileManager.default.attributesOfItem(atPath: url.path) } catch let error
      as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    { return nil }
  }
  private static func require(
    _ attributes: [FileAttributeKey: Any], type: FileAttributeType, limit: Int? = nil
  ) throws {
    guard attributes[.type] as? FileAttributeType == type else { throw ClientError.invalidResponse }
    if let limit {
      guard let size = attributes[.size] as? NSNumber, size.intValue >= 0, size.intValue <= limit
      else { throw ClientError.invalidResponse }
    }
  }
  private static func reportID(documents: URL) throws -> UUID? {
    let report = documents.appendingPathComponent("profiling-report.json")
    guard let values = try attributes(report) else { return nil }
    try require(values, type: .typeRegular, limit: 300_000)
    guard
      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: report))
        as? [String: Any],
      object["marker"] as? String == "JUKEBOX-PROFILE-1", let text = object["runID"] as? String,
      let id = UUID(uuidString: text)
    else { throw ClientError.invalidResponse }
    return id
  }
  static func freshDirectory(support: URL, runID: UUID) throws -> URL {
    if let values = try attributes(support) { try require(values, type: .typeDirectory) }
    let namespace = support.appendingPathComponent("JukeboxProfiling", isDirectory: true)
    if let values = try attributes(namespace) { try require(values, type: .typeDirectory) }
    let folder = namespace.appendingPathComponent(runID.uuidString, isDirectory: true)
    guard try attributes(folder) == nil else { throw ClientError.invalidResponse }
    return folder
  }
  static let audioName = "profile-silence.wav"
  static let audioByteCount = 17_280_044
  static func prepareAudio(support: URL, runID: UUID) throws -> URL {
    let folder = try freshDirectory(support: support, runID: runID)
    let files = FileManager.default
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    let audio = folder.appendingPathComponent(audioName)
    let descriptor = open(audio.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      _ = rmdir(folder.path)
      throw ClientError.invalidResponse
    }
    var complete = false
    defer {
      close(descriptor)
      if !complete {
        _ = unlink(audio.path)
        _ = rmdir(folder.path)
      }
    }
    func writeBytes(_ data: Data) throws {
      try data.withUnsafeBytes { raw in
        var count = 0
        while count < raw.count {
          let written = write(descriptor, raw.baseAddress!.advanced(by: count), raw.count - count)
          if written < 0, errno == EINTR { continue }
          guard written > 0 else { throw ClientError.invalidResponse }
          count += written
        }
      }
    }
    var header = Data("RIFF".utf8)
    func littleEndian<T: FixedWidthInteger>(_ value: T) {
      var value = value.littleEndian
      withUnsafeBytes(of: &value) { header.append(contentsOf: $0) }
    }
    littleEndian(UInt32(audioByteCount - 8))
    header.append(contentsOf: "WAVEfmt ".utf8)
    littleEndian(UInt32(16))
    littleEndian(UInt16(1))
    littleEndian(UInt16(1))
    littleEndian(UInt32(48_000))
    littleEndian(UInt32(96_000))
    littleEndian(UInt16(2))
    littleEndian(UInt16(16))
    header.append(contentsOf: "data".utf8)
    littleEndian(UInt32(audioByteCount - 44))
    try writeBytes(header)
    let second = Data(repeating: 0, count: 96_000)
    for _ in 0..<180 { try writeBytes(second) }
    complete = true
    return audio
  }
  static func cleanup(support: URL, documents: URL, runID: UUID) throws {
    let files = FileManager.default
    let namespace = support.appendingPathComponent("JukeboxProfiling", isDirectory: true)
    let ownsReport = try reportID(documents: documents) == runID
    if let values = try attributes(namespace) {
      try require(values, type: .typeDirectory)
      let folder = namespace.appendingPathComponent(runID.uuidString, isDirectory: true)
      if let values = try attributes(folder) {
        try require(values, type: .typeDirectory)
        let children = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard children.count <= 5 else { throw ClientError.invalidResponse }
        for child in children {
          let name = child.lastPathComponent
          if name == audioName {
            guard let values = try attributes(child),
              (values[.size] as? NSNumber)?.intValue == audioByteCount
            else { throw ClientError.invalidResponse }
            try require(values, type: .typeRegular, limit: audioByteCount)
            continue
          }
          let account = child.deletingPathExtension().lastPathComponent
          let allowed =
            ["connections.json", "installation-id"].contains(name)
            || (child.pathExtension == "json" && account.count == 64
              && account.allSatisfy({ $0.isHexDigit }))
          guard allowed, let values = try attributes(child) else {
            throw ClientError.invalidResponse
          }
          try require(values, type: .typeRegular, limit: 1_000_000)
        }
        try files.removeItem(at: folder)
      }
    }
    if ownsReport {
      try files.removeItem(at: documents.appendingPathComponent("profiling-report.json"))
    }
  }
  struct IdentityReceipt: Codable {
    let marker: String
    let requestID: UUID
    let result: String
    let reportID: UUID?
  }
  static func inspectionURL(documents: URL, requestID: UUID) -> URL {
    documents.appendingPathComponent("profiling-identity-" + requestID.uuidString + ".json")
  }
  static func inspectReport(documents: URL, requestID: UUID) throws {
    let receipt = inspectionURL(documents: documents, requestID: requestID)
    guard try attributes(receipt) == nil else { throw ClientError.invalidResponse }
    let id: UUID?
    let result: String
    do {
      id = try reportID(documents: documents)
      result = id == nil ? "absent" : "valid"
    } catch {
      id = nil
      result = "rejected"
    }
    let data = try JSONEncoder().encode(
      IdentityReceipt(
        marker: "JUKEBOX-PROFILE-IDENTITY-1", requestID: requestID, result: result, reportID: id))
    guard data.count <= 512 else { throw ClientError.invalidResponse }
    #if os(iOS)
      try data.write(
        to: receipt, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: receipt, options: .atomic)
    #endif
  }
  static func clearInspection(documents: URL, requestID: UUID) throws {
    let receipt = inspectionURL(documents: documents, requestID: requestID)
    guard let values = try attributes(receipt) else { return }
    try require(values, type: .typeRegular, limit: 512)
    let value = try JSONDecoder().decode(IdentityReceipt.self, from: Data(contentsOf: receipt))
    guard value.marker == "JUKEBOX-PROFILE-IDENTITY-1", value.requestID == requestID,
      ["absent", "valid", "rejected"].contains(value.result),
      (value.result == "valid") == (value.reportID != nil)
    else { throw ClientError.invalidResponse }
    try FileManager.default.removeItem(at: receipt)
  }
}

struct ProfilingIdleTimerState {
  private var prior: Bool?
  mutating func begin(current: Bool) -> Bool {
    guard prior == nil else { return false }
    prior = current
    return true
  }
  mutating func restore() -> Bool? {
    defer { prior = nil }
    return prior
  }
}
