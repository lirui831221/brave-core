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

    static let empty = DiagnosticStatus(
      activeVersion: nil,
      activeSHA256: nil,
      activeRuleCount: 0,
      lastSuccessDate: nil,
      lastFailureDate: nil,
      lastFailureReason: nil,
      lastAttemptSource: nil
    )
  }

  struct DownloadPayload: Sendable {
    let data: Data
    let statusCode: Int
    let mimeType: String?
  }

  struct InstallResult: Equatable, Sendable {
    let changed: Bool
    let status: DiagnosticStatus
  }

  enum StoreError: Error, Equatable {
    case insecureSource
    case httpStatus(Int)
    case noHTTPResponse
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
    var validateAndTrialCompile: @Sendable (String, URL, String) async throws -> Void
    var activate: @Sendable (URL, String) async throws -> Void
    var now: @Sendable () -> Date
  }

  static let shared = BuiltInFilterListStorage()
  static let maximumBytes = 16 * 1_024 * 1_024
  static let maximumLines = 100_000

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

  /// Downloads a candidate from a secure endpoint and installs it only after all checks pass.
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
        mimeType: payload.mimeType
      )
    } catch {
      if !Self.isCandidateError(error) {
        recordFailure(Self.failureReason(for: error), source: source)
      }
      throw error
    }
  }

  /// Installs rules embedded in this app through the same candidate-validation transaction used
  /// by downloaded updates.
  @discardableResult
  func installBundledCandidate(_ rules: String, version: String) async throws -> InstallResult {
    try await installCandidate(
      Data(rules.utf8),
      version: version,
      source: "bundled",
      mimeType: "text/plain"
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
    mimeType: String?
  ) async throws -> InstallResult {
    var oldActiveData: Data?
    var didPromote = false
    var candidateURL: URL?
    let statusBeforeAttempt = readStatus()

    do {
      let rules = try Self.validatedString(from: data, mimeType: mimeType)
      try createRootDirectoryIfNeeded()

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
        lastAttemptSource: source
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
    status.lastFailureDate = dependencies.now()
    status.lastFailureReason = reason
    status.lastAttemptSource = source
    try? writeStatus(status)
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

  private static func isCandidateError(_ error: Error) -> Bool {
    guard let error = error as? StoreError else { return false }
    switch error {
    case .emptyContent, .invalidEncoding, .unexpectedDocument, .tooLarge, .tooManyLines,
      .invalidRule, .trialCompilationFailed, .storageFailed, .activationFailed:
      return true
    case .insecureSource, .httpStatus, .noHTTPResponse:
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
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse else {
          throw StoreError.noHTTPResponse
        }
        guard response.url?.scheme?.lowercased() == "https" else {
          throw StoreError.insecureSource
        }
        return DownloadPayload(
          data: data,
          statusCode: response.statusCode,
          mimeType: response.mimeType
        )
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
      now: Date.init
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
