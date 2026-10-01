#!/usr/bin/env python3
"""Exercise Mecum's real Chrome adapter on synthetic loopback pages. No provider or personal profile access."""
import argparse
import json
from pathlib import Path
import select
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from websockets.sync.client import connect as websocket_connect

PAGE = rb"""<!doctype html><html><head><title>Mecum browser fixture</title></head><body>
<h1>Mecum browser fixture</h1><p id="cookie"></p>
<label>Name <input aria-label="Name"></label><label>Secret <input type="password" aria-label="Secret"></label>
<label>Format <select aria-label="Format"><option value="mono">Mono</option><option value="stereo">Stereo</option></select></label>
<label><input type="checkbox" aria-label="Enabled">Enabled</label>
<button id="increment" onclick="document.getElementById('result').textContent='Clicks: '+(++window.clicks)">Increment</button>
<p id="result">Clicks: 0</p>
<button onclick="document.getElementById('increment').textContent='Different meaning'">Rename target</button>
<button onclick="history.pushState({},'', '#changed')">Change route</button>
<button onclick="alert('Synthetic dialog')">Open dialog</button>
<button id="obscured" style="position:absolute;left:10px;top:400px">Covered</button>
<div style="position:absolute;left:0;top:390px;width:200px;height:80px;background:#333;z-index:20"></div>
<div id="shadow"></div><iframe title="Synthetic frame" src="/frame"></iframe>
<div style="height:1200px"></div><button>Bottom</button>
<script>
window.clicks=0;
document.getElementById('cookie').textContent='Cookie: '+(document.cookie.includes('mecumSynthetic=present')?'present':'missing');
document.cookie='mecumSynthetic=present; Max-Age=3600; SameSite=Strict';
const s=document.getElementById('shadow').attachShadow({mode:'open'});
s.innerHTML='<button onclick="this.textContent=\'Shadow clicked\'">Shadow button</button>';
</script></body></html>"""
TEXT_TARGETS = b"""<!doctype html><title>Text target fixture</title>
<style>.choice{padding:12px;cursor:pointer}</style>
<div role="dialog" aria-label="Trip type">
<div class="choice" onclick="result.textContent='Trip: one way; clicks: '+(++clicks)"><span>Solo andata</span></div>
<div class="choice" aria-disabled="true" onclick="result.textContent='BAD disabled'"><span>Disabled choice</span></div>
<fieldset disabled><label><input type="radio" aria-label="Unavailable radio">Disabled native choice</label></fieldset>
<div class="choice" inert><span>Inert choice</span></div>
<div style="position:relative;width:240px"><span>Covered text</span>
<div style="position:absolute;inset:0;background:#333;z-index:20" aria-hidden="true"></div></div>
<label><input type="radio" name="trip" onchange="result.textContent='Trip: return'">Return trip</label>
<div style="width:90px" onclick="result.textContent='Wrapped selected'"><span>A long wrapped choice across several lines</span></div>
<button id="rename" onclick="document.querySelector('#renamed').textContent='Different choice'">Rename text</button>
<div onclick="result.textContent='BAD stale'"><span id="renamed">Original choice</span></div>
</div><p id="result">No selection</p>
<script>let clicks=0;</script>"""

BACKGROUND = b"""<!doctype html><title>Background input fixture</title>
<button onclick="this.textContent=document.visibilityState==='visible'&&document.hasFocus()?'Background click verified':'Inactive click'">Background probe</button>"""

FRAME = b"""<html><body><button onclick="this.textContent='Frame clicked'">Frame button</button></body></html>"""

FEED = b"""<!doctype html><title>Synthetic growing feed</title>
<style>article{height:230px;padding:12px;border:1px solid #555}</style><main></main><script>
let count=0,busy=false;
function append(){for(let i=0;i<5&&count<30;i++,count++){
let a=document.createElement('article');a.id='post-'+count;
a.innerHTML='<h2>Invented article '+count+'</h2><p>Synthetic text '+count+'</p><a rel="bookmark" href="https://example.invalid/post/'+count+'">Permalink</a>';
document.querySelector('main').append(a);}busy=false;}
append();addEventListener('scroll',()=>{if(!busy&&count<30){busy=true;setTimeout(append,250)}});
</script>"""

class PageServer(BaseHTTPRequestHandler):
    def do_GET(self):
        body = BACKGROUND if self.path == '/background' else TEXT_TARGETS if self.path == '/text-targets' else FRAME if self.path == '/frame' else FEED if self.path == '/feed' else PAGE
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

