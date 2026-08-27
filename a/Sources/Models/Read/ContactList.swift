// a

import Foundation
import SwiftData

@Model
class RContactList {
  @Attribute(.unique) var publicKey: String
  var following: [RUserProfile]
  var followedBy: [RUserProfile]
  var followingCount: Int = 0
  var followedByCount: Int = 0
  
  init(
    publicKey: String,
    following: [RUserProfile] = [],
    followedBy: [RUserProfile] = [],
    followingCount: Int? = nil,
    followedByCount: Int? = nil
  ) {
    self.publicKey = publicKey
    self.following = following
    self.followedBy = followedBy
    self.followingCount = followingCount ?? following.count
    self.followedByCount = followedByCount ?? followedBy.count
  }

  var visibleFollowingCount: Int {
    max(followingCount, following.count)
  }

  var visibleFollowedByCount: Int {
    max(followedByCount, followedBy.count)
  }
}

@Model
class VerseWatcher {
  @Attribute(.unique) var id: String
  var ownerPublicKey: String
  var title: String
  var termsText: String
  var isEnabled: Bool
  var createdAt: Date
  var updatedAt: Date

  init(
    id: String = UUID().uuidString,
    ownerPublicKey: String,
    title: String = "My Verse",
    termsText: String = "",
    isEnabled: Bool = true,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.ownerPublicKey = ownerPublicKey
    self.title = title
    self.termsText = termsText
    self.isEnabled = isEnabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  var terms: [String] {
    Self.parseTerms(termsText)
  }

  var publicKeys: [String] {
    terms.compactMap(Self.normalizedPublicKey)
  }

  var hashtags: [String] {
    terms
      .filter { $0.hasPrefix("#") }
      .map { String($0.drop(while: { $0 == "#" })) }
      .filter { !$0.isEmpty }
      .uniqued()
  }

  var summaryText: String {
    let users = publicKeys
      .prefix(2)
      .map { bech32_pubkey($0)?.accordionString(index: 8) ?? $0.accordionString(index: 8) }
    let tags = hashtags.prefix(3).map { "#\($0)" }
    let summary = (users + tags).joined(separator: " ")
    return summary.isEmpty ? "No filters" : summary
  }

  static func defaultID(forPublicKey publicKey: String) -> String {
    "default:\(publicKey)"
  }

  static func parseTerms(_ rawTerms: String) -> [String] {
    rawTerms
      .components(separatedBy: CharacterSet(charactersIn: ",\n "))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
      .uniqued()
  }

  static func normalizedPublicKey(_ rawTerm: String) -> String? {
    let token = rawTerm
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
      .lowercased()

    if case .pub(let publicKeyHex) = decode_bech32_key(token) {
      return publicKeyHex
    }

    guard token.count == 64,
      token.allSatisfy({ $0.isHexDigit }),
      hex_decode(token) != nil
    else {
      return nil
    }

    return token
  }
}

private extension Array where Element: Hashable {
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}

extension RContactList {

  static func createEmpty(withPublicKey publicKey: String) -> RContactList {
    return RContactList(publicKey: publicKey)
  }

  static let preview = RContactList(
    publicKey: "lasdfjenandlfieasdnf",
    following: [RUserProfile.preview],
    followedBy: [RUserProfile.preview]
  )
}
