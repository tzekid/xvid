#!/usr/bin/env python3
"""Real-binary Instagram journeys; loopback fixture traffic, no account or network.

The request ledger is the important assertion: choosing a carousel child must
never acquire its neighbours. Python is test tooling only, not a runtime service.
"""
import contextlib
import http.client
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

BINARY = str(Path(sys.argv[1]).resolve())
ROOT = Path(__file__).resolve().parent.parent
REQUESTS = []
RESOLVES = {}
LOCK = threading.Lock()
PNG = (ROOT / 'assets/icon-180.png').read_bytes()
VIDEO = b''
ORIGIN = ''


def image(n):
    return {'pk': str(1000 + n), 'media_type': 1, 'image_versions2': {'candidates': [
        {'url': f'{ORIGIN}/original/{n}.png', 'width': 1080, 'height': 1350},
        {'url': f'{ORIGIN}/thumb/{n}.png', 'width': 180, 'height': 180},
    ]}}


def video(n):
    result = image(n)
    result.update(media_type=2, video_duration=1.0, video_versions=[
        {'url': f'{ORIGIN}/original/{n}.mp4', 'width': 320, 'height': 240},
    ])
    return result


def post(code):
    if code in ('SinglePhoto', 'GraphQL'):
        return dict(image(1), code=code)
    if code in ('SingleVideo', 'InvalidVideo'):
        value = dict(video(7), code=code)
        if code == 'InvalidVideo':
            value['video_versions'][0]['url'] = f'{ORIGIN}/original/not-video.mp4'
        return value
    if code == 'MissingVideo':
        return dict(image(2), code=code, media_type=2)
    if code == 'Incomplete':
        return dict(image(1), code=code, media_type=8, carousel_media_count=12)
    values = [image(n) for n in range(1, 13)]
    values[6] = video(7)
    values[2] = dict(image(3), media_type=2)  # unavailable video, not its poster
    if code in ('Renew', 'Disappeared'):
        if RESOLVES.get(code, 0) == 1:
            values[6]['video_versions'][0]['url'] = f'{ORIGIN}/original/expired.mp4'
        else:
            values[1], values[6] = values[6], values[1]
            if code == 'Disappeared':
                values[1] = image(22)
    if code == 'BadHost':
        values[6]['video_versions'][0]['url'] = 'http://169.254.169.254/secret'
    if code == 'Cancelled':
        values[6]['video_versions'][0]['url'] = f'{ORIGIN}/original/stall.mp4'
    return {'code': code, 'pk': '9000', 'media_type': 8, 'product_type': 'carousel_container',
            'carousel_media_count': 12, 'carousel_media': values, 'user': {'username': 'fixture'}}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def reply(self, status, body=b'', mime='application/json', headers=()):
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            if self.command != 'HEAD':
                self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        with LOCK:
            REQUESTS.append((self.command, path))
        if path.startswith('/share/'):
            return self.reply(302, headers=[('Location', '/p/Carousel/')])
        if path.startswith(('/p/', '/reel/')):
            code = path.strip('/').split('/')[1]
            with LOCK:
                RESOLVES[code] = RESOLVES.get(code, 0) + 1
            if code == 'Private':
                return self.reply(302, headers=[('Location', '/accounts/login/')])
            if code == 'Challenge':
                return self.reply(302, headers=[('Location', '/challenge/required/')])
            if code == 'Rate':
                return self.reply(429, headers=[('Retry-After', '1')])
            if code in ('GraphQL', 'Hydration'):
                body = b'<script type="application/json">["LSD",[],{"token":"fixture_lsd"}]</script>'
                if code == 'Hydration':
                    stub = dict(image(1), code=code, media_type=8, carousel_media_count=12)
                    body += b'<script type="application/json">' + json.dumps(stub).encode() + b'</script>'
                return self.reply(200, body, 'text/html', [('Set-Cookie', 'csrftoken=fixture_csrf; Path=/; HttpOnly')])
            data = json.dumps({'data': {'xdt_api__v1__media__shortcode__web_info': {'items': [post(code)]}}}).encode()
            if code == 'RepeatedMetadata':
                stub = dict(image(1), code=code, media_type=8, carousel_media_count=12)
                prefix = b'<script type="application/json">' + json.dumps(stub).encode() + b'</script>'
                return self.reply(200, prefix + b'<script type="application/json">' + data + b'</script>', 'text/html')
            # Real page extraction, not just a JSON endpoint masquerading as HTML.
            return self.reply(200, b'<html><script type="application/json" data-sjs>' + data + b'</script></html>', 'text/html')
        if path.startswith('/thumb/'):
            return self.reply(200, PNG, 'image/png')
        if path == '/original/expired.mp4':
            return self.reply(403)
        if path == '/original/not-video.mp4':
            return self.reply(200, b'<html>login page</html>', 'video/mp4')
        if path == '/original/stall.mp4':
            self.send_response(200)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Content-Length', str(len(VIDEO) * 50))
            self.send_header('Connection', 'close')
            self.end_headers()
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                self.wfile.write(VIDEO[:1024])
                self.wfile.flush()
                time.sleep(4)
            self.close_connection = True
            return
        if path.startswith('/original/'):
            if path.endswith('.mp4'):
                return self.reply(200, VIDEO, 'video/mp4')
            return self.reply(200, PNG, 'image/png')
        return self.reply(404)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        with LOCK:
            REQUESTS.append((self.command, urllib.parse.urlsplit(self.path).path))
        if self.path != '/graphql/query':
            return self.reply(404)
        values = urllib.parse.parse_qs(body.decode())
        code = json.loads(values['variables'][0])['shortcode']
        if code not in ('GraphQL', 'Hydration'):
            return self.reply(200, b'{"data":null}')
        assert self.headers.get('X-CSRFToken') == 'fixture_csrf', 'bootstrap cookie not propagated'
        assert self.headers.get('X-FB-LSD') == 'fixture_lsd', 'bootstrap LSD not propagated'
        assert values['doc_id'] == ['27128499623469141']
        return self.reply(200, b'for (;;);' + json.dumps({'data': {'xdt_api__v1__media__shortcode__web_info': {'items': [post(code)]}}}).encode())


