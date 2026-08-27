# Remote Profile Search - Implementation Log

Status: implemented and verified  
Date: 2026-08-26

## Problem

`SearchView` currently fetches at most 180 cached `RUserProfile` records and filters them locally. A profile can only appear after another feature has already caused its metadata to be cached, so searching for a valid remote user by name produces a misleading `No Results` state.

The exact `npub` path can open an uncached profile, but the search result itself still has no remote metadata.

## Protocol Decision

- Free-text profile search uses NIP-50: `kinds: [0]`, `search: <query>`, bounded `limit`.
- Exact `npub` or 64-character public key lookup uses standard NIP-01 metadata lookup: `kinds: [0]`, `authors: [pubkey]`, `limit: 1`.
- Queries use only the user's active relays. No hidden search relay is added.
- Relays that do not implement NIP-50 may return no free-text results; successful responses from other active relays are still shown.

## Data Flow

```text
SearchView
  -> cached snapshots immediately
  -> debounce
  -> ProfileSearchRepository
       -> active NostrRelay instances
            -> NIP-50 text search or exact-author metadata lookup
       -> dedupe by event ID
       -> latest valid kind:0 metadata per pubkey
       -> immutable ProfileSearchProfile values
       -> SwiftData cache side effect
  -> merge cached + remote snapshots
  -> existing local relevance signals
  -> UI
```

SwiftData remains a cache and ranking input. A remote response is rendered directly and never depends on a save/refetch cycle.

## Request Lifecycle

- Require at least two normalized characters for free-text relay search.
- Debounce typing by 300 ms.
- Permit one active search request per `SearchView`.
- Cancel every relay subscription when the query changes, the active key changes, or the view disappears.
- Ignore stale completions by query generation.
- Bound each relay to 20 metadata events and a short timeout.
- Deduplicate events across relays, then select the newest valid metadata event for each pubkey.
- Do not paginate free-text results initially. Search is an intent lookup, not an infinite feed.

## UI States

- Cached matches render immediately.
- A native inline `ProgressView` indicates remote search without replacing existing results.
- Remote results merge into the same `Profiles` section; there is no separate relay-results UI.
- `No Results` appears only after local matching and the current remote request both finish.
- Exact public-key navigation remains immediately available while its metadata loads.
- Copy remains concise and does not claim the whole Nostr network was searched.

## Persistence Boundary

`ProfileSearchProfile` is an immutable `Sendable` value containing only public key, display metadata, and metadata timestamp. `RUserProfile` never lives in view state or crosses asynchronous callbacks.

Remote metadata is upserted only when it is newer than the cached profile event. NIP-05 is stored as unverified and follows the existing verification pipeline.

## Implementation Phases

1. Add typed profile-search values, request cancellation, repository aggregation, validation, dedupe, and cache side effect.
2. Add bounded profile-search subscriptions to `NostrRelay`, including timeout, EOSE, reconnect, explicit cancellation, and relay-aware logs.
3. Convert `SearchView` results from SwiftData models to immutable snapshots and merge cached/remote results with the existing scoring signals.
4. Add loading and final empty states, then verify exact-key and free-text navigation.
5. Add focused tests for metadata parsing, newest-event selection, multi-relay dedupe, stale request protection, and exact/free-text filter semantics.

## Definition of Done

- Searching a name or bio can return profiles not previously cached when an active relay supports NIP-50.
- Pasting an uncached `npub` fetches and displays its metadata without blocking navigation.
- A query change leaves no obsolete subscriptions or stale UI updates.
- Results are bounded, deduplicated, sorted with existing local relevance signals, and safe across SwiftData pruning.
- No search result stores an `RUserProfile` reference.
- No relay, key, or private content is silently added or exposed.
- App build and profile-search tests pass.

## Verification

- `build-for-testing` succeeds for the `a` scheme on the generic iOS Simulator destination.
- The complete unit suite passes: 17 tests, 0 failures, 0 skipped.
- Seven focused profile-search tests cover NIP-50 vs exact-author query semantics, relay-event dedupe, newest metadata selection, local relevance validation, multi-term matching, malformed-event rejection, and idempotent cancellation.
- Query generation guards were audited at both the debounce boundary and repository-start boundary so stale tasks cannot open a new subscription.

## Operational Note

Exact `npub` lookup uses standard NIP-01 filters and works with ordinary Nostr relays. Free-text lookup requires at least one active relay that implements NIP-50. The app does not silently add a dedicated search relay; an unsupported active relay is allowed to return no matches, and irrelevant results are discarded locally.
