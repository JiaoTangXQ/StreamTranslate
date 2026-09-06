#!/usr/bin/env python3
"""Evaluate the installed Metal translator on authored contrasts and ASR errors."""
import json
from pathlib import Path
import secrets
import socket
import subprocess
import time
import urllib.request
import argparse
import re

parser = argparse.ArgumentParser()
parser.add_argument('--model', default='/Volumes/PortableSSD/StreamTranslate-verification-20260905/Hy-MT2-1.8B/Hy-MT2-1.8B-Q4_K_M.gguf')
parser.add_argument('--label', default='hymt')
parser.add_argument('--expanded', action='store_true')
parser.add_argument('--glossary', action='store_true')
parser.add_argument('--context-probes', action='store_true')
parser.add_argument('--speech-context', action='store_true')
parser.add_argument('--numeric-probes', action='store_true')
parser.add_argument('--precision-hint', action='store_true')
parser.add_argument('--temperature', type=float, default=0.7)
parser.add_argument('--cross-lingual-hint', action='store_true')
parser.add_argument('--percent-hint', action='store_true')
parser.add_argument('--domain-probes', action='store_true')
parser.add_argument('--domain-terms', action='store_true')
parser.add_argument('--cache-prompt', action='store_true')
parser.add_argument('--contrast-probes', action='store_true')
parser.add_argument('--contrast-hint', action='store_true')
parser.add_argument('--translategemma', action='store_true',
                    help='Render the embedded structured translation template; use native completion API')
args = parser.parse_args()

gemma_template = None
if args.translategemma:
    import gguf
    from jinja2 import StrictUndefined
    from jinja2.sandbox import SandboxedEnvironment
    reader = gguf.GGUFReader(args.model)
    template_text = reader.fields['tokenizer.chat_template'].contents()
    gemma_template = SandboxedEnvironment(undefined=StrictUndefined).from_string(template_text)
    del reader

root = Path('build/refinement')
cases = []
for line in (root/'translation-low-repeat.jsonl').read_text().splitlines():
    row = json.loads(line)
    if row['event']=='translation':
        cases.append(dict(id=f"contrast-{row['language']}-{row['index']}", source=row['source'],
                          language=row['language'], apple=row['target']))
manifest = {x['id']: x for x in json.loads((root/'corpus/manifest.json').read_text())}
for line in (root/'recognition-summary.jsonl').read_text().splitlines():
    row = json.loads(line); language = manifest[row['id']]['language']
    key = 'chinese' if language=='zh' else 'english'
    target = 'english' if language=='zh' else 'chinese'
    cases.append(dict(id='asr-'+row['id'], source=' '.join(x[key] for x in row['captions']),
                      language=language, apple=' '.join(x[target] for x in row['captions'])))

if args.expanded:
    heldout = [
        ('zh', '这项测试只能说明两个变量相关，不能证明其中一个导致另一个。'),
        ('en', 'The service is available, but the data is not necessarily up to date.'),
        ('zh', '她说的不是预算不够，而是时间不够。'),
        ('en', 'We can ship today only if the rollback has been tested.'),
        ('zh', '问题不在于模型太大，而在于每次请求都重新加载模型。'),
        ('en', 'A lower error rate does not always mean fewer errors if traffic has doubled.'),
        ('zh', '先把旧数据备份，再清空缓存，注意不是删除数据库。'),
        ('en', 'The patch reduced latency by a third, not to a third of the previous value.'),
    ]
    for index, (language, source) in enumerate(heldout):
        cases.append(dict(id=f'heldout-{index}', language=language, source=source, apple=None))
    for line in (root/'qwen-native-corpus.jsonl').read_text().splitlines():
        row = json.loads(line)
        if row.get('id') in ['zh-technical', 'en-technical']:
            cases.append(dict(id='qwen-'+row['id'], language=row['language'], source=row['text'], apple=None))

if args.context_probes:
    probes = [
        ('It was a cash eviction problem.', 'We ruled out a memory leak.'),
        ('I no longer do.', 'I used to think the update was safe.'),
        ('It does not.', 'Does a lower error rate prove that there are fewer errors?'),
        ('They were all empty.', 'The office had thousands of cubicles.'),
        ('Not until the backup finishes.', 'When can we restart the server?'),
        ('Cash collection failed.', 'The tenants pay their rent in cash.'),
        ('Cache collection failed.', 'The server uses a cache to reduce repeated database requests.'),
        ('By a third, not to a third.', 'How much did the patch reduce latency?'),
    ]
    cases = [dict(id=f'context-{index}', language='en', source=source, context=context, apple=None)
             for index, (source, context) in enumerate(probes)]

