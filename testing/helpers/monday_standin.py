#!/usr/bin/env python3
"""A local stand-in for Monday's API, for the testing kit (12 Nov 2026; the 7 Oct one never reached the repo).

run_monday_sync('http://127.0.0.1:8765/') reads this instead of api.monday.com. It answers the sync's
board query with two jobs on the Orders board, PROJ-09001 (In Production) and PROJ-09002 (Pre-Production),
in the shape Monday sends: boards → items_page → items, each with column_values {id, text}. Any GET answers
200 "ok" (the tests use it to see the server is up, and as an address to try to reach).

    setsid python3 monday_standin.py &      # port 8765; PORT=… for another
"""
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer

COL_PROJ, COL_DATE, COL_PHASE = 'text_mm0wnntf', 'date_mkwjd2an', 'color_mkwqppkb'

def item(i, proj, name, date, phase):
    return {'id': str(i), 'name': f'{proj} - {name}',
            'column_values': [{'id': COL_PROJ, 'text': proj}, {'id': COL_DATE, 'text': date}, {'id': COL_PHASE, 'text': phase}],
            'subitems': []}

ITEMS = [item(900001, 'PROJ-09001', 'Stand-in job A', '2026-12-01', 'In Production'),
         item(900002, 'PROJ-09002', 'Stand-in job B', '2026-12-15', 'Pre-Production')]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, ctype='application/json'):
        b = body.encode()
        self.send_response(code); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(b))); self.end_headers()
        self.wfile.write(b)
    def do_GET(self): self._send(200, 'ok', 'text/plain')
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        try: q = json.loads(self.rfile.read(n) or b'{}').get('query', '')
        except Exception: q = ''
        if not self.headers.get('Authorization'):
            return self._send(401, json.dumps({'errors': ['Not Authenticated']}))
        if 'next_items_page' in q:
            return self._send(200, json.dumps({'data': {'next_items_page': {'cursor': None, 'items': []}}}))
        if 'items_page' in q:
            return self._send(200, json.dumps({'data': {'boards': [{'items_page': {'cursor': None, 'items': ITEMS}}]}}))
        self._send(200, json.dumps({'data': {'boards': [{'columns': []}]}}))

if __name__ == '__main__':
    HTTPServer(('127.0.0.1', int(os.environ.get('PORT', '8765'))), H).serve_forever()
