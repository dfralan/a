// a

import CryptoKit
import Foundation
import NostrKit
import Security
import SwiftData
import secp256k1

enum MessagingProtocolKind: String, Codable, Hashable {
  case nip17
  case marmot
}

struct MessagingConversation: Hashable {
  enum Kind: Hashable {
    case direct(peerPublicKey: String)
    case group(id: String)
  }

  let kind: Kind
  let participants: [String]
  let subject: String?

  static func direct(
    currentUserPublicKey: String,
    peerPublicKey: String
  ) -> MessagingConversation {
    MessagingConversation(
      kind: .direct(peerPublicKey: peerPublicKey),
      participants: [currentUserPublicKey, peerPublicKey].sorted(),
      subject: nil
    )
  }
}

struct MessagingPlaintextMessage: Hashable {
  let id: String
  let conversation: MessagingConversation
  let senderPublicKey: String
  let content: String
  let createdAt: Date
}

struct MessagingEncryptedEnvelope {
  let id: String
  let protocolKind: MessagingProtocolKind
  let recipientPublicKey: String
  let event: Event
}

struct MessagingPublishRoute {
  let envelope: MessagingEncryptedEnvelope
  let relayURLs: [URL]
  let isRequired: Bool
}

struct MessagingSendRequest {
  let message: MessagingPlaintextMessage
  let senderPrivateKeyHex: String
  let relayURLs: [URL]
}

struct MessagingSendResult {
  let wrapEventIds: [String]
}

struct MessagingSendFailure: LocalizedError {
  let underlyingError: Error
  let wrapEventIds: [String]

  var errorDescription: String? {
    if let localizedError = underlyingError as? LocalizedError,
      let description = localizedError.errorDescription
    {
      return description
    }

    return underlyingError.localizedDescription
  }

  var userMessage: String {
    if let messagingError = underlyingError as? MessagingError {
      return messagingError.userMessage
    }

    if let nestedFailure = underlyingError as? MessagingSendFailure {
      return nestedFailure.userMessage
    }

    return errorDescription ?? "Message could not be sent."
  }
}

protocol MessagingCryptoProvider {
  var protocolKind: MessagingProtocolKind { get }

  func seal(
    _ message: MessagingPlaintextMessage,
    senderPrivateKeyHex: String
  ) throws -> [MessagingEncryptedEnvelope]

  func open(
    _ envelope: MessagingEncryptedEnvelope,
    recipientPrivateKeyHex: String
  ) throws -> MessagingPlaintextMessage
}

protocol MessagingTransport {
  func publish(
    _ routes: [MessagingPublishRoute],
    authPrivateKeyHex: String?,
    completion: @escaping (Result<Void, Error>) -> Void
  )
}

protocol MessagingRelayResolver {
  func resolveRoutes(
    for envelopes: [MessagingEncryptedEnvelope],
    senderPublicKey: String,
    peerPublicKey: String,
    localRelayURLs: [URL],
    completion: @escaping (Result<[MessagingPublishRoute], Error>) -> Void
  )
}

enum MessagingError: LocalizedError {
  case emptyMessage
  case messageTooLong
  case missingRelay
  case invalidConversation
  case invalidKey
  case invalidRecipient
  case recipientInboxUnavailable
  case encryptionFailed
  case decryptionUnavailable(protocolKind: MessagingProtocolKind)
  case cryptoUnavailable(protocolKind: MessagingProtocolKind)
  case transportUnavailable
  case publishFailed(details: [String])

  var errorDescription: String? {
    switch self {
    case .emptyMessage:
      return "Message is empty."
    case .messageTooLong:
      return "Message is too long."
    case .missingRelay:
      return "No active relay is available."
    case .invalidConversation:
      return "This conversation cannot be encrypted yet."
    case .invalidKey:
      return "The active private key is not valid."
    case .invalidRecipient:
      return "The recipient public key is not valid."
    case .recipientInboxUnavailable:
      return "The recipient has not published NIP-17 DM relays."
    case .encryptionFailed:
      return "The message could not be encrypted."
    case .decryptionUnavailable(let protocolKind):
      return "\(protocolKind.title) inbox decryption is not connected yet."
    case .cryptoUnavailable(let protocolKind):
      return "\(protocolKind.title) messaging is not available yet."
    case .transportUnavailable:
      return "Message transport is not available yet."
    case .publishFailed:
      return "No relay accepted the message."
    }
  }

  var userMessage: String {
    switch self {
    case .emptyMessage:
      return "Write a message first."
    case .messageTooLong:
      return "Keep the message shorter and try again."
    case .missingRelay:
      return "Enable at least one relay before sending."
    case .invalidConversation:
      return "Only direct messages are available right now."
    case .invalidKey:
      return "Select a valid saved key before sending."
    case .invalidRecipient:
      return "That public key does not look valid."
    case .recipientInboxUnavailable:
      return "This user has not advertised DM relays yet."
    case .encryptionFailed:
      return "The message could not be encrypted."
    case .decryptionUnavailable:
      return "Secure inbox sync is coming next. This device can send encrypted messages now."
    case .cryptoUnavailable:
      return "Secure messaging is not enabled yet. No message was sent."
    case .transportUnavailable:
      return "Message delivery is not connected yet. No message was sent."
    case .publishFailed(let details):
      let uniqueDetails = Array(Set(details)).sorted()
      if !uniqueDetails.isEmpty {
        let relayDetails = uniqueDetails.prefix(2).joined(separator: " ")
        return "No relay accepted the message. \(relayDetails)"
      }

      return "No relay accepted the message. Check your relay list."
    }
  }
}

extension MessagingProtocolKind {
  var title: String {
    switch self {
    case .nip17:
      return "NIP-17"
    case .marmot:
      return "Marmot"
    }
  }
}

struct NIP17MessagingCryptoProvider: MessagingCryptoProvider {
  let protocolKind: MessagingProtocolKind = .nip17

