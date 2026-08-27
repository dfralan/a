# Threaded Comments - Implementation Plan

Status: implemented; app build and 10 focused tests passing  
Scope: NIP-10 threads for `kind:1` and NIP-22 comments for every supported non-`kind:1` target  
Primary platforms: iPhone and iPad, native SwiftUI navigation

## 1. Outcome

Turn the current flat comments sheet into a navigable thread experience:

```text
Feed
  -> Post thread
       -> Comment thread
            -> Reply thread
                 -> ...
```

Every screen focuses on one event and renders only its direct replies. Every focused event and reply uses the same core event card actions: like, comments, repost, and share. The system back button walks through the exact route the user followed until returning to the feed.

Logical depth is unlimited. Rendering is deliberately not recursive: each navigation destination owns one focused event and one paginated page of direct replies.

## 2. Product Decisions

### Navigation

- Replace `EventCommentsSheet` as the canonical comments experience with a pushed route in the app's existing `NavigationStack`.
- Add the typed route `.thread(target: ThreadTarget)`.
- A comment button always pushes the thread for the selected event.
- Use the native back button. Do not add a custom back control or nest another `NavigationStack`.
- Opening a profile, shared `nostr:note` link, notification, or search result must reach the same thread destination.
- Preserve the previous screen and scroll position when navigating back.
- A sheet remains appropriate only for short modal actions such as share or report, not for browsing a hierarchy.

### Thread layout

Each `ThreadView` contains:

1. The focused event at the top, rendered as a complete event card.
2. A subtle divider or thread connector.
3. The focused event's direct replies, each rendered with the standard event content and action bar.
4. A bottom composer whose placeholder is `Reply to <name>`.
5. A bottom pagination skeleton while an older reply page is loading.

The screen title is `Post` for a root note and `Reply` for a reply. The hierarchy is communicated by navigation and content, not by deeply indented cards.

### Counts and ordering

- A comment counter represents known direct replies to that event, not every descendant in the subtree.
- A nonzero count never changes the comment icon to filled.
- Show replies oldest first within the visible conversation so reading order is stable.
- Do not rerank a mounted thread when reactions arrive. A future `Top` sort can be a separate product decision.

### Event actions

- Like: existing NIP-25 behavior and optimistic animation.
- Comments: push the selected event's thread.
- Repost: existing repost behavior, valid for `kind:1` replies as well as root posts.
- Share: existing NIP-21 link and DM share flow.
- Report and sensitive-content behavior remain available from the event menu.

## 3. Protocol Rules

Both protocols are first-class implementations of one thread pipeline:

```text
ThreadView
    -> ThreadController
        -> ThreadRepository
            -> CommentProtocolStrategy
                -> NIP-10
                -> NIP-22
```

The strategy is selected once from the semantic target. Views and controllers never branch on a NIP.

### NIP-10 for `kind:1`

Posts and their replies are `kind:1`, so their thread relationships must use NIP-10.

- A direct reply to a root post has one marked `e` tag with marker `root`.
- A nested reply has a `root` tag for the original post and a `reply` tag for its immediate parent.
- Marked tags are preferred. Positional `e` tags are read only for backward compatibility.
- `e` tags used as mentions or quotes must not become parent relationships.
- Referenced authors must be represented by `p` tags.
- When replying, inherit the parent's participant `p` tags and add the parent author, deduplicated.
- Add relay hints and referenced-author fields to `e` tags when known.

The existing `NIP10.reply` writer needs correction because it currently emits both `root` and `reply` even when replying directly to the root.

### NIP-22 for non-`kind:1` targets

NIP-22 `kind:1111` comments are used for every supported commentable target that is not a `kind:1` note. This includes regular event IDs, addressable event coordinates, and supported external identifiers.

- Root scope uses uppercase `E`, `A`, or `I`, plus mandatory `K` and root author `P` when available.
- The immediate parent uses lowercase `e`, `a`, or `i`, plus mandatory `k` and parent author `p` when available.
- A direct comment on a root repeats that semantic target as both root scope and parent.
- A reply to a `kind:1111` comment preserves the original uppercase root scope and points its lowercase parent tags to the immediate `kind:1111` comment.
- NIP-22 comments are never published as NIP-10 replies, and the client never dual-publishes two representations of one comment.

