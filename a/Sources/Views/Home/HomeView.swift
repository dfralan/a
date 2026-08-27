// a

import Kingfisher
import SwiftData
import SwiftUI

// MARK: - Home View

struct HomeView: View {

  // MARK: - Properties

  private static let feedTopID = "home-feed-top"
  private static let toolbarCollapseOffset: CGFloat = 28
  private static let toolbarScrollDirectionBucketSize: CGFloat = 4
  private static let olderLoadThreshold: CGFloat = 420
  private static let mediaPrefetchNoteLimit = 12
  private static let mediaPrefetchURLLimit = 12
  var onMenuTap: (() -> Void)? = nil
  var onMessagesTap: (() -> Void)? = nil
  var onNotificationsTap: (() -> Void)? = nil

  @State private var textNotesFilter: TextNotesFilter = .global
  @State private var viewIsVisible = true
  @State private var mediaPrefetcher: ImagePrefetcher?
  @State private var prefetchedMediaURLs: [URL] = []
  @StateObject private var feedController = HomeFeedController()
  @StateObject private var toolbarState = ToolbarState()
  @EnvironmentObject var nostrData: NostrData
  @EnvironmentObject var navigation: AppNavigation
  @EnvironmentObject var keyManager: KeyManager
  @EnvironmentObject var coordinator: Coordinator
  @Environment(\.modelContext) private var modelContext
  @State private var guestWelcomeDismissed = false
  @State private var showKeyGenerator = false
  @State private var showVerseInterestsEditor = false
  @State private var didBootstrapRelays = false
  @State private var isToolbarCollapsed = false
  @State private var isNearFeedBottom = false
  @State private var didTriggerOlderLoadForBottomEdge = false
  @State private var olderLoadRequest: OlderLoadRequest?

  @Query var contactLists: [RContactList]
  @Query var verseWatchers: [VerseWatcher]
  @Query var relayItems: [RelayItem]

  /// Text Notes Filter
  enum TextNotesFilter: String {
    case global = "Global"
    case verse = "My Verse"
    case crew = "Crew"

    var systemImage: String {
      switch self {
      case .global: return "globe.americas"
      case .verse: return "sparkles"
      case .crew: return "person.3"
      }
    }
  }

  var textNotes: [FeedItem] {
    feedController.visibleItems
  }

  private var warmTextNotes: [FeedItem] {
    Array(feedController.visibleItems.prefix(Self.mediaPrefetchNoteLimit))
  }

  private var isGuestMode: Bool {
    keyManager.storedKeys.isEmpty
  }

  private var shouldShowGuestWelcome: Bool {
    isGuestMode && !guestWelcomeDismissed
  }

  private var canSignEvents: Bool {
    keyManager.selectedPrivateKeyHex != nil
  }

  private var currentUserPublicKey: String? {
    if let privateKeyHex = keyManager.selectedPrivateKeyHex {
      return privkey_to_pubkey(privkey: privateKeyHex)
    }

    guard case .pub(let publicKeyHex) = decode_bech32_key(keyManager.selectedKey) else {
      return nil
    }
    return publicKeyHex
  }

  private var currentUserContactList: RContactList? {
    guard let currentUserPublicKey else { return nil }
    return contactLists.first { $0.publicKey == currentUserPublicKey }
  }

  private var crewPublicKeys: Set<String> {
    Set(currentUserContactList?.following.map { $0.publicKey } ?? [])
  }

  private var currentVerseWatchers: [VerseWatcher] {
    guard let currentUserPublicKey else { return [] }
    return verseWatchers.filter {
      $0.ownerPublicKey == currentUserPublicKey && $0.isEnabled
    }
  }

  private var currentFeedScope: FeedScope {
    switch textNotesFilter {
    case .global:
      return .global
    case .verse:
      return compiledVerseScope
    case .crew:
      return .crew(pubkeys: crewPublicKeys)
    }
  }

  private var compiledVerseScope: FeedScope {
    let authors = Set(currentVerseWatchers.flatMap(\.publicKeys))
    let hashtags = Set(currentVerseWatchers.flatMap(\.hashtags))
    return .verse(authors: authors, hashtags: hashtags)
  }

  private var hasActiveVerseFilters: Bool {
    currentVerseWatchers.contains {
      !$0.publicKeys.isEmpty || !$0.hashtags.isEmpty
    }
  }

  private var shouldHideFeedHeader: Bool {
    isToolbarCollapsed && navigation.isAtRoot && !shouldShowGuestWelcome
  }

