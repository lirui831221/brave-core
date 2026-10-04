// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

#include "brave/components/brave_shields/core/browser/ad_block_default_resource_provider.h"

#include <set>
#include <string>
#include <vector>

#include "base/base_paths.h"
#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/json/json_reader.h"
#include "base/test/scoped_command_line.h"
#include "base/test/scoped_path_override.h"
#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace brave_shields {

class AdBlockDefaultResourceProviderTest : public testing::Test {
 protected:
  void SetUp() override { ASSERT_TRUE(directory_.CreateUniqueTempDir()); }

  void ComponentReady(AdBlockDefaultResourceProvider& provider,
                      const base::FilePath& path) {
    provider.OnComponentReady(path);
  }

  base::FilePath WriteResources(const base::FilePath& directory) {
    EXPECT_TRUE(base::CreateDirectory(directory));
    auto path = directory.AppendASCII("resources.json");
    EXPECT_TRUE(base::WriteFile(path, R"([{"name":"probe.js","aliases":[],
      "kind":{"mime":"application/javascript"},"content":"KCgpPT57fSkoKTs=",
      "dependencies":[]}])"));
    return path;
  }

  base::test::TaskEnvironment task_environment_;
  base::test::ScopedCommandLine command_line_;
  base::ScopedTempDir directory_;
};

TEST_F(AdBlockDefaultResourceProviderTest, UnmarkedBuildKeepsEmptyFallback) {
  command_line_.GetProcessCommandLine()->RemoveSwitch("brave-local-build");
  base::ScopedPathOverride assets(base::DIR_ASSETS, directory_.GetPath());
  WriteResources(directory_.GetPath().AppendASCII("brave_local_adblock"));
  AdBlockDefaultResourceProvider provider(nullptr);
  EXPECT_TRUE(provider.GetResourcesPath().empty());
  base::test::TestFuture<AdblockResourceStorageBox> loaded;
  provider.LoadResources(loaded.GetCallback());
  auto storage = loaded.Take();
  EXPECT_FALSE(adblock::has_resource_for_testing(*storage, "probe.js"));
}

TEST_F(AdBlockDefaultResourceProviderTest, MarkedBuildLoadsBundledResources) {
  command_line_.GetProcessCommandLine()->AppendSwitch("brave-local-build");
  base::ScopedPathOverride assets(base::DIR_ASSETS, directory_.GetPath());
  auto expected =
      WriteResources(directory_.GetPath().AppendASCII("brave_local_adblock"));
  AdBlockDefaultResourceProvider provider(nullptr);
  EXPECT_EQ(base::MakeAbsoluteFilePath(expected),
            base::MakeAbsoluteFilePath(provider.GetResourcesPath()));
  base::test::TestFuture<AdblockResourceStorageBox> loaded;
  provider.LoadResources(loaded.GetCallback());
  auto storage = loaded.Take();
  EXPECT_TRUE(adblock::has_resource_for_testing(*storage, "probe.js"));
}

TEST_F(AdBlockDefaultResourceProviderTest, MissingBundleDoesNotBlockCallback) {
  command_line_.GetProcessCommandLine()->AppendSwitch("brave-local-build");
  base::ScopedPathOverride assets(base::DIR_ASSETS, directory_.GetPath());
  AdBlockDefaultResourceProvider provider(nullptr);
  base::test::TestFuture<AdblockResourceStorageBox> loaded;
  provider.LoadResources(loaded.GetCallback());
  auto storage = loaded.Take();
  EXPECT_FALSE(adblock::has_resource_for_testing(*storage, "probe.js"));
}

TEST_F(AdBlockDefaultResourceProviderTest, VerifiedComponentTakesPrecedence) {
  command_line_.GetProcessCommandLine()->AppendSwitch("brave-local-build");
  base::ScopedPathOverride assets(base::DIR_ASSETS, directory_.GetPath());
  WriteResources(directory_.GetPath().AppendASCII("brave_local_adblock"));
  auto component = directory_.GetPath().AppendASCII("verified_component");
  auto expected = WriteResources(component);
  AdBlockDefaultResourceProvider provider(nullptr);
  ComponentReady(provider, component);
  EXPECT_EQ(base::MakeAbsoluteFilePath(expected),
            base::MakeAbsoluteFilePath(provider.GetResourcesPath()));
  base::test::TestFuture<AdblockResourceStorageBox> loaded;
  provider.LoadResources(loaded.GetCallback());
  auto storage = loaded.Take();
  EXPECT_TRUE(adblock::has_resource_for_testing(*storage, "probe.js"));
}

TEST_F(AdBlockDefaultResourceProviderTest,
       PackagedSnapshotBuildsYouTubeScripts) {
  const auto directory =
      command_line_.GetProcessCommandLine()->GetSwitchValuePath(
          "adblock-snapshot-dir");
  if (directory.empty()) {
    GTEST_SKIP()
        << "Pass --adblock-snapshot-dir to verify the packaged payload";
  }
  std::string rules;
  std::string resources;
  ASSERT_TRUE(base::ReadFileToString(
      directory.AppendASCII("youtube-filters.txt"), &rules));
  ASSERT_TRUE(base::ReadFileToString(directory.AppendASCII("resources.json"),
                                     &resources));
  adblock::set_domain_resolver();
  auto filters = adblock::new_filter_set(false);
  std::vector<unsigned char> bytes(rules.begin(), rules.end());
  ASSERT_EQ(adblock::ResultKind::Success,
            filters->add_filter_list(bytes).result_kind);
  auto result = adblock::engine_from_filter_set(std::move(filters));
  ASSERT_EQ(adblock::ResultKind::Success, result.result_kind);
  auto& engine = result.value;
  const std::string youtube = "https://www.youtube.com/watch?v=synthetic";
  EXPECT_EQ(std::string::npos,
            std::string(engine->url_cosmetic_resources(youtube))
                .find("ytInitialPlayerResponse"));
  auto storage = adblock::new_resource_storage(resources);
  ASSERT_TRUE(adblock::has_resource_for_testing(*storage, "noop.js"));
  engine->use_resource_storage(*storage);
  const std::string output(engine->url_cosmetic_resources(youtube));
  const auto output_path =
      command_line_.GetProcessCommandLine()->GetSwitchValuePath(
          "dump-cosmetic-test-fixture");
  if (!output_path.empty()) {
    ASSERT_TRUE(base::WriteFile(output_path, output));
  }
  EXPECT_NE(std::string::npos, output.find("ytInitialPlayerResponse"));
  EXPECT_NE(std::string::npos, output.find("ytd-ad-slot-renderer"));
  EXPECT_EQ(std::string::npos,
            std::string(engine->url_cosmetic_resources("https://example.org/"))
                .find("ytInitialPlayerResponse"));
}