  func seal(
    _ message: MessagingPlaintextMessage,
    senderPrivateKeyHex: String
  ) throws -> [MessagingEncryptedEnvelope] {
    guard case .direct(let peerPublicKey) = message.conversation.kind else {
      throw MessagingError.invalidConversation
    }

    guard isValidKeyHex(senderPrivateKeyHex) else {
      throw MessagingError.invalidKey
    }

    guard isValidKeyHex(peerPublicKey) else {
      throw MessagingError.invalidRecipient
    }

    let senderKeyPair: KeyPair
    do {
      senderKeyPair = try KeyPair(privateKey: senderPrivateKeyHex)
    } catch {
      throw MessagingError.invalidKey
    }

    let senderPublicKey = senderKeyPair.publicKey
    guard message.senderPublicKey == senderPublicKey else {
      throw MessagingError.invalidKey
    }

    let recipients = uniquePublicKeys([peerPublicKey, senderPublicKey])
    let rumor = try NIP17Rumor.from(message: message, authorPublicKey: senderPublicKey)
    guard message.id == rumor.id else {
      throw MessagingError.invalidConversation
    }
    let rumorJSON = try rumor.jsonString()

    return try recipients.map { recipientPublicKey in
      let conversationKey = try NIP44.conversationKey(
        privateKeyHex: senderPrivateKeyHex,
        publicKeyHex: recipientPublicKey
      )
      let sealedRumor = try NIP44.encrypt(rumorJSON, conversationKey: conversationKey)
      let seal = try NostrEventFactory.signedEvent(
        privateKeyHex: senderPrivateKeyHex,
        kind: .custom(13),
        tags: [],
        content: sealedRumor,
        createdAt: NostrEventFactory.randomPastTimestamp()
      )
      let sealJSON = try seal.jsonString()

      guard let wrapperPrivateKeyHex = generate_new_keypair().privkey else {
        throw MessagingError.encryptionFailed
      }

      do {
        _ = try KeyPair(privateKey: wrapperPrivateKeyHex)
      } catch {
        throw MessagingError.encryptionFailed
      }

      let wrapperConversationKey = try NIP44.conversationKey(
        privateKeyHex: wrapperPrivateKeyHex,
        publicKeyHex: recipientPublicKey
      )
      let wrappedSeal = try NIP44.encrypt(sealJSON, conversationKey: wrapperConversationKey)
      let giftWrap = try NostrEventFactory.signedEvent(
        privateKeyHex: wrapperPrivateKeyHex,
        kind: .custom(1059),
        tags: [.pubKey(publicKey: recipientPublicKey)],
        content: wrappedSeal,
        createdAt: NostrEventFactory.randomPastTimestamp()
      )

      return MessagingEncryptedEnvelope(
        id: giftWrap.id,
        protocolKind: protocolKind,
        recipientPublicKey: recipientPublicKey,
        event: giftWrap
      )
    }
  }

  func open(
    _ envelope: MessagingEncryptedEnvelope,
    recipientPrivateKeyHex: String
  ) throws -> MessagingPlaintextMessage {
    guard envelope.event.kind == .custom(1059) else {
      throw MessagingError.decryptionUnavailable(protocolKind: envelope.protocolKind)
    }
    try NostrEventFactory.validateEventSignature(envelope.event)

    let recipientKeyPair: KeyPair
    do {
      recipientKeyPair = try KeyPair(privateKey: recipientPrivateKeyHex)
    } catch {
      throw MessagingError.invalidKey
    }

    let recipientPublicKey = recipientKeyPair.publicKey
    let isAddressedToRecipient = envelope.event.tags.contains { tag in
      tag.id == "p" && tag.otherInformation.first == recipientPublicKey
    }
    guard isAddressedToRecipient else {
      throw MessagingError.invalidRecipient
    }

    let giftWrapConversationKey = try NIP44.conversationKey(
      privateKeyHex: recipientPrivateKeyHex,
      publicKeyHex: envelope.event.publicKey
    )
    let sealJSON = try NIP44.decrypt(envelope.event.content, conversationKey: giftWrapConversationKey)
    let seal = try JSONDecoder().decode(Event.self, from: Data(sealJSON.utf8))
    guard seal.kind == .custom(13),
      seal.tags.isEmpty
    else {
      throw MessagingError.decryptionUnavailable(protocolKind: envelope.protocolKind)
    }
    try NostrEventFactory.validateEventSignature(seal)

    let sealConversationKey = try NIP44.conversationKey(
      privateKeyHex: recipientPrivateKeyHex,
      publicKeyHex: seal.publicKey
    )
    let rumorJSON = try NIP44.decrypt(seal.content, conversationKey: sealConversationKey)
    let rumor = try JSONDecoder().decode(NIP17Rumor.self, from: Data(rumorJSON.utf8))
    guard seal.publicKey == rumor.publicKey else {
      throw MessagingError.decryptionUnavailable(protocolKind: envelope.protocolKind)
    }
    guard rumor.kind == .custom(14) else {
      throw MessagingError.decryptionUnavailable(protocolKind: envelope.protocolKind)
    }
    guard rumor.id == (try rumor.computedID()) else {
      throw MessagingError.decryptionUnavailable(protocolKind: envelope.protocolKind)
    }

    let taggedPublicKeys = rumor.taggedPublicKeys
    let peerPublicKey: String
    if rumor.publicKey == recipientPublicKey {
      peerPublicKey = taggedPublicKeys.first { $0 != recipientPublicKey } ?? recipientPublicKey
    } else {
      peerPublicKey = rumor.publicKey
    }

    return MessagingPlaintextMessage(
      id: rumor.id,
      conversation: .direct(currentUserPublicKey: recipientPublicKey, peerPublicKey: peerPublicKey),
      senderPublicKey: rumor.publicKey,
      content: rumor.content,
      createdAt: Date(timeIntervalSince1970: Double(rumor.createdAt.timestamp))
    )
  }

  private func isValidKeyHex(_ value: String) -> Bool {
    let normalized = value.lowercased()
    let hexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
    return normalized.count == 64
      && normalized.unicodeScalars.allSatisfy { hexCharacters.contains($0) }
  }

  private func uniquePublicKeys(_ publicKeys: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []

    for publicKey in publicKeys where !seen.contains(publicKey) {
      seen.insert(publicKey)
      result.append(publicKey)
    }

    return result
  }
}

struct NostrMessagingTransport: MessagingTransport {
  func publish(
    _ routes: [MessagingPublishRoute],
    authPrivateKeyHex: String?,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard !routes.isEmpty else {
      completion(.failure(MessagingError.encryptionFailed))
      return
    }

    let targets = routes.flatMap { route in
      route.relayURLs.map { relayURL in
        (route: route, relayURL: relayURL)
      }
    }
    let requiredEnvelopeIDs = Set(routes.filter(\.isRequired).map(\.envelope.id))

    guard !targets.isEmpty else {
      completion(.failure(MessagingError.missingRelay))
      return
    }

    let completionQueue = DispatchQueue(label: "nostr.messaging.transport.\(UUID().uuidString)")
    var completed = 0
    var accepted = 0
    var failed = 0
    var acceptedEnvelopeIDs = Set<String>()
    var failureDetails: [String] = []
    var didFinishTransport = false

    func finishTransport(_ result: Result<Void, Error>) {
      guard !didFinishTransport else { return }

      didFinishTransport = true
      DispatchQueue.main.async {
        completion(result)
      }
    }

    for target in targets {
      publish(
        target.route.envelope.event,
        to: target.relayURL,
        authPrivateKeyHex: authPrivateKeyHex
      ) { result in
        completionQueue.async {
          completed += 1

          switch result {
          case .success:
            accepted += 1
            acceptedEnvelopeIDs.insert(target.route.envelope.id)
          case .failure(let error):
            failed += 1
            failureDetails.append(Self.failureMessage(from: error))
          }

          if requiredEnvelopeIDs.isSubset(of: acceptedEnvelopeIDs)
            || (requiredEnvelopeIDs.isEmpty && accepted > 0)
          {
            finishTransport(.success(()))
            return
          }

          guard completed == targets.count else { return }

          if !didFinishTransport {
            finishTransport(.failure(MessagingError.publishFailed(details: failureDetails)))
          }
        }
      }
    }
  }