if args.numeric_probes:
    probes = [
        ('en', 'The patch reduced latency by a third—not to a third. The success rate rose from 95% to 98%.'),
        ('en', 'The patch reduced latency by a third, not to a third of the previous value.'),
        ('en', 'The price fell to fifty dollars, not by fifty dollars.'),
        ('en', 'Output increased by twenty percent, not to twenty percent.'),
        ('en', 'The failure rate decreased to two percent, not by two percent.'),
        ('en', 'The budget was reduced by half, not to half a million dollars.'),
        ('en', 'Latency fell from three hundred to two hundred milliseconds, a reduction of one third.'),
        ('en', 'We travelled by train to the third station.'),
        ('zh', '延迟降低了三分之一，不是降低到三分之一。成功率从95%提高到98%。'),
        ('zh', '价格降到了五十元，不是下降了五十元。'),
        ('zh', '产量增加了百分之二十，不是增加到百分之二十。'),
        ('zh', '失败率降低到百分之二，不是降低了百分之二。'),
    ]
    cases = [dict(id=f'numeric-{index}', language=language, source=source, apple=None)
             for index, (language, source) in enumerate(probes)]

if args.domain_probes:
    probes = [
        ('It was a cash eviction problem.', 'We ruled out a memory leak.'),
        ('The key value cash keeps growing.', 'The model weights stay the same size.'),
        ('The key-value cash keeps growing.', 'The key-value cache is stored in memory.'),
        ('Cash collection failed.', 'The server has a memory leak.'),
        ('It was a cash eviction problem.', 'The tenant and landlord argued about rent.'),
        ('We paid cash after the eviction.', 'The tenant and landlord argued about rent.'),
        ('The cash balance keeps growing.', 'We ruled out a memory leak.'),
        ('It was a cash eviction problem.', 'We fixed a memory leak. Now the tenant has to pay rent.'),
    ]
    cases = [dict(id=f'domain-{index}', language='en', source=source, terminology_context=context, apple=None)
             for index, (source, context) in enumerate(probes)]

if args.contrast_probes:
    sources = [
        '我们已经排除了内存泄漏问题，出在缓存淘汰策略。模型权重没有变大，但键值缓存还在增长。',
        '我们已经排除了内存泄漏，问题出在缓存淘汰策略。',
        '我们已经排除了网络故障，问题在于密码错误。',
        '我们还没有排除内存泄漏的可能，缓存淘汰策略也需要检查。',
        '不能排除服务器故障，但目前还没有证据。',
        '他们说已经排除了权限问题，我们并不同意。',
        '我们排除了由缓存淘汰策略造成的内存泄漏问题，其他问题还没有解决。',
        '只有排除了所有故障，才能重新上线。',
    ]
    cases = [dict(id=f'contrast-scope-{i}', language='zh', source=source, apple=None)
             for i, source in enumerate(sources)]

with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
api_key = secrets.token_hex(24)
headers = {'Authorization':'Bearer '+api_key, 'Content-Type':'application/json'}
url = f'http://127.0.0.1:{port}'
log = (root/(args.label+'-server.log')).open('w')
# llama-server's startup chat-capability probe uses string content, which the
# structured Gemma template correctly rejects. Its chat endpoint is unused:
# render the actual embedded template below and send exact tokens to completion.
template_args = ['--no-jinja', '--chat-template', 'chatml'] if args.translategemma else ['--jinja']
process = subprocess.Popen(['build/verification/llama-b10809/llama-server',
    '-m',args.model,
    '--host','127.0.0.1','--port',str(port),'--api-key',api_key,
    '-ngl','99','-c','2048','-t','4','-np','1',*template_args,'--no-webui','-lv','4'], stdout=log, stderr=subprocess.STDOUT)
