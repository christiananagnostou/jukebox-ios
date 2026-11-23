import Foundation

protocol TokenVault: Sendable {
  func read(account: String) async throws -> String?
  func write(_ token: String, account: String) async throws
  func erase(account: String) async throws
}
actor MemoryVault: TokenVault {
  private var tokens: [String: String] = [:]
  func read(account: String) -> String? { tokens[account] }
  func write(_ token: String, account: String) { tokens[account] = token }
  func erase(account: String) { tokens[account] = nil }
}
