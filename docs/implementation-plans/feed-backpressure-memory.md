# Feed Backpressure and Memory Recovery

Status: Implemented through native memory recovery (Phases 1-6) on 2026-08-28.

Implementation notes:

- Home saturation, bounded latest rebase, stale-session rebase, immutable feed pages, serialized off-main relay persistence, card/media budgets, and native memory-warning recovery are active.
- Per-card comment network subscriptions were removed. Existing bounded local engagement queries remain until engagement presentation is moved app-wide; Home no longer creates one relay request per mounted card.
- Automatic `RTextNote`/`RRepost` deletion remains intentionally disabled. Profile and thread destinations still have SwiftData-backed paths, so enabling retention before protected-ID ownership is complete could invalidate a model being rendered. This gate is part of the design, not a cache-growth workaround.
- The full simulator test suite passes. Instruments/device profiling and protected-ID persistent retention remain the follow-up verification phase.

## 1. Objective

Keep Home responsive during long live sessions, relay bursts, deep scrolling, media-heavy feeds, and foreground/background transitions.

The solution must:

- cap the new-post toast at `99+` and stop Home live backlog collection once its backlog reaches 100 unique events;
- keep global relay ingestion, routing, DMs, notifications, profiles, explicit event lookups, and older-page requests working while Home backlog collection is saturated;
- refresh Home from a bounded latest page instead of replaying an arbitrarily large gap;
- establish deterministic budgets for visible cards, parsed event content, image decoding, media prefetch, subscriptions, and persistence;
- react to the native iOS memory-warning signal by releasing evictable memory;
- preserve keys, relays, conversations, and persisted cache during automatic recovery;
- move relay persistence and maintenance off the main actor;
- avoid SwiftData model invalidation while a view is rendering.

This is runtime resource management, not a user-visible data wipe.

## 2. Product Decisions

### 2.1 New-event backlog

Recommended behavior:

- Count unique new Home events up to 100.
- Display `1...99`, then `99+` at capacity.
- At 100, transition the Home live consumer from `collecting` to `saturated` exactly once.
- Keep relay WebSockets and all existing subscriptions active. Saturation must not unsubscribe, pause, disconnect, or recreate relay work.
- Stop admitting additional Home-only candidates to Home's backlog, temporary buffers, timers, or persistence path.
- Continue processing the event through every applicable non-Home consumer before applying the Home-specific drop.
- Advance only a bounded scalar `latestObservedCursor` for Home so saturation cannot create an ID backlog or an unbounded cursor gap to replay.
- Do not increment the backlog beyond 100 and do not retain identifiers for events 101+.

An event rejected by Home can still be relevant to DMs, mentions, replies, reactions, notifications, metadata/profile updates, thread requests, or another active subscription. Saturation is therefore a Home-consumer admission rule, never an early guard in relay ingestion or shared persistence.

The toast remains actionable while saturated.

### 2.2 Tapping `99+`

Tapping the toast is a bounded rebase, not a replay of 100 events:

1. Move Home from `saturated` to `refreshing`; relay ingestion and subscriptions remain unchanged.
2. Show the latest-page skeleton state.
3. Request the latest 12 events for the active `FeedScope` with a finite relay limit.
4. Merge and deduplicate relay results as immutable `FeedItem` values.
5. Replace the visible Home window with those latest items.
6. Persist the page as a cache side effect.
7. Atomically commit the latest page and a bounded set of live arrivals observed during that refresh generation.
8. Set Home's semantic cursor to the newest committed timestamp, clear the old backlog, and return its consumer to `collecting`.
9. Scroll to the feed top.

If the latest request fails, keep the existing feed and `99+` toast, expose retry feedback, and keep rejecting additional Home backlog entries. Global relay processing remains active throughout.

### 2.3 Memory recovery

Do not call `wipeLocalDataPreservingKeysAndRelays()` automatically. A full SwiftData deletion under memory pressure can:

- increase peak memory and database churn;
- invalidate models still observed by SwiftUI;
- destroy useful offline state;
- create a blank-screen/network dependency at the worst possible time.

Use a soft feed reset instead:

