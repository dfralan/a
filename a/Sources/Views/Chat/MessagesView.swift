// a

import RealmSwift
import SDWebImageSwiftUI
import SwiftUI

struct MessagesView: View {

  @ObservedRealmObject var userProfile: RUserProfile
  @State private var searchText = ""

  var body: some View {
    ZStack {
      HStack {
        ZStack(alignment: .leading) {

          TextField("Search", text: $searchText, axis: .vertical)
            .textFieldStyle(ClassicTextFieldStyle(text: $searchText, paddingLeft: 35))
            .lineLimit(3)
          Button(
            action: {},
            label: {
              Image(systemName: "magnifyingglass")
                .foregroundColor(Color(.gray))
                .font(.system(size: 18))
            }

          ).padding(.horizontal, 10)

        }
        if !searchText.isEmpty {
          Button(
            action: { self.searchText = "" },
            label: {
              Text("Cancel")
                .foregroundColor(.accentColor)
            }

          )
        }
      }
      .padding(.horizontal)

      List {
        ForEach(0...20, id: \.self) { _ in
          NavigationLink(destination: ChatView(userProfile: RUserProfile.preview)) {
            HStack(alignment: .top) {
              //ProfileWebImageView(size: 60, border: 2)
              AvatarView(url: userProfile.avatarUrl, size: 40)
              VStack(alignment: .leading) {
                HStack(spacing: 3) {
                  //usernameView(username: "Fer", nip05: "nostr.ar", extended: false)
                  Text("Alan")
                  Spacer()

                  // SEND & RECEIPT CONFIRMATION
                  Image(systemName: "checkmark")
                    .font(.caption).bold()
                    .foregroundColor(.accentColor)
                  // CREATED AT
                  //MomentConstructorThread(timestamp: "1677955434")
                  Text("created at")
                    .font(.subheadline)
                    .foregroundColor(.primary.opacity(0.3))

                }
                Text(
                  "Sup body, time not seeing that cute litle face, miss u, arru."
                )
                .font(.subheadline)
                .foregroundColor(.gray)

              }
            }
          }

        }

      }
      .listStyle(.plain)

      Spacer()
        .navigationTitle("Messages")

        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            NavigationLink {
              NewChat()
            } label: {
              Image(systemName: "square.and.pencil")
            }
          }
        }
    }
  }
}

struct MessagesView_Previews: PreviewProvider {
  static var previews: some View {
    MessagesView(userProfile: RUserProfile.preview)
  }
}
