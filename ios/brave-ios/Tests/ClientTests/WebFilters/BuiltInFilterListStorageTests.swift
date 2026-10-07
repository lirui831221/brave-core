// Copyright 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation
import XCTest

@testable import Brave

final class BuiltInFilterListStorageTests: XCTestCase {
  private enum DownloadBehavior: Sendable {
    case response(Data, Int, String?)
    case urlError(URLError.Code)
  }

  private enum ValidationBehavior: Sendable {
    case accept
    case rejectInvalidRule
    case rejectTrialCompile
  }

  private actor ActivationRecorder {
    private(set) var versions: [String] = []
    let failingVersion: String?

    init(failingVersion: String? = nil) {
      self.failingVersion = failingVersion
    }

    func activate(version: String) throws {
      versions.append(version)
      if version == failingVersion {
        throw BuiltInFilterListStorage.StoreError.activationFailed
      }
    }
  }

  private actor SignedNetworkFixture {
    var manifestResponses: [BuiltInFilterListStorage.DownloadPayload]
    let rulesResponse: BuiltInFilterListStorage.DownloadPayload
    private(set) var receivedETags: [String?] = []
    private(set) var ruleDownloadCount = 0

    init(
      manifestResponses: [BuiltInFilterListStorage.DownloadPayload],
      rulesResponse: BuiltInFilterListStorage.DownloadPayload
    ) {
      self.manifestResponses = manifestResponses
      self.rulesResponse = rulesResponse
    }

    func downloadManifest(etag: String?) throws -> BuiltInFilterListStorage.DownloadPayload {
      receivedETags.append(etag)
      guard !manifestResponses.isEmpty else { throw URLError(.resourceUnavailable) }
      return manifestResponses.removeFirst()
    }

    func downloadRules() -> BuiltInFilterListStorage.DownloadPayload {
      ruleDownloadCount += 1
      return rulesResponse
    }
  }