def wait_until(predicate, description, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.04)
    raise AssertionError('timed out: ' + description)


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


with tempfile.TemporaryDirectory(prefix='xvid-instagram-') as directory:
    root = Path(directory)
    media = root / 'sample.mp4'
    subprocess.run(['ffmpeg', '-nostdin', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=10',
                    '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '1', '-c:v', 'libx264', '-threads', '1',
                    '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-movflags', '+faststart', str(media)], check=True)
    VIDEO = media.read_bytes()
    fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    fixture.daemon_threads = True
    ORIGIN = f'http://127.0.0.1:{fixture.server_port}'
    thread = threading.Thread(target=fixture.serve_forever, daemon=True)
    thread.start()
    port = free_port()
    config = root / 'config.json'
    config.write_text(json.dumps({
        'listen': f'127.0.0.1:{port}', 'public_origin': f'http://127.0.0.1:{port}', 'data_dir': str(root / 'data'),
        'instagram_origin': ORIGIN, 'instagram_timeout_seconds': 2,
        'probes_per_minute': 100, 'jobs_per_hour': 100, 'max_loaded_jobs': 64, 'rate_limit_capacity': 64,
        'max_download_bytes': 8 * 1024 * 1024, 'max_output_bytes': 8 * 1024 * 1024,
        'job_storage_budget_bytes': 128 * 1024 * 1024, 'minimum_free_bytes': 1024 * 1024,
        'cleanup_interval_seconds': 1, 'ffmpeg': shutil.which('ffmpeg'), 'ffprobe': shutil.which('ffprobe'),
    }))
    log = (root / 'server.log').open('wb')
    process = None

    def request(path, values=None, headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
        try:
            body = urllib.parse.urlencode(values) if values is not None else None
            request_headers = dict(headers or {})
            if body is not None:
                request_headers['Content-Type'] = 'application/x-www-form-urlencoded'
            connection.request('POST' if body is not None else 'GET', path, body=body, headers=request_headers)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def start():
        global process
        process = subprocess.Popen([BINARY, 'serve', '--config', str(config)], stdout=log, stderr=log)
        def ready():
            if process.poll() is not None:
                raise AssertionError('xvid exited during startup')
            try:
                return request('/readyz')[0] == 200
            except (OSError, http.client.HTTPException):
                return False
        wait_until(ready, 'server readiness')

    def manifest(job_path):
        try:
            return json.loads((root / 'data/jobs' / job_path.rsplit('/', 1)[1] / 'job.json').read_text())
        except (OSError, json.JSONDecodeError):
            return None

    def state(job_path, wanted):
        def check():
            value = manifest(job_path)
            if value and value['state'] in ('failed', 'cancelled') and value['state'] != wanted:
                raise AssertionError(value.get('failure') or value['state'])
            return value if value and value['state'] == wanted else None
        return wait_until(check, wanted)

    def create(code, route='p', extra=''):
        status, headers, _ = request('/jobs', {'url': f'https://www.instagram.com/{route}/{code}/{extra}'})
        assert status == 303, (status, headers)
        return urllib.parse.urlsplit(headers['location']).path

    def originals_since(index):
        with LOCK:
            return [path for _, path in REQUESTS[index:] if path.startswith('/original/')]

    try:
        start()
        marker = len(REQUESTS)
        location = create('Carousel', 'reel', '?img_index=7')
        data = state(location, 'awaiting_choice')
        assert data['probe']['item_count'] == 12
        assert data['probe']['instagram_plan']['highlighted_ordinal'] == 7
        assert data['selection'] is None
        assert originals_since(marker) == [], 'carousel originals fetched before selection'
        status, _, html = request(location)
        assert status == 200
        assert b'Tap one photo or video' in html and b'7 of 12' in html
        assert b'item_id' in html and b'lazy' in html
        assert b'169.254' not in html and ORIGIN.encode() not in html
        status, _, preview = request(location + '/thumbnail/1007')
        assert status == 200 and preview == PNG
        assert originals_since(marker) == [], 'thumbnail fetched an original'
        assert request(location + '/start', {'item_id': '1003'})[0] == 422, 'missing video was offered as a photo'
        assert request(location + '/start', {'item_id': 'not-in-post'})[0] == 422
        assert request(location + '/start', {'item_id': '1007'})[0] == 303
        data = state(location, 'ready')
        assert data['selection']['item_id'] == '1007'
        assert len(data['source_artifacts']) == 1 and data['output_artifacts'] == []
        assert originals_since(marker) == ['/original/7.mp4'], originals_since(marker)
        status, _, saved = request(location + '/artifact/file-1?download=1')
        assert status == 200 and saved == VIDEO
        status, _, part = request(location + '/artifact/file-1', headers={'Range': 'bytes=0-15'})
        assert status == 206 and part == VIDEO[:16]
        assert request(location + '/start', {'item_id': '1007'})[0] == 303
        assert request(location + '/start', {'item_id': '1008'})[0] == 409
        assert originals_since(marker) == ['/original/7.mp4']
        assert request(location + '/delete', {})[0] == 303
        print('PASS: ordered carousel, unavailable slot, preview, selected-only download, range, idempotency')

        for code in ('SinglePhoto', 'SingleVideo', 'GraphQL'):
            location = create(code)
            value = state(location, 'ready')
            assert value['selection']['item_id'] in ('1001', '1007')
            assert len(value['source_artifacts']) == 1
        print('PASS: single-media automatic acquisition and bootstrapped GraphQL')

        for code in ('Hydration', 'RepeatedMetadata'):
            marker = len(REQUESTS)
            location = create(code)
            value = state(location, 'awaiting_choice')
            assert value['probe']['item_count'] == 12
            assert originals_since(marker) == []
        print('PASS: incomplete hydration stubs continue to complete script or GraphQL metadata')

        marker = len(REQUESTS)
        location = create('Renew')
        state(location, 'awaiting_choice')
        assert request(location + '/start', {'item_id': '1007'})[0] == 303
        value = state(location, 'ready')
        assert value['source_artifacts'][0]['filename'].endswith('-7.mp4')
        assert originals_since(marker) == ['/original/expired.mp4', '/original/7.mp4']
        print('PASS: expired URL refresh preserves selected child across carousel reordering')

        for code in ('Incomplete', 'MissingVideo', 'Private', 'Challenge', 'InvalidVideo'):
            location = create(code)
            value = state(location, 'failed')
            assert value['source_artifacts'] == [] and value['failure']
        print('PASS: incomplete carousel, poster-only video, private/challenged post, invalid video fail honestly')

        marker = len(REQUESTS)
        location = create('Disappeared')
        state(location, 'awaiting_choice')
        request(location + '/start', {'item_id': '1007'})
        state(location, 'failed')
        assert originals_since(marker) == ['/original/expired.mp4']
        print('PASS: disappeared selected child never falls back to an array index')

        location = create('Carousel')
        state(location, 'awaiting_choice')
        process.terminate()
        process.wait(timeout=8)
        start()
        assert manifest(location)['state'] == 'awaiting_choice'
        marker = len(REQUESTS)
        request(location + '/start', {'item_id': '1004'})
        value = state(location, 'ready')
        assert value['selection']['item_id'] == '1004'
        assert originals_since(marker) == ['/original/4.png']
        print('PASS: persistent chooser survives restart')

        location = create('Cancelled')
        state(location, 'awaiting_choice')
        request(location + '/start', {'item_id': '1007'})
        state(location, 'acquiring')
        request(location + '/cancel', {})
        state(location, 'cancelled')
        time.sleep(2.3)
        assert manifest(location)['source_artifacts'] == []
        print('PASS: cancelled transfer publishes no artifact')

        location = create('Rate')
        state(location, 'failed')
        assert manifest(location)['failure']['code'] == 'INSTAGRAM_BUSY'
        print('PASS: rate-limit classification')
        print('Instagram real-binary E2E: all checks passed')
    except BaseException:
        log.flush()
        print((root / 'server.log').read_text(errors='replace'), file=sys.stderr)
        raise
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        fixture.shutdown()
        log.close()
