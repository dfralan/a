// a

import SwiftData
import SwiftUI

@Model
class RelayItem: Identifiable {
  @Attribute(.unique) var id = UUID().uuidString
  var address = ""
  var state = StoredRelays.activeState

  init(id: String = UUID().uuidString, address: String = "", state: String = StoredRelays.activeState) {
    self.id = id
    self.address = address
    self.state = state
  }
}

class StoredRelays: ObservableObject {
  static let activeState = "active"
  static let inactiveState = "inactive"

  private static let didBootstrapDefaultRelaysKey = "storedRelays.didBootstrapDefaultRelays"
  private static let persistedRelayItemsKey = "storedRelays.items.v1"

  private let modelContext: ModelContext
  @Published var relayItems: [RelayItem] = []

  private struct PersistedRelayItem: Codable, Equatable {
    var id: String
    var address: String
    var state: String

    init(id: String = UUID().uuidString, address: String, state: String) {
      self.id = id
      self.address = address
      self.state = state
    }

    init(_ item: RelayItem) {
      self.id = item.id
      self.address = item.address
      self.state = item.state
    }
  }

  init(modelContainer: ModelContainer) {
    self.modelContext = ModelContext(modelContainer)
    loadData()
  }

  var activeRelayAddresses: [String] {
    relayItems
      .filter { isActive($0) }
      .compactMap { normalizedRelayAddress($0.address) }
  }

  var activeRelayCount: Int {
    activeRelayAddresses.count
  }

  func ensureDefaultRelays() {
    loadData()

    guard !hasPersistedRelaySnapshot, relayItems.isEmpty else {
      return
    }

    for relay in NostrData.defaultRelayURLs {
      addItem(address: relay, state: Self.activeState)
    }

    UserDefaults.standard.set(true, forKey: Self.didBootstrapDefaultRelaysKey)
    loadData()
  }

  @discardableResult
  func addItem(address: String, state: String = StoredRelays.activeState) -> Bool {
    loadData()

    guard let normalizedAddress = normalizedRelayAddress(address) else {
      loadData()
      return false
    }

    guard !relayItems.contains(where: { $0.address == normalizedAddress }) else {
      loadData()
      return false
    }

    let item = RelayItem(address: normalizedAddress, state: sanitizedState(state))
    modelContext.insert(item)
    try? modelContext.save()
    savePersistedRelayItems((relayItems + [item]).map(PersistedRelayItem.init))
    loadData()
    return true
  }

  func deleteItems(withIDs ids: [String]) {
    for item in relayItems where ids.contains(item.id) {
      modelContext.delete(item)
    }
    try? modelContext.save()
    savePersistedRelayItems(
      relayItems
        .filter { !ids.contains($0.id) }
        .map(PersistedRelayItem.init)
    )
    loadData()
  }

  func setActive(_ isActive: Bool, for item: RelayItem) {
    item.state = isActive ? Self.activeState : Self.inactiveState
    try? modelContext.save()
    savePersistedRelayItems(relayItems.map(PersistedRelayItem.init))
    loadData()
  }

  func isActive(_ item: RelayItem) -> Bool {
    item.state != Self.inactiveState
  }

  func loadData() {
    let descriptor = FetchDescriptor<RelayItem>(
      sortBy: [SortDescriptor(\.address, order: .forward)]
    )

    do {
      let fetchedItems = try modelContext.fetch(descriptor)
      let sanitizedItems = sanitizedRelayItems(from: fetchedItems)

      if let persistedItems = loadPersistedRelayItems() {
        let normalizedPersistedItems = sanitizedPersistedRelayItems(from: persistedItems)
        if normalizedPersistedItems != persistedItems {
          savePersistedRelayItems(normalizedPersistedItems)
        }

        relayItems = mirrorPersistedRelays(normalizedPersistedItems, fetchedItems: sanitizedItems)
      } else {
        relayItems = sanitizedItems
        if !sanitizedItems.isEmpty {
          savePersistedRelayItems(sanitizedItems.map(PersistedRelayItem.init))
        }
      }
    } catch {
      print("Error loading relay items: \(error)")
      relayItems = []
    }
  }

  func deleteAllItems() {
    for item in relayItems {
      modelContext.delete(item)
    }
    try? modelContext.save()
    savePersistedRelayItems([])
    loadData()
  }

  func normalizedRelayAddress(_ address: String) -> String? {
    var trimmed = address
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: " ", with: "")
      .lowercased()

    if trimmed.hasPrefix("https://") {
      trimmed = "wss://" + trimmed.dropFirst("https://".count)
    } else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("ws://") {
      return nil
    } else if !trimmed.hasPrefix("wss://") {
      trimmed = "wss://" + trimmed
    }

    guard let url = URL(string: trimmed),
      url.scheme == "wss",
      url.host != nil
    else {
      return nil
    }

