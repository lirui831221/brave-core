// Copyright 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
