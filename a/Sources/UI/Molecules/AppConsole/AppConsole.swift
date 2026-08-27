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