    var normalized = url.absoluteString
    if url.path == "/" && normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }

  private func sanitizedRelayItems(from fetchedItems: [RelayItem]) -> [RelayItem] {
    var seenAddresses = Set<String>()
    var sanitizedItems: [RelayItem] = []
    var didMutate = false

    for item in fetchedItems {
      guard let normalizedAddress = normalizedRelayAddress(item.address) else {
        modelContext.delete(item)
        didMutate = true
        continue
      }

      guard !seenAddresses.contains(normalizedAddress) else {
        modelContext.delete(item)
        didMutate = true
        continue
      }

      seenAddresses.insert(normalizedAddress)
      if item.address != normalizedAddress {
        item.address = normalizedAddress
        didMutate = true
      }
      sanitizedItems.append(item)
    }

    if didMutate {
      try? modelContext.save()
    }

    return sanitizedItems.sorted { $0.address < $1.address }
  }

  private func loadPersistedRelayItems() -> [PersistedRelayItem]? {
    guard hasPersistedRelaySnapshot else {
      return nil
    }

    guard let data = UserDefaults.standard.data(forKey: Self.persistedRelayItemsKey) else {
      return []
    }

    return (try? JSONDecoder().decode([PersistedRelayItem].self, from: data)) ?? []
  }

  private var hasPersistedRelaySnapshot: Bool {
    UserDefaults.standard.object(forKey: Self.persistedRelayItemsKey) != nil
  }

  private func savePersistedRelayItems(_ items: [PersistedRelayItem]) {
    let sanitizedItems = sanitizedPersistedRelayItems(from: items)
    guard let data = try? JSONEncoder().encode(sanitizedItems) else {
      return
    }

    UserDefaults.standard.set(data, forKey: Self.persistedRelayItemsKey)
    UserDefaults.standard.set(true, forKey: Self.didBootstrapDefaultRelaysKey)
  }

  private func sanitizedPersistedRelayItems(from items: [PersistedRelayItem]) -> [PersistedRelayItem] {
    var seenAddresses = Set<String>()
    var sanitizedItems: [PersistedRelayItem] = []

    for item in items {
      guard let normalizedAddress = normalizedRelayAddress(item.address),
        !seenAddresses.contains(normalizedAddress)
      else {
        continue
      }

      seenAddresses.insert(normalizedAddress)
      sanitizedItems.append(
        PersistedRelayItem(
          id: item.id.isEmpty ? UUID().uuidString : item.id,
          address: normalizedAddress,
          state: sanitizedState(item.state)
        )
      )
    }

    return sanitizedItems.sorted { $0.address < $1.address }
  }

  private func mirrorPersistedRelays(
    _ persistedItems: [PersistedRelayItem],
    fetchedItems: [RelayItem]
  ) -> [RelayItem] {
    var didMutate = false
    var mirroredItems: [RelayItem] = []
    var fetchedByID = Dictionary(uniqueKeysWithValues: fetchedItems.map { ($0.id, $0) })
    let fetchedByAddress = Dictionary(fetchedItems.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })

    for persistedItem in persistedItems {
      let item = fetchedByID[persistedItem.id] ?? fetchedByAddress[persistedItem.address]

      if let item {
        if item.id != persistedItem.id {
          item.id = persistedItem.id
          didMutate = true
        }

        if item.address != persistedItem.address {
          item.address = persistedItem.address
          didMutate = true
        }

        if item.state != persistedItem.state {
          item.state = persistedItem.state
          didMutate = true
        }

        fetchedByID[persistedItem.id] = item
        mirroredItems.append(item)
      } else {
        let newItem = RelayItem(
          id: persistedItem.id,
          address: persistedItem.address,
          state: persistedItem.state
        )
        modelContext.insert(newItem)
        mirroredItems.append(newItem)
        didMutate = true
      }
    }

    let persistedIDs = Set(persistedItems.map(\.id))
    for fetchedItem in fetchedItems where !persistedIDs.contains(fetchedItem.id) {
      modelContext.delete(fetchedItem)
      didMutate = true
    }

    if didMutate {
      try? modelContext.save()
    }

    return mirroredItems.sorted { $0.address < $1.address }
  }

  private func sanitizedState(_ state: String) -> String {
    state == Self.inactiveState ? Self.inactiveState : Self.activeState
  }
}

private enum RelayManagerAlert: Identifiable {
  case deleteLastRelays([String])
  case deleteAllRelays
  case deactivateLastRelay

  var id: String {
    switch self {
    case .deleteLastRelays: return "deleteLastRelays"
    case .deleteAllRelays: return "deleteAllRelays"
    case .deactivateLastRelay: return "deactivateLastRelay"
    }
  }
}

struct RelayManager: View {
  @ObservedObject var storedRelays: StoredRelays

