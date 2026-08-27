// a

import SwiftUI

// ANIMATED BACKGROUND
struct AnimatedBackground: View {
  @State var start = UnitPoint(x: -1, y: 0.5)
  @State var end = UnitPoint(x: 1, y: 1)
  @State var blurRadius: CGFloat = 1

  let timer = Timer.publish(every: 0, on: .main, in: .default).autoconnect()
  let colors = [Color.purple, Color.blue, Color.green, Color.yellow, Color.orange, Color.red]

  var body: some View {
    LinearGradient(gradient: Gradient(colors: colors), startPoint: start, endPoint: end)
      .onReceive(timer) { _ in
        withAnimation(Animation.linear(duration: 6).repeatForever(autoreverses: true)) {
          self.start = UnitPoint(x: 1, y: 1)
          self.end = UnitPoint(x: 3, y: -1)
        }
      }
      .edgesIgnoringSafeArea(.all)
      .blur(radius: blurRadius)
  }
}

// ANIMATED BACKGROUND FOR SAT
struct AnimatedSatBackground: View {
  @State var start = UnitPoint(x: -1, y: 0.5)
  @State var end = UnitPoint(x: 1, y: 1)
  @State var blurRadius: CGFloat = 0
  @State var opacity: CGFloat = 0

  let timer = Timer.publish(every: 6, on: .main, in: .default).autoconnect()
  let colors = [Color.yellow, Color.red]

  var body: some View {
    LinearGradient(gradient: Gradient(colors: colors), startPoint: start, endPoint: end)
      .onReceive(timer) { _ in
        withAnimation(Animation.linear(duration: 2).repeatForever(autoreverses: true)) {
          self.start = UnitPoint(x: 1, y: 1)
          self.end = UnitPoint(x: 1, y: -1)
        }
      }
      .edgesIgnoringSafeArea(.all)
      .blur(radius: blurRadius)
      .opacity(opacity)
  }
}

/// Reusable fade mask
struct FadeMask: View {
  var body: some View {
    LinearGradient(
      gradient: Gradient(colors: [
        .clear, .black, .black, .black, .black, .black, .black, .black, .black, .black, .black,
        .black, .black, .black, .black, .black, .black, .black, .black, .black, .black, .black,
        .black, .black, .black, .black, .black, .black, .black, .black, .black, .black, .black,
        .black, .black, .black, .black, .black, .black, .black, .black, .black, .black, .black,
        .clear,
      ]), startPoint: .leading, endPoint: .trailing)
  }
}

// BACKGROUNDS PREVIEW
struct AnimatedBackgroundView_Previews: PreviewProvider {
  static var previews: some View {
    HStack {
      AnimatedBackground(blurRadius: 50)
    }
  }
}
