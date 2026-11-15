#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/home"
cp "$repo/Desk.qml" "$repo/WorkspaceDesk.qml" "$repo/Colors.js" "$repo/Storage.js" "$fixture/"
cp "$repo/tests/workspaces.qml" "$fixture/shell.qml"
ln -s /usr/share/omarchy/shell/Commons "$fixture/Commons"
ln -s /usr/share/omarchy/shell/Ui "$fixture/Ui"
HOME="$fixture/home" XDG_CACHE_HOME="$fixture/cache" timeout 15s quickshell -p "$fixture" --no-color
python - "$fixture/home" <<'PY'
import json
import pathlib
import sys
home = pathlib.Path(sys.argv[1])
for workspace, name in [(901, 'First'), (902, 'Second')]:
    board = json.loads((home / f'.local/share/boardhydra-desk/workspace-{workspace}.json').read_text())
    state = json.loads((home / f'.config/boardhydra-desk/workspace-{workspace}.json').read_text())
    assert board['columns'][0]['title'] == f'{name} workspace'
    assert state['boardId'] == f'board-{name.lower()}'
print('PASS: independent workspace files persisted')
PY
# Reuse successfully initialized data beneath a newly shared parent. The next
# startup must fail closed, and later UI save calls must not touch the files.
cp "$fixture/home/.local/share/boardhydra-desk/workspace-901.json" "$fixture/before.json"
chmod 777 "$fixture/home/.local/share"
cp "$repo/tests/storage-failure.qml" "$fixture/shell.qml"
HOME="$fixture/home" XDG_CACHE_HOME="$fixture/cache" timeout 15s quickshell -p "$fixture" --no-color
cmp "$fixture/before.json" "$fixture/home/.local/share/boardhydra-desk/workspace-901.json"
echo 'PASS: failed initialization cannot persist confidential cards'
