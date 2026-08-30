// a

import Foundation
import NostrKit
import SwiftData

struct PersistedTextNoteSummary: Hashable, Sendable {
  enum Origin: Hashable, Sendable {
    case historicalRelay
    case liveRelay
    case localPublish
  }

  let id: String
  let eventId: String
  let publicKey: String
  let content: String
  let createdAt: Date
  let eventCreatedAt: Date
  let hashtags: [String]
  let isSensitiveContent: Bool
  let sensitiveContentReason: String
  let origin: Origin
  let repost: FeedRepost?

  var actorPublicKey: String {
    repost?.publicKey ?? publicKey
  }

  init(
    id: String? = nil,
    eventId: String,
    publicKey: String,
    content: String,
    createdAt: Date,
    eventCreatedAt: Date? = nil,
    hashtags: [String] = [],
    isSensitiveContent: Bool = false,
    sensitiveContentReason: String = "",
    origin: Origin = .historicalRelay,
    repost: FeedRepost? = nil
  ) {
    self.id = id ?? eventId
    self.eventId = eventId
    self.publicKey = publicKey
    self.content = content
    self.createdAt = createdAt
    self.eventCreatedAt = eventCreatedAt ?? createdAt
    self.hashtags = hashtags
    self.isSensitiveContent = isSensitiveContent
    self.sensitiveContentReason = sensitiveContentReason
    self.origin = origin
    self.repost = repost
  }
}

enum TextNoteFeedPolicy {
  static let maximumFutureSkew: TimeInterval = 5 * 60

  static func accepts(createdAt: Date, now: Date = Date()) -> Bool {
    createdAt <= now.addingTimeInterval(maximumFutureSkew)
  }
}

enum TextNoteFeedScope: Equatable {
  case global
  case authors(Set<String>)
  case terms([String])
  case verse(authors: Set<String>, hashtags: [String])

  var debugDescription: String {
    switch self {
    case .global:
      return "global"
    case .authors(let authors):
      return "authors(\(authors.count))"
    case .terms(let terms):
      return "terms(\(Self.normalizedTerms(terms).joined(separator: ",")))"
    case .verse(let authors, let hashtags):
      let tags = Self.normalizedTerms(hashtags).joined(separator: ",")
      return "verse(authors=\(authors.count),hashtags=\(tags))"
    }
  }

  var isGlobal: Bool {
    if case .global = self {
      return true
    }

    return false
  }

  var relayAuthors: [String]? {
    guard case .authors(let authors) = self else { return nil }
    return Array(authors).sorted()
  }

  var normalizedTerms: [String] {
    switch self {
    case .terms(let terms):
      return Self.normalizedTerms(terms)
    case .verse(_, let hashtags):
      return Self.normalizedTerms(hashtags)
    case .global, .authors:
      return []
    }
  }

  var relayHashtags: [String] {
    switch self {
    case .terms(let rawTerms):
      return rawTerms
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { $0.hasPrefix("#") }
        .map { String($0.drop(while: { $0 == "#" })) }
        .filter { !$0.isEmpty }
        .uniqued()
    case .verse(_, let hashtags):
      return Self.normalizedTerms(hashtags)
    case .global, .authors:
      return []
    }
  }

  var relaySearchTerms: [String] {
    guard case .terms(let terms) = self else { return [] }
    return terms
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
      .uniqued()
  }

  func matches(_ note: RTextNote) -> Bool {
    matches(publicKey: note.publicKey, content: note.content)
      || matches(hashtags: note.taggedHashtags)
  }

  func matches(_ summary: PersistedTextNoteSummary) -> Bool {
    matches(actorPublicKey: summary.actorPublicKey, contentPublicKey: summary.publicKey, content: summary.content)
      || matches(hashtags: summary.hashtags)
  }

