#!/usr/bin/env python3
"""Fault injection for the native pipe transport; never opens an ASCEND profile."""
import json
import sys
import signal
import time
mode, log = sys.argv[1:3]
if mode == 'focus_ok':
    print('https://www.example.com/lesson', flush=True)
    sys.exit(0)
if mode == 'focus_long_url':
    print('https://www.example.com/lesson?query=' + 'x' * 1000, flush=True)
    sys.exit(0)
if mode == 'focus_blank':
    print('about:blank', flush=True)
    sys.exit(0)
if mode == 'focus_failed':
    print('https://example.com/lesson', flush=True)
    sys.exit(1)
if mode == 'focus_flood':
    print('x' * 2_000_000, flush=True)
    sys.exit(0)
if mode == 'focus_stubborn':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    sys.stdout.close()
    time.sleep(60)
if mode == 'exit':
    sys.exit(0)
if mode == 'blocked_write':
    time.sleep(60)
for line in sys.stdin:
    command = json.loads(line)
    if mode == 'hang':
        time.sleep(60)
    if mode == 'partial':
        print('{"ok":true', end='', flush=True)
        time.sleep(60)
    if mode == 'oversized':
        print('x' * 8192, flush=True)
        time.sleep(60)
    if mode == 'malformed':
        print('invalid JSON', flush=True)
        continue
    if mode == 'slow':
        time.sleep(0.04)
    if log != '-':
        with open(log, 'a') as output:
            output.write(json.dumps(command) + '\n')
    try:
        print(json.dumps({'ok': True, 'timer': {'active': None}}), flush=True)
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except BrokenPipeError:
            pass
        sys.exit(0)
