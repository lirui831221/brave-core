# Copyright (c) 2026 The Brave Authors. All rights reserved.
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at https://mozilla.org/MPL/2.0/.
"""The `brave_core_checkout` module API."""

from __future__ import annotations

from collections.abc import Iterable
import contextlib
import functools
import json
import logging
import re
from pathlib import Path, PurePosixPath

import config_types
from PB.recipe_modules.brave.brave_core_checkout.properties import (
    InputProperties)
from recipe_api import RecipeApi

# Default SSH remote for the brave-core repository.
REPO_URL = 'git@github.com:brave/brave-core.git'

# The brave-core ref checked out when no `brave_core_ref` property is given.
DEFAULT_BRAVE_CORE_REF = 'master'

# The url used by git-cache for brave-core.
CACHE_REPO_URL = 'https://github.com/brave/brave-core.git'

# Flags we want passed in every fetch.
FETCH_ARGS = ('--no-show-forced-updates', )

# The brave-core tree deployed for recipes: scripts, vpython spec and all.
CR_PATH = 'tools/cr'

# The path in brave-core for the bootstrap scripts that may be added to PATH.
BOOTSTRAP_PATH = f'{CR_PATH}/bootstrap'


# What a branch or tag name may look like. It must not start with `-`, so that
# git never reads it as an option.
_REF_RE = re.compile(r'[A-Za-z0-9_][A-Za-z0-9._/-]*')


def _is_tag_ref(ref: str) -> bool:
    """Whether *ref* looks like a brave-core release tag (e.g. `v1.80.100`),
    as opposed to a branch name."""
    return bool(re.fullmatch(r'v\d+(\.\d+)+', ref))


# The suites the asan CI jobs run for brave-core: unit, browser and interactive
# UI tests, plus the network audit.
TEST_SUITES = ('brave_all_unit_tests', 'brave_browser_tests',
               'brave_interactive_ui_tests', 'brave_network_tests')

# Fingerprint of a deployed Chromium `src/`.
CHROME_VERSION_FILE = 'chrome/VERSION'