  func matches(_ event: Event) -> Bool {
    switch self {
    case .global:
      return true
    case .authors(let authors):
      return authors.contains(event.publicKey)
    case .terms:
      if matches(publicKey: event.publicKey, content: event.content) {
        return true
      }

      let tags = Set(
        event.tags
          .filter { $0.id.lowercased() == "t" }
          .compactMap { $0.otherInformation.first?.lowercased() }
      )
      return !tags.isDisjoint(with: Set(relayHashtags))
    case .verse(let authors, let hashtags):
      if authors.contains(event.publicKey) {
        return true
      }

      if matches(publicKey: event.publicKey, content: event.content) {
        return true
      }

      let tags = Set(
        event.tags
          .filter { $0.id.lowercased() == "t" }
          .compactMap { $0.otherInformation.first?.lowercased() }
      )
      return !tags.isDisjoint(with: Set(Self.normalizedTerms(hashtags)))
    }
  }

  func matches(publicKey: String, content: String) -> Bool {
    matches(actorPublicKey: publicKey, contentPublicKey: publicKey, content: content)
  }

  private func matches(actorPublicKey: String, contentPublicKey: String, content: String) -> Bool {
    switch self {
    case .global:
      return true
    case .authors(let authors):
      return authors.contains(actorPublicKey)
    case .terms:
      let terms = normalizedTerms
      guard !terms.isEmpty else { return false }

      let lowercasedContent = content.lowercased()
      return terms.contains { term in
        contentPublicKey.lowercased().contains(term)
          || actorPublicKey.lowercased().contains(term)
          || lowercasedContent.contains(term)
          || lowercasedContent.contains("#\(term)")
      }
    case .verse(let authors, let hashtags):
      if authors.contains(actorPublicKey) {
        return true
      }

      let terms = Self.normalizedTerms(hashtags)
      guard !terms.isEmpty else { return false }

      let lowercasedContent = content.lowercased()
      return terms.contains { term in
        lowercasedContent.contains("#\(term)") || lowercasedContent.contains(term)
      }
    }
  }

  private func matches(hashtags: [String]) -> Bool {
    let normalizedHashtags = Set(Self.normalizedTerms(hashtags))
    guard !normalizedHashtags.isEmpty else { return false }

    switch self {
    case .global:
      return true
    case .authors:
      return false
    case .terms, .verse:
      return !normalizedHashtags.isDisjoint(with: Set(relayHashtags))
    }
  }

  static func normalizedTerms(_ rawTerms: [String]) -> [String] {
    rawTerms
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .map { term in
        String(term.drop(while: { $0 == "#" }))
      }
      .filter { !$0.isEmpty }
      .uniqued()
  }
}

private extension Array where Element: Hashable {
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}

enum FeedScope: Hashable, Sendable {
  case global
  case verse(authors: Set<String>, hashtags: Set<String>)
  case crew(pubkeys: Set<String>)
  case profile(pubkey: String)

  var textNoteFeedScope: TextNoteFeedScope {
    switch self {
    case .global:
      return .global
    case .verse(let authors, let hashtags):
      return .verse(authors: authors, hashtags: Array(hashtags).sorted())
    case .crew(let pubkeys):
      return .authors(pubkeys)
    case .profile(let pubkey):
      return .authors([pubkey])
    }
  }

  var debugDescription: String {
    textNoteFeedScope.debugDescription
  }
}

struct FeedCursor: Hashable, Sendable {
  let until: Int64

  init(until: Int64) {
    self.until = until
  }

  init(date: Date) {
    self.until = Int64(date.timeIntervalSince1970)
  }

  var date: Date {
    Date(timeIntervalSince1970: TimeInterval(until))
  }
}

struct FeedPage<Item: Sendable>: Sendable {
  let items: [Item]
  let cursor: FeedCursor?
  let exhausted: Bool
}

struct NostrEventReference: Hashable, Sendable, Identifiable {
  let id: String
  let relayHints: [String]
  let kind: Int?
  let publicKey: String?

  init(
    id: String,
    relayHints: [String] = [],
    kind: Int? = nil,
    publicKey: String? = nil
  ) {
    self.id = id
    self.relayHints = relayHints
    self.kind = kind
    self.publicKey = publicKey
  }

