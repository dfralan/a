// a

import Combine
import SwiftUI

// MARK: - Notification Data Module

class NotificationModel: ObservableObject, Identifiable {
  @Published var id = UUID()
  @Published var user: String
  @Published var kind: Int
  @Published var context: String
  @Published var at: String

  init(user: String, kind: Int, context: String, at: String) {
    self.user = user
    self.kind = kind
    self.context = context
    self.at = at
  }
}

// MARK: - Notification Manager

class NotificationManager: ObservableObject {
  @Published var notifications: [NotificationModel] = []

  init() {

    notifications.append(
      NotificationModel(user: "John", kind: 1, context: "😂", at: "10 minutes ago"))
    notifications.append(
      NotificationModel(user: "Sarah", kind: 2, context: "Hello handsome 😘", at: "1 hour ago"))
    notifications.append(NotificationModel(user: "Mike", kind: 3, context: "300", at: "2 days ago"))
    notifications.append(
      NotificationModel(user: "Emily", kind: 4, context: "Started following you", at: "1 week ago"))
  }

  private func processNotification(_ notification: NotificationModel) {
    // Handle the received notification
    DispatchQueue.main.async {
      self.notifications.append(notification)
    }
  }
}