  private static func failureMessage(from error: Error) -> String {
    if let localizedError = error as? LocalizedError,
      let description = localizedError.errorDescription
    {
      return description
    }

    return error.localizedDescription
  }

  private static func relayAlreadyHasEvent(_ message: String) -> Bool {
    let normalized = message.lowercased()
    return normalized.contains("duplicate")
      || normalized.contains("already")
      || normalized.contains("have this event")
  }

  private func publish(
    _ event: Event,
    to relayURL: URL,
    authPrivateKeyHex: String?,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    DispatchQueue.global(qos: .background).async {
      do {
        let message = ClientMessage.event(event)
        let eventMessageString = try message.string()
        let session = URLSession(configuration: .default)
        let webSocketTask = session.webSocketTask(with: relayURL)
        let completionQueue = DispatchQueue(label: "nostr.messaging.publish.\(UUID().uuidString)")
        var didComplete = false
        var authChallenge: String?
        var authEventID: String?
        var isAuthInFlight = false
        var didAuthenticate = false
        var didSendEvent = false
        var didRetryEventAfterAuth = false

        func finish(_ result: Result<URL, Error>) {
          completionQueue.async {
            guard !didComplete else { return }

            didComplete = true
            webSocketTask.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            completion(result)
          }
        }

        func sendEvent() {
          guard !didSendEvent else { return }

          didSendEvent = true
          webSocketTask.send(.string(eventMessageString)) { error in
            if let error {
              finish(.failure(NostrPublishError.relayRejected(
                relayURL,
                error.localizedDescription
              )))
            }
          }
        }

        func sendAuth(challenge: String) {
          guard let authPrivateKeyHex else {
            finish(.failure(NostrPublishError.relayRejected(
              relayURL,
              "auth-required: relay requested authentication"
            )))
            return
          }

          guard !isAuthInFlight,
            !didAuthenticate
          else {
            return
          }

          do {
            let auth = try NostrRelayAuth(
              challenge: challenge,
              relayURL: relayURL,
              privateKeyHex: authPrivateKeyHex
            )
            authEventID = auth.event.id
            isAuthInFlight = true
            webSocketTask.send(.string(try auth.messageString())) { error in
              if let error {
                finish(.failure(NostrPublishError.relayRejected(
                  relayURL,
                  error.localizedDescription
                )))
              }
            }
          } catch {
            finish(.failure(error))
          }
        }

        func resendEventAfterAuth() {
          guard didAuthenticate, !didRetryEventAfterAuth else { return }

          didRetryEventAfterAuth = true
          webSocketTask.send(.string(eventMessageString)) { error in
            if let error {
              finish(.failure(NostrPublishError.relayRejected(
                relayURL,
                error.localizedDescription
              )))
            }
          }
        }

        func receiveNext() {
          webSocketTask.receive { result in
            switch result {
            case .success(let message):
              switch message {
              case .string(let text):
                if let relayOK = MessagingRelayOK(text: text) {
                  if relayOK.eventId == event.id {
                    if relayOK.accepted || Self.relayAlreadyHasEvent(relayOK.message) {
                      finish(.success(relayURL))
                    } else if relayOK.message.hasPrefix("auth-required:") {
                      guard let authChallenge else {
                        finish(.failure(NostrPublishError.relayRejected(relayURL, relayOK.message)))
                        return
                      }

                      sendAuth(challenge: authChallenge)
                      receiveNext()
                    } else {
                      finish(.failure(NostrPublishError.relayRejected(relayURL, relayOK.message)))
                    }
                    return
                  }

                  if relayOK.eventId == authEventID {
                    isAuthInFlight = false
                    if relayOK.accepted {
                      didAuthenticate = true
                      resendEventAfterAuth()
                      receiveNext()
                    } else {
                      finish(.failure(NostrPublishError.relayRejected(relayURL, relayOK.message)))
                    }
                    return
                  }

                  receiveNext()
                  return
                }

                if let auth = MessagingRelayAuthChallenge(text: text) {
                  authChallenge = auth.challenge
                  sendAuth(challenge: auth.challenge)
                  receiveNext()
                  return
                }

                receiveNext()
              case .data:
                receiveNext()
              @unknown default:
                receiveNext()
              }
            case .failure(let error):
              finish(.failure(NostrPublishError.relayRejected(
                relayURL,
                error.localizedDescription
              )))
            }
          }
        }

        webSocketTask.resume()
        receiveNext()

        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.25) {
          if !isAuthInFlight && !didAuthenticate {
            sendEvent()
          }
        }

        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 12) {
          finish(.failure(NostrPublishError.relayTimeout(relayURL)))
        }
      } catch {
        completion(.failure(error))
      }
    }
  }
}

struct DeferredMessagingCryptoProvider: MessagingCryptoProvider {
  let protocolKind: MessagingProtocolKind

  init(protocolKind: MessagingProtocolKind = .nip17) {
    self.protocolKind = protocolKind
  }

  func seal(
    _ message: MessagingPlaintextMessage,
    senderPrivateKeyHex: String
  ) throws -> [MessagingEncryptedEnvelope] {
    throw MessagingError.cryptoUnavailable(protocolKind: protocolKind)
  }

  func open(
    _ envelope: MessagingEncryptedEnvelope,
    recipientPrivateKeyHex: String
  ) throws -> MessagingPlaintextMessage {
    throw MessagingError.cryptoUnavailable(protocolKind: envelope.protocolKind)
  }
}

struct DeferredMessagingTransport: MessagingTransport {
  func publish(
    _ routes: [MessagingPublishRoute],
    authPrivateKeyHex: String?,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    completion(.failure(MessagingError.transportUnavailable))
  }
}

