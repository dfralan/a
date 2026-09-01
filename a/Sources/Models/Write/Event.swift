import Foundation
import CryptoKit
import NostrKit
import SwiftData
import SwiftUI
import secp256k1

enum NostrEventSigningError: LocalizedError {
  case invalidPrivateKey
  case invalidEvent
  case signingFailed

  var errorDescription: String? {
    switch self {
    case .invalidPrivateKey:
      return "The private key is invalid"
    case .invalidEvent:
      return "The event could not be encoded"
    case .signingFailed:
      return "The event could not be signed"
    }
  }
}

enum NostrCanonicalJSON {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}

struct NostrSerializableEvent: Encodable {
  let id = 0
  let publicKey: String
  let createdAt: Timestamp
  let kind: EventKind
  let tags: [EventTag]
  let content: String

  func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    try container.encode(id)
    try container.encode(publicKey)
    try container.encode(createdAt)
    try container.encode(kind)
    try container.encode(tags)
    try container.encode(content)
  }
}

private struct NostrSignedEvent: Codable {
  let id: String
  let publicKey: String
  let createdAt: Timestamp
  let kind: EventKind
  let tags: [EventTag]
  let content: String
  let signature: String

  enum CodingKeys: String, CodingKey {
    case id
    case publicKey = "pubkey"
    case createdAt = "created_at"
    case kind
    case tags
    case content
    case signature = "sig"
  }
}

enum NostrEventFactory {
  private static let maxTimestampJitter = 60 * 60 * 24 * 2

  static func randomPastTimestamp() -> Timestamp {
    let jitter = Int.random(in: 0...maxTimestampJitter)
    return Timestamp(date: Date().addingTimeInterval(-Double(jitter)))
  }

  static func signedEvent(
    privateKeyHex: String,
    kind: EventKind,
    tags: [EventTag],
    content: String,
    createdAt: Timestamp
  ) throws -> Event {
    guard let privateKeyBytes = hex_decode(privateKeyHex), privateKeyBytes.count == 32 else {
      throw NostrEventSigningError.invalidPrivateKey
    }

    let privateKey = try secp256k1.Signing.PrivateKey(
      rawRepresentation: Data(privateKeyBytes)
    )
    let publicKey = hex_encode(Data(privateKey.publicKey.xonly.bytes))
    let serializableEvent = NostrSerializableEvent(
      publicKey: publicKey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content
    )
    let serializedEvent = try NostrCanonicalJSON.encode(serializableEvent)
    let eventID = hex_encode(Data(CryptoKit.SHA256.hash(data: serializedEvent)))
    let signature = try privateKey.schnorr.signature(for: serializedEvent)

    guard privateKey.publicKey.schnorr.isValidSignature(signature, for: serializedEvent) else {
      throw NostrEventSigningError.signingFailed
    }

    let signedEvent = NostrSignedEvent(
      id: eventID,
      publicKey: publicKey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
      signature: hex_encode(signature.rawRepresentation)
    )
    let signedEventJSON = try NostrCanonicalJSON.encode(signedEvent)

    guard let event = try? JSONDecoder().decode(Event.self, from: signedEventJSON) else {
      throw NostrEventSigningError.invalidEvent
    }
    return event
  }

  static func validateEventSignature(_ event: Event) throws {
    let serializableEvent = NostrSerializableEvent(
      publicKey: event.publicKey,
      createdAt: event.createdAt,
      kind: event.kind,
      tags: event.tags,
      content: event.content
    )
    let serializedEvent = try NostrCanonicalJSON.encode(serializableEvent)
    let eventID = hex_encode(Data(CryptoKit.SHA256.hash(data: serializedEvent)))
    guard eventID == event.id,
      let publicKeyBytes = hex_decode(event.publicKey), publicKeyBytes.count == 32,
      let signatureBytes = hex_decode(event.signature), signatureBytes.count == 64
    else {
      throw NostrEventSigningError.invalidEvent
    }

    var compressedPublicKey = Data([0x02])
    compressedPublicKey.append(contentsOf: publicKeyBytes)
    let publicKey = try secp256k1.Signing.PublicKey(
      rawRepresentation: compressedPublicKey,
      format: .compressed
    )
    let signature = try secp256k1.Signing.SchnorrSignature(
      rawRepresentation: Data(signatureBytes)
    )
    guard publicKey.schnorr.isValidSignature(signature, for: serializedEvent) else {
      throw NostrEventSigningError.signingFailed
    }
  }
}

struct NostrWriteEventDraft {
  let kind: EventKind
  let tags: [EventTag]
  let content: String
  let nips: Set<NIP>

  enum NIP: String, Hashable {
    case nip01 = "NIP-01"
    case nip02 = "NIP-02"
    case nip10 = "NIP-10"
    case nip22 = "NIP-22"
    case nip24 = "NIP-24"
    case nip27 = "NIP-27"
    case nip92 = "NIP-92"
    case nip36 = "NIP-36"
    case nip25 = "NIP-25"
    case nip18 = "NIP-18"
    case nip56 = "NIP-56"
  }
}

struct FileCloudUploadFile {
  let data: Data
  let fileName: String
  let mimeType: String
}

struct FileCloudUploadResult {
  let url: URL
  let metadataTags: [[String]]
}

struct FileCloudProvider: Identifiable, Codable, Equatable {
  let id: String
  var title: String
  var endpoint: String
  var uploadMode: UploadMode
  var isEnabled: Bool

  var endpointURL: URL? {
    URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  enum UploadMode: String, Codable, CaseIterable, Identifiable {
    case nostrBuild
    case nip96
    case nostrImg
    case raw

    var id: String {
      rawValue
    }

    var title: String {
      switch self {
      case .nostrBuild: return "nostr.build"
      case .nip96: return "NIP-96"
      case .nostrImg: return "nostrimg"
      case .raw: return "Raw body"
      }
    }

    var detail: String {
      switch self {
      case .nostrBuild: return "Multipart field fileToUpload with NIP-98 auth"
      case .nip96: return "Multipart field file with NIP-98 auth"
      case .nostrImg: return "Legacy image field"
      case .raw: return "Raw upload with file headers"
      }
    }

    var multipartFieldName: String? {
      switch self {
      case .nostrBuild: return "fileToUpload"
      case .nip96: return "file"
      case .nostrImg: return "image"
      case .raw: return nil
      }
    }

    var requiresNIP98Authorization: Bool {
      switch self {
      case .nostrBuild, .nip96:
        return true
      case .nostrImg, .raw:
        return false
      }
    }
  }

  static let nostrBuild = FileCloudProvider(
    id: "nostr-build",
    title: "nostr.build",
    endpoint: "https://nostr.build/api/v2/upload/files",
    uploadMode: .nostrBuild,
    isEnabled: true
  )

  static let nostrImg = FileCloudProvider(
    id: "nostr-img",
    title: "nostrimg.com",
    endpoint: "https://nostrimg.com/api/upload",
    uploadMode: .nostrImg,
    isEnabled: false
  )

  static let voidCat = FileCloudProvider(
    id: "void-cat",
    title: "void.cat",
    endpoint: "https://void.cat/upload?cli=true",
    uploadMode: .raw,
    isEnabled: false
  )

  static var defaultProviders: [FileCloudProvider] {
    [.nostrBuild, .nostrImg, .voidCat]
  }

  static var defaultProviderID: String {
    nostrBuild.id
  }

  static func legacyID(rawValue: Int) -> String {
    switch rawValue {
    case 0: return voidCat.id
    case 2: return nostrImg.id
    default: return nostrBuild.id
    }
  }
}

final class FileCloudProviderStore: ObservableObject {
  static let shared = FileCloudProviderStore()

