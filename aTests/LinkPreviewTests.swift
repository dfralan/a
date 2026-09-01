import XCTest
import NostrKit
@testable import a

final class LinkPreviewTests: XCTestCase {
  func testDetectsAnyWebLink() throws {
    let links = [
      "https://suno.com/s/kQeaXxP76ZiOUKda",
      "https://open.spotify.com/intl-es/track/04d5HIcQX6zH5MMqffXOon?si=share",
      "https://example.com/story?id=42&source=nostr#comments"
    ]

    for value in links {
      let url = try XCTUnwrap(URL(string: value))
      let descriptor = try XCTUnwrap(LinkPreviewDescriptor.detect(url: url))
      XCTAssertEqual(descriptor.sourceURL, url)
    }
  }

  func testRejectsNonWebLinks() throws {
    let links = [
      "nostr:note1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
      "mailto:hello@example.com",
      "file:///tmp/audio.mp3"
    ]

    for value in links {
      let url = try XCTUnwrap(URL(string: value))
      XCTAssertNil(LinkPreviewDescriptor.detect(url: url))
    }
  }

  func testSunoShareLinkCreatesAValidTextNoteEvent() throws {
    let content = "https://suno.com/s/kQeaXxP76ZiOUKda"
    let draft = NIP01.textNote(content: content)
    let privateKeyHex = String(repeating: "1", count: 64)

    let post = try PostEventContent(privateKeyHex: privateKeyHex, draft: draft)

    XCTAssertEqual(post.event.content, content)
    XCTAssertEqual(post.event.kind.integerValue, 1)
    XCTAssertEqual(post.event.id.count, 64)
    XCTAssertFalse(draft.nips.contains(.nip27))
  }

  func testRegularWebLinkCreatesAValidTextNoteEventWithoutRewritingTheURL() throws {
    let content = "Read this https://example.com/story?id=42&source=nostr#comments"
    let draft = NIP01.textNote(content: content)
    let privateKeyHex = String(repeating: "1", count: 64)

    let post = try PostEventContent(privateKeyHex: privateKeyHex, draft: draft)

    XCTAssertEqual(post.event.content, content)
    XCTAssertEqual(post.event.kind.integerValue, 1)
    XCTAssertEqual(post.event.id.count, 64)
    XCTAssertEqual(draft.tags.count, 0)
    XCTAssertNoThrow(try NostrEventFactory.validateEventSignature(post.event))
  }
}
