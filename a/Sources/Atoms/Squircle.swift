// a

import SwiftUI

// MARK: - Squircle Shape Path
struct Squircle: Shape {

  let cornerRadius: CGFloat

  /// Squircle morphing Shape Path
  func path(in rect: CGRect) -> Path {
    let width = rect.size.width
    let height = rect.size.height
    let minSize = min(width, height)

    let controlOffset = minSize * 0.45
    let straightOffset = (minSize - minSize * 0.7071) / 2

    var path = Path()

    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
    path.addCurve(
      to: CGPoint(x: rect.maxX, y: rect.midY),
      control1: CGPoint(x: rect.midX + controlOffset, y: rect.minY),
      control2: CGPoint(x: rect.maxX, y: rect.midY - controlOffset)
    )
    path.addCurve(
      to: CGPoint(x: rect.midX, y: rect.maxY),
      control1: CGPoint(x: rect.maxX, y: rect.midY + controlOffset),
      control2: CGPoint(x: rect.midX + controlOffset, y: rect.maxY)
    )
    path.addCurve(
      to: CGPoint(x: rect.minX, y: rect.midY),
      control1: CGPoint(x: rect.midX - controlOffset, y: rect.maxY),
      control2: CGPoint(x: rect.minX, y: rect.midY + controlOffset)
    )
    path.addCurve(
      to: CGPoint(x: rect.midX, y: rect.minY),
      control1: CGPoint(x: rect.minX, y: rect.midY - controlOffset),
      control2: CGPoint(x: rect.midX - controlOffset, y: rect.minY)
    )

    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + straightOffset))
    path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - straightOffset))
    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.minX + straightOffset, y: rect.midY))
    path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.maxX - straightOffset, y: rect.midY))

    return path
  }
}

// MARK: - Accordion String

func accordionString(_ str: String, index: Int) -> Text {

  /// Index of characters to show on lead and trail
  let index = index

  let startIndex = str.startIndex
  let endIndex = str.index(startIndex, offsetBy: index)
  let lastStartIndex = str.index(str.endIndex, offsetBy: -index)
  let lastEndIndex = str.endIndex
  let lead = String(str[startIndex..<endIndex])
  let trail = String(str[lastStartIndex..<lastEndIndex])
  return Text("\(lead)...\(trail)")
}