- stop Home live backlog collection without changing relay connections or non-Home consumers;
- cancel Home media prefetch and obsolete Home page requests;
- release offscreen event-card state and video players;
- clear only in-memory render and image caches;
- shrink the retained Home window around the current visible anchor;
- mark the Home session as requiring a latest-page rebase;
- rebase when the user returns to the top, taps the toast, or re-enters Home.

Keys, relays, DMs, notifications, watchers, and the persistent cache remain untouched.

### 2.4 Fixed memory thresholds

Do not poll a single hard MB threshold as a kill switch. The iOS jetsam budget varies by device, OS state, foreground conditions, extensions, and loaded frameworks.

Use two controls:

1. Proactive, deterministic resource budgets that prevent unbounded growth.
2. `UIApplication.didReceiveMemoryWarningNotification` as the native emergency signal when SwiftUI has no equivalent API.

The UIKit notification must be isolated in the app lifecycle/resource layer. It must not leak UIKit state into feed presentation code.

## 3. Current-State Diagnosis

### 3.1 The toast is visually capped, but ingestion is not

`HomeFeedController` already has:

```swift
private let maximumPendingNewerNotes = 100
```

It appends, sorts, recreates an array prefix, and rebuilds an ID set whenever persisted events arrive. Once it reaches 100, the toast says `99+`, but:

- relay Home subscriptions remain active;
- relay events continue to enter the write buffers;
- SwiftData continues to dedupe, insert, save, and notify;
- Home continues to receive callbacks and repeat sort/truncate work.

The existing limit bounds one array. It does not provide consumer-specific backpressure.

The transport already identifies Home live events by subscription purpose. However, `NostrEventIngestionGate` currently deduplicates globally. Purpose-specific routing must happen before shared persistence dedupe; otherwise a Home event can claim the global ID and unintentionally suppress later processing by Activity, Threads, Notifications, or another consumer.

### 3.2 Relay persistence runs on the main thread

`NostrRelay.flushPendingEvents()` explicitly dispatches to the main queue and then performs:

- profile upserts;
- per-event existence fetches;
- text-note/repost/reaction inserts;
- SwiftData saves;
- retention checks;
- observer fan-out.

This work competes directly with scrolling, animation, navigation, and image rendering. A bounded buffer prevents infinite queue growth, but a 24-event write batch can still create visible hitches.

### 3.3 Event cards multiply live work

Every mounted `EventView` owns multiple SwiftData queries for reactions, reposts, comments, thread replies, author profile, and reposter profile.

It also starts `fetchReplyPage(limit: 12)` from `onAppear` to discover comment counts. With multiple cards and relays, this can produce a large subscription/query fan-out even though the feed window itself is bounded.

### 3.4 Render and media budgets are too generous

Current behavior includes:

- `maximumVisibleItems = 24`;
- `EventRenderCache.countLimit = 600` with no explicit total-cost limit;
- prefetching up to 12 media URLs;
- `.cacheOriginalImage()` for feed images, avatars, and fullscreen images;
- no feed-sized downsampling processor before decoding/caching.

Full-resolution source images can dominate the process footprint even when their rendered frames are small.

### 3.5 Persistent text-note pruning is disabled

`pruneStoredTextNotes` and `pruneStoredReposts` are intentionally no-ops because deleting rows previously invalidated SwiftData models held by views.

That protected correctness, but it means the cache can grow indefinitely. Retention must only return after the UI boundary stops retaining live persistence models and maintenance can protect currently referenced IDs.

## 4. Architecture

```text
Relay message + subscription purpose
          |
          v
Existing purpose-specific routing
          |
          +----------------------> Non-Home consumers
          |                         DMs / activity / threads /
          |                         reactions / profiles / lookups
          |
          v
HomeLiveConsumer  collecting -> saturated -> refreshing -> collecting
          |              |                              |
          |              +-- drop for Home only         +-- bounded latest page
          |                  and advance scalar cursor
          v
RelayIngestionActor
  - persistence dedupe after consumer routing
  - bounded write batches
  - SwiftData side-effect cache
  - immutable persisted summaries
          |
          +---------------------> SwiftData cache maintenance
          |
          v
HomeFeedController
  - bounded visible window
  - bounded pending state
  - semantic latest/older cursors
          |
          v
HomeView / EventCard values

iOS memory warning
          |
          v
AppMemoryRecovery
  - stop Home backlog collection
  - cancel prefetch/obsolete requests
  - purge in-memory render/image caches
  - shrink Home window
  - request latest rebase on next demand
```

