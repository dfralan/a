// a

import ImageIO
import LinkPresentation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LinkPreviewDescriptor: Identifiable, Hashable, Sendable {
  let sourceURL: URL

  var id: String {
    sourceURL.absoluteString
  }

  static func detect(url: URL) -> LinkPreviewDescriptor? {
    guard let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      url.host != nil
    else {
      return nil
    }

    return LinkPreviewDescriptor(sourceURL: url)
  }
}

@MainActor
final class LinkPreviewMetadataRepository {
  static let shared = LinkPreviewMetadataRepository()

  private let cache = NSCache<NSString, LinkPreviewCacheEntry>()
  private var inFlight: [String: Task<ResolvedLinkPreview, Error>] = [:]

  private init() {
    cache.countLimit = 48
  }

  func metadata(for descriptor: LinkPreviewDescriptor) async throws -> ResolvedLinkPreview {
    let key = descriptor.id
    if let cached = cache.object(forKey: key as NSString) {
      return cached.preview
    }

    if let request = inFlight[key] {
      return try await request.value
    }

    let sourceURL = descriptor.sourceURL
    let request = Task { @MainActor in
      let provider = LPMetadataProvider()
      provider.timeout = 12
      let metadata = try await provider.startFetchingMetadata(for: sourceURL)
      let destinationURL = metadata.originalURL ?? metadata.url ?? sourceURL
      let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let primaryArtwork = await Self.loadImage(from: metadata.imageProvider)
      let artwork = if let primaryArtwork {
        primaryArtwork
      } else {
        await Self.loadImage(from: metadata.iconProvider)
      }
      let resolvedTitle = if let title, !title.isEmpty {
        title
      } else {
        Self.fallbackTitle(for: destinationURL)
      }

      return ResolvedLinkPreview(
        title: resolvedTitle,
        displayURL: Self.displayURL(for: destinationURL),
        destinationURL: destinationURL,
        artwork: artwork
      )
    }
    inFlight[key] = request

    do {
      let metadata = try await request.value
      inFlight[key] = nil
      cache.setObject(LinkPreviewCacheEntry(preview: metadata), forKey: key as NSString)
      return metadata
    } catch {
      inFlight[key] = nil
      throw error
    }
  }

  private static func loadImage(from provider: NSItemProvider?) async -> UIImage? {
    guard let provider,
      let imageTypeIdentifier = provider.registeredTypeIdentifiers.first(where: {
        UTType($0)?.conforms(to: .image) == true
      })
    else {
      return nil
    }

    return await withCheckedContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: imageTypeIdentifier) { data, _ in
        continuation.resume(returning: data.flatMap(Self.downsampleImage(data:)))
      }
    }
  }

  private static func downsampleImage(data: Data) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: 264,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      return nil
    }
    return UIImage(cgImage: image)
  }

  private static func fallbackTitle(for url: URL) -> String {
    url.host?.replacingOccurrences(of: "www.", with: "") ?? "Link"
  }

  private static func displayURL(for url: URL) -> String {
    var displayValue = url.absoluteString
    if let scheme = url.scheme {
      displayValue.removeFirst(min(displayValue.count, scheme.count + 3))
    }
    if displayValue.hasSuffix("/") {
      displayValue.removeLast()
    }
    return displayValue
  }
}

struct ResolvedLinkPreview {
  let title: String
  let displayURL: String
  let destinationURL: URL
  let artwork: UIImage?
}

private final class LinkPreviewCacheEntry: NSObject {
  let preview: ResolvedLinkPreview

  init(preview: ResolvedLinkPreview) {
    self.preview = preview
  }
}

struct LinkPreviewCard: View {
  let descriptor: LinkPreviewDescriptor

  @Environment(\.openURL) private var openURL
  @State private var preview: ResolvedLinkPreview?
  @State private var didFail = false

  var body: some View {
    Group {
      if let preview {
        resolvedCard(preview)
      } else if didFail {
        fallbackCard
      } else {
        loadingCard
      }
    }
    .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104, alignment: .leading)
    .background(Color(uiColor: .secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    }
    .task(id: descriptor.id) {
      await loadMetadata()
    }
  }

  private func resolvedCard(_ preview: ResolvedLinkPreview) -> some View {
    Button {
      openURL(preview.destinationURL)
    } label: {
      HStack(spacing: 12) {
        previewArtwork(preview.artwork)

        VStack(alignment: .leading, spacing: 5) {
          Text(preview.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)

          Text(preview.displayURL)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Image(systemName: "arrow.up.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .padding(.trailing, 12)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Open \(preview.title)")
  }

  private func previewArtwork(_ artwork: UIImage?) -> some View {
    Group {
      if let artwork {
        Image(uiImage: artwork)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "link")
          .font(.title3)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.secondary.opacity(0.08))
      }
    }
    .frame(width: 104, height: 104)
    .clipped()
  }

  private var loadingCard: some View {
    HStack(spacing: 12) {
      Rectangle()
        .fill(Color.secondary.opacity(0.12))
        .frame(width: 104, height: 104)

      VStack(alignment: .leading, spacing: 8) {
        Capsule()
          .fill(Color.secondary.opacity(0.14))
          .frame(maxWidth: 190, minHeight: 12, maxHeight: 12)
        Capsule()
          .fill(Color.secondary.opacity(0.1))
          .frame(maxWidth: 120, minHeight: 10, maxHeight: 10)
      }

      Spacer(minLength: 0)
    }
    .redacted(reason: .placeholder)
    .accessibilityLabel("Loading link preview")
  }

  private var fallbackCard: some View {
    Button {
      openURL(descriptor.sourceURL)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "link")
          .font(.title3)
          .frame(width: 104, height: 104)
          .background(Color.secondary.opacity(0.12))

        VStack(alignment: .leading, spacing: 2) {
          Text(descriptor.sourceURL.host ?? "Link")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Text(descriptor.sourceURL.absoluteString)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)

        Image(systemName: "arrow.up.right")
          .foregroundStyle(.secondary)
          .padding(.trailing, 12)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Open \(descriptor.sourceURL.host ?? "link")")
  }

  private func loadMetadata() async {
    preview = nil
    didFail = false

    do {
      let resolvedMetadata = try await LinkPreviewMetadataRepository.shared.metadata(for: descriptor)
      guard !Task.isCancelled else { return }
      preview = resolvedMetadata
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      preview = nil
      didFail = true
    }
  }
}