// Uses only caller-provided synthetic/public fixtures. This exercises the same
// binary format that AdBlockEngine loads, without borrowing a personal cache.
TEST_F(AdBlockDefaultResourceProviderTest, SyntheticLegacyDatRoundTrip) {
  const auto fixture =
      command_line_.GetProcessCommandLine()->GetSwitchValuePath(
          "legacy-cache-fixture-dir");
  const auto snapshot =
      command_line_.GetProcessCommandLine()->GetSwitchValuePath(
          "adblock-snapshot-dir");
  if (fixture.empty() || snapshot.empty()) {
    GTEST_SKIP() << "Supply synthetic legacy fixtures and the current snapshot";
  }
  std::string resources;
  ASSERT_TRUE(base::ReadFileToString(snapshot.AppendASCII("resources.json"),
                                     &resources));
  adblock::set_domain_resolver();
  for (const std::string name : {"engine0", "engine1"}) {
    SCOPED_TRACE(name);
    std::string rules;
    ASSERT_TRUE(base::ReadFileToString(fixture.AppendASCII(name + "-rules.txt"),
                                       &rules));
    auto filters = adblock::new_filter_set(false);
    std::vector<unsigned char> bytes(rules.begin(), rules.end());
    ASSERT_EQ(adblock::ResultKind::Success,
              filters->add_filter_list(bytes).result_kind);
    auto original = adblock::engine_from_filter_set(std::move(filters));
    ASSERT_EQ(adblock::ResultKind::Success, original.result_kind);
    auto serialized = original.value->serialize();
    ASSERT_FALSE(serialized.empty());
    const std::vector<unsigned char> dat(serialized.begin(), serialized.end());
    auto restored =
        adblock::engine_from_filter_set(adblock::new_filter_set(false));
    ASSERT_EQ(adblock::ResultKind::Success, restored.result_kind);
    ASSERT_TRUE(restored.value->deserialize(dat));
    auto storage = adblock::new_resource_storage(resources);
    original.value->use_resource_storage(*storage);
    restored.value->use_resource_storage(*storage);
    const std::string youtube = "https://www.youtube.com/watch?v=synthetic";
    const std::string output(restored.value->url_cosmetic_resources(youtube));
    const auto before = base::JSONReader::Read(
        std::string(original.value->url_cosmetic_resources(youtube)),
        base::JSON_PARSE_RFC);
    const auto after = base::JSONReader::Read(output, base::JSON_PARSE_RFC);
    ASSERT_TRUE(before && before->is_dict());
    ASSERT_TRUE(after && after->is_dict());
    // Engine serialization can change the order of set-backed selectors.
    for (const char* key :
         {"hide_selectors", "procedural_actions", "exceptions"}) {
      const auto* left = before->GetDict().FindList(key);
      const auto* right = after->GetDict().FindList(key);
      ASSERT_TRUE(left);
      ASSERT_TRUE(right);
      std::set<std::string> left_set;
      std::set<std::string> right_set;
      for (const auto& value : *left) {
        left_set.insert(value.GetString());
      }
      for (const auto& value : *right) {
        right_set.insert(value.GetString());
      }
      EXPECT_EQ(left_set, right_set);
    }
    if (name == "engine1") {
      EXPECT_NE(std::string::npos, output.find("ytInitialPlayerResponse"));
      // New resources do not add the new get_watch rule to a valid old DAT.
      EXPECT_EQ(std::string::npos, output.find("/get_watch?"));
    }
    ASSERT_TRUE(base::WriteFile(
        fixture.AppendASCII(name + ".dat"),
        std::string(reinterpret_cast<const char*>(dat.data()), dat.size())));
    ASSERT_TRUE(
        base::WriteFile(fixture.AppendASCII(name + "-cosmetic.json"), output));
  }
}

TEST_F(AdBlockDefaultResourceProviderTest, CorruptSerializedEngineIsRejected) {
  adblock::set_domain_resolver();
  auto engine = adblock::engine_from_filter_set(adblock::new_filter_set(false));
  ASSERT_EQ(adblock::ResultKind::Success, engine.result_kind);
  const std::vector<unsigned char> corrupt = {'b', 'r', 'o', 'k', 'e', 'n'};
  EXPECT_FALSE(engine.value->deserialize(corrupt));
  const auto serialized = engine.value->serialize();
  ASSERT_GT(serialized.size(), 24U);
  const std::vector<unsigned char> truncated(serialized.begin(),
                                             serialized.begin() + 24);
  EXPECT_FALSE(engine.value->deserialize(truncated));
}

}  // namespace brave_shields
