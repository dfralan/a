import Foundation
import NostrKit
import XCTest

@testable import a

final class ProfileSearchTests: XCTestCase {
  private let alicePublicKey = String(repeating: "a", count: 64)
  private let bobPublicKey = String(repeating: "b", count: 64)

  func testRelayQueryUsesNIP50ForTextAndAuthorFilterForExactKey() {
    let textQuery = ProfileSearchRelayQuery(mode: .text("Alice"), limit: 20)
    XCTAssertEqual(textQuery.search, "Alice")
    XCTAssertNil(textQuery.authors)
    XCTAssertEqual(textQuery.relayLimit, 20)

    let exactQuery = ProfileSearchRelayQuery(mode: .publicKey(alicePublicKey), limit: 20)
    XCTAssertNil(exactQuery.search)
    XCTAssertEqual(exactQuery.authors, [alicePublicKey])
    XCTAssertEqual(exactQuery.relayLimit, 1)
  }

  func testNewestMetadataWinsAndDuplicateRelayEventsAreRemoved() throws {
    let oldEvent = try metadataEvent(
      id: "1",
      publicKey: alicePublicKey,
      createdAt: 10,
      metadata: ["name": "Alice Old"]
    )
    let newEvent = try metadataEvent(
      id: "2",
      publicKey: alicePublicKey,
      createdAt: 20,
      metadata: ["name": "Alice New"]
    )

    let profiles = NostrProfileSearchRepository.process(
      events: [oldEvent, newEvent, newEvent],
      mode: .text("alice"),
      limit: 20
    )

    XCTAssertEqual(profiles.count, 1)
    XCTAssertEqual(profiles.first?.name, "Alice New")
    XCTAssertEqual(profiles.first?.createdAt, Date(timeIntervalSince1970: 20))
  }

  func testTextSearchDropsResultsThatDoNotMatchMetadata() throws {
    let unrelatedEvent = try metadataEvent(
      id: "3",
      publicKey: bobPublicKey,
      createdAt: 30,
      metadata: ["name": "Bob", "about": "Photography"]
    )

    let profiles = NostrProfileSearchRepository.process(
      events: [unrelatedEvent],
      mode: .text("alice"),
      limit: 20
    )

    XCTAssertTrue(profiles.isEmpty)
  }

  func testTextSearchMatchesMultipleTermsAcrossMetadataFields() throws {
    let event = try metadataEvent(
      id: "4",
      publicKey: alicePublicKey,
      createdAt: 40,
      metadata: [
        "display_name": "Alice",
        "about": "Protocol engineer",
        "nip05": "alice@example.com",
      ]
    )

    let profiles = NostrProfileSearchRepository.process(
      events: [event],
      mode: .text("alice engineer"),
      limit: 20
    )

    XCTAssertEqual(profiles.first?.name, "Alice")
    XCTAssertEqual(profiles.first?.nip05, "alice@example.com")
  }

  func testExactPublicKeyExcludesOtherAuthorsWithoutRequiringMetadataMatch() throws {
    let aliceEvent = try metadataEvent(
      id: "5",
      publicKey: alicePublicKey,
      createdAt: 50,
      metadata: ["name": "A"]
    )
    let bobEvent = try metadataEvent(
      id: "6",
      publicKey: bobPublicKey,
      createdAt: 60,
      metadata: ["name": "B"]
    )

    let profiles = NostrProfileSearchRepository.process(
      events: [bobEvent, aliceEvent],
      mode: .publicKey(alicePublicKey),
      limit: 20
    )

    XCTAssertEqual(profiles.map(\.publicKey), [alicePublicKey])
  }

  func testMalformedMetadataAndNonProfileEventsAreIgnored() throws {
    let malformed = try rawEvent(
      id: "7",
      publicKey: alicePublicKey,
      createdAt: 70,
      kind: 0,
      content: "not-json"
    )
    let textNote = try rawEvent(
      id: "8",
      publicKey: alicePublicKey,
      createdAt: 80,
      kind: 1,
      content: "alice"
    )

    let profiles = NostrProfileSearchRepository.process(
      events: [malformed, textNote],
      mode: .text("alice"),
      limit: 20
    )

    XCTAssertTrue(profiles.isEmpty)
  }

  func testRequestCancellationIsIdempotent() {
    var cancellationCount = 0
    let request = ProfileSearchRequest {
      cancellationCount += 1
    }

    request.cancel()
    request.cancel()

    XCTAssertEqual(cancellationCount, 1)
  }

  private func metadataEvent(
    id: Character,
    publicKey: String,
    createdAt: Int,
    metadata: [String: String]
  ) throws -> Event {
    let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    let content = try XCTUnwrap(String(data: data, encoding: .utf8))
    return try rawEvent(
      id: id,
      publicKey: publicKey,
      createdAt: createdAt,
      kind: 0,
      content: content
    )
  }

  private func rawEvent(
    id: Character,
    publicKey: String,
    createdAt: Int,
    kind: Int,
    content: String
  ) throws -> Event {
    let object: [String: Any] = [
      "id": String(repeating: id, count: 64),
      "pubkey": publicKey,
      "created_at": createdAt,
      "kind": kind,
      "tags": [],
      "content": content,
      "sig": String(repeating: "0", count: 128),
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try JSONDecoder().decode(Event.self, from: data)
  }
}

final class NIP05VerificationTests: XCTestCase {
  func testIdentifierParsingNormalizesAndBuildsCanonicalURL() throws {
    let identifier = try XCTUnwrap(NIP05.parse(" Alice@Example.COM "))

    XCTAssertEqual(identifier.name, "alice")
    XCTAssertEqual(identifier.domain, "example.com")
    XCTAssertEqual(
      identifier.url?.absoluteString,
      "https://example.com/.well-known/nostr.json?name=alice"
    )
  }

  func testVerifiedResultUsesDailyRefreshWindow() {
    let now = Date(timeIntervalSince1970: 1_000_000)

    XCTAssertFalse(
      NIP05VerificationPolicy.shouldRefresh(
        status: .verified,
        lastCheckedAt: now.addingTimeInterval(-60),
        now: now
      )
    )
    XCTAssertTrue(
      NIP05VerificationPolicy.shouldRefresh(
        status: .verified,
        lastCheckedAt: now.addingTimeInterval(-NIP05VerificationPolicy.verifiedRefreshInterval),
        now: now
      )
    )
  }

  func testInvalidResultRetriesSoonerThanVerifiedResult() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let lastCheckedAt = now.addingTimeInterval(-NIP05VerificationPolicy.invalidRefreshInterval)

    XCTAssertTrue(
      NIP05VerificationPolicy.shouldRefresh(
        status: .invalid,
        lastCheckedAt: lastCheckedAt,
        now: now
      )
    )
    XCTAssertFalse(
      NIP05VerificationPolicy.shouldRefresh(
        status: .verified,
        lastCheckedAt: lastCheckedAt,
        now: now
      )
    )
  }

  func testUncheckedAndMissingDatesAlwaysRefresh() {
    let now = Date(timeIntervalSince1970: 1_000_000)

    XCTAssertTrue(
      NIP05VerificationPolicy.shouldRefresh(
        status: .unchecked,
        lastCheckedAt: now,
        now: now
      )
    )
    XCTAssertTrue(
      NIP05VerificationPolicy.shouldRefresh(
        status: .verified,
        lastCheckedAt: nil,
        now: now
      )
    )
  }
}
