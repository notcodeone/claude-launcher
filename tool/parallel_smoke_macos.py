#!/usr/bin/env python3
"""Offline macOS smoke test. Starts only disposable, unauthenticated profiles.

Never closes a pre-existing process. Verifies two distinct main processes,
closing one without closing the other; reports per-directory deduplication.
Does not verify login, Code, Cowork, or complete network containment.
"""
import json
import os
from pathlib import Path
import signal
import sys
import subprocess
import tempfile
import time

APP = '/Applications/Claude.app'
MAIN = APP + '/Contents/MacOS/Claude'


def processes():
    out = subprocess.check_output(['ps', '-axww', '-o', 'pid=,command='], text=True)
    result = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].startswith(MAIN):
            result[int(parts[0])] = parts[1]
    return result


def wait_for(check, timeout=25):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = check()
        if value:
            return value
        time.sleep(0.25)
    raise RuntimeError('Timed out waiting for Claude main processes')


def launch(directory):
    subprocess.run(['open', '-n', '-a', APP, '--args',
                    '--user-data-dir=' + str(directory),
                    '--proxy-server=http://127.0.0.1:9',
                    '--disable-background-networking'], check=True)


def main():
    before = set(processes())
    with tempfile.TemporaryDirectory(prefix='Claude-ParallelSmoke-') as root:
        dirs = [Path(root) / name for name in ('A', 'B')]
        def owned():
            return {pid: command for pid, command in processes().items()
                    if pid not in before and any(
                        '--user-data-dir=' + str(d) in command for d in dirs)}
        def of(directory):
            return [pid for pid, command in owned().items()
                    if '--user-data-dir=' + str(directory) in command]
        def stop(pid):
            if pid in owned():
                os.kill(pid, signal.SIGTERM)
            try:
                wait_for(lambda: pid not in owned(), timeout=10)
            except RuntimeError:
                if pid in owned():
                    os.kill(pid, signal.SIGKILL)
                wait_for(lambda: pid not in owned())
        try:
            launch(dirs[0])
            a = wait_for(lambda: of(dirs[0]))[0]
            launch(dirs[1])
            b = wait_for(lambda: of(dirs[1]))[0]
            time.sleep(5)
            assert a != b and set(owned()) == {a, b}, 'Profiles did not coexist'
            assert all(d.exists() for d in dirs), 'Profile directories not created'
            links_tested = '--links' in sys.argv
            if links_tested:
                repo = Path(__file__).resolve().parents[1]
                sender = Path(root) / 'link-sender'
                subprocess.run(['swiftc', str(repo / 'macos/Runner/ClaudeLinkDispatcher.swift'),
                                str(repo / 'tool/link_dispatch_test/main.swift'),
                                '-o', str(sender)], check=True)
                for target in [a, b]:
                    subprocess.run([str(sender), 'send', str(target),
                                    'claude://claude.ai/epitaxy/local_launcher_smoke'], check=True)
                assert set(owned()) == {a, b}, 'URL delivery launched another process'

            launch(dirs[0])
            time.sleep(5)
            deduplicated = set(owned()) == {a, b}
            print('Same-directory process count:', len(of(dirs[0])), flush=True)
            for extra in set(owned()) - {a, b}:
                stop(extra)
            stop(a)
            assert b in owned(), 'Closing A also closed B'
            assert before.issubset(processes()), 'A pre-existing Claude exited'
            print(json.dumps({'result': 'PASS', 'two_profiles': True,
                              'targeted_url_transport': links_tested,
                              'same_directory_deduplicated': deduplicated,
                              'independent_close': True,
                              'existing_processes_preserved': True}))
        finally:
            for pid in list(owned()):
                stop(pid)
            assert not owned(), 'Disposable processes remain'


if __name__ == '__main__':
    main()
