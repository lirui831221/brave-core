// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

#include "brave/components/brave_shields/content/browser/ad_block_subscription_download_manager.h"

#include <utility>

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/task/sequenced_task_runner.h"
#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "brave/components/brave_shields/core/common/brave_shield_constants.h"
#include "build/build_config.h"
#include "components/download/public/background_service/test/mock_download_service.h"
#include "testing/gmock/include/gmock/gmock.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace brave_shields {

class AdBlockSubscriptionDownloadManagerTest : public testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(directory_.CreateUniqueTempDir());
    manager_.set_subscription_path_callback(base::BindRepeating(
        &AdBlockSubscriptionDownloadManagerTest::CacheDirectory,
        base::Unretained(this)));
    manager_.set_on_download_failed_callback(base::BindRepeating(
        &AdBlockSubscriptionDownloadManagerTest::Failed,
        base::Unretained(this)));
    manager_.set_on_download_succeeded_callback(base::BindRepeating(
        &AdBlockSubscriptionDownloadManagerTest::Succeeded,
        base::Unretained(this)));
    ASSERT_TRUE(base::CreateDirectory(CacheDirectory(url_)));
    ASSERT_TRUE(base::WriteFile(CachePath(), "||old-rule.example^\n"));
  }

  base::FilePath CacheDirectory(const GURL&) {
    return directory_.GetPath().AppendASCII("cache");
  }
  base::FilePath CachePath() {
    return CacheDirectory(url_).Append(kCustomSubscriptionListText);
  }
  std::string CachedText() {
    std::string text;
    EXPECT_TRUE(base::ReadFileToString(CachePath(), &text));
    return text;
  }
  void Failed(const GURL& url) {
    EXPECT_EQ(url, url_);
    failed_.SetValue();
  }
  void Succeeded(const GURL& url) {
    EXPECT_EQ(url, url_);
    succeeded_.SetValue();
  }
  void Queue(download::DownloadParams::StartResult result, bool from_ui) {
    EXPECT_CALL(service_, StartDownload_(testing::_))
        .WillOnce([&](download::DownloadParams& params) {
          EXPECT_EQ(params.request_params.url, url_);
          EXPECT_EQ(params.scheduling_params.priority,
                    from_ui ? download::SchedulingParams::Priority::UI
                            : download::SchedulingParams::Priority::NORMAL);
          guid_ = params.guid;
          std::move(params.callback).Run(guid_, result);
        });
    manager_.StartDownload(url_, from_ui);
  }
  void FailDownload() { manager_.OnDownloadFailed(guid_); }
  void CompleteDownload(const base::FilePath& path) {
    manager_.OnDownloadSucceeded(guid_, path);
  }

  base::test::TaskEnvironment environment_;
  base::ScopedTempDir directory_;
  testing::StrictMock<download::test::MockDownloadService> service_;
  AdBlockSubscriptionDownloadManager manager_{
      &service_, base::SequencedTaskRunner::GetCurrentDefault()};
  const GURL url_{"https://lists.example/test.txt"};
  std::string guid_;
  base::test::TestFuture<void> failed_;
  base::test::TestFuture<void> succeeded_;
};

TEST_F(AdBlockSubscriptionDownloadManagerTest, RejectedSchedulingReportsFailure) {
  Queue(download::DownloadParams::StartResult::BACKOFF, false);
  EXPECT_TRUE(failed_.Wait());
  EXPECT_FALSE(succeeded_.IsReady());
  EXPECT_EQ(CachedText(), "||old-rule.example^\n");
}

TEST_F(AdBlockSubscriptionDownloadManagerTest, FailedDownloadPreservesCache) {
  Queue(download::DownloadParams::StartResult::ACCEPTED, true);
  FailDownload();
  EXPECT_TRUE(failed_.Wait());
  EXPECT_EQ(CachedText(), "||old-rule.example^\n");
}

TEST_F(AdBlockSubscriptionDownloadManagerTest, MissingDownloadPreservesCache) {
  Queue(download::DownloadParams::StartResult::ACCEPTED, true);
  CompleteDownload(directory_.GetPath().AppendASCII("missing.txt"));
  EXPECT_TRUE(failed_.Wait());
  EXPECT_FALSE(succeeded_.IsReady());
  EXPECT_EQ(CachedText(), "||old-rule.example^\n");
}