class BraveCoreCheckoutApi(RecipeApi):
    """Checks out brave-core, either in full (`checkout`) or as a shallow,
    sparse deployment of a few subpaths (`deploy`).

    Instead of cloning the whole (large) repository, this fetches just enough
    history and only the requested subtrees, so a recipe can use a handful of
    paths (scripts, configs, ...) without paying for a full checkout. The flow
    matches a manual:

        git clone --depth 2 --filter=blob:none --sparse <url> <dest>
        git -C <dest> sparse-checkout set <path>...

    `--filter=blob:none` defers blob downloads until checkout, `--sparse` starts
    the working tree with only top-level files (cone mode), and
    `sparse-checkout set` then materialises exactly the requested directories.
    """

    @contextlib.contextmanager
    def _bootstrap_layout(self):
        """Put brave-core's `bootstrap` dir first on `PATH` within the block.
        """
        with self.m.context(
                env_prefixes={'PATH': [self._root / BOOTSTRAP_PATH]}):
            yield

    def __init__(self, properties: InputProperties) -> None:
        super().__init__()
        # The brave-core ref to check out, `master` when none was provided.
        self._brave_core_ref: str = (properties.brave_core_ref
                                     or DEFAULT_BRAVE_CORE_REF)
        self._properties = properties
        self._root: Path | None = None

    @property
    def _ref(self) -> str:
        """The `brave_core_ref`, checked to be safe to pass to git."""
        if not _REF_RE.fullmatch(self._brave_core_ref):
            raise ValueError(
                f'invalid brave_core_ref: {self._brave_core_ref!r}')
        return self._brave_core_ref

    def initialise(self) -> None:
        # The brave-core root of the standard job layout, resolved once.
        self._root = self.m.path.abs(self.m.path.brave_core)

    def get_config_defaults(self) -> dict:
        # The module's properties are the defaults of the `.env` config.
        return {
            'USE_REMOTEEXEC': self._properties.use_remoteexec,
            'SISO_CACHE_DIR': self._properties.siso_cache_dir,
            'RBE_JOBS_LIMIT': self._properties.rbe_jobs_limit,
        }

    def _write_dotenv(self) -> None:
        """Write the `.env` config, if one was set, to the checkout."""
        if self.c is None:
            return
        entries = {
            k: v
            for k, v in sorted(self.c.dotenv.items()) if v is not None
        }
        # A line break would start another entry.
        for k, v in entries.items():
            if any(c in f'{k}{v}' for c in '\r\n'):
                raise ValueError(f'line break in .env entry {k!r}')
        lines = [f'{k}={v}' for k, v in entries.items()]
        text = '\n'.join(lines) + '\n'
        logging.info('Writing %s:\n%s', self._root / '.env', text)
        self.m.file.write_text('write .env', self._root / '.env', text)

    def _with_bootstrap_path(fn):
        """A decorator for functions that require bootstrap layout on $PATH."""

        @functools.wraps(fn)
        def inner(self, *args, **kwargs):
            with self._bootstrap_layout():
                return fn(self, *args, **kwargs)

        return inner

    def _with_chromium_layout(fn):
        """A decorator for the Chromium layout on $PATH."""

        @functools.wraps(fn)
        def inner(self, *args, **kwargs):
            with self.m.chromium_checkout.chromium_layout():
                return fn(self, *args, **kwargs)

        return inner

    def checkout(self) -> Path:
        """Ensure a full brave-core checkout on the `brave_core_ref`, via git
        cache.

        The `brave_core_ref` module property is a branch (`master`, `1.80.x`) or
        release tag (`v1.80.100`); `master` if unset.

        Returns:
            The absolute `Path` to the brave-core checkout root.
        """
        populate_ref, mirror_dir = self._populate_mirror(self._ref)
        return self._checkout_from_mirror(self._ref, populate_ref, mirror_dir)

    def _populate_mirror(self, ref: str) -> tuple[str, str]:
        """Populate the brave-core git cache mirror with *ref*.

        Returns:
            The ref as named in the mirror, and the mirror's directory.
        """
        # A tag is mirrored and fetched by its fully-qualified name; a branch
        # is already covered by the mirror's `refs/heads/*`.
        populate_ref = f'refs/tags/{ref}' if _is_tag_ref(ref) else ref

        # `git cache` comes from depot_tools.
        self.m.depot_tools.ensure_on_path()
        self.m.git_cache.populate(CACHE_REPO_URL, ref=populate_ref)
        return populate_ref, self.m.git_cache.mirror_dir(CACHE_REPO_URL)

    def _checkout_from_mirror(self, ref: str, populate_ref: str,
                              mirror_dir: str) -> Path:
        """Clone or update the brave-core checkout from the populated mirror."""
        dest = self._root
        is_tag = _is_tag_ref(ref)

        if self.m.path.is_dir(dest / '.git'):
            self.m.step('point origin at git cache',
                        ['git', 'remote', 'set-url', 'origin', mirror_dir],
                        cwd=dest)
            fetch_spec = f'{populate_ref}:{populate_ref}' if is_tag else ref
            fetch_cmd = ['git', 'fetch', *FETCH_ARGS]
            if is_tag:
                fetch_cmd.append('--no-tags')
            self.m.step('fetch brave-core ref',
                        [*fetch_cmd, 'origin', fetch_spec],
                        cwd=dest)
            self.m.step('checkout brave-core ref',
                        ['git', 'checkout', '--force', 'FETCH_HEAD'],
                        cwd=dest)
        else:
            self.m.path.mkdir(dest.parent)
            self.m.step('clone brave-core from git cache', [
                'git', 'clone', '--no-checkout', '--local', '--shared',
                mirror_dir, dest
            ])
            self.m.git.disable_auto_gc(dest)
            self.m.step('checkout brave-core ref',
                        ['git', 'checkout', '--force', populate_ref, '--'],
                        cwd=dest)
        # `origin` may point at the local mirror; pushes still go to the real
        # remote.
        self.m.step(
            'restore origin push url',
            ['git', 'remote', 'set-url', '--push', 'origin', CACHE_REPO_URL],
            cwd=dest)
        return dest

    def ensure_checkout(self,
                        *,
                        chromium_src: str | Path | None = None) -> Path:
        """Check out brave-core on `brave_core_ref` and Chromium, then sync if
        needed.

        Chromium is deployed first: brave-core lives inside Chromium's `src/`,
        and a Chromium clone cannot go into a directory that already holds
        brave-core. If Chromium had to be deployed, `pnpm run sync` then brings
        it to the version brave-core pins.

        Args:
            chromium_src: Chromium `src/` directory. Defaults to the `path`
                module's `chromium_src`.

        Returns:
            The absolute `Path` to the brave-core checkout root.
        """
        populate_ref, mirror_dir = self._populate_mirror(self._ref)
        # The Chromium tag is read straight from the mirror, as brave-core
        # cannot be checked out ahead of Chromium.
        deployed = self._deploy_chromium(chromium_src, mirror_dir,
                                         populate_ref)
        root = self._checkout_from_mirror(self._ref, populate_ref, mirror_dir)
        # Before `pnpm run sync`, which already needs the RBE settings.
        self._write_dotenv()
        if deployed:
            self._pnpm_sync()
        return root

    def _deploy_chromium(self, chromium_src: str | Path | None,
                         mirror_dir: str, rev: str) -> bool:
        """Deploy Chromium through `chromium_checkout`, unless present.

        Cloned from git cache at the tag brave-core pins, without `gclient
        sync`.

        Args:
            chromium_src: Chromium `src/` directory, or the default.
            mirror_dir: The brave-core git cache mirror to read the pinned tag
                from.
            rev: The brave-core revision, in the mirror, to read it at.

        Returns:
            Whether Chromium was deployed (`chrome/VERSION` was absent).
        """
        chromium_src = self.m.path.abs(chromium_src if chromium_src is not None
                                       else self.m.path.chromium_src)
        if self.m.path.exists(chromium_src / CHROME_VERSION_FILE):
            return False
        self.m.chromium_checkout.ensure_checkout(chromium_src=chromium_src,
                                                 ref=self._chromium_tag(
                                                     mirror_dir, rev),
                                                 run_sync=False)
        return True

    def _chromium_tag(self, mirror_dir: str, rev: str) -> str:
        """The Chromium tag `package.json` pins at *rev*, read with `git show`.
        """
        result = self.m.step(
            'read chromium tag',
            ['git', '--git-dir', mirror_dir, 'show', f'{rev}:package.json'],
            stdout=self.m.raw_io.output_text(),
            step_test_data=lambda: self.m.raw_io.test_api.stream_output_text(
                self.test_api.package_json()))
        return json.loads(result.stdout)['config']['projects']['chrome']['tag']

    @_with_bootstrap_path
    @_with_chromium_layout
    def _pnpm_sync(self) -> None:
        """Bring Chromium to the version brave-core pins, with `pnpm run sync`.
        """
        self.m.step('pnpm run sync', ['pnpm', 'run', 'sync'], cwd=self._root)

    @_with_bootstrap_path
    @_with_chromium_layout
    def compile(self, *, target: str = 'brave:all') -> None:
        """Build *target* with `pnpm run build`, in an existing checkout.

        Args:
            target: The build target; `brave:all` by default.
        """
        self.m.step('build', ['pnpm', 'run', 'build', f'--target={target}'],
                    cwd=self._root)

    @_with_bootstrap_path
    @_with_chromium_layout
    def run_tests(self, suites: Iterable[str] = TEST_SUITES) -> None:
        """Run each of *suites* with `pnpm run test`, in an existing checkout.

        Every suite runs even if an earlier one fails; the failures are raised
        together at the end. On Linux the tests run under Xvfb.

        Args:
            suites: The test suites to run; by default those of the asan CI
                jobs.

        Raises:
            RuntimeError: If any suite failed.
        """
        xvfb = []
        if self.m.platform.is_linux:
            xvfb = [
                self.m.depot_tools.vpython3(),
                self.m.path.chromium_src / 'testing' / 'xvfb.py'
            ]
        failed = []
        for suite in suites:
            cmd = [
                *xvfb, 'pnpm', 'run', 'test', suite, '--output_xml',
                '--test-launcher-bot-mode',
                f'--test-launcher-jobs={self.m.platform.cpu_count}'
            ]
            result = self.m.step(f'test {suite}',
                                 cmd,
                                 cwd=self._root,
                                 check=False)
            if result.retcode != 0:
                failed.append(suite)
        if failed:
            raise RuntimeError(f'test suites failed: {", ".join(failed)}')

    def deploy(self,
               paths: str | Path | Iterable[str | Path],
               *,
               url: str = REPO_URL,
               depth: int = 2) -> Path:
        """Ensure *paths* from brave-core are checked out.

        Clones brave-core (shallow + sparse) when it is not already
        a checkout, then restricts the working tree to *paths*. Re-running is
        cheap: an existing checkout is reused, fetched to the `brave_core_ref`, and only the
        sparse set is re-applied -- so a checkout left on a different ref by a
        prior run is brought to the requested one rather than trusted as-is.

        Every requested path keeps its brave-core-relative layout beneath the
        returned root (a path `tools/a` lands at `<root>/tools/a`), so scripts
        deployed in one path can reference sibling paths exactly as they do in a
        full checkout, with no rewriting. Paths accumulate: each call extends
        the working tree via `sparse-checkout add`, so subtrees checked out by
        an earlier call -- or by an external bootstrap sharing this same
        checkout -- coexist rather than being replaced.

        Args:
            paths: A single repo-relative path, or an iterable of them, to
                materialise (e.g. `'tools/cr'`).
            url: Git remote to clone from; defaults to brave-core over SSH.
            depth: History depth for the shallow clone/fetch.

        Returns:
            The absolute `Path` to the brave-core checkout root. Requested paths
            live beneath it at their original repo-relative locations.

        Raises:
            ValueError: If *paths* is empty.
            RuntimeError: If a requested path is absent after the checkout
                (e.g. a typo or a path that does not exist on *ref*).
        """
        single = isinstance(paths, (str, Path, config_types.Path))
        rel_paths = [str(paths)] if single else [str(p) for p in paths]
        if not rel_paths:
            raise ValueError('deploy() requires at least one path')

        # Fall back to the engine-provided ref when the caller doesn't specify.
        ref = self._ref

        dest = self._root

        if self.m.path.is_dir(dest / '.git'):
            # Reuse the existing checkout, but bring it to *ref* -- it may have
            # been cloned (here or by a prior run) at a different ref that lacks
            # the requested paths, so fetch and hard-checkout rather than trust
            # its current state.
            logging.info('brave-core checkout present at %s; updating to %s',
                         dest, ref)
            self.m.step('fetch brave-core ref', [
                'git', '-C',
                str(dest), 'fetch', '--depth',
                str(depth), 'origin', ref
            ])
            self.m.step(
                'checkout brave-core ref',
                ['git', '-C',
                 str(dest), 'checkout', '--force', 'FETCH_HEAD'])
        else:
            self.m.path.mkdir(dest.parent)
            clone_cmd = [
                'git', 'clone', '--depth',
                str(depth), '--filter=blob:none', '--sparse', '--branch', ref,
                url,
                str(dest)
            ]
            self.m.step('clone brave-core (shallow, sparse)', clone_cmd)

        # Ask the checkout which subtrees are already present and drop any
        # request it (or an ancestor) already covers, so a path is never
        # deployed twice.
        deployed = {PurePosixPath(d) for d in self._sparse_checkout_list(dest)}
        new_paths = []
        for p in rel_paths:
            lineage = PurePosixPath(p)
            # Covered when the path itself, or a deployed ancestor, is in the
            # sparse set: a cone entry brings its whole subtree.
            if deployed.isdisjoint((lineage, *lineage.parents)):
                new_paths.append(p)

        if new_paths:
            # Extend the sparse working tree with the not-yet-present subtrees.
            # `add` (rather than `set`) accumulates, so subtrees checked out by
            # a prior call or an external bootstrap into this checkout survive.
            self.m.step(
                'sparse-checkout add',
                ['git', '-C',
                 str(dest), 'sparse-checkout', 'add', *new_paths])

        for rel in rel_paths:
            if not self.m.path.exists(dest / rel):
                raise RuntimeError(
                    f'brave-core path not found after sparse checkout: {rel!r} '
                    f'(looked under {dest})')

        return dest

    def _sparse_checkout_list(self, dest: Path) -> set[str]:
        """Return the checkout's current cone-mode sparse directories.

        Empty when the sparse set lists nothing (e.g. a just-cloned tree whose
        cone is still empty) or is uninitialised. Non-zero is treated as
        "nothing deployed yet" rather than an error.
        """
        result = self.m.step(
            'sparse-checkout list',
            ['git', '-C', str(dest), 'sparse-checkout', 'list'],
            check=False,
            stdout=self.m.raw_io.output_text())
        if result.retcode != 0 or not result.stdout:
            return set()
        return {
            line.strip()
            for line in result.stdout.splitlines() if line.strip()
        }

    @contextlib.contextmanager
    def bootstrap_on_path(self,
                          *,
                          url: str = REPO_URL,
                          depth: int = 2):
        """Deploy `tools/cr`, putting its `bootstrap` dir first on PATH in the block.

        Args:
            url, depth: Forwarded to `deploy` (see its docs).

        Yields:
            The absolute `Path` to the brave-core checkout root.
        """
        root = self.deploy(CR_PATH, url=url, depth=depth)
        with self.m.context(env_prefixes={'PATH': [root / BOOTSTRAP_PATH]}):
            yield root
