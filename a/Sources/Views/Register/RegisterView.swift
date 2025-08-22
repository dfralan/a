// a

import SwiftUI

struct RegisterView: View {

  @State private var name: String = ""

  @Environment(\.presentationMode) var presentationMode

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 10) {
        Text("What's your name?")
        TextField("", text: $name)
          .textFieldStyle(ClassicTextFieldStyle(text: $name))
          .lineLimit(3)
        HStack {

          Spacer()
          NavigationLink(
            destination:
              HomeView()
          ) {
            Text("Generate key")

          }
          .foregroundColor(.accentColor)
          .buttonStyle(.bordered)
        }
        Spacer()
        NavigationLink {
          KeyManagerView()
        } label: {
          HStack(alignment: .center) {
            Text("Already have an account?")
              .font(.caption)
            Text("Log in")
              .font(.caption).bold()
          }
          .frame(maxWidth: .infinity)
          .foregroundColor(.primary)
        }
      }
      //.navigationBarBackButtonHidden(true)

      .toolbar {
        ToolbarItem(placement: .principal) {
          Text("Register")
        }
      }

      .padding()

      #if os(macOS)

        // TOOLBAR ELEMENTS
        .toolbar {
          ToolbarItem(placement: .navigation) {
            NavigationLink {
              HomeView()
            } label: {
              Text("Cancel")

            }
          }
        }
      #else
        // TOOLBAR ELEMENTS
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            NavigationLink {
              //HomeView()
            } label: {
              Text("Cancel")

            }
          }
        }
      #endif

    }
    .background(.regularMaterial)
  }
}

struct RegisterView_Previews: PreviewProvider {
  static var previews: some View {
    RegisterView()
  }
}
