import AVFoundation
import AudioToolbox
import Foundation
import Synchronization

enum QueuedTranscode {
  static let maximumBytes = 16 * 1024 * 1024

  static func canPrepare(_ source: MediaSource) -> Bool {
    guard source.serverTimeSeek, source.quality != .original, source.timeOrigin == 0,
      let scheme = source.url.scheme, ["http", "https"].contains(scheme),
      let seconds = source.serverDuration, seconds.isFinite, seconds > 0
    else { return false }
    return seconds * Double(source.quality.bitrate) / 8 <= Double(maximumBytes)
  }

  @discardableResult static func write(
    _ source: MediaSource, to file: URL, configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> AVURLAsset {
    guard canPrepare(source), let expectedDuration = source.serverDuration else {
      throw ClientError.unavailable
    }
    try Task.checkCancellation()
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    var request = source.upstreamRequest
    request.networkServiceType = .background
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    let running = Mutex<URLSessionDataTask?>(nil)
    let encodedDuration = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (completion: CheckedContinuation<Double, any Error>) in
        let sink = FileReceiver(file: handle, completion: completion)
        let session = URLSession(configuration: configuration, delegate: sink, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.priority = URLSessionTask.lowPriority
        running.withLock { active in
          active = task
          task.resume()
          if Task.isCancelled { task.cancel() }
        }
      }
    } onCancel: {
      running.withLock { $0?.cancel() }
    }
    try Task.checkCancellation()
    let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let duration = try await asset.load(.duration).seconds
    try Task.checkCancellation()
    guard duration.isFinite, duration > 0, abs(encodedDuration - expectedDuration) <= 0.25,
      abs(encodedDuration - duration) <= 0.25
    else {
      throw ClientError.invalidResponse
    }
    return asset
  }

  private final class FileReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let file: FileHandle
    let completion: CheckedContinuation<Double, any Error>
    var parser: AudioFileStreamID?
    var packets: UInt64 = 0
    var expected: Int64?
    var count = 0
    var failure: (any Error)?

    init(file: FileHandle, completion: CheckedContinuation<Double, any Error>) {
      self.file = file
      self.completion = completion
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
      do {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        if http.statusCode == 401 { throw ClientError.unauthorized }
        if http.statusCode == 403 { throw ClientError.forbidden }
        guard http.statusCode == 200, http.value(forHTTPHeaderField: "Content-Range") == nil,
          ["audio/mpeg", "audio/mp3", "application/octet-stream"].contains(
            http.mimeType?.lowercased() ?? "application/octet-stream")
        else { throw ClientError.invalidResponse }
        let request = MediaBridgeRequest(method: "GET", path: "", range: nil)
        expected = try MediaBridgeResponse(http, request: request).bodyLength
        guard expected.map({ $0 > 0 && $0 <= maximumBytes }) ?? true else {
          throw ClientError.invalidResponse
        }
        guard parser == nil,
          AudioFileStreamOpen(
            Unmanaged.passUnretained(self).toOpaque(), { _, _, _, _ in },
            { context, _, packetCount, _, _ in
              Unmanaged<FileReceiver>.fromOpaque(context).takeUnretainedValue().packets += UInt64(
                packetCount)
            }, kAudioFileMP3Type, &parser) == noErr
        else { throw ClientError.invalidResponse }
        completionHandler(.allow)
      } catch {
        failure = error
        completionHandler(.cancel)
      }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      guard failure == nil else { return }
      do {
        guard !data.isEmpty else { return }
        guard data.count <= maximumBytes - count, let parser,
          data.withUnsafeBytes({
            AudioFileStreamParseBytes(parser, UInt32($0.count), $0.baseAddress, [])
          }) == noErr
        else { throw ClientError.invalidResponse }
        try file.write(contentsOf: data)
        count += data.count
      } catch {
        failure = error
        dataTask.cancel()
      }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
      defer {
        if let parser { AudioFileStreamClose(parser) }
        session.finishTasksAndInvalidate()
      }
      do {
        if let error = failure ?? error { throw error }
        guard count > 0, expected.map({ $0 == Int64(count) }) ?? true, let parser,
          AudioFileStreamParseBytes(parser, 0, nil, []) == noErr
        else {
          throw ClientError.invalidResponse
        }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        guard
          AudioFileStreamGetProperty(parser, kAudioFileStreamProperty_DataFormat, &size, &format)
            == noErr,
          format.mFormatID == kAudioFormatMPEGLayer3, format.mSampleRate > 0,
          format.mFramesPerPacket > 0, packets > 0
        else { throw ClientError.invalidResponse }
        completion.resume(
          returning: Double(packets) * Double(format.mFramesPerPacket) / format.mSampleRate)
      } catch {
        completion.resume(throwing: error)
      }
    }
  }
}
