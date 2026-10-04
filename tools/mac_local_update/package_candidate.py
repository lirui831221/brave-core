#!/usr/bin/env python3
"""Seal a marked local candidate without modifying the installed application."""
import argparse
import datetime
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

import update


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-app', type=Path, required=True)
    parser.add_argument('--baseline-app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    args = parser.parse_args()
    update.version(args.tag)
    args.output.mkdir(parents=True, exist_ok=False)
    app = args.output / update.APP_NAME
    subprocess.run(['/usr/bin/ditto', str(args.build_app), str(app)], check=True)
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.update(CrProductDirName=update.PRODUCT_DIR, BraveLocalBuild=True,
                BraveLocalReleaseTag=args.tag, BraveLocalBuildStatus='unreleased-candidate',
                BraveLocalUpdateRepository=update.REPOSITORY)
    removed = {key: info.pop(key) for key in list(info)
               if key in ['KSProductID', 'KSUpdateURL', 'KSVersion', 'KSChannelID', 'SUFeedURL']}
    info_path.write_bytes(plistlib.dumps(info))
    framework = Path('Contents/Frameworks/Brave Browser Framework.framework')
    version = framework / 'Versions' / info['CFBundleShortVersionString']
    resources = Path(__file__).parent / 'adblock_resources'
    snapshot = json.loads((resources / 'snapshot.json').read_text())
    if snapshot.get('schema') != 1 or not {'resources.json', 'youtube-filters.txt'}.issubset(snapshot['files']):
        raise update.UpdateError('Incomplete bundled adblock snapshot')
    destination = app / version / 'Resources/brave_local_adblock'
    destination.mkdir(exist_ok=False)
    for name, expected in snapshot['files'].items():
        source = resources / name
        if Path(name).name != name or source.is_symlink() or update.digest(source) != expected:
            raise update.UpdateError('Bundled adblock resource snapshot mismatch')
        if source.suffix not in ('.mjs', '.py'):
            shutil.copy2(source, destination / name)
    shutil.copy2(resources / 'snapshot.json', destination / 'snapshot.json')
    relatives = [path.relative_to(app) for path in
                 sorted((app / version / 'Helpers').glob('Brave Browser Helper*.app'))]
    relatives += [framework, Path('.')]
    result = {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'source': str(args.build_app), 'candidate': str(app), 'tag': args.tag,
              'releaseStatus': 'unpublished local candidate',
              'removedOfficialUpdateMetadata': removed, 'sign': [], 'verify': [],
              'bundledAdblockSnapshot': snapshot}
    for relative in relatives:
        baseline = args.baseline_app / relative
        metadata = update.run(['/usr/bin/codesign', '-dvv', str(baseline)])
        if metadata['exitCode'] or 'Signature=adhoc' not in metadata['output']:
            raise update.UpdateError('Refuse to replace a non-ad-hoc baseline signature')
        identifier = next(line.split('=', 1)[1] for line in metadata['output'].splitlines()
                          if line.startswith('Identifier='))
        signed = update.run(['/usr/bin/codesign', '--force', '--sign', '-',
                             '--preserve-metadata=entitlements,flags',
                             '--identifier', identifier, str(app / relative)])
        result['sign'].append({'path': str(relative), **signed})
        if signed['exitCode']:
            raise update.UpdateError('Candidate signing failed')
    targets = [app, app / 'Contents/MacOS/Brave Browser', app / framework]
    targets += sorted((app / version).rglob('*.app'))
    targets += sorted((app / version).rglob('Sparkle.framework'))
    for target in targets:
        result['verify'].append({'path': str(target.relative_to(app)), **update.run([
            '/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', str(target)])})
    result['allSignaturesPass'] = all(row['exitCode'] == 0 for row in result['verify'])
    result['gatekeeper'] = update.run(['/usr/sbin/spctl', '--assess', '--type', 'execute', str(app)])
    result['files'] = [{'path': str(relative), 'sha256': update.digest(app / relative),
                        'bytes': (app / relative).stat().st_size}
                       for relative in [Path('Contents/Info.plist'), Path('Contents/MacOS/Brave Browser'),
                                        version / 'Brave Browser Framework']]
    (args.output / 'artifact.json').write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(json.dumps({'candidate': str(app), 'signatureObjects': len(targets),
                      'signaturePass': result['allSignaturesPass'], 'gatekeeper': result['gatekeeper']}))
    return 0 if result['allSignaturesPass'] else 1


if __name__ == '__main__':
    sys.exit(main())