struct NIP17MessagingRelayResolver: MessagingRelayResolver {
  func resolveRoutes(
    for envelopes: [MessagingEncryptedEnvelope],
    senderPublicKey: String,
    peerPublicKey: String,
    localRelayURLs: [URL],
    completion: @escaping (Result<[MessagingPublishRoute], Error>) -> Void
  ) {
    guard !localRelayURLs.isEmpty else {
      completion(.failure(MessagingError.missingRelay))
      return
    }

    if peerPublicKey == senderPublicKey {
      let routes = envelopes.map {
        MessagingPublishRoute(envelope: $0, relayURLs: localRelayURLs, isRequired: true)
      }
      completion(.success(routes))
      return
    }

    fetchInboxRelayURLs(for: peerPublicKey, from: localRelayURLs) { result in
      switch result {
      case .success(let peerRelayURLs):
        guard !peerRelayURLs.isEmpty else {
          completion(.failure(MessagingError.recipientInboxUnavailable))
          return
        }

        let routes = envelopes.compactMap { envelope -> MessagingPublishRoute? in
          if envelope.recipientPublicKey == peerPublicKey {
            return MessagingPublishRoute(
              envelope: envelope,
              relayURLs: peerRelayURLs,
              isRequired: true
            )
          }

          if envelope.recipientPublicKey == senderPublicKey {
            return MessagingPublishRoute(
              envelope: envelope,
              relayURLs: localRelayURLs,
              isRequired: false
            )
          }

          return nil
        }

        guard routes.contains(where: \.isRequired) else {
          completion(.failure(MessagingError.invalidRecipient))
          return
        }

        completion(.success(routes))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  private func fetchInboxRelayURLs(
    for publicKey: String,
    from discoveryRelayURLs: [URL],
    completion: @escaping (Result<[URL], Error>) -> Void
  ) {
    let completionQueue = DispatchQueue(label: "nostr.messaging.dm-relays.\(UUID().uuidString)")
    var completed = 0
    var relayListEvents: [Event] = []

    for relayURL in discoveryRelayURLs {
      fetchInboxRelayEvent(from: relayURL, publicKey: publicKey) { result in
        completionQueue.async {
          completed += 1

          if case .success(let event?) = result {
            if (try? NostrEventFactory.validateEventSignature(event)) != nil {
              relayListEvents.append(event)
            }
          }

          guard completed == discoveryRelayURLs.count else { return }

          let latestRelayList = relayListEvents.max {
            $0.createdAt.timestamp < $1.createdAt.timestamp
          }
          DispatchQueue.main.async {
            completion(.success(latestRelayList.map(Self.relayURLs(from:)) ?? []))
          }
        }
      }
    }
  }

  private func fetchInboxRelayEvent(
    from relayURL: URL,
    publicKey: String,
    completion: @escaping (Result<Event?, Error>) -> Void
  ) {
    DispatchQueue.global(qos: .background).async {
      do {
        let session = URLSession(configuration: .default)
        let webSocketTask = session.webSocketTask(with: relayURL)
        let subscription = Subscription(filters: [
          .init(
            authors: [publicKey],
            eventKinds: [.custom(10050)],
            limit: 1
          )
        ])
        let requestMessage = try ClientMessage.subscribe(subscription).string()
        let completionQueue = DispatchQueue(label: "nostr.messaging.dm-relay.\(UUID().uuidString)")
        var didComplete = false
        var latestEvent: Event?

        func finish(_ result: Result<Event?, Error>) {
          completionQueue.async {
            guard !didComplete else { return }

            didComplete = true
            if let closeMessage = try? ClientMessage.unsubscribe(subscription.id).string() {
              webSocketTask.send(.string(closeMessage)) { _ in }
            }
            webSocketTask.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            completion(result)
          }
        }

        func receiveNext() {
          webSocketTask.receive { result in
            switch result {
            case .success(let message):
              switch message {
              case .string(let text):
                if let relayMessage = try? RelayMessage(text: text) {
                  switch relayMessage {
                  case .event(let subscriptionID, let event):
                    if subscriptionID == subscription.id,
                      event.publicKey == publicKey,
                      event.kind == .custom(10050)
                    {
                      latestEvent = event
                    }
                    receiveNext()
                  case .other(let values):
                    if values.count >= 2,
                      values[0] == "EOSE",
                      values[1] == subscription.id
                    {
                      finish(.success(latestEvent))
                    } else {
                      receiveNext()
                    }
                  case .notice:
                    receiveNext()
                  }
                } else {
                  receiveNext()
                }
              case .data:
                receiveNext()
              @unknown default:
                receiveNext()
              }
            case .failure(let error):
              finish(.failure(error))
            }
          }
        }

        webSocketTask.resume()
        webSocketTask.send(.string(requestMessage)) { error in
          if let error {
            finish(.failure(error))
            return
          }

          receiveNext()
          DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 4) {
            finish(.success(latestEvent))
          }
        }
      } catch {
        completion(.failure(error))
      }
    }
  }

  private static func relayURLs(from event: Event) -> [URL] {
    uniqueRelayStrings(
      event.tags
        .filter { $0.id == "relay" }
        .compactMap { $0.otherInformation.first }
    )
    .compactMap { relayString in
      guard let url = URL(string: relayString),
        url.scheme == "wss",
        url.host != nil
      else {
        return nil
      }

      return url
    }
  }

  private static func uniqueRelayStrings(_ relayStrings: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []

    for relayString in relayStrings {
      let normalized = relayString
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      guard !normalized.isEmpty,
        !seen.contains(normalized)
      else {
        continue
      }

      seen.insert(normalized)
      result.append(normalized)
    }

    return result
  }
}

struct MessagingInboxSync {
  private struct DecryptedInboxMessage {
    let message: MessagingPlaintextMessage
    let wrapEventId: String
  }

  private let cryptoProvider: MessagingCryptoProvider
  private let historyWindow: TimeInterval = -60 * 60 * 24 * 14
  private let subscriptionLimit = 100

  init(cryptoProvider: MessagingCryptoProvider = NIP17MessagingCryptoProvider()) {
    self.cryptoProvider = cryptoProvider
  }

  func sync(
    recipientPrivateKeyHex: String,
    relayURLs: [URL],
    modelContainer: ModelContainer,
    completion: @escaping (Result<Int, Error>) -> Void
  ) {
    guard !relayURLs.isEmpty else {
      completion(.failure(MessagingError.missingRelay))
      return
    }

    guard let recipientPublicKey = privkey_to_pubkey(privkey: recipientPrivateKeyHex) else {
      completion(.failure(MessagingError.invalidKey))
      return
    }

    let completionQueue = DispatchQueue(label: "nostr.messaging.inbox.\(UUID().uuidString)")
    var completedRelays = 0
    var decryptedMessages: [DecryptedInboxMessage] = []

    for relayURL in relayURLs {
      fetchGiftWraps(
        from: relayURL,
        recipientPublicKey: recipientPublicKey,
        authPrivateKeyHex: recipientPrivateKeyHex
      ) { result in
        completionQueue.async {
          completedRelays += 1

          if case .success(let events) = result {
            for event in events {
              let envelope = MessagingEncryptedEnvelope(
                id: event.id,
                protocolKind: .nip17,
                recipientPublicKey: recipientPublicKey,
                event: event
              )

              if let plaintext = try? cryptoProvider.open(
                envelope,
                recipientPrivateKeyHex: recipientPrivateKeyHex
              ) {
                decryptedMessages.append(DecryptedInboxMessage(
                  message: plaintext,
                  wrapEventId: event.id
                ))
              }
            }
          }

          guard completedRelays == relayURLs.count else { return }

          let inserted = persist(
            decryptedMessages,
            activePublicKey: recipientPublicKey,
            modelContainer: modelContainer
          )

          DispatchQueue.main.async {
            completion(.success(inserted))
          }
        }
      }
    }
  }

  private func fetchGiftWraps(
    from relayURL: URL,
    recipientPublicKey: String,
    authPrivateKeyHex: String,
    completion: @escaping (Result<[Event], Error>) -> Void
  ) {
    DispatchQueue.global(qos: .background).async {
      do {
        let session = URLSession(configuration: .default)
        let webSocketTask = session.webSocketTask(with: relayURL)
        let subscription = Subscription(filters: [
          .init(
            eventKinds: [.custom(1059)],
            pubKeyTags: [recipientPublicKey],
            since: Timestamp(date: Date().addingTimeInterval(historyWindow)),
            limit: subscriptionLimit
          )
        ])
        let requestMessage = try ClientMessage.subscribe(subscription).string()
        let completionQueue = DispatchQueue(label: "nostr.messaging.inbox.relay.\(UUID().uuidString)")
        var didComplete = false
        var events: [Event] = []
        var authEventID: String?
        var isAuthInFlight = false
        var didAuthenticate = false
        var didSendRequest = false
        var didRetryRequestAfterAuth = false

        func finish(_ result: Result<[Event], Error>) {
          completionQueue.async {
            guard !didComplete else { return }

            didComplete = true

            if let closeMessage = try? ClientMessage.unsubscribe(subscription.id).string() {
              webSocketTask.send(.string(closeMessage)) { _ in }
            }

            webSocketTask.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            completion(result)
          }
        }

        func sendRequest() {
          guard !didSendRequest else { return }

          didSendRequest = true
          webSocketTask.send(.string(requestMessage)) { error in
            if let error {
              finish(.failure(error))
            }
          }
        }

        func sendAuth(challenge: String) {
          guard !isAuthInFlight,
            !didAuthenticate
          else {
            return
          }

          do {
            let auth = try NostrRelayAuth(
              challenge: challenge,
              relayURL: relayURL,
              privateKeyHex: authPrivateKeyHex
            )
            authEventID = auth.event.id
            isAuthInFlight = true
            webSocketTask.send(.string(try auth.messageString())) { error in
              if let error {
                finish(.failure(error))
              }
            }
          } catch {
            finish(.failure(error))
          }
        }

        func resendRequestAfterAuth() {
          guard didAuthenticate, !didRetryRequestAfterAuth else { return }

          didRetryRequestAfterAuth = true
          webSocketTask.send(.string(requestMessage)) { error in
            if let error {
              finish(.failure(error))
            }
          }
        }

        func receiveNext() {
          webSocketTask.receive { result in
            switch result {
            case .success(let message):
              switch message {
              case .string(let text):
                if let relayOK = MessagingRelayOK(text: text), relayOK.eventId == authEventID {
                  isAuthInFlight = false
                  if relayOK.accepted {
                    didAuthenticate = true
                    resendRequestAfterAuth()
                    receiveNext()
                  } else {
                    finish(.failure(NostrPublishError.relayRejected(relayURL, relayOK.message)))
                  }
                  return
                }

                if let auth = MessagingRelayAuthChallenge(text: text) {
                  sendAuth(challenge: auth.challenge)
                  receiveNext()
                  return
                }

                if let relayMessage = try? RelayMessage(text: text) {
                  switch relayMessage {
                  case .event(let subscriptionID, let event):
                    if subscriptionID == subscription.id {
                      events.append(event)
                    }
                    receiveNext()
                  case .other(let values):
                    if let closed = MessagingRelayClosed(values: values),
                      closed.subscriptionID == subscription.id
                    {
                      if closed.isAuthRequired {
                        if didAuthenticate {
                          resendRequestAfterAuth()
                        } else if !isAuthInFlight {
                          finish(.failure(NostrPublishError.relayRejected(relayURL, closed.message)))
                          return
                        }
                        receiveNext()
                      } else {
                        finish(.success(events))
                      }
                    } else if values.count >= 2,
                      values[0] == "EOSE",
                      values[1] == subscription.id
                    {
                      finish(.success(events))
                    } else {
                      receiveNext()
                    }
                  case .notice:
                    receiveNext()
                  }
                } else {
                  receiveNext()
                }
              case .data:
                receiveNext()
              @unknown default:
                receiveNext()
              }
            case .failure(let error):
              finish(.failure(error))
            }
          }
        }

        webSocketTask.resume()
        receiveNext()

        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.25) {
          if !isAuthInFlight && !didAuthenticate {
            sendRequest()
          }
        }

        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 8) {
          finish(.success(events))
        }
      } catch {
        completion(.failure(error))
      }
    }
  }

