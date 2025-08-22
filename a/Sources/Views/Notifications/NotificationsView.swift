// a

import RealmSwift
import SDWebImageSwiftUI
import SwiftUI

// MARK: - Notifications View

struct NotificationsView: View {

  // MARK: - Properties

  /// Select the kind of notifications i want to show, otherwise show all kinds
  @State private var notificationSort = 0

  /// Actual logged user
  @ObservedRealmObject var userProfile: RUserProfile

  /// Notifications Manager
  @ObservedObject var notificationsManager: NotificationManager = NotificationManager()

  // MARK: - Notifications kinds

  var filteredNotifications: [NotificationModel] {
    switch notificationSort {
    case 1:
      /// reactions
      return notificationsManager.notifications.filter { $0.kind == 1 }
    case 2:
      /// comments
      return notificationsManager.notifications.filter { $0.kind == 2 }
    case 3:
      /// sats
      return notificationsManager.notifications.filter { $0.kind == 3 }
    case 4:
      /// follows
      return notificationsManager.notifications.filter { $0.kind == 4 }
    default:
      /// all
      return notificationsManager.notifications
    }
  }

  var body: some View {

    /// View when there is no notifications
    if filteredNotifications.isEmpty {
      VStack {
        Image(systemName: "bell.slash.fill")
          .font(.system(size: 100))
          .foregroundColor(.gray)
        Text("No new notifications")
          .foregroundColor(.gray)
      }
      .padding()
    } else {
      List {
        Section("Notifications") {
          ForEach(filteredNotifications) { notification in
            NavigationLink(destination: SettingsView()) {
              switch notification.kind {

              /// Reaction notification
              case 1:
                HStack(alignment: .center) {
                  AvatarView(url: userProfile.avatarUrl, size: 50)

                  Text(
                    "\(Text(notification.user).bold()) reacted with: \(Text(notification.context)) \(Text(notification.at).foregroundColor(.gray).font(.subheadline))"
                  )
                  .foregroundColor(.primary)
                  .font(.body)

                }
                .lineLimit(2)

              /// New comment notification
              case 2:
                HStack(alignment: .center) {
                  AvatarView(url: userProfile.avatarUrl, size: 50)

                  Text(
                    "\(Text(notification.user).bold()) commented: \(Text(notification.context)) \(Text(notification.at).foregroundColor(.gray).font(.subheadline))"
                  )
                  .foregroundColor(.primary)
                  .font(.body)

                }
                .lineLimit(2)

              /// Zapped notification
              case 3:
                HStack(alignment: .center) {
                  AvatarView(url: userProfile.avatarUrl, size: 50)

                  Text(
                    "\(Text(notification.user).bold()) sent you: \(Text(notification.context))\(Text(Image(systemName: "bolt.fill")).foregroundColor(.yellow)) \(Text(notification.at).foregroundColor(.gray).font(.subheadline))"
                  )
                  .foregroundColor(.primary)
                  .font(.body)

                }
                .lineLimit(2)

              /// New follower notification
              case 4:
                HStack(alignment: .center) {
                  HStack(alignment: .center) {
                    AvatarView(url: userProfile.avatarUrl, size: 50)

                    Text(
                      "\(Text(notification.user).bold()) started following you \(Text(notification.at).foregroundColor(.gray).font(.subheadline))"
                    )
                    .foregroundColor(.primary)
                    .font(.body)

                  }
                  Spacer()

                  /// Follow or following button
                  Button {
                  } label: {
                    Text("Follow")
                      .bold()
                      .foregroundColor(.white)
                  }
                  .buttonStyle(.bordered)
                }
                .lineLimit(2)

              /// Default
              default:
                HStack(alignment: .center) {
                  HStack(alignment: .center) {
                    AvatarView(url: userProfile.avatarUrl, size: 50)

                    Text(
                      "\(Text(notification.user).bold()) started following you \(Text(notification.at).foregroundColor(.gray).font(.subheadline))"
                    )
                    .foregroundColor(.primary)
                    .font(.body)
                  }
                  Spacer()

                  /// Follow or following button
                  Button {
                  } label: {
                    Text("Follow")
                      .bold()
                      .foregroundColor(.white)
                  }
                  .buttonStyle(.bordered)
                }
                .lineLimit(2)
              }
            }
          }
        }
        .navigationTitle("")
      }
      .listStyle(.plain)

      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Picker("Sorter", selection: $notificationSort) {
            Text("All").tag(0)
            Text("Reactions").tag(1)
            Text("Comments").tag(2)
            Text("Sats").tag(3)
          }
        }
      }
    }
  }
}

struct NotificationsView_Previews: PreviewProvider {
  static var previews: some View {
    let userProfile = RUserProfile()  // Replace with your user profile

    return NotificationsView(userProfile: userProfile)
  }
}