  init?(rawValue: String) {
    let trimmed = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let token = trimmed.hasPrefix("nostr:")
      ? String(trimmed.dropFirst("nostr:".count))
      : trimmed

    guard let decoded = try? bech32_decode(token) else { return nil }

    switch decoded.hrp {
    case "note":
      guard decoded.data.count == 32 else { return nil }
      self.init(id: hex_encode(decoded.data))
    case "nevent":
      guard let decodedEvent = Self.decodeNEvent(decoded.data) else { return nil }
      self.init(
        id: decodedEvent.id,
        relayHints: decodedEvent.relayHints,
        kind: decodedEvent.kind,
        publicKey: decodedEvent.publicKey
      )
    default:
      return nil
    }
  }

  init?(url: URL) {
    guard url.scheme == "nostr" else { return nil }

    let token: String
    if let host = url.host, !host.isEmpty {
      token = host
    } else {
      token = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
    }

    self.init(rawValue: "nostr:\(token)")
  }

  var canonicalLink: String {
    guard let bytes = hex_decode(id), bytes.count == 32 else {
      return "nostr:\(id)"
    }

    if kind != nil || publicKey != nil || !relayHints.isEmpty {
      var tlv: [UInt8] = [0, UInt8(bytes.count)] + bytes
      for relayHint in relayHints.prefix(3) {
        let relayBytes = Array(relayHint.utf8.prefix(255))
        tlv.append(contentsOf: [1, UInt8(relayBytes.count)] + relayBytes)
      }
      if let publicKey, let publicKeyBytes = hex_decode(publicKey), publicKeyBytes.count == 32 {
        tlv.append(contentsOf: [2, 32] + publicKeyBytes)
      }
      if let kind {
        let value = UInt32(clamping: kind)
        tlv.append(contentsOf: [
          3, 4,
          UInt8((value >> 24) & 0xff),
          UInt8((value >> 16) & 0xff),
          UInt8((value >> 8) & 0xff),
          UInt8(value & 0xff),
        ])
      }
      return "nostr:\(bech32_encode(hrp: "nevent", tlv))"
    }

    return "nostr:\(bech32_encode(hrp: "note", bytes))"
  }

  var url: URL? {
    URL(string: canonicalLink)
  }

  private static func decodeNEvent(
    _ data: Data
  ) -> (id: String, relayHints: [String], kind: Int?, publicKey: String?)? {
    var index = 0
    var eventID: String?
    var relayHints: [String] = []
    var eventKind: Int?
    var publicKey: String?

    while index + 2 <= data.count {
      let type = data[index]
      let length = Int(data[index + 1])
      index += 2

      guard index + length <= data.count else { break }

      let value = Data(data[index..<index + length])
      index += length

      switch type {
      case 0 where length == 32:
        eventID = hex_encode(value)
      case 1:
        if let relayHint = String(data: value, encoding: .utf8),
          !relayHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          relayHints.append(relayHint)
        }
      case 2 where length == 32:
        publicKey = hex_encode(value)
      case 3 where length == 4:
        eventKind = value.reduce(0) { partial, byte in
          (partial << 8) | Int(byte)
        }
      default:
        break
      }
    }

    guard let eventID else { return nil }
    return (eventID, relayHints, eventKind, publicKey)
  }
}

struct NostrTag: Hashable, Sendable {
  let id: String
  let values: [String]

  init(id: String, values: [String]) {
    self.id = id
    self.values = values
  }

  init(eventTag: EventTag) {
    self.id = eventTag.id
    self.values = eventTag.otherInformation
  }
}

struct FeedItem: Identifiable, Hashable, Sendable {
  let id: String
  let eventId: String
  let pubkey: String
  let createdAt: Date
  let eventCreatedAt: Date
  let createdAtTimestamp: Int64
  let content: String
  let tags: [NostrTag]
  let replyTo: String?
  let rootEventId: String?
  let hashtags: [String]
  let isSensitiveContent: Bool
  let sensitiveContentReason: String
  let repost: FeedRepost?

  var actorPublicKey: String {
    repost?.publicKey ?? pubkey
  }