  @Published private(set) var providers: [FileCloudProvider]
  @Published private(set) var selectedProviderID: String

  private let providersKey = "fileCloudProviders"
  private let selectedProviderIDKey = "selectedFileCloudProviderID"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    if let data = defaults.data(forKey: providersKey),
      let decodedProviders = try? JSONDecoder().decode([FileCloudProvider].self, from: data),
      !decodedProviders.isEmpty
    {
      providers = Self.refreshBuiltInProviders(decodedProviders)
    } else {
      providers = FileCloudProvider.defaultProviders
    }

    if let selectedID = defaults.string(forKey: selectedProviderIDKey), !selectedID.isEmpty {
      selectedProviderID = selectedID
    } else if let legacyCloudService = defaults.object(forKey: "cloudService") as? Int {
      selectedProviderID = FileCloudProvider.legacyID(rawValue: legacyCloudService)
    } else {
      selectedProviderID = FileCloudProvider.defaultProviderID
    }

    if selectedProvider == nil {
      selectedProviderID = enabledProviders.first?.id ?? FileCloudProvider.defaultProviderID
    }

    persist()
  }

  private static func refreshBuiltInProviders(_ storedProviders: [FileCloudProvider]) -> [FileCloudProvider] {
    var providers = storedProviders.map { provider in
      switch provider.id {
      case FileCloudProvider.nostrBuild.id:
        var refreshedProvider = FileCloudProvider.nostrBuild
        refreshedProvider.isEnabled = provider.isEnabled
        return refreshedProvider
      case FileCloudProvider.nostrImg.id:
        var refreshedProvider = FileCloudProvider.nostrImg
        refreshedProvider.isEnabled = provider.isEnabled
        return refreshedProvider
      case FileCloudProvider.voidCat.id:
        var refreshedProvider = FileCloudProvider.voidCat
        refreshedProvider.isEnabled = provider.isEnabled
        return refreshedProvider
      default:
        return provider
      }
    }

    for defaultProvider in FileCloudProvider.defaultProviders
    where !providers.contains(where: { $0.id == defaultProvider.id }) {
      providers.append(defaultProvider)
    }

    return providers
  }

  var enabledProviders: [FileCloudProvider] {
    providers.filter(\.isEnabled)
  }

  var selectedProvider: FileCloudProvider? {
    providers.first { $0.id == selectedProviderID && $0.isEnabled }
      ?? enabledProviders.first
  }

  var selectedProviderTitle: String {
    selectedProvider?.title ?? "No provider"
  }

  func select(_ provider: FileCloudProvider) {
    guard providers.contains(where: { $0.id == provider.id && $0.isEnabled }) else { return }

    selectedProviderID = provider.id
    persistSelection()
  }

  func save(_ provider: FileCloudProvider) {
    let isNewProvider = !providers.contains { $0.id == provider.id }

    if let index = providers.firstIndex(where: { $0.id == provider.id }) {
      providers[index] = provider
    } else {
      providers.append(provider)
    }

    if isNewProvider, provider.isEnabled {
      selectedProviderID = provider.id
    } else if selectedProviderID == provider.id, !provider.isEnabled {
      selectedProviderID = enabledProviders.first?.id ?? provider.id
    }

    persist()
  }

  func addProvider() -> FileCloudProvider {
    let provider = FileCloudProvider(
      id: UUID().uuidString,
      title: "New Provider",
      endpoint: "https://",
      uploadMode: .nip96,
      isEnabled: true
    )
    providers.append(provider)
    selectedProviderID = provider.id
    persist()
    return provider
  }

  func deleteProviders(at offsets: IndexSet) {
    providers.remove(atOffsets: offsets)

    if providers.isEmpty {
      providers = FileCloudProvider.defaultProviders
    }

    if selectedProvider == nil {
      selectedProviderID = enabledProviders.first?.id ?? providers[0].id
    }

    persist()
  }

  func resetToDefaults() {
    providers = FileCloudProvider.defaultProviders
    selectedProviderID = FileCloudProvider.defaultProviderID
    persist()
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(providers) {
      defaults.set(data, forKey: providersKey)
    }

    persistSelection()
  }

  private func persistSelection() {
    defaults.set(selectedProviderID, forKey: selectedProviderIDKey)
  }
}

enum FileCloudUploadError: LocalizedError {
  case noProvider
  case authorizationRequired(String)
  case invalidEndpoint(String)
  case unsupportedServiceResponse(String)
  case transportFailed(String, String)
  case uploadFailed(String, Int, String)
  case invalidResponse(String)

  var errorDescription: String? {
    switch self {
    case .noProvider:
      return "No file upload provider is active."
    case .authorizationRequired(let provider):
      return "\(provider) needs a saved private key to upload."
    case .invalidEndpoint(let provider):
      return "\(provider) has an invalid upload URL."
    case .unsupportedServiceResponse(let provider):
      return "\(provider) did not return a file URL."
    case .transportFailed(let provider, let message):
      return "\(provider) could not be reached. \(message)"
    case .uploadFailed(let provider, let statusCode, let body):
      return "\(provider) rejected the upload (\(statusCode)). \(body)"
    case .invalidResponse(let provider):
      return "\(provider) returned an invalid response."
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .noProvider:
      return "Open Settings and enable a file provider."
    case .authorizationRequired:
      return "Save or select a private key before posting media."
    case .uploadFailed(_, 401, _), .uploadFailed(_, 403, _):
      return "This provider may require NIP-98 auth or a different endpoint."
    case .uploadFailed(_, 413, _):
      return "Try a smaller image."
    case .invalidEndpoint:
      return "Open Settings and edit the provider URL."
    case .transportFailed:
      return "Check the provider URL or try another service."
    case .unsupportedServiceResponse:
      return "Open Settings and try another upload mode."
    case .invalidResponse:
      return "Try another provider."
    default:
      return nil
    }
  }

  var userMessage: String {
    let base = errorDescription ?? "Upload failed."
    if let recoverySuggestion {
      return "\(base) \(recoverySuggestion)"
    }
    return base
  }
}