  private var feedHeaderVisibility: Visibility {
    shouldHideFeedHeader ? .hidden : .visible
  }

  private var hasSavedRelays: Bool {
    !relayItems.isEmpty
  }

  private var hasActiveRelays: Bool {
    relayItems.contains { $0.state != StoredRelays.inactiveState }
  }

  private var shouldShowRelayEmptyState: Bool {
    !shouldShowGuestWelcome
      && textNotes.isEmpty
      && !feedController.isLoadingOlder
      && (!hasSavedRelays || !hasActiveRelays)
  }

  private var shouldShowFeedEmptyState: Bool {
    !shouldShowRelayEmptyState
      && !shouldShowGuestWelcome
      && textNotes.isEmpty
      && !feedController.isLoadingOlder
      && feedController.hasReachedOlderEnd
  }

  var body: some View {
    ZStack(alignment: .bottom) {
        VStack {
          ScrollViewReader { reader in
            ScrollView {
              // MARK: - Main Events Iteration

              LazyVStack(alignment: .leading, spacing: 20) {
                Color.clear
                  .frame(height: 1)
                  .id(Self.feedTopID)

                if shouldShowRelayEmptyState {
                  relayEmptyState
                } else if shouldShowFeedEmptyState {
                  feedEmptyState
                } else {
                  ForEach(textNotes, id: \.id) { textNote in
                    EventView(feedItem: textNote, onInteractionRequiresKey: requestKeySetup)/// Displays an EventView with the given textNote
                      .id(textNote.id)/// Identifies the EventView using the stable Nostr event ID
                      .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                  }

                  olderFeedLoader
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding()/// Adds padding to the LazyVStack
              .padding(.bottom, 96)
            }
            .onScrollGeometryChange(for: FeedScrollState.self) { geometry in
              let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
              let bottomDistance = max(0, geometry.contentSize.height - visibleBottom)

              return FeedScrollState(
                isBeyondToolbarCollapseOffset: geometry.contentOffset.y > Self.toolbarCollapseOffset,
                scrollOffsetBucket: Int(
                  max(0, geometry.contentOffset.y) / Self.toolbarScrollDirectionBucketSize
                ),
                isNearBottom: bottomDistance <= Self.olderLoadThreshold,
                bottomDistanceBucket: Int(bottomDistance / 48)
              )
            } action: { previousState, scrollState in
              updateFeedScrollState(from: previousState, to: scrollState)
            }
            .onDisappear {
              viewIsVisible = false
              isNearFeedBottom = false
              didTriggerOlderLoadForBottomEdge = false
              olderLoadRequest = nil
              mediaPrefetcher?.stop()
              mediaPrefetcher = nil
              prefetchedMediaURLs.removeAll()
              /// Sets the viewIsVisible property to false when the ScrollView disappears
            }

            .onAppear {
              viewIsVisible = true
              feedController.configure(modelContainer: nostrData.modelContainer, nostrData: nostrData)
              applyFeedScope()
              feedController.bootstrap()
              if nostrData.isNetworkEnabled, !didBootstrapRelays {
                nostrData.bootstrapConfiguredRelays()
                didBootstrapRelays = true
              }
              /// Bootstraps configured relays once so the app works out of the box
              fetchCurrentUserFollowList()
              prefetchWarmMedia()
            }
            .refreshable {
              guard feedController.pendingNewerCount > 0 else { return }
              returnToLatest()
            }

            /// Home tapped listener
            .onChange(of: toolbarState.homeTapped) { _, _ in
              expandToolbar()
              if !navigation.isAtRoot {
                navigation.popToRoot()
                /// Clears the home navigation stack when the user taps Home
              }
              if viewIsVisible {
                if feedController.hasPrunedNewerItems {
                  feedController.refreshToLatest()
                  prefetchWarmMedia()
                }
                withAnimation {
                  reader.scrollTo(Self.feedTopID, anchor: .top)
                  /// Scrolls to the top of the ScrollView using the ID of the first textNote
                }
              }
            }
          }
        }

        // MARK: - Floating Toolbar

        floatingToolbarView(
          toolbarState: toolbarState,
          canInteract: canSignEvents,
          onInteractionRequiresKey: requestKeySetup,
          onMenuTap: openMenu,
          onProfileTap: openCurrentProfile,
          onMessagesTap: openMessages,
          isCollapsed: isToolbarCollapsed
        )
        .padding(.horizontal)
        .padding(.bottom, 8)

        if shouldShowGuestWelcome {
          Rectangle()
            .fill(.ultraThinMaterial)
            .ignoresSafeArea()
            .transition(.opacity)

          WelcomeView(
            pendingPublicKey: keyManager.pendingPublicKey,
            onStart: {
              withAnimation(.spring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.2)) {
                guestWelcomeDismissed = true
              }
            }
          )
          .padding()
          .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
      }
      .sheet(isPresented: $showKeyGenerator) {
        KeyGen(initialMode: .generate)
          .environmentObject(keyManager)
      }
      .sheet(isPresented: $showVerseInterestsEditor) {
        if let currentUserPublicKey {
          VerseWatchersEditor(
            ownerPublicKey: currentUserPublicKey,
            onChange: {
              applyFeedScope()
            }
          )
        }
      }
      .onChange(of: keyManager.storedKeys.isEmpty) { _, isEmpty in
        if isEmpty {
          guestWelcomeDismissed = false
        } else {
          guestWelcomeDismissed = true
          showKeyGenerator = false
          fetchCurrentUserFollowList()
        }
      }
      .onChange(of: keyManager.selectedKey) { _, _ in
        fetchCurrentUserFollowList()
        applyFeedScope()
      }
      .onChange(of: textNotesFilter) { _, _ in
        applyFeedScope()
      }
      .onChange(of: currentFeedScope) { _, _ in
        applyFeedScope()
      }
      .onChange(of: coordinator.attachmentLoadingMode) { _, _ in
        prefetchWarmMedia()
      }
      .onChange(of: feedController.visibleItems.count) { _, _ in
        prefetchWarmMedia()
      }
      .task(id: olderLoadRequest) {
        guard let olderLoadRequest else { return }
        await Task.yield()
        requestOlderFeedPage(reason: olderLoadRequest.reason)
      }

      .overlay(alignment: .top) {
        Group {
          if feedController.pendingNewerCount > 0 && !shouldShowGuestWelcome {
            NewPostsCounterButton(count: feedController.pendingNewerCount) {
              returnToLatest()
            }
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
          }
        }
        .animation(
          .spring(response: 0.24, dampingFraction: 0.86),
          value: feedController.pendingNewerCount > 0
        )
      }

      // MARK: - Title

      .navigationTitle(textNotesFilter.rawValue)
      .navigationBarTitleDisplayMode(.inline)
      .navigationBarBackButtonHidden(true)
      .toolbar(feedHeaderVisibility, for: .navigationBar)
      .toolbarTitleMenu {
        Picker("Feed", selection: $textNotesFilter) {
          feedFilterLabel(.global)
            .tag(TextNotesFilter.global)
          feedFilterLabel(.crew)
            .tag(TextNotesFilter.crew)
          feedFilterLabel(.verse)
            .tag(TextNotesFilter.verse)
        }
        .pickerStyle(.inline)

        Divider()

        Button {
          openVerseInterestsEditor()
        } label: {
          Label("Edit My Verse", systemImage: "slider.horizontal.3")
        }
      }

      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: openSearch) {
            Image(systemName: "safari.fill")
          }
          .accessibilityLabel("Search")
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: openNotifications) {
            Image(systemName: "heart.fill")
          }
          .accessibilityLabel("Activity")
        }
      }
  }

  private func feedFilterLabel(_ filter: TextNotesFilter) -> some View {
    Label(filter.rawValue, systemImage: filter.systemImage)
  }

  @ViewBuilder
  private var relayEmptyState: some View {
    ContentUnavailableView(
      hasSavedRelays ? "No Active Relays" : "No Relays",
      systemImage: "antenna.radiowaves.left.and.right",
      description: Text(
        hasSavedRelays
          ? "Turn on at least one relay to load posts."
          : "Add a relay to start loading posts."
      )
    )
    .frame(maxWidth: .infinity)
    .padding(.top, 96)
  }

  @ViewBuilder
  private var feedEmptyState: some View {
    ContentUnavailableView(
      feedEmptyStateTitle,
      systemImage: feedEmptyStateSystemImage,
      description: Text(feedEmptyStateDescription)
    )
    .frame(maxWidth: .infinity)
    .padding(.top, 96)
  }

  private var feedEmptyStateTitle: String {
    switch textNotesFilter {
    case .global:
      return "No Posts Yet"
    case .verse:
      return hasActiveVerseFilters ? "No My Verse Posts" : "No Active Watchers"
    case .crew:
      return "No Crew Posts"
    }
  }

  private var feedEmptyStateDescription: String {
    switch textNotesFilter {
    case .global:
      return "No recent posts were returned by your active relays."
    case .verse:
      return hasActiveVerseFilters
        ? "No recent posts match your active watchers."
        : "Add a watcher to build your My Verse feed."
    case .crew:
      return "Follow people to build your Crew feed."
    }
  }

  private var feedEmptyStateSystemImage: String {
    switch textNotesFilter {
    case .global:
      return "message"
    case .verse:
      return "sparkles"
    case .crew:
      return "person.3"
    }
  }

  private func requestKeySetup() {
    guestWelcomeDismissed = true
    showKeyGenerator = true
  }

  private func returnToLatest() {
    guard feedController.refreshToLatest() > 0 else { return }

    prefetchWarmMedia()
    expandToolbar()
    toolbarState.homeTapped += 1
  }

  private func openMessages() {
    guard canSignEvents else {
      requestKeySetup()
      return
    }

    onMessagesTap?()
  }

  private func updateToolbarCollapseState(from previousState: FeedScrollState, to scrollState: FeedScrollState) {
    guard viewIsVisible, !shouldShowGuestWelcome else {
      expandToolbar()
      return
    }

    guard scrollState.isBeyondToolbarCollapseOffset else {
      expandToolbar()
      return
    }

    if scrollState.scrollOffsetBucket < previousState.scrollOffsetBucket {
      expandToolbar()
    } else if scrollState.scrollOffsetBucket > previousState.scrollOffsetBucket {
      setToolbarCollapsed(true)
    }
  }

  private func expandToolbar() {
    setToolbarCollapsed(false)
  }

  private func setToolbarCollapsed(_ isCollapsed: Bool) {
    guard isToolbarCollapsed != isCollapsed else { return }

    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
      isToolbarCollapsed = isCollapsed
    }
  }

  private func updateFeedScrollState(from previousState: FeedScrollState, to scrollState: FeedScrollState) {
    updateToolbarCollapseState(from: previousState, to: scrollState)
    updateOlderLoadProximity(isNearBottom: scrollState.isNearBottom)
  }

  private func updateOlderLoadProximity(isNearBottom: Bool) {
    guard viewIsVisible, !shouldShowGuestWelcome else {
      isNearFeedBottom = false
      didTriggerOlderLoadForBottomEdge = false
      return
    }

    if !isNearBottom {
      isNearFeedBottom = false
      didTriggerOlderLoadForBottomEdge = false
      return
    }

    isNearFeedBottom = true
    guard !didTriggerOlderLoadForBottomEdge else { return }
    didTriggerOlderLoadForBottomEdge = true
    olderLoadRequest = OlderLoadRequest(reason: "bottom-edge")
  }

  private func requestOlderFeedPage(reason: String) {
    guard viewIsVisible,
      !shouldShowGuestWelcome,
      !shouldShowRelayEmptyState,
      !shouldShowFeedEmptyState,
      feedController.canLoadOlder,
      !feedController.isLoadingOlder
    else {
      return
    }

    feedController.loadOlder(trigger: reason)
  }

  private func openMenu() {
    onMenuTap?()
  }

  private func openSearch() {
    navigation.popToRoot()
    navigation.push(.search)
  }

  private func openNotifications() {
    guard currentUserPublicKey != nil else {
      requestKeySetup()
      return
    }

    onNotificationsTap?()
  }

  private func openCurrentProfile() {
    guard let currentUserPublicKey else {
      requestKeySetup()
      return
    }

    navigation.popToRoot()
    navigation.push(.profile(publicKey: currentUserPublicKey))
  }

  private func openVerseInterestsEditor() {
    guard currentUserPublicKey != nil else {
      requestKeySetup()
      return
    }

    showVerseInterestsEditor = true
  }

  private func fetchCurrentUserFollowList() {
    guard let currentUserPublicKey else { return }
    nostrData.fetchContactList(forPublicKey: currentUserPublicKey)
  }

  @ViewBuilder
  private var olderFeedLoader: some View {
    if feedController.isLoadingOlder {
      FeedSkeletonBatch(count: 2)
    } else if feedController.canLoadOlder {
      Color.clear
        .frame(height: 24)
        .accessibilityHidden(true)
    } else if feedController.hasReachedOlderEnd && !textNotes.isEmpty {
      Text("No earlier posts")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
  }

  private func applyFeedScope() {
    let scope = currentFeedScope
    nostrData.updateTextNoteFeedScope(scope.textNoteFeedScope)
    feedController.setScope(scope)
    prefetchWarmMedia()
  }

  private func prefetchWarmMedia() {
    var seenURLs = Set<URL>()
    var urls: [URL] = []

    for textNote in warmTextNotes where urls.count < Self.mediaPrefetchURLLimit {
      guard shouldPrefetchMedia(for: textNote) else { continue }

      for imageURL in EventRenderCache.shared.rendered(for: EventViewModel(feedItem: textNote)).imageUrls
        where seenURLs.insert(imageURL).inserted
      {
        urls.append(imageURL)
        if urls.count == Self.mediaPrefetchURLLimit {
          break
        }
      }
    }

    guard urls != prefetchedMediaURLs else { return }
    prefetchedMediaURLs = urls

    guard !urls.isEmpty else {
      mediaPrefetcher?.stop()
      mediaPrefetcher = nil
      return
    }

    mediaPrefetcher?.stop()
    mediaPrefetcher = ImagePrefetcher(urls: urls)
    mediaPrefetcher?.start()
  }

  private func shouldPrefetchMedia(for textNote: FeedItem) -> Bool {
    switch coordinator.selectedAttachmentLoadingMode {
    case .automatically:
      return true
    case .askFirst:
      return false
    case .sensitiveOnly:
      return !textNote.isSensitiveContent
    }
  }
}