NIP-22 must not be used to reply to `kind:1` notes. Those always remain NIP-10.

The strategy is an actual protocol boundary used by the repository and publisher:

```swift
enum CommentProtocol: Hashable, Sendable {
  case nip10TextNote
  case nip22(root: CommentScope)
}
```

Both cases are implemented and enabled in this scope. The protocol-specific layer owns only event kind/filters, root and parent parsing, direct-child classification, event/tag construction, relay query semantics, and validation.

## 4. Current Gaps

| Area | Current behavior | Required behavior |
| --- | --- | --- |
| Presentation | Modal `EventCommentsSheet` | Main typed navigation route |
| Reply list | Flat query matches `replyEventId` or `rootEventId` | Direct children only |
| Comment UI | Lightweight `EventCommentRow` | Shared event card and actions |
| Thread depth | No navigation from a comment | One pushed route per selected reply |
| Writer | Always writes `root` + `reply` | Correct top-level vs nested NIP-10 tags |
| Networking | Callback returns every event containing `#e` | Typed paginated direct-reply page |
| State | Sheet owns fetch/post flags | Controller owns focused item, pages, errors, and optimistic replies |
| Event detail | Mixes replies, same-author posts, and hashtags under `More Like This` | Canonical focused event plus direct replies |

The current SwiftData predicate also flattens descendants under the root:

```text
replyEventId == focusedID OR rootEventId == focusedID
```

For a thread screen, the relationship must be:

```text
directParentEventID == focusedID
```

## 5. Domain Model

Do not pass `RTextNote` outside the persistence boundary. Thread rendering should use immutable, `Sendable` values, consistent with the feed and DM architecture.

```swift
struct ThreadItem: Identifiable, Hashable, Sendable {
  let id: String
  let publicKey: String
  let createdAt: Date
  let content: String
  let root: ThreadEventReference
  let parent: ThreadEventReference?
  let participantPublicKeys: Set<String>
  let isSensitiveContent: Bool
  let sensitiveContentReason: String
}

struct ThreadEventReference: Hashable, Sendable {
  let target: ThreadTargetReference
  let publicKey: String?
  let relayHints: [String]
}

enum ThreadTargetReference: Hashable, Sendable {
  case event(id: String, kind: Int)
  case address(coordinate: String, eventID: String?, kind: Int)
  case external(identifier: String, kind: String)
}

struct ThreadCursor: Hashable, Sendable {
  let until: Int64
}

struct ThreadPage<Item: Sendable>: Sendable {
  let items: [Item]
  let cursor: ThreadCursor?
  let exhausted: Bool
}
```

`ThreadItem` may share or converge with `FeedItem`, but thread semantics must not be reconstructed from an `EventViewModel` that has already discarded tags and parent information.

### Persistence fields

Normalize and persist the protocol data needed after a cold launch:

- root event ID
- direct parent event ID
- referenced root and parent public keys when available
- participant public keys from `p` tags
- useful relay hints
- event kind

Use SwiftData-compatible scalar storage or a dedicated Codable payload supported by the model. Do not declare raw `[String]` model attributes; that shape has already caused Core Data materialization failures in this project.

SwiftData remains a cache sidecar. A network page is returned directly to the controller and is persisted independently; rendering must not wait for a second cache refetch.

## 6. Repository and Relay API

Introduce a semantic API:

```swift
func fetchReplyPage(
  parent: ThreadEventReference,
  cursor: ThreadCursor?,
  limit: Int
) async throws -> ThreadPage<ThreadItem>
```

For NIP-10, relay filters use `kinds: [1]` and `#e: [parent event ID]`, plus `until` and a bounded raw limit.

For NIP-22, relay filters use `kinds: [1111]` and the lowercase direct-parent index appropriate to the target: `#e`, `#a`, or `#i`. Root-scope lookups may additionally use uppercase `#E`, `#A`, or `#I` when the relay supports those indexes. Direct-child classification is still performed by the strategy after parsing.

Important: `#e` only means that the event references the ID somewhere. For a root post, it can return every descendant because nested replies retain the root tag. The repository must parse each event and return only items whose direct parent equals `parent.eventID`.

### Pagination behavior

