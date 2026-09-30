# Copyright (c) 2026 The Brave Authors. All rights reserved.
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at https://mozilla.org/MPL/2.0/.
"""Configuration schema and items composing brave-core's `.env` file.
"""

from __future__ import annotations

from config import ConfigGroup, Dict, Static, config_item_context

# The remote build execution service.
RBE_SERVICE = 'rbe.ba.brave.com:443'


def BaseConfig(USE_REMOTEEXEC=False, SISO_CACHE_DIR='', RBE_JOBS_LIMIT=0):
    # Schema arguments come from the module's properties, see
    # `BraveCoreCheckoutApi.get_config_defaults`.
    return ConfigGroup(
        # A `None` value is left out of the rendered `.env`.
        dotenv=Dict(value_type=(str, type(None))),
        USE_REMOTEEXEC=Static(bool(USE_REMOTEEXEC)),
        SISO_CACHE_DIR=Static(str(SISO_CACHE_DIR)),
        RBE_JOBS_LIMIT=Static(int(RBE_JOBS_LIMIT)),
    )


config_ctx = config_item_context(BaseConfig)


@config_ctx(is_root=True)
def BASE(c):
    c.dotenv['use_remoteexec'] = str(c.USE_REMOTEEXEC).lower()
    if not c.USE_REMOTEEXEC:
        return
    c.dotenv['rbe_service'] = RBE_SERVICE
    # Unset values are left out, for `config.ts` to default them.
    c.dotenv['rbe_jobs_limit'] = (str(c.RBE_JOBS_LIMIT)
                                  if c.RBE_JOBS_LIMIT else None)
    c.dotenv['siso_cache_dir'] = c.SISO_CACHE_DIR or None


@config_ctx()
def brave(c):
    # The configuration of a brave-core checkout. `BASE` applies underneath; the
    # defaults to share between builds belong here.
    del c  # Nothing to add yet.


@config_ctx()
def asan(c):
    c.dotenv['is_asan'] = 'true'
