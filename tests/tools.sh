#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
server_pid=''
cleanup() {
  if [[ -n $server_pid ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf -- "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/local" "$fixture/remote/.config/boardhydra-desk"
cp "$repo/Desk.qml" "$repo/BoardDesk.qml" "$repo/Colors.js" "$repo/Storage.js" "$repo/SharedEnvironment.qml" "$repo/Appearance.js" "$repo/AppearancePicker.qml" "$repo/BoardTools.js" "$repo/BoardToolsPanel.qml" "$fixture/"
cp "$repo/tests/tools.qml" "$fixture/shell.qml"
ln -s /usr/share/omarchy/shell/Commons "$fixture/Commons"
ln -s /usr/share/omarchy/shell/Ui "$fixture/Ui"
HOME="$fixture/local" XDG_CACHE_HOME="$fixture/cache" timeout 20s quickshell -p "$fixture" --no-color
python "$repo/tests/tools-api.py" "$fixture" &
server_pid=$!
for ((i=0; i<50; i++)); do [[ -f $fixture/port ]] && break; sleep 0.1; done
python - "$fixture" <<'PY'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
port = (folder / 'port').read_text()
(folder / 'remote/.config/boardhydra-desk/config.json').write_text(json.dumps(dict(apiUrl='http://127.0.0.1:'+port, apiKey='bh_live_test12345678', boardId='test-board', live=False)))
PY
BOARDHYDRA_TEST_SYNC=1 HOME="$fixture/remote" XDG_CACHE_HOME="$fixture/cache" timeout 20s quickshell -p "$fixture" --no-color
python - "$fixture" <<'PY'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
for home in ['local', 'remote']:
    templates = json.loads((folder / home / '.local/share/boardhydra-desk/templates.json').read_text())
    assert len(templates) == 1 and templates[0]['name'] == 'Review'
events = json.loads((folder / 'events.json').read_text())
assert len([event for event in events if event['method'] == 'POST']) == 2
cards = {card['id']: card for card in json.loads((folder / 'cards.json').read_text())}
assert cards['c1']['closed'] and cards['c2']['closed']
assert cards['new-1']['idLabels'] == ['old-label', 'new-label']
assert cards['new-1']['idMembers'] == ['old-member', 'new-member']
assert not cards['new-1']['dueComplete']
assert cards['new-1']['checklists'][0]['checkItems'][0]['state'] == 'incomplete'
assert cards['new-2']['desc'] == ''
assert len([e for e in events if e.get('id') == 'new-1' and e['body'] == {'dueComplete': True}]) == 1
assert not [e for e in events if e.get('id') == 'new-2' and e['body'] == {'dueComplete': True}]
print('PASS: template persistence, API payloads, preserved labels/members and partial creation')
PY
