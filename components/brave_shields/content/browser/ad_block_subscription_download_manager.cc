// Copyright (c) 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

#include "brave/components/brave_shields/content/browser/ad_block_subscription_download_manager.h"

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/metrics/histogram_functions.h"
#include "base/uuid.h"
#include "brave/components/brave_shields/core/common/adblock/rs/src/lib.rs.h"
#include "brave/components/brave_shields/core/common/brave_shield_constants.h"
#include "build/build_config.h"
#include "components/download/public/background_service/background_download_service.h"
#include "net/traffic_annotation/network_traffic_annotation.h"

namespace brave_shields {

namespace {

bool IsValidListFile(const base::FilePath& file) {
  std::string text;
  // Bound untrusted downloads before parsing them on the background sequence.
  if (!base::ReadFileToStringWithMaxSize(file, &text, 64 * 1024 * 1024)) {
    return false;
  }
  const std::vector<uint8_t> bytes(text.begin(), text.end());
  return adblock::validate_filter_list(bytes);
}

std::string ValidateAndReplaceList(const base::FilePath& downloaded_file,
                                   const base::FilePath& destination) {
  if (!IsValidListFile(downloaded_file)) {
    return "invalid_list";
  }
  if (!base::CreateDirectory(destination.DirName())) {
    return "cache_directory_failed";
  }
  if (!base::ReplaceFile(downloaded_file, destination, nullptr)) {
    return "cache_replace_failed";
  }
  return {};
}

const net::NetworkTrafficAnnotationTag
    kBraveShieldsAdBlockSubscriptionTrafficAnnotation =
        net::DefineNetworkTrafficAnnotation(
            "brave_shields_ad_block_subscription",
            R"(
        semantics {
          sender: "Brave Shields"
          description:
            "Brave periodically downloads updates to third-party filter lists "
            "added by users on brave://adblock."
          trigger:
            "After being registered in brave://adblock, any enabled filter "
            "list subscriptions will be updated in accordance with their "
            "`Expires` field if present, or daily otherwise. A manual refresh "
            "for a particular list can also be triggered in brave://adblock."
          data: "The URL endpoint provided by the user in brave://adblock to "
            "fetch list updates from. No user information is sent."
          destination: BRAVE_OWNED_SERVICE
        }
        policy {
          cookies_allowed: NO
          setting:
            "This request cannot be disabled in settings. However it will "
            "never be made if the corresponding entry is removed from the "
            "brave://adblock page's custom list subscription section."
          policy_exception_justification: "Not yet implemented."
        })");

}  // namespace

AdBlockSubscriptionDownloadManager::AdBlockSubscriptionDownloadManager(
    download::BackgroundDownloadService* download_service,
    scoped_refptr<base::SequencedTaskRunner> background_task_runner)
    : download_service_(download_service),
      is_available_for_downloads_(true),
      background_task_runner_(background_task_runner) {}

AdBlockSubscriptionDownloadManager::~AdBlockSubscriptionDownloadManager() =
    default;

void AdBlockSubscriptionDownloadManager::StartDownload(const GURL& download_url,
                                                       bool from_ui) {
  download::DownloadParams download_params;
  download_params.client = download::DownloadClient::CUSTOM_LIST_SUBSCRIPTIONS;
  download_params.guid = base::Uuid::GenerateRandomV4().AsLowercaseString();
  download_params.callback = base::BindRepeating(
      &AdBlockSubscriptionDownloadManager::OnDownloadStarted, AsWeakPtr(),
      download_url);
  download_params.traffic_annotation = net::MutableNetworkTrafficAnnotationTag(
      kBraveShieldsAdBlockSubscriptionTrafficAnnotation);
  download_params.request_params.url = download_url;
  download_params.request_params.method = "GET";
  if (from_ui) {
    // This triggers a high priority download with no network restrictions to
    // provide status feedback as quickly as possible.
    download_params.scheduling_params.priority =
        download::SchedulingParams::Priority::UI;
    download_params.scheduling_params.battery_requirements =
        download::SchedulingParams::BatteryRequirements::BATTERY_INSENSITIVE;
    download_params.scheduling_params.network_requirements =
        download::SchedulingParams::NetworkRequirements::NONE;
  } else {
    download_params.scheduling_params.priority =
        download::SchedulingParams::Priority::NORMAL;
    download_params.scheduling_params.battery_requirements =
        download::SchedulingParams::BatteryRequirements::BATTERY_INSENSITIVE;
    download_params.scheduling_params.network_requirements =
        download::SchedulingParams::NetworkRequirements::OPTIMISTIC;
  }

  download_service_->StartDownload(std::move(download_params));
}

void AdBlockSubscriptionDownloadManager::CancelAllPendingDownloads() {
  for (const std::pair<std::string, GURL> pending_download :
       pending_download_guids_) {
    const std::string& pending_download_guid = pending_download.first;
    download_service_->CancelDownload(pending_download_guid);
  }
}

bool AdBlockSubscriptionDownloadManager::IsAvailableForDownloads() const {
  return is_available_for_downloads_;
}

base::WeakPtr<AdBlockSubscriptionDownloadManager>
AdBlockSubscriptionDownloadManager::AsWeakPtr() {
  return weak_ptr_factory_.GetWeakPtr();
}

void AdBlockSubscriptionDownloadManager::Shutdown() {
  is_available_for_downloads_ = false;
  CancelAllPendingDownloads();
  // notify
}

void AdBlockSubscriptionDownloadManager::OnDownloadServiceReady(
    const std::set<std::string>& pending_download_guids,
    const std::map<std::string, base::FilePath>& successful_downloads) {
  // Ignore any pending guids because they will just retry automatically
  // and we we don't have the url to map them to
}

void AdBlockSubscriptionDownloadManager::OnDownloadServiceUnavailable() {
  is_available_for_downloads_ = false;
}

void AdBlockSubscriptionDownloadManager::OnDownloadStarted(
    const GURL download_url,
    const std::string& guid,
    download::DownloadParams::StartResult start_result) {
  if (start_result == download::DownloadParams::StartResult::ACCEPTED) {
    pending_download_guids_.insert(
        std::pair<std::string, GURL>(guid, download_url));
  } else {
    // Rejected scheduling must update the failure state so the timer retries.
    ReportFailure(download_url, "scheduling_failed");
  }
}

void AdBlockSubscriptionDownloadManager::OnDownloadFailed(
    const std::string& guid,
    const std::string& reason) {
  auto it = pending_download_guids_.find(guid);
  if (it == pending_download_guids_.end()) {
    return;
  }
  GURL download_url = it->second;
  pending_download_guids_.erase(guid);

  base::UmaHistogramBoolean(
      "BraveShields.AdBlockSubscriptionDownloadManager.DownloadSucceeded",
      false);

  ReportFailure(download_url, reason);
}

void AdBlockSubscriptionDownloadManager::OnDownloadSucceeded(
    const std::string& guid,
    base::FilePath downloaded_file) {
  auto it = pending_download_guids_.find(guid);
  if (it == pending_download_guids_.end()) {
    return;
  }
  GURL download_url = it->second;
  pending_download_guids_.erase(guid);

  base::UmaHistogramBoolean(
      "BraveShields.AdBlockSubscriptionDownloadManager.DownloadSucceeded",
      true);

  const auto destination = subscription_path_callback_.Run(download_url)
                               .Append(kCustomSubscriptionListText);
  background_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&ValidateAndReplaceList, downloaded_file, destination),
      base::BindOnce(&AdBlockSubscriptionDownloadManager::ReplaceFileCallback,
                     AsWeakPtr(), download_url));
}

