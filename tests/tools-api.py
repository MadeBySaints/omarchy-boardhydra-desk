import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

folder = pathlib.Path(sys.argv[1])
raw = [dict(id='old-list', name='Steps', checkItems=[dict(id='old-item', name='Review', state='complete', children=[dict(id='old-child', name='Check', state='complete')])])]
cards = [dict(id=key, idList='todo', name=title, desc='Needle in description' if key == 'c1' else '', dueComplete=False, closed=False, pos=i + 1, idLabels=['old-label'], idMembers=['old-member'], checklists=raw if key == 'c1' else []) for i, (key, title) in enumerate([('c1', 'Alpha'), ('c2', 'Beta')])]
events = []
rejected = False
created = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, data):
        content = json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)
        (folder / 'events.json').write_text(json.dumps(events))
        (folder / 'cards.json').write_text(json.dumps(cards))

    def do_GET(self):
        if self.path == '/api/v1/boards/test-board':
            self.reply(200, dict(board=dict(name='Test'), lists=[dict(id='todo', name='To do', pos=1), dict(id='done', name='Done', pos=2)], cards=cards,
                                 labels=[dict(id=x, name=x, color='blue') for x in ['old-label', 'new-label']], members=[dict(id=x, fullName=x) for x in ['old-member', 'new-member']]))
        elif self.path.endswith('/attachments'):
            self.reply(200, [])
        else:
            self.reply(404, dict(error='Unknown test route'))

    def do_POST(self):
        global created
        assert self.path == '/api/v1/boards/test-board/cards'
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        events.append(dict(method='POST', body=body))
        created += 1
        card = dict(id=f'new-{created}', idList=body['idList'], name=body['name'], pos=body['pos'], desc='', dueComplete=False, closed=False, idLabels=[], idMembers=[], checklists=[])
        cards.append(card)
        self.reply(200, card)

    def do_PATCH(self):
        global rejected
        key = self.path.removeprefix('/api/v1/cards/')
        assert key != self.path
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        events.append(dict(method='PATCH', id=key, body=body))
        if key == 'c2' and body == dict(dueComplete=True) and not rejected:
            rejected = True
            self.reply(403, dict(error='Test rejection'))
            return
        if key == 'new-1' and body == dict(dueComplete=True):
            self.reply(429, dict(error='Test rate limit'))
            return
        if key == 'new-2':
            self.reply(403, dict(error='Template details rejected'))
            return
        card = next(card for card in cards if card['id'] == key)
        card.update(body)
        self.reply(200, card)


server = HTTPServer(('127.0.0.1', 0), Handler)
(folder / 'port').write_text(str(server.server_port))
server.serve_forever()