enum FileCloudUploader {
  static func upload(
    _ file: FileCloudUploadFile,
    using provider: FileCloudProvider,
    keyPair: KeyPair? = nil
  ) async throws -> FileCloudUploadResult {
    switch provider.uploadMode {
    case .raw:
      return try await uploadRaw(file, using: provider, keyPair: keyPair)
    case .nostrBuild, .nip96, .nostrImg:
      return try await uploadMultipart(file, using: provider, keyPair: keyPair)
    }
  }

  private static func uploadRaw(
    _ file: FileCloudUploadFile,
    using provider: FileCloudProvider,
    keyPair: KeyPair?
  ) async throws -> FileCloudUploadResult {
    guard let endpoint = provider.endpointURL else {
      throw FileCloudUploadError.invalidEndpoint(provider.title)
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue(file.mimeType, forHTTPHeaderField: "V-Content-Type")
    request.setValue(file.fileName, forHTTPHeaderField: "V-Filename")
    request.httpBody = file.data
    try authorizeIfNeeded(&request, provider: provider, keyPair: keyPair, payload: file.data)

    return try await performUpload(
      request: request,
      provider: provider,
      fallbackMimeType: file.mimeType
    )
  }

  private static func uploadMultipart(
    _ file: FileCloudUploadFile,
    using provider: FileCloudProvider,
    keyPair: KeyPair?
  ) async throws -> FileCloudUploadResult {
    guard let endpoint = provider.endpointURL else {
      throw FileCloudUploadError.invalidEndpoint(provider.title)
    }

    guard let fieldName = provider.uploadMode.multipartFieldName else {
      throw FileCloudUploadError.invalidResponse(provider.title)
    }

    let boundary = "LandBoundary-\(UUID().uuidString)"
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = multipartBody(
      boundary: boundary,
      fieldName: fieldName,
      file: file,
      fields: multipartFields(for: file, provider: provider)
    )
    try authorizeIfNeeded(&request, provider: provider, keyPair: keyPair, payload: request.httpBody)

    return try await performUpload(
      request: request,
      provider: provider,
      fallbackMimeType: file.mimeType
    )
  }

  private static func multipartFields(
    for file: FileCloudUploadFile,
    provider: FileCloudProvider
  ) -> [(String, String)] {
    switch provider.uploadMode {
    case .nip96:
      return [
        ("content_type", file.mimeType),
        ("size", "\(file.data.count)"),
      ]
    case .nostrBuild, .nostrImg, .raw:
      return []
    }
  }

  private static func authorizeIfNeeded(
    _ request: inout URLRequest,
    provider: FileCloudProvider,
    keyPair: KeyPair?,
    payload: Data?
  ) throws {
    guard provider.uploadMode.requiresNIP98Authorization else { return }
    guard let keyPair else {
      throw FileCloudUploadError.authorizationRequired(provider.title)
    }

    request.setValue(
      try NIP98.authorizationHeader(
        keyPair: keyPair,
        url: request.url,
        method: request.httpMethod ?? "POST",
        payload: payload
      ),
      forHTTPHeaderField: "Authorization"
    )
  }

  private static func multipartBody(
    boundary: String,
    fieldName: String,
    file: FileCloudUploadFile,
    fields: [(String, String)]
  ) -> Data {
    var body = Data()

    for field in fields {
      body.appendString("--\(boundary)\r\n")
      body.appendString("Content-Disposition: form-data; name=\"\(field.0)\"\r\n\r\n")
      body.appendString("\(field.1)\r\n")
    }

    body.appendString("--\(boundary)\r\n")
    body.appendString(
      "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(file.fileName)\"\r\n"
    )
    body.appendString("Content-Type: \(file.mimeType)\r\n\r\n")
    body.append(file.data)
    body.appendString("\r\n--\(boundary)--\r\n")

    return body
  }

  private static func performUpload(
    request: URLRequest,
    provider: FileCloudProvider,
    fallbackMimeType: String
  ) async throws -> FileCloudUploadResult {
    let data: Data
    let response: URLResponse

    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw FileCloudUploadError.transportFailed(provider.title, error.localizedDescription)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw FileCloudUploadError.invalidResponse(provider.title)
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let body = uploadErrorMessage(from: data)
      throw FileCloudUploadError.uploadFailed(provider.title, httpResponse.statusCode, body)
    }

    guard let result = parseUploadResult(
      data,
      fallbackMimeType: fallbackMimeType
    ) else {
      throw FileCloudUploadError.unsupportedServiceResponse(provider.title)
    }

    return result
  }

  private static func parseUploadResult(
    _ data: Data,
    fallbackMimeType: String
  ) -> FileCloudUploadResult? {
    if let tags = try? JSONDecoder().decode([[String]].self, from: data),
      let url = url(fromNIP94Tags: tags)
    {
      return FileCloudUploadResult(
        url: url,
        metadataTags: normalizedMetadataTags(tags, url: url, fallbackMimeType: fallbackMimeType)
      )
    }

    if let json = try? JSONSerialization.jsonObject(with: data) {
      if let tags = recursiveNostrBuildTags(in: json, fallbackMimeType: fallbackMimeType),
        let url = url(fromNIP94Tags: tags)
      {
        return FileCloudUploadResult(
          url: url,
          metadataTags: normalizedMetadataTags(tags, url: url, fallbackMimeType: fallbackMimeType)
        )
      }

      if let tags = recursiveNIP94Tags(in: json), let url = url(fromNIP94Tags: tags) {
        return FileCloudUploadResult(
          url: url,
          metadataTags: normalizedMetadataTags(tags, url: url, fallbackMimeType: fallbackMimeType)
        )
      }

      if let url = recursiveURL(in: json) {
        return FileCloudUploadResult(
          url: url,
          metadataTags: fallbackMetadataTags(url: url, fallbackMimeType: fallbackMimeType)
        )
      }
    }

    if let text = String(data: data, encoding: .utf8),
      let url = URL(string: text.trimmingCharacters(in: CharacterSet(charactersIn: "\"\n\r\t "))),
      url.scheme?.hasPrefix("http") == true
    {
      return FileCloudUploadResult(
        url: url,
        metadataTags: fallbackMetadataTags(url: url, fallbackMimeType: fallbackMimeType)
      )
    }

    return nil
  }

  private static func url(fromNIP94Tags tags: [[String]]) -> URL? {
    tags.first { $0.first == "url" }
      .flatMap { $0.dropFirst().first }
      .flatMap(URL.init(string:))
  }

  private static func normalizedMetadataTags(
    _ tags: [[String]],
    url: URL,
    fallbackMimeType: String
  ) -> [[String]] {
    var normalizedTags = tags.filter { !$0.isEmpty }

    if !normalizedTags.contains(where: { $0.first == "url" }) {
      normalizedTags.insert(["url", url.absoluteString], at: 0)
    }

    if !normalizedTags.contains(where: { $0.first == "m" }) {
      normalizedTags.append(["m", fallbackMimeType])
    }

    return normalizedTags
  }

