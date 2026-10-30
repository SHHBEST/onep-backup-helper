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

# Visually reviewed screenshots; any byte change requires a fresh review.
REVIEWED_IMAGES = {
    '界面预览/加密备份.png': 'fc0fd0061d26d79be0cdea9bea462e1816b9e9fc350c6bb73eb4821dadd26f20',
    '界面预览/解密恢复.png': '9cc0a8b70baa9a5f89ab0ecbb19d73cb69feb889d9ca1f136f592812cf428ac8',
    '界面预览/校验恢复.png': '1fde0aa055e30d249c4505fac097d2cc42031e8f3fd070dc7667c74963d04d96',
    '界面预览/密钥位置.png': '484c32e653921d36d2004d86458da4019d5827eda750a894a9c664723699862c',
    '界面预览/浅色.jpg': '177a0f19cbf806e3f0eb617be83013b8078dd5615e5343d63b9f021ca5f7788d',
    '界面预览/深色.jpg': '395ad72b994584ad95c7a5bc87d17cab68220b7b168f904c91eeab6b4bedee65',
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
    if name in REVIEWED_IMAGES:
        if hashlib.sha256(data).hexdigest() != REVIEWED_IMAGES[name]:
            return ['reviewed screenshot hash mismatch; inspect before publishing']
        return []
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
    print('Official age binaries and visually reviewed screenshots accepted only by exact SHA256.')


if __name__ == '__main__':
    main()
