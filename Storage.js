.pragma library

// Validate the whole path before mkdir/chmod. A private leaf is insufficient
// when another UID can rename it through a writable ancestor. Root-owned
// sticky directories (such as /tmp) protect entries owned by this UID.
var prepare = `
set -eu
umask 077
owner=$(id -u)
trusted_path() {
  path=$1
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path/" in */../*|*/./*|*//*) return 1 ;; esac
  while [ "$path" != / ]; do
    [ ! -L "$path" ] || return 1
    if [ -e "$path" ]; then
      [ -d "$path" ] || return 1
      info=$(stat -c '%u %a' -- "$path") || return 1
      uid=\${info%% *}; mode=\${info#* }
      [ "$uid" = "$owner" ] || [ "$uid" = 0 ] || return 1
      if [ $((0$mode & 0022)) -ne 0 ]; then
        [ "$uid" = 0 ] && [ $((0$mode & 01000)) -ne 0 ] || return 1
      fi
    fi
    path=\${path%/*}
    [ -n "$path" ] || path=/
  done
}
private_dir() {
  trusted_path "$1" || return 1
  mkdir -p -- "$1" || return 1
  [ "$(stat -c %u -- "$1")" = "$owner" ] || return 1
  chmod 700 -- "$1" || return 1
}
private_file() {
  [ ! -L "$1" ] || return 1
  [ ! -e "$1" ] && return 0
  [ -f "$1" ] || return 1
  [ "$(stat -c '%u %h' -- "$1")" = "$owner 1" ] || return 1
  chmod 600 -- "$1"
}
private_dir "$1" && private_dir "$2" && private_dir "$4" || exit 1
for file in "$1"/*.json "$4"/*.json; do
  private_file "$file" || exit 1
done
private_file "$3" || exit 1
`