  init(
    id: String,
    eventId: String? = nil,
    pubkey: String,
    createdAt: Date,
    eventCreatedAt: Date? = nil,
    createdAtTimestamp: Int64,
    content: String,
    tags: [NostrTag],
    replyTo: String?,
    rootEventId: String?,
    hashtags: [String],
    isSensitiveContent: Bool,
    sensitiveContentReason: String,
    repost: FeedRepost? = nil
  ) {
    self.id = id
    self.eventId = eventId ?? id
    self.pubkey = pubkey
    self.createdAt = createdAt
    self.eventCreatedAt = eventCreatedAt ?? createdAt
    self.createdAtTimestamp = createdAtTimestamp
    self.content = content
    self.tags = tags
    self.replyTo = replyTo
    self.rootEventId = rootEventId
    self.hashtags = hashtags
    self.isSensitiveContent = isSensitiveContent
    self.sensitiveContentReason = sensitiveContentReason
    self.repost = repost
  }

  init(event: Event) {
    self.init(textNoteEvent: event)
  }

  init(textNoteEvent event: Event) {
    let tags = event.tags.map(NostrTag.init(eventTag:))
    let eTags = tags.filter { $0.id.lowercased() == "e" }
    let rootEventId = Self.eventID(in: eTags, marker: "root") ?? eTags.first?.values.first
    let replyTo = Self.eventID(in: eTags, marker: "reply") ?? eTags.last?.values.first
    let sensitiveWarning = Self.contentWarning(from: tags)
    let hashtags = Self.hashtags(from: tags)
    let timestamp = Int64(event.createdAt.timestamp)

    self.init(
      id: event.id,
      pubkey: event.publicKey,
      createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
      createdAtTimestamp: timestamp,
      content: event.content,
      tags: tags,
      replyTo: replyTo,
      rootEventId: rootEventId,
      hashtags: hashtags,
      isSensitiveContent: sensitiveWarning.isSensitive,
      sensitiveContentReason: sensitiveWarning.reason
    )
  }

  init?(networkEvent event: Event) {
    switch event.kind {
    case .textNote:
      self.init(textNoteEvent: event)
    case .custom(let kind) where kind == 6:
      guard let originalEvent = RRepost.embeddedTextNoteEvent(from: event) else {
        return nil
      }
      self.init(repostEvent: event, originalEvent: originalEvent)
    default:
      return nil
    }
  }

  init(repostEvent: Event, originalEvent: Event) {
    let originalItem = FeedItem(textNoteEvent: originalEvent)
    let timestamp = Int64(repostEvent.createdAt.timestamp)
    self.init(
      id: repostEvent.id,
      eventId: originalItem.eventId,
      pubkey: originalItem.pubkey,
      createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
      eventCreatedAt: originalItem.eventCreatedAt,
      createdAtTimestamp: timestamp,
      content: originalItem.content,
      tags: originalItem.tags,
      replyTo: originalItem.replyTo,
      rootEventId: originalItem.rootEventId,
      hashtags: originalItem.hashtags,
      isSensitiveContent: originalItem.isSensitiveContent,
      sensitiveContentReason: originalItem.sensitiveContentReason,
      repost: FeedRepost(repostEvent: repostEvent)
    )
  }

  init(textNote: RTextNote) {
    self.init(
      id: textNote.eventId,
      eventId: textNote.eventId,
      pubkey: textNote.publicKey,
      createdAt: textNote.createdAt,
      eventCreatedAt: textNote.createdAt,
      createdAtTimestamp: Int64(textNote.createdAt.timeIntervalSince1970),
      content: textNote.content,
      tags: textNote.taggedHashtags.map { NostrTag(id: "t", values: [$0]) },
      replyTo: textNote.replyEventId.isEmpty ? textNote.reply?.eventId : textNote.replyEventId,
      rootEventId: textNote.rootEventId.isEmpty ? textNote.rootReply?.eventId : textNote.rootEventId,
      hashtags: textNote.taggedHashtags,
      isSensitiveContent: textNote.isSensitiveContent,
      sensitiveContentReason: textNote.sensitiveContentReason
    )
  }

