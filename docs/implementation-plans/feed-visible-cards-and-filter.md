# Feed Visible Cards And Filter

Updated: 2026-08-29

## Goal

Keep Home smooth by treating visible feed cards as the only fully active cards, while preserving live Nostr behavior and native SwiftUI navigation.

## Diagnosis

Home already has bounded pagination and a capped visible window, but each visible event card still owns too much reactive work:

- per-card SwiftData queries for reactions, reposts, comments, thread replies, and profiles
- per-card verification tasks
- per-card media state and presentation state

That means the feed cost is not only "how many cards are mounted", but also "how many live data sources each mounted card owns".

The feed filter also resets to `Global` because it is currently local `@State` in `HomeView`, not persisted per active key.

## Phase 1

Implemented on 2026-08-28:

- Persist Home filter selection per active public key.
- Restore that filter when the active key changes or Home reappears.
- Introduce a lightweight Home-only event card path.
- Resolve author profile, reposter profile, like count, comment count, and repost/like state in batch for visible feed items.
- Keep `EventView` full-featured for thread and profile destinations.

## Architecture

```text
HomeFeedController
    -> visible FeedItem values
    -> HomeView
    -> FeedEventSupplementStore
    -> FeedEventView (lightweight)

Thread/Profile
    -> EventView (full)
```

The important boundary is:

- `Home` cards draw from immutable feed items plus aggregated supplements.
- `Thread` and `Profile` can remain richer and more reactive.

## Phase 2

Implemented on 2026-08-29:

- Track the leading visible event with native `scrollPosition` and stable Nostr event IDs.
- Preserve that event as the visual anchor when older items are appended and newer items are pruned.
- Move older-page demand from scroll geometry to a stable bottom visibility boundary.
- Keep geometry observation responsible only for toolbar direction and collapse state.
- Make LifeHash updates idempotent so unrelated feed updates do not flash the avatar placeholder.

The bottom boundary is edge-triggered: becoming visible requests one page and becoming hidden rearms it. The active scroll-position anchor introduced in this phase was removed in Phase 3 after runtime testing showed that it snapped variable-height cards.

## Phase 3

Implemented on 2026-08-29 after runtime scroll testing exposed anchor jumps:

- Remove the active `scrollPosition(..., anchor: .top)` binding from Home. It preserved an event ID but snapped that event to a different visual position when the data window changed.
- Stop pruning newer items while the user is reading older history. Appending below the viewport therefore cannot invalidate content above the reader.
- Prefetch at most 20 older values from cache or relay into a controller-owned buffer.
- Consume exactly one buffered event per bottom-boundary demand.
- Publish each append as one atomic `visibleItems` snapshot instead of append, sort, and prune mutations.
- Show one skeleton only while waiting for network. Buffered and cached values do not fake a loading state.
- Resolve reactive event supplements only for IDs SwiftUI reports as visible.
- Log viewport range, approximate offset, boundary transitions, demand, buffer preparation, single-item append, cursor, and exhaustion under the `HomeFeedController:` prefix.

The logical history may grow during a reading session, but only viewport cards receive reactive supplements and `LazyVStack` remains responsible for mounting. Memory-pressure handling still collapses the logical history around the visible event and requires a bounded latest rebase.

## Current Tradeoff

This first cut removes the hottest per-card SwiftData subscriptions from Home, but it does not yet fully unify all event presentation into a single shared resolver.

That is intentional. It reduces feed pressure now without risking thread/profile regressions.

## Next Steps

1. Extract a shared event header/footer presentation layer used by both `FeedEventView` and `EventView`.
2. Move profile verification refresh out of card lifecycle and into profile ingestion or a dedicated cache refresher.
3. Add targeted logging for visible-card count, supplement refresh count, and feed render churn.
4. Measure again before touching visible window size further.
