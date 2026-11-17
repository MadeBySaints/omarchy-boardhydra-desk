import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

folder = pathlib.Path(sys.argv[1])
card = dict(id='test-card', idList='todo', name='No due date', due=None, dueComplete=False, closed=False, pos=1)
patches = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, code, data):
        payload = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == '/api/v1/boards/test-board':
            self.reply(200, dict(board=dict(name='Test'), lists=[dict(id='todo', name='To do', pos=1), dict(id='done', name='Done', pos=2)], cards=[card]))
        elif self.path.endswith('/attachments'):
            self.reply(200, [])
        else:
            self.reply(404, dict(error='Unknown test route'))

    def do_PATCH(self):
        assert self.path == '/api/v1/cards/test-card'
        patch = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert set(patch) == {'dueComplete'} and type(patch['dueComplete']) is bool
        patches.append(patch)
        (folder / 'patches.json').write_text(json.dumps(patches))
        if len(patches) == 2:
            self.reply(403, dict(error='Rejected test write'))
            return
        card.update(patch)
        if len(patches) == 1:
            card['idList'] = 'done'
        if len(patches) == 4:
            card['closed'] = True
        self.reply(200, card)


server = HTTPServer(('127.0.0.1', 0), Handler)
(folder / 'port').write_text(str(server.server_port))
server.serve_forever()
