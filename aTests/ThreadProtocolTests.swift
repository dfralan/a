import XCTest
import NostrKit
@testable import a

final class ThreadProtocolTests: XCTestCase {
  private let rootID = String(repeating: "a", count: 64)
  private let parentID = String(repeating: "b", count: 64)
  private let rootAuthor = String(repeating: "c", count: 64)
  private let parentAuthor = String(repeating: "d", count: 64)

  func testNIP10DirectReplyUsesOnlyRootMarker() throws {
    let root = ThreadReference.event(
      id: rootID,
      kind: 1,
      publicKey: rootAuthor,
      relayHints: ["wss://relay.example"]
    )
    let draft = try NIP10ThreadStrategy().makeReplyDraft(
      content: "Direct reply",
      target: ThreadTarget(focused: root),
      parseProfileMentions: false
    )

    XCTAssertEqual(draft.kind.integerValue, 1)
    XCTAssertEqual(eventTags(in: draft).count, 1)
    XCTAssertEqual(eventTags(in: draft).first?.otherInformation[safe: 2], "root")
    XCTAssertEqual(eventTags(in: draft).first?.otherInformation[safe: 3], rootAuthor)
  }

  func testNIP10NestedReplyKeepsRootAndImmediateParent() throws {
    let root = ThreadReference.event(
      id: rootID,
      kind: 1,
      publicKey: rootAuthor,
      relayHints: []
    )
    let parent = ThreadReference.event(
      id: parentID,
      kind: 1,
      publicKey: parentAuthor,
      relayHints: []
    )
    let target = ThreadTarget(
      focused: parent,
      root: root,
      commentProtocol: .nip10,
      participantPublicKeys: [rootAuthor, parentAuthor]
    )
    let draft = try NIP10ThreadStrategy().makeReplyDraft(
      content: "Nested reply",
      target: target,
      parseProfileMentions: false
    )

    let references = eventTags(in: draft)
    XCTAssertEqual(references.count, 2)
    XCTAssertEqual(references[0].otherInformation[safe: 0], rootID)
    XCTAssertEqual(references[0].otherInformation[safe: 2], "root")
    XCTAssertEqual(references[1].otherInformation[safe: 0], parentID)
    XCTAssertEqual(references[1].otherInformation[safe: 2], "reply")
    XCTAssertEqual(Set(publicKeyTags(in: draft)), [rootAuthor, parentAuthor])
  }

  func testNIP22DirectEventCommentUsesUppercaseRootAndLowercaseParent() throws {
    let root = ThreadReference.event(
      id: rootID,
      kind: 1063,
      publicKey: rootAuthor,
      relayHints: ["wss://relay.example"]
    )
    let draft = try NIP22ThreadStrategy().makeReplyDraft(
      content: "File comment",
      target: ThreadTarget(focused: root),
      parseProfileMentions: false
    )

    XCTAssertEqual(draft.kind.integerValue, 1111)
    XCTAssertEqual(tagValue("E", in: draft), rootID)
    XCTAssertEqual(tagValue("K", in: draft), "1063")
    XCTAssertEqual(tagValue("P", in: draft), rootAuthor)
    XCTAssertEqual(tagValue("e", in: draft), rootID)
    XCTAssertEqual(tagValue("k", in: draft), "1063")
    XCTAssertEqual(tagValue("p", in: draft), rootAuthor)
    XCTAssertTrue(draft.nips.contains(.nip22))
    XCTAssertFalse(draft.nips.contains(.nip10))
  }

  func testNIP22NestedReplyPreservesRootAndTargetsCommentParent() throws {
    let root = ThreadReference.event(
      id: rootID,
      kind: 1063,
      publicKey: rootAuthor,
      relayHints: []
    )
    let parent = ThreadReference.event(
      id: parentID,
      kind: 1111,
      publicKey: parentAuthor,
      relayHints: []
    )
    let target = ThreadTarget(
      focused: parent,
      root: root,
      commentProtocol: .nip22,
      participantPublicKeys: [rootAuthor, parentAuthor]
    )
    let draft = try NIP22ThreadStrategy().makeReplyDraft(
      content: "Nested comment",
      target: target,
      parseProfileMentions: false
    )

    XCTAssertEqual(draft.kind.integerValue, 1111)
    XCTAssertEqual(tagValue("E", in: draft), rootID)
    XCTAssertEqual(tagValue("K", in: draft), "1063")
    XCTAssertEqual(tagValue("e", in: draft), parentID)
    XCTAssertEqual(tagValue("k", in: draft), "1111")
    XCTAssertEqual(tagValue("p", in: draft), parentAuthor)
  }

