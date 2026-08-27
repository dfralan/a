import Foundation
import NostrKit
import SwiftData

enum CommentProtocolKind: String, Codable, Hashable, Sendable {
  case nip10
  case nip22
}

enum ThreadReference: Hashable, Sendable {
  case event(
    id: String,
    kind: Int,
    publicKey: String?,
    relayHints: [String]
  )
  case address(
    coordinate: String,
    eventID: String?,
    kind: Int,
    publicKey: String?,
    relayHints: [String]
  )
  case external(
    identifier: String,
    kind: String,
    hints: [String]
  )

  var canonicalKey: String {
    switch self {
    case .event(let id, _, _, _):
      return "e:\(id)"
    case .address(let coordinate, _, _, _, _):
      return "a:\(coordinate)"
    case .external(let identifier, let kind, _):
      return "i:\(kind):\(identifier)"
    }
  }

  var eventID: String? {
    switch self {
    case .event(let id, _, _, _): return id
    case .address(_, let eventID, _, _, _): return eventID
    case .external: return nil
    }
  }

  var nostrKind: Int? {
    switch self {
    case .event(_, let kind, _, _), .address(_, _, let kind, _, _): return kind
    case .external: return nil
    }
  }

  var externalKind: String? {
    guard case .external(_, let kind, _) = self else { return nil }
    return kind
  }

  var publicKey: String? {
    switch self {
    case .event(_, _, let publicKey, _), .address(_, _, _, let publicKey, _):
      return publicKey
    case .external:
      return nil
    }
  }

  var relayHints: [String] {
    switch self {
    case .event(_, _, _, let relayHints), .address(_, _, _, _, let relayHints):
      return relayHints
    case .external(_, _, let hints):
      return hints
    }
  }

  var primaryRelayHint: String? {
    relayHints.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  var commentProtocol: CommentProtocolKind {
    nostrKind == 1 ? .nip10 : .nip22
  }

  var parentQueryTag: String {
    switch self {
    case .event: return "e"
    case .address: return "a"
    case .external: return "i"
    }
  }

  var parentQueryValue: String {
    switch self {
    case .event(let id, _, _, _): return id
    case .address(let coordinate, _, _, _, _): return coordinate
    case .external(let identifier, _, _): return identifier
    }
  }

}

extension NostrEventReference {
  var threadTarget: ThreadTarget {
    let reference = ThreadReference.event(
      id: id,
      kind: kind ?? 1,
      publicKey: publicKey,
      relayHints: relayHints
    )
    return ThreadTarget(focused: reference)
  }
}

struct ThreadTarget: Hashable, Sendable, Identifiable {
  let focused: ThreadReference
  let root: ThreadReference
  let commentProtocol: CommentProtocolKind
  let participantPublicKeys: Set<String>

  var id: String {
    "\(commentProtocol.rawValue):\(focused.canonicalKey):\(root.canonicalKey)"
  }

  init(
    focused: ThreadReference,
    root: ThreadReference? = nil,
    commentProtocol: CommentProtocolKind? = nil,
    participantPublicKeys: Set<String> = []
  ) {
    let resolvedRoot = root ?? focused
    self.focused = focused
    self.root = resolvedRoot
    self.commentProtocol = commentProtocol ?? resolvedRoot.commentProtocol
    self.participantPublicKeys = participantPublicKeys
  }

  init(item: ThreadItem) {
    self.init(
      focused: item.reference,
      root: item.root,
      commentProtocol: item.commentProtocol,
      participantPublicKeys: item.participantPublicKeys
    )
  }
}

struct ThreadCursor: Hashable, Sendable {
  let until: Int64

  var date: Date {
    Date(timeIntervalSince1970: TimeInterval(until))
  }
}

struct ThreadPage<Item: Sendable>: Sendable {
  let items: [Item]
  let cursor: ThreadCursor?
  let exhausted: Bool
}

struct ThreadItem: Identifiable, Hashable, Sendable {
  let id: String
  let reference: ThreadReference
  let root: ThreadReference
  let parent: ThreadReference?
  let commentProtocol: CommentProtocolKind
  let publicKey: String
  let kind: Int
  let createdAt: Date
  let content: String
  let tags: [NostrTag]
  let participantPublicKeys: Set<String>
  let isSensitiveContent: Bool
  let sensitiveContentReason: String
  let rawEventJSON: String?

  var target: ThreadTarget {
    ThreadTarget(item: self)
  }

  var isRoot: Bool {
    parent == nil
  }

  init(
    id: String,
    reference: ThreadReference,
    root: ThreadReference,
    parent: ThreadReference?,
    commentProtocol: CommentProtocolKind,
    publicKey: String,
    kind: Int,
    createdAt: Date,
    content: String,
    tags: [NostrTag],
    participantPublicKeys: Set<String>,
    isSensitiveContent: Bool,
    sensitiveContentReason: String,
    rawEventJSON: String?
  ) {
    self.id = id
    self.reference = reference
    self.root = root
    self.parent = parent
    self.commentProtocol = commentProtocol
    self.publicKey = publicKey
    self.kind = kind
    self.createdAt = createdAt
    self.content = content
    self.tags = tags
    self.participantPublicKeys = participantPublicKeys
    self.isSensitiveContent = isSensitiveContent
    self.sensitiveContentReason = sensitiveContentReason
    self.rawEventJSON = rawEventJSON
  }

