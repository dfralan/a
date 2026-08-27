// a

import Foundation
import NostrKit
import SwiftData

@Model
class RUserProfile {
  @Attribute(.unique) var publicKey: String
  var name: String
  var about: String
  var picture: String
  var createdAt: Date
  var nip05: String
  var nip05VerificationStatusRaw: String
  var nip05LastCheckedAt: Date?
  var nip05VerificationURLString: String
  
  init(
    publicKey: String,
    name: String = "",
    about: String = "",
    picture: String = "",
    createdAt: Date = Date(),
    nip05: String = "",
    nip05VerificationStatusRaw: String = NIP05VerificationStatus.unchecked.rawValue,
    nip05LastCheckedAt: Date? = nil,
    nip05VerificationURLString: String = ""
  ) {
    self.publicKey = publicKey
    self.name = name
    self.about = about
    self.picture = picture
    self.createdAt = createdAt
    self.nip05 = nip05
    self.nip05VerificationStatusRaw = nip05VerificationStatusRaw
    self.nip05LastCheckedAt = nip05LastCheckedAt
    self.nip05VerificationURLString = nip05VerificationURLString
  }

  var avatarUrl: URL? {
    let trimmedPicture = picture.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPicture.isEmpty, let url = URL(string: trimmedPicture) else {
      return nil
    }

    if url.scheme == nil && !trimmedPicture.hasPrefix("data:") {
      return nil
    }

    return url
  }

  var nip05VerificationStatus: NIP05VerificationStatus {
    get {
      NIP05VerificationStatus(rawValue: nip05VerificationStatusRaw) ?? .unchecked
    }
    set {
      nip05VerificationStatusRaw = newValue.rawValue
    }
  }

  var parsedNIP05: NIP05? {
    NIP05.parse(nip05)
  }

  var verifiedNIP05: NIP05? {
    guard nip05VerificationStatus == .verified else { return nil }
    return parsedNIP05
  }

  var nip05VerificationURL: URL? {
    URL(string: nip05VerificationURLString)
  }

  var nip05DisplayIdentifier: String? {
    parsedNIP05?.displayIdentifier
  }

  func resetNIP05Verification() {
    nip05VerificationStatus = .unchecked
    nip05LastCheckedAt = nil
    nip05VerificationURLString = ""
  }

  var aboutFormatted: AttributedString? {
    if !about.isEmpty {
      return try? AttributedString(
        markdown: about,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }
    return nil
  }
}

extension RUserProfile {

  static func create(with event: Event) -> RUserProfile? {
    do {
      let decoder = JSONDecoder()
      let eventData = try decoder.decode(
        NostrRelay.SetMetaDataEventData.self, from: Data(event.content.utf8))
      return RUserProfile(
        publicKey: event.publicKey,
        name: eventData.preferredName,
        about: eventData.about ?? "",
        picture: eventData.picture ?? "",
        createdAt: Date(timeIntervalSince1970: Double(event.createdAt.timestamp)),
        nip05: eventData.normalizedNIP05
      )
    } catch {
      print(error)
      return nil
    }
  }

  static func createEmpty(withPublicKey publicKey: String) -> RUserProfile {
    return RUserProfile(publicKey: publicKey, createdAt: .distantPast)
  }

  static let preview = RUserProfile(
    publicKey: "2a765be8bf9f74e1e642856cf08370871070ae228fb14fc640990a8bf22ba8c4",
    name: "Fer",
    about: "Flawless 🥷",
    picture: "",
    createdAt: Date()
  )
}