  private static func fallbackMetadataTags(
    url: URL,
    fallbackMimeType: String
  ) -> [[String]] {
    [["url", url.absoluteString], ["m", fallbackMimeType]]
  }

  private static func uploadErrorMessage(from data: Data) -> String {
    if let json = try? JSONSerialization.jsonObject(with: data),
      let message = recursiveString(in: json, keys: ["message", "error", "reason", "detail"])
    {
      return clipped(message)
    }

    if let text = String(data: data, encoding: .utf8),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return clipped(text)
    }

    return "The service did not accept the file."
  }

  private static func clipped(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 180 else { return trimmed }
    return "\(trimmed.prefix(180))..."
  }

  private static func recursiveURL(in value: Any) -> URL? {
    if let string = value as? String,
      let url = URL(string: string),
      url.scheme?.hasPrefix("http") == true
    {
      return url
    }

    if let dictionary = value as? [String: Any] {
      for key in ["url", "link", "src", "href"] {
        if let nested = dictionary[key], let url = recursiveURL(in: nested) {
          return url
        }
      }

      for nested in dictionary.values {
        if let url = recursiveURL(in: nested) {
          return url
        }
      }
    }

    if let array = value as? [Any] {
      for nested in array {
        if let url = recursiveURL(in: nested) {
          return url
        }
      }
    }

    return nil
  }

  private static func recursiveString(in value: Any, keys: [String]) -> String? {
    if let string = value as? String, !string.isEmpty {
      return string
    }

    if let dictionary = value as? [String: Any] {
      for key in keys {
        if let nested = dictionary[key], let string = recursiveString(in: nested, keys: keys) {
          return string
        }
      }

      for nested in dictionary.values {
        if let string = recursiveString(in: nested, keys: keys) {
          return string
        }
      }
    }

    if let array = value as? [Any] {
      for nested in array {
        if let string = recursiveString(in: nested, keys: keys) {
          return string
        }
      }
    }

    return nil
  }

  private static func recursiveNostrBuildTags(
    in value: Any,
    fallbackMimeType: String
  ) -> [[String]]? {
    if let dictionary = value as? [String: Any] {
      if let tags = nostrBuildTags(from: dictionary, fallbackMimeType: fallbackMimeType) {
        return tags
      }

      for key in ["data", "file", "files", "result"] {
        if let nested = dictionary[key],
          let tags = recursiveNostrBuildTags(in: nested, fallbackMimeType: fallbackMimeType)
        {
          return tags
        }
      }

      for nested in dictionary.values {
        if let tags = recursiveNostrBuildTags(in: nested, fallbackMimeType: fallbackMimeType) {
          return tags
        }
      }
    }

    if let array = value as? [Any] {
      for nested in array {
        if let tags = recursiveNostrBuildTags(in: nested, fallbackMimeType: fallbackMimeType) {
          return tags
        }
      }
    }

    return nil
  }

  private static func nostrBuildTags(
    from dictionary: [String: Any],
    fallbackMimeType: String
  ) -> [[String]]? {
    guard let urlString = dictionary["url"] as? String,
      URL(string: urlString)?.scheme?.hasPrefix("http") == true
    else {
      return nil
    }

    var tags = [["url", urlString]]
    tags.append(["m", (dictionary["mime"] as? String) ?? fallbackMimeType])

    if let sha256 = stringValue(dictionary["sha256"]) {
      tags.append(["x", sha256])
    }

    if let originalSHA256 = stringValue(dictionary["original_sha256"]) {
      tags.append(["ox", originalSHA256])
    }

    if let size = stringValue(dictionary["size"]) {
      tags.append(["size", size])
    }

    if let dimensions = dictionary["dimensions"] as? [String: Any],
      let width = stringValue(dimensions["width"]),
      let height = stringValue(dimensions["height"])
    {
      tags.append(["dim", "\(width)x\(height)"])
    }

    if let blurhash = stringValue(dictionary["blurhash"]) {
      tags.append(["blurhash", blurhash])
    }

    return tags
  }

  private static func stringValue(_ value: Any?) -> String? {
    switch value {
    case let string as String:
      return string.isEmpty ? nil : string
    case let int as Int:
      return String(int)
    case let double as Double:
      return double.rounded() == double ? String(Int(double)) : String(double)
    case let number as NSNumber:
      return number.stringValue
    default:
      return nil
    }
  }

  private static func recursiveNIP94Tags(in value: Any) -> [[String]]? {
    if let dictionary = value as? [String: Any] {
      for key in ["tags", "nip94", "metadata"] {
        if let nested = dictionary[key], let tags = recursiveNIP94Tags(in: nested) {
          return tags
        }
      }

      for nested in dictionary.values {
        if let tags = recursiveNIP94Tags(in: nested) {
          return tags
        }
      }
    }

    guard let array = value as? [Any] else {
      return nil
    }

    let directTags = array.compactMap(tagStrings)
    if directTags.count == array.count, url(fromNIP94Tags: directTags) != nil {
      return directTags
    }

    for nested in array {
      if let tags = recursiveNIP94Tags(in: nested) {
        return tags
      }
    }

    return nil
  }

  private static func tagStrings(from value: Any) -> [String]? {
    guard let array = value as? [Any], !array.isEmpty else {
      return nil
    }

    var strings: [String] = []
    for item in array {
      guard let string = item as? String else {
        return nil
      }
      strings.append(string)
    }

    return strings
  }
}

private extension Data {
  mutating func appendString(_ string: String) {
    append(Data(string.utf8))
  }
}

enum NIP01 {
  private struct ProfileMetadata: Encodable {
    let name: String
    let about: String
    let picture: String?
    let nip05: String?
  }

  static func textNote(
    content: String,
    isSensitive: Bool = false,
    sensitiveReason: String? = nil,
    mediaMetadata: [[[String]]] = [],
    parseProfileMentions: Bool = true
  ) -> NostrWriteEventDraft {
    let normalizedContent = parseProfileMentions ? NIP27.normalizedContent(content) : content
    var tags: [EventTag] = []
    var nips: Set<NostrWriteEventDraft.NIP> = [.nip01]

    if isSensitive {
      tags.append(NIP36.contentWarningTag(reason: sensitiveReason))
      nips.insert(.nip36)
    }

    if parseProfileMentions {
      let mentionTags = NIP27.profileMentionTags(in: normalizedContent)
      if !mentionTags.isEmpty {
        tags.append(contentsOf: mentionTags)
        nips.insert(.nip27)
      }
    }

    let hashtagTags = NIP24.hashtagTags(in: normalizedContent)
    if !hashtagTags.isEmpty {
      tags.append(contentsOf: hashtagTags)
      nips.insert(.nip24)
    }

    if !mediaMetadata.isEmpty {
      tags.append(contentsOf: mediaMetadata.map(NIP92.imetaTag))
      nips.insert(.nip92)
    }

    return NostrWriteEventDraft(
      kind: .textNote,
      tags: tags,
      content: normalizedContent,
      nips: nips
    )
  }

