// Copyright (c) 2025 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

import BraveCore

extension PrefService {
  /// Whether or not the Brave Talk feature in general is available to use and the UI should display
  /// buttons/settings for it.
  public var isBraveTalkAvailable: Bool {
    // [brave-ios-trim] Brave Talk disabled in this custom build
    // (parity with mac-brave-1.0.4 service trim). Returning false hides the
    // Talk menu entry and blocks the Jitsi bridge from initializing.
    return false
  }
}
