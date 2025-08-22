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
}

// EXTENSIONS IDENTIFIER
extension URL {
  public func isImageType() -> Bool {
    return ["jpeg", "jpg", "png", "gif"].contains(self.pathExtension)
  }
  public func isVideoType() -> Bool {
    return ["mp4", "mov"].contains(self.pathExtension)
  }
}