  @State private var newAddress = ""
  @State private var alert: RelayManagerAlert?

  init(storedRelays: StoredRelays = NostrData.shared.storedRelays) {
    self._storedRelays = ObservedObject(initialValue: storedRelays)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: 8) {
            TextField("wss://relay.example.com", text: $newAddress)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()

            if !newAddress.isEmpty {
              Button {
                newAddress = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundColor(.secondary)
              }
              .buttonStyle(.borderless)
            }

            Button {
              addRelays()
            } label: {
              Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(newAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        } header: {
          Text("Add Relay")
        } footer: {
          Text("Paste one relay, or several separated by commas.")
        }

        Section {
          if storedRelays.relayItems.isEmpty {
            Label("No relays saved", systemImage: "antenna.radiowaves.left.and.right")
              .foregroundColor(.secondary)
          } else {
            ForEach(storedRelays.relayItems, id: \.id) { item in
              Toggle(
                isOn: Binding(
                  get: { storedRelays.isActive(item) },
                  set: { isActive in
                    setRelay(item, active: isActive)
                  }
                )
              ) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(item.address)
                    .lineLimit(1)
                  Text(storedRelays.isActive(item) ? "Active" : "Inactive")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
              }
              .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                  requestDeleteRelay(item)
                } label: {
                  Label("Delete", systemImage: "trash")
                }
              }
            }
          }
        } header: {
          Text("Relays")
        } footer: {
          Text("Active relays are used to read and publish events.")
        }

        if !storedRelays.relayItems.isEmpty {
          Section {
            Button {
              UIPasteboard.general.string =
                storedRelays.relayItems.map(\.address).sorted().joined(separator: ", ")
              EfimerousManager.shared.showMessage("Copied")
            } label: {
              Label("Copy All Relays", systemImage: "doc.on.doc")
            }

            Button(role: .destructive) {
              alert = .deleteAllRelays
            } label: {
              Label("Delete All Relays", systemImage: "trash")
            }
          }
        }
      }
      .navigationTitle("Relays")
      .navigationBarTitleDisplayMode(.inline)
      .onAppear {
        storedRelays.ensureDefaultRelays()
      }
      .alert(item: $alert) { alert in
        switch alert {
        case .deactivateLastRelay:
          return Alert(
            title: Text("Keep One Relay Active?"),
            message: Text("Without an active relay, the feed cannot receive new events."),
            dismissButton: .default(Text("OK"))
          )

        case .deleteLastRelays(let ids):
          return Alert(
            title: Text("Delete Last Active Relay?"),
            message: Text("Without an active relay, the feed cannot receive events until you add or enable one again."),
            primaryButton: .destructive(Text("Delete")) {
              storedRelays.deleteItems(withIDs: ids)
              NostrData.shared.disconnect()
            },
            secondaryButton: .cancel()
          )

        case .deleteAllRelays:
          return Alert(
            title: Text("Delete All Relays?"),
            message: Text("Without relays, the feed cannot receive events until you add one again."),
            primaryButton: .destructive(Text("Delete All")) {
              storedRelays.deleteAllItems()
              NostrData.shared.disconnect()
            },
            secondaryButton: .cancel()
          )
        }
      }
    }
  }

  private func addRelays() {
    let relayStrings = newAddress
      .split(separator: ",")
      .map { String($0) }

    var didAddRelay = false
    for relay in relayStrings {
      didAddRelay = storedRelays.addItem(address: relay) || didAddRelay
    }

    if didAddRelay {
      NostrData.shared.bootstrapConfiguredRelays()
      newAddress = ""
    } else {
      EfimerousManager.shared.showMessage("Enter a valid wss relay")
    }
  }

  private func setRelay(_ item: RelayItem, active: Bool) {
    if !active && storedRelays.isActive(item) && storedRelays.activeRelayCount <= 1 {
      alert = .deactivateLastRelay
      return
    }

    storedRelays.setActive(active, for: item)

    if active {
      NostrData.shared.bootstrapRelays(relay: item.address)
    } else {
      NostrData.shared.disconnectRelay(urlString: item.address)
    }
  }

  private func requestDeleteRelay(_ item: RelayItem) {
    requestDeleteRelayIDs([item.id])
  }

  private func requestDeleteRelayIDs(_ relayIDs: [String]) {
    let activeRelaysLeft = storedRelays.relayItems.contains {
      !relayIDs.contains($0.id) && storedRelays.isActive($0)
    }

    if !activeRelaysLeft {
      alert = .deleteLastRelays(relayIDs)
      return
    }

    storedRelays.deleteItems(withIDs: relayIDs)
    NostrData.shared.bootstrapConfiguredRelays()
  }
}

struct RelayManager_Previews: PreviewProvider {
  static var previews: some View {
    RelayManager()
  }
}
