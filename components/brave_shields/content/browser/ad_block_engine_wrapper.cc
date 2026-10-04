// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

#include "brave/components/brave_shields/content/browser/ad_block_engine_wrapper.h"

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/check.h"
#include "base/debug/leak_annotations.h"
#include "base/feature_list.h"
#include "base/json/json_reader.h"
#include "base/sequence_checker.h"
#include "base/strings/strcat.h"
#include "base/trace_event/trace_event.h"
#include "base/values.h"
#include "brave/components/brave_shields/content/browser/ad_block_engine.h"
#include "brave/components/brave_shields/core/browser/ad_block_resource_provider.h"
#include "brave/components/brave_shields/core/browser/ad_block_service_helper.h"
#include "brave/components/brave_shields/core/common/adblock/rs/src/lib.rs.h"
#include "brave/components/brave_shields/core/common/brave_shield_constants.h"
#include "brave/components/brave_shields/core/common/features.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "third_party/blink/public/mojom/loader/resource_load_info.mojom-shared.h"
#include "url/origin.h"

namespace brave_shields {

namespace {

adblock::BlockerResult MergeBlockerResults(adblock::BlockerResult earlier,
                                           adblock::BlockerResult later) {
  later.matched |= earlier.matched;
  later.has_exception |= earlier.has_exception;
  later.important |= earlier.important;
  if (!later.filter) {
    later.filter = std::move(earlier.filter);
  }
  if (!later.exception) {
    later.exception = std::move(earlier.exception);
  }
  if (!later.redirect.has_value) {
    later.redirect = std::move(earlier.redirect);
  }
  if (!later.rewritten_url.has_value) {
    later.rewritten_url = std::move(earlier.rewritten_url);
  }
  return later;
}

}  // namespace

AdBlockEngineWrapper::AdBlockEngineWrapper(
    std::unique_ptr<AdBlockEngine> default_engine,
    std::unique_ptr<AdBlockEngine> additional_engine)
    : default_engine_(std::move(default_engine)),
      additional_filters_engine_(std::move(additional_engine)) {
  // `this` is stored using SequenceBound, so false-positive shutdown leaks
  // are expected
  ANNOTATE_LEAKING_OBJECT_PTR(this);
}

AdBlockEngineWrapper::~AdBlockEngineWrapper() = default;

// static
std::unique_ptr<AdBlockEngineWrapper> AdBlockEngineWrapper::Create() {
  return std::make_unique<AdBlockEngineWrapper>(
      std::make_unique<AdBlockEngine>(true /* is_default */),
      std::make_unique<AdBlockEngine>(false /* is_default */));
}

adblock::BlockerResult AdBlockEngineWrapper::ShouldStartRequest(
    const GURL& url,
    blink::mojom::ResourceType resource_type,
    const url::Origin& request_initiator,
    const std::string& method,
    bool aggressive_blocking,
    bool previously_matched_rule,
    bool previously_matched_exception,
    bool previously_matched_important) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  TRACE_EVENT("brave.adblock", "ShouldStartRequest", "url", url);

  adblock::BlockerResult cached_default{};
  if (retained_cache_engines_[0]) {
    cached_default = retained_cache_engines_[0]->ShouldStartRequest(
        url, resource_type, request_initiator, method, previously_matched_rule,
        previously_matched_exception, previously_matched_important);
  }
  adblock::BlockerResult fp_result = default_engine_->ShouldStartRequest(
      url, resource_type, request_initiator, method,
      previously_matched_rule || cached_default.matched,
      previously_matched_exception || cached_default.has_exception,
      previously_matched_important || cached_default.important);
  fp_result =
      MergeBlockerResults(std::move(cached_default), std::move(fp_result));

  // removeparam results from the default engine are always ignored
  fp_result.rewritten_url.has_value = false;

  if (aggressive_blocking ||
      base::FeatureList::IsEnabled(
          brave_shields::features::kBraveAdblockDefault1pBlocking) ||
      !SameDomainOrHost(
          url, request_initiator,
          net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES)) {
    if (fp_result.important) {
      return fp_result;
    }
  } else {
    // if there's an exception from the default engine, it still needs to be
    // considered by the additional engine
    fp_result = {
        .has_exception = fp_result.has_exception,
        .exception = std::move(fp_result.exception),
    };
  }