def emit(**fields): print(json.dumps(fields, ensure_ascii=False), flush=True)
try:
    for _ in range(600):
        if process.poll() is not None: raise RuntimeError('Server exited')
        try:
            with urllib.request.urlopen(urllib.request.Request(url+'/health',headers=headers),timeout=1) as response:
                if response.status==200: break
        except Exception: pass
        time.sleep(.1)
    else: raise TimeoutError('Local server startup')
    for item in cases:
        target = 'Chinese' if item['language']=='en' else 'English'
        prompt = f'Translate the following text into {target}. Note that you should only output the translated result without any additional explanation:\n{item["source"]}'
        if args.contrast_hint:
            prompt = ('Preserve the scope of negation: distinguish a ruled-out explanation from the stated actual problem. '
                      'Do not turn an excluded cause into an actual cause.\n' + prompt)
        precision_hint = args.precision_hint and item['language'] == 'en' and all(
            re.search(pattern, item['source'], re.I) for pattern in
            [r'\bby\b', r'\bto\b', r'\b(reduced?|decreased?|increased?|fell|fall|rose|rise|grew|grow|cut)\b'])
        if args.precision_hint and args.cross_lingual_hint and item['language'] == 'zh':
            precision_hint = bool(re.search(r'(降低|减少|下降|增加|增长|上升|降)[到了]+', item['source']) and '到' in item['source'])
        if precision_hint:
            hint = "When translating numerical changes, distinguish the amount of change ('by') from the resulting value ('to'); preserve this distinction in both clauses."
            if args.percent_hint:
                hint += " A percent change is not a percentage-point change; do not substitute one for the other."
            prompt = hint + "\n" + prompt
        if item.get('context'):
            prompt = (f'[Background Information]\n{item["context"]}\n'
                      f'Please translate the following text into {target}, taking the provided background information into consideration. '
                      f'Only output the translated source text, not the background information.\n[Source Text]\n{item["source"]}')
            if args.speech_context:
                prompt = 'The source is an automatic speech transcript. Use context to resolve obvious transcription errors, but do not add information.\n' + prompt
        if args.glossary and item['language'] == 'en':
            terms = [('model weights', '模型权重'), ('key-value cache', '键值缓存'),
                ('key value cache', '键值缓存'), ('cache eviction', '缓存淘汰'),
                ('readiness probe', '就绪探针'), ('feature flag', '功能开关'),
                ('eventual consistency', '最终一致性'), ('memory leak', '内存泄漏')]
            domain = item.get('terminology_context', '').lower().replace('-', ' ')
            if args.domain_terms and any(cue in domain for cue in ['memory leak', 'model weights', 'key value cache']) and not re.search(
                r'\b(rent|rental|landlords?|tenants?|mortgages?|cash payments?)\b', domain + ' ' + item['source'].lower()):
                terms += [('cash eviction', '缓存淘汰'), ('key value cash', '键值缓存'), ('key-value cash', '键值缓存')]
            matched = [f'{source} -> {translation}' for source, translation in terms if source in item['source'].lower()]
            if matched:
                prompt = 'Use the following terminology:\n' + '\n'.join(matched) + '\n\n' + prompt
        body = dict(messages=[dict(role='user',content=prompt)], temperature=args.temperature, top_p=.6,
                    top_k=20, repeat_penalty=1.05, seed=42, max_tokens=384,
                    stream=False, cache_prompt=args.cache_prompt)
        start = time.perf_counter()
        endpoint = '/v1/chat/completions'
        if gemma_template is not None:
            # Preserve Google/model-publisher language metadata rather than
            # sending it through an OpenAI-compatible content sanitizer.
            def invalid_template(message): raise ValueError(message)
            prompt = gemma_template.render(bos_token='<bos>', add_generation_prompt=True,
                raise_exception=invalid_template, messages=[dict(role='user', content=[dict(
                    type='text', source_lang_code=item['language'],
                    target_lang_code='zh' if item['language']=='en' else 'en', text=item['source'])])])
            tokenize = urllib.request.Request(url+'/tokenize', headers=headers,
                data=json.dumps(dict(content=prompt, add_special=False, parse_special=True)).encode())
            with urllib.request.urlopen(tokenize, timeout=10) as response:
                tokens = json.load(response)['tokens']
            body = dict(prompt=tokens, temperature=args.temperature, n_predict=384,
                        stream=False, cache_prompt=args.cache_prompt, seed=42,
                        stop=['<end_of_turn>', '<eos>'])
            endpoint = '/completion'
        request = urllib.request.Request(url+endpoint,data=json.dumps(body).encode(),headers=headers)
        with urllib.request.urlopen(request,timeout=30) as response: result = json.load(response)
        choice = (dict(message=dict(content=result['content']),
                       finish_reason='length' if result.get('stopped_limit') else 'stop')
                  if gemma_template is not None else result['choices'][0])
        emit(event='translation', **item, target=choice['message']['content'],
             model=args.model, glossary=args.glossary,
             precision_hint=bool(precision_hint),
             temperature=args.temperature,
             cache_prompt=args.cache_prompt,
             cross_lingual_hint=args.cross_lingual_hint, percent_hint=args.percent_hint,
             prompt=prompt,
             seconds=time.perf_counter()-start, finish_reason=choice['finish_reason'],
             timings=result.get('timings'))
finally:
    process.terminate()
    try: process.wait(timeout=10)
    except subprocess.TimeoutExpired: process.kill(); process.wait()
    log.close()
