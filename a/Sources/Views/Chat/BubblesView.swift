// a

import Combine
import SwiftUI

struct ChatBubbleShape: Shape {
  let isFromCurrentUser: Bool
  var lastOfRow: Bool
  var firstOfRow: Bool

  func path(in rect: CGRect) -> Path {
    var path = Path()

    let cornerRadius = 20.0
    let smallRadius = 9.0
    let radius = cornerRadius
    let tipRadius = 5.0
    let width = rect.size.width
    //let width = (rect.size.width) < 100 ? 100 : (rect.size.width)
    let height = rect.size.height

    //RIGHT BUBBLE
    if isFromCurrentUser {

      // 1 START BOTTOM RIGHT
      path.move(to: CGPoint(x: width - radius, y: height))

      // 2 RADIUS BOTTOM RIGHT
      path.addArc(
        tangent1End: CGPoint(x: width + (lastOfRow ? tipRadius : 0), y: height),
        tangent2End: CGPoint(x: width, y: height - radius),
        radius: lastOfRow ? tipRadius : smallRadius)

      // 3 RIGHT LINE
      path.addLine(to: CGPoint(x: width, y: (height - radius) + (lastOfRow ? tipRadius : 0)))

      // 4 RADIUS TOP RIGHT
      path.addArc(
        tangent1End: CGPoint(x: width, y: 0), tangent2End: CGPoint(x: width - radius, y: 0),
        radius: firstOfRow ? radius : smallRadius)

      // 5 TOP LINE
      path.addLine(to: CGPoint(x: radius, y: 0))

      // 6 RADIUS TOP LEFT
      path.addArc(
        tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: 0, y: radius), radius: radius)

      // 7 LEFT LINE
      path.addLine(to: CGPoint(x: 0, y: height - radius))

      // 8 RADIUS BOTTOM LEFT
      path.addArc(
        tangent1End: CGPoint(x: 0, y: height), tangent2End: CGPoint(x: radius, y: height),
        radius: radius)

      // 9 BOTTOM LINE
      path.closeSubpath()
    }

    //RIGHT BUBBLE
    else {
      // 1 START BOTTOM RIGHT
      path.move(to: CGPoint(x: width - radius, y: height))

      // 2 RADIUS BOTTOM RIGHT
      path.addArc(
        tangent1End: CGPoint(x: width, y: height),
        tangent2End: CGPoint(x: width, y: height - radius), radius: radius)

      // 3 RIGHT LINE
      path.addLine(to: CGPoint(x: width, y: radius))

      // 4 RADIUS TOP RIGHT
      path.addArc(
        tangent1End: CGPoint(x: width, y: 0), tangent2End: CGPoint(x: width - radius, y: 0),
        radius: radius)

      // 5 TOP LINE
      path.addLine(to: CGPoint(x: radius, y: 0))

      // 6 RADIUS TOP LEFT
      path.addArc(
        tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: 0, y: radius),
        radius: firstOfRow ? radius : smallRadius)

      // 7 LEFT LINE
      path.addLine(to: CGPoint(x: 0, y: (height - radius) + (lastOfRow ? tipRadius : 0)))

      // 8 RADIUS BOTTOM LEFT
      path.addArc(
        tangent1End: CGPoint(x: lastOfRow ? -tipRadius : 0, y: height),
        tangent2End: CGPoint(x: radius, y: height), radius: lastOfRow ? tipRadius : smallRadius)

      // 9 BOTTOM LINE
      path.closeSubpath()

    }
    return path
  }
}

struct Message: Identifiable {
  let id = UUID()
  var isFromCurrentUser: Bool
  var content: String
  var created_at: String
  var state: Int

  init(isFromCurrentUser: Bool, content: String, created_at: String, state: Int) {
    self.isFromCurrentUser = isFromCurrentUser
    self.content = content
    self.created_at = created_at
    self.state = state
  }
}

