import Foundation
import SwiftUI

struct NIP05 {
  let name: String
  let domain: String

  var url: URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = domain
    components.path = "/.well-known/nostr.json"
    components.queryItems = [URLQueryItem(name: "name", value: name)]
    return components.url
  }

  var siteUrl: URL? {
    URL(string: "https://\(domain)")
  }

  var displayIdentifier: String {
    name == "_" ? domain : "\(name)@\(domain)"
  }

  var displayDomain: String {
    domain
  }

  static func parse(_ nip05: String) -> NIP05? {
    let normalized = nip05
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }

    let name = String(parts[0])
    let domain = String(parts[1])
    guard isValidLocalPart(name), isValidDomain(domain) else {
      return nil
    }

    return NIP05(name: name, domain: domain)
  }

  private static func isValidLocalPart(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    return value.allSatisfy { character in
      character.isASCII
        && (character.isLowercase || character.isNumber || character == "-" || character == "_" || character == ".")
    }
  }

  private static func isValidDomain(_ value: String) -> Bool {
    guard !value.isEmpty,
      !value.contains("/"),
      !value.contains(":"),
      value.contains(".")
    else {
      return false
    }

    return value.allSatisfy { character in
      character.isASCII
        && (character.isLowercase || character.isNumber || character == "-" || character == ".")
    }
  }
}

struct NIP05Response: Decodable {
  let names: [String: String]
  let relays: [String: [String]]?
}

enum NIP05VerificationStatus: String, Codable {
  case unchecked
  case checking
  case verified
  case invalid
}

enum NIP05VerificationPolicy {
  static let verifiedRefreshInterval: TimeInterval = 24 * 60 * 60
  static let invalidRefreshInterval: TimeInterval = 6 * 60 * 60

  static func shouldRefresh(
    status: NIP05VerificationStatus,
    lastCheckedAt: Date?,
    now: Date = Date()
  ) -> Bool {
    guard let lastCheckedAt else { return true }

    let refreshInterval: TimeInterval
    switch status {
    case .verified:
      refreshInterval = verifiedRefreshInterval
    case .invalid:
      refreshInterval = invalidRefreshInterval
    case .unchecked, .checking:
      return true
    }

    return now.timeIntervalSince(lastCheckedAt) >= refreshInterval
  }
}

actor NIP05VerificationGate {
  private let limit: Int
  private var activeCount = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func acquire() async {
    if activeCount < limit {
      activeCount += 1
      return
    }

    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    guard !waiters.isEmpty else {
      activeCount = max(0, activeCount - 1)
      return
    }

    waiters.removeFirst().resume()
  }
}

struct NIP05VerificationResult {
  let status: NIP05VerificationStatus
  let identifier: NIP05
  let verificationURL: URL
  let checkedAt: Date
  let relays: [String]

  var isVerified: Bool {
    status == .verified
  }
}

struct FetchedNIP05 {
  let response: NIP05Response
  let nip05: NIP05Response
}

private final class NIP05NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
  static let shared = NIP05NoRedirectDelegate()

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

enum NIP05Verifier {
  private static let maximumResponseSize = 128 * 1_024
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 12
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    return URLSession(
      configuration: configuration,
      delegate: NIP05NoRedirectDelegate.shared,
      delegateQueue: nil
    )
  }()

  static func fetch(identifier: NIP05) async -> NIP05Response? {
    guard let url = identifier.url else { return nil }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    guard let (data, response) = try? await session.data(for: request),
      let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      data.count <= maximumResponseSize
    else {
      return nil
    }

    return try? JSONDecoder().decode(NIP05Response.self, from: data)
  }

  static func verify(publicKey: String, nip05: String) async -> NIP05VerificationResult? {
    guard let identifier = NIP05.parse(nip05),
      let verificationURL = identifier.url
    else {
      return nil
    }

    let normalizedPublicKey = publicKey.lowercased()
    let response = await fetch(identifier: identifier)
    let matchedPublicKey = response?.names[identifier.name]?.lowercased()
    let status: NIP05VerificationStatus = matchedPublicKey == normalizedPublicKey ? .verified : .invalid
    let relays = response?.relays?[normalizedPublicKey] ?? []

    return NIP05VerificationResult(
      status: status,
      identifier: identifier,
      verificationURL: verificationURL,
      checkedAt: Date(),
      relays: relays
    )
  }
}

func fetch_nip05_str(nip05_str: String) async -> NIP05Response? {
  guard let nip05 = NIP05.parse(nip05_str) else {
    return nil
  }

  return await fetch_nip05(nip05: nip05)
}

func fetch_nip05(nip05: NIP05) async -> NIP05Response? {
  await NIP05Verifier.fetch(identifier: nip05)
}

func validate_nip05(pubkey: String, nip05_str: String) async -> NIP05? {
  guard let result = await NIP05Verifier.verify(publicKey: pubkey, nip05: nip05_str),
    result.isVerified
  else {
    return nil
  }

  return result.identifier
}

struct nip05: View {
  var body: some View {
    Text( /*@START_MENU_TOKEN@*/"Hello, World!" /*@END_MENU_TOKEN@*/)
  }
}

struct nip05_Previews: PreviewProvider {
  static var previews: some View {
    nip05()
  }
}
