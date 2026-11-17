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
mkdir -p "$fixture/home/.local/share/boardhydra-desk" "$fixture/home/.config/boardhydra-desk"
cp "$repo/Desk.qml" "$repo/BoardDesk.qml" "$repo/Colors.js" "$repo/Storage.js" "$repo/SharedEnvironment.qml" "$repo/Appearance.js" "$repo/AppearancePicker.qml" "$repo/BoardTools.js" "$repo/BoardToolsPanel.qml" "$fixture/"
cp "$repo/tests/shared-board.qml" "$fixture/shell.qml"
ln -s /usr/share/omarchy/shell/Commons "$fixture/Commons"
ln -s /usr/share/omarchy/shell/Ui "$fixture/Ui"
python - "$fixture/home" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
data = home / '.local/share/boardhydra-desk'
state = home / '.config/boardhydra-desk'
(data / 'workspace-1.json').write_text(json.dumps(dict(columns=[dict(title='Migrated', cards=[dict(id='test-card', text='Complete without a date')])])))
(state / 'workspace-1.json').write_text(json.dumps(dict(boardId='migrated-board', appearance=dict(preset='holo'))))
(data / 'board.json').write_text('{"columns": []}')
(state / 'state.json').write_text('{"boardId": "old-board"}')
PY
HOME="$fixture/home" XDG_CACHE_HOME="$fixture/cache" timeout 15s quickshell -p "$fixture" --no-color
python - "$fixture/home" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
data = home / '.local/share/boardhydra-desk'
state = home / '.config/boardhydra-desk'
assert json.loads((data / 'board.json').read_text())['columns'][0]['cards'][0]['dueComplete']
assert not json.loads((data / 'board-before-shared.json').read_text())['columns']
assert json.loads((state / 'state-before-shared.json').read_text())['boardId'] == 'old-board'
assert (data / 'workspace-1.json').exists()
assert (state / 'workspace-1.json').exists()
print('PASS: local completion saved; migration retained old files')
PY
python "$repo/tests/mock-api.py" "$fixture" &
server_pid=$!
for ((i=0; i<50; i++)); do [[ -f $fixture/port ]] && break; sleep 0.1; done
python - "$fixture" <<'PY'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
port = (folder / 'port').read_text()
(folder / 'home/.config/boardhydra-desk/config.json').write_text(json.dumps(dict(apiUrl='http://127.0.0.1:'+port, apiKey='bh_live_test12345678', boardId='test-board', live=False)))
(folder / 'home/.config/boardhydra-desk/state.json').write_text('{}')
PY
BOARDHYDRA_TEST_SYNC=1 HOME="$fixture/home" XDG_CACHE_HOME="$fixture/cache" timeout 15s quickshell -p "$fixture" --no-color
python - "$fixture" <<'PY'
import json, pathlib, sys
patches = json.loads((pathlib.Path(sys.argv[1]) / 'patches.json').read_text())
assert patches == [dict(dueComplete=v) for v in [True, False, False, True]], patches
print('PASS: exact completion API route and payload, failure rollback, automation move and archive')
PY

# Previously initialized storage must remain unchanged if ancestry becomes unsafe.
cp "$fixture/home/.local/share/boardhydra-desk/board.json" "$fixture/before-board.json"
cp "$fixture/home/.config/boardhydra-desk/state.json" "$fixture/before-state.json"
chmod 777 "$fixture/home/.local/share"
rm -f "$fixture/home/.config/boardhydra-desk/config.json"
cp "$repo/tests/storage-failure.qml" "$fixture/shell.qml"
HOME="$fixture/home" XDG_CACHE_HOME="$fixture/cache" timeout 15s quickshell -p "$fixture" --no-color
cmp "$fixture/before-board.json" "$fixture/home/.local/share/boardhydra-desk/board.json"
cmp "$fixture/before-state.json" "$fixture/home/.config/boardhydra-desk/state.json"
[[ ! -e "$fixture/home/.local/share/boardhydra-desk/templates.json" ]]
echo 'PASS: failed initialization cannot persist cards, state or templates'
