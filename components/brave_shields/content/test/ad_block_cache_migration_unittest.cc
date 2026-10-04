// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

#include <memory>
#include <string>
#include <vector>

#include "base/command_line.h"
#include "base/containers/to_vector.h"
#include "base/files/file_util.h"
#include "base/test/scoped_feature_list.h"
#include "base/test/task_environment.h"
#include "brave/components/brave_shields/content/browser/ad_block_engine_wrapper.h"
#include "brave/components/brave_shields/core/common/features.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace brave_shields {
namespace {

constexpr char kResources[] = R"([{"name":"probe.js","aliases":[],
  "kind":{"mime":"application/javascript"},
  "content":"d2luZG93LmxheWVyUHJvYmU9dHJ1ZTs=","dependencies":[]}])";

std::unique_ptr<rust::Box<adblock::FilterSet>> Rules(const std::string& text) {
  auto fs = std::make_unique<rust::Box<adblock::FilterSet>>(
      adblock::new_filter_set(false));
  std::vector<unsigned char> bytes(text.begin(), text.end());
  EXPECT_EQ(adblock::ResultKind::Success,
            (*fs)->add_filter_list(bytes).result_kind);
  return fs;
}

DATFileDataBuffer SerializeRules(const std::string& text) {
  auto fs = Rules(text);
  auto engine = adblock::engine_from_filter_set(std::move(*fs));
  EXPECT_EQ(adblock::ResultKind::Success, engine.result_kind);
  return base::ToVector(engine.value->serialize());
}

AdblockResourceStorageBox Resources() {
  return adblock::new_resource_storage(kResources);
}

class AdBlockCacheMigrationTest : public testing::Test {
 protected:
  void SetUp() override {
    features_.InitAndEnableFeature(features::kAdblockDATCache);
    adblock::set_domain_resolver();
    wrapper_ = AdBlockEngineWrapper::Create();
  }
  bool Blocked(const char* path) {
    const auto result = wrapper_->ShouldStartRequest(
        GURL(std::string("https://cdn.example/") + path),
        blink::mojom::ResourceType::kScript,
        url::Origin::Create(GURL("https://example.org/")), "GET", true, false,
        false, false);
    return result.important || (result.matched && !result.has_exception);
  }
  bool HasSelector(const char* selector) {
    auto result = wrapper_->UrlCosmeticResources("https://example.org/", true);
    const auto* list = result.FindList("force_hide_selectors");
    return list && list->contains(selector);
  }
  bool LoadLocal(const std::string& rules) {
    return wrapper_->Load(false, Rules(rules), Resources(), true, true);
  }
  base::test::TaskEnvironment tasks_;
  base::test::ScopedFeatureList features_;
  std::unique_ptr<AdBlockEngineWrapper> wrapper_;
};

TEST_F(AdBlockCacheMigrationTest, ValidLegacyDatKeepsRulesMissingFromText) {
  const auto dat = SerializeRules(
      "/legacy.js\nexample.org###legacy\n"
      "example.org##+js(probe)");
  ASSERT_TRUE(wrapper_->LoadDAT(false, dat, Resources()));
  ASSERT_TRUE(Blocked("legacy.js"));
  ASSERT_TRUE(LoadLocal("/new.js\nexample.org###new"));
  EXPECT_TRUE(Blocked("legacy.js"));
  EXPECT_TRUE(Blocked("new.js"));
  EXPECT_TRUE(HasSelector("#legacy"));
  EXPECT_TRUE(HasSelector("#new"));
  auto cosmetic = wrapper_->UrlCosmeticResources("https://example.org/", true);
  ASSERT_TRUE(cosmetic.FindString("injected_script"));
  EXPECT_NE(std::string::npos,
            cosmetic.FindString("injected_script")->find("layerProbe"));
  EXPECT_TRUE(wrapper_->Serialize(false).empty());
}

TEST_F(AdBlockCacheMigrationTest, FailedRuleValidationRetainsBothLiveLayers) {
  ASSERT_TRUE(
      wrapper_->LoadDAT(false, SerializeRules("/legacy.js"), Resources()));
  ASSERT_TRUE(LoadLocal("/current.js"));
  auto invalid = Rules("/partial.js");
  (*invalid)->invalidate();
  EXPECT_FALSE(
      wrapper_->Load(false, std::move(invalid), Resources(), true, true));
  EXPECT_TRUE(Blocked("legacy.js"));
  EXPECT_TRUE(Blocked("current.js"));
  EXPECT_FALSE(Blocked("partial.js"));
}

