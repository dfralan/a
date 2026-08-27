// a

import Foundation
import SwiftUI
import WebKit

// EMBEDED YOUTUBE VIDEO VIEW
#if os(iOS)
  struct EmbededVideoView: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> WKWebView {
      let configuration = WKWebViewConfiguration()
      configuration.allowsInlineMediaPlayback = true
      configuration.mediaTypesRequiringUserActionForPlayback = []
      let webview = WKWebView(frame: .zero, configuration: configuration)
      return webview
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
      uiView.scrollView.isScrollEnabled = false
      let urlAutoplay = url.absoluteString + "?autoplay=1&fs=1"
      let embededLink = urlAutoplay.replacingOccurrences(of: "watch?v=", with: "embed/")
      uiView.load(URLRequest(url: URL(string: embededLink)!))
    }
  }
#elseif os(macOS)
  struct EmbededVideoView: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> WKWebView {
      let view = WKWebView()
      view.autoresizingMask = [.width, .height]
      return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
      guard context.coordinator.needsToLoadURL else { return }
      nsView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> VideoEmbedView.Coordinator {
      Coordinator()
    }

    class Coordinator {
      var needsToLoadURL = true
    }

  }
#endif

struct EmbededVideoView_Previews: PreviewProvider {
  static var previews: some View {
    EmbededVideoView(
      url: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&ab_channel=RickAstley")!
    )
    .frame(height: 200)
  }
}
