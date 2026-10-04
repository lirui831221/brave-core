import copy
from pathlib import Path
import stat
import plistlib
from unittest import mock
import tempfile
import unittest
import zipfile

import update
import install


def release(tag='mac-brave-1.0', prerelease=False):
    return {'tag_name': tag, 'draft': False, 'prerelease': prerelease,
            'html_url': 'https://github.com/' + update.REPOSITORY + '/releases/tag/' + tag,
            'assets': []}


class ReleaseValidationTests(unittest.TestCase):
    def test_numeric_version_order(self):
        self.assertGreater(update.version('mac-brave-1.10'), update.version('mac-brave-1.9'))
        self.assertEqual(update.version('mac-brave-1.0'), update.version('mac-brave-1.0.0'))

    def test_reject_non_release_tags(self):
        for tag in ['main', 'mac-brave-01.0', 'mac-brave-1.0/../other', 'android-1.0', 'mac-brave-1.0-dev']:
            with self.subTest(tag=tag), self.assertRaises(update.UpdateError):
                update.version(tag)

    def test_prerelease_requires_opt_in(self):
        self.assertIsNone(update.select_release([release(prerelease=True)]))
        self.assertIsNotNone(update.select_release([release(prerelease=True)], True))

    def test_drafts_and_unrelated_tags_excluded(self):
        draft = release('mac-brave-9.0')
        draft['draft'] = True
        selected = update.select_release([draft, release('android-99.0'), release()])
        self.assertEqual(selected['tag_name'], 'mac-brave-1.0')

    def test_wrong_repository_rejected(self):
        item = release()
        item['html_url'] = 'https://github.com/other/brave-core/releases/tag/mac-brave-1.0'
        with self.assertRaises(update.UpdateError):
            update.select_release([item])

    def test_asset_origin_digest_and_duplicates(self):
        item = release()
        asset = {'name': 'build-manifest.json', 'state': 'uploaded', 'size': 100,
                 'digest': 'sha256:' + 'a' * 64,
                 'browser_download_url': 'https://github.com/' + update.REPOSITORY
                 + '/releases/download/mac-brave-1.0/build-manifest.json'}
        item['assets'] = [asset]
        self.assertEqual(update.require_asset(item, asset['name']), asset)
        for key, value in [('digest', ''), ('browser_download_url', 'https://example.com/file'), ('state', 'new')]:
            bad = copy.deepcopy(item)
            bad['assets'][0][key] = value
            with self.subTest(key=key), self.assertRaises(update.UpdateError):
                update.require_asset(bad, asset['name'])
        item['assets'].append(asset.copy())
        with self.assertRaises(update.UpdateError):
            update.require_asset(item, asset['name'])

    def test_checksum_duplicates_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'SHA256SUMS'
            path.write_text(('a' * 64 + '  app.zip\n') * 2)
            with self.assertRaises(update.UpdateError):
                update.checksums(path)

    def archive(self, entries):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / 'app.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            for name, contents, link in entries:
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = ((stat.S_IFLNK | 0o777) if link else (stat.S_IFREG | 0o644)) << 16
                archive.writestr(entry, contents)
        return path

    def test_valid_internal_link(self):
        path = self.archive([('Brave Browser.app/Contents/file', 'data', False),
                             ('Brave Browser.app/Contents/link', 'file', True)])
        self.assertEqual(update.validate_archive(path)['entries'], 2)

    def test_macos_path_aliases_rejected(self):
        for names in [('File', 'file'), ('caf\u00e9', 'cafe\u0301')]:
            path = self.archive([('Brave Browser.app/Contents/' + name, 'data', False) for name in names])
            with self.subTest(names=names), self.assertRaises(update.UpdateError):
                update.validate_archive(path)
        path = self.archive([('Brave Browser.app/Contents/Link', 'real', True),
                             ('Brave Browser.app/Contents/link/file', 'data', False)])
        with self.assertRaises(update.UpdateError):
            update.validate_archive(path)

    def test_zip_path_traversal(self):
        for name in ['../outside', '/tmp/file', 'Brave Browser.app/../outside', 'Brave Browser.app//file']:
            with self.subTest(name=name), self.assertRaises(update.UpdateError):
                update.validate_archive(self.archive([(name, 'data', False)]))

    def test_symlink_escape_and_loop(self):
        for target in ['../../outside', '/tmp/outside', 'link']:
            with self.subTest(target=target), self.assertRaises(update.UpdateError):
                update.validate_archive(self.archive([('Brave Browser.app/Contents/link', target, True)]))

    def test_write_through_symlink_rejected(self):
        path = self.archive([('Brave Browser.app/Contents/link', 'real', True),
                             ('Brave Browser.app/Contents/link/file', 'data', False)])
        with self.assertRaises(update.UpdateError):
            update.validate_archive(path)

    def test_downgrade_refused_before_network(self):
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(update.UpdateError):
            update.prepare(release('mac-brave-1.0'), Path(directory), 'mac-brave-1.1')

    def test_baseline_requires_framework_and_plist_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            (app / 'Contents').mkdir()
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CrProductDirName': update.PRODUCT_DIR,
                'CFBundleIdentifier': 'com.brave.Browser'}))
            def changed_framework(path):
                relative = str(path.relative_to(app))
                return '0' * 64 if 'Framework' in relative else update.BASELINE_FILES[relative]
            with mock.patch.object(update, 'run', return_value={'exitCode': 0}), mock.patch.object(update, 'digest', side_effect=changed_framework):
                with self.assertRaises(update.UpdateError):
                    update.installed_version(app)

    def test_signature_failure_rejects_installed_version(self):
        with mock.patch.object(update, 'run', return_value={'exitCode': 1}):
            with self.assertRaises(update.UpdateError):
                update.installed_version(Path('/unused'))

    def test_internal_version_downgrade_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in [('old', '155.1.98.0'), ('new', '154.1.99.0')]:
                path = root / name / 'Contents'
                path.mkdir(parents=True)
                (path / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': value}))
            with self.assertRaises(update.UpdateError):
                install.refuse_internal_downgrade(root / 'old', root / 'new')

    def test_install_failure_restores_previous_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target, incoming = root / 'Browser.app', root / 'incoming.app'
            target.mkdir()
            incoming.mkdir()
            (target / 'version').write_text('old')
            (incoming / 'version').write_text('new')
            def reject(_):
                raise update.UpdateError('synthetic final verification failure')
            with self.assertRaises(update.UpdateError):
                install.promote(incoming, target, reject)
            self.assertEqual((target / 'version').read_text(), 'old')
            failed = list(root.glob('Browser.failed-*.app'))
            self.assertEqual(len(failed), 1)
            self.assertEqual((failed[0] / 'version').read_text(), 'new')

    def test_install_keeps_old_app_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target, incoming = root / 'Browser.app', root / 'incoming.app'
            target.mkdir()
            incoming.mkdir()
            (target / 'version').write_text('old')
            (incoming / 'version').write_text('new')
            backup = install.promote(incoming, target, lambda _: None)
            self.assertEqual((target / 'version').read_text(), 'new')
            self.assertEqual((backup / 'version').read_text(), 'old')


if __name__ == '__main__':
    unittest.main()