- Visible page size: 10 direct replies.
- Raw relay batch: up to 40 events per relay request.
- Deduplicate by event ID across relays before classifying relationships.
- Advance the cursor using the oldest raw event, not the oldest accepted direct child.
- If a raw page contains descendants but no direct children, continue scanning within a bounded request budget instead of declaring the thread exhausted.
- Mark `exhausted` only when the raw relay page is exhausted/empty, not when the filtered direct-child page is empty.
- Permit one in-flight older-page request per controller.
- Cancel/unsubscribe an obsolete request when its destination is removed.
- Persist every valid received event as cache, including descendants not yet shown.

This avoids both false `No more replies` states and uncontrolled relay consumption.

### Cache behavior

- Bootstrap each thread from cached direct children immediately.
- Refresh from active relays after presenting cached content.
- Cache pages by parent event ID with a short freshness timestamp to avoid duplicate fetches when navigating back.
- Deduplicate optimistic, cached, and relay-confirmed items by event ID.
- Do not preload replies of replies. Fetch a child thread only after the user opens it.

## 7. Controller Ownership

Create one `@MainActor` `ThreadController` per visible `ThreadView`.

```swift
@MainActor
final class ThreadController: ObservableObject {
  @Published private(set) var focusedItem: ThreadItem?
  @Published private(set) var directReplies: [ThreadItem] = []
  @Published private(set) var isLoadingFocusedItem = false
  @Published private(set) var isLoadingInitialReplies = false
  @Published private(set) var isLoadingOlderReplies = false
  @Published private(set) var hasReachedReplyEnd = false
  @Published private(set) var error: ThreadError?
}
```

Responsibilities:

- Resolve the focused event from cache or relays.
- Load the first 10 direct replies.
- Append older pages with stable ordering and event-ID dedupe.
- Insert a newly published reply optimistically.
- Reconcile relay confirmation without duplicating the item.
- Expose retryable errors and empty/loading states.
- Never own global navigation or SwiftUI presentation flags.

The route stores only a semantic `ThreadTarget`. It must not retain SwiftData models or a complete recursive tree.

## 8. Reusable Event Presentation

Refactor the current private comment row into the same event presentation pipeline used by posts.

Recommended boundary:

```swift
EventCard(
  item: EventPresentationItem,
  context: .threadReply,
  onComments: { navigation.push(.thread(target: ...)) }
)
```

`EventCard` owns visual composition. Action execution remains in focused services/controllers so the view does not accumulate more independent `@Query` and publishing state for every row.

Support presentation contexts without duplicating the card:

- `.feed`
- `.threadFocus`
- `.threadReply`
- `.profile`

Contexts may adjust spacing or divider treatment, but they share content rendering, sensitive-media policy, menus, counts, and the four primary actions.

Do not nest complete `EventView` instances recursively and do not place cards inside decorative parent cards.

## 9. Composer and Publishing

The composer always replies to the currently focused event.

Publishing inputs must include:

- original thread root reference
- direct parent reference
- root and parent authors
- inherited participant public keys
- active relay hints when known
- normalized NIP-27 mentions and NIP-24 hashtags already supported by the writer

Expected writer behavior:

```text
Reply to root:
  e(root, marker=root)

Reply to comment:
  e(root, marker=root)
  e(parent, marker=reply)
```

On send:

1. Select the strategy from the semantic target and create exactly one signed NIP-10 or NIP-22 event.
2. Insert an optimistic reply into the current controller.
3. Publish to active relays.
4. Reconcile confirmation and persist once any relay accepts it.
5. On total rejection, keep the reply visible with a compact error and retry action.
6. Never block scrolling or replace the thread with a full-screen loader.

Read-only public-key sessions can browse every thread. Attempting to like, reply, or repost must invoke the existing key-generation/auth flow without losing the navigation path.

## 10. Loading and Empty States

- Focused event missing: full event-card skeleton, then `Post Unavailable` with retry.
- Initial replies loading: 3 lightweight reply skeletons below the focused event.
- Older replies loading: one reply skeleton at the bottom.
- No direct replies after EOSE: `No Replies` with `Be the first to reply.`
- No active relays: reuse the relay empty state and provide the route to Relay Manager.
- Partial relay failure: show available replies; do not fail the whole screen.
- Offline with cache: show cached content and a subtle offline state, without an indefinite skeleton.

Skeletons must reserve final layout dimensions to prevent jumps.

