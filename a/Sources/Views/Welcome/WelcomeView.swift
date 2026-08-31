// a

import SwiftUI

struct WelcomeView: View {
  let pendingPublicKey: String
  let onStart: () -> Void

  private let pages = [
    WelcomePage(
      title: "Welcome to a",
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
      description: "When you post, react, or message, you'll be asked to save a key.",
      systemImage: "key"
    ),
  ]

  var body: some View {
    welcomeDialog
      .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var welcomeDialog: some View {
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

struct ALogoView: View {
  let drawProgress: CGFloat

  init(drawProgress: CGFloat = 1) {
    self.drawProgress = drawProgress
  }

  var body: some View {
    GeometryReader { geometry in
      let side = min(geometry.size.width, geometry.size.height)
      let strokeWidth = side * 11 / 51

      ALogoPath()
        .trim(from: 0, to: drawProgress)
        .stroke(
          Color.primary,
          style: StrokeStyle(
            lineWidth: strokeWidth,
            lineCap: .butt,
            lineJoin: .miter
          )
        )
        .frame(width: side, height: side)
        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
    }
    .clipped()
    .aspectRatio(1, contentMode: .fit)
    .scaleEffect(x: 0.9, y: 1, anchor: .bottom)
    .rotation3DEffect(
      .degrees(10),
      axis: (x: 1, y: 0, z: 0),
      anchor: .bottom,
      perspective: 0.46
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("a")
  }
}

struct AppLaunchCurtain: View {
  let onFinished: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var drawProgress: CGFloat = 0
  @State private var curtainOpacity: CGFloat = 1

  var body: some View {
    GeometryReader { geometry in
      let logoSide = min(geometry.size.width * 0.15, 60)

      ZStack {
        Color(uiColor: .systemBackground)

        ALogoView(drawProgress: drawProgress)
          .frame(width: logoSide, height: logoSide)
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .ignoresSafeArea()
    .opacity(curtainOpacity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("a")
    .onAppear(perform: play)
  }

  private func play() {
    guard !reduceMotion else {
      onFinished()
      return
    }

    withAnimation(.easeInOut(duration: 1.2), completionCriteria: .logicallyComplete) {
      drawProgress = 1
    } completion: {
      withAnimation(.easeInOut(duration: 0.46), completionCriteria: .logicallyComplete) {
        curtainOpacity = 0
      } completion: {
        onFinished()
      }
    }
  }
}

private enum ALogoGeometry {
  private static let sourceSize: CGFloat = 51
  private static let sourcePoints = [
    CGPoint(x: 25.5, y: 20),
    CGPoint(x: 25.5, y: 45.5),
    CGPoint(x: 5.5, y: 45.5),
    CGPoint(x: 5.5, y: 5.5),
    CGPoint(x: 45.5, y: 5.5),
    CGPoint(x: 45.5, y: 51),
  ]

  static func points(in rect: CGRect) -> [CGPoint] {
    sourcePoints.map { sourcePoint in
      CGPoint(
        x: rect.minX + (sourcePoint.x / sourceSize) * rect.width,
        y: rect.minY + (sourcePoint.y / sourceSize) * rect.height
      )
    }
  }
}

private struct ALogoPath: Shape {
  func path(in rect: CGRect) -> Path {
    let points = ALogoGeometry.points(in: rect)
    guard let firstPoint = points.first else { return Path() }

    var path = Path()
    path.move(to: firstPoint)
    points.dropFirst().forEach { path.addLine(to: $0) }
    return path
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
    Group {
      AppLaunchCurtain(onFinished: {})
        .previewDisplayName("App Launch")

      ZStack {
        Color(uiColor: .systemGroupedBackground)
          .ignoresSafeArea()
        WelcomeView(
          pendingPublicKey: "npub19fm9h69lna6wrejzs4k0pqmssug8pt3z37c5l3jqny9ghu3t4rzq7l3fwq",
          onStart: {}
        )
      }
      .previewDisplayName("Welcome")
    }
  }
}
