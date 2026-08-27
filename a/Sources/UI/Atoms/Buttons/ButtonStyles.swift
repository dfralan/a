// a

import SwiftUI

struct aButton: View {
  @State var content: String
  var body: some View {
    ZStack {
      Button(action: {
      }) {
        Text(content)
          .bold()
          .font(.subheadline)
          .foregroundColor(.clear)
          .background(AnimatedBackground(blurRadius: 0))
          .mask(
            Text(content)
              .bold()
              .font(.caption)
          )
      }
      .buttonStyle(.borderedProminent)
      .tint(Color(UIColor.systemBackground))
      .background(AnimatedBackground(blurRadius: 5))

    }
  }
}

struct B_Previews: PreviewProvider {
  static var previews: some View {
    ZStack {
      let content = "Post"
      Button(action: {
      }) {
        Text(content)
          .bold()
          .font(.subheadline)
          .foregroundColor(.clear)
          .background(AnimatedBackground(blurRadius: 0))
          .mask(
            Text(content)
              .bold()
          )
          .font(.subheadline)
      }
      .buttonStyle(.borderedProminent)
      .tint(Color(UIColor.systemBackground))
      .background(AnimatedBackground(blurRadius: 5))

    }
  }
}
