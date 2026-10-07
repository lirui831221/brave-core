// Copyright 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BraveCore
import BraveShields
import Foundation
import Preferences
import os

/// This class helps to prepare the browser during launch by ensuring the state of managers, resources and downloaders before performing additional tasks.
public actor LaunchHelper {
  public static let shared = LaunchHelper()
  static let signpost = OSSignposter(logger: ContentBlockerManager.log)
  private var loadTask: Task<(), Never>?
  private var areAdBlockServicesReady = false

  // [brave-ios-trim] Bundled YouTube ad-blocking rules, ported from
  // mac-brave-1.0.4 (`brave_local_adblock/youtube-filters.txt`).
  // Injection follows the same conservative principles as the macOS build:
  //  - never overwrite a user's own custom rules (injection is skipped if the
  //    user has saved any custom rules of their own)
  //  - idempotent: a matching version is never re-injected
  //  - version bump triggers recompile through the standard pipeline
  private enum BundledYouTubeRules {
    // v1: Mac 1.0.4 base snapshot (www.youtube.com only).
    // v2: P0 — mobile domain adaptation, anti-anti-adblock, network-layer blocks.
    // v3: P1 — in-page shell ads, Shorts/promo shelves, Premium upsell popups.
    // v4: P0+ — SSAP mobile hardening: uBO-2026 attestation countermeasures
    //      mirrored to m.youtube.com (5G/cellular server-side ad injection).
    // v5: pre-roll fix — MWEB/WEB_EMBEDDED client names for the attestation
    //      bypass + full player-response prune on fetch/xhr for m. player.
    // v6: pre-roll final layer — rewrite innerTube clientName to WEB on all
    //      mobile variants (MWEB/IOS/WEB_REMIX) + force empty adSlots/
    //      adPlacements at every object level. iOS WebKit UA is targeted.
    // v7: HTTP-level UA switch — BVC+UserAgent now returns a Windows-Chrome
    //      desktop UA for all youtube.com/googlevideo/youtubei requests.
    //      Rule layers cannot touch HTTP headers; this can.
    // v8: revert v7 — UA spoofing contradicts the iOS TLS fingerprint and
    //      trips bot detection (guaranteed 5s pre-roll punishment).
    // v9: ad-segment network blocks — pagead video hosts, doubleclick,
    //      ad-format watchtime pings on top of the identity-clean state.
    // v10: official Brave "default list" merged in. The stock App Store
    //      build ships these rules via an authenticated S3 download we
    //      cannot replicate; we bundle the same sources instead (uBO
    //      filters 2020-2026 + quick-fixes + EasyList + brave-lists).
    //      Injection = our YouTube rules (top, highest priority)
    //      followed by the full official set.
    // v11: slim the official set to network-block rules only (~64k lines).
    //      The full 137k-line set failed to save — the WebKit content
    //      blocker conversion caps out — and cosmetic rules are already
    //      covered by the C++ engine's separate pipeline.
    //      ALSO: CustomFilterListStorage.maxNumberOfCustomRulesLines was
    //      10k and silently rejected every injection over it. Raised to
    //      80k so the 64k-line official set actually saves.
    static let version = 11

    static func injectIfAllowed() async {
      do {
        // [brave-ios-trim] Fix: distinguish OUR previous injection from a
        // user's own rules. Our injections are recorded by the version pref;
        // only treat the saved rules as user-owned when the pref says we have
        // never injected (version 0) yet rules exist.
        let injectedVersion = Preferences.Option<Int>(
          key: "brave-ios-trim.youtube-rules-version", default: 0
        )

        let existingRules = try await CustomFilterListStorage.shared.loadCustomRules()

        if existingRules != nil && !existingRules!.isEmpty && injectedVersion.value == 0 {
          // Rules exist but we never injected them: user-owned, do not touch.
          ContentBlockerManager.log.debug(
            "Bundled YouTube rules skipped: user has custom rules")
          return
        }

        guard
          let bundledURL = Bundle.module.url(
            forResource: "youtube-filters", withExtension: "txt")
        else {
          ContentBlockerManager.log.error("Bundled YouTube rules not found")
          return
        }

        var bundledRules = try String(contentsOf: bundledURL, encoding: .utf8)

        // [brave-ios-trim] v10: append the official default filter set —
        // the same rule sources the stock App Store build downloads from
        // Brave's S3 (which needs an official service key we do not have).
        if let officialURL = Bundle.module.url(
          forResource: "official-filters", withExtension: "txt")
        {
          let officialRules = try String(contentsOf: officialURL, encoding: .utf8)
          bundledRules += "\n\n! === [brave-ios-trim] official default set ===\n"
          bundledRules += officialRules
        }

        guard injectedVersion.value < version else {
          // Up to date; nothing to do. Never removed on downgrade.
          return
        }

        // The save API validates rules, bumps the internal version and
        // recompiles both the AdBlockEngine and Content Blocker rule lists.
        try await CustomFilterListStorage.shared.save(customRules: bundledRules)
        injectedVersion.value = version
        ContentBlockerManager.log.info(
          "Bundled YouTube rules injected (v\(version))")
      } catch {
        // A failed injection must never break the launch sequence; the
        // standard lists still provide blocking without these rules.
        ContentBlockerManager.log.error(
          "Failed to inject bundled YouTube rules: \(String(describing: error))"
        )
      }
    }
  }

  /// This method prepares the ad-block services one time so that multiple scenes can benefit from its results
  /// This is particularly important since we use a shared instance for most of our ad-block services.
  public func prepareAdBlockServices(adBlockService: AdblockService) async {
    // Check if ad-block services are already ready.
    // If so, we don't have to do anything
    guard !areAdBlockServicesReady else { return }

    // Check if we're still preparing the ad-block services
    // If so we await that task
    if let task = loadTask {
      return await task.value
    }

    // Otherwise prepare the services and await the task
    let task = Task {
      let signpostID = Self.signpost.makeSignpostID()
      ContentBlockerManager.log.debug("Loading blocking launch data")
      let state = Self.signpost.beginInterval("blockingLaunchTask", id: signpostID)
      await FilterListStorage.shared.start(with: adBlockService)

      // Load cached data
      // This is done first because compileResources need their results
      // The scriptlets are loaded before the resources as they are injected into them
      await CustomFilterListStorage.shared.loadCachedCustomScriptlets()
      await AdBlockGroupsManager.shared.loadResourcesFromCache()
      async let loadEngines: Void = AdBlockGroupsManager.shared.loadEnginesFromCache()
      async let adblockResourceCache: Void = AdBlockGroupsManager.shared.loadBundledDataIfNeeded()
      _ = await (loadEngines, adblockResourceCache)
      Self.signpost.emitEvent("loadedCachedData", id: signpostID, "Loaded cached data")

      // [brave-ios-trim] Inject the bundled YouTube rules after the cached
      // data is loaded but before post-load tasks, so the first compile of
      // the session already includes them (first-screen timing parity with
      // the macOS 1.0.4 fix).
      await BundledYouTubeRules.injectIfAllowed()

      ContentBlockerManager.log.debug("Loaded blocking launch data")

      // This one is non-blocking
      performPostLoadTasks(adBlockService: adBlockService)
      areAdBlockServicesReady = true
      Self.signpost.endInterval("blockingLaunchTask", state)
    }

    // Await the task and wait for the results
    self.loadTask = task
    await task.value
    self.loadTask = nil
  }

  /// Perform tasks that don't need to block the initial load (things that can happen happily in the background after the first page loads
  private func performPostLoadTasks(
    adBlockService: AdblockService
  ) {
    Task.detached(priority: .low) {
      let signpostID = Self.signpost.makeSignpostID()
      let state = Self.signpost.beginInterval("nonBlockingLaunchTask", id: signpostID)
      await FilterListResourceDownloader.shared.start(with: adBlockService)
      await FilterListCustomURLDownloader.shared.startFetching()
      await AdblockResourceDownloader.shared.startFetching()
      // It's important to do this at the end to ensure we have our lists loaded
      await AdBlockGroupsManager.shared.cleaupInvalidRuleLists()
      Self.signpost.endInterval("nonBlockingLaunchTask", state)
    }
  }
}

