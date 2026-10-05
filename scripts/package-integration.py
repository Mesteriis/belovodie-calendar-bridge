#!/usr/bin/env python3
"""Create a deterministic manual-install integration ZIP and SHA-256 sidecar."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import zipfile

DOMAIN = 'belovodie_calendar_bridge'
ROOT = Path(__file__).resolve().parents[1]


def package(output, expected_version=None):
    component = ROOT / 'custom_components' / DOMAIN
    manifest = json.loads((component / 'manifest.json').read_text())
    version = manifest['version']
    if manifest['domain'] != DOMAIN or not re.fullmatch(r'\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?', version):
        raise ValueError('Invalid integration identity/version')
    if expected_version is not None and version != expected_version:
        raise ValueError('Release tag does not match the integration version')
    payload = io.BytesIO()
    with zipfile.ZipFile(payload, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(component.rglob('*')):
            if '__pycache__' in path.parts:
                continue
            if path.is_symlink():
                raise ValueError('Symlinks are not supported in integration packages')
            if not path.is_file() or path.suffix not in {'.py', '.json', '.yaml'}:
                continue
            info = zipfile.ZipInfo(path.relative_to(ROOT).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes(), compresslevel=9)
    data = payload.getvalue()
    output.mkdir(parents=True, exist_ok=True)
    archive_path = output / f'belovodie-calendar-bridge-{version}.zip'
    archive_path.write_bytes(data)
    archive_path.with_suffix('.zip.sha256').write_text(hashlib.sha256(data).hexdigest() + '  ' + archive_path.name + '\n')
    return archive_path


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build')
    parser.add_argument('--expected-version')
    args = parser.parse_args()
    try:
        print(package(args.output, args.expected_version))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'Integration packaging failed: {error}\n')
