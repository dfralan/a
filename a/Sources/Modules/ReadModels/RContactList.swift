// a

import Foundation
import RealmSwift

class RContactList: Object, ObjectKeyIdentifiable {
  @Persisted(primaryKey: true) var publicKey: String
  @Persisted var following: List<RUserProfile>
  @Persisted var followedBy: List<RUserProfile>
}

extension RContactList {

  static func createEmpty(withPublicKey publicKey: String) -> RContactList {
    return RContactList(value: ["publicKey": publicKey])
  }

  static let preview = RContactList(value: [
    "publicKey": "lasdfjenandlfieasdnf",
    "following": [RUserProfile.preview],
    "followedBy": [RUserProfile.preview],
  ])

}
