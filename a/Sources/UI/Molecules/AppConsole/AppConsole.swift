import Foundation
import SwiftData
/// Secured persisted database
import SwiftUI

// Define the AppConsole class
@Model
class AppConsole {
  @Attribute(.unique) var id = UUID().uuidString
  var key: String = ""
  var at: String = ""
  var kind: String = ""
  var content: String = ""
  
  init(key: String = "", at: String = "", kind: String = "", content: String = "") {
    self.key = key
    self.at = at
    self.kind = kind
    self.content = content
  }
}

// Define the AppConsole Manager struct
struct AppConsoleManager {
  let modelContainer: ModelContainer

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
  }

  func addItem(key: String, at: String, kind: String, content: String) {
    let consoleItem = AppConsole(key: key, at: at, kind: kind, content: content)
    let context = ModelContext(modelContainer)
    context.insert(consoleItem)
    try? context.save()
  }

  func getAllItems(kind: String? = nil, key: String? = nil) -> [AppConsole] {
    let context = ModelContext(modelContainer)
    var descriptor = FetchDescriptor<AppConsole>()
    
    if let kind = kind, let key = key {
      descriptor.predicate = #Predicate { $0.kind == kind && $0.key == key }
    } else if let kind = kind {
      descriptor.predicate = #Predicate { $0.kind == kind }
    } else if let key = key {
      descriptor.predicate = #Predicate { $0.key == key }
    }
    
    do {
      return try context.fetch(descriptor)
    } catch {
      print("Error fetching console items: \(error)")
      return []
    }
  }
}

struct EphemeralMessage: Identifiable, Equatable {
  let id = UUID()
  let content: String
}

@MainActor
final class ForegroundActivityNotificationCenter: ObservableObject {
  @Published private(set) var currentItem: ActivityItem?

  private weak var nostrData: NostrData?
  private var observerID: UUID?
  private var activePublicKey: String?
  private var foregroundStartedAtTimestamp = Int64(Date().timeIntervalSince1970)
  private var queuedItems: [ActivityItem] = []
  private var deliveredIDs = Set<String>()
  private var deliveredIDOrder: [String] = []
  private var dismissalTask: Task<Void, Never>?

  private let maximumQueuedItems = 8
  private let maximumDeliveredIDs = 200

  func configure(nostrData: NostrData) {
    guard self.nostrData == nil else { return }

    self.nostrData = nostrData
    observerID = nostrData.observePersistedActivityItems { [weak self] items in
      Task { @MainActor in
        self?.receive(items)
      }
    }
  }

  func activate(publicKey: String?) {
    activePublicKey = publicKey
    foregroundStartedAtTimestamp = Int64(Date().timeIntervalSince1970)
    queuedItems.removeAll()
    deliveredIDs.removeAll()
    deliveredIDOrder.removeAll()
    dismissalTask?.cancel()
    dismissalTask = nil
    currentItem = nil

    guard let publicKey else { return }
    nostrData?.fetchActivity(forPublicKey: publicKey, force: true)
  }

  func dismissCurrent() {
    dismissalTask?.cancel()
    dismissalTask = nil
    withAnimation(.easeInOut(duration: 0.18)) {
      currentItem = nil
    }
    presentNextIfNeeded()
  }

  private func receive(_ items: [ActivityItem]) {
    guard let activePublicKey else { return }

    let eligibleItems = items
      .filter { $0.targetPublicKey == activePublicKey }
      .filter { $0.actorPublicKey != activePublicKey }
      .filter { $0.createdAtTimestamp >= foregroundStartedAtTimestamp }
      .sorted { $0.createdAt < $1.createdAt }

    for item in eligibleItems where rememberDelivery(id: item.id) {
      queuedItems.append(item)
    }
    if queuedItems.count > maximumQueuedItems {
      queuedItems.removeFirst(queuedItems.count - maximumQueuedItems)
    }

    presentNextIfNeeded()
  }

  private func rememberDelivery(id: String) -> Bool {
    guard deliveredIDs.insert(id).inserted else { return false }

    deliveredIDOrder.append(id)
    while deliveredIDOrder.count > maximumDeliveredIDs {
      deliveredIDs.remove(deliveredIDOrder.removeFirst())
    }
    return true
  }

  private func presentNextIfNeeded() {
    guard currentItem == nil, !queuedItems.isEmpty else { return }

    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
      currentItem = queuedItems.removeFirst()
    }
    dismissalTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.dismissCurrent()
      }
    }
  }

  deinit {
    dismissalTask?.cancel()
    guard let observerID else { return }
    let nostrData = nostrData
    Task { @MainActor in
      nostrData?.removePersistedActivityObserver(observerID)
    }
  }
}

struct ForegroundActivityBanner: View {
  let item: ActivityItem
  let onOpen: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: onOpen) {
        HStack(spacing: 10) {
          AvatarView(publicKey: item.actorPublicKey, url: avatarURL, size: 38)

          VStack(alignment: .leading, spacing: 2) {
            Text(title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)

            Text(item.context)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 32, height: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss notification")
    }
    .padding(10)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(.primary.opacity(0.08), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title) \(item.context)")
  }

  private var title: String {
    item.actorName.isValidName()
      ? item.actorName
      : (bech32_pubkey(item.actorPublicKey) ?? item.actorPublicKey).accordionString(index: 10)
  }

  private var avatarURL: URL? {
    let picture = item.actorPicture.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !picture.isEmpty, let url = URL(string: picture), url.scheme != nil else { return nil }
    return url
  }
}

class EfimerousManager: ObservableObject {
  static let shared = EfimerousManager()

  @Published var messages: [EphemeralMessage] = []

  func showMessage(_ message: String) {
    let ephemeralMessage = EphemeralMessage(content: message)

    DispatchQueue.main.async {
      withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
        self.messages.append(ephemeralMessage)
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
        self.messages.removeAll { $0.id == ephemeralMessage.id }
      }
    }
  }
}

// MARK: - Quick ephemeral notification (Does not necessarily belong to App Console)

struct EphemeralNotificationView: View {
  @ObservedObject private var messageManager = EfimerousManager.shared

  var body: some View {
    VStack {
      ForEach(messageManager.messages) { message in
        noti(content: message.content)
      }
    }
  }

}

struct noti: View {

  @State var content: String
  @State private var appear: Bool = true

  var body: some View {
    if appear {
      Text(content)
        .opacity(appear ? 1 : 0)
        .foregroundColor(.white)
        .padding()
        .background(Color.black)
        .cornerRadius(10)
        .onAppear {
          DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
              appear = false

            }
          }
        }

    }
  }
}
