/* Copyright (c) 2025 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

#include "chrome/browser/policy/chrome_browser_policy_connector.h"

#include "base/command_line.h"
#include "base/values.h"
#include "build/build_config.h"
#include "components/policy/core/common/configuration_policy_provider.h"
#include "components/policy/core/common/policy_bundle.h"
#include "components/policy/core/common/policy_map.h"
#include "components/policy/core/common/policy_types.h"

#if BUILDFLAG(IS_MAC)
namespace {

// Reuse public feature policies without modifying user data or service access.
class LocalBuildPolicyProvider final
    : public policy::ConfigurationPolicyProvider {
 public:
  LocalBuildPolicyProvider() { PublishPolicies(); }

  void RefreshPolicies(policy::PolicyFetchReason reason) override {
    PublishPolicies();
  }

 private:
  void PublishPolicies() {
    policy::PolicyBundle bundle;
    auto& policies = bundle.Get(
        policy::PolicyNamespace(policy::POLICY_DOMAIN_CHROME, std::string()));
    constexpr struct {
      const char* name;
      bool value;
    } kPolicies[] = {{"BraveRewardsDisabled", true},
                     {"BraveWalletDisabled", true},
                     {"BraveAIChatEnabled", false},
                     {"BraveLocalAIEnabled", false},
                     {"BraveVPNDisabled", true},
                     {"TorDisabled", true},
                     {"BraveNewsDisabled", true},
                     {"BraveTalkDisabled", true}};
    for (const auto& entry : kPolicies) {
      policies.Set(entry.name, policy::POLICY_LEVEL_MANDATORY,
                   policy::POLICY_SCOPE_USER,
                   policy::POLICY_SOURCE_COMMAND_LINE,
                   base::Value(entry.value), nullptr);
    }
    UpdatePolicy(std::move(bundle));
  }
};

}  // namespace
#endif

// Forward declare functions that will be implemented in
// brave_browser_policy_provider.cc This is done so that we don't need to depend
// on anything in the brave layer here. Otherwise we'd have a circular
// dependency.
namespace brave_policy {
std::unique_ptr<policy::ConfigurationPolicyProvider>
CreateBraveBrowserPolicyProvider();

std::unique_ptr<policy::ConfigurationPolicyProvider>
CreateLocalBuildPolicyProvider() {
#if BUILDFLAG(IS_MAC)
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("brave-local-build")) {
    return std::make_unique<LocalBuildPolicyProvider>();
  }
#endif
  return nullptr;
}
}  // namespace brave_policy

// Rename CreatePolicyProviders to CreatePolicyProviders_ChromiumImpl
#define CreatePolicyProviders CreatePolicyProviders_ChromiumImpl

#include <chrome/browser/policy/chrome_browser_policy_connector.cc>  // IWYU pragma: export

#undef CreatePolicyProviders

// And define the new one
namespace policy {

std::vector<std::unique_ptr<policy::ConfigurationPolicyProvider>>
ChromeBrowserPolicyConnector::CreatePolicyProviders() {
  auto providers =
      ChromeBrowserPolicyConnector::CreatePolicyProviders_ChromiumImpl();
  if (auto local_provider = ::brave_policy::CreateLocalBuildPolicyProvider()) {
    providers.push_back(std::move(local_provider));
  }
  // Add browser policy provider for browser-level (local state) policies
  auto brave_browser_provider =
      ::brave_policy::CreateBraveBrowserPolicyProvider();
  // providers takes ownership of brave_browser_provider
  providers.push_back(std::move(brave_browser_provider));
  return providers;
}

}  // namespace policy