  static func profileMetadata(
    name: String,
    about: String,
    picture: String?,
    nip05: String? = nil
  ) -> NostrWriteEventDraft {
    let trimmedPicture = picture?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedNIP05 = nip05?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let metadata = ProfileMetadata(
      name: name,
      about: about,
      picture: trimmedPicture?.isEmpty == false ? trimmedPicture : nil,
      nip05: trimmedNIP05?.isEmpty == false ? trimmedNIP05 : nil
    )
    let contentData = try? JSONEncoder().encode(metadata)
    let content = contentData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

    return NostrWriteEventDraft(
      kind: .setMetadata,
      tags: [],
      content: content,
      nips: [.nip01]
    )
  }
}

enum NIP24 {
  static func hashtagTags(in content: String) -> [EventTag] {
    normalizedHashtags(in: content).map { hashtag in
      EventTag(id: "t", otherInformation: hashtag)
    }
  }

  static func hashtagRanges(in content: String) -> [Range<String.Index>] {
    let source = content as NSString

    return hashtagMatches(in: content).compactMap { match in
      guard match.numberOfRanges > 1 else { return nil }

      let marker = source.substring(
        with: NSRange(location: match.range.location, length: 1)
      )
      let value = source.substring(with: match.range(at: 1))

      if marker == "$", value.allSatisfy(\.isNumber) {
        return nil
      }

      return Range(match.range, in: content)
    }
  }

  private static func normalizedHashtags(in content: String) -> [String] {
    let source = content as NSString
    var seen = Set<String>()
    var hashtags: [String] = []

    for match in hashtagMatches(in: content) {
      guard match.numberOfRanges > 1 else { continue }

      let marker = source.substring(
        with: NSRange(location: match.range.location, length: 1)
      )
      let value = source
        .substring(with: match.range(at: 1))
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

      if marker == "$", value.allSatisfy(\.isNumber) {
        continue
      }

      guard !value.isEmpty, seen.insert(value).inserted else {
        continue
      }

      hashtags.append(value)
    }

    return hashtags
  }

  private static func hashtagMatches(in content: String) -> [NSTextCheckingResult] {
    let pattern = "(?<![A-Za-z0-9_])[$#]([A-Za-z0-9_][A-Za-z0-9_-]{0,63})"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return []
    }

    let source = content as NSString
    return regex.matches(
      in: content,
      range: NSRange(location: 0, length: source.length)
    )
  }
}

enum NIP10 {
  static func reply(
    content: String,
    rootEventID: String,
    replyEventID: String,
    rootPublicKey: String,
    replyPublicKey: String,
    rootRelayHint: String? = nil,
    replyRelayHint: String? = nil,
    participantPublicKeys: Set<String> = [],
    parseProfileMentions: Bool = true
  ) -> NostrWriteEventDraft {
    let normalizedContent = parseProfileMentions ? NIP27.normalizedContent(content) : content
    var tags: [EventTag] = [
      replyTag(
        eventID: rootEventID,
        relayHint: rootRelayHint,
        marker: "root",
        publicKey: rootPublicKey
      )
    ]
    var nips: Set<NostrWriteEventDraft.NIP> = [.nip01, .nip10]

    if replyEventID != rootEventID {
      tags.append(
        replyTag(
          eventID: replyEventID,
          relayHint: replyRelayHint,
          marker: "reply",
          publicKey: replyPublicKey
        )
      )
    }

    var taggedPublicKeys = Set<String>()
    let involvedPublicKeys = participantPublicKeys.union([rootPublicKey, replyPublicKey])
    for publicKey in involvedPublicKeys
    where !publicKey.isEmpty && taggedPublicKeys.insert(publicKey).inserted
    {
      tags.append(EventTag(id: "p", otherInformation: publicKey))
    }

    if parseProfileMentions {
      let mentionTags = NIP27.profileMentionTags(in: normalizedContent)
      if !mentionTags.isEmpty {
        tags.append(contentsOf: mentionTags)
        nips.insert(.nip27)
      }
    }

    let hashtagTags = NIP24.hashtagTags(in: normalizedContent)
    if !hashtagTags.isEmpty {
      tags.append(contentsOf: hashtagTags)
      nips.insert(.nip24)
    }

    return NostrWriteEventDraft(
      kind: .textNote,
      tags: tags,
      content: normalizedContent,
      nips: nips
    )
  }

  private static func replyTag(
    eventID: String,
    relayHint: String?,
    marker: String,
    publicKey: String
  ) -> EventTag {
    EventTag(
      id: "e",
      otherInformation: eventID,
      relayHint ?? "",
      marker,
      publicKey.isEmpty ? nil : publicKey
    )
  }
}

enum NIP22 {
  static func comment(
    content: String,
    root: ThreadReference,
    parent: ThreadReference,
    participantPublicKeys: Set<String> = [],
    parseProfileMentions: Bool = true
  ) throws -> NostrWriteEventDraft {
    guard root.commentProtocol == .nip22 else {
      throw ThreadProtocolValidationError.malformedNIP22
    }

    let normalizedContent = parseProfileMentions ? NIP27.normalizedContent(content) : content
    var tags = try rootTags(for: root)
    tags.append(contentsOf: try parentTags(for: parent))
    var nips: Set<NostrWriteEventDraft.NIP> = [.nip01, .nip22]

    var taggedPublicKeys = Set(
      tags
        .filter { $0.id.lowercased() == "p" }
        .compactMap { $0.otherInformation.first }
    )
    for publicKey in participantPublicKeys
    where !publicKey.isEmpty && taggedPublicKeys.insert(publicKey).inserted
    {
      tags.append(EventTag(id: "p", otherInformation: publicKey))
    }

    if parseProfileMentions {
      let mentionTags = NIP27.profileMentionTags(in: normalizedContent)
      for mentionTag in mentionTags {
        guard let publicKey = mentionTag.otherInformation.first else { continue }
        if taggedPublicKeys.insert(publicKey).inserted {
          tags.append(mentionTag)
        }
      }
      if !mentionTags.isEmpty {
        nips.insert(.nip27)
      }
    }

    let hashtagTags = NIP24.hashtagTags(in: normalizedContent)
    if !hashtagTags.isEmpty {
      tags.append(contentsOf: hashtagTags)
      nips.insert(.nip24)
    }

    return NostrWriteEventDraft(
      kind: .custom(1111),
      tags: tags,
      content: normalizedContent,
      nips: nips
    )
  }

