#!/usr/bin/env python3
"""Run only the specified child with explicit disk/time safety limits."""
import argparse
import json
import os
import signal
import shutil
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--minimum-free-gib', type=float, default=1.5)
p.add_argument('--timeout', type=float, default=240)
p.add_argument('--stdout', required=True)
p.add_argument('--stderr', required=True)
p.add_argument('command', nargs=argparse.REMAINDER)
args = p.parse_args()
command = args.command[1:] if args.command[:1] == ['--'] else args.command
threshold = args.minimum_free_gib * 1024**3
minimum = shutil.disk_usage('.').free
if minimum < threshold + 1024**3: raise SystemExit('Insufficient disk headroom before starting')
start = time.monotonic()
reason = None
swap_before = subprocess.check_output(['sysctl', 'vm.swapusage'], text=True).strip()
with open(args.stdout, 'w') as output, open(args.stderr, 'w') as errors:
    # Private process group includes native model helpers, so a guard-triggered
    # exit does not orphan their allocations. Never signal unrelated processes.
    child = subprocess.Popen(command, stdout=output, stderr=errors, start_new_session=True)
    try:
        while child.poll() is None:
            free = shutil.disk_usage('.').free
            minimum = min(minimum, free)
            if free < threshold: reason = 'disk_safety_limit'; break
            if time.monotonic()-start > args.timeout: reason = 'time_limit'; break
            time.sleep(.25)
    finally:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        if child.poll() is None:
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: pass
        # Also clean up helpers orphaned by an already-exited failed parent.
        try: os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        child.wait()
print(json.dumps(dict(returncode=child.returncode, reason=reason,
    minimum_free_bytes=minimum, elapsed=time.monotonic()-start,
    swap_before=swap_before,
    swap_after=subprocess.check_output(['sysctl', 'vm.swapusage'], text=True).strip())))
raise SystemExit(0 if child.returncode==0 and reason is None else 1)
