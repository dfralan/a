// a

import Foundation
import NostrKit
import SwiftData

enum ActivityKind: String, Hashable, Sendable {
  case reaction
  case follow
  case reply
  case mention
}

enum ActivityRoute: Hashable, Sendable {
  case profile(publicKey: String)
  case event(reference: NostrEventReference)
}

struct ActivityScope: Hashable, Sendable {
  let publicKey: String
  let kinds: Set<ActivityKind>

  var includesReactions: Bool {
    kinds.contains(.reaction)
  }

  var includesFollows: Bool {
    kinds.contains(.follow)
  }

  var includesReplies: Bool {
    kinds.contains(.reply)
  }

  var includesMentions: Bool {
    kinds.contains(.mention)
  }

  var includesThreadActivity: Bool {
    includesReplies || includesMentions
  }

  func includes(_ kind: ActivityKind) -> Bool {
    kinds.contains(kind)
  }

  func matches(_ item: ActivityItem, ownEventIDs: Set<String> = []) -> Bool {
    guard includes(item.kind) else { return false }

    switch item.kind {
    case .reaction:
      return item.targetPublicKey == publicKey
        || ownEventIDs.contains(item.relatedEventID ?? "")
    case .follow:
      return item.targetPublicKey == publicKey
    case .reply, .mention:
      return item.targetPublicKey == publicKey
    }
  }
}

struct ActivityCursor: Hashable, Sendable {
  let until: Int64

  init(until: Int64) {
    self.until = until
  }

  init(date: Date) {
    self.until = Int64(date.timeIntervalSince1970)
  }

  var date: Date {
    Date(timeIntervalSince1970: Double(until))
  }
}

struct ActivityPage<Item: Sendable>: Sendable {
  let items: [Item]
  let cursor: ActivityCursor?
  let exhausted: Bool
}

struct ActivityItem: Identifiable, Hashable, Sendable {
  let id: String
  let kind: ActivityKind
  let actorPublicKey: String
  let targetPublicKey: String
  let actorName: String
  let actorPicture: String
  let createdAt: Date
  let context: String
  let detail: String?
  let relatedEventID: String?
  let relatedEventKind: Int?
  let route: ActivityRoute

  var createdAtTimestamp: Int64 {
    Int64(createdAt.timeIntervalSince1970)
  }

  init(
    id: String,
    kind: ActivityKind,
    actorPublicKey: String,
    targetPublicKey: String,
    actorProfile: RUserProfile?,
    createdAt: Date,
    context: String,
    detail: String?,
    relatedEventID: String?,
    relatedEventKind: Int?,
    route: ActivityRoute
  ) {
    self.id = id
    self.kind = kind
    self.actorPublicKey = actorPublicKey
    self.targetPublicKey = targetPublicKey
    self.actorName = actorProfile?.name ?? ""
    self.actorPicture = actorProfile?.picture ?? ""
    self.createdAt = createdAt
    self.context = context
    self.detail = detail
    self.relatedEventID = relatedEventID
    self.relatedEventKind = relatedEventKind
    self.route = route
  }

  init(reaction: RReaction, actorProfile: RUserProfile? = nil, targetPublicKey: String? = nil) {
    self.init(
      id: "reaction:\(reaction.eventId)",
      kind: .reaction,
      actorPublicKey: reaction.reactorPublicKey,
      targetPublicKey: targetPublicKey ?? reaction.targetPublicKey,
      actorProfile: actorProfile,
      createdAt: reaction.createdAt,
      context: reaction.isLike ? "liked your post" : "reacted to your post",
      detail: reaction.isLike ? nil : reaction.content,
      relatedEventID: reaction.reactedEventId,
      relatedEventKind: nil,
      route: .event(reference: NostrEventReference(id: reaction.reactedEventId))
    )
  }

  init(
    followNotification: RFollowNotification,
    actorProfile: RUserProfile? = nil
  ) {
    self.init(
      id: "follow:\(followNotification.eventId)",
      kind: .follow,
      actorPublicKey: followNotification.followerPublicKey,
      targetPublicKey: followNotification.targetPublicKey,
      actorProfile: actorProfile ?? followNotification.followerProfile,
      createdAt: followNotification.createdAt,
      context: "started following you",
      detail: nil,
      relatedEventID: nil,
      relatedEventKind: nil,
      route: .profile(publicKey: followNotification.followerPublicKey)
    )
  }