## 11. Navigation Integration

Update the canonical route map:

```text
AppNavigation.Route.thread(target)
  -> RootView.routeDestination
       -> ThreadView(target)
```

Entry points to unify:

- comment button on a feed event
- comment button on a reply
- event preview in DMs
- notification referring to a post/reply
- `nostr:note` / `nostr:nevent` link
- event detail reached from profiles or search
- popular-comment preview under a feed event

`EventDetailView` should become `ThreadView` or delegate to the same implementation. Its current `More Like This` section must not be part of the canonical thread because it mixes replies with unrelated author/hashtag content.

## 12. Performance and Safety

- Render only direct replies in a `LazyVStack`.
- Load 10 replies initially and 10 per bottom-edge request.
- Use the same edge-triggered pagination latch as Home: one page per threshold entry, rearmed only after leaving it.
- Never start page loading from a row's repeated `onAppear` without an in-flight guard.
- Do not subscribe to every descendant or recursively prefetch.
- Keep parsed text/media presentation in `EventRenderCache` keyed by event ID.
- Keep media lazy and honor the existing attachment/sensitive-content download policy.
- Batch reaction, repost, profile, and reply-count lookups for the visible thread instead of adding several unconstrained queries per row.
- Measure before adding a hard visible-item window. If needed, cap retained reply IDs rather than retaining SwiftData objects or media players.

## 13. Observability

Add purpose-specific, relay-aware logs:

```text
[relay][connection][sub] REQ purpose=thread-replies parent=<id> until=<cursor> limit=40
[relay][connection][sub] EOSE raw=40 direct=7 descendants=31 invalid=2
ThreadController parent=<id> source=network appended=7 deduped=3 next=<cursor>
```

Track:

- raw events received
- direct children accepted
- descendants cached
- duplicates across relays
- malformed/ambiguous NIP-10 tags
- request duration and timeout
- optimistic publish accepted/rejected relay count

No content or private key material may appear in logs.

## 14. Implementation Sequence

### Phase 1 - Protocol and domain foundation

- Add NIP-10 parser tests for root, nested, legacy positional, mention, and malformed tags.
- Add NIP-22 parser tests for event-ID, addressable, and external roots; direct root comments; nested `kind:1111` replies; and malformed mandatory tags.
- Correct `NIP10.reply` for direct-root and nested replies.
- Implement `NIP22.comment` with uppercase root and lowercase parent semantics.
- Add the shared strategy selector and protocol-specific validation.
- Preserve participant pubkeys, relay hints, and parent/root author data.
- Introduce `ThreadItem`, `ThreadCursor`, and `ThreadPage`.

Exit criterion: both parser/writer pairs round-trip thread relationships without UI involvement and never dual-publish.

### Phase 2 - Typed repository

- Add async `fetchReplyPage` and relay subscription cancellation for both NIP-10 and NIP-22 filters.
- Merge relay results, classify direct children, dedupe, paginate, and persist as a side effect.
- Add local cached direct-reply bootstrap.

Exit criterion: repository tests return only direct children for both protocols and never report false exhaustion on descendant-only batches.

### Phase 3 - Thread controller

- Resolve the focused event.
- Bootstrap and paginate direct replies.
- Add protocol-agnostic optimistic reply state and relay reconciliation.
- Expose explicit loading, empty, offline, and error states.

Exit criterion: controller tests cover cache/network merge, concurrent load guards, retries, and cancellation.

### Phase 4 - Native navigation

- Add `.thread(target:)` to `AppNavigation.Route` and `RootView`.
- Build `ThreadView` on the existing app `NavigationStack`.
- Route feed comments, shared event links, notifications, profiles, and DMs to it.
- Remove nested navigation and modal ownership from the old comments sheet.

Exit criterion: a three-level reply chain navigates forward and back to the original feed position using only system navigation.

### Phase 5 - Unified event card

- Extract reusable event content and action components from `EventView`.
- Replace `EventCommentRow` with the standard thread-reply card.
- Connect like, comments, repost, share, report, sensitive content, and profile navigation. Use NIP-18 `kind:6` for `kind:1` and generic repost `kind:16` for non-`kind:1` events.
- Batch engagement/profile data for visible replies.

Exit criterion: root posts and replies have behaviorally identical actions without duplicated publishing code.