private struct FeedScrollState: Equatable {
  let isBeyondToolbarCollapseOffset: Bool
  let scrollOffsetBucket: Int
  let isNearBottom: Bool
  let bottomDistanceBucket: Int
}

private struct OlderLoadRequest: Equatable, Identifiable {
  let id = UUID()
  let reason: String
}

private struct FeedSkeletonBatch: View {
  let count: Int

  var body: some View {
    ForEach(0..<count, id: \.self) { _ in
      EventSkeletonView()
      Divider()
    }
  }
}

private struct VerseWatchersEditor: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  let ownerPublicKey: String
  let onChange: () -> Void

  @Query private var watchers: [VerseWatcher]
  @State private var draft: VerseWatcherDraft?

  init(ownerPublicKey: String, onChange: @escaping () -> Void) {
    self.ownerPublicKey = ownerPublicKey
    self.onChange = onChange

    let owner = ownerPublicKey
    let descriptor = FetchDescriptor<VerseWatcher>(
      predicate: #Predicate { $0.ownerPublicKey == owner },
      sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
    )
    _watchers = Query(descriptor)
  }

  private var sortedWatchers: [VerseWatcher] {
    watchers.sorted {
      if $0.updatedAt == $1.updatedAt {
        return $0.title < $1.title
      }

      return $0.updatedAt > $1.updatedAt
    }
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          if sortedWatchers.isEmpty {
            ContentUnavailableView("No Watchers", systemImage: "sparkles")
          } else {
            ForEach(sortedWatchers, id: \.id) { watcher in
              VerseWatcherRow(
                watcher: watcher,
                isEnabled: Binding(
                  get: { watcher.isEnabled },
                  set: { setWatcher(watcher, isEnabled: $0) }
                ),
                onEdit: {
                  draft = VerseWatcherDraft(watcher: watcher)
                }
              )
              .swipeActions {
                Button(role: .destructive) {
                  deleteWatcher(watcher)
                } label: {
                  Label("Delete", systemImage: "trash")
                }
              }
            }
          }
        } header: {
          Text("Watchers")
        }

        Section {
          Button {
            draft = VerseWatcherDraft(ownerPublicKey: ownerPublicKey)
          } label: {
            Label("New Watcher", systemImage: "plus")
          }
        }
      }
      .navigationTitle("My Verse")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .sheet(item: $draft) { draft in
        VerseWatcherDraftEditor(
          draft: draft,
          onCancel: {
            self.draft = nil
          },
          onSave: { savedDraft in
            saveDraft(savedDraft)
          }
        )
      }
    }
  }

  private func setWatcher(_ watcher: VerseWatcher, isEnabled: Bool) {
    watcher.isEnabled = isEnabled
    watcher.updatedAt = Date()
    saveChanges()
  }

  private func deleteWatcher(_ watcher: VerseWatcher) {
    withAnimation {
      modelContext.delete(watcher)
      saveChanges()
    }
  }

  private func saveDraft(_ draft: VerseWatcherDraft) {
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let termsText = draft.termsText.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !title.isEmpty || !termsText.isEmpty else {
      self.draft = nil
      return
    }

    let watcher = draft.watcher ?? VerseWatcher(ownerPublicKey: ownerPublicKey)
    watcher.title = title.isEmpty ? "Watcher" : title
    watcher.termsText = termsText
    watcher.isEnabled = draft.isEnabled
    watcher.updatedAt = Date()

    if draft.watcher == nil {
      modelContext.insert(watcher)
    }

    saveChanges()
    self.draft = nil
  }

  private func saveChanges() {
    try? modelContext.save()
    onChange()
  }
}

