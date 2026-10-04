#!/usr/bin/env python3
"""Install an explicitly confirmed, newer, notarized local release with rollback."""
import argparse
import datetime
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import sys
import uuid

import update


def promote(incoming, target, validate):
    """All paths are on the target volume. Keep both old and failed packages."""
    suffix = uuid.uuid4().hex
    backup = target.with_name(target.stem + '.previous-' + suffix + '.app')
    failed = target.with_name(target.stem + '.failed-' + suffix + '.app')
    os.rename(target, backup)
    try:
        os.rename(incoming, target)
        validate(target)
    except Exception:
        if target.exists():
            os.rename(target, failed)
        os.rename(backup, target)
        raise
    return backup


def verify_trust(app, team_id):
    for command in [
            ['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', str(app)],
            ['/usr/sbin/spctl', '--assess', '--type', 'execute', str(app)]]:
        result = update.run(command)
        if result['exitCode']:
            raise update.UpdateError('Signature/Gatekeeper verification failed; no bypass is available')
    identity = update.run(['/usr/bin/codesign', '-dvv', str(app)])
    if identity['exitCode'] or ('TeamIdentifier=' + team_id) not in identity['output'].splitlines():
        raise update.UpdateError('Publisher Team ID differs from the explicitly trusted identity')


def refuse_internal_downgrade(current_app, staged_app):
    def numeric(app):
        value = plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('CFBundleShortVersionString', '')
        if not re.fullmatch(r'\d+\.\d+\.\d+\.\d+', value):
            raise update.UpdateError('Unrecognized internal browser version')
        return tuple(int(part) for part in value.split('.'))
    if numeric(staged_app) < numeric(current_app):
        raise update.UpdateError('Internal browser version downgrade refused')


def require_closed(app):
    executable = str(app / 'Contents/MacOS/Brave Browser')
    running = update.run(['/usr/bin/pgrep', '-f', '^' + re.escape(executable) + '($| )'])
    if running['exitCode'] != 1:
        raise update.UpdateError('Browser is running or process check failed; close it normally first')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepared-result', required=True, type=Path)
    parser.add_argument('--confirm-tag', required=True, help='Exact release approved for installation')
    parser.add_argument('--expected-team-id', required=True, help='Independently established publisher Team ID')
    parser.add_argument('--output', required=True, type=Path, help='New transaction evidence directory')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    result = {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'installed': False}
    target = Path('/Applications/Brave Browser.app')
    try:
        if not re.fullmatch(r'[A-Z0-9]{10}', args.expected_team_id):
            raise update.UpdateError('A valid publisher Team ID must be configured before installation')
        reviewed = json.loads(args.prepared_result.read_text())['prepared']
        tag = reviewed['tag']
        if tag != args.confirm_tag:
            raise update.UpdateError('Confirmed version differs from the reviewed package')
        current = update.installed_version(target)
        if update.version(tag) <= update.version(current):
            raise update.UpdateError('Only newer releases can be installed; downgrade/reinstall refused')
        if target.is_symlink() or not target.is_dir():
            raise update.UpdateError('Unexpected application target')
        require_closed(target)
        release = update.select_release(update.releases(), True, tag)
        if release is None:
            raise update.UpdateError('Confirmed release is no longer available')
        # Re-fetch and revalidate instead of trusting a previously unpacked app.
        fresh = update.prepare(release, args.output, current)
        if fresh['archiveSha256'] != reviewed['archiveSha256']:
            raise update.UpdateError('Release changed after review; new approval is required')
        staged = Path(fresh['app'])
        refuse_internal_downgrade(target, staged)
        verify_trust(staged, args.expected_team_id)
        incoming = target.with_name('.Brave Browser.incoming-' + uuid.uuid4().hex + '.app')
        shutil.copytree(staged, incoming, symlinks=True, copy_function=shutil.copy2)
        verify_trust(incoming, args.expected_team_id)
        require_closed(target)
        backup = promote(incoming, target, lambda app: verify_trust(app, args.expected_team_id))
        result.update(installed=True, status='installed', tag=tag, backup=str(backup),
                      restart='Open the application normally; browser profile was not accessed')
        code = 0
    except (update.UpdateError, OSError, ValueError, KeyError) as error:
        result.update(status='failed', error=str(error))
        code = 1
    (args.output / 'install-result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return code


if __name__ == '__main__':
    sys.exit(main())