  private var temporaryDirectory: URL!
  private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BuiltInFilterListStorageTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: temporaryDirectory)
  }

  func testSuccessfulUpgradeSeparatesUserRulesAndRetainsPreviousCache() async throws {
    let root = temporaryDirectory.appendingPathComponent("built-in")
    let userRulesURL = temporaryDirectory.appendingPathComponent("custom_rules/list.txt")
    try FileManager.default.createDirectory(
      at: userRulesURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let userRules = "example.com##.my-personal-rule"
    try userRules.write(to: userRulesURL, atomically: true, encoding: .utf8)

    let newRules = "||new.example^\nnew.example##.sponsor"
    let recorder = ActivationRecorder()
    let store = makeStore(
      root: root,
      download: .response(Data(newRules.utf8), 200, "text/plain"),
      activationRecorder: recorder
    )

    _ = try await store.installBundledCandidate("||old.example^", version: "11")
    let result = try await store.update(
      from: XCTUnwrap(URL(string: "https://updates.example/rules.txt")),
      version: "12"
    )

    let activeRules = try await store.activeRules()
    let previousRules = try await store.previousRules()
    let activatedVersions = await recorder.versions
    XCTAssertTrue(result.changed)
    XCTAssertEqual(activeRules, newRules)
    XCTAssertEqual(previousRules, "||old.example^")
    XCTAssertEqual(
      try String(contentsOf: userRulesURL, encoding: .utf8),
      userRules,
      "A managed-rule update must never overwrite user-authored rules"
    )
    XCTAssertEqual(result.status.activeVersion, "12")
    XCTAssertEqual(result.status.activeRuleCount, 2)
    XCTAssertEqual(result.status.lastSuccessDate, fixedDate)
    XCTAssertNil(result.status.lastFailureReason)
    XCTAssertEqual(activatedVersions, ["11", "12"])
    try assertNoCandidateFiles(in: root)
  }

  func testBundledV12SnapshotPassesRealValidationAndTrialCompilation() async throws {
    let root = temporaryDirectory.appendingPathComponent("real-validation")
    let rules = try BuiltInFilterListStorage.bundledSnapshot()
    let fixedDate = fixedDate
    let store = BuiltInFilterListStorage(
      rootDirectoryURL: root,
      dependencies: .init(
        download: { _ in
          throw URLError(.unsupportedURL)
        },
        validateAndTrialCompile: { rules, candidateURL, version in
          try await BuiltInFilterListStorage.validateAndTrialCompileCandidate(
            rules: rules,
            candidateURL: candidateURL,
            version: version
          )
        },
        activate: { _, _ in },
        now: { fixedDate }
      )
    )

    let result = try await store.installBundledCandidate(rules, version: "12")

    XCTAssertTrue(result.changed)
    XCTAssertGreaterThan(result.status.activeRuleCount, 60_000)
    XCTAssertEqual(result.status.activeVersion, "12")
    XCTAssertEqual(result.status.lastSuccessDate, fixedDate)
    XCTAssertNil(result.status.lastFailureReason)
  }

  func testBundledCandidateDoesNotReplaceNewerDownloadedRules() async throws {
    let root = temporaryDirectory.appendingPathComponent("bundled-rollback")
    let downloadedRules = "||new.example^\nnew.example##.sponsor"
    let recorder = ActivationRecorder()
    let store = makeStore(
      root: root,
      download: .response(Data(downloadedRules.utf8), 200, "text/plain"),
      activationRecorder: recorder
    )

    _ = try await store.installBundledCandidate("||bundled.example^", version: "12")
    _ = try await store.update(
      from: XCTUnwrap(URL(string: "https://updates.example/rules.txt")),
      version: "12.1"
    )
    let result = try await store.installBundledCandidate(
      "||bundled.example^",
      version: "12"
    )

    let activeRules = try await store.activeRules()
    let previousRules = try await store.previousRules()
    let activatedVersions = await recorder.versions
    XCTAssertFalse(result.changed)
    XCTAssertEqual(activeRules, downloadedRules)
    XCTAssertEqual(previousRules, "||bundled.example^")
    XCTAssertEqual(result.status.activeVersion, "12.1")
    XCTAssertEqual(activatedVersions, ["12", "12.1"])
  }

  func testLaunchRemovesInterruptedCandidateWithoutTouchingActiveRules() async throws {
    let root = temporaryDirectory.appendingPathComponent("interrupted-candidate")
    let store = makeStore(
      root: root,
      download: .response(Data(), 500, "text/plain")
    )
    _ = try await store.installBundledCandidate("||active.example^", version: "12")
    let interruptedCandidate = root.appendingPathComponent("candidate-interrupted.txt")
    try "||incomplete.example^".write(
      to: interruptedCandidate,
      atomically: true,
      encoding: .utf8
    )

    await store.loadActiveRules()

    XCTAssertFalse(FileManager.default.fileExists(atPath: interruptedCandidate.path))
    let activeRules = try await store.activeRules()
    XCTAssertEqual(activeRules, "||active.example^")
  }

  func testHTTPFailuresKeepLastKnownGoodRules() async throws {
    try await assertFailedUpdate(
      download: .response(Data("denied".utf8), 403, "text/plain"),
      expectedReason: .http403
    )
    try await assertFailedUpdate(
      download: .response(Data("missing".utf8), 404, "text/plain"),
      expectedReason: .http404
    )
    try await assertFailedUpdate(
      download: .response(Data("server error".utf8), 500, "text/plain"),
      expectedReason: .httpError
    )
  }

  func testNetworkFailuresKeepLastKnownGoodRules() async throws {
    try await assertFailedUpdate(
      download: .urlError(.timedOut),
      expectedReason: .timedOut
    )
    try await assertFailedUpdate(
      download: .urlError(.notConnectedToInternet),
      expectedReason: .offline
    )
  }

  func testMalformedResponsesKeepLastKnownGoodRules() async throws {
    try await assertFailedUpdate(
      download: .response(Data(), 200, "text/plain"),
      expectedReason: .emptyContent
    )
    try await assertFailedUpdate(
      download: .response(
        Data("<!doctype html><html><body>Access denied</body></html>".utf8),
        200,
        "text/html"
      ),
      expectedReason: .unexpectedDocument
    )
    try await assertFailedUpdate(
      download: .response(
        Data(#"{"error":"access denied"}"#.utf8),
        200,
        "application/octet-stream"
      ),
      expectedReason: .unexpectedDocument
    )
    try await assertFailedUpdate(
      download: .response(Data([0xFF, 0xFE, 0xFD]), 200, "text/plain"),
      expectedReason: .invalidEncoding
    )
    try await assertFailedUpdate(
      download: .response(Data("||valid.example^\0hidden".utf8), 200, "text/plain"),
      expectedReason: .invalidEncoding
    )
    try await assertFailedUpdate(
      download: .response(
        Data(repeating: 0x61, count: BuiltInFilterListStorage.maximumBytes + 1),
        200,
        "text/plain"
      ),
      expectedReason: .tooLarge
    )
    let tooManyLines = Array(
      repeating: "||line.example^",
      count: BuiltInFilterListStorage.maximumLines + 1
    ).joined(separator: "\n")
    try await assertFailedUpdate(
      download: .response(Data(tooManyLines.utf8), 200, "text/plain"),
      expectedReason: .tooManyLines
    )
  }

  func testRuleValidationAndTrialCompileFailuresKeepLastKnownGoodRules() async throws {
    try await assertFailedUpdate(
      download: .response(Data("||bad.example^".utf8), 200, "text/plain"),
      validation: .rejectInvalidRule,
      expectedReason: .invalidRule
    )
    try await assertFailedUpdate(
      download: .response(Data("||bad.example^".utf8), 200, "text/plain"),
      validation: .rejectTrialCompile,
      expectedReason: .trialCompilationFailed
    )
  }

  func testActivationFailureRollsBackPromotedRulesAndStatus() async throws {
    let root = temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let recorder = ActivationRecorder(failingVersion: "12")
    let store = makeStore(
      root: root,
      download: .response(Data("||new.example^".utf8), 200, "text/plain"),
      activationRecorder: recorder
    )
    _ = try await store.installBundledCandidate("||old.example^", version: "11")

    do {
      _ = try await store.update(
        from: XCTUnwrap(URL(string: "https://updates.example/rules.txt")),
        version: "12"
      )
      XCTFail("Activation should have failed")
    } catch {}

    let activeRules = try await store.activeRules()
    let previousRules = try await store.previousRules()
    let status = await store.diagnosticStatus()
    let activatedVersions = await recorder.versions
    XCTAssertEqual(activeRules, "||old.example^")
    XCTAssertEqual(previousRules, "||old.example^")
    XCTAssertEqual(status.activeVersion, "11")
    XCTAssertEqual(status.lastFailureReason, .activationFailed)
    XCTAssertEqual(status.lastFailureDate, fixedDate)
    XCTAssertEqual(activatedVersions, ["11", "12", "11"])
    try assertNoCandidateFiles(in: root)
  }

  func testRejectsNonHTTPSUpdateWithoutCallingDownloader() async throws {
    let root = temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = makeStore(
      root: root,
      download: .response(Data("||new.example^".utf8), 200, "text/plain")
    )
    _ = try await store.installBundledCandidate("||old.example^", version: "11")

    do {
      _ = try await store.update(
        from: XCTUnwrap(URL(string: "http://updates.example/rules.txt")),
        version: "12"
      )
      XCTFail("An insecure update source should be rejected")
    } catch {}

    let activeRules = try await store.activeRules()
    let status = await store.diagnosticStatus()
    XCTAssertEqual(activeRules, "||old.example^")
    XCTAssertEqual(status.lastFailureReason, .insecureSource)
  }

  func testSignedManifestUpgradeStoresETagAndKeepsUserRulesSeparate() async throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let newRules = Data("||signed.example^\nsigned.example##.promotion".utf8)
    let manifest = try makeSignedManifest(
      privateKey: privateKey,
      rules: newRules,
      version: "12.1"
    )
    let fixture = makeSignedFixture(manifest: manifest, rules: newRules, etag: #""rules-12.1""#)
    let root = temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = makeSignedStore(root: root, fixture: fixture, privateKey: privateKey)
    _ = try await store.installBundledCandidate("||old.example^", version: "12")

    let result = try await store.refresh(
      manifestURL: XCTUnwrap(URL(string: "https://updates.example/manifest.json")),
      force: true
    )

    XCTAssertEqual(result.outcome, .updated)
    XCTAssertEqual(result.status.activeVersion, "12.1")
    XCTAssertEqual(result.status.manifestETag, #""rules-12.1""#)
    XCTAssertEqual(result.status.lastCheckDate, fixedDate)
    let activeRules = try await store.activeRules()
    let previousRules = try await store.previousRules()
    let ruleDownloadCount = await fixture.ruleDownloadCount
    XCTAssertEqual(activeRules, String(decoding: newRules, as: UTF8.self))
    XCTAssertEqual(previousRules, "||old.example^")
    XCTAssertEqual(ruleDownloadCount, 1)
    try assertNoCandidateFiles(in: root)
  }

  func testInvalidSignatureNeverDownloadsOrReplacesRules() async throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let rules = Data("||signed.example^".utf8)
    var envelope = try JSONDecoder().decode(
      BuiltInFilterListStorage.SignedManifestEnvelope.self,
      from: makeSignedManifest(privateKey: privateKey, rules: rules, version: "12.1")
    )
    envelope = .init(
      payload: envelope.payload,
      signature: Data(repeating: 0, count: 64).base64EncodedString()
    )
    let manifest = try JSONEncoder().encode(envelope)
    let fixture = makeSignedFixture(manifest: manifest, rules: rules)
    let store = makeSignedStore(
      root: temporaryDirectory.appendingPathComponent(UUID().uuidString),
      fixture: fixture,
      privateKey: privateKey
    )
    _ = try await store.installBundledCandidate("||old.example^", version: "12")

    await assertRefreshFailure(store: store, expectedReason: .invalidSignature)
    let ruleDownloadCount = await fixture.ruleDownloadCount
    XCTAssertEqual(ruleDownloadCount, 0)
  }

  func testSignedHashAndSizeMismatchKeepLastKnownGoodRules() async throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let rules = Data("||signed.example^".utf8)
    let badHashManifest = try makeSignedManifest(
      privateKey: privateKey,
      rules: rules,
      version: "12.1",
      declaredSHA256: String(repeating: "0", count: 64)
    )
    let badHashStore = makeSignedStore(
      root: temporaryDirectory.appendingPathComponent(UUID().uuidString),
      fixture: makeSignedFixture(manifest: badHashManifest, rules: rules),
      privateKey: privateKey
    )
    _ = try await badHashStore.installBundledCandidate("||old.example^", version: "12")
    await assertRefreshFailure(store: badHashStore, expectedReason: .hashMismatch)

    let badSizeManifest = try makeSignedManifest(
      privateKey: privateKey,
      rules: rules,
      version: "12.1",
      declaredByteCount: rules.count + 1
    )
    let badSizeStore = makeSignedStore(
      root: temporaryDirectory.appendingPathComponent(UUID().uuidString),
      fixture: makeSignedFixture(manifest: badSizeManifest, rules: rules),
      privateKey: privateKey
    )
    _ = try await badSizeStore.installBundledCandidate("||old.example^", version: "12")
    await assertRefreshFailure(store: badSizeStore, expectedReason: .sizeMismatch)
  }

  func testDowngradeReusedVersionAndIncompatibleAppAreRejectedBeforeRuleDownload() async throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let rules = Data("||signed.example^".utf8)

    for (version, minimumAppVersion, expectedReason) in [
      ("11.9", "1.98.0", BuiltInFilterListStorage.FailureReason.versionRollback),
      ("12", "1.98.0", .versionRollback),
      ("12.1", "99.0.0", .incompatibleAppVersion),
    ] {
      let manifest = try makeSignedManifest(
        privateKey: privateKey,
        rules: rules,
        version: version,
        minimumAppVersion: minimumAppVersion
      )
      let fixture = makeSignedFixture(manifest: manifest, rules: rules)
      let store = makeSignedStore(
        root: temporaryDirectory.appendingPathComponent(UUID().uuidString),
        fixture: fixture,
        privateKey: privateKey
      )
      _ = try await store.installBundledCandidate("||old.example^", version: "12")

      await assertRefreshFailure(store: store, expectedReason: expectedReason)
      let ruleDownloadCount = await fixture.ruleDownloadCount
      XCTAssertEqual(ruleDownloadCount, 0)
    }
  }

  func testRefreshIntervalAndETagNotModifiedAvoidRuleRedownload() async throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let rules = Data("||signed.example^".utf8)
    let manifest = try makeSignedManifest(
      privateKey: privateKey,
      rules: rules,
      version: "12.1"
    )
    let manifestURL = try XCTUnwrap(URL(string: "https://updates.example/manifest.json"))
    let rulesURL = try XCTUnwrap(URL(string: "https://updates.example/rules.txt"))
    let fixture = SignedNetworkFixture(
      manifestResponses: [
        .init(
          data: manifest,
          statusCode: 200,
          mimeType: "application/json",
          etag: #""rules-12.1""#,
          finalURL: manifestURL
        ),
        .init(
          data: Data(),
          statusCode: 304,
          mimeType: nil,
          etag: #""rules-12.1""#,
          finalURL: manifestURL
        ),
      ],
      rulesResponse: .init(
        data: rules,
        statusCode: 200,
        mimeType: "text/plain",
        finalURL: rulesURL
      )
    )
    let store = makeSignedStore(
      root: temporaryDirectory.appendingPathComponent(UUID().uuidString),
      fixture: fixture,
      privateKey: privateKey
    )
    _ = try await store.installBundledCandidate("||old.example^", version: "12")

    let firstOutcome = try await store.refresh(manifestURL: manifestURL, force: true).outcome
    let deferredOutcome = try await store.refresh(manifestURL: manifestURL).outcome
    let notModifiedOutcome = try await store.refresh(manifestURL: manifestURL, force: true).outcome
    let receivedETags = await fixture.receivedETags
    let ruleDownloadCount = await fixture.ruleDownloadCount
    XCTAssertEqual(firstOutcome, .updated)
    XCTAssertEqual(deferredOutcome, .deferred)
    XCTAssertEqual(notModifiedOutcome, .notModified)
    XCTAssertEqual(receivedETags, [nil, #""rules-12.1""#])
    XCTAssertEqual(ruleDownloadCount, 1)
  }

  func testLiveSignedReleaseUpgradeWhenEnabled() async throws {
    guard ProcessInfo.processInfo.environment["BRAVE_TEST_LIVE_RULE_RELEASES"] == "1" else {
      throw XCTSkip("Set BRAVE_TEST_LIVE_RULE_RELEASES=1 to exercise public GitHub releases")
    }
    let root = temporaryDirectory.appendingPathComponent("live-release-upgrade")
    let store = BuiltInFilterListStorage(
      rootDirectoryURL: root,
      dependencies: .init(
        download: { url in
          try await Self.liveDownload(url: url, etag: nil)
        },
        validateAndTrialCompile: { rules, candidateURL, version in
          try await BuiltInFilterListStorage.validateAndTrialCompileCandidate(
            rules: rules,
            candidateURL: candidateURL,
            version: version
          )
        },
        activate: { _, _ in },
        now: Date.init,
        downloadManifest: { url, etag in
          try await Self.liveDownload(url: url, etag: etag)
        },
        currentAppVersion: { "1.98.0" },
        manifestPublicKey: BuiltInFilterListStorage.productionManifestPublicKey
      )
    )
    _ = try await store.installBundledCandidate("||old.example^", version: "12")
    let manifest12_1 = try XCTUnwrap(
      URL(
        string:
          "https://github.com/lirui831221/brave-ios-rules/releases/download/ios-rules-v12.1/manifest.json"
      )
    )
    let manifest12_2 = try XCTUnwrap(
      URL(
        string:
          "https://github.com/lirui831221/brave-ios-rules/releases/download/ios-rules-v12.2/manifest.json"
      )
    )

    let first = try await store.refresh(manifestURL: manifest12_1, force: true)
    let second = try await store.refresh(manifestURL: manifest12_2, force: true)
    let previousRulesValue = try await store.previousRules()
    let previousRules = try XCTUnwrap(previousRulesValue)
    XCTAssertEqual(first.status.activeVersion, "12.1")
    XCTAssertEqual(second.status.activeVersion, "12.2")
    XCTAssertTrue(previousRules.contains("release 12.1"))

    do {
      _ = try await store.refresh(manifestURL: manifest12_1, force: true)
      XCTFail("A public-release downgrade should fail")
    } catch {}
    let status = await store.diagnosticStatus()
    XCTAssertEqual(status.activeVersion, "12.2")
    XCTAssertEqual(status.lastFailureReason, .versionRollback)
  }

  private func makeSignedManifest(
    privateKey: Curve25519.Signing.PrivateKey,
    rules: Data,
    version: String,
    minimumAppVersion: String = "1.98.0",
    declaredSHA256: String? = nil,
    declaredByteCount: Int? = nil
  ) throws -> Data {
    let payload = BuiltInFilterListStorage.ManifestPayload(
      schemaVersion: 1,
      ruleVersion: version,
      minimumAppVersion: minimumAppVersion,
      publishedAt: "2027-01-15T08:00:00Z",
      keyID: BuiltInFilterListStorage.productionManifestKeyID,
      rules: .init(
        url:
          "https://github.com/lirui831221/brave-ios-rules/releases/download/ios-rules-v\(version)/rules.txt",
        sha256: declaredSHA256 ?? sha256Hex(rules),
        byteCount: declaredByteCount ?? rules.count
      )
    )
    let payloadEncoder = JSONEncoder()
    payloadEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payloadData = try payloadEncoder.encode(payload)
    let envelope = BuiltInFilterListStorage.SignedManifestEnvelope(
      payload: payloadData.base64EncodedString(),
      signature: try privateKey.signature(for: payloadData).base64EncodedString()
    )
    return try JSONEncoder().encode(envelope)
  }

  private func makeSignedFixture(
    manifest: Data,
    rules: Data,
    etag: String? = nil
  ) -> SignedNetworkFixture {
    SignedNetworkFixture(
      manifestResponses: [
        .init(
          data: manifest,
          statusCode: 200,
          mimeType: "application/json",
          etag: etag,
          finalURL: URL(string: "https://updates.example/manifest.json")
        )
      ],
      rulesResponse: .init(
        data: rules,
        statusCode: 200,
        mimeType: "text/plain",
        finalURL: URL(string: "https://updates.example/rules.txt")
      )
    )
  }

  private func makeSignedStore(
    root: URL,
    fixture: SignedNetworkFixture,
    privateKey: Curve25519.Signing.PrivateKey
  ) -> BuiltInFilterListStorage {
    let fixedDate = fixedDate
    return BuiltInFilterListStorage(
      rootDirectoryURL: root,
      dependencies: .init(
        download: { _ in
          await fixture.downloadRules()
        },
        validateAndTrialCompile: { _, _, _ in },
        activate: { _, _ in },
        now: { fixedDate },
        downloadManifest: { _, etag in
          try await fixture.downloadManifest(etag: etag)
        },
        currentAppVersion: { "1.98.0" },
        manifestPublicKey: privateKey.publicKey.rawRepresentation
      )
    )
  }

  private func assertRefreshFailure(
    store: BuiltInFilterListStorage,
    expectedReason: BuiltInFilterListStorage.FailureReason
  ) async {
    do {
      _ = try await store.refresh(
        manifestURL: URL(string: "https://updates.example/manifest.json")!,
        force: true
      )
      XCTFail("The signed update should have failed")
    } catch {}

    let activeRules = try? await store.activeRules()
    let status = await store.diagnosticStatus()
    XCTAssertEqual(activeRules, "||old.example^")
    XCTAssertEqual(status.activeVersion, "12")
    XCTAssertEqual(status.lastFailureReason, expectedReason)
    XCTAssertEqual(status.lastFailureDate, fixedDate)
  }

  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func liveDownload(
    url: URL,
    etag: String?
  ) async throws -> BuiltInFilterListStorage.DownloadPayload {
    var request = URLRequest(url: url)
    if let etag {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
    return .init(
      data: data,
      statusCode: httpResponse.statusCode,
      mimeType: httpResponse.mimeType,
      etag: httpResponse.value(forHTTPHeaderField: "ETag"),
      finalURL: httpResponse.url
    )
  }

  private func assertFailedUpdate(
    download: DownloadBehavior,
    validation: ValidationBehavior = .accept,
    expectedReason: BuiltInFilterListStorage.FailureReason
  ) async throws {
    let root = temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = makeStore(root: root, download: download, validation: validation)
    _ = try await store.installBundledCandidate("||old.example^", version: "11")

    do {
      _ = try await store.update(
        from: XCTUnwrap(URL(string: "https://updates.example/rules.txt")),
        version: "12"
      )
      XCTFail("The candidate should have failed")
    } catch {}

    let activeRules = try await store.activeRules()
    let status = await store.diagnosticStatus()
    XCTAssertEqual(activeRules, "||old.example^")
    XCTAssertEqual(status.activeVersion, "11")
    XCTAssertEqual(status.lastFailureReason, expectedReason)
    XCTAssertEqual(status.lastFailureDate, fixedDate)
    try assertNoCandidateFiles(in: root)
  }

  private func makeStore(
    root: URL,
    download: DownloadBehavior,
    validation: ValidationBehavior = .accept,
    activationRecorder: ActivationRecorder = ActivationRecorder()
  ) -> BuiltInFilterListStorage {
    let fixedDate = fixedDate
    return BuiltInFilterListStorage(
      rootDirectoryURL: root,
      dependencies: .init(
        download: { _ in
          switch download {
          case .response(let data, let statusCode, let mimeType):
            return .init(data: data, statusCode: statusCode, mimeType: mimeType)
          case .urlError(let code):
            throw URLError(code)
          }
        },
        validateAndTrialCompile: { _, _, version in
          guard version == "12" else { return }
          switch validation {
          case .accept:
            return
          case .rejectInvalidRule:
            throw BuiltInFilterListStorage.StoreError.invalidRule(line: 1)
          case .rejectTrialCompile:
            throw BuiltInFilterListStorage.StoreError.trialCompilationFailed
          }
        },
        activate: { _, version in
          try await activationRecorder.activate(version: version)
        },
        now: { fixedDate }
      )
    )
  }

  private func assertNoCandidateFiles(in root: URL) throws {
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertFalse(files.contains(where: { $0.hasPrefix("candidate-") }))
  }
}