  private static func rootTags(for reference: ThreadReference) throws -> [EventTag] {
    switch reference {
    case .event(let id, let kind, let publicKey, let relayHints):
      guard kind != 1 else { throw ThreadProtocolValidationError.malformedNIP22 }
      let relayHint = relayHints.first ?? ""
      var tags = [
        EventTag(id: "E", otherInformation: id, relayHint, publicKey),
        EventTag(id: "K", otherInformation: String(kind)),
      ]
      if let publicKey, !publicKey.isEmpty {
        tags.append(EventTag(id: "P", otherInformation: publicKey, relayHint))
      }
      return tags

    case .address(let coordinate, _, let kind, let publicKey, let relayHints):
      guard kind != 1 else { throw ThreadProtocolValidationError.malformedNIP22 }
      let relayHint = relayHints.first ?? ""
      var tags = [
        EventTag(id: "A", otherInformation: coordinate, relayHint),
        EventTag(id: "K", otherInformation: String(kind)),
      ]
      if let publicKey, !publicKey.isEmpty {
        tags.append(EventTag(id: "P", otherInformation: publicKey, relayHint))
      }
      return tags

    case .external(let identifier, let kind, let hints):
      guard !identifier.isEmpty, !kind.isEmpty else {
        throw ThreadProtocolValidationError.missingRootKind
      }
      return [
        EventTag(id: "I", otherInformation: identifier, hints.first),
        EventTag(id: "K", otherInformation: kind),
      ]
    }
  }

  private static func parentTags(for reference: ThreadReference) throws -> [EventTag] {
    switch reference {
    case .event(let id, let kind, let publicKey, let relayHints):
      let relayHint = relayHints.first ?? ""
      var tags = [
        EventTag(id: "e", otherInformation: id, relayHint, publicKey),
        EventTag(id: "k", otherInformation: String(kind)),
      ]
      if let publicKey, !publicKey.isEmpty {
        tags.append(EventTag(id: "p", otherInformation: publicKey, relayHint))
      }
      return tags

    case .address(
      let coordinate,
      let eventID,
      let kind,
      let publicKey,
      let relayHints
    ):
      let relayHint = relayHints.first ?? ""
      var tags = [EventTag(id: "a", otherInformation: coordinate, relayHint)]
      if let eventID, !eventID.isEmpty {
        tags.append(EventTag(id: "e", otherInformation: eventID, relayHint, publicKey))
      }
      tags.append(EventTag(id: "k", otherInformation: String(kind)))
      if let publicKey, !publicKey.isEmpty {
        tags.append(EventTag(id: "p", otherInformation: publicKey, relayHint))
      }
      return tags

    case .external(let identifier, let kind, let hints):
      guard !identifier.isEmpty, !kind.isEmpty else {
        throw ThreadProtocolValidationError.missingParentKind
      }
      return [
        EventTag(id: "i", otherInformation: identifier, hints.first),
        EventTag(id: "k", otherInformation: kind),
      ]
    }
  }
}

enum NIP27 {
  private struct ProfileReference {
    let publicKey: String
    let relayHint: String?
  }

  static func normalizedContent(_ content: String) -> String {
    let matches = profileMentionMatches(in: content)

    guard !matches.isEmpty else {
      return content
    }

    var normalizedContent = content
    for match in matches.reversed() {
      guard match.numberOfRanges > 1,
        let range = Range(match.range, in: normalizedContent),
        let tokenRange = Range(match.range(at: 1), in: normalizedContent)
      else {
        continue
      }

      let token = normalizedContent[tokenRange].lowercased()
      guard profileReference(from: token) != nil else {
        continue
      }

      normalizedContent.replaceSubrange(range, with: "nostr:\(token)")
    }

    return normalizedContent
  }

  static func displayContent(_ content: String) -> String {
    let matches = profileMentionMatches(in: content)
    guard !matches.isEmpty else {
      return content
    }

    let source = content as NSString
    var displayContent = content

    for match in matches.reversed() {
      guard match.numberOfRanges > 1,
        let range = Range(match.range, in: displayContent)
      else {
        continue
      }

      let matchedText = source.substring(with: match.range).lowercased()
      guard matchedText.hasPrefix("nostr:") else {
        continue
      }

      let token = source.substring(with: match.range(at: 1)).lowercased()
      guard profileReference(from: token) != nil else {
        continue
      }

      displayContent.replaceSubrange(range, with: "@\(token)")
    }

    return displayContent
  }

  static func profileMentionTags(in content: String) -> [EventTag] {
    profileReferences(in: content).map { reference in
      if let relayHint = reference.relayHint, !relayHint.isEmpty {
        return EventTag(id: "p", otherInformation: reference.publicKey, relayHint)
      }

      return EventTag(id: "p", otherInformation: reference.publicKey)
    }
  }

  static func profileMentionPublicKeys(in content: String) -> [String] {
    profileReferences(in: content).map(\.publicKey)
  }

  static func profileMentionTargets(in content: String) -> [NostrInlineProfileMentionTarget] {
    let source = content as NSString

    return profileMentionMatches(in: content).compactMap { match in
      guard match.numberOfRanges > 1,
        let range = Range(match.range, in: content)
      else {
        return nil
      }

      let token = source
        .substring(with: match.range(at: 1))
        .lowercased()

      guard let reference = profileReference(from: token) else {
        return nil
      }

      return NostrInlineProfileMentionTarget(range: range, publicKey: reference.publicKey)
    }
  }

  static func profileMentionRanges(in content: String) -> [Range<String.Index>] {
    let source = content as NSString

    return profileMentionMatches(in: content).compactMap { match in
      guard match.numberOfRanges > 1 else { return nil }

      let token = source
        .substring(with: match.range(at: 1))
        .lowercased()

      guard profileReference(from: token) != nil else {
        return nil
      }

      return Range(match.range, in: content)
    }
  }

  private static func profileReferences(in content: String) -> [ProfileReference] {
    let source = content as NSString
    var seen = Set<String>()
    var references: [ProfileReference] = []

    for match in profileMentionMatches(in: content) {
      guard match.numberOfRanges > 1 else { continue }

      let token = source
        .substring(with: match.range(at: 1))
        .lowercased()

      guard let reference = profileReference(from: token),
        seen.insert(reference.publicKey).inserted
      else {
        continue
      }

      references.append(reference)
    }

    return references
  }

  private static func profileMentionMatches(in content: String) -> [NSTextCheckingResult] {
    let pattern = "(?<![A-Za-z0-9_/:])(?:nostr:|@)?((?:npub|nprofile)1[023456789acdefghjklmnpqrstuvwxyz]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return []
    }