### 4.1 Home live collection state

Use explicit semantic state rather than independent booleans:

```swift
enum HomeLiveCollectionState: Equatable, Sendable {
  case inactive(needsRebase: Bool)
  case collecting
  case saturated(displayCount: Int)
  case refreshing
  case refreshFailed
}
```

Required transitions:

```text
Home appears + network available     inactive -> collecting
100 unique newer events              collecting -> saturated(100)
toast / pull to latest               saturated -> refreshing
latest page succeeds                 refreshing -> collecting
latest page fails                    refreshing -> refreshFailed
retry                                refreshFailed -> refreshing
Home disappears                      any -> inactive
memory warning                       collecting/saturated -> inactive(needsRebase: true)
scope or active key changes          reset -> refreshing -> collecting
```

These transitions never subscribe, unsubscribe, disconnect, or recreate relay connections. Admission is idempotent: once capacity is reached, additional Home-only candidates are constant-memory no-ops except for advancing the scalar observed cursor.

### 4.2 Backlog representation

`pendingNewer` is not consumed by the latest refresh; `refreshToLatest()` currently refetches from cache. Do not retain 100 complete `FeedItem` values only to display a count.

Recommended representation:

```swift
struct NewerBacklog: Sendable {
  let capacity = 100
  private(set) var eventIDs: Set<String>
  private(set) var isSaturated: Bool
}
```

It owns only unique IDs and count semantics. At capacity it rejects additions without sorting or reallocating full event arrays.

### 4.3 Purpose-specific Home admission

Use the existing subscription-purpose identity and add a small Home-specific admission policy at the `NostrData`/Home-consumer boundary:

```swift
enum HomeLiveAdmissionDecision: Sendable {
  case collectBacklog
  case collectRefreshHandoff
  case dropSaturated
  case dropInactive
}

func admitHomeLiveEvent(id: String, createdAt: Int64) -> HomeLiveAdmissionDecision
func fetchLatestFeedPage(scope: FeedScope, limit: Int) async -> FeedPage<FeedItem>
```

The state is owned by the Home consumer/controller. `NostrRelay` consults it only in the branch already identified as `home-live`; `RelayManager`, the shared WebSocket lifecycle, and shared ingestion do not own saturation state.

Required processing order:

1. Classify the incoming message by subscription purpose.
2. Run any applicable non-Home consumer routing or request completion.
3. If the purpose is `home-live`, consult Home admission.
4. If accepted, enqueue either normal bounded backlog work or the latest page-sized refresh handoff.
5. If rejected, advance Home's scalar observed cursor and return from the Home branch before claiming shared persistence dedupe or entering a write buffer.

Shared event-ID dedupe protects persistence; it must not suppress purpose-specific consumer behavior. If a Home-rejected event later arrives through an Activity, Thread, Notification, or other subscription, that consumer processes it normally and may persist it as its own cache side effect.

The refresh handoff is not a second backlog. It exists only for the active latest-page generation, is capped to that page size, merges atomically with the page response, and is discarded on cancellation or generation change. This closes the EOSE-to-commit race without retaining every event observed while Home was saturated.

Older pagination, profile pages, thread lookups, search, DMs, and activity keep their own request lifecycles.

### 4.4 Ingestion boundary

Move SwiftData work out of `NostrRelay` and off the main actor.

Introduce an immutable network DTO and one serialized persistence owner:

```swift
struct RelayEventEnvelope: Hashable, Sendable {
  let eventID: String
  let publicKey: String
  let createdAt: Int64
  let kind: Int
  let content: String
  let tags: [NostrTagValue]
  let signature: String
  let sourceRelay: String
  let purpose: RelayRequestPurpose
}

@ModelActor
actor RelayIngestionActor {
  func ingest(_ batch: [RelayEventEnvelope]) async -> IngestionResult
}
```

Do not pass `RTextNote`, `RUserProfile`, or any SwiftData model across this boundary. Return immutable, `Sendable` values already used by feed/controllers.

