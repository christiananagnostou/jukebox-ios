import Foundation
import Synchronization

struct HTTPReply: Sendable {
  let data: Data
  let status: Int
}
protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> HTTPReply }

private final class BoundedHTTPBody: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let limit: Int
  let finish: @Sendable (Result<HTTPReply, any Error>, HTTPURLResponse?, Int) -> Void
  private var response: HTTPURLResponse?
  private var data = Data()
  private var failure: (any Error)?

  init(
    limit: Int,
    finish: @escaping @Sendable (Result<HTTPReply, any Error>, HTTPURLResponse?, Int) -> Void
  ) {
    self.limit = limit
    self.finish = finish
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive value: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = value as? HTTPURLResponse else {
      failure = ClientError.invalidResponse
      completionHandler(.cancel)
      return
    }
    response = http
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    guard failure == nil else { return }
    guard chunk.count <= limit - data.count else {
      failure = URLError(.dataLengthExceedsMaximum)
      dataTask.cancel()
      return
    }
    data.append(chunk)
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let result: Result<HTTPReply, any Error>
    if let problem = failure ?? error {
      result = .failure(problem)
    } else if let response {
      result = .success(HTTPReply(data: data, status: response.statusCode))
    } else {
      result = .failure(ClientError.invalidResponse)
    }
    finish(result, response, data.count)
  }
}

actor LiveHTTP: HTTPTransport {
  private let session: URLSession
  private let maximumBytes: Int
  init(maximumBytes: Int = 3_000_000, resourceTimeout: TimeInterval = 25) {
    self.maximumBytes = max(0, maximumBytes)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForRequest = min(12, resourceTimeout)
    configuration.timeoutIntervalForResource = resourceTimeout
    session = URLSession(configuration: configuration)
  }
  #if DEBUG
    init(captureTestSession: URLSession, maximumBytes: Int = 3_000_000) {
      session = captureTestSession
      self.maximumBytes = max(0, maximumBytes)
    }
  #endif
  func send(_ request: URLRequest) async throws -> HTTPReply {
    try Task.checkCancellation()
    #if DEBUG
      let capture = TransportCapture.shared
      let ticket = capture.begin(context: TransportCapture.caller)
    #endif
    let running = Mutex<URLSessionDataTask?>(nil)
    let reply: HTTPReply = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { completion in
        let task = session.dataTask(with: request)
        task.delegate = BoundedHTTPBody(limit: maximumBytes) { result, response, count in
          #if DEBUG
            if let ticket {
              capture.finish(ticket) {
                var code = 0
                if case .failure(let error) = result { code = (error as? URLError)?.errorCode ?? 0 }
                return .init(
                  stage: .classify(request), http: response?.statusCode ?? 0, error: code,
                  bytes: count, httpResponseObserved: response != nil)
              }
            }
          #endif
          completion.resume(with: result)
        }
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
    return reply
  }
}
