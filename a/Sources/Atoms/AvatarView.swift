// a

import Kingfisher
import SDWebImageSwiftUI
import SwiftUI

// AVATAR VIEW CONSTRUCTOR
struct AvatarView: View {
  @State var url = URL(string: "puf2gnnuafcc8uxmwueq40duxzhx83xkrelmu29sdrlz699f6vhsxs93y2rtr5rt")
  @State var size: CGFloat = 20

  var body: some View {
    if let StringUrl = url?.absoluteString {
      let pattern = "^[a-z0-9]{64}$"
      let patternURI =
        "^data:[^;]+;base64,([a-zA-Z0-9+/]{4})*([a-zA-Z0-9+/]{2}==|[a-zA-Z0-9+/]{3}=)?$"
      if StringUrl.range(of: pattern, options: .regularExpression) != nil {
        RMGenerator(url: url, size: size)
          .frame(width: size, height: size)
          .clipShape(Circle())
      } else if StringUrl.range(of: patternURI, options: .regularExpression) != nil {
        if let range = StringUrl.range(of: ",") {
          let base64String = String(StringUrl[range.upperBound...])
          if let data = Data(base64Encoded: base64String),
            let image = UIImage(data: data)
          {
            Image(uiImage: image)
              .resizable()
              .clipShape(Circle())
              .frame(width: size, height: size)
          }
        }
      } else if let pathExtension = url?.pathExtension {
        switch pathExtension.lowercased() {

        case "jpg", "jpeg", "png":

          if let url {
            KFImage(url)
              .onProgress { receivedSize, totalSize in }
              .onSuccess { result in }
              .onFailure { error in }
              .placeholder {
                ProgressView()
              }
              .cacheOriginalImage()
              .resizable()
              .aspectRatio(contentMode: .fill)
              .clipShape(Circle())
              .frame(width: size, height: size)
              .transition(.fade(duration: 1))

          } else {
            RMGenerator(url: url, size: size)

          }

        case "gif", "webp", "svg", "":
          AnimatedImage(url: url)
            .placeholder {
              ProgressView()
            }
            .resizable()
            .aspectRatio(contentMode: .fill)
            .clipShape(Circle())
            .frame(width: size, height: size)
        default:
          AsyncImage(url: url) { phase in
            if let image = phase.image {
              image  // Displays the loaded image.
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(Circle())
            } else if phase.error != nil {
              RMGenerator(url: url, size: size)
            } else {
              ProgressView()
            }
          }

          .frame(width: size, height: size)
        }
      } else {
        RMGenerator(url: url, size: size)
      }

    } else {
      RMGenerator(url: url, size: size)
    }
  }
}

struct AvatarView_Previews: PreviewProvider {
  static var previews: some View {
    AvatarView(size: 90)
  }
}
