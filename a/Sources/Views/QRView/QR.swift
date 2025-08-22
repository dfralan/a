//
//  QR.swift
//  a
//
//  Created by Alan D on 11/05/2023.
//

import SwiftUI

func generateQRCodeImage(url: String) -> UIImage {
  /// Qr Tools
  let context = CIContext()
  let filter = CIFilter.qrCodeGenerator()

  let data = Data(url.utf8)
  filter.setValue(data, forKey: "inputMessage")
  if let qrCodeImage = filter.outputImage {
    if let qrCodeCGImage = context.createCGImage(
      qrCodeImage,
      from:
        qrCodeImage.extent)
    {
      return UIImage(cgImage: qrCodeCGImage)
    }
  }
  return UIImage(systemName: "xmark") ?? UIImage()
}

func captureScreenshotAndShare() {
  guard
    let windowScene = UIApplication.shared.connectedScenes.first(where: {
      $0.activationState == .foregroundActive
    }) as? UIWindowScene,
    let window = windowScene.windows.first
  else {
    return
  }

  UIGraphicsBeginImageContextWithOptions(window.bounds.size, false, 0)
  window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
  guard let screenshotImage = UIGraphicsGetImageFromCurrentImageContext() else {
    return
  }
  UIGraphicsEndImageContext()

  let activityViewController = UIActivityViewController(
    activityItems: [screenshotImage], applicationActivities: nil)

  guard let viewController = windowScene.windows.first?.rootViewController else {
    return
  }

  if let popoverController = activityViewController.popoverPresentationController {
    popoverController.sourceView = viewController.view
    popoverController.sourceRect = CGRect(
      x: viewController.view.bounds.midX, y: viewController.view.bounds.midY, width: 0, height: 0)
    popoverController.permittedArrowDirections = []
  }

  viewController.present(activityViewController, animated: true)
}
