#!/usr/bin/env python3
"""Scan tracked files and staged blobs without printing matched secrets."""
from pathlib import Path
import hashlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OFFICIAL = {
    'vendor/age/darwin-arm64/age': '4012dfc2725883beafb710894af4f599b7a94f8c8e0f51f02cc96ab8df33915e',
    'vendor/age/darwin-arm64/age-keygen': 'c16e229245123d0ad27442317461d63915416cad0294395cd19ca93feb3211ea',
}
PATTERNS = {
    'full age private key': rb'AGE-SECRET-KEY-1[0-9A-Z]{58}',
    'full age public key': rb'age1[0-9a-z]{58}',
    'GitHub token': rb'(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})',
    'private PEM': rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'personal absolute path': rb'/Us' + rb'ers/[^/\s\x00]+/',
}
FORBIDDEN = {'.key', '.pem', '.p12', '.pfx', '.1pux', '.1pif', '.age', '.zip', '.gz', '.png', '.jpg', '.jpeg'}


def check(name, data):
    errors = []
    p = Path(name)
    if p.suffix.lower() in FORBIDDEN or (p.suffix.lower() == '.txt' and p.name != 'LICENSE-age.txt'):
        errors.append('key/backup/archive/unreviewed image filename')
    if p.name in {'settings.plist', '.DS_Store'} or any(x in p.parts for x in ['.build-native', '__pycache__', 'ModuleCache']):
        errors.append('local configuration or build output')
    if name in OFFICIAL:
        if hashlib.sha256(data).hexdigest() != OFFICIAL[name]:
            errors.append('upstream binary hash mismatch')
        return errors
    for label, pattern in PATTERNS.items():
        if re.search(pattern, data):
            errors.append(label)
    if b'\x00' in data:
        errors.append('unreviewed binary')
    return errors


def main():
    files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    files = [x for x in files if x]
    if not files:
        raise SystemExit('No tracked files: stage the explicit allowlist first.')
    failed = False
    for name in files:
        p = ROOT / name
        if p.is_symlink() or not p.is_file():
            issues = ['not an ordinary file']
        else:
            issues = check(name, p.read_bytes())
            staged = subprocess.check_output(['git', 'show', ':' + name], cwd=ROOT)
            issues += check(name, staged)
        if issues:
            failed = True
            print('REJECT:', name, ', '.join(sorted(set(issues))))
    if failed:
        raise SystemExit(1)
    print('PASS:', len(files), 'tracked files; no personal key/backup/configuration detected.')
    print('Official age binaries accepted only by exact SHA256.')


if __name__ == '__main__':
    main()
