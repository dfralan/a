// a

import Combine
import KeychainSwift
/// Keychain Swift Library for safe key storage
import SwiftUI

// MARK: - Key Manager Module

class KeyManager: ObservableObject {

  private static let storedKeysIndexKey = "keys"
  private static let selectedKeychainKey = "selectedKey"

  /// Data structure for key in keychain
  let objectWillChange = ObservableObjectPublisher()

  private(set) var storedKeys: [String] = []
  private(set) var selectedKey: String = ""
  private(set) var pendingKeypair: Keypair = generate_new_keypair()

  /// Initialize KeychainSwift instance
  private let keychain = KeychainSwift()

  init() {
    loadKeys()
  }

  /// Check if a String is a valid bech 32 encoded key
  func isValidBech32EncodedKey(_ key: String) -> Bool {
    normalizedKey(key) != nil
  }

  /// Delete all keys from keychain and update de list
  func deleteAllKeys() {
    for key in storedKeys {
      keychain.delete(key)
    }
    keychain.delete(Self.storedKeysIndexKey)
    keychain.delete(Self.selectedKeychainKey)

    objectWillChange.send()
    storedKeys = []
    selectedKey = ""
  }

  /// Delete a key from the keychain and the storedKeys published object array
  func deleteKey(_ key: String) {
    let updatedKeys = storedKeys.filter { $0 != key }
    let updatedSelectedKey = selectedKey == key ? updatedKeys.first ?? "" : selectedKey

    /// Remove the key from the keychain
    keychain.delete(key)
    /// Update the storedKeys array in the keychain
    persistStoredKeysIndex(updatedKeys)

    if updatedSelectedKey.isEmpty {
      keychain.delete(Self.selectedKeychainKey)
    } else {
      keychain.set(updatedSelectedKey, forKey: Self.selectedKeychainKey)
    }

    objectWillChange.send()
    storedKeys = updatedKeys
    selectedKey = updatedSelectedKey
  }

  /// Load stored keys
  func loadKeys() {
    let loadedKeys: [String]
    if let serializedKeys = keychain.get(Self.storedKeysIndexKey), !serializedKeys.isEmpty {
      loadedKeys = serializedKeys
        .split(separator: ",")
        .map(String.init)
        .filter { normalizedKey($0) != nil }
    } else {
      loadedKeys = keychain.allKeys
        .filter { $0 != Self.storedKeysIndexKey && $0 != Self.selectedKeychainKey }
        .filter { normalizedKey($0) != nil }
    }

    persistStoredKeysIndex(loadedKeys)

    let loadedSelectedKey: String
    if let selectedKey = keychain.get(Self.selectedKeychainKey),
      loadedKeys.contains(selectedKey)
    {
      loadedSelectedKey = selectedKey
    } else {
      loadedSelectedKey = loadedKeys.first ?? ""
      if loadedSelectedKey.isEmpty {
        keychain.delete(Self.selectedKeychainKey)
      } else {
        keychain.set(loadedSelectedKey, forKey: Self.selectedKeychainKey)
      }
    }

    objectWillChange.send()
    storedKeys = loadedKeys
    self.selectedKey = loadedSelectedKey
  }

  /// Store keys in keychain as a single string
  @discardableResult
  func saveKey(_ key: String) -> Bool {
    /// Delete empty spaces, and lowercase the string
    guard let newKey = normalizedKey(key) else {
      print("Invalid key")
      return false
    }

    var updatedKeys = storedKeys

    /// Check to avoid duplication
    if !updatedKeys.contains(where: { $0 == newKey }) {
      /// Append new key to the keys array
      updatedKeys.append(newKey)
      /// Saves the new key as a value under its own keychain key
      keychain.set(newKey, forKey: newKey)
    } else {
      /// Duplicated public key
      print("Key already exist")
    }

    persistStoredKeysIndex(updatedKeys)
    keychain.set(newKey, forKey: Self.selectedKeychainKey)

    objectWillChange.send()
    storedKeys = updatedKeys
    selectedKey = newKey
    return true
  }

  func selectKey(_ key: String) {
    guard !key.isEmpty else {
      keychain.delete(Self.selectedKeychainKey)
      objectWillChange.send()
      selectedKey = ""
      return
    }

    guard storedKeys.contains(key) else { return }
    keychain.set(key, forKey: Self.selectedKeychainKey)
    objectWillChange.send()
    selectedKey = key
  }

  func normalizedKey(_ key: String) -> String? {
    let normalized = key
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()
      .lowercased()
    guard normalized.count == 63, let decoded = decode_bech32_key(normalized) else {
      return nil
    }

    if case .sec(let privKeyHex) = decoded,
      privkey_to_pubkey(privkey: privKeyHex) == nil
    {
      return nil
    }

    return normalized
  }

  func isStored(_ key: String) -> Bool {
    guard let normalized = normalizedKey(key) else { return false }
    return storedKeys.contains(normalized)
  }

  func privateKeyHex(for key: String) -> String? {
    guard let normalized = normalizedKey(key),
      let decoded = decode_bech32_key(normalized)
    else {
      return nil
    }

    if case .sec(let privateKeyHex) = decoded {
      return privateKeyHex
    }

    return nil
  }

  var selectedPrivateKeyHex: String? {
    privateKeyHex(for: selectedKey)
  }

  func publicKeyHex(for key: String) -> String? {
    PublicKeyIdentity.publicKeyHex(from: key)
  }

  func regeneratePendingKeypair() {
    objectWillChange.send()
    pendingKeypair = generate_new_keypair()
  }

  var pendingPublicKey: String {
    pendingKeypair.pubkey_bech32
  }

  func publicKey(for key: String) -> String? {
    guard let publicKeyHex = publicKeyHex(for: key) else { return nil }
    return bech32_pubkey(publicKeyHex) ?? publicKeyHex
  }

  func keyKindDescription(for key: String) -> String {
    guard let normalized = normalizedKey(key),
      let decoded = decode_bech32_key(normalized)
    else {
      return "Invalid key"
    }

    switch decoded {
    case .pub:
      return "Public Key"
    case .sec:
      return "Private Key"
    }
  }

  private func persistStoredKeysIndex(_ keys: [String]? = nil) {
    keychain.set((keys ?? storedKeys).joined(separator: ","), forKey: Self.storedKeysIndexKey)
  }
}
