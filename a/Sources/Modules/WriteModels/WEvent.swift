import Foundation
import NostrKit
import RealmSwift
import SwiftUI

class PostEventContent {

  var keyPair: KeyPair
  let content: String
  let timestamp: Date

  init(keyPair: KeyPair, content: String, timestamp: Date = Date()) throws {
    self.keyPair = keyPair
    self.content = content
    self.timestamp = timestamp

    do {
      self.keyPair = try KeyPair(
        privateKey: "df9aae2ac8233ffa210a086c54059d02ba3247dab1130dad968f28f036326a83")
    } catch {
      throw error
    }
  }

  func sendToNostr(relayUrl: URL) {
    DispatchQueue.global(qos: .background).async {
      do {
        let event = try Event(keyPair: self.keyPair, content: self.content)
        let message = ClientMessage.event(event)

        let webSocketTask = URLSession(configuration: .default).webSocketTask(with: relayUrl)

        webSocketTask.resume()

        webSocketTask.send(.string(try message.string())) { error in
          if let error = error {
            print("Error: \(error)")
            webSocketTask.cancel(with: .goingAway, reason: nil)
            return
          }

          webSocketTask.cancel(with: .goingAway, reason: nil)
        }
      } catch {
        print("Error: \(error)")
      }
    }
  }

  func saveToRealm() {
    let event = try! Event(keyPair: keyPair, content: content)

    let realm = try! Realm()
    let realmEvent = RealmEvent()
    realmEvent.id = event.id
    realmEvent.content = content
    realmEvent.timestamp = timestamp

    try! realm.write {
      realm.add(realmEvent)
    }
  }
}

class RealmEvent: Object {
  @objc dynamic var id: String = ""
  @objc dynamic var content: String = ""
  @objc dynamic var timestamp: Date = Date()

  override static func primaryKey() -> String? {
    return "id"
  }
}