  private func persist(
    _ messages: [DecryptedInboxMessage],
    activePublicKey: String,
    modelContainer: ModelContainer
  ) -> Int {
    let context = ModelContext(modelContainer)
    var inserted = 0

    for decryptedMessage in messages {
      let message = decryptedMessage.message
      guard case .direct(let peerPublicKey) = message.conversation.kind else { continue }

      if let existing = existingMessage(
        rumorId: message.id,
        in: context
      ) {
        existing.deliveryState = "sent"
        existing.errorMessage = nil
        existing.peerPubkey = peerPublicKey
        existing.isFromCurrentUser = message.senderPublicKey == activePublicKey
        existing.wrapEventIds = appendedUnique(
          existing.wrapEventIds,
          decryptedMessage.wrapEventId
        )
        continue
      }

      let recipientPublicKey =
        message.senderPublicKey == activePublicKey ? peerPublicKey : activePublicKey
      let directMessage = RDirectMessage(
        id: UUID().uuidString,
        rumorId: message.id,
        conversationID: RDirectMessage.conversationID(activePublicKey, peerPublicKey),
        peerPubkey: peerPublicKey,
        senderPublicKey: message.senderPublicKey,
        recipientPublicKey: recipientPublicKey,
        content: message.content,
        createdAt: message.createdAt,
        isFromCurrentUser: message.senderPublicKey == activePublicKey,
        deliveryState: "sent",
        errorMessage: nil,
        wrapEventIds: [decryptedMessage.wrapEventId],
        protocolKind: messageProtocolKind.rawValue
      )

      context.insert(directMessage)
      inserted += 1
    }

    do {
      try context.save()
      return inserted
    } catch {
      return 0
    }
  }

  private func existingMessage(
    rumorId: String,
    in context: ModelContext
  ) -> RDirectMessage? {
    var rumorDescriptor = FetchDescriptor<RDirectMessage>(
      predicate: #Predicate { $0.rumorId == rumorId }
    )
    rumorDescriptor.fetchLimit = 1

    if let existing = try? context.fetch(rumorDescriptor).first {
      return existing
    }

    var legacyDescriptor = FetchDescriptor<RDirectMessage>(
      predicate: #Predicate { $0.id == rumorId }
    )
    legacyDescriptor.fetchLimit = 1

    return try? context.fetch(legacyDescriptor).first
  }

  private func appendedUnique(_ values: [String], _ value: String) -> [String] {
    guard !value.isEmpty, !values.contains(value) else { return values }
    return values + [value]
  }

  private var messageProtocolKind: MessagingProtocolKind {
    cryptoProvider.protocolKind
  }
}

final class MessagingService {
  private let cryptoProvider: MessagingCryptoProvider
  private let transport: MessagingTransport
  private let relayResolver: MessagingRelayResolver

