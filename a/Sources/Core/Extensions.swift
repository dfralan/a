// a

import Foundation

extension String {

  //CORROBORATE IS A VALID NAME
  func isValidName() -> Bool {
    if self.isEmpty {
      return false
    }
    return self.range(of: #"^[\w+\-]*$"#, options: [.regularExpression]) != nil
  }

  func removingUrls() -> String {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else {
      return self
    }
    return detector.stringByReplacingMatches(
      in: self, options: [], range: NSRange(location: 0, length: self.utf16.count), withTemplate: ""
    )
  }
    
    
    func accordionString(index: Int) -> String { // <--- Cambia a String
            let safeIndex = min(index, self.count / 2)
            
            let startIndex = self.startIndex
            let endIndex = self.index(startIndex, offsetBy: safeIndex)
            let lastStartIndex = self.index(self.endIndex, offsetBy: -safeIndex)
            
            let lead = String(self[startIndex..<endIndex])
            let trail = String(self[lastStartIndex..<self.endIndex])
            
            // Retorna un String, NO una vista Text
            if self.count > 2 * safeIndex {
               return "\(lead)...\(trail)" // <--- Retorna el String acortado
            } else {
               return self
            }
        }
}

// EXTENSIONS IDENTIFIER
extension URL {
  public func isImageType() -> Bool {
    return ["jpeg", "jpg", "png", "gif", "webp", "svg"].contains(self.pathExtension.lowercased())
  }
  public func isVideoType() -> Bool {
    return ["mp4", "mov"].contains(self.pathExtension.lowercased())
  }
}
