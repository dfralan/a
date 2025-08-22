// a
// TODO: Post emoji comment when double tapped on it

import SwiftUI

// MARK: - Reactions Bar View

struct ReactionsBarView: View {

  // MARK: - Properties

  ///
  @ObservedObject var reactionsBarState: ReactionsBarState
  let frequentReactions = ["👍", "❤️", "😂", "🔥", "😢", "😀"]

  var sortedEmojiCounts: [(String, Int)] {
    emojiCounter(emojis: reactionsBarState.eventReactions)
  }

  var body: some View {
    HStack {
      // REACTIONS BAR

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 14) {

          /// Button to add a reaction (it expands the frequent reactions bar)
          Button {

          } label: {
            Image(systemName: "face.smiling")
          }

          /// If the event is already reacted, it will count and show them
          if !sortedEmojiCounts.isEmpty {
            ForEach(sortedEmojiCounts, id: \.0) { (emoji, count) in
              HStack(spacing: 2) {
                Text(emoji)
                  .font(.system(size: reactionsBarState.expanded ? 20 : 14, weight: .regular))

                Text(shortString(count))
                  .font(.system(size: reactionsBarState.expanded ? 14 : 12, weight: .regular))
              }
              .padding(.horizontal, 2)
              .gesture(
                TapGesture(count: 2)
                  .onEnded({

                    // DOUBLE TAP GESTURE
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2))
                    {
                      reactionsBarState.expanded = false
                      reactionsBarState.selectedEmoji = emoji
                      reactionsBarState.eventReactions.append(reactionsBarState.selectedEmoji)
                    }
                  })
                  .exclusively(
                    before: TapGesture()
                      .onEnded({
                        print("Tapped Once")

                      })
                  )
              )
            }
          }
        }
      }

      /// Fade mask
      .mask(FadeMask())
    }
  }

  func emojiCounter(emojis: [String]) -> [(String, Int)] {
    var emojiCount: [String: Int] = [:]
    for emoji in emojis {
      if emoji.isEmpty {
        continue
      }
      if let count = emojiCount[emoji] {
        emojiCount[emoji] = count + 1
      } else {
        emojiCount[emoji] = 1
      }
    }
    let sortedEmojiCount = emojiCount.sorted { $0.value > $1.value }
    return sortedEmojiCount
  }

  func shortString(_ value: Int) -> String {
    let suffixes = ["", "K", "M", "B", "T"]
    var num = Double(value)
    var suffixIndex = 0
    while num >= 1000 && suffixIndex < suffixes.count - 1 {
      num /= 1000
      suffixIndex += 1
    }
    var numStr = "\(num)"
    if num.truncatingRemainder(dividingBy: 1) == 0 {
      numStr = String(format: "%.0f", num)
    } else {
      numStr = String(format: "%.1f", num)
    }
    return "\(numStr)\(suffixes[suffixIndex])"
  }
}

struct EmojiCounterView_Previews: PreviewProvider {
  static var previews: some View {
    ReactionsBarView(reactionsBarState: ReactionsBarState())
  }
}
