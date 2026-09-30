// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

import { mangle } from 'lit_mangler'

// Hide the passwords card
mangle((root) => {
  const passwordsCard = root.getElementById('passwords')
  if (!passwordsCard) {
    throw new Error(`[Settings] Safety Hub: couldn't find #passwords card`)
  }
  passwordsCard.setAttribute('hidden', 'true')
})

// #emptyStateModule lives inside `${this.shouldShowNoRecommendationsState_()
// ? html`...` : ''}`, a nested template, so it isn't reachable from the root
// template above. We use a shield icon here instead of upstream's checkmark;
// the companion browser/resources/settings/br/safety_hub_page.ts override
// colors it to match.
mangle((root) => {
  const emptyStateModule = root.getElementById('emptyStateModule')
  if (!emptyStateModule) {
    throw new Error(
      `[Settings] Safety Hub: couldn't find #emptyStateModule`)
  }
  emptyStateModule.setAttribute('header-icon', 'shield-done-filled')
}, (t) => t.text.includes('id="emptyStateModule"'))