  func testNIP22AddressAndExternalTargetsUseTheirNativeReferences() throws {
    let coordinate = "30023:\(rootAuthor):article"
    let address = ThreadReference.address(
      coordinate: coordinate,
      eventID: rootID,
      kind: 30023,
      publicKey: rootAuthor,
      relayHints: []
    )
    let addressDraft = try NIP22ThreadStrategy().makeReplyDraft(
      content: "Article comment",
      target: ThreadTarget(focused: address),
      parseProfileMentions: false
    )

    XCTAssertEqual(tagValue("A", in: addressDraft), coordinate)
    XCTAssertEqual(tagValue("a", in: addressDraft), coordinate)
    XCTAssertEqual(tagValue("e", in: addressDraft), rootID)
    XCTAssertEqual(tagValue("K", in: addressDraft), "30023")

    let external = ThreadReference.external(
      identifier: "https://example.com/article",
      kind: "web",
      hints: []
    )
    let externalDraft = try NIP22ThreadStrategy().makeReplyDraft(
      content: "Web comment",
      target: ThreadTarget(focused: external),
      parseProfileMentions: false
    )

    XCTAssertEqual(tagValue("I", in: externalDraft), "https://example.com/article")
    XCTAssertEqual(tagValue("i", in: externalDraft), "https://example.com/article")
    XCTAssertEqual(tagValue("K", in: externalDraft), "web")
    XCTAssertEqual(tagValue("k", in: externalDraft), "web")
  }

  func testProtocolSelectionIsDeterministic() {
    let textNote = ThreadTarget(
      focused: .event(id: rootID, kind: 1, publicKey: nil, relayHints: [])
    )
    let file = ThreadTarget(
      focused: .event(id: rootID, kind: 1063, publicKey: nil, relayHints: [])
    )

    XCTAssertEqual(ThreadProtocolStrategies.strategy(for: textNote).protocolKind, .nip10)
    XCTAssertEqual(ThreadProtocolStrategies.strategy(for: file).protocolKind, .nip22)
  }

  func testActivityClassifiesNIP10DirectReply() throws {
    let root = ThreadReference.event(
      id: rootID,
      kind: 1,
      publicKey: rootAuthor,
      relayHints: []
    )
    let event = try signedEvent(
      from: NIP10ThreadStrategy().makeReplyDraft(
        content: "Direct reply",
        target: ThreadTarget(focused: root),
        parseProfileMentions: false
      )
    )
    let item = try XCTUnwrap(
      ActivityItem(event: event, targetPublicKey: rootAuthor)
    )

    XCTAssertEqual(item.kind, .reply)
    XCTAssertEqual(item.relatedEventID, event.id)
    guard case .event(let reference) = item.route else {
      return XCTFail("Reply activity should navigate to its event")
    }
    XCTAssertEqual(reference.id, event.id)
    XCTAssertEqual(reference.kind, 1)
  }

  func testExplicitMentionWinsOverReplyForNIP22Comment() throws {
    let root = ThreadReference.event(
      id: rootID,
      kind: 1063,
      publicKey: rootAuthor,
      relayHints: []
    )
    let mention = try XCTUnwrap(bech32_pubkey(rootAuthor))
    let event = try signedEvent(
      from: NIP22ThreadStrategy().makeReplyDraft(
        content: "Hey @\(mention)",
        target: ThreadTarget(focused: root),
        parseProfileMentions: true
      )
    )
    let item = try XCTUnwrap(
      ActivityItem(event: event, targetPublicKey: rootAuthor)
    )

    XCTAssertEqual(item.kind, .mention)
    XCTAssertEqual(item.relatedEventKind, 1111)
  }

