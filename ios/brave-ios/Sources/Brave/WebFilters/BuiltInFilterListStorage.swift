// Copyright 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation

/// Stores rules shipped and updated by this distribution separately from user-authored rules.
///
/// A candidate is never exposed to the blocking engines until it has passed structural
/// validation, WebKit conversion and an adblock-rust trial compile. The active file is replaced
/// with an atomic write, while the previous active bytes remain available for rollback.
actor BuiltInFilterListStorage {
  enum FailureReason: String, Codable, Equatable, Sendable {
    case insecureSource = "insecure_source"
    case http403 = "http_403"
    case http404 = "http_404"
    case httpError = "http_error"
    case timedOut = "timed_out"
    case offline = "offline"
    case downloadFailed = "download_failed"
    case invalidManifest = "invalid_manifest"
    case invalidSignature = "invalid_signature"
    case unsupportedSchema = "unsupported_schema"
    case incompatibleAppVersion = "incompatible_app_version"
    case versionRollback = "version_rollback"
    case hashMismatch = "hash_mismatch"
    case sizeMismatch = "size_mismatch"
    case emptyContent = "empty_content"
    case invalidEncoding = "invalid_utf8"
    case unexpectedDocument = "unexpected_document"
    case tooLarge = "too_large"
    case tooManyLines = "too_many_lines"
    case invalidRule = "invalid_rule"
    case trialCompilationFailed = "trial_compilation_failed"
    case storageFailed = "storage_failed"
    case activationFailed = "activation_failed"

    var displayDescription: String {
      switch self {
      case .insecureSource: return "The update source is not HTTPS."
      case .http403: return "The update server denied access (HTTP 403)."
      case .http404: return "The update file was not found (HTTP 404)."
      case .httpError: return "The update server returned an HTTP error."
      case .timedOut: return "The update request timed out."
      case .offline: return "The device was offline."
      case .downloadFailed: return "The update could not be downloaded."
      case .invalidManifest: return "The signed update manifest was invalid."
      case .invalidSignature: return "The update manifest signature was invalid."
      case .unsupportedSchema: return "The update manifest format is not supported."
      case .incompatibleAppVersion: return "The update requires a newer browser version."
      case .versionRollback: return "An older or reused rule version was rejected."
      case .hashMismatch: return "The downloaded rules did not match the signed SHA-256."
      case .sizeMismatch: return "The downloaded rules did not match the signed size."
      case .emptyContent: return "The downloaded rule list was empty."
      case .invalidEncoding: return "The downloaded rule list was not valid UTF-8."
      case .unexpectedDocument:
        return "The server returned an HTML or JSON document instead of rules."
      case .tooLarge: return "The downloaded rule list exceeded the size limit."
      case .tooManyLines: return "The downloaded rule list exceeded the line limit."
      case .invalidRule: return "The candidate contained a rule that WebKit could not compile."
      case .trialCompilationFailed: return "The candidate failed the ad-block engine trial compile."
      case .storageFailed: return "The validated rules could not be stored safely."
      case .activationFailed:
        return "The validated rules could not be activated; the previous rules remain active."
      }
    }
  }

  struct DiagnosticStatus: Codable, Equatable, Sendable {
    var activeVersion: String?
    var activeSHA256: String?
    var activeRuleCount: Int
    var lastSuccessDate: Date?
    var lastFailureDate: Date?
    var lastFailureReason: FailureReason?
    var lastAttemptSource: String?
    var lastCheckDate: Date?
    var manifestETag: String?

    static let empty = DiagnosticStatus(
      activeVersion: nil,
      activeSHA256: nil,
      activeRuleCount: 0,
      lastSuccessDate: nil,
      lastFailureDate: nil,
      lastFailureReason: nil,
      lastAttemptSource: nil,
      lastCheckDate: nil,
      manifestETag: nil
    )
  }

  struct DownloadPayload: Sendable {
    let data: Data
    let statusCode: Int
    let mimeType: String?
    let etag: String?
    let finalURL: URL?

    init(
      data: Data,
      statusCode: Int,
      mimeType: String?,
      etag: String? = nil,
      finalURL: URL? = nil
    ) {
      self.data = data
      self.statusCode = statusCode
      self.mimeType = mimeType
      self.etag = etag
      self.finalURL = finalURL
    }
  }

  struct InstallResult: Equatable, Sendable {
    let changed: Bool
    let status: DiagnosticStatus
  }

  enum RefreshOutcome: String, Equatable, Sendable {
    case updated
    case upToDate
    case notModified
    case deferred
  }

  struct RefreshResult: Equatable, Sendable {
    let outcome: RefreshOutcome
    let status: DiagnosticStatus
  }

  struct SignedManifestEnvelope: Codable, Equatable, Sendable {
    let payload: String
    let signature: String
  }

  struct ManifestPayload: Codable, Equatable, Sendable {
    struct RuleAsset: Codable, Equatable, Sendable {
      let url: String
      let sha256: String
      let byteCount: Int
    }

    let schemaVersion: Int
    let ruleVersion: String
    let minimumAppVersion: String
    let publishedAt: String
    let keyID: String
    let rules: RuleAsset
  }

  enum StoreError: Error, Equatable {
    case insecureSource
    case httpStatus(Int)
    case noHTTPResponse
    case invalidManifest
    case invalidSignature
    case unsupportedSchema
    case incompatibleAppVersion
    case versionRollback
    case hashMismatch
    case sizeMismatch
    case emptyContent
    case invalidEncoding
    case unexpectedDocument
    case tooLarge
    case tooManyLines
    case invalidRule(line: Int)
    case trialCompilationFailed
    case storageFailed
    case activationFailed
  }

  struct Dependencies: Sendable {
    var download: @Sendable (URL) async throws -> DownloadPayload
    var downloadManifest: @Sendable (URL, String?) async throws -> DownloadPayload
    var validateAndTrialCompile: @Sendable (String, URL, String) async throws -> Void
    var activate: @Sendable (URL, String) async throws -> Void
    var now: @Sendable () -> Date
    var currentAppVersion: @Sendable () -> String
    var manifestPublicKey: Data

    init(
      download: @escaping @Sendable (URL) async throws -> DownloadPayload,
      validateAndTrialCompile: @escaping @Sendable (String, URL, String) async throws -> Void,
      activate: @escaping @Sendable (URL, String) async throws -> Void,
      now: @escaping @Sendable () -> Date,
      downloadManifest: (@Sendable (URL, String?) async throws -> DownloadPayload)? = nil,
      currentAppVersion: @escaping @Sendable () -> String = { "1.98.0" },
      manifestPublicKey: Data = BuiltInFilterListStorage.productionManifestPublicKey
    ) {
      self.download = download
      self.downloadManifest = downloadManifest ?? { url, _ in try await download(url) }
      self.validateAndTrialCompile = validateAndTrialCompile
      self.activate = activate
      self.now = now
      self.currentAppVersion = currentAppVersion
      self.manifestPublicKey = manifestPublicKey
    }
  }

  static let shared = BuiltInFilterListStorage()
  static let maximumBytes = 16 * 1_024 * 1_024
  static let maximumLines = 100_000
  static let refreshInterval: TimeInterval = 24 * 60 * 60
  static let automaticCheckInterval: TimeInterval = 6 * 60 * 60
  static let productionManifestURL = URL(
    string:
      "https://github.com/lirui831221/brave-ios-rules/releases/latest/download/manifest.json"
  )!
  static let productionManifestPublicKey = Data(
    base64Encoded: "qzNx5MIgHOYlUl8b6jTRSZwmWQQK2BxDfYUvaqgNo24="
  )!
  static let productionManifestKeyID = "brave-ios-rules-v1"

  private static let folderName = "built_in_rules"
  private static let activeFileName = "active.txt"
  private static let previousFileName = "previous.txt"
  private static let metadataFileName = "status.json"

  static var defaultRootDirectoryURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent(folderName, isDirectory: true)
  }

  static var hasActiveRules: Bool {
    FileManager.default.fileExists(
      atPath: defaultRootDirectoryURL.appendingPathComponent(activeFileName).path
    )
  }

  static func bundledSnapshot() throws -> String {
    guard
      let youtubeURL = Bundle.module.url(
        forResource: "youtube-filters",
        withExtension: "txt"
      )
    else {
      throw StoreError.storageFailed
    }

    var rules = try String(contentsOf: youtubeURL, encoding: .utf8)
    if let officialURL = Bundle.module.url(
      forResource: "official-filters",
      withExtension: "txt"
    ) {
      rules += "\n\n! === [brave-ios-trim] official default set ===\n"
      rules += try String(contentsOf: officialURL, encoding: .utf8)
    }
    return rules
  }

  private let rootDirectoryURL: URL
  private let dependencies: Dependencies
  private let fileManager: FileManager
  private var automaticUpdateTask: Task<Void, Never>?

  init(
    rootDirectoryURL: URL = BuiltInFilterListStorage.defaultRootDirectoryURL,
    dependencies: Dependencies? = nil,
    fileManager: FileManager = .default
  ) {
    self.rootDirectoryURL = rootDirectoryURL
    self.dependencies = dependencies ?? Self.liveDependencies()
    self.fileManager = fileManager
  }

  /// Makes an already-validated active file available to both blocking engines during launch.
  func loadActiveRules() async {
    removeStaleCandidateFiles()
    guard let fileInfo = activeFileInfo() else { return }
    await MainActor.run {
      AdBlockGroupsManager.shared.update(
        fileInfo: AdBlockEngineManager.FileInfo(
          filterListInfo: GroupedAdBlockEngine.FilterListInfo(
            source: .bundledRules,
            version: fileInfo.version
          ),
          localFileURL: fileInfo.url
        )
      )
    }
  }

  /// Starts opportunistic checks at launch and while the browser process remains active.
  /// iOS may suspend the process, so this supplements rather than promises background delivery.
  func startAutomaticUpdates() {
    guard automaticUpdateTask == nil else { return }
    automaticUpdateTask = Task { [weak self] in
      guard let self else { return }
      await self.refreshIfDue()
      while !Task.isCancelled {
        do {
          try await Task.sleep(seconds: Self.automaticCheckInterval)
        } catch {
          return
        }
        await self.refreshIfDue()
      }
    }
  }

  @discardableResult
  func refresh(
    manifestURL: URL = BuiltInFilterListStorage.productionManifestURL,
    force: Bool = false
  ) async throws -> RefreshResult {
    let statusBeforeAttempt = readStatus()
    if !force,
      let lastCheckDate = statusBeforeAttempt.lastCheckDate,
      dependencies.now().timeIntervalSince(lastCheckDate) < Self.refreshInterval
    {
      return RefreshResult(outcome: .deferred, status: statusBeforeAttempt)
    }

    let source = Self.safeSourceDescription(for: manifestURL)
    guard manifestURL.scheme?.lowercased() == "https" else {
      recordFailure(.insecureSource, source: source)
      throw StoreError.insecureSource
    }

    do {
      let manifestResponse = try await dependencies.downloadManifest(
        manifestURL,
        statusBeforeAttempt.manifestETag
      )
      if manifestResponse.statusCode == 304 {
        let status = recordSuccessfulCheck(
          source: source,
          etag: manifestResponse.etag ?? statusBeforeAttempt.manifestETag
        )
        return RefreshResult(outcome: .notModified, status: status)
      }
      guard (200...299).contains(manifestResponse.statusCode) else {
        throw StoreError.httpStatus(manifestResponse.statusCode)
      }
      try Self.requireSecureFinalURL(manifestResponse.finalURL)

      let manifest = try verifiedManifest(from: manifestResponse.data)
      let appComparison = try Self.compareVersions(
        dependencies.currentAppVersion(),
        manifest.minimumAppVersion
      )
      guard appComparison != .orderedAscending else {
        throw StoreError.incompatibleAppVersion
      }

      if let activeVersion = statusBeforeAttempt.activeVersion {
        let comparison = try Self.compareVersions(manifest.ruleVersion, activeVersion)
        if comparison == .orderedAscending {
          throw StoreError.versionRollback
        }
        if comparison == .orderedSame {
          guard statusBeforeAttempt.activeSHA256?.lowercased() == manifest.rules.sha256.lowercased()
          else {
            throw StoreError.versionRollback
          }
          let status = recordSuccessfulCheck(source: source, etag: manifestResponse.etag)
          return RefreshResult(outcome: .upToDate, status: status)
        }
      }

      guard let rulesURL = URL(string: manifest.rules.url),
        rulesURL.scheme?.lowercased() == "https"
      else {
        throw StoreError.insecureSource
      }
      guard manifest.rules.byteCount > 0, manifest.rules.byteCount <= Self.maximumBytes else {
        throw StoreError.invalidManifest
      }

      let rulesResponse = try await dependencies.download(rulesURL)
      guard (200...299).contains(rulesResponse.statusCode) else {
        throw StoreError.httpStatus(rulesResponse.statusCode)
      }
      try Self.requireSecureFinalURL(rulesResponse.finalURL)
      guard rulesResponse.data.count == manifest.rules.byteCount else {
        throw StoreError.sizeMismatch
      }
      guard Self.sha256Hex(of: rulesResponse.data) == manifest.rules.sha256.lowercased() else {
        throw StoreError.hashMismatch
      }

      let installed = try await installCandidate(
        rulesResponse.data,
        version: manifest.ruleVersion,
        source: source,
        mimeType: rulesResponse.mimeType,
        manifestETag: manifestResponse.etag
      )
      return RefreshResult(
        outcome: installed.changed ? .updated : .upToDate,
        status: installed.status
      )
    } catch {
      if !Self.isCandidateError(error) {
        recordFailure(Self.failureReason(for: error), source: source)
      }
      throw error
    }
  }

  private func refreshIfDue() async {
    do {
      _ = try await refresh()
    } catch {
      ContentBlockerManager.log.error(
        "Built-in rule update check failed: \(String(describing: error))"
      )
    }
  }

  #if DEBUG
  /// Downloads an unsigned candidate for local fault-injection tests. This API is excluded from
  /// release builds; production updates use `refresh` and require a signed manifest.
  @discardableResult
  func update(from url: URL, version: String) async throws -> InstallResult {
    guard url.scheme?.lowercased() == "https" else {
      recordFailure(.insecureSource, source: Self.safeSourceDescription(for: url))
      throw StoreError.insecureSource
    }

    let source = Self.safeSourceDescription(for: url)
    do {
      let payload = try await dependencies.download(url)
      guard (200...299).contains(payload.statusCode) else {
        throw StoreError.httpStatus(payload.statusCode)
      }
      return try await installCandidate(
        payload.data,
        version: version,
        source: source,
        mimeType: payload.mimeType,
        manifestETag: nil
      )
    } catch {
      if !Self.isCandidateError(error) {
        recordFailure(Self.failureReason(for: error), source: source)
      }
      throw error
    }
  }
  #endif

  /// Installs rules embedded in this app through the same candidate-validation transaction used
  /// by downloaded updates.
  @discardableResult
  func installBundledCandidate(_ rules: String, version: String) async throws -> InstallResult {
    let currentStatus = readStatus()
    if let activeVersion = currentStatus.activeVersion,
      fileManager.fileExists(atPath: activeFileURL.path)
    {
      let comparison = try Self.compareVersions(version, activeVersion)
      if comparison != .orderedDescending {
        return InstallResult(changed: false, status: currentStatus)
      }
    }

    return try await installCandidate(
      Data(rules.utf8),
      version: version,
      source: "bundled",
      mimeType: "text/plain",
      manifestETag: nil
    )
  }

  func diagnosticStatus() -> DiagnosticStatus {
    readStatus()
  }

  func activeRules() throws -> String? {
    let url = activeFileURL
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try String(contentsOf: url, encoding: .utf8)
  }

  func previousRules() throws -> String? {
    let url = previousFileURL
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try String(contentsOf: url, encoding: .utf8)
  }

  @discardableResult
  private func installCandidate(
    _ data: Data,
    version: String,
    source: String,
    mimeType: String?,
    manifestETag: String?
  ) async throws -> InstallResult {
    var oldActiveData: Data?
    var didPromote = false
    var candidateURL: URL?
    let statusBeforeAttempt = readStatus()

    do {
      let rules = try Self.validatedString(from: data, mimeType: mimeType)
      try createRootDirectoryIfNeeded()
      removeStaleCandidateFiles()

      let url = rootDirectoryURL.appendingPathComponent("candidate-\(UUID().uuidString).txt")
      candidateURL = url
      try atomicWrite(data, to: url)

      try await dependencies.validateAndTrialCompile(rules, url, version)

      let sha256 = Self.sha256Hex(of: data)
      let currentStatus = statusBeforeAttempt
      if currentStatus.activeVersion == version,
        currentStatus.activeSHA256 == sha256,
        fileManager.fileExists(atPath: activeFileURL.path)
      {
        try? fileManager.removeItem(at: url)
        return InstallResult(changed: false, status: currentStatus)
      }

      oldActiveData = try? Data(contentsOf: activeFileURL)
      if let oldActiveData {
        try atomicWrite(oldActiveData, to: previousFileURL)
      }

      // Data.write(.atomic) creates and renames a temporary sibling, so readers see either the
      // complete old file or the complete validated candidate.
      try atomicWrite(data, to: activeFileURL)
      didPromote = true

      let successStatus = DiagnosticStatus(
        activeVersion: version,
        activeSHA256: sha256,
        activeRuleCount: Self.meaningfulRuleCount(in: rules),
        lastSuccessDate: dependencies.now(),
        lastFailureDate: currentStatus.lastFailureDate,
        lastFailureReason: currentStatus.lastFailureReason,
        lastAttemptSource: source,
        lastCheckDate: source == "bundled" ? currentStatus.lastCheckDate : dependencies.now(),
        manifestETag: manifestETag ?? currentStatus.manifestETag
      )
      try writeStatus(successStatus)
      do {
        try await dependencies.activate(activeFileURL, version)
      } catch {
        throw StoreError.activationFailed
      }
      try? fileManager.removeItem(at: url)
      return InstallResult(changed: true, status: successStatus)
    } catch {
      if didPromote {
        do {
          if let oldActiveData {
            try atomicWrite(oldActiveData, to: activeFileURL)
          } else if fileManager.fileExists(atPath: activeFileURL.path) {
            try fileManager.removeItem(at: activeFileURL)
          }
          try writeStatus(statusBeforeAttempt)
        } catch {
          ContentBlockerManager.log.error("Failed to restore the previous built-in rule cache")
        }
      }
      if let candidateURL {
        try? fileManager.removeItem(at: candidateURL)
      }

      let reason = Self.failureReason(for: error)
      recordFailure(reason, source: source)

      if didPromote, let restoredInfo = activeFileInfo() {
        try? await dependencies.activate(restoredInfo.url, restoredInfo.version)
      }
      throw error
    }
  }

  private func removeStaleCandidateFiles() {
    guard
      let files = try? fileManager.contentsOfDirectory(
        at: rootDirectoryURL,
        includingPropertiesForKeys: nil
      )
    else { return }

    for file in files
    where file.lastPathComponent.hasPrefix("candidate-") && file.pathExtension == "txt" {
      try? fileManager.removeItem(at: file)
    }
  }

  private var activeFileURL: URL {
    rootDirectoryURL.appendingPathComponent(Self.activeFileName)
  }

  private var previousFileURL: URL {
    rootDirectoryURL.appendingPathComponent(Self.previousFileName)
  }

  private var metadataFileURL: URL {
    rootDirectoryURL.appendingPathComponent(Self.metadataFileName)
  }

  private func activeFileInfo() -> (url: URL, version: String)? {
    guard fileManager.fileExists(atPath: activeFileURL.path) else { return nil }
    return (activeFileURL, readStatus().activeVersion ?? "recovered")
  }

  private func createRootDirectoryIfNeeded() throws {
    do {
      try fileManager.createDirectory(
        at: rootDirectoryURL,
        withIntermediateDirectories: true
      )
    } catch {
      throw StoreError.storageFailed
    }
  }

  private func atomicWrite(_ data: Data, to url: URL) throws {
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      throw StoreError.storageFailed
    }
  }

  private func readStatus() -> DiagnosticStatus {
    guard let data = try? Data(contentsOf: metadataFileURL) else { return .empty }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode(DiagnosticStatus.self, from: data)) ?? .empty
  }

  private func writeStatus(_ status: DiagnosticStatus) throws {
    do {
      try createRootDirectoryIfNeeded()
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(status).write(to: metadataFileURL, options: .atomic)
    } catch let error as StoreError {
      throw error
    } catch {
      throw StoreError.storageFailed
    }
  }

  private func recordFailure(_ reason: FailureReason, source: String) {
    var status = readStatus()
    status.lastCheckDate = dependencies.now()
    status.lastFailureDate = dependencies.now()
    status.lastFailureReason = reason
    status.lastAttemptSource = source
    try? writeStatus(status)
  }

  @discardableResult
  private func recordSuccessfulCheck(source: String, etag: String?) -> DiagnosticStatus {
    var status = readStatus()
    status.lastCheckDate = dependencies.now()
    status.lastAttemptSource = source
    status.manifestETag = etag ?? status.manifestETag
    try? writeStatus(status)
    return status
  }

  private func verifiedManifest(from data: Data) throws -> ManifestPayload {
    let envelope: SignedManifestEnvelope
    do {
      envelope = try JSONDecoder().decode(SignedManifestEnvelope.self, from: data)
    } catch {
      throw StoreError.invalidManifest
    }
    guard
      let payloadData = Data(base64Encoded: envelope.payload),
      let signatureData = Data(base64Encoded: envelope.signature)
    else {
      throw StoreError.invalidManifest
    }

    let publicKey: Curve25519.Signing.PublicKey
    do {
      publicKey = try Curve25519.Signing.PublicKey(
        rawRepresentation: dependencies.manifestPublicKey
      )
    } catch {
      throw StoreError.invalidManifest
    }
    guard publicKey.isValidSignature(signatureData, for: payloadData) else {
      throw StoreError.invalidSignature
    }

    let manifest: ManifestPayload
    do {
      manifest = try JSONDecoder().decode(ManifestPayload.self, from: payloadData)
    } catch {
      throw StoreError.invalidManifest
    }
    guard manifest.schemaVersion == 1 else { throw StoreError.unsupportedSchema }
    guard manifest.keyID == Self.productionManifestKeyID else {
      throw StoreError.invalidSignature
    }
    guard ISO8601DateFormatter().date(from: manifest.publishedAt) != nil else {
      throw StoreError.invalidManifest
    }
    _ = try Self.versionComponents(manifest.ruleVersion)
    _ = try Self.versionComponents(manifest.minimumAppVersion)
    guard manifest.rules.sha256.count == 64,
      manifest.rules.sha256.allSatisfy({ $0.isHexDigit })
    else {
      throw StoreError.invalidManifest
    }
    return manifest
  }

  private static func validatedString(from data: Data, mimeType: String?) throws -> String {
    guard !data.isEmpty else { throw StoreError.emptyContent }
    guard data.count <= maximumBytes else { throw StoreError.tooLarge }

    if let mimeType = mimeType?.lowercased(),
      mimeType.contains("text/html") || mimeType.contains("application/json")
    {
      throw StoreError.unexpectedDocument
    }

    guard var rules = String(data: data, encoding: .utf8) else {
      throw StoreError.invalidEncoding
    }
    if rules.first == "\u{FEFF}" {
      rules.removeFirst()
    }
    guard !rules.contains("\0") else { throw StoreError.invalidEncoding }

    let lines = rules.components(separatedBy: .newlines)
    guard lines.count <= maximumLines else { throw StoreError.tooManyLines }
    guard meaningfulRuleCount(in: rules) > 0 else { throw StoreError.emptyContent }

    let prefix = rules.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_048).lowercased()
    if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html")
      || (prefix.hasPrefix("<") && (prefix.contains("<body") || prefix.contains("<head")))
      || (prefix.hasPrefix("{") && (prefix.contains("\"error\"") || prefix.contains("\"message\"")))
    {
      throw StoreError.unexpectedDocument
    }
    return rules
  }

  private static func meaningfulRuleCount(in rules: String) -> Int {
    rules.components(separatedBy: .newlines).reduce(into: 0) { count, line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty && !trimmed.hasPrefix("!") && !trimmed.hasPrefix("[") {
        count += 1
      }
    }
  }

  private static func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func safeSourceDescription(for url: URL) -> String {
    guard let host = url.host, !host.isEmpty else { return "remote" }
    return "remote:\(host)"
  }

  private static func requireSecureFinalURL(_ url: URL?) throws {
    if let url, url.scheme?.lowercased() != "https" {
      throw StoreError.insecureSource
    }
  }

  private static func versionComponents(_ value: String) throws -> [Int] {
    let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
    let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.count <= 4 else { throw StoreError.invalidManifest }
    return try parts.map { part in
      guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), value >= 0 else {
        throw StoreError.invalidManifest
      }
      return value
    }
  }

  private static func compareVersions(_ lhs: String, _ rhs: String) throws -> ComparisonResult {
    let left = try versionComponents(lhs)
    let right = try versionComponents(rhs)
    for index in 0..<max(left.count, right.count) {
      let leftValue = index < left.count ? left[index] : 0
      let rightValue = index < right.count ? right[index] : 0
      if leftValue < rightValue { return .orderedAscending }
      if leftValue > rightValue { return .orderedDescending }
    }
    return .orderedSame
  }

  private static func isCandidateError(_ error: Error) -> Bool {
    guard let error = error as? StoreError else { return false }
    switch error {
    case .emptyContent, .invalidEncoding, .unexpectedDocument, .tooLarge, .tooManyLines,
      .invalidRule, .trialCompilationFailed, .storageFailed, .activationFailed:
      return true
    case .insecureSource, .httpStatus, .noHTTPResponse, .invalidManifest, .invalidSignature,
      .unsupportedSchema, .incompatibleAppVersion, .versionRollback, .hashMismatch, .sizeMismatch:
      return false
    }
  }

  private static func failureReason(for error: Error) -> FailureReason {
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut: return .timedOut
      case .notConnectedToInternet, .networkConnectionLost: return .offline
      default: return .downloadFailed
      }
    }
    guard let error = error as? StoreError else { return .downloadFailed }
    switch error {
    case .insecureSource: return .insecureSource
    case .httpStatus(403): return .http403
    case .httpStatus(404): return .http404
    case .httpStatus: return .httpError
    case .noHTTPResponse: return .downloadFailed
    case .invalidManifest: return .invalidManifest
    case .invalidSignature: return .invalidSignature
    case .unsupportedSchema: return .unsupportedSchema
    case .incompatibleAppVersion: return .incompatibleAppVersion
    case .versionRollback: return .versionRollback
    case .hashMismatch: return .hashMismatch
    case .sizeMismatch: return .sizeMismatch
    case .emptyContent: return .emptyContent
    case .invalidEncoding: return .invalidEncoding
    case .unexpectedDocument: return .unexpectedDocument
    case .tooLarge: return .tooLarge
    case .tooManyLines: return .tooManyLines
    case .invalidRule: return .invalidRule
    case .trialCompilationFailed: return .trialCompilationFailed
    case .storageFailed: return .storageFailed
    case .activationFailed: return .activationFailed
    }
  }

  private static func liveDependencies() -> Dependencies {
    Dependencies(
      download: { url in
        try await liveDownload(url: url, etag: nil)
      },
      validateAndTrialCompile: validateAndTrialCompileCandidate,
      activate: { fileURL, version in
        let fileInfo = await MainActor.run {
          AdBlockEngineManager.FileInfo(
            filterListInfo: GroupedAdBlockEngine.FilterListInfo(
              source: .bundledRules,
              version: version
            ),
            localFileURL: fileURL
          )
        }
        await AdBlockGroupsManager.shared.updateImmediately(fileInfo: fileInfo)
      },
      now: Date.init,
      downloadManifest: { url, etag in
        try await liveDownload(url: url, etag: etag)
      },
      currentAppVersion: {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
          ?? "0"
      }
    )
  }

  private static func liveDownload(url: URL, etag: String?) async throws -> DownloadPayload {
    var request = URLRequest(url: url)
    request.setValue("application/json, text/plain;q=0.9", forHTTPHeaderField: "Accept")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if let etag {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw StoreError.noHTTPResponse
    }
    guard response.url?.scheme?.lowercased() == "https" else {
      throw StoreError.insecureSource
    }
    return DownloadPayload(
      data: data,
      statusCode: response.statusCode,
      mimeType: response.mimeType,
      etag: response.value(forHTTPHeaderField: "ETag"),
      finalURL: response.url
    )
  }

  static func validateAndTrialCompileCandidate(
    rules: String,
    candidateURL: URL,
    version: String
  ) async throws {
    if let failure = await AdBlockGroupsManager.shared.contentBlockerManager.testRules(
      forFilterSet: rules
    ) {
      throw StoreError.invalidRule(line: failure.line)
    }

    let group = GroupedAdBlockEngine.FilterListGroup(
      infos: [
        GroupedAdBlockEngine.FilterListInfo(source: .bundledRules, version: version)
      ],
      localFileURL: candidateURL
    )
    do {
      try await Task.detached(priority: .userInitiated) {
        _ = try GroupedAdBlockEngine.compile(group: group, type: .standard)
        _ = try GroupedAdBlockEngine.compile(group: group, type: .aggressive)
      }.value
    } catch {
      throw StoreError.trialCompilationFailed
    }
  }
}