  GURL request_url = fp_result.rewritten_url.has_value
                         ? GURL(std::string(fp_result.rewritten_url.value))
                         : url;
  if (retained_cache_engines_[1]) {
    auto cached = retained_cache_engines_[1]->ShouldStartRequest(
        request_url, resource_type, request_initiator, method,
        previously_matched_rule || fp_result.matched,
        previously_matched_exception || fp_result.has_exception,
        previously_matched_important || fp_result.important);
    fp_result = MergeBlockerResults(std::move(fp_result), std::move(cached));
    if (fp_result.rewritten_url.has_value) {
      request_url = GURL(std::string(fp_result.rewritten_url.value));
    }
  }
  auto result = additional_filters_engine_->ShouldStartRequest(
      request_url, resource_type, request_initiator, method,
      previously_matched_rule | fp_result.matched,
      previously_matched_exception | fp_result.has_exception,
      previously_matched_important | fp_result.important);

  return MergeBlockerResults(std::move(fp_result), std::move(result));
}

bool AdBlockEngineWrapper::Load(
    bool is_default_engine,
    std::unique_ptr<rust::Box<adblock::FilterSet>> filter_set,
    AdblockResourceStorageBox storage,
    bool preserve_cached_rules,
    bool validate_replacement) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto& engine =
      is_default_engine ? default_engine_ : additional_filters_engine_;
  if (!preserve_cached_rules && !validate_replacement) {
    if (filter_set) {
      return engine->Load(std::move(*filter_set), *storage);
    }
    engine->UseResources(*storage);
    return true;
  }
  const size_t index = is_default_engine ? 0 : 1;
  auto& retained = retained_cache_engines_[index];
  if (validate_replacement && !adblock::has_resources(*storage)) {
    return false;
  }
  if (!filter_set) {
    engine->UseResources(*storage);
    if (retained) {
      retained->UseResources(*storage);
    }
    return true;
  }

  // DAT rules arrive before resources. Complete their resource initialization
  // even when the separate rule replacement is rejected below.
  if (loaded_from_dat_[index]) {
    engine->UseResources(*storage);
  }

  // Build off to the side. Failed parsing/resources leave both live layers
  // intact.
  auto replacement = std::make_unique<AdBlockEngine>(is_default_engine);
  if (regex_discard_policy_) {
    replacement->SetupDiscardPolicy(*regex_discard_policy_);
  }
  if (!replacement->Load(std::move(*filter_set), *storage)) {
    return false;
  }
  if (preserve_cached_rules && loaded_from_dat_[index] && !retained) {
    retained = std::move(engine);
  } else if (!preserve_cached_rules) {
    retained.reset();
  }
  if (retained) {
    retained->UseResources(*storage);
  }
  // All blocking queries use this sequence, so none can observe a partial swap.
  engine = std::move(replacement);
  loaded_from_dat_[index] = false;
  local_rules_published_[index] = true;
  complete_rules_published_[index] = !preserve_cached_rules;
  return true;
}

bool AdBlockEngineWrapper::LoadDAT(bool is_default_engine,
                                   DATFileDataBuffer dat,
                                   AdblockResourceStorageBox storage) {
  CHECK(base::FeatureList::IsEnabled(features::kAdblockDATCache));
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto* engine = is_default_engine ? default_engine_.get()
                                   : additional_filters_engine_.get();
  const size_t index = is_default_engine ? 0 : 1;
  if (complete_rules_published_[index]) {
    // An asynchronous cache read cannot roll back a completed rule rebuild.
    return true;
  }
  if (local_rules_published_[index]) {
    auto cached = std::make_unique<AdBlockEngine>(is_default_engine);
    if (regex_discard_policy_) {
      cached->SetupDiscardPolicy(*regex_discard_policy_);
    }
    if (!cached->Load(true, dat, *storage)) {
      return false;
    }
    retained_cache_engines_[index] = std::move(cached);
    return true;
  }
  if (!dat.empty()) {
    const bool loaded = engine->Load(true, std::move(dat), *storage);
    if (loaded) {
      loaded_from_dat_[index] = true;
      retained_cache_engines_[index].reset();
    }
    return loaded;
  } else {
    engine->UseResources(*storage);
    return true;
  }
}

DATFileDataBuffer AdBlockEngineWrapper::Serialize(bool is_default_engine) {
  CHECK(base::FeatureList::IsEnabled(features::kAdblockDATCache));
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto* engine = is_default_engine ? default_engine_.get()
                                   : additional_filters_engine_.get();
  if (retained_cache_engines_[is_default_engine ? 0 : 1]) {
    return {};
  }
  return engine->Serialize();
}

