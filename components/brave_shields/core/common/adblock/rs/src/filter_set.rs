/* Copyright (c) 2023 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

use adblock::{lists::ParseOptions, resources::PermissionMask, FilterSet as InnerFilterSet};
use cxx::CxxVector;

use crate::ffi::{AddFilterListResult, AddedFiltersRecord};
use crate::result::InternalError;

pub struct FilterSet(pub(crate) InnerFilterSet, pub(crate) bool);

impl Default for Box<FilterSet> {
    fn default() -> Self {
        new_filter_set(false)
    }
}

pub fn new_filter_set(debug: bool) -> Box<FilterSet> {
    Box::new(FilterSet(InnerFilterSet::new(debug), true))
}

impl FilterSet {
    // A failed provider must not publish a partially assembled replacement.
    pub fn invalidate(&mut self) {
        self.1 = false;
    }

    pub fn add_filter_list(&mut self, rules: &CxxVector<u8>) -> AddFilterListResult {
        self.add_filter_list_with_permissions(rules, 0)
    }

    pub fn add_filter_list_with_permissions(
        &mut self,
        rules: &CxxVector<u8>,
        permission_mask: u8,
    ) -> AddFilterListResult {
        let result = || -> Result<AddedFiltersRecord, InternalError> {
            Ok(self
                .0
                .add_filter_list(
                    std::str::from_utf8(rules.as_slice())?.to_string(),
                    ParseOptions {
                        permissions: PermissionMask::from_bits(permission_mask),
                        ..Default::default()
                    },
                )
                .into())
        }();
        if result.is_err() {
            self.invalidate();
        }
        result.into()
    }
}

// Validate with the same parser used by the engine, without requiring a header
// or rejecting a list merely because some rules use unsupported syntax.
pub fn validate_filter_list(rules: &CxxVector<u8>) -> bool {
    let Ok(text) = std::str::from_utf8(rules.as_slice()) else {
        return false;
    };
    let text = text.trim_start_matches('\u{feff}').trim();
    if text.is_empty() || text.chars().any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t')) {
        return false;
    }
    if matches!(
        serde_json::from_str::<serde_json::Value>(text),
        Ok(serde_json::Value::Object(_)) | Ok(serde_json::Value::Array(_))
    ) {
        return false;
    }
    let mut has_rule = false;
    let mut has_comment = false;
    let mut has_content = false;
    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        if line.starts_with('!')
            || line.starts_with("[Adblock")
            || line.strip_prefix('#').is_some_and(|s| s.starts_with(char::is_whitespace))
        {
            has_comment = true;
            continue;
        }
        if !has_content {
            // HTML fragments and XML error documents are not subscriptions.
            // Network URL filters cannot begin with an unescaped markup tag;
            // cosmetic selectors and regular expressions have other prefixes.
            let starts_markup = line
                .strip_prefix('<')
                .and_then(|rest| rest.chars().next())
                .is_some_and(|c| c.is_ascii_alphabetic() || matches!(c, '!' | '?' | '/'));
            if starts_markup {
                return false;
            }
        }
        has_content = true;
        has_rule |= adblock::lists::parse_filter(line, false, ParseOptions::default()).is_ok();
    }
    // A comment-only list can intentionally withdraw all its previous rules.
    has_rule || (has_comment && !has_content)
}