One app-level ingestion actor performs cross-relay persistence dedupe after purpose-specific routing and before database existence checks. The current per-event fetch-before-insert pattern should become a bounded batch fetch/upsert.

### 4.5 Engagement loading

Remove per-card network reply-count prefetch from `EventView.onAppear`.

Home should own one bounded `FeedEngagementController` for the current visible event IDs:

- maximum 12 event IDs per batch;
- one in-flight request per engagement type;
- one merged relay request instead of one repository per card;
- return immutable counts and current-user state;
- cancel when the visible ID set changes materially or Home disappears;
- cache short-lived results by event ID;
- load the full comment thread only when the comment action is opened.

Event cards render engagement values passed from the parent presentation layer. They do not each own independent network subscriptions.

## 5. Resource Budgets

Initial recommended budgets, subject to Instruments validation:

| Resource | Current | Initial target |
| --- | ---: | ---: |
| Home latest page | 12 | 12 |
| Older page shown per demand | 10 | 10 |
| Retained Home items | 24 | 16 |
| New-event backlog | 100 full values | 100 IDs, then Home-only drop |
| Event render cache | 600 entries | 64 entries, ~12 MB cost |
| Feed media prefetch | 12 URLs | 4 downsampled images |
| Comment-count requests | one per mounted card | one batch for <= 12 IDs |
| Home live subscriptions | one per active relay | same; saturation never recreates them |
| Relay write batch | 24 on main | <= 24 off-main |
| Text-note disk cache | effectively unbounded | 750 unprotected snapshots |
| Thread disk cache | 1,000 | retain 1,000, maintained off-main |

These are ownership budgets, not arbitrary timers. Each owner must expose its current count in debug diagnostics.

### 5.1 Image policy

- Remove `.cacheOriginalImage()` from feed cards and avatars.
- Decode feed images to the card's target pixel dimensions using Kingfisher downsampling.
- Decode avatars to their rendered pixel size.
- Allow a larger screen-sized decode only after opening fullscreen.
- Configure an explicit Kingfisher memory cost limit and expiration.
- Configure equivalent SDWebImage thumbnail contexts for animated media.
- Keep disk caching, but never retain both full original and downsampled images in memory for feed display.
- Cancel decode/download when a card disappears.

### 5.2 Event render cache

Add:

```swift
func removeAll()
```

Configure both `countLimit` and `totalCostLimit`. Cost should approximate content bytes plus parsed attributed-content overhead. `NSCache` remains opportunistic; the explicit purge is for lifecycle and memory-warning handling.

## 6. Feed Session Freshness

Recommended product rule:

- Leaving Home marks its consumer inactive and stops collecting Home-only candidates; global relay processing and non-Home consumers remain active.
- Returning within 5 minutes can show the preserved window first, then perform one bounded latest-page refresh.
- Returning after 5 minutes, returning after a memory warning, or becoming active after a long background interval starts with latest-page skeletons and a bounded rebase.
- Never request every event since the old cursor after a stale session.

The existing app-wide background policy may still disconnect relays when iOS backgrounds the process. That lifecycle decision is independent from Home saturation and must not be triggered by it.

The 5-minute value is a product constant, not a memory workaround. It can be revised before implementation.

## 7. Safe Persistent Cache Maintenance

Persistent maintenance is separate from memory recovery.

### 7.1 Protected IDs

Maintain a set of event IDs currently required by:

- the visible Home window;
- the active profile/thread destination;
- optimistic/pending posts;
- DM post previews currently shown;
- notification destinations currently shown.

Cache maintenance must never delete protected rows.

### 7.2 Maintenance rules

- Run on the ingestion `ModelActor`, never in the live save path on MainActor.
- Trigger after app backgrounding, after a bounded number of successful batches, or during explicit Settings cleanup.
- Delete oldest unprotected rows in small batches.
- Save once per maintenance batch.
- Do not run `incremental_vacuum` after every save.
- Allow normal SQLite WAL checkpoint behavior; schedule heavier maintenance only while background time is available.
- Keep feed correctness independent from the cache result.

Before enabling text-note/repost deletion, remove any remaining view-held SwiftData models for those entities or prove they cannot outlive the maintenance protection set.

