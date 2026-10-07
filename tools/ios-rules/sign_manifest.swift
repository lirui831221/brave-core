#!/usr/bin/env swift
import CryptoKit
import Foundation
import Security

private let keychainService = "com.lirui.brave-ios-rules.signing"
private let keychainAccount = "manifest-ed25519-v1"
private let signingKeyID = "brave-ios-rules-v1"

private struct RuleAsset: Codable {
  let url: String
  let sha256: String
  let byteCount: Int
}

private struct ManifestPayload: Codable {
  let schemaVersion: Int
  let ruleVersion: String
  let minimumAppVersion: String
  let publishedAt: String
  let keyID: String
  let rules: RuleAsset
}

private struct SignedEnvelope: Codable {
  let payload: String
  let signature: String
}

private enum ToolError: Error, CustomStringConvertible {
  case usage(String)
  case keychain(OSStatus)
  case missingKey
  case invalidKey
  case invalidURL
  case invalidSignature
  case assetMismatch

  var description: String {
    switch self {
    case .usage(let text): return text
    case .keychain(let status): return "Keychain operation failed (status \(status))."
    case .missingKey: return "The signing key is missing. Run keygen on the release Mac first."
    case .invalidKey: return "The signing key or public key is invalid."
    case .invalidURL: return "The asset URL must be an immutable HTTPS GitHub Release URL."
    case .invalidSignature: return "The manifest signature is invalid."
    case .assetMismatch: return "The rules file does not match the signed size and SHA-256."
    }
  }
}

private func baseQuery() -> [CFString: Any] {
  [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: keychainService,
    kSecAttrAccount: keychainAccount,
  ]
}

private func loadPrivateKey() throws -> Curve25519.Signing.PrivateKey {
  var query = baseQuery()
  query[kSecReturnData] = true
  query[kSecMatchLimit] = kSecMatchLimitOne
  var result: CFTypeRef?
  let status = SecItemCopyMatching(query as CFDictionary, &result)
  guard status != errSecItemNotFound else { throw ToolError.missingKey }
  guard status == errSecSuccess, let data = result as? Data else {
    throw ToolError.keychain(status)
  }
  do {
    return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
  } catch {
    throw ToolError.invalidKey
  }
}

private func generateKeyIfNeeded() throws -> Curve25519.Signing.PrivateKey {
  do {
    return try loadPrivateKey()
  } catch ToolError.missingKey {
    // Create a key only when the expected Keychain item is absent. Authentication and
    // corruption errors must remain visible instead of being mistaken for a missing key.
  } catch {
    throw error
  }
  let key = Curve25519.Signing.PrivateKey()
  var query = baseQuery()
  query[kSecValueData] = key.rawRepresentation
  query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
  let status = SecItemAdd(query as CFDictionary, nil)
  guard status == errSecSuccess else { throw ToolError.keychain(status) }
  return key
}

private func arguments() throws -> (command: String, values: [String: String]) {
  let raw = Array(CommandLine.arguments.dropFirst())
  guard let command = raw.first else {
    throw ToolError.usage(usage)
  }
  var values: [String: String] = [:]
  var index = 1
  while index < raw.count {
    guard raw[index].hasPrefix("--"), index + 1 < raw.count else {
      throw ToolError.usage(usage)
    }
    values[String(raw[index].dropFirst(2))] = raw[index + 1]
    index += 2
  }
  return (command, values)
}

private func required(_ name: String, in values: [String: String]) throws -> String {
  guard let value = values[name], !value.isEmpty else {
    throw ToolError.usage("Missing --\(name).\n\n\(usage)")
  }
  return value
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func validateReleaseURL(_ value: String, version: String) throws -> URL {
  guard
    let url = URL(string: value),
    url.scheme?.lowercased() == "https",
    url.host?.lowercased() == "github.com",
    url.path.contains("/releases/download/ios-rules-v\(version)/"),
    url.lastPathComponent == "rules.txt"
  else {
    throw ToolError.invalidURL
  }
  return url
}

private func validateVersion(_ value: String) throws {
  let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
  let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
  guard !parts.isEmpty, parts.count <= 4,
    parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0) != nil })
  else {
    throw ToolError.usage("Versions must contain one to four numeric components.")
  }
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try encoder.encode(value).write(to: url, options: .atomic)
}

