//
//  ReactionsBarModule.swift
//  a
//
//  Created by Alan D on 11/04/2023.
//

import Foundation

// WHEEL PARAMETERS
class ReactionsBarState: ObservableObject {
  @Published var expanded = false
  @Published var eventReactions = [""]
  @Published var selectedEmoji = "😀"
}
