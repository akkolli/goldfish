import CryptoKit
import Foundation
import LocalAuthentication
import Security

// Swift marks SecAccessCreate deprecated, but macOS still needs kSecAttrAccess
// here to avoid legacy keychain authorization UI during generic-password creation.
@_silgen_name("SecAccessCreate") private func goldfishSecAccessCreate(
  _ descriptor: CFString, _ trustedList: CFArray?, _ accessRef: UnsafeMutablePointer<SecAccess?>
) -> OSStatus

final class HistoryEncryption {
  enum StorageError: Error { case keyUnavailable, encryptionFailed }
  static let marker = "goldfish:v1:"
  private static let markerData = Data(marker.utf8)

  private let keyProvider: () -> SymmetricKey?
  private let resetProvider: () -> Void
  private let allowsUnencryptedStorage: Bool

  init() {
    if Self.shouldBypassSystemKeychain() {
      allowsUnencryptedStorage = true
      keyProvider = { nil }
      resetProvider = {}
    } else {
      allowsUnencryptedStorage = false
      keyProvider = { ClipboardEncryptionKeychain.shared.symmetricKey() }
      resetProvider = { ClipboardEncryptionKeychain.shared.resetStoredKey() }
    }
  }

  init(keyProvider: @escaping () -> SymmetricKey?, resetProvider: @escaping () -> Void = {}, allowsUnencryptedStorage: Bool = true) {
    self.keyProvider = keyProvider
    self.resetProvider = resetProvider
    self.allowsUnencryptedStorage = allowsUnencryptedStorage
  }

  static func migrationEncryption(at directory: URL) throws -> HistoryEncryption {
    guard let key = ClipboardEncryptionKeychain.shared.adoptLegacyKey(from: directory) else { throw StorageError.keyUnavailable }
    return HistoryEncryption(keyProvider: { key }, allowsUnencryptedStorage: false)
  }

  var isAvailable: Bool { keyProvider() != nil }

  var canPersist: Bool { allowsUnencryptedStorage || isAvailable }

  func protect(_ value: String?) -> String? {
    guard let value else { return nil }
    guard let combined = try? seal(Data(value.utf8)) else { return allowsUnencryptedStorage ? value : nil }
    return Self.marker + combined.base64EncodedString()
  }

  func unprotect(_ value: String?) -> String? {
    guard let value else { return nil }
    guard Self.isProtected(value) else { return value }
    let encoded = String(value.dropFirst(Self.protectionPrefix(value)?.count ?? 0))
    guard let data = Data(base64Encoded: encoded), let sealed = try? AES.GCM.SealedBox(combined: data) else { return value }
    guard let key = keyProvider(), let decrypted = try? AES.GCM.open(sealed, using: key) else { return nil }
    return String(data: decrypted, encoding: .utf8)
  }

  private func seal(_ data: Data) throws -> Data {
    guard let key = keyProvider() else { throw StorageError.keyUnavailable }
    guard let combined = try AES.GCM.seal(data, using: key).combined else { throw StorageError.encryptionFailed }
    return combined
  }

  func protectData(_ data: Data) -> Data { (try? seal(data)).map { Self.markerData + $0 } ?? data }

  func protectDataForStorage(_ data: Data) throws -> Data {
    do { return Self.markerData + (try seal(data)) } catch StorageError.keyUnavailable where allowsUnencryptedStorage { return data }
  }

  func unprotectData(_ data: Data) -> Data? {
    guard Self.isProtected(data) else { return data }
    let encrypted = data.dropFirst(
      data.starts(with: Self.markerData) ? Self.markerData.count : GoldfishMigration.legacyEncryptionMarker.utf8.count)
    guard let sealed = try? AES.GCM.SealedBox(combined: encrypted), let key = keyProvider(),
      let decrypted = try? AES.GCM.open(sealed, using: key)
    else { return nil }
    return decrypted
  }

  private static func protectionPrefix(_ value: String) -> String? {
    [marker, GoldfishMigration.legacyEncryptionMarker].first { value.hasPrefix($0) }
  }

  static func isProtected(_ value: String) -> Bool { protectionPrefix(value) != nil }

  static func isProtected(_ data: Data) -> Bool {
    data.starts(with: markerData) || data.starts(with: Data(GoldfishMigration.legacyEncryptionMarker.utf8))
  }

  func resetStoredKey() { resetProvider() }

