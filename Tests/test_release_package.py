"""Manual distribution archive uses only generic integration files."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class ReleasePackageTests(unittest.TestCase):
    def test_archive_layout_checksum_and_reproducible_bytes(self):
        script = ROOT / 'scripts/package-integration.py'
        self.assertTrue(script.is_file(), 'release packager must exist')
        with tempfile.TemporaryDirectory() as directory:
            command = [sys.executable, str(script), '--output', directory]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            version = json.loads((ROOT / 'custom_components/belovodie_calendar_bridge/manifest.json').read_text())['version']
            archive = Path(directory) / f'belovodie-calendar-bridge-{version}.zip'
            original = archive.read_bytes()
            with zipfile.ZipFile(archive) as packaged:
                names = packaged.namelist()
                self.assertIn('custom_components/belovodie_calendar_bridge/manifest.json', names)
                self.assertIn('custom_components/belovodie_calendar_bridge/calendar.py', names)
                self.assertTrue(all(name.startswith('custom_components/belovodie_calendar_bridge/') for name in names))
                self.assertFalse(any('__pycache__' in name or name.endswith('.pyc') for name in names))
                for name in names:
                    self.assertEqual(packaged.read(name), (ROOT / name).read_bytes())
            checksum = archive.with_suffix('.zip.sha256').read_text()
            self.assertEqual(checksum, hashlib.sha256(original).hexdigest() + '  ' + archive.name + '\n')
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(archive.read_bytes(), original)

    def test_tag_version_mismatch_leaves_no_archive(self):
        script = ROOT / 'scripts/package-integration.py'
        self.assertTrue(script.is_file(), 'release packager must exist')
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(script), '--output', directory, '--expected-version', '9.9.9'], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
