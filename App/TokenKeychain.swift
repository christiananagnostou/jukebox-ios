import Foundation
import Security

actor KeychainVault: TokenVault {
  private(set) var diagnosticStatus: OSStatus?
  private let service = "dev.jukebox.ios.tokens"
  private func query(_ account: String) throws -> [CFString: Any] {
    guard account.count == 64, account.allSatisfy(\.isHexDigit) else {
      throw ClientError.invalidResponse
    }
    return [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
    ]
  }
  func read(account: String) throws -> String? {
    var q = try query(account)
    q[kSecReturnData] = true
    q[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else { throw ClientError.secureStorage }
    return value
  }
  func write(_ token: String, account: String) throws {
    let q = try query(account)
    let data = Data(token.utf8)
    let updated = SecItemUpdate(q as CFDictionary, [kSecValueData: data] as CFDictionary)
    diagnosticStatus = updated
    if updated == errSecItemNotFound {
      var add = q
      add[kSecValueData] = data
      add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let added = SecItemAdd(add as CFDictionary, nil)
      diagnosticStatus = added
      guard added == errSecSuccess else { throw ClientError.secureStorage }
    } else if updated != errSecSuccess {
      throw ClientError.secureStorage
    }
  }
  func erase(account: String) throws {
    let status = SecItemDelete(try query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ClientError.secureStorage
    }
  }
}