  init(
    cryptoProvider: MessagingCryptoProvider = NIP17MessagingCryptoProvider(),
    transport: MessagingTransport = NostrMessagingTransport(),
    relayResolver: MessagingRelayResolver = NIP17MessagingRelayResolver()
  ) {
    self.cryptoProvider = cryptoProvider
    self.transport = transport
    self.relayResolver = relayResolver
  }

  func buildDirectMessage(
    currentUserPublicKey: String,
    peerPublicKey: String,
    content: String,
    createdAt: Date = Date()
  ) throws -> MessagingPlaintextMessage {
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      throw MessagingError.emptyMessage
    }

    guard Self.isValidPublicKeyHex(currentUserPublicKey) else {
      throw MessagingError.invalidKey
    }

    guard Self.isValidPublicKeyHex(peerPublicKey) else {
      throw MessagingError.invalidRecipient
    }

    let conversation = MessagingConversation.direct(
      currentUserPublicKey: currentUserPublicKey,
      peerPublicKey: peerPublicKey
    )
    let draft = MessagingPlaintextMessage(
      id: "",
      conversation: conversation,
      senderPublicKey: currentUserPublicKey,
      content: trimmedContent,
      createdAt: createdAt
    )
    let rumor = try NIP17Rumor.from(message: draft, authorPublicKey: currentUserPublicKey)

    return MessagingPlaintextMessage(
      id: rumor.id,
      conversation: conversation,
      senderPublicKey: currentUserPublicKey,
      content: trimmedContent,
      createdAt: Date(timeIntervalSince1970: Double(rumor.createdAt.timestamp))
    )
  }

  func publishInboxRelayList(
    privateKeyHex: String,
    relayURLs: [URL],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let publicKey = privkey_to_pubkey(privkey: privateKeyHex) else {
      completion(.failure(MessagingError.invalidKey))
      return
    }

    let relayURLs = Array(relayURLs.prefix(3))
    guard !relayURLs.isEmpty else {
      completion(.failure(MessagingError.missingRelay))
      return
    }

    do {
      let tags = relayURLs.map { EventTag(id: "relay", otherInformation: $0.absoluteString) }
      let event = try NostrEventFactory.signedEvent(
        privateKeyHex: privateKeyHex,
        kind: .custom(10050),
        tags: tags,
        content: "",
        createdAt: Timestamp(date: Date())
      )
      let envelope = MessagingEncryptedEnvelope(
        id: event.id,
        protocolKind: .nip17,
        recipientPublicKey: publicKey,
        event: event
      )
      transport.publish(
        [MessagingPublishRoute(envelope: envelope, relayURLs: relayURLs, isRequired: true)],
        authPrivateKeyHex: privateKeyHex
      ) { result in
        switch result {
        case .success:
          completion(.success(()))
        case .failure(let error):
          completion(.failure(error))
        }
      }
    } catch {
      completion(.failure(error))
    }
  }

  func send(
    _ request: MessagingSendRequest,
    completion: @escaping (Result<MessagingSendResult, Error>) -> Void
  ) {
    let content = request.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else {
      completion(.failure(MessagingError.emptyMessage))
      return
    }

    guard !request.relayURLs.isEmpty else {
      completion(.failure(MessagingError.missingRelay))
      return
    }

    do {
      let envelopes = try cryptoProvider.seal(
        request.message,
        senderPrivateKeyHex: request.senderPrivateKeyHex
      )
      let wrapEventIds = envelopes.map(\.id)
      guard case .direct(let peerPublicKey) = request.message.conversation.kind else {
        completion(.failure(MessagingSendFailure(
          underlyingError: MessagingError.invalidConversation,
          wrapEventIds: wrapEventIds
        )))
        return
      }

      relayResolver.resolveRoutes(
        for: envelopes,
        senderPublicKey: request.message.senderPublicKey,
        peerPublicKey: peerPublicKey,
        localRelayURLs: request.relayURLs
      ) { [transport] result in
        switch result {
        case .success(let routes):
          transport.publish(
            routes,
            authPrivateKeyHex: request.senderPrivateKeyHex,
            completion: { result in
              switch result {
              case .success:
                completion(.success(MessagingSendResult(wrapEventIds: wrapEventIds)))
              case .failure(let error):
                completion(.failure(MessagingSendFailure(
                  underlyingError: error,
                  wrapEventIds: wrapEventIds
                )))
              }
            }
          )
        case .failure(let error):
          completion(.failure(MessagingSendFailure(
            underlyingError: error,
            wrapEventIds: wrapEventIds
          )))
        }
      }
    } catch {
      completion(.failure(error))
    }
  }

  private static func isValidPublicKeyHex(_ value: String) -> Bool {
    let normalized = value.lowercased()
    let hexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
    return normalized.count == 64
      && normalized.unicodeScalars.allSatisfy { hexCharacters.contains($0) }
  }
}

private struct NIP17Rumor: Codable {
  let id: String
  let publicKey: String
  let createdAt: Timestamp
  let kind: EventKind
  let tags: [EventTag]
  let content: String

  enum CodingKeys: String, CodingKey {
    case id
    case publicKey = "pubkey"
    case createdAt = "created_at"
    case kind
    case tags
    case content
  }

  var taggedPublicKeys: [String] {
    tags
      .filter { $0.id == "p" }
      .compactMap { $0.otherInformation.first }
  }

  static func from(message: MessagingPlaintextMessage, authorPublicKey: String) throws -> NIP17Rumor {
    let createdAt = Timestamp(date: message.createdAt)
    let tags = message.conversation.participants
      .filter { $0 != authorPublicKey }
      .map { EventTag.pubKey(publicKey: $0) }
    let serializable = NostrSerializableEvent(
      publicKey: authorPublicKey,
      createdAt: createdAt,
      kind: .custom(14),
      tags: tags,
      content: message.content
    )
    let serialized = try NostrCanonicalJSON.encode(serializable)
    let eventID = Data(CryptoKit.SHA256.hash(data: serialized)).nostrHex

    return NIP17Rumor(
      id: eventID,
      publicKey: authorPublicKey,
      createdAt: createdAt,
      kind: .custom(14),
      tags: tags,
      content: message.content
    )
  }

  func computedID() throws -> String {
    let serializable = NostrSerializableEvent(
      publicKey: publicKey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content
    )
    let serialized = try NostrCanonicalJSON.encode(serializable)
    return Data(CryptoKit.SHA256.hash(data: serialized)).nostrHex
  }

  func jsonString() throws -> String {
    let data = try NostrCanonicalJSON.encode(self)
    guard let json = String(data: data, encoding: .utf8) else {
      throw MessagingError.encryptionFailed
    }

    return json
  }
}

private extension Event {
  func jsonString() throws -> String {
    let data = try NostrCanonicalJSON.encode(self)
    guard let json = String(data: data, encoding: .utf8) else {
      throw MessagingError.encryptionFailed
    }

    return json
  }
}