  init?(
    threadItem: ThreadItem,
    targetPublicKey: String,
    actorProfile: RUserProfile? = nil
  ) {
    guard threadItem.publicKey != targetPublicKey,
      let activityKind = Self.threadActivityKind(
        for: threadItem,
        targetPublicKey: targetPublicKey
      )
    else {
      return nil
    }

    self.init(
      id: "\(activityKind.rawValue):\(threadItem.id)",
      kind: activityKind,
      actorPublicKey: threadItem.publicKey,
      targetPublicKey: targetPublicKey,
      actorProfile: actorProfile,
      createdAt: threadItem.createdAt,
      context: activityKind == .mention ? "mentioned you" : "replied to you",
      detail: threadItem.content,
      relatedEventID: threadItem.id,
      relatedEventKind: threadItem.kind,
      route: .event(
        reference: NostrEventReference(
          id: threadItem.id,
          relayHints: threadItem.reference.relayHints,
          kind: threadItem.kind,
          publicKey: threadItem.publicKey
        )
      )
    )
  }

  init?(event: Event, targetPublicKey: String, actorProfile: RUserProfile? = nil) {
    switch event.kind {
    case .custom(let kind) where kind == 7:
      guard let reaction = RReaction.create(with: event) else { return nil }
      self.init(
        reaction: reaction,
        actorProfile: actorProfile,
        targetPublicKey: targetPublicKey
      )
    case .custom(let kind) where kind == 3:
      guard event.tags.contains(where: {
        $0.id == "p" && $0.otherInformation.first == targetPublicKey
      }) else {
        return nil
      }

      let notification = RFollowNotification.create(with: event, targetPublicKey: targetPublicKey)
      self.init(followNotification: notification, actorProfile: actorProfile)
    case .textNote, .custom(1111):
      guard let threadItem = ThreadItem(event: event) else { return nil }
      self.init(
        threadItem: threadItem,
        targetPublicKey: targetPublicKey,
        actorProfile: actorProfile
      )
    default:
      return nil
    }
  }

  func enriched(with profile: RUserProfile?) -> ActivityItem {
    ActivityItem(
      id: id,
      kind: kind,
      actorPublicKey: actorPublicKey,
      targetPublicKey: targetPublicKey,
      actorProfile: profile,
      createdAt: createdAt,
      context: context,
      detail: detail,
      relatedEventID: relatedEventID,
      relatedEventKind: relatedEventKind,
      route: route
    )
  }

  private static func threadActivityKind(
    for item: ThreadItem,
    targetPublicKey: String
  ) -> ActivityKind? {
    if NIP27.profileMentionPublicKeys(in: item.content).contains(targetPublicKey) {
      return .mention
    }

    guard item.parent != nil else { return nil }

    if item.parent?.publicKey == targetPublicKey {
      return .reply
    }

    let directlyTaggedPublicKeys = Set(
      item.tags
        .filter { $0.id == "p" }
        .compactMap { $0.values.first }
        .filter { !$0.isEmpty }
    )
    return directlyTaggedPublicKeys == [targetPublicKey] ? .reply : nil
  }
}

@Model
class RReaction {
  @Attribute(.unique) var eventId: String
  var reactedEventId: String
  var reactorPublicKey: String
  var targetPublicKey: String
  var content: String
  var createdAt: Date

  init(
    eventId: String,
    reactedEventId: String,
    reactorPublicKey: String,
    targetPublicKey: String,
    content: String,
    createdAt: Date
  ) {
    self.eventId = eventId
    self.reactedEventId = reactedEventId
    self.reactorPublicKey = reactorPublicKey
    self.targetPublicKey = targetPublicKey
    self.content = content
    self.createdAt = createdAt
  }

  var isLike: Bool {
    content == "+" || content == "\u{2764}" || content == "\u{2764}\u{FE0F}"
  }
}

extension RReaction {
  static func create(with event: Event) -> RReaction? {
    guard let reactedEventId = event.tags
      .first(where: { $0.id == "e" })?
      .otherInformation
      .first
    else {
      return nil
    }

    let targetPublicKey = event.tags
      .first(where: { $0.id == "p" })?
      .otherInformation
      .first ?? ""

    return RReaction(
      eventId: event.id,
      reactedEventId: reactedEventId,
      reactorPublicKey: event.publicKey,
      targetPublicKey: targetPublicKey,
      content: event.content,
      createdAt: Date(timeIntervalSince1970: Double(event.createdAt.timestamp))
    )
  }
}
