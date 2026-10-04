// Copyright (c) 2026 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

#include "brave/components/brave_shields/content/browser/ad_block_startup_gate.h"

#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace brave_shields {

TEST(AdBlockStartupGateTest, CachedRulesWaitForBothResourceLoads) {
  base::test::TaskEnvironment tasks;
  AdBlockStartupGate gate;
  base::test::TestFuture<void> first_document;
  gate.Post(first_document.GetCallback());
  gate.OnRulesLoaded(true);
  gate.OnRulesLoaded(false);
  gate.OnResourcesLoaded(false);
  base::test::TestFuture<void> queued_tasks;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, queued_tasks.GetCallback());
  ASSERT_TRUE(queued_tasks.Wait());
  EXPECT_FALSE(first_document.IsReady());
  gate.OnResourcesLoaded(true);
  EXPECT_TRUE(first_document.Wait());
}

TEST(AdBlockStartupGateTest, ResourcesDoNotReleaseBeforeRuleParsing) {
  base::test::TaskEnvironment tasks;
  AdBlockStartupGate gate;
  base::test::TestFuture<void> first_document;
  gate.Post(first_document.GetCallback());
  gate.OnResourcesLoaded(true);
  gate.OnResourcesLoaded(false);
  gate.OnRulesLoaded(true);
  base::test::TestFuture<void> queued_tasks;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, queued_tasks.GetCallback());
  ASSERT_TRUE(queued_tasks.Wait());
  EXPECT_FALSE(first_document.IsReady());
  gate.OnRulesLoaded(false);
  EXPECT_TRUE(first_document.Wait());
}

TEST(AdBlockStartupGateTest, LaterDocumentsAndUpdatesDoNotWaitAgain) {
  base::test::TaskEnvironment tasks;
  AdBlockStartupGate gate;
  for (bool is_default : {true, false}) {
    gate.OnRulesLoaded(is_default);
    gate.OnResourcesLoaded(is_default);
  }
  base::test::TestFuture<void> later_document;
  gate.Post(later_document.GetCallback());
  EXPECT_TRUE(later_document.Wait());
  gate.OnRulesLoaded(false);
  gate.OnResourcesLoaded(false);
  base::test::TestFuture<void> after_update;
  gate.Post(after_update.GetCallback());
  EXPECT_TRUE(after_update.Wait());
}

}  // namespace brave_shields
