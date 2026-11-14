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
  # Headers go in on stdin (printf is a builtin), so the key never shows in a process list.
  printf 'Authorization: Bearer %s\nAccept: application/json\n' "$KEY" |
    curl -sS --max-time 15 --max-filesize 10485760 -o "$TMP/out" -w '%{http_code}' -H @- -- "$API_URL$1"
}
# Printable text only, cut to $2 characters.
CLEAN='def clean($n): tostring | gsub("[[:cntrl:]]"; "") | .[0:$n];'

status=$(call /api/v1/boards)
if [[ "$status" != 200 ]]; then
  echo "Couldn't list boards (HTTP $status): $(jq -r '.error? // ""' "$TMP/out" 2>/dev/null)" >&2
  exit 1
fi

jq -r "$CLEAN"' .[:50][] | select(.id | type == "string" and test("^[A-Za-z0-9_-]{1,64}$"))
  | [.id, (.name // "" | clean(60)), (.teamName // "" | clean(40)), (.cardCount // 0 | tostring)] | @tsv' \
  "$TMP/out" > "$TMP/boards.tsv"
if [[ ! -s "$TMP/boards.tsv" ]]; then echo "No boards on this account yet." >&2; exit 1; fi

echo; echo "Your boards:"
awk -F'\t' '{ printf "  %2d) %s%s  (%s cards)\n", NR, $2, ($3 != "" ? "  · " $3 : ""), $4 }' "$TMP/boards.tsv"
echo
read -rp "Show which board on the desktop? [1]: " PICK; PICK=${PICK:-1}
BOARD_ID=$(awk -F'\t' -v n="$PICK" 'NR==n {print $1}' "$TMP/boards.tsv")
[[ -n "$BOARD_ID" ]] || { echo "No board number $PICK." >&2; exit 1; }

status=$(call "/api/v1/boards/$BOARD_ID")
[[ "$status" == 200 ]] || { echo "Couldn't open that board (HTTP $status)." >&2; exit 1; }
mapfile -t LISTS < <(jq -r "$CLEAN"' .lists // [] | map(select(.closed | not)) | sort_by(.pos // 0)[] | .name // "" | clean(100)' "$TMP/out")

echo; echo "Lists on that board:"
for i in "${!LISTS[@]}"; do printf "  %2d) %s\n" $((i+1)) "${LISTS[$i]}"; done
echo
echo "The desktop has four columns. Pick up to four lists by number, e.g. \"1 2 3 4\"."
echo "(You can change them later by clicking the board name at the top of the desktop board.)"
read -rp "Lists [first four]: " -a PICKS
CHOSEN=()
for p in "${PICKS[@]:-}"; do
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#LISTS[@]} )) && CHOSEN+=("${LISTS[$((p-1))]}")
done
CHOSEN=("${CHOSEN[@]:0:4}")

read -rp "Background refresh every how many minutes? [10]: " MINS; MINS=${MINS:-10}
[[ "$MINS" =~ ^[0-9]+$ ]] && (( MINS >= 2 )) || MINS=10

mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
umask 077
# The key goes in on stdin; only non-secret values are arguments.
printf '%s' "$KEY" | jq -Rs --arg url "$API_URL" --arg board "$BOARD_ID" --argjson mins "$MINS" \
  '{apiUrl: $url, apiKey: ., boardId: $board, lists: $ARGS.positional, refreshMinutes: $mins}' \
  --args "${CHOSEN[@]}" > "$CONF.tmp"
mv "$CONF.tmp" "$CONF"; chmod 600 "$CONF"

echo
echo "Saved $CONF. The desktop board switches to this board within a few seconds."