class ChatViewModel: ObservableObject {
  @Published var messages: [Message]
  @Published var messageStream: [(Bool, String, String)]

  init(messages: [Message]) {
    self.messages = messages
    self.messageStream = messages.map { message in
      return (message.isFromCurrentUser, message.content, message.created_at)
    }
  }

  func sendMessage(isFromCurrentUser: Bool, content: String, created_at: String) {
    let newMessage = Message(
      isFromCurrentUser: isFromCurrentUser, content: content, created_at: created_at, state: 0)
    messages.append(newMessage)
    messageStream.append((newMessage.isFromCurrentUser, newMessage.content, newMessage.created_at))
  }

}

struct BubblesView: View {

  var avatarURL: URL

  let viewModel = ChatViewModel(messages: messages)

  let created_at: String = "\(Int(Date().timeIntervalSince1970))"

  var body: some View {

    ScrollView {
      VStack {

        ForEach(Array(viewModel.messages.enumerated()), id: \.1.id) { index, message in

          // BUBBLE RIGHT
          if message.isFromCurrentUser {
            HStack(alignment: .bottom) {

              Spacer()

              //BUBBLE CONTAINER
              VStack {
                HStack(alignment: .bottom) {

                  // CONTENT
                  Text(message.content)
                    .foregroundColor(.white)

                  HStack(spacing: 0) {
                    // CREATED AT
                    //MomentConstructorBubble(timestamp: (message.created_at))
                    Text(created_at)
                      .font(.footnote)
                      .foregroundColor(.primary.opacity(0.3))

                    // SEND & RECEIPT CONFIRMATION
                    Image(systemName: messageState(for: index))
                      .font(.caption).bold()
                      .foregroundColor(.primary.opacity(0.3))
                  }
                }
              }
              .padding(.horizontal, 12)
              .padding(.top, 10)
              .padding(.bottom, 12)
              .background(
                ChatBubbleShape(
                  isFromCurrentUser: message.isFromCurrentUser, lastOfRow: lastOfRow(at: index),
                  firstOfRow: firstOfRow(at: index)
                )
                .fill(Color.accentColor.opacity(0.9)))
            }
            .padding(.leading, 50)
            .padding(.bottom, lastOfRow(at: index) ? 10 : -3)
          }

          // BUBBLE LEFT
          else {
            HStack(alignment: .bottom) {

              // SHOW PROFILE IF IS THE LAST OF THE ROW
              if lastOfRow(at: index) {
                AvatarView(url: avatarURL, size: 30)
                  .offset(y: 10)
              }

              // SHOW SPACER TO FULLFILL EMPTINESS, weeeeeena
              else {
                Spacer().frame(width: 38)
              }

              //BUBBLE CONTAINER
              VStack {
                HStack(alignment: .bottom) {

                  // CONTENT
                  Text(message.content)
                    .foregroundColor(.primary)

                  // CREATED AT
                  //MomentConstructorBubble(timestamp: (message.created_at))
                  Text(created_at)
                    .font(.footnote)
                    .foregroundColor(.primary.opacity(0.3))

                }
              }

              .padding(.horizontal, 12)
              .padding(.top, 10)
              .padding(.bottom, 12)
              .background(
                ChatBubbleShape(
                  isFromCurrentUser: message.isFromCurrentUser, lastOfRow: lastOfRow(at: index),
                  firstOfRow: firstOfRow(at: index)
                )
                //.blur(radius: 50)
                .fill(Color.primary.opacity(0.1)))

              Spacer()
            }
            .padding(.trailing, 50)
            .padding(.bottom, lastOfRow(at: index) ? 10 : -3)

          }
        }
      }
      .textSelection(.enabled)
      .padding()

    }

    //.background(AnimatedBackgroundView(blur: 10))

  }

