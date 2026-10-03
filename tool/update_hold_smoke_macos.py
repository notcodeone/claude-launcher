#!/usr/bin/env python3
"""Offline macOS check that the launcher's update hold reaches Claude.

Starts one disposable, unauthenticated profile whose `<dir>-3p` folder holds
the same configuration EgressConfig.holdUpdates writes, then looks for the
updater's policy message in Claude's shared main.log. The decision line is
written once, at process start, so an already running Claude does not produce
it; do not start or restart another Claude while the check runs.

The process is killed (SIGKILL) as soon as the updater logs its decision and
well before its first feed check, so even a failed hold cannot download or
install an update into /Applications/Claude.app.

`--control` starts the profile without the hold and expects the updater to be
enabled, proving that the check distinguishes both outcomes.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

APP = '/Applications/Claude.app'
MAIN = APP + '/Contents/MacOS/Claude'
LOG = Path.home() / 'Library/Logs/Claude/main.log'
ENTRY = '6c4e1f8a-2b3d-4c5e-9f70-a1b2c3d4e5f6'
HELD = 'Auto-updates disabled by enterprise policy'
ENABLED = 'enabling initial check and auto-updates'


def claude_processes():
    out = subprocess.check_output(['ps', '-axww', '-o', 'pid=,command='], text=True)
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].startswith(APP + '/Contents/'):
            yield int(parts[0]), parts[1]


def write_hold(config_dir: Path):
    library = config_dir / 'configLibrary'
    library.mkdir(parents=True)
    (library / f'{ENTRY}.json').write_text(json.dumps({'disableAutoUpdates': True}))
    (library / '_meta.json').write_text(json.dumps({
        'appliedId': ENTRY,
        'entries': [{'id': ENTRY, 'name': 'ClaudeLauncher Kill Switch'}],
    }))
    (config_dir / 'claude_desktop_config.json').write_text(
        json.dumps({'deploymentMode': '1p'}))


def main():
    control = '--control' in sys.argv
    expected = 'enabled' if control else 'held'
    running = sum(command.startswith(MAIN) for _, command in claude_processes())
    if running:
        print(f'{running} Claude running: do not restart it during the check')
    offset = LOG.stat().st_size if LOG.exists() else 0
    with tempfile.TemporaryDirectory(prefix='Claude-UpdateHold-') as root:
        data = Path(root) / 'A'
        if not control:
            write_hold(Path(root) / 'A-3p')
        flag = '--user-data-dir=' + str(data)

        def owned():
            return [pid for pid, command in claude_processes() if flag in command]

        subprocess.run(['open', '-n', '-a', APP, '--args', flag,
                        '--proxy-server=http://127.0.0.1:9',
                        '--disable-background-networking'], check=True)
        verdict = None
        try:
            until = time.monotonic() + 20
            while time.monotonic() < until and verdict is None:
                time.sleep(0.25)
                if not LOG.exists():
                    continue
                with LOG.open('rb') as log:
                    log.seek(offset)
                    text = log.read().decode('utf-8', 'replace')
                if HELD in text:
                    verdict = 'held'
                elif ENABLED in text:
                    verdict = 'enabled'
        finally:
            for _ in range(40):
                pids = owned()
                if not pids:
                    break
                for pid in pids:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                time.sleep(0.25)
            assert not owned(), 'Disposable processes remain'
    print(json.dumps({'result': 'PASS' if verdict == expected else 'FAIL',
                      'control': control,
                      'updater': verdict or 'no decision logged'}))
    if verdict != expected:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
