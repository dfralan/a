import Foundation
import XCTest

@testable import a

final class HomeFeedBackpressureTests: XCTestCase {
  func testCapacitySaturatesOnceAndDropsHomeOnlyOverflow() {
    let admission = HomeLiveEventAdmission(capacity: 3, refreshCapacity: 2)
    _ = admission.activate()

    XCTAssertEqual(admit("a", at: 1, to: admission), .collectBacklog)
    XCTAssertEqual(admit("b", at: 2, to: admission), .collectBacklog)

    let capacityResult = admission.admit(eventID: "c", createdAt: 3, item: item("c", at: 3))
    XCTAssertEqual(capacityResult.decision, .collectBacklog)
    XCTAssertEqual(capacityResult.snapshot.state, .saturated(displayCount: 3))
    XCTAssertEqual(capacityResult.snapshot.pendingCount, 3)

    let overflowResult = admission.admit(eventID: "d", createdAt: 4, item: item("d", at: 4))
    XCTAssertEqual(overflowResult.decision, .dropSaturated)
    XCTAssertFalse(overflowResult.shouldNotifyObservers)
    XCTAssertEqual(overflowResult.snapshot.state, .saturated(displayCount: 3))
    XCTAssertEqual(overflowResult.snapshot.pendingCount, 3)
    XCTAssertEqual(overflowResult.snapshot.latestObservedCursor, 4)
  }

  func testDuplicateRelayDeliveryDoesNotConsumeCapacity() {
    let admission = HomeLiveEventAdmission(capacity: 2, refreshCapacity: 2)
    _ = admission.activate()

    XCTAssertEqual(admit("same", at: 1, to: admission), .collectBacklog)
    let duplicate = admission.admit(eventID: "same", createdAt: 1, item: item("same", at: 1))
    XCTAssertEqual(duplicate.decision, .dropDuplicate)
    XCTAssertFalse(duplicate.shouldNotifyObservers)
    XCTAssertEqual(admission.snapshot().pendingCount, 1)
    XCTAssertEqual(admit("other", at: 2, to: admission), .collectBacklog)
    XCTAssertEqual(admission.snapshot().state, .saturated(displayCount: 2))
  }

  func testInactiveHomeDropsCandidateAndRequestsBoundedRebase() {
    let admission = HomeLiveEventAdmission(capacity: 3, refreshCapacity: 2)

    let result = admission.admit(eventID: "a", createdAt: 10, item: item("a", at: 10))
    XCTAssertEqual(result.decision, .dropInactive)
    XCTAssertEqual(result.snapshot.pendingCount, 0)
    XCTAssertEqual(result.snapshot.latestObservedCursor, 10)

    let activation = admission.activate()
    XCTAssertTrue(activation.needsRebase)
    XCTAssertEqual(activation.snapshot.state, .inactive(needsRebase: true))
  }

  func testLatestRefreshMergesOnlyBoundedHandoffAndResetsBacklog() {
    let admission = HomeLiveEventAdmission(capacity: 2, refreshCapacity: 2)
    _ = admission.activate()
    XCTAssertEqual(admit("old-a", at: 1, to: admission), .collectBacklog)
    XCTAssertEqual(admit("old-b", at: 2, to: admission), .collectBacklog)

    XCTAssertEqual(admission.beginRefresh().state, .refreshing)
    XCTAssertEqual(admit("live-a", at: 12, to: admission), .collectRefreshHandoff)
    XCTAssertEqual(admit("live-b", at: 11, to: admission), .collectRefreshHandoff)
    XCTAssertEqual(admit("live-c", at: 13, to: admission), .dropSaturated)

    let completed = admission.completeRefresh(
      pageItems: [item("page", at: 10), item("live-a", at: 12)],
      newestCursor: 12
    )

    XCTAssertEqual(completed.items.map(\.id), ["live-a", "live-b", "page"])
    XCTAssertEqual(completed.snapshot.state, .collecting)
    XCTAssertEqual(completed.snapshot.pendingCount, 0)
    XCTAssertEqual(completed.snapshot.latestObservedCursor, 13)
  }

  func testMemoryWarningDropsBacklogButRetainsScalarCursorForRebase() {
    let admission = HomeLiveEventAdmission(capacity: 3, refreshCapacity: 2)
    _ = admission.activate()
    XCTAssertEqual(admit("a", at: 10, to: admission), .collectBacklog)
    XCTAssertEqual(admit("b", at: 12, to: admission), .collectBacklog)

    let snapshot = admission.handleMemoryWarning()

    XCTAssertEqual(snapshot.state, .inactive(needsRebase: true))
    XCTAssertEqual(snapshot.pendingCount, 0)
    XCTAssertEqual(snapshot.latestObservedCursor, 12)
    XCTAssertTrue(admission.activate().needsRebase)
  }

  func testInactiveHomeRequiresBoundedRebaseAfterStaleInterval() {
    let admission = HomeLiveEventAdmission(
      capacity: 3,
      refreshCapacity: 2,
      staleInterval: 300
    )
    let departure = Date(timeIntervalSince1970: 1_000)
    _ = admission.activate(now: departure)
    _ = admission.deactivate(now: departure)

    XCTAssertFalse(
      admission.activate(now: departure.addingTimeInterval(299)).needsRebase
    )

    _ = admission.deactivate(now: departure)
    XCTAssertTrue(
      admission.activate(now: departure.addingTimeInterval(300)).needsRebase
    )
  }

  private func admit(
    _ eventID: String,
    at timestamp: Int64,
    to admission: HomeLiveEventAdmission
  ) -> HomeLiveAdmissionDecision {
    admission.admit(
      eventID: eventID,
      createdAt: timestamp,
      item: item(eventID, at: timestamp)
    ).decision
  }

  private func item(_ id: String, at timestamp: Int64) -> FeedItem {
    FeedItem(
      id: id,
      pubkey: "pubkey",
      createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
      createdAtTimestamp: timestamp,
      content: id,
      tags: [],
      replyTo: nil,
      rootEventId: nil,
      hashtags: [],
      isSensitiveContent: false,
      sensitiveContentReason: ""
    )
  }
}
