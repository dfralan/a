// a

import RealmSwift
import SDWebImageSwiftUI
import SwiftUI

struct ProfileDetailView: View {

  // QRVIEW PARAMETERS
  @EnvironmentObject var nostrData: NostrData
  @EnvironmentObject var navigation: Navigation

  // REALM OBJECTS
  @ObservedRealmObject var userProfile: RUserProfile
  @ObservedResults(RContactList.self) var contactLists

  //BOOL THAT INDICATES IF THE PROFILE SHOWED IS FROM CURRENT LOGGED USER
  @State var isFromCurrentUser: Bool = false

  // MENU ACTION SHEET
  @State private var showActionSheet = false
  @State private var principalOpacity: Double = 1.0
  @State private var yOffset: CGFloat = 0

  // PROCESSOR
  @ObservedResults(
    TextNoteVM.self, sortDescriptor: SortDescriptor(keyPath: "createdAt", ascending: false))
  var textNoteResults

  var contactList: RContactList? {
    return contactLists.filter("publicKey = %@", self.userProfile.publicKey).first
  }

  // EVENTS OF USER
  var textNotes: [TextNoteVM] {
    return Array(textNoteResults.filter("publicKey = %@", self.userProfile.publicKey).prefix(100))
  }

  var body: some View {
    let avatarUrl = userProfile.avatarUrl
    let username = userProfile.name.isValidName() ? ("@" + userProfile.name) : "Anonymous"
    let pubkey = userProfile.publicKey

    //CARD
    VStack(alignment: .center) {

      ScrollView {
        VStack(alignment: .center, spacing: 4) {
          // AVATAR
          AvatarView(url: avatarUrl, size: 100)

          // USERNAME
          Text(username)
            .font(.title3).bold()

          //PUBKEY
          HStack(alignment: .center, spacing: 2) {
            Text("\(Text(pubkey.prefix(8)))...")
              .foregroundColor(.gray)

            Image(systemName: "key.horizontal")
          }
          .font(.subheadline)
          .foregroundColor(.secondary)
        }
        .background(
          GeometryReader { geometry in
            Color.clear
              .preference(key: ViewOffsetKey.self, value: geometry.frame(in: .named("scroll")).minY)
          }
        )
        .onPreferenceChange(ViewOffsetKey.self) { offset in
          let maxOpacity: Double = 1.0
          let minOpacity: Double = 0.0

          if offset >= 0 && offset <= 100 {
            principalOpacity = minOpacity
          } else if offset < -100 {
            principalOpacity = maxOpacity
          } else {
            let progress = Double((offset + 100) / 100)
            principalOpacity = maxOpacity - progress * (maxOpacity - minOpacity)
          }
        }

        //ABOUT
        if let about = userProfile.aboutFormatted {

          Text(about)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .lineLimit(5)
            .font(.body)
            .padding()

        }

        //ACTION BUTTON SECTION
        HStack {
          if !isFromCurrentUser {
            Button(action: {}) {
              Text("Follow")
                .font(.subheadline)
            }
            .buttonStyle(.borderedProminent)

          }

          Button(action: {}) {
            Image(systemName: "message")
              .font(.subheadline)
          }
          .buttonStyle(.bordered)

          Button(action: {}) {
            Image(systemName: "bolt")
              .font(.subheadline)
              .foregroundColor(.accentColor)
          }
          .buttonStyle(.bordered)
        }
        //FOLLOWING FOLLOWER COUNTER IF > 0
        if let contactList {
          HStack {
            Button(action: {
              if contactList.following.count > 0 {
                self.navigation.homePath.append(Navigation.NavFollowing(userProfile: userProfile))
              }
            }) {
              Text("Following")
                .foregroundColor(.secondary)
                + Text(" \(contactList.following.count)")

            }

            Button(action: {
              if contactList.followedBy.count > 0 {
                self.navigation.homePath.append(Navigation.NavFollowers(userProfile: userProfile))
              }
            }) {
              Text("Followers")
                .foregroundColor(.secondary)
                + Text(" \(contactList.followedBy.count)")
            }
          }
          .font(.caption)
          .fontWeight(.medium)
          .navigationTitle("")

        }

        Divider()
        LazyVStack(spacing: 20) {
          ForEach(textNotes) { textNote in
            EventView(textNote: textNote)
              .id(textNote.id)
            Divider()
          }
        }
        .padding()
      }
      Spacer()
    }
    .coordinateSpace(name: "scroll")
    // ACTION SHEET PROFILE
    .actionSheet(isPresented: $showActionSheet) {
      ActionSheet(
        title: Text("Opciones"), message: Text("Elija una opción"),
        buttons: [
          .default(Text("Opción 1")) {
            // Acción a realizar al seleccionar la opción 1
          },
          .default(Text("Opción 2")) {
            // Acción a realizar al seleccionar la opción 2
          },
          .cancel(),
        ])
    }

    // FETCH
    .task {
      nostrData.fetchContactList(forPublicKey: userProfile.publicKey)
    }
    .navigationTitle("")

    .toolbar {
      //UserProfileNavigationTitle(userProfile: userProfile)

      ToolbarItem(placement: .principal) {
        HStack {
          // AVATAR
          AvatarView(url: avatarUrl, size: 32)
          VStack(alignment: .leading) {
            // USERNAME
            Text(username)
              .font(.subheadline)
            //PUBKEY
            HStack(alignment: .center, spacing: 2) {
              Text("\(Text(pubkey.prefix(8)))...")
              Image(systemName: "key.horizontal")
            }
            .font(.caption)
            .foregroundColor(.secondary)
          }
        }
        .opacity(principalOpacity)
      }

      if isFromCurrentUser {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: {

            //self.navigation.homePath.append(Navigation.NavEditProfile(userProfile: userProfile))

          }) {
            Text("Edit")

          }
        }

      }

      //QR CODE
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: {
          self.navigation.homePath.append(Navigation.NavQR(userProfile: userProfile))
        }) {
          Image(systemName: "qrcode")
        }
      }

      //ACTION BUTTONS
      ToolbarItem(placement: .navigationBarTrailing) {

        //ACTION SHEET BUTTON
        Button {
          showActionSheet = true
        } label: {
          Image(systemName: "ellipsis")
        }
        .padding(0)
      }
    }
  }
}

struct ViewOffsetKey: PreferenceKey {
  typealias Value = CGFloat
  static var defaultValue = CGFloat.zero
  static func reduce(value: inout Value, nextValue: () -> Value) {
    value += nextValue()
  }
}