std::optional<std::string> AdBlockEngineWrapper::GetCspDirectives(
    const GURL& url,
    blink::mojom::ResourceType resource_type,
    const url::Origin& first_party_origin,
    const std::string& method) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  TRACE_EVENT("brave.adblock", "GetCspDirectives", "url", url);
  auto csp_directives = default_engine_->GetCspDirectives(
      url, resource_type, first_party_origin, method);

  const auto additional_csp = additional_filters_engine_->GetCspDirectives(
      url, resource_type, first_party_origin, method);
  MergeCspDirectiveInto(additional_csp, &csp_directives);
  for (const auto& cached : retained_cache_engines_) {
    if (cached) {
      MergeCspDirectiveInto(cached->GetCspDirectives(
                                url, resource_type, first_party_origin, method),
                            &csp_directives);
    }
  }

  return csp_directives;
}

void AdBlockEngineWrapper::UseResources(
    const adblock::BraveCoreResourceStorage& storage) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  default_engine_->UseResources(storage);
  additional_filters_engine_->UseResources(storage);
  for (const auto& cached : retained_cache_engines_) {
    if (cached) {
      cached->UseResources(storage);
    }
  }
}

std::pair<base::DictValue, base::DictValue>
AdBlockEngineWrapper::GetDebugInfo() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto first = default_engine_->GetDebugInfo();
  auto second = additional_filters_engine_->GetDebugInfo();
  first.Set("retained_cache", static_cast<bool>(retained_cache_engines_[0]));
  second.Set("retained_cache", static_cast<bool>(retained_cache_engines_[1]));
  return {std::move(first), std::move(second)};
}

void AdBlockEngineWrapper::DiscardRegex(uint64_t regex_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  // Dispatch to both engines since regex IDs are unique across engines.
  default_engine_->DiscardRegex(regex_id);
  additional_filters_engine_->DiscardRegex(regex_id);
  for (const auto& cached : retained_cache_engines_) {
    if (cached) {
      cached->DiscardRegex(regex_id);
    }
  }
}

void AdBlockEngineWrapper::SetupDiscardPolicy(
    const adblock::RegexManagerDiscardPolicy& policy) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  regex_discard_policy_ = policy;
  for (const auto& cached : retained_cache_engines_) {
    if (cached) {
      cached->SetupDiscardPolicy(policy);
    }
  }
  default_engine_->SetupDiscardPolicy(policy);
  additional_filters_engine_->SetupDiscardPolicy(policy);
}

base::DictValue AdBlockEngineWrapper::UrlCosmeticResources(
    const std::string& url,
    bool aggressive_blocking) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  TRACE_EVENT("brave.adblock", "UrlCosmeticResources", "url", url);

  base::DictValue resources = default_engine_->UrlCosmeticResources(url);
  if (retained_cache_engines_[0]) {
    MergeResourcesInto(retained_cache_engines_[0]->UrlCosmeticResources(url),
                       resources, false);
  }

  if (!aggressive_blocking) {
    // `:has` procedural selectors from the default engine should not be hidden
    // in standard blocking mode.
    base::ListValue* default_hide_selectors =
        resources.FindList("hide_selectors");
    if (default_hide_selectors) {
      base::ListValue::iterator it = default_hide_selectors->begin();
      while (it < default_hide_selectors->end()) {
        DCHECK(it->is_string());
        if (it->GetString().find(":has(") != std::string::npos) {
          it = default_hide_selectors->erase(it);
        } else {
          it++;
        }
      }
    }

    // In standard blocking mode, drop procedural filters but otherwise keep
    // action filters.
    StripProceduralFilters(resources);
  }

  base::DictValue additional_resources =
      additional_filters_engine_->UrlCosmeticResources(url);
  if (retained_cache_engines_[1]) {
    MergeResourcesInto(retained_cache_engines_[1]->UrlCosmeticResources(url),
                       additional_resources, false);
  }

  MergeResourcesInto(std::move(additional_resources), resources,
                     /*force_hide=*/true);

  return resources;
}

