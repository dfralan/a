// a

import Foundation
import Combine
import SwiftData

struct DirectMessageCursor: Hashable, Sendable {
  let before: Date
}

struct DirectMessagePage<Item: Sendable>: Sendable {
  let items: [Item]
  let cursor: DirectMessageCursor?
  let exhausted: Bool
}

struct DirectMessageItem: Identifiable, Hashable, Sendable {
  let id: String
  let rumorId: String
  let conversationID: String
  let peerPublicKey: String
  let senderPublicKey: String
  let recipientPublicKey: String
  let content: String
  let createdAt: Date
  let isFromCurrentUser: Bool
  let deliveryState: String
  let errorMessage: String?
  let wrapEventIds: [String]
  let protocolKind: String

  init(
    id: String,
    rumorId: String,
    conversationID: String,
    peerPublicKey: String,
    senderPublicKey: String,
    recipientPublicKey: String,
    content: String,
    createdAt: Date,
    isFromCurrentUser: Bool,
    deliveryState: String,
    errorMessage: String?,
    wrapEventIds: [String],
    protocolKind: String
  ) {
    self.id = id
    self.rumorId = rumorId
    self.conversationID = conversationID
    self.peerPublicKey = peerPublicKey
    self.senderPublicKey = senderPublicKey
    self.recipientPublicKey = recipientPublicKey
    self.content = content
    self.createdAt = createdAt
    self.isFromCurrentUser = isFromCurrentUser
    self.deliveryState = deliveryState
    self.errorMessage = errorMessage
    self.wrapEventIds = wrapEventIds
    self.protocolKind = protocolKind
  }

  init?(directMessage: RDirectMessage, activePublicKey: String) {
    guard let peerPublicKey = directMessage.peerPublicKey(for: activePublicKey) else {
      return nil
    }

    self.init(
      id: directMessage.id,
      rumorId: directMessage.rumorId,
      conversationID: directMessage.conversationID,
      peerPublicKey: peerPublicKey,
      senderPublicKey: directMessage.senderPublicKey,
      recipientPublicKey: directMessage.recipientPublicKey,
      content: directMessage.content,
      createdAt: directMessage.createdAt,
      isFromCurrentUser: directMessage.senderPublicKey == activePublicKey,
      deliveryState: directMessage.deliveryState,
      errorMessage: directMessage.errorMessage,
      wrapEventIds: directMessage.wrapEventIds,
      protocolKind: directMessage.protocolKind
    )
  }

  var dedupeKey: String {
    rumorId.isEmpty ? id : rumorId
  }
}

struct DirectConversationItem: Identifiable, Hashable, Sendable {
  var id: String { peerPublicKey }
  let peerPublicKey: String
  let lastMessage: String
  let lastDate: Date
  let deliveryState: String
  let errorMessage: String?
}

