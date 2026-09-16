#!/usr/bin/env python3
"""Check Git-index contents, never print secret values. Run before commit/publication."""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MAX_BYTES = 5 * 1024 * 1024
BLOCKED_DIRS = {'.git', 'node_modules', '.venv', 'venv', '__pycache__', 'build', 'dist',
                'DerivedData', '.build', 'Pods', 'bin', 'obj', 'backups', 'backup',
                'dumps', 'mongodump', 'uploads', 'logs', 'xcuserdata', '.idea',
                '.cursor', '.claude', '.agents', '.gradle', 'oh_modules', '.hvigor'}
BLOCKED_SUFFIX = re.compile(r'(?i)\.(?:sql(?:\..*)?|dump(?:\..*)?|bson(?:\..*)?|db(?:-.*)?|sqlite\w*|rdb|aof|archive(?:\..*)?|bak|backup|bundle|p8|p12|pfx|pem|key|cer|jks|keystore|p7b|mobileprovision|provisionprofile|ipa|apk|aab|hap|hsp|dmg|exe|msi|dll|so|dylib|o|a|class|zip|tar(?:\.gz)?|tgz|7z|rar|pyc|log)$')
RULES = {
    'literal Cloudflare token in documentation': re.compile(r'(?i)(?:API[ _-]*(?:Token|令牌)|Cloudflare[^\r\n|]{0,30})[^\r\n]{0,30}`[A-Za-z0-9_+/=-]{35,}`'.encode('utf-8')),
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----[\r\n]+[A-Za-z0-9+/=\r\n]{32,}-----END'),
    'provider token': re.compile(rb'\b(?:AKIA[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-(?:proj-|ant-)?[A-Za-z0-9_-]{24,})\b'),
    'database credentials': re.compile(rb'(?:mongodb(?:\+srv)?|postgres(?:ql)?|mysql|redis)://(?!YOUR_DB_USER:YOUR_DB_PASSWORD@)[^\s/"\x27:]+:[^\s/"\x27@]+@'),
    'authenticated URL': re.compile(rb'https?://(?!\$\{)(?!user:pass@proxy\.example\.com)[^\s/"\x27:]+:[^\s/"\x27@]+@'),
}


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staged', action='store_true', help='Check changed staged files only')
    args = parser.parse_args()
    entries = git('ls-files', '--stage', '-z').split(b'\0')
    changed = None
    if args.staged:
        changed = set(git('diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z').split(b'\0'))
    object_ids = list(dict.fromkeys(entry.split(b'\t', 1)[0].split()[1] for entry in entries if entry and not entry.startswith(b'160000')))
    raw = subprocess.check_output(['git', '-C', str(ROOT), 'cat-file', '--batch'], input=b'\n'.join(object_ids) + b'\n')
    objects = {}
    offset = 0
    for oid in object_ids:
        end = raw.index(b'\n', offset)
        size = int(raw[offset:end].split()[2])
        objects[oid] = raw[end + 1:end + 1 + size]
        offset = end + 2 + size
    errors = []
    checked = 0
    for entry in filter(None, entries):
        meta, raw_path = entry.split(b'\t', 1)
        if changed is not None and raw_path not in changed:
            continue
        mode, oid, stage = meta.split()
        path = raw_path.decode('utf-8')
        p = pathlib.PurePosixPath(path)
        checked += 1
        if mode == b'160000':
            errors.append((path, 'nested Git repository/submodule'))
            continue
        if mode == b'120000':
            errors.append((path, 'symlink requires explicit publication review'))
            continue
        if stage != b'0':
            errors.append((path, 'unresolved merge'))
            continue
        if (set(p.parts[:-1]) & BLOCKED_DIRS or BLOCKED_SUFFIX.search(path)
                or p.name.startswith('.env') and not p.name.endswith('.example')
                or p.name in {'.DS_Store', 'PASSWORD.txt', 'credentials.json', 'secrets.json'}
                or p.name.startswith('ExportOptions')) and not (str(p.parent) == 'lobster-input-payment/app/resources/apple_root_certs' and p.suffix == '.cer'):
            errors.append((path, 'private/generated/backup file'))
        data = objects[oid]
        size = len(data)
        if size > MAX_BYTES:
            errors.append((path, 'file exceeds 5 MiB; remove or review separately'))
            continue
        for label, pattern in RULES.items():
            for match in pattern.finditer(data):
                if label == 'authenticated URL':
                    value = match.group()
                    if b'${' in value:
                        continue  # Environment interpolation is not a literal credential.
                    if path == 'lobster-input-backend/backend/tests/test_proxy_config.py' and value in {
                        b'http://' + b'url-user:url-pass@',
                        b'http://' + b'user%40example.com:p%2Fa%3Ass%20word@',
                    }:
                        continue  # Exact synthetic test fixtures only.
                errors.append((path, label))
                break
    for path, message in errors:
        print(f'ERROR {path}: {message}', file=sys.stderr)
    print(f'Checked {checked} Git-index files; {len(errors)} finding(s).')
    return 1 if errors else 0


if __name__ == '__main__':
    raise SystemExit(main())
