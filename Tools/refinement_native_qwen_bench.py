"""Benchmark a single loaded native worker; all audio remains on this Mac."""
import argparse
import json
import pathlib
import resource
import selectors
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--helper", required=True)
parser.add_argument("--model", required=True)
parser.add_argument("--manifest", default="build/refinement/corpus/manifest.json")
args = parser.parse_args()
selector = selectors.DefaultSelector()
process = subprocess.Popen([args.helper, args.model], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, text=True, bufsize=1)
selector.register(process.stdout, selectors.EVENT_READ)

def receive(timeout):
    if not selector.select(timeout):
        raise TimeoutError("Native worker exceeded its deadline")
    line = process.stdout.readline().strip()
    if not line:
        raise RuntimeError(f"Native worker exited: {process.poll()}")
    return line

try:
    print(json.dumps({"event": "ready", "response": receive(90)}), flush=True)
    for item in json.loads(pathlib.Path(args.manifest).read_text()):
        start = time.monotonic()
        process.stdin.write(item["id"] + "\t" + str(pathlib.Path(item["audio"]).resolve()) + "\n")
        process.stdin.flush()
        identifier, status, elapsed, text = receive(30).split("\t", 3)
        assert identifier == item["id"] and status == "OK", (identifier, status, text)
        print(json.dumps({**item, "text": text, "inference_s": float(elapsed),
                          "wall_s": time.monotonic() - start}, ensure_ascii=False), flush=True)
    process.stdin.write("QUIT\n")
    process.stdin.flush()
    process.wait(timeout=5)
finally:
    selector.close()
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    print(json.dumps({"event": "exit", "returncode": process.returncode,
                      "peak_child_rss": resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss}), flush=True)
