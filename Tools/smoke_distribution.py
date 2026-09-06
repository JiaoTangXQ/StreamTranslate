#!/usr/bin/env python3
"""Exercise only shipped native runtimes/weights; never records live audio."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

app = Path(sys.argv[1]).resolve()
wav = Path(sys.argv[2]).resolve()
assert app.is_dir() and wav.is_file()
result = {}
with tempfile.TemporaryDirectory(prefix='st-dmg-smoke-') as temporary:
    root = Path(temporary)
    # No developer model caches or DYLD overrides are supplied to the workers.
    environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': temporary,
                   'TMPDIR': temporary, 'LANG': 'en_US.UTF-8'}
    with (root/'qwen.stderr').open('w') as errors:
        worker = subprocess.Popen([
            str(app/'Contents/Helpers/Qwen/QwenHelper'),
            str(app/'Contents/Resources/Models/Qwen.gguf')],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
            text=True, env=environment, cwd=temporary)
        try:
            started = time.monotonic()
            output, _ = worker.communicate(f'1\t{wav}\nQUIT\n', timeout=90)
            assert worker.returncode == 0 and output.startswith('READY\t'), output
            lines = output.splitlines()
            assert len(lines) == 2 and lines[1].startswith('1\tOK\t'), output
            result['qwen'] = {'output': lines, 'total_seconds': time.monotonic()-started}
        finally:
            if worker.poll() is None:
                worker.kill()
            worker.wait()
    socket = str(root/'translate.sock')
    with (root/'hymt.stderr').open('w') as errors:
        worker = subprocess.Popen([
            str(app/'Contents/Helpers/HyMT/llama-server'),
            '-m', str(app/'Contents/Resources/Models/HyMT.gguf'),
            '--host', socket, '-ngl', '99', '-c', '2048', '-t', '4', '-np', '1',
            '--jinja', '--no-webui', '--log-disable'],
            stdout=subprocess.DEVNULL, stderr=errors, env=environment, cwd=temporary)
        curl = ['/usr/bin/curl', '--silent', '--show-error', '--fail', '--noproxy', '*',
                '--unix-socket', socket, '--max-time', '10']
        try:
            deadline = time.monotonic()+60
            while time.monotonic() < deadline:
                assert worker.poll() is None, 'HyMT exited before ready'
                health = subprocess.run(curl+['http://localhost/health'], capture_output=True)
                if health.returncode == 0:
                    break
                time.sleep(0.2)
            else:
                raise TimeoutError('HyMT did not become ready')
            prompt = ('Translate the following text into Chinese. Note that you should only output '
                      'the translated result without any additional explanation:\n'
                      'Do not restart the server before the backup is complete.')
            payload = json.dumps({'messages': [{'role': 'user', 'content': prompt}],
                                  'temperature': 0.7, 'top_p': 0.6, 'top_k': 20,
                                  'repeat_penalty': 1.05, 'seed': 42, 'max_tokens': 384,
                                  'cache_prompt': True, 'stream': False})
            started = time.monotonic()
            response = subprocess.run(curl+['-H', 'Content-Type: application/json',
                                      '--data-binary', '@-', 'http://localhost/v1/chat/completions'],
                                      input=payload, capture_output=True, text=True, check=True)
            choice = json.loads(response.stdout)['choices'][0]
            assert choice['finish_reason'] == 'stop'
            text = choice['message']['content']
            assert '备份' in text and '重启' in text and any(s in text for s in ['不要', '请勿', '不得', '不应'])
            result['hymt'] = {'translation': text, 'request_seconds': time.monotonic()-started}
        finally:
            if worker.poll() is None:
                worker.terminate()
                try:
                    worker.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    worker.kill()
            worker.wait()
print(json.dumps(result, ensure_ascii=False, indent=2))