## 8. Memory-Warning Recovery Sequence

Handle the native memory warning in this order:

1. Stop Home live backlog collection; do not alter relay connections or non-Home subscriptions.
2. Cancel media prefetch and obsolete Home latest/older requests.
3. Stop and release offscreen `AVPlayer` instances.
4. Clear `EventRenderCache`.
5. Clear Kingfisher and SDWebImage memory caches, preserving disk caches.
6. Reduce Home's retained immutable window to at most 8 items around the visible anchor.
7. Clear the pending ID backlog and mark `needsLatestRebase`.
8. Yield back to the run loop. Do not synchronously delete SwiftData rows or vacuum SQLite.

If Home is not visible, do not rebuild it during the warning. Rebase on the next Home appearance.

## 9. Loading and UX States

- Normal backlog: current compact toast count.
- Saturated backlog: `99+`, same compact visual treatment.
- Latest rebase: 10 lightweight event skeletons while the bounded page is in flight.
- Rebase success: replace the window atomically and scroll to top.
- Rebase failure: retain current content and show a concise retryable error; no blank feed.
- Memory recovery while reading: preserve the currently visible anchor, release offscreen content, and avoid an unsolicited jump.
- Stale Home re-entry: skeleton latest page, then fresh content.

No technical memory copy should be shown to the user.

## 10. Observability

Replace high-volume `print` statements with purpose-specific `Logger` categories and debug signposts.

Track without event content or key material:

```text
HomeConsumer state=collecting->saturated pending=100 scope=global
HomeConsumer DROP reason=saturated event=... observedCursor=...
HomeConsumer routedNonHome=1 purpose=notification homeAdmission=dropped
LatestFeed request scope=global relayLimit=24 merged=18 visible=12 durationMs=...
Ingestion batch raw=24 deduped=9 inserted=8 durationMs=... mainThread=false
FeedMemory warning visible=16 renderCache=64 prefetch=4 action=soft-reset
EngagementBatch visibleIDs=12 relayRequests=2 durationMs=...
```

Measure:

- Home live events admitted/rejected at capacity;
- Home-only drops and events still routed to non-Home consumers while saturated;
- subscriptions by relay and purpose;
- buffered event counts;
- database batch duration and thread/actor;
- visible card and live query counts;
- render-cache entries/cost;
- image memory cost and active prefetch count;
- active players;
- latest/older request duration and cancellation;
- main-thread hitches using Instruments and signposts.

## 11. Implementation Phases

### Phase 0 - Baseline and tests

- Add debug counters/signposts for Home state, relay purposes, ingestion batches, mounted event cards, engagement requests, render cache, media prefetch, and active players.
- Record an Instruments baseline using the verification scenario in section 13.
- Add pure state-machine tests for backlog and Home admission transitions.

Exit criterion: the current freeze can be attributed to measured main-thread, media, query, or subscription work before behavior changes.

### Phase 1 - Real Home backpressure

- Replace the pending full-value array with the bounded ID backlog.
- Add `HomeLiveCollectionState` and the purpose-specific admission rule at the Home consumer boundary.
- Stop Home backlog collection exactly once at 100 without changing sockets or subscriptions.
- Route purpose-specific consumers before shared persistence dedupe.
- Reject Home-only events 101+ before Home buffering/persistence while still advancing the scalar observed cursor.
- Keep all global and non-Home relay functions active.
- Preserve `99+` UI semantics.

Exit criterion: after saturation, Home backlog, temporary buffers, and Home-only persistence writes stop increasing. Relay traffic and DMs, mentions, replies, reactions, activity, profiles, search, threads, metadata, and older pagination continue normally.

### Phase 2 - Bounded latest rebase

- Add `fetchLatestFeedPage(scope:limit:)` returning `FeedPage<FeedItem>` directly.
- Add one in-flight latest request and cancellation generation.
- Implement skeleton-backed toast/pull refresh.
- Atomically merge the accepted latest page with a bounded refresh-generation handoff, set the semantic cursor, and return Home collection to `collecting`.
- Cover offline/partial relay/timeout states.

Exit criterion: tapping `99+` loads current latest posts, not merely the first cached events received before saturation, and never replays the entire gap.

### Phase 3 - Off-main ingestion