enum DirectMessageRepository {
  static func fetchConversationPage(
    activePublicKey: String,
    peerPublicKey: String,
    cursor: DirectMessageCursor?,
    limit: Int,
    modelContainer: ModelContainer
  ) -> DirectMessagePage<DirectMessageItem> {
    let context = ModelContext(modelContainer)
    let conversationID = RDirectMessage.conversationID(activePublicKey, peerPublicKey)
    let fetchLimit = max(1, limit)

    let messages: [RDirectMessage]
    if let cursor {
      let cutoff = cursor.before
      var descriptor = FetchDescriptor<RDirectMessage>(
        predicate: #Predicate {
          $0.conversationID == conversationID && $0.createdAt < cutoff
        },
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      descriptor.fetchLimit = fetchLimit
      messages = (try? context.fetch(descriptor)) ?? []
    } else {
      var descriptor = FetchDescriptor<RDirectMessage>(
        predicate: #Predicate { $0.conversationID == conversationID },
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      descriptor.fetchLimit = fetchLimit
      messages = (try? context.fetch(descriptor)) ?? []
    }

    let items = orderedUnique(
      messages.compactMap {
        DirectMessageItem(directMessage: $0, activePublicKey: activePublicKey)
      }
    )
    let nextCursor = items.first.map { DirectMessageCursor(before: $0.createdAt) }

    return DirectMessagePage(
      items: items,
      cursor: nextCursor,
      exhausted: messages.count < fetchLimit
    )
  }

  static func fetchConversationSummaries(
    activePublicKey: String,
    limit: Int,
    modelContainer: ModelContainer
  ) -> [DirectConversationItem] {
    let context = ModelContext(modelContainer)
    var descriptor = FetchDescriptor<RDirectMessage>(
      predicate: #Predicate {
        $0.senderPublicKey == activePublicKey || $0.recipientPublicKey == activePublicKey
      },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = max(1, limit)

    let messages = (try? context.fetch(descriptor)) ?? []
    var latestByPeer: [String: DirectMessageItem] = [:]

    for message in messages {
      guard let item = DirectMessageItem(directMessage: message, activePublicKey: activePublicKey) else {
        continue
      }

      if let existing = latestByPeer[item.peerPublicKey] {
        if item.createdAt > existing.createdAt {
          latestByPeer[item.peerPublicKey] = item
        }
      } else {
        latestByPeer[item.peerPublicKey] = item
      }
    }

    return latestByPeer.values
      .map {
        DirectConversationItem(
          peerPublicKey: $0.peerPublicKey,
          lastMessage: $0.content,
          lastDate: $0.createdAt,
          deliveryState: $0.deliveryState,
          errorMessage: $0.errorMessage
        )
      }
      .sorted { $0.lastDate > $1.lastDate }
  }

  private static func orderedUnique(_ items: [DirectMessageItem]) -> [DirectMessageItem] {
    var seen = Set<String>()
    return items
      .sorted {
        if $0.createdAt == $1.createdAt {
          return $0.id < $1.id
        }

        return $0.createdAt < $1.createdAt
      }
      .filter { seen.insert($0.dedupeKey).inserted }
  }
}

@MainActor
final class DirectConversationController: ObservableObject {
  @Published private(set) var visibleItems: [DirectMessageItem] = []
  @Published private(set) var isLoadingOlder = false
  @Published private(set) var hasReachedOlderEnd = false

  private var modelContainer: ModelContainer?
  private var activePublicKey: String?
  private var peerPublicKey: String?
  private var cursor: DirectMessageCursor?
  private var visibleKeys = Set<String>()

  private let initialPageSize = 50
  private let pageSize = 50

  var canLoadOlder: Bool {
    !hasReachedOlderEnd && !visibleItems.isEmpty
  }

  func configure(
    modelContainer: ModelContainer,
    activePublicKey: String,
    peerPublicKey: String
  ) {
    let scopeChanged = self.activePublicKey != activePublicKey || self.peerPublicKey != peerPublicKey
    self.modelContainer = modelContainer
    self.activePublicKey = activePublicKey
    self.peerPublicKey = peerPublicKey

    if scopeChanged {
      resetKeepingScope()
    }

    if visibleItems.isEmpty {
      bootstrap()
    }
  }

  func reset() {
    modelContainer = nil
    activePublicKey = nil
    peerPublicKey = nil
    resetKeepingScope()
  }

  func bootstrap() {
    guard let modelContainer,
      let activePublicKey,
      let peerPublicKey
    else {
      return
    }

    let page = DirectMessageRepository.fetchConversationPage(
      activePublicKey: activePublicKey,
      peerPublicKey: peerPublicKey,
      cursor: nil,
      limit: initialPageSize,
      modelContainer: modelContainer
    )
    replace(with: page)
  }

  func refreshFromCache() {
    guard let modelContainer,
      let activePublicKey,
      let peerPublicKey
    else {
      return
    }

    let refreshLimit = max(initialPageSize, visibleItems.count + 12)
    let page = DirectMessageRepository.fetchConversationPage(
      activePublicKey: activePublicKey,
      peerPublicKey: peerPublicKey,
      cursor: nil,
      limit: refreshLimit,
      modelContainer: modelContainer
    )
    replace(with: page)
  }

  func loadOlder() {
    guard !isLoadingOlder,
      !hasReachedOlderEnd,
      let modelContainer,
      let activePublicKey,
      let peerPublicKey,
      let cursor
    else {
      return
    }

    isLoadingOlder = true
    let page = DirectMessageRepository.fetchConversationPage(
      activePublicKey: activePublicKey,
      peerPublicKey: peerPublicKey,
      cursor: cursor,
      limit: pageSize,
      modelContainer: modelContainer
    )
    prepend(page.items)
    self.cursor = page.cursor
    hasReachedOlderEnd = page.exhausted
    isLoadingOlder = false
  }