private enum NIP44 {
  private static let versionByte: UInt8 = 2
  private static let minPlaintextBytes = 1
  private static let maxPlaintextBytes = 1_048_576
  private static let extendedPrefixThreshold = 65_536
  private static let nonceBytes = 32
  private static let chachaNonceBytes = 12
  private static let macBytes = 32
  private static let hkdfSalt = Data("nip44-v2".utf8)
  private static let xCoordinateECDH: secp256k1.KeyAgreement.PrivateKey.HashFunctionType = {
    output,
    x,
    _,
    _ in
    guard let output, let x else { return 0 }
    output.update(from: x, count: 32)
    return 1
  }

  static func conversationKey(privateKeyHex: String, publicKeyHex: String) throws -> Data {
    let privateKeyData = try Data(nostrHex: privateKeyHex)
    let publicKeyData = try Data(nostrHex: publicKeyHex)
    guard publicKeyData.count == 32 else {
      throw MessagingError.invalidRecipient
    }

    do {
      let privateKey = try secp256k1.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
      var compressedPublicKey = Data([0x02])
      compressedPublicKey.append(publicKeyData)
      let publicKey = try secp256k1.KeyAgreement.PublicKey(
        rawRepresentation: compressedPublicKey,
        format: .compressed
      )
      let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(
        with: publicKey,
        handler: xCoordinateECDH
      )
      let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
      return hkdfExtract(inputKeyMaterial: sharedSecretData, salt: hkdfSalt)
    } catch {
      throw MessagingError.invalidKey
    }
  }

  static func encrypt(_ plaintext: String, conversationKey: Data) throws -> String {
    let nonce = try Data.secureRandom(count: nonceBytes)
    return try encrypt(plaintext, conversationKey: conversationKey, nonce: nonce)
  }

  static func encrypt(_ plaintext: String, conversationKey: Data, nonce: Data) throws -> String {
    let plaintextData = Data(plaintext.utf8)
    guard plaintextData.count >= minPlaintextBytes else {
      throw MessagingError.emptyMessage
    }
    guard plaintextData.count <= maxPlaintextBytes else {
      throw MessagingError.messageTooLong
    }
    guard conversationKey.count == 32, nonce.count == nonceBytes else {
      throw MessagingError.encryptionFailed
    }

    let keys = hkdfExpand(pseudorandomKey: conversationKey, info: nonce, outputByteCount: 76)
    let chachaKey = Data(keys[0..<32])
    let chachaNonce = Data(keys[32..<44])
    let hmacKey = Data(keys[44..<76])
    let paddedPlaintext = try pad(plaintextData)
    let ciphertext = try ChaCha20.xor(data: paddedPlaintext, key: chachaKey, nonce: chachaNonce)
    let mac = hmac(key: hmacKey, data: nonce + ciphertext)

    var payload = Data([versionByte])
    payload.append(nonce)
    payload.append(ciphertext)
    payload.append(mac)
    return payload.base64EncodedString()
  }

  static func decrypt(_ payload: String, conversationKey: Data) throws -> String {
    guard let payloadData = Data(base64Encoded: payload),
      payloadData.count >= 1 + nonceBytes + 2 + macBytes,
      payloadData.first == versionByte
    else {
      throw MessagingError.encryptionFailed
    }

    let nonce = Data(payloadData[1..<(1 + nonceBytes)])
    let macStartIndex = payloadData.count - macBytes
    let ciphertext = Data(payloadData[(1 + nonceBytes)..<macStartIndex])
    let expectedMac = Data(payloadData[macStartIndex..<payloadData.count])

    let keys = hkdfExpand(pseudorandomKey: conversationKey, info: nonce, outputByteCount: 76)
    let chachaKey = Data(keys[0..<32])
    let chachaNonce = Data(keys[32..<44])
    let hmacKey = Data(keys[44..<76])
    let actualMac = hmac(key: hmacKey, data: nonce + ciphertext)
    guard constantTimeEquals(actualMac, expectedMac) else {
      throw MessagingError.encryptionFailed
    }

    let paddedPlaintext = try ChaCha20.xor(data: ciphertext, key: chachaKey, nonce: chachaNonce)
    let plaintext = try unpad(paddedPlaintext)
    guard let decrypted = String(data: plaintext, encoding: .utf8) else {
      throw MessagingError.encryptionFailed
    }

    return decrypted
  }

  private static func pad(_ plaintext: Data) throws -> Data {
    let unpaddedLength = plaintext.count
    guard unpaddedLength <= maxPlaintextBytes else {
      throw MessagingError.messageTooLong
    }

    let paddedLength = paddedLength(for: unpaddedLength)
    var padded = Data()
    if unpaddedLength >= extendedPrefixThreshold {
      padded.append(contentsOf: [0, 0])
      padded.appendUInt32BE(UInt32(unpaddedLength))
    } else {
      padded.appendUInt16BE(UInt16(unpaddedLength))
    }
    padded.append(plaintext)
    padded.append(Data(repeating: 0, count: paddedLength - unpaddedLength))
    return padded
  }

  private static func unpad(_ paddedPlaintext: Data) throws -> Data {
    guard paddedPlaintext.count >= 2 else {
      throw MessagingError.encryptionFailed
    }

    let firstTwoBytes = paddedPlaintext.uint16BE(at: 0)
    let prefixLength: Int
    let unpaddedLength: Int

    if firstTwoBytes == 0 {
      guard paddedPlaintext.count >= 6 else {
        throw MessagingError.encryptionFailed
      }

      unpaddedLength = Int(paddedPlaintext.uint32BE(at: 2))
      guard unpaddedLength >= extendedPrefixThreshold else {
        throw MessagingError.encryptionFailed
      }
      prefixLength = 6
    } else {
      unpaddedLength = Int(firstTwoBytes)
      prefixLength = 2
    }

    let paddedLength = paddedLength(for: unpaddedLength)
    guard paddedPlaintext.count == paddedLength + prefixLength,
      unpaddedLength >= minPlaintextBytes,
      unpaddedLength <= maxPlaintextBytes,
      unpaddedLength <= paddedPlaintext.count - prefixLength
    else {
      throw MessagingError.encryptionFailed
    }

    return Data(paddedPlaintext[prefixLength..<(prefixLength + unpaddedLength)])
  }

  private static func paddedLength(for unpaddedLength: Int) -> Int {
    if unpaddedLength <= 32 {
      return 32
    }

    let nextPower = 1 << (Int(log2(Double(unpaddedLength - 1))) + 1)
    let chunk = nextPower <= 256 ? 32 : nextPower / 8
    return chunk * (((unpaddedLength - 1) / chunk) + 1)
  }

  private static func hkdfExtract(inputKeyMaterial: Data, salt: Data) -> Data {
    hmac(key: salt, data: inputKeyMaterial)
  }

  private static func hkdfExpand(
    pseudorandomKey: Data,
    info: Data,
    outputByteCount: Int
  ) -> Data {
    var output = Data()
    var previousBlock = Data()
    var counter: UInt8 = 1

    while output.count < outputByteCount {
      var input = Data()
      input.append(previousBlock)
      input.append(info)
      input.append(counter)
      previousBlock = hmac(key: pseudorandomKey, data: input)
      output.append(previousBlock)
      counter &+= 1
    }

    return Data(output.prefix(outputByteCount))
  }