- Introduce immutable relay envelopes.
- Move batching, dedupe, SwiftData insertion, and observer-summary creation to one `ModelActor`.
- Replace per-event existence queries with batch dedupe/upsert.
- Keep UI delivery on MainActor using immutable values only.

Exit criterion: relay batch persistence performs no database work on MainActor and feed scrolling remains interactive during relay bursts.

### Phase 4 - Event-card fan-out reduction

- Remove per-card comment network prefetch.
- Introduce batched engagement loading for visible IDs.
- Reduce per-card live SwiftData query ownership where values can be supplied by the feed presentation model.
- Cancel batched work when the visible set or destination changes.

Exit criterion: mounted card count no longer multiplies relay subscriptions, repositories, or unconstrained queries.

### Phase 5 - Media and render budgets

- Downsample images and avatars to display size.
- Remove feed/avatar original-image memory caching.
- Reduce prefetch to four processed images.
- Set Kingfisher, SDWebImage, and `EventRenderCache` memory budgets.
- Verify player release and animated-media cancellation on disappear.

Exit criterion: scrolling through media-heavy events reaches a stable memory plateau and decoded originals are absent from the feed memory graph.

### Phase 6 - Native memory recovery and stale-session refresh

- Isolate the iOS memory-warning observer in the lifecycle/resource layer.
- Implement the soft reset sequence.
- Mark Home collection inactive on disappearance and keep the separate app-background relay lifecycle unchanged.
- Add the reviewed stale-session rule and bounded rebase on return.

Exit criterion: a simulated memory warning releases evictable caches and feed state without deleting persistent data or breaking navigation.

### Phase 7 - Safe cache retention

- Add protected event-ID reporting.
- Re-enable text-note/repost retention on the persistence actor.
- Delete in bounded background batches.
- Add maintenance and invalidation regression tests.

Exit criterion: persistent cache size remains bounded across long sessions with no invalidated SwiftData model crashes.

### Phase 8 - Final profiling and hardening

- Repeat Instruments scenarios on a low-memory simulator/device profile and a current device.
- Tune budgets only from measurements.
- Remove temporary high-volume diagnostics or keep them behind a debug flag.
- Run the full build/test suite after each meaningful phase.

Exit criterion: all Definition of Done requirements pass with no new SwiftUI, SwiftData, WebSocket, or navigation warnings.

## 12. Test Matrix

### Backpressure

- 99 unique events remains live and displays `99`.
- Event 100 transitions once to saturated and displays `99+`.
- Events 101+ that are Home-only do not grow Home's backlog, temporary buffers, timers, or persistence work.
- Duplicates across relays do not increment the count.
- Scope/key changes clear the old backlog and cannot reuse its live cursor.
- Admission transitions are idempotent across relay reconnects.
- Saturation does not disconnect, pause, unsubscribe, resubscribe, or recreate relay connections/subscriptions.
- Home saturation does not suppress DMs, mentions, replies, reactions, notifications, metadata, profiles, or any other active subscription.
- An event required by another consumer is processed even when it also qualifies for Home.
- A Home-rejected event can later be processed through another subscription purpose despite shared persistence dedupe.
- Home-first and non-Home-first delivery orders produce the same consumer results and one persisted event.
- Home advances no unbounded ID list or replayable cursor gap while saturated.

### Latest refresh

- Saturation -> tap -> latest network page -> Home collection resumes on the existing live subscription.
- Latest page dedupes cross-relay events.
- Events posted after saturation that belong to the bounded latest snapshot or refresh handoff appear after rebase.
- Partial relay success renders available items.
- Total failure preserves current feed and retry state.
- Obsolete refresh results cannot mutate a new scope/key generation.

### Memory recovery

- Memory warning clears memory caches but not disk cache, keys, relays, DMs, or notifications.
- Visible anchor survives an active-reading soft reset.
- Offscreen players and prefetchers are released.
- Home not visible does not instantiate/render during recovery.
- Next Home entry performs one bounded latest rebase.

### Persistence

- Relay batch saves off MainActor.
- Cross-relay duplicates are inserted once.
- Protected event IDs survive maintenance.
- Old unprotected rows are removed in bounded batches.
- No view reads an invalidated SwiftData model after maintenance.

