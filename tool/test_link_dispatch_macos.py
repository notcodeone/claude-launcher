#!/usr/bin/env python3
"""Two real event receivers verify the production Swift dispatcher by PID."""
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_for(predicate):
    until = time.monotonic() + 10
    while time.monotonic() < until:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError('No expected Apple Event receipt')


with tempfile.TemporaryDirectory(prefix='claude-link-dispatch-') as temp:
    root = Path(temp)
    binary = root / 'receiver'
    subprocess.run(['swiftc', str(ROOT / 'macos/Runner/ClaudeLinkDispatcher.swift'),
                    str(ROOT / 'tool/link_dispatch_test/main.swift'),
                    '-o', str(binary)], check=True)
    paths = [root / 'A', root / 'B']
    children = []
    try:
        for path in paths:
            children.append(subprocess.Popen([str(binary), 'receive', str(path)]))
        wait_for(lambda: all(Path(str(p) + '.ready').exists() for p in paths))
        for index in [1, 0]:
            link = 'claude://claude.ai/epitaxy/local_test_' + str(index)
            subprocess.run([str(binary), 'send', str(children[index].pid), link], check=True)
            wait_for(paths[index].exists)
            assert paths[index].read_text() == link
            if index == 1:
                assert not paths[0].exists(), 'Wrong process received the URL'
        rejected = subprocess.run([str(binary), 'send', str(children[0].pid),
                                   'https://example.com/']).returncode
        assert rejected != 0
        assert paths[0].read_text().endswith('local_test_0')
        print('PASS: both URLs reached only their target PID; non-Claude URL rejected')
    finally:
        for child in children:
            child.terminate()
        for child in children:
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