  private func replace(with page: DirectMessagePage<DirectMessageItem>) {
    visibleItems = page.items
    visibleKeys = Set(page.items.map(\.dedupeKey))
    cursor = page.cursor
    hasReachedOlderEnd = page.exhausted
    isLoadingOlder = false
  }

  private func prepend(_ items: [DirectMessageItem]) {
    let newItems = items.filter { visibleKeys.insert($0.dedupeKey).inserted }
    visibleItems = (newItems + visibleItems).sorted {
      if $0.createdAt == $1.createdAt {
        return $0.id < $1.id
      }

      return $0.createdAt < $1.createdAt
    }
  }

  private func resetKeepingScope() {
    visibleItems.removeAll()
    visibleKeys.removeAll()
    cursor = nil
    isLoadingOlder = false
    hasReachedOlderEnd = false
  }
}

@MainActor
final class MessagingInboxController: ObservableObject {
  @Published private(set) var visibleConversations: [DirectConversationItem] = []

  private var modelContainer: ModelContainer?
  private var activePublicKey: String?
  private let fetchLimit = 800

  func configure(modelContainer: ModelContainer, activePublicKey: String) {
    let scopeChanged = self.activePublicKey != activePublicKey
    self.modelContainer = modelContainer
    self.activePublicKey = activePublicKey

    if scopeChanged {
      visibleConversations.removeAll()
    }

    refreshFromCache()
  }

  func reset() {
    modelContainer = nil
    activePublicKey = nil
    visibleConversations.removeAll()
  }

  func refreshFromCache() {
    guard let modelContainer,
      let activePublicKey
    else {
      return
    }

    visibleConversations = DirectMessageRepository.fetchConversationSummaries(
      activePublicKey: activePublicKey,
      limit: fetchLimit,
      modelContainer: modelContainer
    )
  }
}

@Model
class RDirectMessage {
  @Attribute(.unique) var id: String
  var rumorId: String = ""
  var conversationID: String
  var peerPubkey: String = ""
  var senderPublicKey: String
  var recipientPublicKey: String
  var content: String
  var createdAt: Date
  var isFromCurrentUser: Bool = false
  var deliveryState: String
  var errorMessage: String?
  var wrapEventIdsText: String = ""
  var protocolKind: String

  init(
    id: String,
    rumorId: String = "",
    conversationID: String,
    peerPubkey: String = "",
    senderPublicKey: String,
    recipientPublicKey: String,
    content: String,
    createdAt: Date,
    isFromCurrentUser: Bool = false,
    deliveryState: String = "sent",
    errorMessage: String? = nil,
    wrapEventIds: [String] = [],
    protocolKind: String = MessagingProtocolKind.nip17.rawValue
  ) {
    self.id = id
    self.rumorId = rumorId.isEmpty ? id : rumorId
    self.conversationID = conversationID
    self.peerPubkey = peerPubkey
    self.senderPublicKey = senderPublicKey
    self.recipientPublicKey = recipientPublicKey
    self.content = content
    self.createdAt = createdAt
    self.isFromCurrentUser = isFromCurrentUser
    self.deliveryState = deliveryState
    self.errorMessage = errorMessage
    self.wrapEventIdsText = Self.encodedWrapEventIds(wrapEventIds)
    self.protocolKind = protocolKind
  }

  var wrapEventIds: [String] {
    get {
      wrapEventIdsText
        .components(separatedBy: " ")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
    set {
      wrapEventIdsText = Self.encodedWrapEventIds(newValue)
    }
  }

  private static func encodedWrapEventIds(_ ids: [String]) -> String {
    var seen = Set<String>()
    return ids
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
      .joined(separator: " ")
  }

  static func conversationID(_ firstPublicKey: String, _ secondPublicKey: String) -> String {
    [firstPublicKey, secondPublicKey].sorted().joined(separator: ":")
  }

  func peerPublicKey(for activePublicKey: String) -> String? {
    if senderPublicKey == activePublicKey {
      return recipientPublicKey
    }

    if recipientPublicKey == activePublicKey {
      return senderPublicKey
    }

    guard conversationParticipants.contains(activePublicKey) else { return nil }

    if !peerPubkey.isEmpty, peerPubkey != activePublicKey {
      return peerPubkey
    }

    return conversationParticipants.first { $0 != activePublicKey }
  }

  private var conversationParticipants: [String] {
    conversationID.split(separator: ":").map(String.init)
  }
}
