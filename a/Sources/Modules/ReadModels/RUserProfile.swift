// a

import Foundation
import NostrKit
import RealmSwift

class RUserProfile: Object, ObjectKeyIdentifiable {
  @Persisted(primaryKey: true) var publicKey: String
  @Persisted var name: String
  @Persisted var about: String
  @Persisted var picture: String
  @Persisted var createdAt: Date

  var avatarUrl: URL? {
    if picture.isEmpty {
      return URL(string: publicKey)
    }
    return URL(string: picture)
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
      return RUserProfile(value: [
        "publicKey": event.publicKey,
        "name": eventData.name ?? "",
        "about": eventData.about ?? "",
        "picture": eventData.picture ?? "",
        "createdAt": Date(timeIntervalSince1970: Double(event.createdAt.timestamp)),
      ])
    } catch {
      print(error)
      return nil
    }
  }

  static func createEmpty(withPublicKey publicKey: String) -> RUserProfile {
    return RUserProfile(value: ["publicKey": publicKey])
  }

  static let preview = RUserProfile(value: [
    "publicKey": "2a765be8bf9f74e1e642856cf08370871070ae228fb14fc640990a8bf22ba8c4",
    "name": "Fer",
    "about": "Flawless 🥷",
    "picture": "",
    "createdAt": Date(),
  ])
}