TEST_F(AdBlockCacheMigrationTest,
       FailedUtf8ProviderCannotPublishPartialEngine) {
  ASSERT_TRUE(
      wrapper_->LoadDAT(false, SerializeRules("/legacy.js"), Resources()));
  auto invalid = Rules("/partial.js");
  std::vector<unsigned char> bytes{0xff};
  EXPECT_NE(adblock::ResultKind::Success,
            (*invalid)->add_filter_list(bytes).result_kind);
  EXPECT_FALSE(
      wrapper_->Load(false, std::move(invalid), Resources(), true, true));
  EXPECT_TRUE(Blocked("legacy.js"));
  EXPECT_FALSE(Blocked("partial.js"));
}

TEST_F(AdBlockCacheMigrationTest,
       MissingOrMalformedResourcesRetainCurrentRules) {
  ASSERT_TRUE(
      wrapper_->LoadDAT(false, SerializeRules("/legacy.js"), Resources()));
  ASSERT_TRUE(LoadLocal("/current.js"));
  EXPECT_FALSE(wrapper_->Load(false, Rules("/partial.js"),
                              adblock::new_empty_resource_storage(), true,
                              true));
  EXPECT_FALSE(wrapper_->Load(
      false, nullptr, adblock::new_resource_storage("<html>failure</html>"),
      true, true));
  EXPECT_TRUE(Blocked("legacy.js"));
  EXPECT_TRUE(Blocked("current.js"));
  EXPECT_FALSE(Blocked("partial.js"));
}

TEST_F(AdBlockCacheMigrationTest, RepeatedRefreshReplacesOnlyTheLocalLayer) {
  ASSERT_TRUE(
      wrapper_->LoadDAT(false, SerializeRules("/legacy.js"), Resources()));
  ASSERT_TRUE(LoadLocal("/first.js"));
  ASSERT_TRUE(LoadLocal("/second.js"));
  EXPECT_TRUE(Blocked("legacy.js"));
  EXPECT_FALSE(Blocked("first.js"));
  EXPECT_TRUE(Blocked("second.js"));
}

TEST_F(AdBlockCacheMigrationTest, RestartDoesNotRequireDeletingOrRewritingDat) {
  const auto original = SerializeRules("/legacy.js");
  ASSERT_TRUE(wrapper_->LoadDAT(false, original, Resources()));
  ASSERT_TRUE(LoadLocal("/new.js"));
  wrapper_ = AdBlockEngineWrapper::Create();
  ASSERT_TRUE(wrapper_->LoadDAT(false, original, Resources()));
  EXPECT_TRUE(Blocked("legacy.js"));
  EXPECT_FALSE(Blocked("new.js"));
  ASSERT_TRUE(LoadLocal("/new.js"));
  EXPECT_TRUE(Blocked("legacy.js"));
  EXPECT_TRUE(Blocked("new.js"));
}

TEST_F(AdBlockCacheMigrationTest, OnlySuccessfulCompleteLoadRetiresFallback) {
  ASSERT_TRUE(
      wrapper_->LoadDAT(false, SerializeRules("/legacy.js"), Resources()));
  ASSERT_TRUE(LoadLocal("/current.js"));
  auto failed = Rules("/complete.js");
  (*failed)->invalidate();
  EXPECT_FALSE(
      wrapper_->Load(false, std::move(failed), Resources(), false, true));
  EXPECT_TRUE(Blocked("legacy.js"));
  EXPECT_TRUE(Blocked("current.js"));
  ASSERT_TRUE(
      wrapper_->Load(false, Rules("/complete.js"), Resources(), false, true));
  EXPECT_FALSE(Blocked("legacy.js"));
  EXPECT_FALSE(Blocked("current.js"));
  EXPECT_TRUE(Blocked("complete.js"));
  EXPECT_FALSE(wrapper_->Serialize(false).empty());
}

TEST_F(AdBlockCacheMigrationTest, ExceptionsAndImportantRulesKeepPrecedence) {
  ASSERT_TRUE(wrapper_->LoadDAT(
      false, SerializeRules("/old.js\n@@/except.js\n/important.js$important"),
      Resources()));
  ASSERT_TRUE(LoadLocal("@@/old.js\n/except.js\n@@/important.js"));
  EXPECT_FALSE(Blocked("old.js"));
  EXPECT_FALSE(Blocked("except.js"));
  EXPECT_TRUE(Blocked("important.js"));
}

TEST_F(AdBlockCacheMigrationTest, CorruptDatDoesNotReplaceExistingEngine) {
  ASSERT_TRUE(
      wrapper_->LoadDAT(false, SerializeRules("/legacy.js"), Resources()));
  EXPECT_FALSE(wrapper_->LoadDAT(false, {1, 2, 3}, Resources()));
  EXPECT_TRUE(Blocked("legacy.js"));
  ASSERT_TRUE(LoadLocal("/new.js"));
  EXPECT_TRUE(Blocked("legacy.js"));
  EXPECT_TRUE(Blocked("new.js"));
}

