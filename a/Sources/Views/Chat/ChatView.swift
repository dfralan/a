// a

import RealmSwift
import SDWebImageSwiftUI
import SwiftUI

struct ChatView: View {

  @State private var chatField = ""

  @ObservedRealmObject var userProfile: RUserProfile

  var body: some View {
    VStack {
      ZStack(alignment: .bottom) {
        ScrollView {
          VStack {
            // BUBBLES VIEW
            BubblesView(avatarURL: userProfile.avatarUrl!)
          }

        }

        // FADE MASK
        //.mask(LinearGradient(gradient: Gradient(colors: [.clear, .black, .black, .black, .black, .black, .black, .clear]), startPoint: .bottom, endPoint: .top)).ignoresSafeArea()

        // TEXTFIELD VIEW
        ZStack(alignment: .trailing) {
          TextField("Type a message", text: $chatField, axis: .vertical)
            .textFieldStyle(ClassicTextFieldStyle(text: $chatField, paddingRigth: 35))
            .lineLimit(3)

          // SEND BUTTON
          Button(
            action: {
            },

            label: {
              Image(systemName: "paperplane")
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
            }
          )
          .padding(.horizontal, 10)
        }
        .padding()
      }

      // HIDE KEYBOARD WHEN TAP OUTSIDE THE TEXTFIELD
      #if !os(macOS)
        .onTapGesture {
          UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        // TOOLBAR ELEMENTS
        .toolbar {
          ToolbarItem(placement: .navigationBarLeading) {
            HStack {
              AvatarView(url: userProfile.avatarUrl, size: 40)
              //ProfileWebImageView(size: 30, border: 0)
              //usernameView(username: "Fer", nip05: "nostr.ar", extended: false)
              Text("Alan")
            }
          }
        }
      #else
        // TOOLBAR ELEMENTS
        .toolbar {
          ToolbarItem(placement: .navigation) {
            HStack {
              AvatarView(size: 30, border: 0)
              usernameView(username: "Fer", nip05: "nostr.ar", extended: false)
            }
          }
        }
      #endif

    }
  }
}

struct ChatView_Previews: PreviewProvider {
  static var previews: some View {
    ChatView(userProfile: RUserProfile.preview)
  }
}