class Client:
    def __init__(self, binary, profile):
        self.process = subprocess.Popen([str(binary), 'browser', '--automation-profile', str(profile)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.connection = None
    def call(self, name, **args):
        if self.connection is not None and name not in ('connect', 'status'):
            args['connection'] = self.connection
        self.process.stdin.write(json.dumps({'tool':'browser_'+name,'arguments':args})+'\n')
        self.process.stdin.flush()
        ready, _, _ = select.select([self.process.stdout], [], [], 55)
        if not ready:
            raise AssertionError('Timed out waiting for '+name)
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError('CLI exited while running '+name)
        result = json.loads(line)
        if result.get('isError'):
            raise RuntimeError(result.get('structuredContent', result))
        if name == 'connect':
            self.connection = result['structuredContent']['id']
        return result.get('structuredContent', result)
    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            self.process.wait(timeout=20)
            assert self.process.returncode == 0

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path('.build/debug/mecum'))
    parser.add_argument('--chrome', type=Path, default=Path('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'))
    parser.add_argument('--artifacts', type=Path, required=True)
    args=parser.parse_args()
    args.artifacts.mkdir(parents=True,exist_ok=True)
    server=ThreadingHTTPServer(('127.0.0.1',0),PageServer)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    url=f'http://127.0.0.1:{server.server_port}/'
    checks=[]
    def passed(name):
        checks.append(name)
        print('PASS '+name,flush=True)
    with tempfile.TemporaryDirectory(prefix='mecum-browser-fixture-') as temporary:
        profile=Path(temporary)/'profile'
        chrome=None
        client=None
        def launch():
            p=subprocess.Popen([str(args.chrome),'--headless=new','--no-first-run','--no-default-browser-check',
                '--remote-debugging-port=0','--remote-debugging-address=127.0.0.1','--window-size=1100,900',
                '--user-data-dir='+str(profile),'about:blank'], stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            endpoint=profile/'DevToolsActivePort'
            deadline=time.monotonic()+15
            while not endpoint.exists() and time.monotonic()<deadline:
                if p.poll() is not None: raise AssertionError('Synthetic Chrome exited')
                time.sleep(.05)
            assert endpoint.exists()
            return p
        try:
            chrome=launch()
            client=Client(args.binary.resolve(),profile)
            connection=client.call('connect',profile='automation')
            assert connection['profile']=='automation'
            passed('native Chrome connection')
            tab=client.call('open',url=url)['id']
            def snap():
                return client.call('snapshot',tab=tab)
            def find(s,name,role=None):
                hits=[n for n in s['nodes'] if n['name']==name and (role is None or n['role']==role)]
                assert len(hits)==1,(name,[(n['name'],n['role']) for n in hits],s['limitations'])
                return hits[0]['ref']
            def node_action(action,name,role=None,**kw):
                s=snap()
                if role is None and action == 'click': role = 'button'
                return client.call(action,tab=tab,snapshot=s['id'],ref=find(s,name,role),**kw)
            deadline=time.monotonic()+10
            while True:
                s=snap()
                if any(n['name']=='Increment' for n in s['nodes']): break
                assert time.monotonic()<deadline
                time.sleep(.05)
            assert any(n['name']=='Frame button' for n in s['nodes'])
            assert any(n['name']=='Shadow button' for n in s['nodes'])
            passed('semantic snapshot, shadow DOM and same-process iframe')
            assert node_action('fill','Name',text='Synthetic Mecum')['status']=='verified'
            assert node_action('fill','Name',text='')['status']=='verified'
            passed('fill and clear verified')
            assert node_action('fill','Secret',text='SYNTHETIC-SECRET')['status']=='verified'
            assert 'SYNTHETIC-SECRET' not in json.dumps(snap())
            passed('password value is not exposed in snapshot')
            assert node_action('select','Format',value='Stereo')['status']=='verified'
            assert node_action('set_checked','Enabled',role='checkbox',checked=True)['status']=='verified'
            passed('native select and checkbox verified')
            s=snap()
            ref=find(s,'Increment','button')
            client.call('click',tab=tab,snapshot=s['id'],ref=ref)
            assert any(n['name']=='Clicks: 1' for n in snap()['nodes'])
            try:
                client.call('click',tab=tab,snapshot=s['id'],ref=ref)
                raise AssertionError('Stale snapshot accepted')
            except RuntimeError: pass
            passed('click outcome observed; used references rejected')
            node_action('click','Shadow button')
            assert any(n['name']=='Shadow clicked' for n in snap()['nodes'])
            node_action('click','Frame button')
            assert any(n['name']=='Frame clicked' for n in snap()['nodes'])
            passed('shadow DOM and iframe click')
            try:
                node_action('click','Covered')
                raise AssertionError('Covered control clicked')
            except RuntimeError: pass
            passed('occluded control refused')
            s=snap()
            client.call('navigate',tab=tab,url=url+'second')
            time.sleep(.15)
            try:
                client.call('click',tab=tab,snapshot=s['id'],ref=find(s,'Increment','button'))
                raise AssertionError('Pre-navigation reference accepted')
            except RuntimeError: pass
            passed('navigation invalidates references')
            node_action('click','Open dialog')
            dialog=client.call('dialog',tab=tab)['dialog']
            assert dialog['message']=='Synthetic dialog'
            client.call('handle_dialog',tab=tab,accept=True)
            passed('JavaScript dialog observed and handled')
            import base64
            shot=client.call('screenshot',tab=tab)
            png=base64.b64decode(shot['content'][0]['data'])
            assert png.startswith(b'\x89PNG\r\n\x1a\n')
            (args.artifacts/'fixture.png').write_bytes(png)
            passed('PNG screenshot')
            original_tab = tab
            tab = client.call('open', url=url+'text-targets')['id']
            deadline=time.monotonic()+5
            while not any(n['name']=='Solo andata' for n in snap()['nodes']):
                assert time.monotonic()<deadline
                time.sleep(.05)
            node_action('click', 'Solo andata', role='StaticText')
            # A page-wide read also checks the outcome outside the focused dialog.
            assert any(n['name']=='Trip: one way; clicks: 1' for n in client.call('snapshot',tab=tab,scope='page')['nodes'])
            passed('custom dialog StaticText click delivered exactly once')
            for name in ['Disabled choice', 'Disabled native choice', 'Covered text']:
                try:
                    node_action('click', name, role='StaticText')
                    raise AssertionError('Unsafe text target accepted: '+name)
                except RuntimeError: pass
            assert not any(n['name']=='Inert choice' for n in snap()['nodes'])
            assert not any('BAD' in n['name'] for n in client.call('snapshot',tab=tab,scope='page')['nodes'])
            passed('disabled ancestors, native labels, inert and occluded text refused')
            node_action('click','Return trip',role='radio')
            assert any(n['name']=='Trip: return' for n in client.call('snapshot',tab=tab,scope='page')['nodes'])
            node_action('click','A long wrapped choice across several lines',role='StaticText')
            assert any(n['name']=='Wrapped selected' for n in client.call('snapshot',tab=tab,scope='page')['nodes'])
            passed('native label and wrapped text targets')
            client.call('close',tab=tab)
            tab=original_tab
            journey = client.call('open', url=(Path(__file__).parent/'Fixtures/browser-journey.html').resolve().as_uri())
            tab = journey['id']
            observation = journey.get('observation')
            def journey_action(action, name, role, **values):
                nonlocal observation
                deadline = time.monotonic()+5
                while True:
                    if observation:
                        hits=[n for n in observation['nodes'] if n['name']==name and n['role']==role]
                        if len(hits)==1: break
                    assert time.monotonic()<deadline, (name, observation)
                    time.sleep(.05)
                    observation=client.call('snapshot',tab=tab)
                result=client.call(action,tab=tab,snapshot=observation['id'],ref=hits[0]['ref'],**values)
                assert result['status'] in ('verified','delivered'),result
                observation=result.get('observation')
            journey_action('fill','Destination','combobox',text='Southhaven')
            journey_action('click','Southhaven (SHV)','option')
            journey_action('click','Trip type: return','button')
            journey_action('click','Solo andata','StaticText')
            journey_action('click','Departure date','button')
            journey_action('click','Tomorrow evening','button')
            journey_action('click','Travelers: 1 adult','button')
            journey_action('click','Add adult','button')
            journey_action('click','Add adult','button')
            journey_action('click','Done','button')
            journey_action('click','Search synthetic trips','button')
            assert any(n['name']=='Trip confirmed: Northport to Southhaven, one way, tomorrow evening, 3 adults.' for n in observation['nodes']),observation
            assert any(n['name']=='Search submissions: 1' for n in observation['nodes']),observation
            shot=client.call('screenshot',tab=tab)
            (args.artifacts/'journey.png').write_bytes(base64.b64decode(shot['content'][0]['data']))
            passed('complete synthetic journey uses returned observations, delayed suggestions and custom text options')
            client.call('close',tab=tab)
            tab=original_tab
            feed = client.call('open', url=url+'feed')['id']
            collected = client.call('collect', tab=feed, count=30, maxScrolls=12)
            assert collected['stopReason']=='countReached', collected
            assert {item['identity'] for item in collected['items']} == {
                f'url:https://example.invalid/post/{i}' for i in range(30)}
            assert 1 <= collected['scrolls'] <= 12
            assert not any(item['truncated'] for item in collected['items'])
            passed('bounded article collection loads and deduplicates 30 synthetic posts')
            limited = client.call('collect', tab=feed, count=50, maxScrolls=0)
            assert limited['stopReason']=='scrollLimit' and limited['scrolls']==0
            assert len(limited['items'])==30
            passed('article collection preserves partial results at its scroll budget')
            client.call('close', tab=feed)
            # Keep an independent observer attached to prove emulation is released, not tab activation.
            lines=(profile/'DevToolsActivePort').read_text().splitlines()
            with websocket_connect('ws://127.0.0.1:'+lines[0]+lines[1],proxy=None) as observer:
                sequence=0
                def cdp(method,params=None,session=None):
                    nonlocal sequence
                    sequence+=1
                    request={'id':sequence,'method':method,'params':params or {}}
                    if session: request['sessionId']=session
                    observer.send(json.dumps(request))
                    while True:
                        reply=json.loads(observer.recv(timeout=10))
                        if reply.get('id')==sequence:
                            assert 'error' not in reply,reply
                            return reply.get('result',{})
                sentinel=cdp('Target.createTarget',{'url':'about:blank','background':False})['targetId']
                sentinel_session=cdp('Target.attachToTarget',{'targetId':sentinel,'flatten':True})['sessionId']
                background=client.call('open',url=url+'background')
                target=next(t['targetId'] for t in cdp('Target.getTargets')['targetInfos'] if t['url']==url+'background')
                reading_session=cdp('Target.attachToTarget',{'targetId':target,'flatten':True})['sessionId']
                def visibility(session):
                    return cdp('Runtime.evaluate',{'expression':'document.visibilityState','returnByValue':True},session)['result']['value']
                assert visibility(reading_session)=='hidden'
                assert visibility(sentinel_session)=='visible'
                deadline=time.monotonic()+5
                while True:
                    reading=client.call('snapshot',tab=background['id'])
                    if any(n['name']=='Background probe' for n in reading['nodes']): break
                    assert time.monotonic()<deadline,reading
                    time.sleep(.05)
                ref=find(reading,'Background probe','button')
                response=client.call('click',tab=background['id'],snapshot=reading['id'],ref=ref)
                assert any(n['name']=='Background click verified' for n in response['observation']['nodes']),response
                assert visibility(sentinel_session)=='visible','Engine activated the background tab'
                client.call('disconnect')
                deadline=time.monotonic()+2
                while visibility(reading_session)!='hidden' and time.monotonic()<deadline: time.sleep(.02)
                assert visibility(reading_session)=='hidden','Emulation survived disconnect'
                assert visibility(sentinel_session)=='visible'
                passed('background input keeps the foreground tab and releases focus emulation on disconnect')
            client.close();client=None
            # Graceful shutdown flushes Chrome's profile. SIGTERM would test a crash, not normal persistence.
            endpoint_lines=(profile/'DevToolsActivePort').read_text().splitlines()
            with websocket_connect('ws://127.0.0.1:'+endpoint_lines[0]+endpoint_lines[1], proxy=None) as socket:
                socket.send(json.dumps({'id':1,'method':'Browser.close'}))
                socket.recv(timeout=10)
            chrome.wait(timeout=15);chrome=None
            endpoint=profile/'DevToolsActivePort'
            if endpoint.exists(): endpoint.unlink()
            chrome=launch()
            client=Client(args.binary.resolve(),profile)
            client.call('connect',profile='automation')
            tab=client.call('open',url=url)['id']
            time.sleep(.2)
            assert any(n['name']=='Cookie: present' for n in snap()['nodes'])
            passed('synthetic cookie survives disconnect and full browser restart without copying')
            client.call('close',tab=tab)
            assert tab not in [t['id'] for t in client.call('tabs')['tabs']]
            passed('explicit tab close')
            (args.artifacts/'result.json').write_text(json.dumps({'checks':checks,'browser':connection['browser']},indent=2))
        finally:
            if client: client.close()
            if chrome:
                chrome.terminate()
                try: chrome.wait(timeout=15)
                except subprocess.TimeoutExpired: chrome.kill();chrome.wait()
            server.shutdown()
    print(f'{len(checks)} browser checks passed',flush=True)

if __name__=='__main__': main()
