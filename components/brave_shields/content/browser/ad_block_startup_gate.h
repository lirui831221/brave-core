// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef BRAVE_COMPONENTS_BRAVE_SHIELDS_CONTENT_BROWSER_AD_BLOCK_STARTUP_GATE_H_
#define BRAVE_COMPONENTS_BRAVE_SHIELDS_CONTENT_BROWSER_AD_BLOCK_STARTUP_GATE_H_

#include <array>
#include <utility>

#include "base/functional/callback.h"
#include "base/location.h"
#include "base/one_shot_event.h"

namespace brave_shields {

// Used on the UI sequence. Completion includes unavailable resources, so a
// missing component cannot leave a renderer's synchronous request waiting.
class AdBlockStartupGate {
 public:
  void Post(base::OnceClosure callback) {
    complete_.Post(FROM_HERE, std::move(callback));
  }

  void OnRulesLoaded(bool is_default) {
    rules_loaded_[is_default ? 0 : 1] = true;
    MaybeSignal();
  }

  void OnResourcesLoaded(bool is_default) {
    resources_loaded_[is_default ? 0 : 1] = true;
    MaybeSignal();
  }

 private:
  void MaybeSignal() {
    if (!complete_.is_signaled() && rules_loaded_[0] && rules_loaded_[1] &&
        resources_loaded_[0] && resources_loaded_[1]) {
      complete_.Signal();
    }
  }

  std::array<bool, 2> rules_loaded_{};
  std::array<bool, 2> resources_loaded_{};
  base::OneShotEvent complete_;
};

}  // namespace brave_shields

#endif  // BRAVE_COMPONENTS_BRAVE_SHIELDS_CONTENT_BROWSER_AD_BLOCK_STARTUP_GATE_H_