  init?(repost: RRepost) {
    guard let textNote = repost.targetTextNote else { return nil }
    self.init(
      id: repost.eventId,
      eventId: textNote.eventId,
      pubkey: textNote.publicKey,
      createdAt: repost.createdAt,
      eventCreatedAt: textNote.createdAt,
      createdAtTimestamp: Int64(repost.createdAt.timeIntervalSince1970),
      content: textNote.content,
      tags: textNote.taggedHashtags.map { NostrTag(id: "t", values: [$0]) },
      replyTo: textNote.replyEventId.isEmpty ? textNote.reply?.eventId : textNote.replyEventId,
      rootEventId: textNote.rootEventId.isEmpty ? textNote.rootReply?.eventId : textNote.rootEventId,
      hashtags: textNote.taggedHashtags,
      isSensitiveContent: textNote.isSensitiveContent,
      sensitiveContentReason: textNote.sensitiveContentReason,
      repost: FeedRepost(repost: repost)
    )
  }

  init(summary: PersistedTextNoteSummary) {
    self.init(
      id: summary.id,
      eventId: summary.eventId,
      pubkey: summary.publicKey,
      createdAt: summary.createdAt,
      eventCreatedAt: summary.eventCreatedAt,
      createdAtTimestamp: Int64(summary.createdAt.timeIntervalSince1970),
      content: summary.content,
      tags: summary.hashtags.map { NostrTag(id: "t", values: [$0]) },
      replyTo: nil,
      rootEventId: nil,
      hashtags: summary.hashtags,
      isSensitiveContent: summary.isSensitiveContent,
      sensitiveContentReason: summary.sensitiveContentReason,
      repost: summary.repost
    )
  }

  var sensitiveContentLabel: String {
    let trimmedReason = sensitiveContentReason.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedReason.isEmpty ? "Sensitive content" : trimmedReason
  }

  private static func eventID(in tags: [NostrTag], marker: String) -> String? {
    tags.first {
      $0.values.dropFirst().contains { $0.lowercased() == marker }
    }?.values.first
  }

  private static func hashtags(from tags: [NostrTag]) -> [String] {
    tags
      .filter { $0.id.lowercased() == "t" }
      .compactMap { $0.values.first?.lowercased() }
      .map { String($0.drop(while: { $0 == "#" })) }
      .filter { !$0.isEmpty }
      .uniqued()
  }

  private static func contentWarning(from tags: [NostrTag]) -> (isSensitive: Bool, reason: String) {
    guard let tag = tags.first(where: { $0.id.lowercased() == "content-warning" }) else {
      return (false, "")
    }

    let reason = tag.values.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (true, reason)
  }
}

struct FeedRepost: Hashable, Sendable {
  let eventId: String
  let publicKey: String
  let createdAt: Date
  let createdAtTimestamp: Int64

  init(eventId: String, publicKey: String, createdAt: Date, createdAtTimestamp: Int64) {
    self.eventId = eventId
    self.publicKey = publicKey
    self.createdAt = createdAt
    self.createdAtTimestamp = createdAtTimestamp
  }

  init(repostEvent event: Event) {
    let timestamp = Int64(event.createdAt.timestamp)
    self.init(
      eventId: event.id,
      publicKey: event.publicKey,
      createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
      createdAtTimestamp: timestamp
    )
  }

  init(repost: RRepost) {
    self.init(
      eventId: repost.eventId,
      publicKey: repost.publicKey,
      createdAt: repost.createdAt,
      createdAtTimestamp: Int64(repost.createdAt.timeIntervalSince1970)
    )
  }
}

extension TextNoteFeedScope {
  func matches(_ item: FeedItem) -> Bool {
    matches(actorPublicKey: item.actorPublicKey, contentPublicKey: item.pubkey, content: item.content)
      || matchesFeedHashtags(item.hashtags)
  }

  private func matchesFeedHashtags(_ hashtags: [String]) -> Bool {
    let normalizedHashtags = Set(Self.normalizedTerms(hashtags))
    guard !normalizedHashtags.isEmpty else { return false }

    switch self {
    case .global:
      return true
    case .authors:
      return false
    case .terms, .verse:
      return !normalizedHashtags.isDisjoint(with: Set(relayHashtags))
    }
  }
}

