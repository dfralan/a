// a

import SwiftUI

struct RegisterView: View {
  var body: some View {
    NavigationStack {
      Form {
        Section {
          NavigationLink {
            KeyGen(initialMode: .generate)
          } label: {
            Label("Create New Key", systemImage: "plus.circle")
          }

          NavigationLink {
            KeyGen(initialMode: .importExisting)
          } label: {
            Label("Use Existing Key", systemImage: "square.and.arrow.down")
          }
        } footer: {
          Text("A private key lets you post and sign events. A public key is read-only.")
        }
      }
      .navigationTitle("Set Up Account")
      .navigationBarTitleDisplayMode(.inline)
    }
    .background(.regularMaterial)
  }
}

struct RegisterView_Previews: PreviewProvider {
  static var previews: some View {
    RegisterView()
      .environmentObject(KeyManager())
  }
}