    let source = content as NSString
    return regex.matches(
      in: content,
      range: NSRange(location: 0, length: source.length)
    )
  }

  private static func profileReference(from token: String) -> ProfileReference? {
    if case .pub(let publicKey)? = decode_bech32_key(token) {
      guard isValidPublicKeyHex(publicKey) else {
        return nil
      }

      return ProfileReference(publicKey: publicKey, relayHint: nil)
    }

    guard let decoded = try? bech32_decode(token),
      decoded.hrp == "nprofile"
    else {
      return nil
    }

    return profileReference(fromNProfileData: decoded.data)
  }

  private static func profileReference(fromNProfileData data: Data) -> ProfileReference? {
    var index = 0
    var publicKey: String?
    var relayHint: String?

    while index + 2 <= data.count {
      let type = data[index]
      let length = Int(data[index + 1])
      index += 2

      guard index + length <= data.count else {
        break
      }

      let value = Data(data[index..<index + length])
      index += length

      switch type {
      case 0 where length == 32:
        publicKey = hex_encode(value)
      case 1 where relayHint == nil:
        relayHint = String(data: value, encoding: .utf8)
      default:
        break
      }
    }

    guard let publicKey else {
      return nil
    }

    guard isValidPublicKeyHex(publicKey) else {
      return nil
    }

    return ProfileReference(publicKey: publicKey, relayHint: relayHint)
  }

  private static func isValidPublicKeyHex(_ value: String) -> Bool {
    let hexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
    return value.count == 64
      && value.unicodeScalars.allSatisfy { hexCharacters.contains($0) }
  }
}

struct NostrInlineProfileMentionTarget {
  let range: Range<String.Index>
  let publicKey: String
}

enum NostrInlineText {
  private static let profileURLScheme = "land-profile"

  static func displayContent(_ content: String) -> String {
    NIP27.displayContent(content)
  }

  static func profileMentionPublicKeys(in content: String) -> [String] {
    NIP27.profileMentionPublicKeys(in: content)
  }

  static func profileMentionTargets(in content: String) -> [NostrInlineProfileMentionTarget] {
    NIP27.profileMentionTargets(in: content)
  }

  static func profileURL(for publicKey: String) -> URL? {
    URL(string: "\(profileURLScheme)://\(publicKey)")
  }

  static func profilePublicKey(from url: URL) -> String? {
    guard url.scheme == profileURLScheme,
      let host = url.host,
      host.count == 64
    else {
      return nil
    }

    return host
  }

  static func emphasisRanges(in content: String) -> [Range<String.Index>] {
    let ranges = NIP24.hashtagRanges(in: content) + NIP27.profileMentionRanges(in: content)

    return ranges.sorted { first, second in
      first.lowerBound < second.lowerBound
    }
  }
}

enum NIP92 {
  static func imetaTag(from nip94Tags: [[String]]) -> EventTag {
    let metadata = nip94Tags
      .filter { !$0.isEmpty }
      .map { $0.joined(separator: " ") }

    return eventTag(id: "imeta", values: metadata)
  }

  private static func eventTag(id: String, values: [String]) -> EventTag {
    let underlyingData = [id] + values

    guard let data = try? JSONEncoder().encode(underlyingData),
      let tag = try? JSONDecoder().decode(EventTag.self, from: data)
    else {
      return EventTag(id: id)
    }

    return tag
  }
}

enum NIP36 {
  static func contentWarningTag(reason: String? = nil) -> EventTag {
    let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)

    if let trimmedReason, !trimmedReason.isEmpty {
      return EventTag(id: "content-warning", otherInformation: trimmedReason)
    }

    return EventTag(id: "content-warning")
  }
}

enum NIP25 {
  static func reaction(
    eventID: String,
    publicKey: String,
    content: String,
    eventKind: Int = 1,
    relayHint: String? = nil,
    address: String? = nil
  ) -> NostrWriteEventDraft {
    let normalizedRelayHint = relayHint ?? ""
    var tags = [
      EventTag(id: "e", otherInformation: eventID, normalizedRelayHint, publicKey),
      EventTag(id: "p", otherInformation: publicKey, normalizedRelayHint),
      EventTag(id: "k", otherInformation: String(eventKind)),
    ]
    if let address, !address.isEmpty {
      tags.append(EventTag(id: "a", otherInformation: address, normalizedRelayHint, publicKey))
    }

    return NostrWriteEventDraft(
      kind: .custom(7),
      tags: tags,
      content: content,
      nips: [.nip25]
    )
  }
}

enum NIP18 {
  static func repost(
    eventID: String,
    publicKey: String,
    eventKind: Int = 1,
    relayHint: String? = nil,
    originalEventJSON: String = ""
  ) -> NostrWriteEventDraft {
    let normalizedRelayHint = relayHint ?? ""
    var tags = [
      EventTag(id: "e", otherInformation: eventID, normalizedRelayHint, publicKey),
      EventTag(id: "p", otherInformation: publicKey, normalizedRelayHint),
    ]
    if eventKind != 1 {
      tags.append(EventTag(id: "k", otherInformation: String(eventKind)))
    }

    return NostrWriteEventDraft(
      kind: .custom(eventKind == 1 ? 6 : 16),
      tags: tags,
      content: originalEventJSON,
      nips: [.nip18]
    )
  }
}

enum NIP56 {
  enum ReportType: String, CaseIterable, Identifiable {
    case spam
    case nudity
    case profanity
    case illegal
    case malware
    case impersonation
    case other

    var id: String {
      rawValue
    }

    var title: String {
      switch self {
      case .spam: return "Spam"
      case .nudity: return "Nudity"
      case .profanity: return "Abusive Content"
      case .illegal: return "Illegal Content"
      case .malware: return "Malware"
      case .impersonation: return "Impersonation"
      case .other: return "Other"
      }
    }
  }

  static func report(
    eventID: String,
    publicKey: String,
    type: ReportType,
    note: String = ""
  ) -> NostrWriteEventDraft {
    NostrWriteEventDraft(
      kind: .custom(1984),
      tags: [
        EventTag(id: "e", otherInformation: eventID, "", type.rawValue),
        EventTag(id: "p", otherInformation: publicKey, "", type.rawValue),
      ],
      content: note,
      nips: [.nip56]
    )
  }
}

enum NIP98 {
  static func authorizationHeader(
    keyPair: KeyPair,
    url: URL?,
    method: String,
    payload: Data?
  ) throws -> String {
    guard let url else {
      throw FileCloudUploadError.invalidResponse("NIP-98")
    }

    var tags = [
      EventTag(id: "u", otherInformation: url.absoluteString),
      EventTag(id: "method", otherInformation: method.uppercased()),
    ]

    if let payload, !payload.isEmpty {
      let payloadHash = hex_encode(Data(SHA256.hash(data: payload)))
      tags.append(EventTag(id: "payload", otherInformation: payloadHash))
    }

    let event = try Event(
      keyPair: keyPair,
      kind: .custom(27235),
      tags: tags,
      content: ""
    )
    let data = try JSONEncoder().encode(event)

    return "Nostr \(data.base64EncodedString())"
  }
}