### Phase 6 - Cleanup and hardening

- Remove `EventCommentsSheet` and obsolete flat comment query paths.
- Replace or delegate `EventDetailView` to the canonical thread destination.
- Add pagination skeletons, accessibility labels, Dynamic Type checks, and relay-aware diagnostics.
- Profile memory, scroll responsiveness, subscription count, and database churn.

Exit criterion: no duplicate subscriptions, no indefinite skeletons, no invalidated SwiftData models, and no new navigation/presentation warnings.

## 15. Verification Matrix

### Protocol tests

- Direct reply to root writes only the marked root tag.
- Nested reply writes root plus immediate reply tags in the correct order.
- Parent author and inherited participant `p` tags are deduplicated.
- Relay hints and referenced pubkeys survive parse/persist/render/publish.
- Marked mentions and quotes do not become parents.
- Legacy positional tags still resolve a usable root and parent.
- Non-`kind:1` targets select NIP-22 and publish exactly one `kind:1111` event.
- NIP-22 event roots emit `E/K/P` plus `e/k/p` correctly.
- NIP-22 address roots emit `A/K/P` plus `a/k/p`, with the concrete `e` version when known.
- NIP-22 external roots emit `I/K` plus `i/k`.
- Replies to NIP-22 comments preserve the uppercase root and use the parent comment's `e`, `k=1111`, and `p`.
- Missing mandatory NIP-22 root or kind data fails validation before signing/publishing.

### Repository/controller tests

- Two relays returning the same reply produce one item.
- A root query containing only nested descendants advances its raw cursor and does not mark exhausted.
- Concurrent bottom triggers result in one request.
- Cache items appear first and relay items merge without layout replacement.
- A confirmed optimistic reply does not duplicate.
- A rejected optimistic reply exposes retry without disappearing silently.
- NIP-10 and NIP-22 pages share dedupe, cancellation, pagination, and cache reconciliation behavior.

### Publishing tests

- A `kind:1` focused target produces one NIP-10 `kind:1` reply.
- A supported non-`kind:1` target produces one NIP-22 `kind:1111` comment.
- A reply to a NIP-22 comment remains NIP-22 and retains the original root scope.
- No send path publishes both NIP-10 and NIP-22 for one user action.
- Optimistic items reconcile against the event ID produced by the selected strategy.
- Reactions include target kind/reference metadata and generic reposts use `kind:16` for non-`kind:1` events.

### UI/navigation tests

- Feed -> post thread -> comment thread -> nested reply thread -> back -> back -> back -> feed.
- Profile and DM event links enter the same thread implementation.
- Opening an author profile from a reply and returning preserves the thread.
- Composer follows keyboard/safe area and dismisses interactively.
- Empty, offline, timeout, partial relay, and unavailable-event states terminate cleanly.
- VoiceOver identifies author, timestamp, counts, action buttons, publish state, and errors.
- Large Dynamic Type, light/dark mode, iPhone/iPad, and long unbroken content do not overflow.

## 16. Definition of Done

- Any `kind:1` event can be opened as a focused thread.
- Each screen displays only direct replies to its focused event.
- Reply depth is limited only by available events, not by the UI model.
- All event cards expose like, comments, repost, and share.
- Native back navigation reaches the exact originating screen and ultimately the feed.
- NIP-10 output is correct for both top-level and nested replies.
- NIP-22 output is correct for event-ID, addressable, external, and nested comment targets.
- Protocol selection is deterministic: `kind:1` uses NIP-10; supported non-`kind:1` targets use NIP-22; no dual-publishing exists.
- View, controller, pagination, cache reconciliation, composer, and event presentation are shared by both protocols.
- Pagination is bounded, deduplicated, cancellable, and skeleton-backed.
- Cache improves startup but is not required for correctness.
- No recursive event tree, nested navigation stack, unbounded query, or SwiftData model crosses the repository/UI boundary.

## 17. Explicitly Out of Scope

- Unsupported external identifier types that cannot be validated through NIP-73 semantics.
- A full-tree indentation view.
- Loading every descendant to calculate subtree totals.
- Moderation ranking or `Top`/`Newest` sorting controls.
- Editing or deleting already-published Nostr replies.
- Dual-publishing NIP-10 and NIP-22 representations.
