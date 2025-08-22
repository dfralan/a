import SwiftUI

struct WelcomeView: View {

  @State private var currentSloganIndex = 0
  @State private var showSlogan = false

  let slogans = [
    "No drama, no hassle, where connections tassel.",
    "No stress, no hassle, embrace the digital castle.",
    "No tension, no hassle, a community that'll make your worries wrastle.",
    "No conflict, no hassle, in this app, friendships amassle.",
    "No trouble, no hassle, a social space that'll make your worries dismantle.",
    "No bickering, no hassle, where thoughts and ideas bristle.",
    "No negativity, no hassle, where positivity will whistle.",
    "No chaos, no hassle, join us and let your creativity thistle.",
    "No friction, no hassle, a platform where expression won't bristle.",
    "No constraints, no hassle, a realm where freedom will chisel.",
    "No haters, no hassle, together we'll form a unified vessel.",
    "No noise, no hassle, where authentic voices nestle.",
    "No limits, no hassle, a playground for minds to wrestle.",
    "No barriers, no hassle, a realm where ideas trestle.",
    "No suppression, no hassle, a platform where thoughts trestle.",
    "No judgment, no hassle, a space where acceptance will nestle.",
    "No filters, no hassle, where connections bloom and nestle.",
    "No exclusion, no hassle, a community where diversity will nestle.",
    "No fear, no hassle, in this app, we'll help you unbuckle.",
    "No bounds, no hassle, where dreams and aspirations will hustle.",
  ]

  var body: some View {
    ZStack {
      Image("portal9")
        .resizable()
        .scaledToFill()
        .edgesIgnoringSafeArea(.all)

      VStack {
        Spacer()

        Text(slogans[currentSloganIndex])
          .font(.title)
          .bold()
          .multilineTextAlignment(.center)
          .padding()
          .frame(width: 350)
          .opacity(showSlogan ? 1 : 0)  // Apply opacity to the container view

        Button(action: {
          // Action for Generate Key button
        }) {
          Text("Generate Key")
        }
        .buttonStyle(.bordered)
        .tint(.primary)
        .foregroundColor(.white)

        Button(action: {
          // Action for Generate Key button
        }) {
          Text("Log Key")
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)

        Spacer()

        Text("Back to Land")
          .foregroundColor(.white)
          .font(.headline)
      }
      .shadow(radius: 5)
    }
  }
}

struct WelcomeView_Previews: PreviewProvider {
  static var previews: some View {
    WelcomeView()
  }
}