TEST_F(AdBlockCacheMigrationTest,
       DefaultAndAdditionalLayersPreserveNetworkRules) {
  ASSERT_TRUE(
      wrapper_->LoadDAT(true, SerializeRules("/default.js"), Resources()));
  ASSERT_TRUE(
      wrapper_->LoadDAT(false, SerializeRules("/additional.js"), Resources()));
  ASSERT_TRUE(wrapper_->Load(true, Rules("/fresh-default.js"), Resources(),
                             true, true));
  ASSERT_TRUE(LoadLocal("/fresh-additional.js"));
  for (const char* path : {"default.js", "additional.js", "fresh-default.js",
                           "fresh-additional.js"}) {
    EXPECT_TRUE(Blocked(path)) << path;
  }
}

TEST_F(AdBlockCacheMigrationTest,
       FailedColdMigrationStillInitializesCachedScriptlets) {
  ASSERT_TRUE(wrapper_->LoadDAT(
      false, SerializeRules("/legacy.js\nexample.org##+js(probe)"),
      adblock::new_empty_resource_storage()));
  auto rejected = Rules("/partial.js");
  (*rejected)->invalidate();
  EXPECT_FALSE(
      wrapper_->Load(false, std::move(rejected), Resources(), true, true));
  EXPECT_TRUE(Blocked("legacy.js"));
  EXPECT_FALSE(Blocked("partial.js"));
  const auto cosmetic =
      wrapper_->UrlCosmeticResources("https://example.org/", true);
  ASSERT_TRUE(cosmetic.FindString("injected_script"));
  EXPECT_NE(std::string::npos,
            cosmetic.FindString("injected_script")->find("layerProbe"));
}

TEST_F(AdBlockCacheMigrationTest, LateCacheReadPreservesPublishedLocalRules) {
  ASSERT_TRUE(LoadLocal("/new.js"));
  ASSERT_TRUE(
      wrapper_->LoadDAT(false, SerializeRules("/legacy.js"), Resources()));
  EXPECT_TRUE(Blocked("new.js"));
  EXPECT_TRUE(Blocked("legacy.js"));
}

TEST_F(AdBlockCacheMigrationTest, LateCacheReadCannotRollBackCompleteRebuild) {
  ASSERT_TRUE(
      wrapper_->Load(false, Rules("/complete.js"), Resources(), false, true));
  ASSERT_TRUE(
      wrapper_->LoadDAT(false, SerializeRules("/obsolete.js"), Resources()));
  EXPECT_TRUE(Blocked("complete.js"));
  EXPECT_FALSE(Blocked("obsolete.js"));
}

TEST_F(AdBlockCacheMigrationTest, ProductionLegacyDatLoadsNewYouTubeRule) {
  const auto* command = base::CommandLine::ForCurrentProcess();
  const auto fixture = command->GetSwitchValuePath("legacy-cache-fixture-dir");
  const auto snapshot = command->GetSwitchValuePath("adblock-snapshot-dir");
  if (fixture.empty() || snapshot.empty()) {
    GTEST_SKIP();
  }
  std::string dat, rules, resources;
  ASSERT_TRUE(base::ReadFileToString(fixture.AppendASCII("engine1.dat"), &dat));
  ASSERT_TRUE(base::ReadFileToString(
      snapshot.AppendASCII("youtube-filters.txt"), &rules));
  ASSERT_TRUE(base::ReadFileToString(snapshot.AppendASCII("resources.json"),
                                     &resources));
  auto storage = adblock::new_resource_storage(resources);
  ASSERT_TRUE(wrapper_->LoadDAT(false,
                                DATFileDataBuffer(dat.begin(), dat.end()),
                                adblock::clone_resource_storage(*storage)));
  auto before = wrapper_->UrlCosmeticResources(
      "https://www.youtube.com/watch?v=synthetic", true);
  ASSERT_TRUE(before.FindString("injected_script"));
  EXPECT_EQ(std::string::npos,
            before.FindString("injected_script")->find("/get_watch?"));
  ASSERT_TRUE(
      wrapper_->Load(false, Rules(rules), std::move(storage), true, true));
  auto after = wrapper_->UrlCosmeticResources(
      "https://www.youtube.com/watch?v=synthetic", true);
  ASSERT_TRUE(after.FindString("injected_script"));
  EXPECT_NE(std::string::npos,
            after.FindString("injected_script")->find("/get_watch?"));
  auto sentinel = wrapper_->UrlCosmeticResources("http://127.0.0.1/", true);
  ASSERT_TRUE(sentinel.FindString("injected_script"));
  EXPECT_NE(std::string::npos,
            sentinel.FindString("injected_script")->find("legacyDatProbe"));
  const auto output = command->GetSwitchValuePath("migration-probe-output");
  if (!output.empty()) {
    ASSERT_TRUE(base::WriteFile(output, *after.FindString("injected_script")));
  }
}

}  // namespace
}  // namespace brave_shields
