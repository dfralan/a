// a

import Kingfisher
import SDWebImageSwiftUI
import SwiftUI
import LifeHash

// AVATAR VIEW
struct AvatarView: View {
  // The stable identity used to derive LifeHash when an image isn't available
  let publicKey: String

  // Optional avatar image URL
  let url: URL?

  // Render size
  let size: CGFloat

  // MARK: - Initializers

  // Preferred initializer: pass the public key and optional URL
  init(publicKey: String, url: URL? = nil, size: CGFloat) {
    self.publicKey = publicKey
    self.url = url
    self.size = size
  }

  // Backwards-compat convenience: if only size is provided, no URL, empty publicKey
  init(size: CGFloat) {
    self.publicKey = ""
    self.url = nil
    self.size = size
  }

  init(size: CGFloat, border: CGFloat) {
    self.publicKey = ""
    self.url = nil
    self.size = size
  }

  // Backwards-compat convenience: legacy call sites may still pass a URL alone
  init(url: URL?, size: CGFloat) {
    self.publicKey = url?.absoluteString ?? ""
    self.url = url
    self.size = size
  }

  // MARK: - Body

  var body: some View {
    Group {
      if let url = url {
        renderForURL(url)
      } else {
        lifeHashView(for: fallbackIdentityKey)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
  }

  // MARK: - Helpers

  // Main router for URL cases
  @ViewBuilder
  private func renderForURL(_ url: URL) -> some View {
    let absolute = url.absoluteString
    let fallbackKey = PublicKeyIdentity.avatarKey(from: publicKey.isEmpty ? absolute : publicKey)

    if isDataURI(absolute) {
      if let img = imageFromDataURI(absolute) {
        Image(uiImage: img)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        lifeHashView(for: fallbackKey)
      }
    } else if !isRenderableRemoteImageURL(url) {
      lifeHashView(for: fallbackKey)
    } else {
      let ext = url.pathExtension.lowercased()
      switch ext {
      case "jpg", "jpeg", "png":
        KFImage(url)
          // Show LifeHash immediately instead of a placeholder that might never resolve
          .onFailure { _ in }
          .resizable()
          .cancelOnDisappear(true)
          .cacheOriginalImage()
          .aspectRatio(contentMode: .fill)
          // If Kingfisher has not produced an image yet, overlay LifeHash
          .modifier(KFFallbackOverlay(publicKey: fallbackKey, size: size))

      case "gif", "webp", "svg", "":
        AnimatedImage(url: url)
          // Avoid placeholder spinner that can remain forever
          .onFailure { _ in }
          .resizable()
          .aspectRatio(contentMode: .fill)
          // Overlay LifeHash when image hasn’t produced a frame yet
          .modifier(AnimatedFallbackOverlay(publicKey: fallbackKey, size: size))

      default:
        AsyncImage(url: url) { phase in
          switch phase {
          case .success(let image):
            image
              .resizable()
              .aspectRatio(contentMode: .fill)
          case .failure(_):
            lifeHashView(for: fallbackKey)
          case .empty:
            // Immediate fallback to LifeHash instead of a spinner
            lifeHashView(for: fallbackKey)
          @unknown default:
            lifeHashView(for: fallbackKey)
          }
        }
      }
    }
  }

  // Render LifeHash for a given key string
  @ViewBuilder
  private func lifeHashView(for key: String) -> some View {
    let data: Data? = key.isEmpty ? nil : Data(key.utf8)
    UIKitLifeHashView(hashInput: data, version: .version2, size: size)
  }

  private var fallbackIdentityKey: String {
    PublicKeyIdentity.avatarKey(from: publicKey)
  }

  // Detect data URI
  private func isDataURI(_ stringUrl: String) -> Bool {
    let pattern =
      "^data:[^;]+;base64,([a-zA-Z0-9+/]{4})*([a-zA-Z0-9+/]{2}==|[a-zA-Z0-9+/]{3}=)?$"
    return stringUrl.range(of: pattern, options: .regularExpression) != nil
  }

  private func isRenderableRemoteImageURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https" || scheme == "file"
  }

  // Decode data URI into UIImage, no View return here
  private func imageFromDataURI(_ stringUrl: String) -> UIImage? {
    guard let range = stringUrl.range(of: ",") else { return nil }
    let base64String = String(stringUrl[range.upperBound...])
    guard let data = Data(base64Encoded: base64String) else { return nil }
    return UIImage(data: data)
  }
}

// MARK: - Overlays for deterministic fallback

private struct KFFallbackOverlay: ViewModifier {
  let publicKey: String
  let size: CGFloat

  func body(content: Content) -> some View {
    ZStack {
      // LifeHash as base (so user always sees something immediately)
      UIKitLifeHashView(hashInput: Data(publicKey.utf8), version: .version2, size: size)
      // KFImage will render on top once available
      content
    }
  }
}

private struct AnimatedFallbackOverlay: ViewModifier {
  let publicKey: String
  let size: CGFloat

  func body(content: Content) -> some View {
    ZStack {
      // LifeHash as base
      UIKitLifeHashView(hashInput: Data(publicKey.utf8), version: .version2, size: size)
      // Animated image on top once it renders frames
      content
    }
  }
}

struct AvatarView_Previews: PreviewProvider {
  static var previews: some View {
    VStack(spacing: 20) {
      // Only LifeHash (no URL)
      AvatarView(publicKey: "npub1example...", size: 90)

      // With URL (static)
      AvatarView(publicKey: "npub1example...", url: URL(string: "https://example.com/a.png"), size: 90)

      // With URL (animated)
      AvatarView(publicKey: "npub1example...", url: URL(string: "https://example.com/a.gif"), size: 90)

      // Data URI
      AvatarView(publicKey: "npub1example...", url: URL(string: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUA..."), size: 90)
    }
  }
}
