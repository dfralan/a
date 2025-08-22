//
//  SwiftUIView.swift
//  a
//
//  Created by Alan D on 18/05/2023.
//

import SwiftUI

struct TacTacAnimationView: View {
  @State private var isShowingImage = false

  var body: some View {
    VStack {
      Image(systemName: "bolt")
        .foregroundColor(.yellow)
        .opacity(isShowingImage ? 1 : 0)
        .animation(.easeInOut(duration: 0.5))
        .onAppear {
          startAnimation()
        }
    }
  }

  func startAnimation() {
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { timer in
      withAnimation {
        isShowingImage.toggle()
      }
    }
  }
}

struct ContentView: View {
  var body: some View {
    TacTacAnimationView()
  }
}

struct SwiftUIView_Previews: PreviewProvider {
  static var previews: some View {
    TacTacAnimationView()
  }
}