private struct VerseWatcherRow: View {
  let watcher: VerseWatcher
  @Binding var isEnabled: Bool
  let onEdit: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Button(action: onEdit) {
        VStack(alignment: .leading, spacing: 4) {
          Text(watcher.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Watcher" : watcher.title)
            .font(.body)
            .foregroundStyle(.primary)

          Text(watcher.summaryText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)

      Toggle("", isOn: $isEnabled)
        .labelsHidden()
    }
    .contentShape(Rectangle())
  }
}

private struct VerseWatcherDraft: Identifiable {
  let id: String
  let watcher: VerseWatcher?
  var title: String
  var termsText: String
  var isEnabled: Bool

  init(ownerPublicKey: String) {
    self.id = UUID().uuidString
    self.watcher = nil
    self.title = ""
    self.termsText = ""
    self.isEnabled = true
  }

  init(watcher: VerseWatcher) {
    self.id = watcher.id
    self.watcher = watcher
    self.title = watcher.title
    self.termsText = watcher.termsText
    self.isEnabled = watcher.isEnabled
  }
}

private struct VerseWatcherDraftEditor: View {
  @Environment(\.dismiss) private var dismiss

  @State private var title: String
  @State private var termsText: String
  @State private var isEnabled: Bool

  let draft: VerseWatcherDraft
  let onCancel: () -> Void
  let onSave: (VerseWatcherDraft) -> Void