void AdBlockSubscriptionDownloadManager::ReplaceFileCallback(
    const GURL& download_url, std::string error) {
  if (!error.empty()) {
    ReportFailure(download_url, error);
    return;
  }
  last_errors_.erase(download_url);
  cache_status_[download_url] = 1;
  on_download_succeeded_callback_.Run(download_url);
}

void AdBlockSubscriptionDownloadManager::ReportFailure(
    const GURL& url, const std::string& reason) {
  background_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&IsValidListFile, subscription_path_callback_.Run(url)
                                         .Append(kCustomSubscriptionListText)),
      base::BindOnce(&AdBlockSubscriptionDownloadManager::OnFailureCacheChecked,
                     AsWeakPtr(), url, reason));
}

void AdBlockSubscriptionDownloadManager::OnFailureCacheChecked(
    const GURL& url, const std::string& reason, bool valid) {
  last_errors_[url] = reason;
  cache_status_[url] = valid ? 1 : 0;
  on_download_failed_callback_.Run(url);
}

std::string AdBlockSubscriptionDownloadManager::GetLastError(
    const GURL& url) const {
  auto it = last_errors_.find(url);
  return it == last_errors_.end() ? std::string() : it->second;
}

int AdBlockSubscriptionDownloadManager::GetCacheStatus(const GURL& url) const {
  auto it = cache_status_.find(url);
  return it == cache_status_.end() ? -1 : it->second;
}

void AdBlockSubscriptionDownloadManager::CheckCache(
    const GURL& url, base::OnceClosure on_checked) {
  cache_status_[url] = -1;
  background_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&IsValidListFile, subscription_path_callback_.Run(url)
                                         .Append(kCustomSubscriptionListText)),
      base::BindOnce(&AdBlockSubscriptionDownloadManager::OnCacheChecked,
                     AsWeakPtr(), url, std::move(on_checked)));
}

void AdBlockSubscriptionDownloadManager::OnCacheChecked(
    const GURL& url, base::OnceClosure on_checked, bool valid) {
  cache_status_[url] = valid ? 1 : 0;
  std::move(on_checked).Run();
}

}  // namespace brave_shields
