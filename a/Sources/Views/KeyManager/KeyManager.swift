// a

import KeychainSwift
/// Keychain Swift Library for safe key storage
import SwiftUI

// MARK: - Key Manager Module

class KeyManager: ObservableObject {

  /// Data structure for key in keychain
  @Published var storedKeys: [String] = []
  @Published var selectedKey: String = ""

  /// Initialize KeychainSwift instance
  private let keychain = KeychainSwift()

  /// Check if a String is a valid bech 32 encoded key
  func isValidBech32EncodedKey(_ key: String) -> Bool {
    let keyTrimmed = key.replacingOccurrences(of: " ", with: "").lowercased()
    /// Delete blank spaces and lowercase the string before decoding
    if decode_bech32_key(keyTrimmed) != nil {
      return true
    } else {
      return false
    }
  }

  /// Delete all keys from keychain and update de list
  func deleteAllKeys() {
    storedKeys.removeAll()
    keychain.clear()
  }

  /// Delete a key from the keychain and the storedKeys published object array
  func deleteKey(_ key: String) {
    /// Remove the key from the storedKeys array
    if let index = storedKeys.firstIndex(of: key) {
      storedKeys.remove(at: index)
    }
    /// Remove the key from the keychain
    keychain.delete(key)
    /// Update the storedKeys array in the keychain
    keychain.set(storedKeys.map { $0 }.joined(separator: ","), forKey: "keys")
  }

  /// Load stored keys
  func loadKeys() {
    let keys = keychain.allKeys.filter { $0 != "keys" }
    storedKeys = keys
  }

  /// Store keys in keychain as a single string
  func saveKey(_ key: String) {
    /// Delete empty spaces, and lowercase the string
    let newKey = key.replacingOccurrences(of: " ", with: "").lowercased()
    /// Check if lenght is valid
    if newKey.count == 63 {
      /// Decode key to trim in npub or nsec case
      if let decoded = decode_bech32_key(newKey) {
        if case .sec(let privKeyHex) = decoded {
          /// Decoding private key bech32 to hex
          let publicKeyHex = privkey_to_pubkey(privkey: privKeyHex)
          /// Building a full keypair from decoded private key
          let keypair = Keypair(pubkey: publicKeyHex!, privkey: privKeyHex)
          /// Declaring string data
          let publicKey = keypair.pubkey_bech32
          let privateKey = keypair.privkey_bech32!
        }
        /// Check to avoid duplication
        if !storedKeys.contains(where: { $0 == newKey }) {
          /// Append new key to the keys array
          storedKeys.append(newKey)
          /// Saves new key as a string in the keychain under the key "keys"
          keychain.set(true, forKey: newKey)
          /// Saves the list of publicKeys in the keys array as a comma-separated string in the keychain under the key "keys"
          keychain.set(storedKeys.map { $0 }.joined(separator: ","), forKey: "keys")
          loadKeys()
        } else {
          /// Duplicated public key
          print("Key already exist")
          return
        }

      } else {
        /// Handle invalid key
        print("Invalid key")
        return
      }
    } else {
      return
    }
  }
}
