// a

import SwiftUI

//ALL USES TEXTFIELD
struct ClassicTextFieldStyle: TextFieldStyle {
  @Binding var text: String
  @State var paddingLeft: CGFloat = 10
  @State var paddingRigth: CGFloat = 10
  @State var cornerRadius: CGFloat = 9

  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .padding(.vertical, 8)
      .padding(.leading, paddingLeft)
      .padding(.trailing, paddingRigth)
      .background(.thinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
  }
}

//ALL USES TEXTFIELD
struct TextAreaStyle: TextFieldStyle {
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .padding(.vertical)
      .background(Color.clear)
  }
}
