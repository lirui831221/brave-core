/* Copyright (c) 2023 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

#ifndef BRAVE_BROWSER_BRAVE_ADS_SERVICES_BAT_ADS_SERVICE_FACTORY_IMPL_H_
#define BRAVE_BROWSER_BRAVE_ADS_SERVICES_BAT_ADS_SERVICE_FACTORY_IMPL_H_

#include "base/memory/ref_counted.h"
#include "base/memory/scoped_refptr.h"
#include "base/synchronization/atomic_flag.h"
#include "brave/components/brave_ads/browser/bat_ads_service_factory.h"
#include "brave/components/services/bat_ads/public/interfaces/bat_ads.mojom.h"
#include "mojo/public/cpp/bindings/remote.h"

namespace brave_ads {

class BatAdsServiceFactoryImpl final : public BatAdsServiceFactory {
 public:
  BatAdsServiceFactoryImpl();

  BatAdsServiceFactoryImpl(const BatAdsServiceFactoryImpl&) = delete;
  BatAdsServiceFactoryImpl& operator=(const BatAdsServiceFactoryImpl&) = delete;

  ~BatAdsServiceFactoryImpl() override;

  // BatAdsServiceFactory:
  mojo::Remote<bat_ads::mojom::BatAdsService> Launch() const override;
  void Invalidate() const override;

 private:
  // Set whenever a new `Launch()` supersedes the previous one, or when
  // `Invalidate()` is called, so a still-pending delayed bind becomes a
  // no-op instead of constructing a stale service. Ref-counted (rather than
  // owned solely by `this`) because the flag must remain valid even if
  // `BatAdsServiceFactoryImpl` is destroyed while a delayed bind is still
  // pending on its own dedicated thread; mirrors
  // `base::CancelableTaskTracker`'s internal `TaskCancellationFlag` for the
  // same cross-sequence-outlives-owner scenario.
  mutable scoped_refptr<base::RefCountedData<base::AtomicFlag>>
      cancellation_flag_;
};

}  // namespace brave_ads

#endif  // BRAVE_BROWSER_BRAVE_ADS_SERVICES_BAT_ADS_SERVICE_FACTORY_IMPL_H_
