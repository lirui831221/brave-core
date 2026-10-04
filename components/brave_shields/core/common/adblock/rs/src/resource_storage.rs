/* Copyright (c) 2025 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

use adblock::resources::{InMemoryResourceStorage, Resource, ResourceImpl, ResourceStorageBackend};
use cxx::CxxString;
use std::sync::Arc;

/// A wrapper around the inner storage to share ownership of the inner storage.
#[derive(Clone)]
pub struct BraveCoreResourceStorage {
    shared_storage: Arc<InMemoryResourceStorage>,
    has_resources: bool,
}

impl ResourceStorageBackend for BraveCoreResourceStorage {
    fn get_resource(&self, resource_ident: &str) -> Option<ResourceImpl> {
        self.shared_storage.get_resource(resource_ident)
    }
}

/// Creates a new ResourceStorage from JSON string.
pub fn new_resource_storage(resources_json: &CxxString) -> Box<BraveCoreResourceStorage> {
    let resources = serde_json::from_str::<Vec<Resource>>(resources_json.to_str().unwrap_or("[]"))
        .unwrap_or_default();
    let mut has_resources = !resources.is_empty();
    let mut in_memory_storage = InMemoryResourceStorage::default();
    for resource in resources {
        has_resources &= in_memory_storage.add_resource(resource).is_ok();
    }
    let shared_storage = Arc::new(in_memory_storage);
    Box::new(BraveCoreResourceStorage { shared_storage, has_resources })
}

/// Creates a new empty ResourceStorage.
pub fn new_empty_resource_storage() -> Box<BraveCoreResourceStorage> {
    let in_memory_storage = InMemoryResourceStorage::from_resources(vec![]);
    let shared_storage = Arc::new(in_memory_storage);
    Box::new(BraveCoreResourceStorage { shared_storage, has_resources: false })
}

/// Clones a BraveCoreResourceStorage.
/// Clones only the Arc-based wrapper, the inner storage remains shared.
pub fn clone_resource_storage(storage: &BraveCoreResourceStorage) -> Box<BraveCoreResourceStorage> {
    Box::new(storage.clone())
}

/// Clones and extends a storage with additional resources.
pub fn extend_resource_storage(
    storage: &BraveCoreResourceStorage,
    additional_resources_json: &str,
) -> Box<BraveCoreResourceStorage> {
    if let Ok(additional_resources) =
        serde_json::from_str::<Vec<Resource>>(additional_resources_json)
    {
        if !additional_resources.is_empty() {
            let mut inner_storage = storage.shared_storage.as_ref().clone();

            let mut has_resources = storage.has_resources;
            for resource in additional_resources {
                has_resources &= inner_storage.add_resource(resource).is_ok();
            }
            return Box::new(BraveCoreResourceStorage {
                shared_storage: Arc::new(inner_storage),
                has_resources,
            });
        }
    }
    clone_resource_storage(storage)
}

pub fn has_resource_for_testing(storage: &BraveCoreResourceStorage, name: &CxxString) -> bool {
    storage.get_resource(name.to_str().unwrap_or("")).is_some()
}

/// Empty or malformed resource documents cannot replace a cached rule layer.
pub fn has_resources(storage: &BraveCoreResourceStorage) -> bool {
    storage.has_resources
}
