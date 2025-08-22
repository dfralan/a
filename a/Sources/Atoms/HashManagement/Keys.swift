//  a
//  Modified by Alan D on 04/05/2023.
//  Created by William Casarin on 2022-05-21.

/*
 nsec1c6ccyshx0etgyzgxe29d0q08r6e0rg5epfdgj2et4sl5mt3k9p8s63na24(63)privHex
 c6b18242e67e56820906ca8ad781e71eb2f1a2990a5a892b2bac3f4dae36284f(64)privBech

 npub19fm9h69lna6wrejzs4k0pqmssug8pt3z37c5l3jqny9ghu3t4rzq7l3fwq(63)pubKey
 2a765be8bf9f74e1e642856cf08370871070ae228fb14fc640990a8bf22ba8c4
 */

import Foundation
import secp256k1

let PUBKEY_HRP = "npub"
let PRIVKEY_HRP = "nsec"

struct FullKeypair {
  let pubkey: String
  let privkey: String
}

struct Keypair {
  let pubkey: String
  let privkey: String?
  let pubkey_bech32: String
  let privkey_bech32: String?

  func to_full() -> FullKeypair? {
    guard let privkey = self.privkey else {
      return nil
    }

    return FullKeypair(pubkey: pubkey, privkey: privkey)
  }

  init(pubkey: String, privkey: String?) {
    self.pubkey = pubkey
    self.privkey = privkey
    self.pubkey_bech32 = bech32_pubkey(pubkey) ?? pubkey
    self.privkey_bech32 = privkey.flatMap { bech32_privkey($0) }
  }
}

enum Bech32Key {
  case pub(String)
  case sec(String)
}

func generate_new_keypair() -> Keypair {
  let key = try! secp256k1.Signing.PrivateKey()
  let privkey = hex_encode(key.rawRepresentation)
  let pubkey = hex_encode(Data(key.publicKey.xonly.bytes))
  return Keypair(pubkey: pubkey, privkey: privkey)
}

func decode_bech32_key(_ key: String) -> Bech32Key? {
  guard let decoded = try? bech32_decode(key) else {
    return nil
  }

  let hexed = hex_encode(decoded.data)
  if decoded.hrp == "npub" {
    return .pub(hexed)
  } else if decoded.hrp == "nsec" {
    return .sec(hexed)
  }
  return nil
}

func hexchar(_ val: UInt8) -> UInt8 {
  if val < 10 {
    return 48 + val
  }
  if val < 16 {
    return 97 + val - 10
  }
  assertionFailure("impossiburu")
  return 0
}

func hex_encode(_ data: Data) -> String {
  var str = ""
  for c in data {
    let c1 = hexchar(c >> 4)
    let c2 = hexchar(c & 0xF)

    str.append(Character(Unicode.Scalar(c1)))
    str.append(Character(Unicode.Scalar(c2)))
  }
  return str
}

func bech32_privkey(_ privkey: String) -> String? {
  guard let bytes = hex_decode(privkey) else {
    return nil
  }
  return bech32_encode(hrp: "nsec", bytes)
}

func bech32_pubkey(_ pubkey: String) -> String? {
  guard let bytes = hex_decode(pubkey) else {
    return nil
  }
  return bech32_encode(hrp: "npub", bytes)
}

func bech32_nopre_pubkey(_ pubkey: String) -> String? {
  guard let bytes = hex_decode(pubkey) else {
    return nil
  }
  return bech32_encode(hrp: "", bytes)
}

func privkey_to_pubkey(privkey: String) -> String? {
  guard let sec = hex_decode(privkey) else {
    return nil
  }
  guard let key = try? secp256k1.Signing.PrivateKey(rawRepresentation: sec) else {
    return nil
  }
  return hex_encode(Data(key.publicKey.xonly.bytes))
}
