// a

import Foundation
import NostrKit
import SwiftData

@Model
class RFollowNotification {
  @Attribute(.unique) var eventId: String
  var followerPublicKey: String
  var targetPublicKey: String
  var createdAt: Date
  var followerProfile: RUserProfile?

  init(
    eventId: String,
    followerPublicKey: String,
    targetPublicKey: String,
    createdAt: Date,
    followerProfile: RUserProfile? = nil
  ) {
    self.eventId = eventId
    self.followerPublicKey = followerPublicKey
    self.targetPublicKey = targetPublicKey
    self.createdAt = createdAt
    self.followerProfile = followerProfile
  }
}

extension RFollowNotification {
  static func create(with event: Event, targetPublicKey: String) -> RFollowNotification {
    RFollowNotification(
      eventId: event.id,
      followerPublicKey: event.publicKey,
      targetPublicKey: targetPublicKey,
      createdAt: Date(timeIntervalSince1970: Double(event.createdAt.timestamp))
    )
  }
}