// MARK: Event data module (temporal text note)
@Model
class RTextNote {
  @Attribute(.unique) var eventId: String
  var publicKey: String
  var content: String
  var createdAt: Date
  var userProfile: RUserProfile?
  var rootReply: RTextNote?
  var reply: RTextNote?
  var rootEventId: String = ""
  var replyEventId: String = ""
  var isSensitiveContent: Bool = false
  var sensitiveContentReason: String = ""
  var lastProfileFetchDate: Date?
  var taggedHashtagsText: String = ""

  init(
    eventId: String,
    publicKey: String,
    content: String,
    createdAt: Date,
    userProfile: RUserProfile? = nil,
    rootReply: RTextNote? = nil,
    reply: RTextNote? = nil,
    rootEventId: String = "",
    replyEventId: String = "",
    isSensitiveContent: Bool = false,
    sensitiveContentReason: String = "",
    lastProfileFetchDate: Date? = nil,
    taggedHashtagsText: String = ""
  ) {
    self.eventId = eventId
    self.publicKey = publicKey
    self.content = content
    self.createdAt = createdAt
    self.userProfile = userProfile
    self.rootReply = rootReply
    self.reply = reply
    self.rootEventId = rootEventId
    self.replyEventId = replyEventId
    self.isSensitiveContent = isSensitiveContent
    self.sensitiveContentReason = sensitiveContentReason
    self.lastProfileFetchDate = lastProfileFetchDate
    self.taggedHashtagsText = taggedHashtagsText
  }

  var taggedHashtags: [String] {
    taggedHashtagsText
      .components(separatedBy: " ")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
  }

  var sensitiveContentLabel: String {
    let trimmedReason = sensitiveContentReason.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedReason.isEmpty ? "Sensitive content" : trimmedReason
  }

  var contentFormatted: AttributedString? {
    guard !content.isEmpty else { return nil }
    return try? AttributedString(
      markdown: content,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )
  }

  // First image URL (kept for backwards compatibility)
  var imageUrl: URL? {
    imageUrls.first
  }

  // All image URLs detected in content
  var imageUrls: [URL] {
    guard let content = contentFormatted else { return [] }
    var urls: [URL] = []
    for run in content.runs {
      if let link = run.link {
        let absolute = link.absoluteURL
        if absolute.isImageType() {
          urls.append(absolute)
        }
      }
    }
    return urls
  }

  // First video URL (kept as-is)
  var videoUrl: URL? {
    guard let content = contentFormatted else { return nil }
    for run in content.runs {
      if let link = run.link, link.absoluteURL.isVideoType() {
        return link.absoluteURL
      }
    }
    return nil
  }

  // Content with image links removed, preserving other text/links
  var contentWithoutImageLinks: AttributedString? {
    guard let attributed = contentFormatted else { return nil }
    var result = AttributedString()
    for run in attributed.runs {
      // Each run represents a contiguous range of attributes and characters
      let slice = attributed[run.range]
      if let link = run.link, link.absoluteURL.isImageType() {
        // Skip runs that are image links
        continue
      } else {
        result.append(slice)
      }
    }
    return result
  }
}

@Model
class RRepost {
  @Attribute(.unique) var eventId: String
  var publicKey: String
  var createdAt: Date
  var targetEventId: String
  var targetPublicKey: String
  var userProfile: RUserProfile?
  var targetTextNote: RTextNote?

  init(
    eventId: String,
    publicKey: String,
    createdAt: Date,
    targetEventId: String,
    targetPublicKey: String,
    userProfile: RUserProfile? = nil,
    targetTextNote: RTextNote? = nil
  ) {
    self.eventId = eventId
    self.publicKey = publicKey
    self.createdAt = createdAt
    self.targetEventId = targetEventId
    self.targetPublicKey = targetPublicKey
    self.userProfile = userProfile
    self.targetTextNote = targetTextNote
  }
}

// MARK: Event data module
class TextNoteVM: ObservableObject {
  @Published var publicKey: String
  @Published var content: String
  @Published var createdAt: Date
  @Published var userProfile: RUserProfile?
  @Published var rootReply: RTextNote?
  @Published var reply: RTextNote?
  @Published var isSensitiveContent: Bool
  @Published var sensitiveContentReason: String