enum NIP02 {
  static func followList(followedPublicKeys: [String]) -> NostrWriteEventDraft {
    let tags = uniquePublicKeys(followedPublicKeys).map { publicKey in
      EventTag(id: "p", otherInformation: publicKey, "", "")
    }

    return NostrWriteEventDraft(
      kind: .custom(3),
      tags: tags,
      content: "",
      nips: [.nip02]
    )
  }

  private static func uniquePublicKeys(_ publicKeys: [String]) -> [String] {
    var seen = Set<String>()
    var unique: [String] = []

    for publicKey in publicKeys where !seen.contains(publicKey) {
      seen.insert(publicKey)
      unique.append(publicKey)
    }

    return unique
  }
}

enum NostrPublishError: LocalizedError {
  case relayRejected(URL, String)
  case relayTimeout(URL)
  case relayClosed(URL, String)

  var errorDescription: String? {
    switch self {
    case .relayRejected(let relayURL, let message):
      return "\(relayURL.absoluteString) rejected the event: \(message)"
    case .relayTimeout(let relayURL):
      return "\(relayURL.absoluteString) did not confirm the event"
    case .relayClosed(let relayURL, let reason):
      return "\(relayURL.absoluteString) closed the connection: \(reason)"
    }
  }
}

private struct NIP01RelayOK {
  let eventId: String
  let accepted: Bool
  let message: String

  init?(text: String) {
    guard let data = text.data(using: .utf8),
      let payload = try? JSONSerialization.jsonObject(with: data) as? [Any],
      payload.count >= 4,
      payload[0] as? String == "OK",
      let eventId = payload[1] as? String,
      let accepted = payload[2] as? Bool,
      let message = payload[3] as? String
    else {
      return nil
    }

    self.eventId = eventId
    self.accepted = accepted
    self.message = message
  }

  var confirmsStoredEvent: Bool {
    guard !accepted else { return true }

    let normalizedMessage = message.lowercased()
    return normalizedMessage.contains("duplicate")
      || normalizedMessage.contains("already")
      || normalizedMessage.contains("have this event")
  }
}

private final class NostrEventPublishOperation: NSObject, URLSessionWebSocketDelegate {
  private let event: Event
  private let relayURL: URL
  private let completion: (Result<URL, Error>) -> Void
  private let stateQueue = DispatchQueue(label: "nostr.event.publish.state.\(UUID().uuidString)")

  private var session: URLSession?
  private var webSocketTask: URLSessionWebSocketTask?
  private var timeoutWorkItem: DispatchWorkItem?
  private var didComplete = false

  init(
    event: Event,
    relayURL: URL,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    self.event = event
    self.relayURL = relayURL
    self.completion = completion
  }

  func start() {
    let session = URLSession(
      configuration: .ephemeral,
      delegate: self,
      delegateQueue: nil
    )
    let webSocketTask = session.webSocketTask(with: relayURL)
    self.session = session
    self.webSocketTask = webSocketTask

    let timeoutWorkItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      finish(.failure(NostrPublishError.relayTimeout(relayURL)))
    }
    self.timeoutWorkItem = timeoutWorkItem

    webSocketTask.resume()
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + 10,
      execute: timeoutWorkItem
    )
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    receiveNext()

    do {
      let message = try ClientMessage.event(event).string()
      webSocketTask.send(.string(message)) { [weak self] error in
        guard let self, let error else { return }
        finish(.failure(error))
      }
    } catch {
      finish(.failure(error))
    }
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    let reasonText = reason
      .flatMap { String(data: $0, encoding: .utf8) }
      .flatMap { $0.isEmpty ? nil : $0 }
      ?? "code \(closeCode.rawValue)"
    finish(.failure(NostrPublishError.relayClosed(relayURL, reasonText)))
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let error else { return }
    finish(.failure(error))
  }

  private func receiveNext() {
    guard let webSocketTask else { return }

    webSocketTask.receive { [weak self] result in
      guard let self else { return }

      switch result {
      case .success(let message):
        switch message {
        case .string(let text):
          handleRelayMessage(text)
        case .data(let data):
          if let text = String(data: data, encoding: .utf8) {
            handleRelayMessage(text)
          } else {
            receiveNext()
          }
        @unknown default:
          receiveNext()
        }
      case .failure(let error):
        finish(.failure(error))
      }
    }
  }

  private func handleRelayMessage(_ text: String) {
    guard let relayOK = NIP01RelayOK(text: text), relayOK.eventId == event.id else {
      // NOTICE, AUTH, and unrelated frames are not terminal publish responses.
      receiveNext()
      return
    }

    if relayOK.confirmsStoredEvent {
      finish(.success(relayURL))
    } else {
      finish(.failure(NostrPublishError.relayRejected(relayURL, relayOK.message)))
    }
  }

  private func finish(_ result: Result<URL, Error>) {
    stateQueue.async { [weak self] in
      guard let self, !didComplete else { return }

      didComplete = true
      timeoutWorkItem?.cancel()
      webSocketTask?.cancel(with: .goingAway, reason: nil)
      session?.invalidateAndCancel()
      webSocketTask = nil
      session = nil

      DispatchQueue.main.async { [completion] in
        completion(result)
      }
    }
  }
}

class PostEventContent {

  let event: Event
  let content: String
  let timestamp: Date
  let draft: NostrWriteEventDraft

  convenience init(privateKeyHex: String, content: String, timestamp: Date = Date()) throws {
    try self.init(
      privateKeyHex: privateKeyHex,
      draft: NIP01.textNote(content: content),
      timestamp: timestamp
    )
  }

  init(privateKeyHex: String, draft: NostrWriteEventDraft, timestamp: Date = Date()) throws {
    self.draft = draft
    self.event = try NostrEventFactory.signedEvent(
      privateKeyHex: privateKeyHex,
      kind: draft.kind,
      tags: draft.tags,
      content: draft.content,
      createdAt: Timestamp(date: timestamp)
    )
    self.content = draft.content
    self.timestamp = timestamp
  }

  func sendToNostr(relayUrl: URL, completion: ((Result<URL, Error>) -> Void)? = nil) {
    NostrEventPublishOperation(
      event: event,
      relayURL: relayUrl,
      completion: { result in completion?(result) }
    ).start()
  }

  func saveToSwiftData(modelContainer: ModelContainer) {
    let swiftDataEvent = SwiftDataEvent()
    swiftDataEvent.id = event.id
    swiftDataEvent.content = content
    swiftDataEvent.timestamp = timestamp

    let context = ModelContext(modelContainer)
    context.insert(swiftDataEvent)
    try? context.save()
  }
}

@Model
class SwiftDataEvent {
  @Attribute(.unique) var id: String = ""
  var content: String = ""
  var timestamp: Date = Date()
  
  init() {}
}
