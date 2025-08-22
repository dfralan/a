import Foundation
import RealmSwift
/// Secured persisted database
import SwiftUI

// Define the AppConsole class
class AppConsole: Object {
  @objc dynamic var id = UUID().uuidString
  @objc dynamic var key: String = ""
  @objc dynamic var at: String = ""
  @objc dynamic var kind: String = ""
  @objc dynamic var content: String = ""
}

// Define the AppConsole Manager struct
struct AppConsoleManager {
  let realm: Realm

  init() {
    realm = try! Realm()
  }

  func addItem(key: String, at: String, kind: String, content: String) {
    let consoleItem = AppConsole()
    consoleItem.key = key
    consoleItem.at = at
    consoleItem.kind = kind
    consoleItem.content = content

    try! realm.write {
      realm.add(consoleItem)
    }
  }

  func getAllItems(kind: String? = nil, key: String? = nil) -> Results<AppConsole> {
    var predicates: [NSPredicate] = []

    if let kind = kind {
      let kindPredicate = NSPredicate(format: "kind == %@", kind)
      predicates.append(kindPredicate)
    }

    if let key = key {
      let keyPredicate = NSPredicate(format: "key == %@", key)
      predicates.append(keyPredicate)
    }

    let compoundPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    return realm.objects(AppConsole.self).filter(compoundPredicate)
  }
}

class EfimerousManager: ObservableObject {
  static let shared = EfimerousManager()

  @Published var messages: [String] = []

  func showMessage(_ message: String) {
    withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
      messages.append(message)

    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      if let index = self.messages.firstIndex(of: message) {
        self.messages.remove(at: index)
      }
    }
  }
}

// MARK: - Quick ephemeral notification (Does not necessarily belong to App Console)

struct EphemeralNotificationView: View {
  @ObservedObject private var messageManager = EfimerousManager.shared

  var body: some View {
    VStack {
      ForEach(messageManager.messages, id: \.self) { message in
        noti(content: message)
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
