// a

import SwiftUI

struct WelcomeView: View {
  let pendingPublicKey: String
  let onStart: () -> Void

  private let pages = [
    WelcomePage(
      title: "Welcome to Land",
      description: "Read the live feed first. Nothing is saved until you choose to keep a key.",
      systemImage: "sparkles"
    ),
    WelcomePage(
      title: "Explore Freely",
      description: "Open profiles, follow the conversation, and get a feel for the network.",
      systemImage: "globe.americas"
    ),
    WelcomePage(
      title: "Save to Interact",
      description: "When you post, react, or message, Land will ask you to save a key.",
      systemImage: "key"
    ),
  ]

  var body: some View {
    VStack(spacing: 18) {
      AvatarView(publicKey: pendingPublicKey, size: 72)
        .padding(.top, 4)

      VStack(spacing: 4) {
        Text("Pending Key")
          .font(.headline)
        Text(pendingPublicKey.accordionString(index: 10))
          .font(.caption.monospaced())
          .foregroundColor(.secondary)
          .lineLimit(1)
      }

      TabView {
        ForEach(pages) { page in
          VStack(spacing: 10) {
            Image(systemName: page.systemImage)
              .font(.title2)
              .foregroundColor(.accentColor)
              .frame(height: 28)

            Text(page.title)
              .font(.title3)
              .fontWeight(.semibold)
              .multilineTextAlignment(.center)

            Text(page.description)
              .font(.callout)
              .foregroundColor(.secondary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.horizontal, 8)
        }
      }
      .tabViewStyle(.page(indexDisplayMode: .automatic))
      .frame(height: 160)

      Button {
        onStart()
      } label: {
        Text("Comenzar")
          .fontWeight(.semibold)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(22)
    .frame(maxWidth: 360)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .shadow(color: .black.opacity(0.14), radius: 28, x: 0, y: 14)
  }
}

private struct WelcomePage: Identifiable {
  let id = UUID()
  let title: String
  let description: String
  let systemImage: String
}

struct WelcomeView_Previews: PreviewProvider {
  static var previews: some View {
    ZStack {
      Color(uiColor: .systemGroupedBackground)
        .ignoresSafeArea()
      WelcomeView(
        pendingPublicKey: "npub19fm9h69lna6wrejzs4k0pqmssug8pt3z37c5l3jqny9ghu3t4rzq7l3fwq",
        onStart: {}
      )
      .padding()
    }
  }
}