private let usage = """
  Usage:
    sign_manifest.swift keygen
    sign_manifest.swift public-key
    sign_manifest.swift sign --rules PATH --version 12.1 --url HTTPS_RELEASE_URL \\
      --minimum-app-version 1.98.0 --output PATH
    sign_manifest.swift verify --manifest PATH --rules PATH --public-key BASE64

  The private Ed25519 key is stored in this Mac's Keychain and is never printed.
  """

do {
  let parsed = try arguments()
  switch parsed.command {
  case "keygen":
    let key = try generateKeyIfNeeded()
    print("key_id=\(signingKeyID)")
    print("public_key_base64=\(key.publicKey.rawRepresentation.base64EncodedString())")

  case "public-key":
    let key = try loadPrivateKey()
    print(key.publicKey.rawRepresentation.base64EncodedString())

  case "sign":
    let rulesPath = try required("rules", in: parsed.values)
    let version = try required("version", in: parsed.values)
    try validateVersion(version)
    let assetURL = try validateReleaseURL(
      required("url", in: parsed.values),
      version: version
    )
    let minimumAppVersion = try required("minimum-app-version", in: parsed.values)
    try validateVersion(minimumAppVersion)
    let outputPath = try required("output", in: parsed.values)
    let rulesData = try Data(contentsOf: URL(fileURLWithPath: rulesPath))
    let payload = ManifestPayload(
      schemaVersion: 1,
      ruleVersion: version,
      minimumAppVersion: minimumAppVersion,
      publishedAt: ISO8601DateFormatter().string(from: Date()),
      keyID: signingKeyID,
      rules: RuleAsset(
        url: assetURL.absoluteString,
        sha256: sha256Hex(rulesData),
        byteCount: rulesData.count
      )
    )
    let payloadEncoder = JSONEncoder()
    payloadEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payloadData = try payloadEncoder.encode(payload)
    let privateKey = try loadPrivateKey()
    let signature = try privateKey.signature(for: payloadData)
    try writeJSON(
      SignedEnvelope(
        payload: payloadData.base64EncodedString(),
        signature: signature.base64EncodedString()
      ),
      to: URL(fileURLWithPath: outputPath)
    )
    print("signed_version=\(version)")
    print("rules_sha256=\(sha256Hex(rulesData))")

  case "verify":
    let manifestData = try Data(
      contentsOf: URL(fileURLWithPath: required("manifest", in: parsed.values))
    )
    let rulesData = try Data(
      contentsOf: URL(fileURLWithPath: required("rules", in: parsed.values))
    )
    let publicKeyString = try required("public-key", in: parsed.values)
    guard
      let publicKeyData = Data(base64Encoded: publicKeyString),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    else {
      throw ToolError.invalidKey
    }
    let envelope = try JSONDecoder().decode(SignedEnvelope.self, from: manifestData)
    guard
      let payloadData = Data(base64Encoded: envelope.payload),
      let signature = Data(base64Encoded: envelope.signature),
      publicKey.isValidSignature(signature, for: payloadData)
    else {
      throw ToolError.invalidSignature
    }
    let payload = try JSONDecoder().decode(ManifestPayload.self, from: payloadData)
    try validateVersion(payload.ruleVersion)
    try validateVersion(payload.minimumAppVersion)
    guard payload.schemaVersion == 1, payload.keyID == signingKeyID else {
      throw ToolError.invalidSignature
    }
    _ = try validateReleaseURL(payload.rules.url, version: payload.ruleVersion)
    guard payload.rules.byteCount == rulesData.count,
      payload.rules.sha256 == sha256Hex(rulesData)
    else {
      throw ToolError.assetMismatch
    }
    print("verified_version=\(payload.ruleVersion)")
    print("verified_key_id=\(payload.keyID)")

  default:
    throw ToolError.usage(usage)
  }
} catch {
  FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
  exit(1)
}