  init?(event: Event) {
    guard let parsed = ThreadProtocolStrategies.parse(event) else { return nil }
    self = parsed
  }

  init(textNote: RTextNote) {
    let reference = ThreadReference.event(
      id: textNote.eventId,
      kind: 1,
      publicKey: textNote.publicKey,
      relayHints: []
    )
    let rootReference = textNote.rootEventId.isEmpty
      ? reference
      : ThreadReference.event(
        id: textNote.rootEventId,
        kind: 1,
        publicKey: nil,
        relayHints: []
      )
    let parentReference = textNote.replyEventId.isEmpty
      ? nil
      : ThreadReference.event(
        id: textNote.replyEventId,
        kind: 1,
        publicKey: nil,
        relayHints: []
      )

    self.init(
      id: textNote.eventId,
      reference: reference,
      root: rootReference,
      parent: parentReference,
      commentProtocol: .nip10,
      publicKey: textNote.publicKey,
      kind: 1,
      createdAt: textNote.createdAt,
      content: textNote.content,
      tags: textNote.taggedHashtags.map { NostrTag(id: "t", values: [$0]) },
      participantPublicKeys: [],
      isSensitiveContent: textNote.isSensitiveContent,
      sensitiveContentReason: textNote.sensitiveContentReason,
      rawEventJSON: nil
    )
  }
}

struct ThreadRelayQuery: Hashable, Sendable {
  let eventKind: Int
  let indexedTag: String
  let indexedValue: String
  let until: Int64?
  let limit: Int
}

enum ThreadProtocolValidationError: LocalizedError {
  case unsupportedTarget
  case malformedNIP10
  case malformedNIP22
  case missingRootKind
  case missingParentKind

  var errorDescription: String? {
    switch self {
    case .unsupportedTarget: return "This event cannot be replied to."
    case .malformedNIP10: return "The NIP-10 thread reference is invalid."
    case .malformedNIP22: return "The NIP-22 comment reference is invalid."
    case .missingRootKind: return "The comment root kind is missing."
    case .missingParentKind: return "The comment parent kind is missing."
    }
  }
}

protocol ThreadProtocolStrategy {
  var protocolKind: CommentProtocolKind { get }
  var publishedEventKind: Int { get }

  func parse(event: Event) -> ThreadItem?
  func replyQuery(for target: ThreadTarget, cursor: ThreadCursor?, limit: Int) throws
    -> ThreadRelayQuery
  func isDirectChild(_ item: ThreadItem, of target: ThreadTarget) -> Bool
  func makeReplyDraft(
    content: String,
    target: ThreadTarget,
    parseProfileMentions: Bool
  ) throws -> NostrWriteEventDraft
}

enum ThreadProtocolStrategies {
  static let nip10 = NIP10ThreadStrategy()
  static let nip22 = NIP22ThreadStrategy()

  static func strategy(for target: ThreadTarget) -> any ThreadProtocolStrategy {
    switch target.commentProtocol {
    case .nip10: return nip10
    case .nip22: return nip22
    }
  }

  static func parse(_ event: Event) -> ThreadItem? {
    switch event.kind.integerValue {
    case 1:
      return nip10.parse(event: event)
    case 1111:
      return nip22.parse(event: event)
    default:
      return rootItem(event: event)
    }
  }

  private static func rootItem(event: Event) -> ThreadItem? {
    let kind = event.kind.integerValue
    let reference = ThreadReference.event(
      id: event.id,
      kind: kind,
      publicKey: event.publicKey,
      relayHints: []
    )
    let tags = event.tags.map(NostrTag.init(eventTag:))
    let warning = contentWarning(from: tags)

    return ThreadItem(
      id: event.id,
      reference: reference,
      root: reference,
      parent: nil,
      commentProtocol: kind == 1 ? .nip10 : .nip22,
      publicKey: event.publicKey,
      kind: kind,
      createdAt: Date(timeIntervalSince1970: TimeInterval(event.createdAt.timestamp)),
      content: event.content,
      tags: tags,
      participantPublicKeys: participantPublicKeys(in: tags),
      isSensitiveContent: warning.isSensitive,
      sensitiveContentReason: warning.reason,
      rawEventJSON: encodedEvent(event)
    )
  }

  static func participantPublicKeys(in tags: [NostrTag]) -> Set<String> {
    Set(
      tags
        .filter { $0.id.lowercased() == "p" }
        .compactMap { $0.values.first }
        .filter { !$0.isEmpty }
    )
  }

  static func contentWarning(from tags: [NostrTag]) -> (isSensitive: Bool, reason: String) {
    guard let warningTag = tags.first(where: { $0.id.lowercased() == "content-warning" }) else {
      return (false, "")
    }

    let reason = warningTag.values.first?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (true, reason)
  }

