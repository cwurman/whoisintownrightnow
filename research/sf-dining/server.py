#!/usr/bin/env python3
"""Local-only Supper demo. Run: python3 research/sf-dining/server.py --port 8787."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from web_search import RESTAURANTS, catalog, local_search, normalize_options, rerank, serialize

WEB = Path(__file__).parent / 'web'
STATIC = {'/': ('index.html', 'text/html'), '/app.js': ('app.js', 'text/javascript'),
          '/state.js': ('state.js', 'text/javascript'), '/styles.css': ('styles.css', 'text/css'),
          '/favicon.svg': ('favicon.svg', 'image/svg+xml')}


class Handler(BaseHTTPRequestHandler):
    def send(self, status, body, mime='application/json'):
        if not isinstance(body, bytes):
            body = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', mime + '; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' https://lh3.googleusercontent.com https://lh5.googleusercontent.com https://lh3.ggpht.com data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def valid_host(self):
        return self.headers.get('Host') in {f'localhost:{self.server.server_port}', f'127.0.0.1:{self.server.server_port}'}

    def do_GET(self):
        if not self.valid_host():
            return self.send(403, {'error': 'Local requests only.'})
        url = urlsplit(self.path)
        if url.path in STATIC:
            name, mime = STATIC[url.path]
            return self.send(200, (WEB / name).read_bytes(), mime)
        try:
            params = parse_qs(url.query)
            if url.path == '/api/catalog':
                return self.send(200, catalog())
            if url.path == '/api/search':
                options = normalize_options({'query': params.get('q', [''])[0], 'scope': params.get('scope', ['nearby'])[0],
                                             'sort': params.get('sort', ['relevance'])[0], 'neighborhoods': params.get('neighborhood', [])})
                return self.send(200, local_search(options))
            if url.path == '/api/restaurant':
                rid = params.get('id', [''])[0]
                if rid not in RESTAURANTS:
                    return self.send(404, {'error': 'Restaurant not found.'})
                return self.send(200, serialize(rid))
            return self.send(404, {'error': 'Not found.'})
        except ValueError as error:
            return self.send(400, {'error': str(error)})

    def do_POST(self):
        origin = self.headers.get('Origin')
        if not self.valid_host() or origin not in {f'http://localhost:{self.server.server_port}', f'http://127.0.0.1:{self.server.server_port}'}:
            return self.send(403, {'error': 'Local same-origin requests only.'})
        if self.path != '/api/rerank':
            return self.send(404, {'error': 'Not found.'})
        try:
            size = int(self.headers.get('Content-Length', 0))
            if not 0 < size <= 4096:
                return self.send(413, {'error': 'Request too large.'})
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict):
                raise ValueError('Expected a search object.')
            options = normalize_options(body)
            return self.send(200, rerank(options))
        except (ValueError, TypeError) as error:
            return self.send(400, {'error': str(error)})

    def log_message(self, fmt, *args):
        # Do not log request bodies or credentials.
        super().log_message(fmt, *args)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8787)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    print(f'Supper is running at http://localhost:{args.port}', flush=True)
    server.serve_forever()