base::DictValue AdBlockEngineWrapper::HiddenClassIdSelectors(
    const std::vector<std::string>& classes,
    const std::vector<std::string>& ids,
    const std::vector<std::string>& exceptions) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  TRACE_EVENT("brave.adblock", "HiddenClassIdSelectors", "classes", classes,
              "ids", ids);

  base::ListValue hide_selectors =
      default_engine_->HiddenClassIdSelectors(classes, ids, exceptions);

  base::ListValue force_hide_selectors =
      additional_filters_engine_->HiddenClassIdSelectors(classes, ids,
                                                         exceptions);

  for (size_t index = 0; index < retained_cache_engines_.size(); ++index) {
    if (!retained_cache_engines_[index]) {
      continue;
    }
    auto cached = retained_cache_engines_[index]->HiddenClassIdSelectors(
        classes, ids, exceptions);
    auto& into = index == 0 ? hide_selectors : force_hide_selectors;
    for (auto& selector : cached) {
      if (!into.contains(selector.GetString())) {
        into.Append(std::move(selector));
      }
    }
  }
  base::DictValue result;
  result.Set("hide_selectors", std::move(hide_selectors));
  result.Set("force_hide_selectors", std::move(force_hide_selectors));
  return result;
}

// Removes any procedural filters from the given UrlCosmeticResources Value.
//
// Procedural filters are filters with at least one selector operator of a type
// that isn't `css-selector`.
//
// These filters are represented as JSON provided by adblock-rust. The format
// is documented at:
// https://docs.rs/adblock/latest/adblock/cosmetic_filter_cache/struct.ProceduralOrActionFilter.html
// static
void AdBlockEngineWrapper::StripProceduralFilters(base::DictValue& resources) {
  TRACE_EVENT("brave.adblock", "StripProceduralFilters");
  base::ListValue* procedural_actions =
      resources.FindList(kCosmeticResourcesProceduralActions);
  if (procedural_actions) {
    base::ListValue::iterator it = procedural_actions->begin();
    while (it < procedural_actions->end()) {
      DCHECK(it->is_string());
      auto* pfilter_str = it->GetIfString();
      if (pfilter_str == nullptr) {
        continue;
      }
      auto val = base::JSONReader::ReadDict(*pfilter_str, base::JSON_PARSE_RFC);
      if (val) {
        auto* list = val->FindList("selector");
        if (list && list->size() != 1) {
          // Non-procedural filters are always a single operator in length.
          it = procedural_actions->erase(it);
          continue;
        }
        // The single operator must also be a `css-selector`.
        auto op_iterator = list->begin();
        auto* dict = op_iterator->GetIfDict();
        if (dict) {
          auto* str = dict->FindString("type");
          if (str && *str != "css-selector") {
            it = procedural_actions->erase(it);
            continue;
          }
        }
      }
      it++;
    }
  }
}

// Merges the contents of the first UrlCosmeticResources Value into the second
// one provided.
//
// If `force_hide` is true, the contents of `from`'s `hide_selectors` field
// will be moved into a possibly new field of `into` called
// `force_hide_selectors`.
void AdBlockEngineWrapper::MergeResourcesInto(base::DictValue from,
                                              base::DictValue& into,
                                              bool force_hide) {
  TRACE_EVENT("brave.adblock", "MergeResourcesInto");
  base::ListValue* resources_hide_selectors = nullptr;
  if (force_hide) {
    resources_hide_selectors = into.FindList("force_hide_selectors");
    if (!resources_hide_selectors) {
      resources_hide_selectors =
          into.Set("force_hide_selectors", base::ListValue())->GetIfList();
    }
  } else {
    resources_hide_selectors = into.FindList("hide_selectors");
  }
  base::ListValue* from_resources_hide_selectors =
      from.FindList("hide_selectors");
  if (resources_hide_selectors && from_resources_hide_selectors) {
    for (auto& selector : *from_resources_hide_selectors) {
      resources_hide_selectors->Append(std::move(selector));
    }
  }

  constexpr std::string_view kListKeys[] = {
      "exceptions", kCosmeticResourcesProceduralActions};
  for (const auto& key : kListKeys) {
    base::ListValue* resources = into.FindList(key);
    base::ListValue* from_resources = from.FindList(key);
    if (resources && from_resources) {
      for (auto& exception : *from_resources) {
        resources->Append(std::move(exception));
      }
    }
  }

  auto* resources_injected_script = into.FindString("injected_script");
  auto* from_resources_injected_script = from.FindString("injected_script");
  if (resources_injected_script && from_resources_injected_script) {
    *resources_injected_script =
        base::StrCat({"{\n", *resources_injected_script, "\n}\n{\n",
                      *from_resources_injected_script, "\n}"});
  }

  auto from_resources_generichide = from.FindBool("generichide");
  if (from_resources_generichide && *from_resources_generichide) {
    into.Set("generichide", true);
  }
}

}  // namespace brave_shields