  static func encodedEvent(_ event: Event) -> String? {
    guard let data = try? JSONEncoder().encode(event) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

struct NIP10ThreadStrategy: ThreadProtocolStrategy {
  let protocolKind: CommentProtocolKind = .nip10
  let publishedEventKind = 1

  func parse(event: Event) -> ThreadItem? {
    guard event.kind.integerValue == 1 else { return nil }

    let tags = event.tags.map(NostrTag.init(eventTag:))
    let reference = ThreadReference.event(
      id: event.id,
      kind: 1,
      publicKey: event.publicKey,
      relayHints: []
    )
    let eventTags = tags.filter {
      $0.id.lowercased() == "e" && marker(in: $0) != "mention"
    }
    let markedRoot = eventTags.first { marker(in: $0) == "root" }
    let markedReply = eventTags.first { marker(in: $0) == "reply" }
    let rootTag = markedRoot ?? eventTags.first
    let replyTag = markedReply ?? (eventTags.count > 1 ? eventTags.last : rootTag)
    let root = rootTag.flatMap { eventReference(from: $0, kind: 1) } ?? reference
    let parent = replyTag.flatMap { eventReference(from: $0, kind: 1) }
    let warning = ThreadProtocolStrategies.contentWarning(from: tags)

    return ThreadItem(
      id: event.id,
      reference: reference,
      root: root,
      parent: parent,
      commentProtocol: .nip10,
      publicKey: event.publicKey,
      kind: 1,
      createdAt: Date(timeIntervalSince1970: TimeInterval(event.createdAt.timestamp)),
      content: event.content,
      tags: tags,
      participantPublicKeys: ThreadProtocolStrategies.participantPublicKeys(in: tags),
      isSensitiveContent: warning.isSensitive,
      sensitiveContentReason: warning.reason,
      rawEventJSON: ThreadProtocolStrategies.encodedEvent(event)
    )
  }

  func replyQuery(for target: ThreadTarget, cursor: ThreadCursor?, limit: Int) throws
    -> ThreadRelayQuery
  {
    guard target.commentProtocol == .nip10,
      case .event(let id, let kind, _, _) = target.focused,
      kind == 1
    else {
      throw ThreadProtocolValidationError.malformedNIP10
    }

    return ThreadRelayQuery(
      eventKind: 1,
      indexedTag: "e",
      indexedValue: id,
      until: cursor?.until,
      limit: limit
    )
  }

  func isDirectChild(_ item: ThreadItem, of target: ThreadTarget) -> Bool {
    item.commentProtocol == .nip10
      && item.parent?.canonicalKey == target.focused.canonicalKey
  }

  func makeReplyDraft(
    content: String,
    target: ThreadTarget,
    parseProfileMentions: Bool
  ) throws -> NostrWriteEventDraft {
    guard target.commentProtocol == .nip10,
      case .event(let rootID, let rootKind, let rootPublicKey, let rootRelays) = target.root,
      case .event(let parentID, let parentKind, let parentPublicKey, let parentRelays) = target.focused,
      rootKind == 1,
      parentKind == 1
    else {
      throw ThreadProtocolValidationError.malformedNIP10
    }

    return NIP10.reply(
      content: content,
      rootEventID: rootID,
      replyEventID: parentID,
      rootPublicKey: rootPublicKey ?? "",
      replyPublicKey: parentPublicKey ?? "",
      rootRelayHint: rootRelays.first,
      replyRelayHint: parentRelays.first,
      participantPublicKeys: target.participantPublicKeys,
      parseProfileMentions: parseProfileMentions
    )
  }

  private func marker(in tag: NostrTag) -> String? {
    guard tag.values.count > 2 else { return nil }
    let marker = tag.values[2].lowercased()
    return ["root", "reply", "mention"].contains(marker) ? marker : nil
  }

  private func eventReference(from tag: NostrTag, kind: Int) -> ThreadReference? {
    guard let eventID = tag.values.first, !eventID.isEmpty else { return nil }
    let relayHint = tag.values.count > 1 ? tag.values[1] : ""
    let publicKey = tag.values.count > 3 ? tag.values[3] : nil
    return .event(
      id: eventID,
      kind: kind,
      publicKey: publicKey?.isEmpty == false ? publicKey : nil,
      relayHints: relayHint.isEmpty ? [] : [relayHint]
    )
  }
}

struct NIP22ThreadStrategy: ThreadProtocolStrategy {
  let protocolKind: CommentProtocolKind = .nip22
  let publishedEventKind = 1111

  func parse(event: Event) -> ThreadItem? {
    guard event.kind.integerValue == 1111 else { return nil }

    let tags = event.tags.map(NostrTag.init(eventTag:))
    guard let rootKind = tags.first(where: { $0.id == "K" })?.values.first,
      let parentKind = tags.first(where: { $0.id == "k" })?.values.first,
      let root = rootReference(in: tags, kind: rootKind),
      let parent = parentReference(in: tags, kind: parentKind)
    else {
      return nil
    }

    let reference = ThreadReference.event(
      id: event.id,
      kind: 1111,
      publicKey: event.publicKey,
      relayHints: []
    )
    let warning = ThreadProtocolStrategies.contentWarning(from: tags)

    return ThreadItem(
      id: event.id,
      reference: reference,
      root: root,
      parent: parent,
      commentProtocol: .nip22,
      publicKey: event.publicKey,
      kind: 1111,
      createdAt: Date(timeIntervalSince1970: TimeInterval(event.createdAt.timestamp)),
      content: event.content,
      tags: tags,
      participantPublicKeys: ThreadProtocolStrategies.participantPublicKeys(in: tags),
      isSensitiveContent: warning.isSensitive,
      sensitiveContentReason: warning.reason,
      rawEventJSON: ThreadProtocolStrategies.encodedEvent(event)
    )
  }

  func replyQuery(for target: ThreadTarget, cursor: ThreadCursor?, limit: Int) throws
    -> ThreadRelayQuery
  {
    guard target.commentProtocol == .nip22 else {
      throw ThreadProtocolValidationError.malformedNIP22
    }

    return ThreadRelayQuery(
      eventKind: 1111,
      indexedTag: target.focused.parentQueryTag,
      indexedValue: target.focused.parentQueryValue,
      until: cursor?.until,
      limit: limit
    )
  }

  func isDirectChild(_ item: ThreadItem, of target: ThreadTarget) -> Bool {
    item.commentProtocol == .nip22
      && item.root.canonicalKey == target.root.canonicalKey
      && item.parent?.canonicalKey == target.focused.canonicalKey
  }

  func makeReplyDraft(
    content: String,
    target: ThreadTarget,
    parseProfileMentions: Bool
  ) throws -> NostrWriteEventDraft {
    guard target.commentProtocol == .nip22 else {
      throw ThreadProtocolValidationError.malformedNIP22
    }

    return try NIP22.comment(
      content: content,
      root: target.root,
      parent: target.focused,
      participantPublicKeys: target.participantPublicKeys,
      parseProfileMentions: parseProfileMentions
    )
  }

  private func rootReference(in tags: [NostrTag], kind: String) -> ThreadReference? {
    let rootPublicKey = tags.first(where: { $0.id == "P" })?.values.first

    if let addressTag = tags.first(where: { $0.id == "A" }) {
      return addressReference(from: addressTag, eventID: nil, kind: kind, publicKey: rootPublicKey)
    }

    if let eventTag = tags.first(where: { $0.id == "E" }) {
      return eventReference(from: eventTag, kind: kind, fallbackPublicKey: rootPublicKey)
    }

    if let externalTag = tags.first(where: { $0.id == "I" }) {
      return externalReference(from: externalTag, kind: kind)
    }

    return nil
  }

  private func parentReference(in tags: [NostrTag], kind: String) -> ThreadReference? {
    let parentPublicKey = tags.first(where: { $0.id == "p" })?.values.first

    if let addressTag = tags.first(where: { $0.id == "a" }) {
      let concreteEventID = tags.first(where: { $0.id == "e" })?.values.first
      return addressReference(
        from: addressTag,
        eventID: concreteEventID,
        kind: kind,
        publicKey: parentPublicKey
      )
    }

    if let eventTag = tags.first(where: { $0.id == "e" }) {
      return eventReference(from: eventTag, kind: kind, fallbackPublicKey: parentPublicKey)
    }

    if let externalTag = tags.first(where: { $0.id == "i" }) {
      return externalReference(from: externalTag, kind: kind)
    }

    return nil
  }

  private func eventReference(
    from tag: NostrTag,
    kind: String,
    fallbackPublicKey: String?
  ) -> ThreadReference? {
    guard let eventID = tag.values.first,
      let eventKind = Int(kind),
      !eventID.isEmpty
    else {
      return nil
    }

    let relayHint = tag.values.count > 1 ? tag.values[1] : ""
    let taggedPublicKey = tag.values.count > 2 ? tag.values[2] : nil
    return .event(
      id: eventID,
      kind: eventKind,
      publicKey: taggedPublicKey?.isEmpty == false ? taggedPublicKey : fallbackPublicKey,
      relayHints: relayHint.isEmpty ? [] : [relayHint]
    )
  }

  private func addressReference(
    from tag: NostrTag,
    eventID: String?,
    kind: String,
    publicKey: String?
  ) -> ThreadReference? {
    guard let coordinate = tag.values.first,
      let eventKind = Int(kind),
      !coordinate.isEmpty
    else {
      return nil
    }

    let relayHint = tag.values.count > 1 ? tag.values[1] : ""
    let coordinatePublicKey = coordinate.split(separator: ":", maxSplits: 2).dropFirst().first
      .map(String.init)
    return .address(
      coordinate: coordinate,
      eventID: eventID,
      kind: eventKind,
      publicKey: publicKey ?? coordinatePublicKey,
      relayHints: relayHint.isEmpty ? [] : [relayHint]
    )
  }

  private func externalReference(from tag: NostrTag, kind: String) -> ThreadReference? {
    guard let identifier = tag.values.first, !identifier.isEmpty, !kind.isEmpty else { return nil }
    let hint = tag.values.count > 1 ? tag.values[1] : ""
    return .external(
      identifier: identifier,
      kind: kind,
      hints: hint.isEmpty ? [] : [hint]
    )
  }
}

@Model
final class RThreadEvent {
  @Attribute(.unique) var eventId: String
  var kind: Int
  var createdAt: Date
  var rootKey: String
  var parentKey: String
  var rawEventJSON: String

  init(
    eventId: String,
    kind: Int,
    createdAt: Date,
    rootKey: String,
    parentKey: String,
    rawEventJSON: String
  ) {
    self.eventId = eventId
    self.kind = kind
    self.createdAt = createdAt
    self.rootKey = rootKey
    self.parentKey = parentKey
    self.rawEventJSON = rawEventJSON
  }

  convenience init?(item: ThreadItem) {
    guard let rawEventJSON = item.rawEventJSON else { return nil }
    self.init(
      eventId: item.id,
      kind: item.kind,
      createdAt: item.createdAt,
      rootKey: item.root.canonicalKey,
      parentKey: item.parent?.canonicalKey ?? "",
      rawEventJSON: rawEventJSON
    )
  }

  func threadItem() -> ThreadItem? {
    guard let data = rawEventJSON.data(using: .utf8),
      let event = try? JSONDecoder().decode(Event.self, from: data)
    else {
      return nil
    }

    return ThreadItem(event: event)
  }
}

extension EventKind {
  var integerValue: Int {
    switch self {
    case .setMetadata: return 0
    case .textNote: return 1
    case .recommentServer: return 2
    case .custom(let value): return value
    }
  }
}

final class ThreadRequest {
  private let lock = NSLock()
  private var cancellation: (() -> Void)?

  init(cancellation: @escaping () -> Void = {}) {
    self.cancellation = cancellation
  }

  func cancel() {
    lock.lock()
    let action = cancellation
    cancellation = nil
    lock.unlock()
    action?()
  }
}

protocol ThreadRepositoryProtocol: AnyObject {
  func cachedFocusedItem(for target: ThreadTarget) -> ThreadItem?
  func cachedReplies(for target: ThreadTarget, limit: Int) -> [ThreadItem]
  @MainActor func persistPublishedEvent(_ event: Event) -> ThreadItem?

  @discardableResult
  func fetchFocusedItem(
    for target: ThreadTarget,
    completion: @escaping (Result<ThreadItem?, Error>) -> Void
  ) -> ThreadRequest

  @discardableResult
  func fetchReplyPage(
    for target: ThreadTarget,
    cursor: ThreadCursor?,
    limit: Int,
    completion: @escaping (Result<ThreadPage<ThreadItem>, Error>) -> Void
  ) -> ThreadRequest
}

struct ThreadProcessedRelayPage {
  let parsedItems: [ThreadItem]
  let directItems: [ThreadItem]
  let nextCursor: ThreadCursor?
  let rawExhausted: Bool
}

final class NostrThreadRepository: ThreadRepositoryProtocol {
  private static let maximumCachedThreadEvents = 1_000
  private let nostrData: NostrData
  private let rawPageSize = 40
  private let maximumScansPerPage = 3

  init(nostrData: NostrData) {
    self.nostrData = nostrData
  }

  func cachedFocusedItem(for target: ThreadTarget) -> ThreadItem? {
    guard let eventID = target.focused.eventID else { return nil }

    if let item = cachedThreadEvent(eventID: eventID) {
      return item
    }

    guard target.focused.nostrKind == 1 else { return nil }
    let context = ModelContext(nostrData.modelContainer)
    var descriptor = FetchDescriptor<RTextNote>(
      predicate: #Predicate { $0.eventId == eventID }
    )
    descriptor.fetchLimit = 1
    return (try? context.fetch(descriptor).first).map(ThreadItem.init(textNote:))
  }

  func cachedReplies(for target: ThreadTarget, limit: Int) -> [ThreadItem] {
    let context = ModelContext(nostrData.modelContainer)
    let parentKey = target.focused.canonicalKey
    var descriptor = FetchDescriptor<RThreadEvent>(
      predicate: #Predicate { $0.parentKey == parentKey },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = max(1, limit)
    var items = ((try? context.fetch(descriptor)) ?? []).compactMap { $0.threadItem() }

    if target.commentProtocol == .nip10,
      let parentEventID = target.focused.eventID
    {
      var noteDescriptor = FetchDescriptor<RTextNote>(
        predicate: #Predicate { $0.replyEventId == parentEventID },
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      noteDescriptor.fetchLimit = max(1, limit)
      items.append(contentsOf: ((try? context.fetch(noteDescriptor)) ?? []).map(ThreadItem.init))
    }

    return Array(
      items
        .filter { ThreadProtocolStrategies.strategy(for: target).isDirectChild($0, of: target) }
        .uniqued(by: \.id)
        .sorted(by: Self.oldestItemFirst)
        .suffix(max(1, limit))
    )
  }

  @MainActor func persistPublishedEvent(_ event: Event) -> ThreadItem? {
    guard let item = ThreadItem(event: event) else { return nil }
    persist([item])
    if event.kind.integerValue == 1 {
      _ = nostrData.persistPublishedTextNote(event)
    }
    return item
  }

  @discardableResult
  func fetchFocusedItem(
    for target: ThreadTarget,
    completion: @escaping (Result<ThreadItem?, Error>) -> Void
  ) -> ThreadRequest {
    guard let eventID = target.focused.eventID else {
      completion(.success(nil))
      return ThreadRequest()
    }

    let kind = target.focused.nostrKind
    return aggregateRelayEvents(
      subscribe: { relay, relayCompletion in
        relay.subscribeThreadEvent(
          eventID: eventID,
          eventKind: kind,
          completion: relayCompletion
        )
      }
    ) { [weak self] events, _ in
      guard let self else { return }
      let item = events
        .first(where: { $0.id == eventID })
        .flatMap(ThreadItem.init(event:))
      if let item {
        self.persist([item])
      }
      completion(.success(item))
    }
  }

  @discardableResult
  func fetchReplyPage(
    for target: ThreadTarget,
    cursor: ThreadCursor?,
    limit: Int,
    completion: @escaping (Result<ThreadPage<ThreadItem>, Error>) -> Void
  ) -> ThreadRequest {
    let strategy = ThreadProtocolStrategies.strategy(for: target)
    let request = ThreadRequest()
    let state = ThreadScanState(cursor: cursor)

    func scan() {
      let query: ThreadRelayQuery
      do {
        query = try strategy.replyQuery(
          for: target,
          cursor: state.cursor,
          limit: rawPageSize
        )
      } catch {
        completion(.failure(error))
        return
      }

      let relayRequest = aggregateRelayEvents(
        subscribe: { relay, relayCompletion in
          relay.subscribeThreadPage(query: query, completion: relayCompletion)
        }
      ) { [weak self] events, relayCounts in
        guard let self, !state.cancelled else { return }

        state.scanCount += 1
        let processed = Self.processRelayPage(
          events: events,
          relayCounts: relayCounts,
          target: target,
          cursor: state.cursor,
          limit: limit,
          rawPageSize: self.rawPageSize
        )
        self.persist(processed.parsedItems)

        if processed.directItems.isEmpty,
          !processed.rawExhausted,
          state.scanCount < self.maximumScansPerPage,
          processed.nextCursor != state.cursor
        {
          state.cursor = processed.nextCursor
          scan()
          return
        }

        let page = ThreadPage(
          items: processed.directItems.sorted(by: Self.oldestItemFirst),
          cursor: processed.nextCursor,
          exhausted: processed.rawExhausted
        )
        completion(.success(page))
      }

      state.activeRequest?.cancel()
      state.activeRequest = relayRequest
    }

    request.replaceCancellation {
      state.cancelled = true
      state.activeRequest?.cancel()
    }
    scan()
    return request
  }

  private func cachedThreadEvent(eventID: String) -> ThreadItem? {
    let context = ModelContext(nostrData.modelContainer)
    var descriptor = FetchDescriptor<RThreadEvent>(
      predicate: #Predicate { $0.eventId == eventID }
    )
    descriptor.fetchLimit = 1
    return (try? context.fetch(descriptor).first)?.threadItem()
  }

  static func processRelayPage(
    events: [Event],
    relayCounts: [Int],
    target: ThreadTarget,
    cursor: ThreadCursor?,
    limit: Int,
    rawPageSize: Int
  ) -> ThreadProcessedRelayPage {
    let strategy = ThreadProtocolStrategies.strategy(for: target)
    let uniqueEvents = events.uniqued(by: \.id).sorted(by: newestEventFirst)
    let parsedItems = uniqueEvents.compactMap(ThreadItem.init(event:))
    var directItems: [ThreadItem] = []
    var consumedTimestamp: Int64?

    for event in uniqueEvents {
      consumedTimestamp = Int64(event.createdAt.timestamp)
      guard let item = ThreadItem(event: event) else { continue }
      guard strategy.isDirectChild(item, of: target) else { continue }

      directItems.append(item)
      if directItems.count == max(1, limit) {
        break
      }
    }

    let nextCursor = consumedTimestamp.map { ThreadCursor(until: max(0, $0 - 1)) } ?? cursor
    return ThreadProcessedRelayPage(
      parsedItems: parsedItems,
      directItems: directItems,
      nextCursor: nextCursor,
      rawExhausted: relayCounts.allSatisfy { $0 < rawPageSize }
    )
  }

  private func persist(_ items: [ThreadItem]) {
    guard !items.isEmpty else { return }

    let context = ModelContext(nostrData.modelContainer)
    var knownProfileKeys = Set<String>()
    for item in items {
      if knownProfileKeys.insert(item.publicKey).inserted {
        let publicKey = item.publicKey
        var profileDescriptor = FetchDescriptor<RUserProfile>(
          predicate: #Predicate { $0.publicKey == publicKey }
        )
        profileDescriptor.fetchLimit = 1
        if (try? context.fetch(profileDescriptor).first) == nil {
          context.insert(RUserProfile.createEmpty(withPublicKey: publicKey))
        }
      }

      let eventID = item.id
      var descriptor = FetchDescriptor<RThreadEvent>(
        predicate: #Predicate { $0.eventId == eventID }
      )
      descriptor.fetchLimit = 1

      if let existing = try? context.fetch(descriptor).first {
        existing.kind = item.kind
        existing.createdAt = item.createdAt
        existing.rootKey = item.root.canonicalKey
        existing.parentKey = item.parent?.canonicalKey ?? ""
        if let rawEventJSON = item.rawEventJSON {
          existing.rawEventJSON = rawEventJSON
        }
      } else if let storedItem = RThreadEvent(item: item) {
        context.insert(storedItem)
      }
    }

    var cacheDescriptor = FetchDescriptor<RThreadEvent>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    cacheDescriptor.fetchLimit = Self.maximumCachedThreadEvents + items.count
    if let cachedEvents = try? context.fetch(cacheDescriptor),
      cachedEvents.count > Self.maximumCachedThreadEvents
    {
      for cachedEvent in cachedEvents.dropFirst(Self.maximumCachedThreadEvents) {
        context.delete(cachedEvent)
      }
    }

    try? context.save()
    nostrData.nostrRelays.forEach { $0.subscribeProfiles() }
  }

  private func aggregateRelayEvents(
    subscribe: @escaping (NostrRelay, @escaping ([Event]) -> Void) -> String,
    completion: @escaping ([Event], [Int]) -> Void
  ) -> ThreadRequest {
    guard nostrData.isNetworkEnabled else {
      completion([], [])
      return ThreadRequest()
    }

    nostrData.bootstrapConfiguredRelays()
    let relays = nostrData.nostrRelays.filter { $0.connected || $0.isConnecting }
    guard !relays.isEmpty else {
      completion([], [])
      return ThreadRequest()
    }

    let state = ThreadRelayAggregationState(expectedCount: relays.count)
    for relay in relays {
      let subscriptionID = subscribe(relay) { events in
        state.lock.lock()
        guard !state.cancelled else {
          state.lock.unlock()
          return
        }
        state.events.append(contentsOf: events)
        state.relayCounts.append(events.count)
        state.completedCount += 1
        let isComplete = state.completedCount == state.expectedCount
        let mergedEvents = state.events
        let relayCounts = state.relayCounts
        state.lock.unlock()

        if isComplete {
          completion(mergedEvents, relayCounts)
        }
      }
      state.requests.append((relay, subscriptionID))
    }

    return ThreadRequest {
      state.lock.lock()
      guard !state.cancelled else {
        state.lock.unlock()
        return
      }
      state.cancelled = true
      let requests = state.requests
      state.lock.unlock()

      for request in requests {
        request.0.cancelThreadRequest(subscriptionID: request.1)
      }
    }
  }

  private static func newestEventFirst(_ lhs: Event, _ rhs: Event) -> Bool {
    if lhs.createdAt.timestamp == rhs.createdAt.timestamp {
      return lhs.id < rhs.id
    }
    return lhs.createdAt.timestamp > rhs.createdAt.timestamp
  }

  private static func oldestItemFirst(_ lhs: ThreadItem, _ rhs: ThreadItem) -> Bool {
    if lhs.createdAt == rhs.createdAt {
      return lhs.id < rhs.id
    }
    return lhs.createdAt < rhs.createdAt
  }
}

private final class ThreadScanState {
  var cursor: ThreadCursor?
  var scanCount = 0
  var activeRequest: ThreadRequest?
  var cancelled = false

  init(cursor: ThreadCursor?) {
    self.cursor = cursor
  }
}

private final class ThreadRelayAggregationState {
  let lock = NSLock()
  let expectedCount: Int
  var completedCount = 0
  var events: [Event] = []
  var relayCounts: [Int] = []
  var requests: [(NostrRelay, String)] = []
  var cancelled = false

  init(expectedCount: Int) {
    self.expectedCount = expectedCount
  }
}

extension ThreadRequest {
  fileprivate func replaceCancellation(_ cancellation: @escaping () -> Void) {
    lock.lock()
    self.cancellation = cancellation
    lock.unlock()
  }
}

@MainActor
final class ThreadController: ObservableObject {
  @Published private(set) var focusedItem: ThreadItem?
  @Published private(set) var directReplies: [ThreadItem] = []
  @Published private(set) var target: ThreadTarget
  @Published private(set) var isLoadingFocusedItem = false
  @Published private(set) var isLoadingInitialReplies = false
  @Published private(set) var isLoadingOlderReplies = false
  @Published private(set) var hasReachedReplyEnd = false
  @Published private(set) var errorMessage: String?

  let pageSize = 10
  private var cursor: ThreadCursor?
  private var visibleIDs = Set<String>()
  private var focusedRequest: ThreadRequest?
  private var replyRequest: ThreadRequest?
  private var repository: ThreadRepositoryProtocol?
  private var didStart = false

  init(target: ThreadTarget) {
    self.target = target
  }

  func start(repository: ThreadRepositoryProtocol) {
    self.repository = repository

    if didStart {
      if focusedItem == nil {
        loadFocusedItemIfNeeded(force: true)
      }
      if directReplies.isEmpty {
        loadInitialReplies(force: true)
      }
      return
    }

    didStart = true

    focusedItem = repository.cachedFocusedItem(for: target)
    if let focusedItem {
      _ = refineTarget(using: focusedItem)
    }

    append(repository.cachedReplies(for: target, limit: pageSize))
    loadFocusedItemIfNeeded()
    loadInitialReplies()
  }

  func loadOlderReplies() {
    guard !isLoadingInitialReplies,
      !isLoadingOlderReplies,
      !hasReachedReplyEnd,
      let repository
    else { return }

    isLoadingOlderReplies = true
    errorMessage = nil
    replyRequest = repository.fetchReplyPage(
      for: target,
      cursor: cursor,
      limit: pageSize
    ) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isLoadingOlderReplies = false
        self.consume(result)
      }
    }
  }

  func registerPublishedReply(_ item: ThreadItem) {
    append([item])
  }

  func replacePublishedReply(eventID: String, with item: ThreadItem) {
    directReplies.removeAll { $0.id == eventID }
    visibleIDs.remove(eventID)
    append([item])
  }

  func retry() {
    errorMessage = nil
    if focusedItem == nil {
      loadFocusedItemIfNeeded(force: true)
    }
    if directReplies.isEmpty {
      loadInitialReplies(force: true)
    } else {
      loadOlderReplies()
    }
  }

  func cancel() {
    focusedRequest?.cancel()
    replyRequest?.cancel()
    focusedRequest = nil
    replyRequest = nil
    isLoadingFocusedItem = false
    isLoadingInitialReplies = false
    isLoadingOlderReplies = false
  }

  private func loadFocusedItemIfNeeded(force: Bool = false) {
    guard (force || focusedItem == nil),
      !isLoadingFocusedItem,
      let repository,
      target.focused.eventID != nil
    else { return }

    isLoadingFocusedItem = true
    focusedRequest = repository.fetchFocusedItem(for: target) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isLoadingFocusedItem = false
        switch result {
        case .success(let item):
          if let item {
            self.focusedItem = item
            if self.refineTarget(using: item) {
              self.replyRequest?.cancel()
              self.replyRequest = nil
              self.cursor = nil
              self.hasReachedReplyEnd = false
              self.directReplies.removeAll()
              self.visibleIDs.removeAll()
              if let repository = self.repository {
                self.append(repository.cachedReplies(for: self.target, limit: self.pageSize))
              }
              self.loadInitialReplies(force: true)
            }
          }
        case .failure(let error):
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func loadInitialReplies(force: Bool = false) {
    guard (force || cursor == nil),
      !isLoadingInitialReplies,
      !isLoadingOlderReplies,
      let repository
    else { return }

    isLoadingInitialReplies = directReplies.isEmpty
    replyRequest = repository.fetchReplyPage(
      for: target,
      cursor: nil,
      limit: pageSize
    ) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isLoadingInitialReplies = false
        self.consume(result)
      }
    }
  }

  private func consume(_ result: Result<ThreadPage<ThreadItem>, Error>) {
    switch result {
    case .success(let page):
      append(page.items)
      if page.cursor != cursor {
        cursor = page.cursor
      }
      hasReachedReplyEnd = page.exhausted
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
  }

  private func append(_ items: [ThreadItem]) {
    let additions = items.filter { visibleIDs.insert($0.id).inserted }
    guard !additions.isEmpty else { return }
    directReplies.append(contentsOf: additions)
    directReplies.sort {
      if $0.createdAt == $1.createdAt { return $0.id < $1.id }
      return $0.createdAt < $1.createdAt
    }
  }

  @discardableResult
  private func refineTarget(using item: ThreadItem) -> Bool {
    let previousTarget = target

    if item.parent != nil || item.kind == 1111 {
      target = item.target
      return target != previousTarget
    }

    let focused = enriched(reference: target.focused, with: item)
    let root = target.root.canonicalKey == target.focused.canonicalKey
      ? focused
      : target.root
    target = ThreadTarget(
      focused: focused,
      root: root,
      commentProtocol: item.commentProtocol,
      participantPublicKeys: target.participantPublicKeys.union(item.participantPublicKeys)
    )
    return target != previousTarget
  }

  private func enriched(reference: ThreadReference, with item: ThreadItem) -> ThreadReference {
    switch reference {
    case .event(let id, _, let publicKey, let relayHints):
      return .event(
        id: id,
        kind: item.kind,
        publicKey: publicKey ?? item.publicKey,
        relayHints: relayHints
      )
    case .address(let coordinate, let eventID, let kind, let publicKey, let relayHints):
      return .address(
        coordinate: coordinate,
        eventID: eventID ?? item.id,
        kind: kind,
        publicKey: publicKey ?? item.publicKey,
        relayHints: relayHints
      )
    case .external:
      return reference
    }
  }
}

private extension Sequence {
  func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
    var keys = Set<Key>()
    return filter { keys.insert($0[keyPath: keyPath]).inserted }
  }
}