### Media and cards

- Feed and avatar images decode near rendered pixel dimensions.
- Fullscreen media loads only on explicit action.
- Mounted card count does not produce per-card reply subscriptions.
- Leaving Home cancels engagement and media work.
- Sensitive/Ask First modes still avoid unwanted downloads.

## 13. Profiling Scenario

Use the same deterministic scenario before and after every performance phase:

1. Cold launch with three active relays.
2. Remain at the top until the new-event toast saturates.
3. Verify Home backlog and Home-only persistence flatten after saturation while global relay/network and non-Home consumers remain active.
4. Tap `99+` and wait for latest rebase.
5. Scroll through 20 older pages containing text, static images, animated images, and video links.
6. Open and dismiss one image and one video fullscreen.
7. Open a thread, profile, notifications, and DMs; return to the exact feed position.
8. Background for more than the reviewed stale threshold and return.
9. Trigger a simulated memory warning.
10. Repeat the scroll and latest refresh.

Capture Allocations, Memory Graph, Time Profiler, SwiftUI, Network, and signpost data.

Acceptance targets are relative across supported devices:

- no monotonically increasing resident-memory curve after repeated page cycles;
- evictable memory drops materially after memory warning/background purge;
- no database work on MainActor;
- no unbounded Home subscriptions or per-card comment subscriptions;
- no Home-only backlog, temporary buffer, or replay cursor growth after saturation;
- no loss of non-Home consumer events while Home is saturated;
- no main-thread stall attributable to a relay batch;
- no jetsam termination, invalidated model crash, or scroll lock;
- latest/older pagination and navigation remain behaviorally correct.

## 14. Definition of Done

- The toast displays at most `99+` and represents a maximum of 100 unique pending IDs.
- Reaching capacity stops only Home live backlog collection. Global relay ingestion and non-Home consumers remain active.
- Home-only candidates received after saturation are discarded without growing backlog state, temporary persistence, timers, or a replayable cursor gap.
- Events required by DMs, mentions, replies, reactions, notifications, metadata, profiles, or another active consumer are processed even when they also qualify for Home.
- Saturation never disconnects, pauses, unsubscribes, or recreates relay connections/subscriptions.
- Tapping the toast performs a bounded latest network rebase and resumes Home collection on the existing live subscription.
- Home does not replay an unbounded cursor gap after saturation or a stale background session.
- Relay persistence and retention execute off MainActor.
- Event cards do not create one reply subscription per mounted item.
- Visible cards, parsed render state, images, prefetch, players, and persistent cache all have explicit owners and budgets.
- Native memory warning performs a soft reset without deleting user data.
- Persistent retention cannot invalidate models held by the UI.
- Feed, profile, threads, activity, and DMs continue using immutable values across persistence/UI boundaries.
- Instruments show a stable memory plateau under the profiling scenario.
- Full build and tests pass after every phase.

## 15. Explicitly Out of Scope

- Automatically deleting keys, relays, DMs, watchers, or notification history during memory recovery.
- Disconnecting all WebSockets because Home is saturated.
- Pausing or recreating the Home subscription because its backlog is saturated.
- Adding a priority-routing framework when existing subscription-purpose routing can apply the Home-specific drop.
- Replacing latest/older cursor pagination with an unbounded `@Query`.
- Polling private or unstable process-memory APIs as product logic.
- Hiding freezes with delays, debounce timers, or arbitrary cooldowns.
- Rewriting Home as UIKit before profiling the corrected SwiftUI ownership model.

## 16. Decisions to Confirm Before Implementation

Recommended defaults:

1. Backlog capacity: **100**, displayed as `99+` at saturation.
2. Retained Home window: **16** immutable items.
3. Latest rebase page: **12** items with **10 skeletons**.
4. Stale Home threshold: **5 minutes** away/backgrounded.
5. Feed image memory budget: **32 MB** processed/downsampled images.
6. Event render cache: **64 entries / approximately 12 MB**.
7. Media prefetch: **4 downsampled static images**.
8. Persistent text-note/repost cache: **750 unprotected items**, with network pagination as source of truth.

These values should be reviewed first, then implemented phase by phase rather than as one large change.
