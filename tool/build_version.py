#!/usr/bin/env python3
"""Keep prerelease labels in CI artifacts; give Inno Setup a numeric file version."""
import json
import os
from pathlib import Path
import re

match = re.search(r'^version:\s*(\d+)\.(\d+)\.(\d+)(-[\w.-]+)?\+(\d+)\s*$', Path('pubspec.yaml').read_text(), re.MULTILINE)
if not match:
    raise SystemExit('Unsupported pubspec version')
major, minor, patch, preview, build = match.groups()
values = {'APP_VERSION': f'{major}.{minor}.{patch}{preview or ""}',
          'APP_FILE_VERSION': f'{major}.{minor}.{patch}.{build}'}
if any(int(n) > 65535 for n in (major, minor, patch, build)):
    raise SystemExit('File version exceeds Windows limits')
if env_file := os.environ.get('GITHUB_ENV'):
    with open(env_file, 'a', encoding='utf-8') as stream:
        for key, value in values.items():
            stream.write(f'{key}={value}\n')
print(json.dumps(values))