  func testInheritedParticipantTagIsNotMisclassifiedAsMentionOrReply() throws {
    let root = ThreadReference.event(
      id: rootID,
      kind: 1,
      publicKey: rootAuthor,
      relayHints: []
    )
    let parent = ThreadReference.event(
      id: parentID,
      kind: 1,
      publicKey: parentAuthor,
      relayHints: []
    )
    let event = try signedEvent(
      from: NIP10ThreadStrategy().makeReplyDraft(
        content: "Replying only to the parent",
        target: ThreadTarget(
          focused: parent,
          root: root,
          commentProtocol: .nip10,
          participantPublicKeys: [rootAuthor, parentAuthor]
        ),
        parseProfileMentions: false
      )
    )

    XCTAssertNil(ActivityItem(event: event, targetPublicKey: rootAuthor))
    XCTAssertEqual(
      ActivityItem(event: event, targetPublicKey: parentAuthor)?.kind,
      .reply
    )
  }

  func testRepositoryPageDeduplicatesRelaysAndKeepsOnlyDirectChildren() throws {
    let root = ThreadReference.event(
      id: rootID,
      kind: 1,
      publicKey: rootAuthor,
      relayHints: []
    )
    let target = ThreadTarget(focused: root)
    let directEvent = try signedEvent(
      from: NIP10ThreadStrategy().makeReplyDraft(
        content: "Direct",
        target: target,
        parseProfileMentions: false
      )
    )
    let directItem = try XCTUnwrap(ThreadItem(event: directEvent))
    let nestedTarget = ThreadTarget(item: directItem)
    let nestedEvent = try signedEvent(
      from: NIP10ThreadStrategy().makeReplyDraft(
        content: "Nested",
        target: nestedTarget,
        parseProfileMentions: false
      )
    )

    let processed = NostrThreadRepository.processRelayPage(
      events: [directEvent, directEvent, nestedEvent],
      relayCounts: [2, 1],
      target: target,
      cursor: nil,
      limit: 10,
      rawPageSize: 40
    )

    XCTAssertEqual(Set(processed.parsedItems.map(\.id)), [directEvent.id, nestedEvent.id])
    XCTAssertEqual(processed.directItems.map(\.id), [directEvent.id])
    XCTAssertTrue(processed.rawExhausted)
  }

  func testRepositoryDescendantOnlyPageAdvancesWithoutFalseExhaustion() throws {
    let root = ThreadReference.event(
      id: rootID,
      kind: 1063,
      publicKey: rootAuthor,
      relayHints: []
    )
    let directEvent = try signedEvent(
      from: NIP22ThreadStrategy().makeReplyDraft(
        content: "Direct",
        target: ThreadTarget(focused: root),
        parseProfileMentions: false
      )
    )
    let directItem = try XCTUnwrap(ThreadItem(event: directEvent))
    let nestedEvent = try signedEvent(
      from: NIP22ThreadStrategy().makeReplyDraft(
        content: "Nested",
        target: ThreadTarget(item: directItem),
        parseProfileMentions: false
      )
    )

    let processed = NostrThreadRepository.processRelayPage(
      events: [nestedEvent],
      relayCounts: [40],
      target: ThreadTarget(focused: root),
      cursor: nil,
      limit: 10,
      rawPageSize: 40
    )

    XCTAssertTrue(processed.directItems.isEmpty)
    XCTAssertNotNil(processed.nextCursor)
    XCTAssertFalse(processed.rawExhausted)
  }

  private func eventTags(in draft: NostrWriteEventDraft) -> [EventTag] {
    draft.tags.filter { $0.id == "e" }
  }

  private func publicKeyTags(in draft: NostrWriteEventDraft) -> [String] {
    draft.tags
      .filter { $0.id == "p" }
      .compactMap { $0.otherInformation.first }
  }

  private func tagValue(_ id: String, in draft: NostrWriteEventDraft) -> String? {
    draft.tags.first { $0.id == id }?.otherInformation.first
  }