  private static func hmac(key: Data, data: Data) -> Data {
    let authenticationCode = CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(
      for: data,
      using: SymmetricKey(data: key)
    )
    return Data(authenticationCode)
  }

  private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0

    for index in lhs.indices {
      difference |= lhs[index] ^ rhs[index]
    }

    return difference == 0
  }
}

private enum ChaCha20 {
  static func xor(data: Data, key: Data, nonce: Data) throws -> Data {
    guard key.count == 32, nonce.count == 12 else {
      throw MessagingError.encryptionFailed
    }

    var output = Data(count: data.count)
    var counter: UInt32 = 0
    var offset = 0

    while offset < data.count {
      let block = block(key: key, nonce: nonce, counter: counter)
      let blockSize = min(64, data.count - offset)

      for index in 0..<blockSize {
        output[offset + index] = data[offset + index] ^ block[index]
      }

      counter &+= 1
      offset += blockSize
    }

    return output
  }

  private static func block(key: Data, nonce: Data, counter: UInt32) -> [UInt8] {
    var state: [UInt32] = [
      0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
      key.uint32LE(at: 0), key.uint32LE(at: 4), key.uint32LE(at: 8), key.uint32LE(at: 12),
      key.uint32LE(at: 16), key.uint32LE(at: 20), key.uint32LE(at: 24), key.uint32LE(at: 28),
      counter, nonce.uint32LE(at: 0), nonce.uint32LE(at: 4), nonce.uint32LE(at: 8),
    ]
    let originalState = state

    for _ in 0..<10 {
      quarterRound(&state, 0, 4, 8, 12)
      quarterRound(&state, 1, 5, 9, 13)
      quarterRound(&state, 2, 6, 10, 14)
      quarterRound(&state, 3, 7, 11, 15)
      quarterRound(&state, 0, 5, 10, 15)
      quarterRound(&state, 1, 6, 11, 12)
      quarterRound(&state, 2, 7, 8, 13)
      quarterRound(&state, 3, 4, 9, 14)
    }

    for index in state.indices {
      state[index] &+= originalState[index]
    }

    var result: [UInt8] = []
    result.reserveCapacity(64)
    for word in state {
      result.append(UInt8(truncatingIfNeeded: word))
      result.append(UInt8(truncatingIfNeeded: word >> 8))
      result.append(UInt8(truncatingIfNeeded: word >> 16))
      result.append(UInt8(truncatingIfNeeded: word >> 24))
    }

    return result
  }

  private static func quarterRound(
    _ state: inout [UInt32],
    _ a: Int,
    _ b: Int,
    _ c: Int,
    _ d: Int
  ) {
    state[a] &+= state[b]
    state[d] = rotateLeft(state[d] ^ state[a], by: 16)
    state[c] &+= state[d]
    state[b] = rotateLeft(state[b] ^ state[c], by: 12)
    state[a] &+= state[b]
    state[d] = rotateLeft(state[d] ^ state[a], by: 8)
    state[c] &+= state[d]
    state[b] = rotateLeft(state[b] ^ state[c], by: 7)
  }

  private static func rotateLeft(_ value: UInt32, by count: UInt32) -> UInt32 {
    (value << count) | (value >> (32 - count))
  }
}

private struct MessagingRelayOK {
  let eventId: String
  let accepted: Bool
  let message: String

  init?(text: String) {
    guard let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
      json.count >= 4,
      (json.first as? String) == "OK",
      let eventId = json[1] as? String,
      let accepted = json[2] as? Bool,
      let message = json[3] as? String
    else {
      return nil
    }

    self.eventId = eventId
    self.accepted = accepted
    self.message = message
  }
}

private struct MessagingRelayAuthChallenge {
  let challenge: String

  init?(text: String) {
    guard let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
      json.count >= 2,
      (json.first as? String) == "AUTH",
      let challenge = json[1] as? String
    else {
      return nil
    }

    self.challenge = challenge
  }
}

private struct MessagingRelayClosed {
  let subscriptionID: String
  let message: String

  init?(values: [String]) {
    guard values.count >= 3,
      values[0] == "CLOSED"
    else {
      return nil
    }

    self.subscriptionID = values[1]
    self.message = values[2]
  }

  var isAuthRequired: Bool {
    message.hasPrefix("auth-required:")
  }
}

private struct NostrRelayAuth {
  let event: Event

  init(challenge: String, relayURL: URL, privateKeyHex: String) throws {
    event = try NostrEventFactory.signedEvent(
      privateKeyHex: privateKeyHex,
      kind: .custom(22242),
      tags: [
        EventTag(id: "relay", otherInformation: relayURL.absoluteString),
        EventTag(id: "challenge", otherInformation: challenge),
      ],
      content: "",
      createdAt: Timestamp(date: Date())
    )
  }

  func messageString() throws -> String {
    let data = try NostrCanonicalJSON.encode(NostrRelayAuthMessage(event: event))
    guard let message = String(data: data, encoding: .utf8) else {
      throw MessagingError.encryptionFailed
    }

    return message
  }
}

private struct NostrRelayAuthMessage: Encodable {
  let event: Event

  func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    try container.encode("AUTH")
    try container.encode(event)
  }
}

private extension Data {
  var nostrHex: String {
    hex_encode(self)
  }

  init(nostrHex: String) throws {
    guard let bytes = hex_decode(nostrHex), bytes.count == 32 else {
      throw MessagingError.invalidKey
    }
    self = Data(bytes)
  }

  init(nostrHex: String, expectedByteCount: Int) throws {
    guard let bytes = hex_decode(nostrHex), bytes.count == expectedByteCount else {
      throw MessagingError.invalidKey
    }
    self = Data(bytes)
  }

  static func secureRandom(count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
      throw MessagingError.encryptionFailed
    }
    return Data(bytes)
  }

  mutating func appendUInt16BE(_ value: UInt16) {
    append(UInt8((value >> 8) & 0xff))
    append(UInt8(value & 0xff))
  }

  mutating func appendUInt32BE(_ value: UInt32) {
    append(UInt8((value >> 24) & 0xff))
    append(UInt8((value >> 16) & 0xff))
    append(UInt8((value >> 8) & 0xff))
    append(UInt8(value & 0xff))
  }

  func uint16BE(at offset: Int) -> UInt16 {
    UInt16(self[offset]) << 8
      | UInt16(self[offset + 1])
  }

  func uint32BE(at offset: Int) -> UInt32 {
    UInt32(self[offset]) << 24
      | UInt32(self[offset + 1]) << 16
      | UInt32(self[offset + 2]) << 8
      | UInt32(self[offset + 3])
  }

  func uint32LE(at offset: Int) -> UInt32 {
    UInt32(self[offset])
      | UInt32(self[offset + 1]) << 8
      | UInt32(self[offset + 2]) << 16
      | UInt32(self[offset + 3]) << 24
  }
}
