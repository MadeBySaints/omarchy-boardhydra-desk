#!/usr/bin/env bash
# Connect the BoardHydra desktop board to one of your real boards.
# Writes ~/.config/boardhydra-desk/config.json (mode 600). Uses 2 API requests.
set -euo pipefail

CONF_DIR="$HOME/.config/boardhydra-desk"
CONF="$CONF_DIR/config.json"
API_URL="${BOARDHYDRA_API_URL:-https://boardhydra.com}"
API_URL="${API_URL%/}"

echo "BoardHydra desktop board setup"
echo "Create an API key in the app (Settings → API keys) if you don't have one."
echo
read -rsp "API key (bh_live_…, input hidden): " KEY; echo
if [[ ! "$KEY" =~ ^bh_live_[A-Za-z0-9_-]{8,200}$ ]]; then
  echo "That doesn't look like a BoardHydra API key (it should start with bh_live_)." >&2; exit 1
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
call() { # path -> body in $TMP/out, prints HTTP status
  curl -sS --max-time 15 --max-filesize 10485760 -o "$TMP/out" -w '%{http_code}' \
    -H "Authorization: Bearer $KEY" -H 'Accept: application/json' "$API_URL$1"
}

status=$(call /api/v1/boards)
if [[ "$status" != 200 ]]; then
  echo "Couldn't list boards (HTTP $status): $(python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("error",""))
except Exception: print("")' "$TMP/out")" >&2
  exit 1
fi

python3 -I - "$TMP/out" > "$TMP/boards.tsv" <<'PY'
import json, sys
for b in json.load(open(sys.argv[1]))[:50]:
    name = "".join(ch for ch in str(b.get("name", "")) if ch.isprintable())[:60]
    team = "".join(ch for ch in str(b.get("teamName") or "") if ch.isprintable())[:40]
    print(f'{b["id"]}\t{name}\t{team}\t{b.get("cardCount", 0)}')
PY
if [[ ! -s "$TMP/boards.tsv" ]]; then echo "No boards on this account yet." >&2; exit 1; fi

echo; echo "Your boards:"
awk -F'\t' '{ printf "  %2d) %s%s  (%s cards)\n", NR, $2, ($3 != "" ? "  · " $3 : ""), $4 }' "$TMP/boards.tsv"
echo
read -rp "Show which board on the desktop? [1]: " PICK; PICK=${PICK:-1}
BOARD_ID=$(awk -F'\t' -v n="$PICK" 'NR==n {print $1}' "$TMP/boards.tsv")
[[ -n "$BOARD_ID" ]] || { echo "No board number $PICK." >&2; exit 1; }

status=$(call "/api/v1/boards/$BOARD_ID")
[[ "$status" == 200 ]] || { echo "Couldn't open that board (HTTP $status)." >&2; exit 1; }
mapfile -t LISTS < <(python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
for l in sorted((l for l in d.get("lists", []) if not l.get("closed")), key=lambda l: l.get("pos", 0)):
    print("".join(ch for ch in str(l.get("name", "")) if ch.isprintable())[:100])' "$TMP/out")

echo; echo "Lists on that board:"
for i in "${!LISTS[@]}"; do printf "  %2d) %s\n" $((i+1)) "${LISTS[$i]}"; done
echo
echo "The desktop has three columns. Pick three lists by number, e.g. \"1 2 3\"."
read -rp "Lists [first three]: " -a PICKS
CHOSEN=()
for p in "${PICKS[@]:-}"; do
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#LISTS[@]} )) && CHOSEN+=("${LISTS[$((p-1))]}")
done
CHOSEN=("${CHOSEN[@]:0:3}")

read -rp "Background refresh every how many minutes? [10]: " MINS; MINS=${MINS:-10}
[[ "$MINS" =~ ^[0-9]+$ ]] && (( MINS >= 2 )) || MINS=10

mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
umask 077
python3 -I - "$CONF.tmp" "$API_URL" "$KEY" "$BOARD_ID" "$MINS" "${CHOSEN[@]}" <<'PY'
import json, sys
out, url, key, board, mins, *lists = sys.argv[1:]
json.dump({"apiUrl": url, "apiKey": key, "boardId": board, "lists": lists,
           "refreshMinutes": int(mins)}, open(out, "w"), indent=2)
PY
mv "$CONF.tmp" "$CONF"; chmod 600 "$CONF"

echo
echo "Saved $CONF. The desktop board switches to this board within a few seconds."