  private func signedEvent(from draft: NostrWriteEventDraft) throws -> Event {
    let privateKeyHex = String(repeating: "1", count: 64)
    return try PostEventContent(privateKeyHex: privateKeyHex, draft: draft).event
  }
}

@MainActor
final class ThreadControllerTests: XCTestCase {
  func testControllerDeduplicatesPagesAndGuardsConcurrentLoads() async {
    let target = ThreadTarget(
      focused: .event(
        id: String(repeating: "a", count: 64),
        kind: 1,
        publicKey: String(repeating: "b", count: 64),
        relayHints: []
      )
    )
    let repository = ThreadRepositorySpy()
    let controller = ThreadController(target: target)

    controller.start(repository: repository)
    XCTAssertEqual(repository.replyFetchCount, 1)

    controller.loadOlderReplies()
    XCTAssertEqual(repository.replyFetchCount, 1)

    repository.completeReplies(
      with: ThreadPage(items: [makeItem(id: "first", target: target)], cursor: ThreadCursor(until: 9), exhausted: false)
    )
    await Task.yield()
    controller.loadOlderReplies()
    controller.loadOlderReplies()
    XCTAssertEqual(repository.replyFetchCount, 2)

    repository.completeReplies(
      with: ThreadPage(
        items: [makeItem(id: "first", target: target), makeItem(id: "second", target: target)],
        cursor: ThreadCursor(until: 8),
        exhausted: true
      )
    )
    await Task.yield()

    XCTAssertEqual(controller.directReplies.map(\.id), ["first", "second"])
    XCTAssertTrue(controller.hasReachedReplyEnd)
  }

  func testControllerCancelsOutstandingRepositoryRequests() {
    let target = ThreadTarget(
      focused: .event(id: "root", kind: 1, publicKey: nil, relayHints: [])
    )
    let repository = ThreadRepositorySpy()
    let controller = ThreadController(target: target)

    controller.start(repository: repository)
    controller.cancel()

    XCTAssertEqual(repository.cancelCount, 2)
  }

  private func makeItem(id: String, target: ThreadTarget) -> ThreadItem {
    let reference = ThreadReference.event(
      id: id,
      kind: 1,
      publicKey: "author",
      relayHints: []
    )
    return ThreadItem(
      id: id,
      reference: reference,
      root: target.root,
      parent: target.focused,
      commentProtocol: .nip10,
      publicKey: "author",
      kind: 1,
      createdAt: Date(timeIntervalSince1970: id == "first" ? 1 : 2),
      content: id,
      tags: [],
      participantPublicKeys: [],
      isSensitiveContent: false,
      sensitiveContentReason: "",
      rawEventJSON: nil
    )
  }
}

private final class ThreadRepositorySpy: ThreadRepositoryProtocol {
  private(set) var replyFetchCount = 0
  private(set) var cancelCount = 0
  private var replyCompletions: [(Result<ThreadPage<ThreadItem>, Error>) -> Void] = []

  func cachedFocusedItem(for target: ThreadTarget) -> ThreadItem? { nil }
  func cachedReplies(for target: ThreadTarget, limit: Int) -> [ThreadItem] { [] }

  @MainActor
  func persistPublishedEvent(_ event: Event) -> ThreadItem? { nil }

  func fetchFocusedItem(
    for target: ThreadTarget,
    completion: @escaping (Result<ThreadItem?, Error>) -> Void
  ) -> ThreadRequest {
    ThreadRequest { [weak self] in self?.cancelCount += 1 }
  }

  func fetchReplyPage(
    for target: ThreadTarget,
    cursor: ThreadCursor?,
    limit: Int,
    completion: @escaping (Result<ThreadPage<ThreadItem>, Error>) -> Void
  ) -> ThreadRequest {
    replyFetchCount += 1
    replyCompletions.append(completion)
    return ThreadRequest { [weak self] in self?.cancelCount += 1 }
  }

  func completeReplies(with page: ThreadPage<ThreadItem>) {
    replyCompletions.removeFirst()(.success(page))
  }
}

private extension Collection {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