extension FilterListStorage {
  /// Return all the blocklist types that are valid for filter lists.
  fileprivate var validBlocklistTypes: Set<ContentBlockerManager.BlocklistType> {
    if filterLists.isEmpty {
      // If we don't have filter lists yet loaded, use the settings
      return Set(
        allFilterListSettings.compactMap { setting -> ContentBlockerManager.BlocklistType? in
          return setting.engineSource?.blocklistType(
            engineType: setting.engineType
          )
        }
      )
    } else {
      // If we do have filter lists yet loaded, use them as they are always the most up to date and accurate
      return Set(
        filterLists.compactMap { filterList in
          return filterList.engineSource.blocklistType(
            engineType: filterList.engineType
          )
        }
      )
    }
  }
}
extension ShieldLevel {
  /// Return a list of first launch content blocker modes that MUST be precompiled during launch
  fileprivate var firstLaunchBlockingModes: Set<ContentBlockerManager.BlockingMode> {
    switch self {
    case .standard, .disabled:
      // Disabled setting may be overriden per domain so we need to treat it as standard
      // Aggressive needs to be included because some filter lists are aggressive only
      return [.general, .standard, .aggressive]
    case .aggressive:
      // If we have aggressive mode enabled, we never use standard
      // (until we allow domain specific aggressive mode)
      return [.general, .aggressive]
    }
  }
}