  static func shouldBypassSystemKeychain(
    environment: [String: String] = ProcessInfo.processInfo.environment, arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> Bool {
    if environment["GOLDFISH_DISABLE_KEYCHAIN"] == "1" || environment["XCTestConfigurationFilePath"] != nil { return true }

    return arguments.contains { argument in argument.contains(".xctest") || argument.hasSuffix("/xctest") }
  }

  static func resolvedKeyData(generatedData: Data, addStatus: OSStatus, existingData: Data?) -> Data? {
    switch addStatus {
    case errSecSuccess: return generatedData
    case errSecDuplicateItem: return existingData
    default: return nil
    }
  }
}

private enum ClipboardEncryptionKeychain { static let shared = KeychainBackedKeyProvider() }

private final class KeychainBackedKeyProvider {
  private let service: String
  private let fallbackDirectory: URL?

  init(service: String = "com.local.goldfish.encryption", fallbackDirectory: URL? = nil) {
    self.service = service
    self.fallbackDirectory = fallbackDirectory
  }

  func adoptLegacyKey(from directory: URL) -> SymmetricKey? {
    queue.sync {
      let legacy = KeychainBackedKeyProvider(
        service: GoldfishMigration.legacyBundleIdentifier + ".encryption", fallbackDirectory: directory)
      guard let data = legacy.readFallbackKeyData() ?? legacy.readKeyData(), let saved = saveKeyData(data), saved == data else {
        return nil
      }
      cachedKey = SymmetricKey(data: data)
      return cachedKey
    }
  }
  private let queue = DispatchQueue(label: "clipboard.encryption-keychain")
  private let keychainTimeout: TimeInterval = 0.35
  private var cachedKey: SymmetricKey?

  func symmetricKey() -> SymmetricKey? {
    queue.sync {
      if let cachedKey { return cachedKey }
      // Read legacy storage first. Only generate a key when neither stable
      // identity is available, and never cache an indeterminate save.
      let data = readFallbackKeyData() ?? readKeyData() ?? saveKeyData(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
      cachedKey = data.map(SymmetricKey.init(data:))
      return cachedKey
    }
  }

  func resetStoredKey() {
    queue.sync {
      cachedKey = nil
      _ = deleteKeyData()
      deleteFallbackKeyData()
    }
  }

  private func readKeyData() -> Data? {
    runKeychainOperation {
      var query = self.baseQuery()
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      query[kSecUseAuthenticationContext as String] = self.nonInteractiveContext()

      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      guard status == errSecSuccess else { return nil }
      return result as? Data
    }
  }

  private func saveKeyData(_ data: Data) -> Data? {
    guard
      let status: OSStatus = runKeychainOperation({
        var query = self.baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecUseAuthenticationContext as String] = self.nonInteractiveContext()
        if let access = self.keychainAccess() { query[kSecAttrAccess as String] = access }

        return SecItemAdd(query as CFDictionary, nil)
      })
    else {
      // The add may still complete after our timeout. Do not create or cache a
      // competing key while the outcome is unknown.
      return nil
    }
    return HistoryEncryption.resolvedKeyData(
      generatedData: data, addStatus: status, existingData: status == errSecDuplicateItem ? readKeyData() : nil)
  }

  private func runKeychainOperation<T>(_ operation: @escaping () -> T?) -> T? {
    let lock = NSLock()
    var result: T?
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .utility).async {
      let value = operation()
      lock.withLock { result = value }
      semaphore.signal()
    }

    guard semaphore.wait(timeout: .now() + keychainTimeout) == .success else { return nil }
    return lock.withLock { result }
  }

  private func baseQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "history-v1"]
  }

  private func nonInteractiveContext() -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = true
    return context
  }

  private func keychainAccess() -> SecAccess? {
    var access: SecAccess?
    let status = goldfishSecAccessCreate("Goldfish encryption key" as CFString, nil, &access)
    guard status == errSecSuccess else { return nil }
    return access
  }

  private func readFallbackKeyData() -> Data? {
    let url = fallbackKeyURL()
    guard let data = try? Data(contentsOf: url), data.count == 32 else { return nil }
    return data
  }

  private func deleteKeyData() -> Bool {
    runKeychainOperation {
      let status = SecItemDelete(self.baseQuery() as CFDictionary)
      return status == errSecSuccess || status == errSecItemNotFound
    } ?? false
  }

  private func deleteFallbackKeyData() { try? FileManager.default.removeItem(at: fallbackKeyURL()) }

  private func fallbackKeyURL() -> URL {
    let base = fallbackDirectory ?? HistoryStore.storageDirectory()
    return base.appendingPathComponent("history-encryption.key")
  }
}
