// a
import SwiftUI

// Encode pubkey to create RM avatar
func RMEncoder(pubkey: String) -> [Int] {
  var result: [Int] = []
  for (i, c) in pubkey.enumerated() {
    if i >= 4 && i <= 9 {
      if let n = Int(String(c)) {
        result.append(n)
      } else if let ascii = c.asciiValue, ascii >= 97, ascii <= 122 {
        var n = Int(ascii - 97)
        if i == 4 {
          n = (n - Int(Character("z").asciiValue! - 97) + 26) % 26
        }
        result.append(n)
      }
    }
  }
  return result
}

// limit the encode to not excede number of available images for layers
func limitRM(_ value: Int, limit: Int) -> Int {
  if value <= limit {
    return value
  }
  var result = value
  while result > limit {
    if result % 2 == 0 {
      result /= 2
    } else {
      result /= 3
    }
  }
  return result
}

// RM GENERATOR
struct RMGenerator: View {
  @State var url = URL(string: "")
  @State var size: CGFloat = 50
  var body: some View {
    if let url = url {
      let pubkey = url.absoluteString

      let pattern = "^[a-z0-9]{64}$"

      if pubkey.range(of: pattern, options: .regularExpression) != nil {
        let RM = RMEncoder(pubkey: pubkey)

        let head =
          "head-\(String(format: "%02d", RM[0] > 15 ? limitRM(RM[0], limit: 15) : RM[0])).png"
        let eyes =
          "eyes-\(String(format: "%02d", RM[1] > 11 ? limitRM(RM[1], limit: 11) : RM[1])).png"
        let nose =
          "nose-\(String(format: "%02d", RM[2] > 1 ? limitRM(RM[2], limit: 1) : RM[2])).png"
        let mouth =
          "mouth-\(String(format: "%02d", RM[3] > 9 ? limitRM(RM[3], limit: 9) : RM[3])).png"
        let hh = "hh-\(String(format: "%02d", RM[4] > 26 ? limitRM(RM[4], limit: 26) : RM[4])).png"
        let acc =
          "acc-\(String(format: "%02d", RM[5] > 17 ? limitRM(RM[5], limit: 17) : RM[5])).png"

        ZStack {
          //HEAD
          Image(uiImage: #imageLiteral(resourceName: head))
            .resizable()
            .aspectRatio(contentMode: .fit)
          //EYES
          Image(uiImage: #imageLiteral(resourceName: eyes))
            .resizable()
            .aspectRatio(contentMode: .fit)
          //NOSE
          Image(uiImage: #imageLiteral(resourceName: nose))
            .resizable()
            .aspectRatio(contentMode: .fit)
          //MOUTH
          Image(uiImage: #imageLiteral(resourceName: mouth))
            .resizable()
            .aspectRatio(contentMode: .fit)
          //HAIR & HAT
          Image(uiImage: #imageLiteral(resourceName: hh))
            .resizable()
            .aspectRatio(contentMode: .fit)
          //ACCESORIE
          Image(uiImage: #imageLiteral(resourceName: acc))
            .resizable()
            .aspectRatio(contentMode: .fit)
        }
        .frame(width: size, height: size)
      } else {
        //HEAD
        Image(uiImage: #imageLiteral(resourceName: "incognito.png"))
          .resizable()
          .aspectRatio(contentMode: .fit)

          .frame(width: size, height: size)
      }
    } else {
      //HEAD
      Image(uiImage: #imageLiteral(resourceName: "incognito.png"))
        .resizable()
        .aspectRatio(contentMode: .fit)

        .frame(width: size, height: size)
    }
  }
}

struct RMGenerator_Previews: PreviewProvider {
  static var previews: some View {
    ScrollView {
      VStack {
        ForEach(0...2, id: \.self) { _ in
          RMGenerator()
        }
      }
    }

  }
}