  // Conditions to show avatar
  func firstOfRow(at index: Int) -> Bool {

    if index == 0 {
      return true  // If the first message, always show profile
    }
    let currentMessage = messages[index]
    let previousMessage = messages[index - 1]

    if currentMessage.isFromCurrentUser != previousMessage.isFromCurrentUser {
      return true  // If the previous message is from a different user, show profile
    }
    return false  // Otherwise, do not show profile
  }

  //
  func lastOfRow(at index: Int) -> Bool {

    let currentMessage = messages[index]
    let nextMessage = index < messages.count - 1 ? messages[index + 1] : nil

    if currentMessage.isFromCurrentUser != nextMessage?.isFromCurrentUser {  // If the nex message is from other user
      return true
    } else {
      return false
    }
  }

  func messageState(for state: Int) -> String {
    if messages[state].state == 0 {
      return "clock"
    } else {
      return "checkmark"
    }
  }

  func sendMessage() {
    viewModel.sendMessage(isFromCurrentUser: false, content: "Hi there!", created_at: "1677955434")
  }

}
let messages: [Message] = [
  Message(isFromCurrentUser: true, content: "Sup?", created_at: "1679096310", state: 0),
  Message(isFromCurrentUser: false, content: "Bae", created_at: "1647340900", state: 1),
  Message(
    isFromCurrentUser: false,
    content: "I'm doing pretty well, thanks for asking. How was your day?",
    created_at: "1647341000", state: 0),
  Message(
    isFromCurrentUser: false,
    content: "Did you end up going to that new restaurant you were talking about?",
    created_at: "1647341100", state: 0),
  Message(
    isFromCurrentUser: false, content: "I'm really curious!", created_at: "1647341200", state: 0),
  Message(
    isFromCurrentUser: true,
    content: "Yeah, I did! It was amazing. We should definitely try it out sometime.",
    created_at: "1647341400", state: 0),
  Message(
    isFromCurrentUser: true, content: "I'll have to make a reservation soon.",
    created_at: "1647341500", state: 0),
  Message(
    isFromCurrentUser: true, content: "So, what are you up to this weekend?",
    created_at: "1647341600", state: 0),
  Message(isFromCurrentUser: false, content: "Any plans?", created_at: "1647341700", state: 0),
  Message(
    isFromCurrentUser: true,
    content:
      "Actually, I was thinking of going to the beach. It's been a while since I've been there.",
    created_at: "1647341900", state: 0),
  Message(
    isFromCurrentUser: false, content: "Oh, that sounds like fun! What day were you thinking?",
    created_at: "1647342000", state: 0),
  Message(
    isFromCurrentUser: true,
    content: "How about Sunday? The weather is supposed to be really nice.",
    created_at: "1647342100", state: 0),
  Message(
    isFromCurrentUser: false, content: "I'm down for that! What time should we meet?",
    created_at: "1647342200", state: 0),
  Message(
    isFromCurrentUser: true, content: "Let's say around noon. We can grab some lunch on the way.",
    created_at: "1647342400", state: 0),
  Message(
    isFromCurrentUser: false, content: "Sounds perfect. Can't wait!", created_at: "1647342500",
    state: 0),
  Message(
    isFromCurrentUser: false,
    content: "By the way, have you seen the new movie that just came out?",
    created_at: "1647342600", state: 0),
  Message(
    isFromCurrentUser: false, content: "I heard it's really good!", created_at: "1647342700",
    state: 0),
  Message(
    isFromCurrentUser: true,
    content: "Yeah, I did! It was amazing. We should definitely try it out sometime.",
    created_at: "1647341400", state: 0),
  Message(
    isFromCurrentUser: true, content: "I'll have to make a reservation soon.",
    created_at: "1647341500", state: 0),
  Message(
    isFromCurrentUser: true, content: "So, what are you up to this weekend?",
    created_at: "1647341600", state: 0),
  Message(
    isFromCurrentUser: false, content: "We should go see it sometime.", created_at: "1647342800",
    state: 0),
]