  init(from textNote: RTextNote) {
    self.publicKey = textNote.publicKey
    self.content = textNote.content
    self.createdAt = textNote.createdAt
    self.userProfile = textNote.userProfile
    self.rootReply = textNote.rootReply
    self.reply = textNote.reply
    self.isSensitiveContent = textNote.isSensitiveContent
    self.sensitiveContentReason = textNote.sensitiveContentReason
  }
}

extension RTextNote {
  static func create(with event: Event) -> RTextNote {
    let sensitiveWarning = contentWarning(from: event)
    let replyTargets = replyTargets(from: event)
    return RTextNote(
      eventId: event.id,
      publicKey: event.publicKey,
      content: event.content,
      createdAt: Date(timeIntervalSince1970: Double(event.createdAt.timestamp)),
      rootEventId: replyTargets.root,
      replyEventId: replyTargets.reply,
      isSensitiveContent: sensitiveWarning.isSensitive,
      sensitiveContentReason: sensitiveWarning.reason,
      taggedHashtagsText: hashtags(from: event).joined(separator: " ")
    )
  }

  static func hashtags(from event: Event) -> [String] {
    event.tags
      .filter { $0.id.lowercased() == "t" }
      .compactMap { $0.otherInformation.first?.lowercased() }
      .map { String($0.drop(while: { $0 == "#" })) }
      .filter { !$0.isEmpty }
      .uniqued()
  }

  private static func contentWarning(from event: Event) -> (isSensitive: Bool, reason: String) {
    guard let tag = event.tags.first(where: { $0.id.lowercased() == "content-warning" }) else {
      return (false, "")
    }

    let reason = tag.otherInformation.first?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    return (true, reason)
  }

  private static func replyTargets(from event: Event) -> (root: String, reply: String) {
    let eventTags = event.tags.filter { $0.id.lowercased() == "e" }
    guard !eventTags.isEmpty else { return ("", "") }

    let replyCandidateTags = eventTags.filter { !hasMarker("mention", in: $0) }
    guard !replyCandidateTags.isEmpty else { return ("", "") }

    let root = eventID(in: replyCandidateTags, marker: "root")
      ?? replyCandidateTags.first?.otherInformation.first ?? ""
    let reply = eventID(in: replyCandidateTags, marker: "reply")
      ?? replyCandidateTags.last?.otherInformation.first ?? root

    let normalizedRoot = root == event.id ? "" : root
    let normalizedReply = reply == event.id ? normalizedRoot : reply
    return (normalizedRoot, normalizedReply)
  }

  private static func eventID(in tags: [EventTag], marker: String) -> String? {
    tags.first {
      $0.otherInformation.dropFirst().contains { $0.lowercased() == marker }
    }?.otherInformation.first
  }

  private static func hasMarker(_ marker: String, in tag: EventTag) -> Bool {
    tag.otherInformation.dropFirst().contains { $0.lowercased() == marker }
  }
}

extension RRepost {
  static func create(with event: Event, targetTextNote: RTextNote? = nil) -> RRepost? {
    guard let targetEventId = targetEventID(from: event) else { return nil }
    let targetPublicKey = targetPublicKey(from: event) ?? targetTextNote?.publicKey ?? ""
    guard !targetPublicKey.isEmpty else { return nil }

    return RRepost(
      eventId: event.id,
      publicKey: event.publicKey,
      createdAt: Date(timeIntervalSince1970: Double(event.createdAt.timestamp)),
      targetEventId: targetEventId,
      targetPublicKey: targetPublicKey,
      targetTextNote: targetTextNote
    )
  }

  static func targetEventID(from event: Event) -> String? {
    event.tags.first { $0.id.lowercased() == "e" }?.otherInformation.first
  }

  static func targetPublicKey(from event: Event) -> String? {
    event.tags.first { $0.id.lowercased() == "p" }?.otherInformation.first
  }

  static func embeddedTextNoteEvent(from repostEvent: Event) -> Event? {
    guard let data = repostEvent.content.data(using: .utf8),
      let event = try? JSONDecoder().decode(Event.self, from: data),
      event.kind == .textNote
    else {
      return nil
    }

    return event
  }
}