#if BUILDFLAG(IS_POSIX)
TEST_F(AdBlockSubscriptionDownloadManagerTest, FailedReplacementPreservesCache) {
  const auto download = directory_.GetPath().AppendASCII("download.txt");
  ASSERT_TRUE(base::WriteFile(download, "||new-rule.example^\n"));
  const auto cache = CacheDirectory(url_);
  ASSERT_TRUE(base::SetPosixFilePermissions(cache, 0500));
  base::ScopedClosureRunner restore_permissions(base::BindOnce(
      [](const base::FilePath& path) {
        base::SetPosixFilePermissions(path, 0700);
      }, cache));
  Queue(download::DownloadParams::StartResult::ACCEPTED, true);
  CompleteDownload(download);
  ASSERT_TRUE(failed_.Wait());
  EXPECT_FALSE(succeeded_.IsReady());
  EXPECT_EQ(CachedText(), "||old-rule.example^\n");
  EXPECT_EQ(manager_.GetLastError(url_), "cache_replace_failed");
  EXPECT_EQ(manager_.GetCacheStatus(url_), 1);
}
#endif

TEST_F(AdBlockSubscriptionDownloadManagerTest, RetryReplacesCacheAfterFailure) {
  Queue(download::DownloadParams::StartResult::ACCEPTED, false);
  FailDownload();
  ASSERT_TRUE(failed_.Wait());
  const auto download = directory_.GetPath().AppendASCII("download.txt");
  ASSERT_TRUE(base::WriteFile(download, "||new-rule.example^\n"));
  Queue(download::DownloadParams::StartResult::ACCEPTED, false);
  CompleteDownload(download);
  EXPECT_TRUE(succeeded_.Wait());
  EXPECT_EQ(CachedText(), "||new-rule.example^\n");
}

TEST_F(AdBlockSubscriptionDownloadManagerTest, InvalidBodiesPreserveCache) {
  const std::string bodies[] = {"", " \r\n\t", "<html><body>Access denied</body></html>",
      "<h1>Access denied</h1>", "<Error><Code>AccessDenied</Code></Error>",
      "! upstream response\n<!DOCTYPE html>\n<html>Error</html>",
      "{\"error\":\"denied\"}", std::string("\xff\xfe", 2),
      std::string("||new.example^\0bad", 18), "||new.example^$not-a-real-option"};
  for (const auto& body : bodies) {
    SCOPED_TRACE(body);
    failed_.Clear();
    const auto path = directory_.GetPath().AppendASCII("invalid.txt");
    ASSERT_TRUE(base::WriteFile(path, body));
    Queue(download::DownloadParams::StartResult::ACCEPTED, true);
    CompleteDownload(path);
    ASSERT_TRUE(failed_.Wait());
    EXPECT_FALSE(succeeded_.IsReady());
    EXPECT_EQ(CachedText(), "||old-rule.example^\n");
    EXPECT_EQ(manager_.GetLastError(url_), "invalid_list");
    EXPECT_EQ(manager_.GetCacheStatus(url_), 1);
  }
}

TEST_F(AdBlockSubscriptionDownloadManagerTest, AcceptsCompatibleListForms) {
  const std::string bodies[] = {"||new.example^\n", "example.com##.advert\n",
      "! deliberately empty list\n", "[Adblock Plus 2.0]\n! comment\n",
      "\xef\xbb\xbf! Unicode comment 测试\n||new.example^\n",
      "||new.example^\n||other.example^$not-a-real-option\n"};
  for (const auto& body : bodies) {
    SCOPED_TRACE(body);
    succeeded_.Clear();
    const auto path = directory_.GetPath().AppendASCII("valid.txt");
    ASSERT_TRUE(base::WriteFile(path, body));
    Queue(download::DownloadParams::StartResult::ACCEPTED, true);
    CompleteDownload(path);
    ASSERT_TRUE(succeeded_.Wait());
    EXPECT_FALSE(failed_.IsReady());
    EXPECT_EQ(CachedText(), body);
    EXPECT_TRUE(manager_.GetLastError(url_).empty());
    EXPECT_EQ(manager_.GetCacheStatus(url_), 1);
  }
}

TEST_F(AdBlockSubscriptionDownloadManagerTest, ReportsMissingCacheAfterFailure) {
  // A separate subscription has no previous download to retain.
  manager_.set_subscription_path_callback(base::BindRepeating(
      [](const base::FilePath& root, const GURL&) { return root.AppendASCII("empty"); },
      directory_.GetPath()));
  Queue(download::DownloadParams::StartResult::BACKOFF, false);
  ASSERT_TRUE(failed_.Wait());
  EXPECT_EQ(manager_.GetCacheStatus(url_), 0);
  EXPECT_EQ(manager_.GetLastError(url_), "scheduling_failed");
}

}  // namespace brave_shields
