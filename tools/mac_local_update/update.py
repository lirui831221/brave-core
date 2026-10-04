#!/usr/bin/env python3
"""Explicit GitHub release checks and verified staging for the local Mac build.

No credentials, profile reads, background jobs, or automatic installation.
Repository HTTPS and GitHub asset digests are not a publisher signing identity.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import unicodedata
from urllib.parse import urlsplit
import zipfile

REPOSITORY = 'lirui831221/brave-core'
BASELINE = 'mac-brave-1.0'
BASELINE_FILES = {
    'Contents/MacOS/Brave Browser': '9f492918492334d36bf3378b4841761c4231ad7ae771f1cc02abb91d9759b006',
    'Contents/Info.plist': 'a40d1382b5b7398cf14856a6c636c5f1e3db60062ae98ebc6a8076125c3302cd',
    'Contents/Frameworks/Brave Browser Framework.framework/Versions/155.1.98.0/Brave Browser Framework':
        '1d6b34099541f8fc95823420692faa374c5c77aa16b068f1ecd7309405b08ecf',
}
API = 'https://api.github.com/repos/' + REPOSITORY + '/releases'
VERSION = re.compile(r'mac-brave-(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\.(0|[1-9]\d*))?\Z')
SHA = re.compile(r'[0-9a-f]{64}\Z')
APP_NAME = 'Brave Browser.app'
PRODUCT_DIR = 'BraveLocalBuild/Brave-Browser'


class UpdateError(Exception):
    pass


def version(tag):
    match = VERSION.fullmatch(tag)
    if not match:
        raise UpdateError('Unsupported local release tag: ' + tag)
    return tuple(int(v or 0) for v in match.groups())


def digest(path):
    result = hashlib.sha256()
    with open(path, 'rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(data)
    return result.hexdigest()


def run(args):
    proc = subprocess.run(args, capture_output=True, text=True)
    return {'exitCode': proc.returncode,
            'output': (proc.stdout + proc.stderr).strip()}


def fetch(url, destination, limit):
    if urlsplit(url).scheme != 'https':
        raise UpdateError('HTTPS is required')
    # -q prevents a personal curl configuration from changing validation or auth.
    proc = subprocess.run([
        '/usr/bin/curl', '-q', '--fail', '--silent', '--show-error',
        '--location', '--proto', '=https', '--proto-redir', '=https',
        '--retry', '2', '--connect-timeout', '20', '--max-time', '600',
        '--max-filesize', str(limit), '--header',
        'Accept: application/vnd.github+json', '--user-agent',
        'mac-brave-local-update', '--output', str(destination), url],
        capture_output=True, text=True)
    if proc.returncode:
        raise UpdateError('HTTPS download failed: ' + proc.stderr.strip())
    if destination.stat().st_size > limit:
        raise UpdateError('Download exceeds size limit')


def releases():
    result = []
    with tempfile.TemporaryDirectory(prefix='mac-brave-release-check-') as temp:
        for page in range(1, 21):
            dest = Path(temp) / ('page-%s.json' % page)
            fetch(API + '?per_page=100&page=' + str(page), dest, 16 * 1024**2)
            data = json.loads(dest.read_text())
            if not isinstance(data, list):
                raise UpdateError('Unexpected GitHub releases response')
            result.extend(data)
            if len(data) < 100:
                return result
    raise UpdateError('Release pagination limit reached; refusing partial list')


def select_release(items, include_prereleases=False, requested=None):
    candidates = []
    for item in items:
        tag = item.get('tag_name', '')
        if not VERSION.fullmatch(tag) or item.get('draft'):
            continue
        if item.get('prerelease') and not include_prereleases:
            continue
        if item.get('html_url') != 'https://github.com/' + REPOSITORY + '/releases/tag/' + tag:
            raise UpdateError('Release repository mismatch')
        if requested is None or requested == tag:
            candidates.append(item)
    if not candidates:
        return None
    return max(candidates, key=lambda item: version(item['tag_name']))


def require_asset(release, name):
    assets = [a for a in release['assets'] if a['name'] == name]
    if len(assets) != 1:
        raise UpdateError('Missing or duplicate asset: ' + name)
    asset = assets[0]
    expected_url = ('https://github.com/' + REPOSITORY + '/releases/download/'
                    + release['tag_name'] + '/' + name)
    if asset.get('browser_download_url') != expected_url:
        raise UpdateError('Unexpected asset origin')
    value = asset.get('digest', '')
    if not value.startswith('sha256:') or not SHA.fullmatch(value[7:]):
        raise UpdateError('GitHub SHA256 asset digest is required')
    if asset.get('state') != 'uploaded' or not isinstance(asset.get('size'), int):
        raise UpdateError('Asset is not a complete upload')
    return asset


def download_asset(release, name, folder, limit):
    asset = require_asset(release, name)
    if asset['size'] <= 0 or asset['size'] > limit:
        raise UpdateError('Asset size outside allowed range')
    path = folder / name
    fetch(asset['browser_download_url'], path, limit)
    if path.stat().st_size != asset['size'] or digest(path) != asset['digest'][7:]:
        raise UpdateError('GitHub asset integrity mismatch: ' + name)
    return path


def checksums(path):
    values = {}
    for line in path.read_text().splitlines():
        fields = line.split('  ', 1)
        if len(fields) != 2 or not SHA.fullmatch(fields[0]):
            raise UpdateError('Malformed SHA256SUMS')
        key = fields[1]
        if PurePosixPath(key).name != key or key in values:
            raise UpdateError('Invalid checksum filename')
        values[key] = fields[0]
    return values


def validate_archive(path):
    """Reject links outside the app, link parents, special files and zip bombs."""
    names, folded_names, links, total = set(), set(), {}, 0
    fold = lambda value: unicodedata.normalize("NFD", value).casefold()
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            name = item.filename.rstrip('/')
            parts = PurePosixPath(name).parts
            if (not parts or parts[0] != APP_NAME or name.startswith('/')
                    or any(p in ('.', '..') for p in parts) or '\\' in name
                    or '\x00' in name or fold(name) in folded_names):
                raise UpdateError('Unsafe or duplicate archive path')
            # Normalize checks before extraction; do not silently accept A//B.
            if '/'.join(parts) != name:
                raise UpdateError('Noncanonical archive path')
            names.add(name)
            folded_names.add(fold(name))
            total += item.file_size
            if total > 4 * 1024**3 or len(names) > 50000:
                raise UpdateError('Archive exceeds extraction limit')
            mode = item.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
                raise UpdateError('Special file in archive')
            if kind == stat.S_IFLNK:
                if item.file_size > 4096:
                    raise UpdateError('Oversized link')
                target = archive.read(item).decode('utf-8')
                if target.startswith('/') or '\\' in target or '\x00' in target:
                    raise UpdateError('Unsafe link target')
                normalized = os.path.normpath(str(PurePosixPath(name).parent / target))
                if not normalized.startswith(APP_NAME + '/'):
                    raise UpdateError('Link escapes application')
                links[name] = normalized
        folded_links = {fold(name) for name in links}
        for name in names:
            if any(fold(str(parent)) in folded_links for parent in PurePosixPath(name).parents):
                raise UpdateError('Archive writes through a symlink')
        for start in links:
            seen, current = set(), start
            # Resolve component links, including Versions/Current references.
            for _ in range(100):
                if current in seen:
                    raise UpdateError('Cyclic archive symlink')
                seen.add(current)
                replaced = False
                parts = PurePosixPath(current).parts
                for index in range(1, len(parts) + 1):
                    prefix = '/'.join(parts[:index])
                    if prefix in links:
                        current = str(PurePosixPath(links[prefix]).joinpath(*parts[index:]))
                        replaced = True
                        break
                if not replaced:
                    if current not in names:
                        raise UpdateError('Broken archive symlink')
                    break
            else:
                raise UpdateError('Too many symlink resolutions')
    return {'entries': len(names), 'uncompressedBytes': total}


def installed_version(app):
    signature = run(['/usr/bin/codesign', '--verify', '--deep', '--strict',
                     '--all-architectures', str(app)])
    if signature['exitCode']:
        raise UpdateError('Installed application signature integrity failed')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (info.get('CrProductDirName') != PRODUCT_DIR
            or info.get('CFBundleIdentifier') != 'com.brave.Browser'):
        raise UpdateError('Installed application is not the expected local build')
    tag = info.get('BraveLocalReleaseTag')
    if tag:
        version(tag)
        return tag
    if all(digest(app / path) == expected for path, expected in BASELINE_FILES.items()):
        return BASELINE
    raise UpdateError('Unknown installed local version; refusing version assumptions')


def prepare(release, folder, installed_tag):
    tag = release['tag_name']
    if version(tag) < version(installed_tag):
        raise UpdateError('Downgrade refused')
    archive_name = tag + '-macos-arm64.zip'
    sums = checksums(download_asset(release, 'SHA256SUMS', folder, 1024**2))
    manifest_path = download_asset(release, 'build-manifest.json', folder, 1024**2)
    if digest(manifest_path) != sums.get(manifest_path.name):
        raise UpdateError('Manifest checksum mismatch')
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get('repository') != REPOSITORY or manifest.get('tag') != tag
            or manifest.get('defaultProfileProductDir') != PRODUCT_DIR):
        raise UpdateError('Manifest identity mismatch')
    archive = download_asset(release, archive_name, folder, 1536 * 1024**2)
    if digest(archive) != sums.get(archive_name):
        raise UpdateError('Archive checksum mismatch')
    archive_details = validate_archive(archive)
    unpacked = folder / 'unpacked'
    unpacked.mkdir()
    extraction = run(['/usr/bin/ditto', '-x', '-k', str(archive), str(unpacked)])
    if extraction['exitCode']:
        raise UpdateError('Archive extraction failed')
    app = unpacked / APP_NAME
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier') != 'com.brave.Browser'
            or info.get('CrProductDirName') != PRODUCT_DIR
            or info.get('CFBundleShortVersionString') != manifest['upstreamVersions']['bundleVersion']):
        raise UpdateError('Application identity/version mismatch')
    if tag != BASELINE and info.get('BraveLocalReleaseTag') != tag:
        raise UpdateError('Application is missing its signed local release tag')
    files = manifest.get('appFiles', [])
    framework = ('Contents/Frameworks/Brave Browser Framework.framework/Versions/'
                 + info['CFBundleShortVersionString'] + '/Brave Browser Framework')
    required = {'Contents/Info.plist', 'Contents/MacOS/Brave Browser', framework}
    paths = set()
    for entry in files:
        relative = PurePosixPath(entry['path'])
        if relative.is_absolute() or '..' in relative.parts or entry['path'] in paths:
            raise UpdateError('Invalid manifest file path')
        paths.add(entry['path'])
        target = app / relative
        if not target.resolve().is_relative_to(app.resolve()):
            raise UpdateError('Manifest path escapes application')
        if digest(target) != entry['sha256'] or target.stat().st_size != entry['bytes']:
            raise UpdateError('Application manifest integrity mismatch')
    if not required.issubset(paths):
        raise UpdateError('Incomplete application manifest')
    for binary in ['Contents/MacOS/Brave Browser', framework]:
        arch = run(['/usr/bin/lipo', '-archs', str(app / binary)])
        if arch['exitCode'] or arch['output'].split() != ['arm64']:
            raise UpdateError('Expected arm64 application and framework')
    signature = run(['/usr/bin/codesign', '--verify', '--deep', '--strict',
                     '--all-architectures', str(app)])
    if signature['exitCode']:
        raise UpdateError('Application signature integrity failed')
    gatekeeper = run(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', str(app)])
    return {'status': 'verified-download', 'tag': tag, 'app': str(app),
            'archive': archive_details, 'archiveSha256': digest(archive),
            'signatureIntegrity': signature, 'gatekeeper': gatekeeper,
            'installationEligible': gatekeeper['exitCode'] == 0,
            'publisherTrust': 'Pinned repository over HTTPS and GitHub asset digest; no independent publisher signature verified',
            'installed': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('/Applications/Brave Browser.app'))
    parser.add_argument('--include-prereleases', action='store_true')
    parser.add_argument('--prepare', action='store_true', help='Download and stage; never replaces the app')
    parser.add_argument('--tag', help='Explicit mac-brave-X.Y[.Z] release')
    parser.add_argument('--output', type=Path, required=True, help='New evidence/staging directory')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('This updater supports macOS arm64 only')
    args.output.mkdir(parents=True, exist_ok=False)
    result = {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'repository': REPOSITORY, 'installed': False}
    try:
        current = installed_version(args.app)
        result['installedTag'] = current
        release = select_release(releases(), args.include_prereleases, args.tag)
        if release is None:
            if args.tag:
                raise UpdateError('Requested release is unavailable in the selected channel')
            result['status'] = 'no-release-in-selected-channel'
        else:
            tag = release['tag_name']
            if version(tag) < version(current):
                raise UpdateError('Available release is older than the installed version')
            result.update(availableTag=tag, prerelease=release['prerelease'],
                          releaseURL=release['html_url'],
                          status='update-available' if version(tag) > version(current) else 'current')
            if args.prepare:
                result['prepared'] = prepare(release, args.output, current)
        code = 0
    except (UpdateError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        result.update(status='failed', error=str(error))
        code = 1
    (args.output / 'result.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return code


if __name__ == '__main__':
    sys.exit(main())
