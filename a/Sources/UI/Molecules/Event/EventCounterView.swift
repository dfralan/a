// a

import SwiftUI

struct NewPostsCounterButton: View {
  let count: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Text(displayCount)
          .monospacedDigit()
          .contentTransition(.numericText(value: Double(count)))

        Image(systemName: "arrow.up")
          .font(.system(size: 13, weight: .bold))
          .symbolRenderingMode(.hierarchical)
      }
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(Color.accentColor)
      .frame(minWidth: 58, minHeight: 36)
      .padding(.horizontal, 4)
      .background(.ultraThinMaterial, in: Capsule())
      .overlay {
        Capsule()
          .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
      }
      .shadow(color: Color.black.opacity(0.12), radius: 10, y: 5)
      .contentShape(Capsule())
      .animation(.spring(response: 0.24, dampingFraction: 0.86), value: count)
    }
    .buttonStyle(.plain)
    .frame(minHeight: 44)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint("Shows the newest posts")
  }

  private var displayCount: String {
    count > 99 ? "99+" : "\(count)"
  }

  private var accessibilityLabel: String {
    if count > 99 {
      return "More than 99 new posts"
    }

    if count == 1 {
      return "1 new post"
    }

    return "\(count) new posts"
  }
}

#Preview {
  VStack(spacing: 18) {
    NewPostsCounterButton(count: 7) {}
    NewPostsCounterButton(count: 42) {}
    NewPostsCounterButton(count: 100) {}
  }
  .padding()
  .background(Color(uiColor: .systemGroupedBackground))
}
