import SwiftUI

struct NavigationLinkItem: Identifiable {
  let id = UUID()
  let title: String
  let url: String
}

struct WalletListView: View {

  var invoiceLink = "c6b18242e67e56820906ca8ad781e71eb2f1a2990a5a892b2bac3f4dae36284f"

  let walletLinks = [
    NavigationLinkItem(title: "Strike", url: "strike:"),
    NavigationLinkItem(title: "Cash App", url: "https://cash.app/launch/lightning/"),
    NavigationLinkItem(title: "Blue Wallet", url: "bluewallet:lightning:"),
    NavigationLinkItem(title: "Wallet of Satoshi", url: "walletofsatoshi:lightning:"),
    NavigationLinkItem(title: "Zebedee", url: "zebedee:lightning:"),
    NavigationLinkItem(title: "Phoenix", url: "phoenix://"),
    NavigationLinkItem(title: "Breez", url: "breez:"),
    NavigationLinkItem(title: "Blixt Wallet", url: "blixtwallet:lightning:"),
    NavigationLinkItem(title: "River", url: "river:"),
  ]

  var body: some View {
    NavigationStack {

      List {
        Section(header: Text("Other Wallets")) {
          HStack {
            Text(invoiceLink)
              .font(.subheadline)
            // MARK: Copy key button
            Button {
              UIPasteboard.general.string = invoiceLink
            } label: {
              Image(systemName: "square.on.square")
            }
          }
        }
        Section(header: Text("Other Wallets")) {
          ForEach(walletLinks) { item in
            NavigationLink(destination: WebView(urlString: item.url)) {
              HStack {
                Image((item.title).replacingOccurrences(of: " ", with: "").lowercased())
                  .resizable()
                  .aspectRatio(contentMode: .fit)
                  .frame(width: 50, height: 50)
                  .cornerRadius(9)

                Text(item.title)
              }
            }
          }
        }
      }
      .navigationBarTitle(Text("Wallet Links"))
    }
  }
}

struct WebView: UIViewRepresentable {
  let urlString: String

  func makeUIView(context: Context) -> UIWebView {
    return UIWebView()
  }

  func updateUIView(_ uiView: UIWebView, context: Context) {
    if let url = URL(string: urlString) {
      uiView.loadRequest(URLRequest(url: url))
    }
  }
}

struct WalletsView_Previews: PreviewProvider {
  static var previews: some View {
    WalletListView()
  }
}