  init(
    draft: VerseWatcherDraft,
    onCancel: @escaping () -> Void,
    onSave: @escaping (VerseWatcherDraft) -> Void
  ) {
    self.draft = draft
    self.onCancel = onCancel
    self.onSave = onSave
    _title = State(initialValue: draft.title)
    _termsText = State(initialValue: draft.termsText)
    _isEnabled = State(initialValue: draft.isEnabled)
  }

  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !termsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $title)
            .textInputAutocapitalization(.words)
        }

        Section {
          TextField("#bitcoin, #nostr, npub1...", text: $termsText, axis: .vertical)
            .lineLimit(4...8)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("Filters")
        }

        Section {
          Toggle("Enabled", isOn: $isEnabled)
        }
      }
      .navigationTitle(draft.watcher == nil ? "New Watcher" : "Watcher")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onCancel()
            dismiss()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            var savedDraft = draft
            savedDraft.title = title
            savedDraft.termsText = termsText
            savedDraft.isEnabled = isEnabled
            onSave(savedDraft)
            dismiss()
          }
          .disabled(!canSave)
        }
      }
    }
  }
}

private struct EventSkeletonView: View {
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Circle()
        .fill(Color.secondary.opacity(0.18))
        .frame(width: 44, height: 44)

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Capsule()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 132, height: 14)

          Capsule()
            .fill(Color.secondary.opacity(0.12))
            .frame(width: 36, height: 12)

          Spacer()
        }

        VStack(alignment: .leading, spacing: 7) {
          Capsule()
            .fill(Color.secondary.opacity(0.16))
            .frame(maxWidth: .infinity, minHeight: 13, maxHeight: 13)
          Capsule()
            .fill(Color.secondary.opacity(0.14))
            .frame(maxWidth: 260, minHeight: 13, maxHeight: 13)
        }

        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Color.secondary.opacity(0.12))
          .aspectRatio(4 / 3, contentMode: .fit)

        Capsule()
          .fill(Color.secondary.opacity(0.14))
          .frame(width: 58, height: 18)
      }
    }
    .redacted(reason: .placeholder)
    .padding(.vertical, 2)
  }
}

struct HomeView_Previews: PreviewProvider {
  static var previews: some View {
	    HomeView()
	      .environmentObject(AppNavigation())
	      .environmentObject(NostrData.shared.initPreview())
	      .environmentObject(Coordinator())
	      .environmentObject(KeyManager())
	      .modelContainer(NostrData.shared.modelContainer)
	  }
}
