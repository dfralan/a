// a

import SwiftUI

struct ProfilePrimaryView: View {

  // Launching the testNIP in this case

  @State var isFromCurrentUser: Bool = true
  @State private var followed = false
  @State var coverImage: Bool = false

  let username: String = "Alan"

  var body: some View {

    NavigationStack {
      VStack(alignment: .leading) {
        //CoverWebImageView(height: 200)
        HStack {

          // AVATAR
          AvatarView(size: 80)
          Spacer()

          // STATICS
          HStack {
            VStack {
              Text("11")
                .font(.subheadline).bold()

              Text("Relays")
                .lineLimit(1)
            }
            VStack {
              Text("333")
                .font(.subheadline).bold()

              Text("Followers")
                .lineLimit(1)
            }
            VStack {
              Text("222")
                .font(.subheadline).bold()
              Text("Following")
                .lineLimit(1)
            }
          }
        }
        usernameView(username: "Fer", nip05: "nostr.ar", extended: true)

        // PUBKEY
        HStack {
          Button(action: {
          }) {
            HStack(alignment: .center, spacing: 2) {
              Text("032j3l2...nm23k3")
                .lineLimit(1)

              Image(systemName: "key.horizontal")

            }
            .font(.subheadline)
          }

          Image(systemName: "square.on.square.dashed")
            .foregroundColor(.gray)
            .font(.subheadline)

        }
        .padding(.trailing, 50)

        // WEB LINK
        HStack {
          Image(systemName: "link")
            .foregroundColor(.accentColor)
            .font(.subheadline)
            .font(.subheadline)
          Text("www.nostr.ar")
            .lineLimit(1)
            .font(.subheadline)
            .foregroundColor(.accentColor)
        }

        // ACTIONS
        HStack(alignment: .lastTextBaseline) {
          if isFromCurrentUser {
            Button(action: {
            }) {
              Text("Edit profile")
                .font(.subheadline)
            }
            .buttonStyle(.bordered)
            Spacer()
            Button(action: {
            }) {
              Text("Share profile")
                .font(.subheadline)
            }
            .buttonStyle(.bordered)

          } else {
            if followed {
              Button(action: {
              }) {
                Text("Following")
              }
              .buttonStyle(.bordered)

            } else {
              Button(action: {
              }) {
                Text("Follow")
              }
              .buttonStyle(.bordered)

            }
            Spacer()

            NavigationLink(
              destination:
                ChatView(userProfile: RUserProfile())
            ) {
              Image(systemName: "bolt")

            }
            .foregroundColor(.accentColor)
            .buttonStyle(.bordered)

            Button(action: {
            }) {
              Image(systemName: "message")
            }
            .buttonStyle(.bordered)
          }
        }

      }

      .padding(.horizontal)

      //ProfileTabView()
      .toolbar {

        //USERNAME
        ToolbarItem(placement: .navigationBarLeading) {
          Text("@dfralan")
        }

        //QR CODE
        ToolbarItem(placement: .navigationBarTrailing) {

          NavigationLink {
            //QRView(userProfile: RUserProfile())
          } label: {
            Image(systemName: "qrcode")

          }
        }
        //ACTION BUTTONS
        ToolbarItem(placement: .navigationBarTrailing) {

          Menu {
            Button("Share on Profile") {}
            Button("Share on Feed") {}
            Menu("Copy") {
              Button("Copy Event Link...") {}
              Button("Copy Content...") {}
            }

          } label: {
            Label("", systemImage: "ellipsis")
          }

        }

      }
      .ignoresSafeArea(edges: .bottom)

    }
  }

}

struct ProfilePrimaryView_Previews: PreviewProvider {
  static var previews: some View {
    ProfilePrimaryView()
    ProfilePrimaryView(isFromCurrentUser: false)
  }
}
