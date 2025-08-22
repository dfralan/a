// a

import RealmSwift
import SDWebImageSwiftUI
import SwiftUI

struct UserProfileListViewRow: View {

  @ObservedRealmObject var userProfile: RUserProfile

  var body: some View {
    HStack(alignment: .center) {

      // AVATAR
      AvatarView(url: userProfile.avatarUrl, size: 50)

      // USERNAME
      VStack(alignment: .leading, spacing: 4) {

        HStack(alignment: .center) {
          if userProfile.name.isValidName() {
            Text("@" + userProfile.name)
              .font(.subheadline).bold()
          }

          // PUBKEY
          HStack(alignment: .center, spacing: 2) {
            Text(userProfile.publicKey.prefix(8))
            Image(systemName: "key.horizontal")
          }
          .font(.caption)
          .foregroundColor(.secondary)
        }

        if let about = userProfile.aboutFormatted {
          Text(about)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .font(.subheadline)
        }

      }
    }
  }
}

// USER NAME INFO HORIZONTAL FOR PRINCIAPL ITEM ON TOOLBAR
struct UserProfileNavigationTitle: View {

  @ObservedRealmObject var userProfile: RUserProfile

  var body: some View {
    HStack {

      // AVATAR
      AvatarView(url: userProfile.avatarUrl, size: 30)

      // USERNAME
      HStack {
        if userProfile.name.isValidName() {
          Text(userProfile.name)
            .font(.system(.subheadline, weight: .bold))
        }

        // PUBKEY
        HStack(alignment: .center, spacing: 2) {
          Text(userProfile.publicKey.prefix(8))
          Image(systemName: "key.horizontal")
        }
        .font(.caption)
        .foregroundColor(.secondary)
      }
    }
  }
}

struct UserProfileListViewRow_Previews: PreviewProvider {
  static var previews: some View {
    NavigationStack {
      List {
        UserProfileListViewRow(userProfile: RUserProfile.preview)
      }
      .listStyle(.plain)
      .navigationTitle("Profiles")
    }
  }
}
