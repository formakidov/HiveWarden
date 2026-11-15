#!/bin/bash
# Dev aid: render the running app's panel to a PNG.
#   scripts/snapshot.sh out.png [session-id|""] [collapsed 0|1]
DIR="$HOME/Library/Application Support/HiveWarden"
Q=""
[ -n "$2" ] && Q="select=$2"
[ -n "$3" ] && Q="$Q&collapsed=$3"
curl -s -X POST -H "X-HiveWarden-Token: $(<"$DIR/token")" "http://127.0.0.1:$(<"$DIR/port")/snapshot?$Q"
sleep 0.9
cp "$DIR/snapshot.png" "${1:-snapshot.png}" && echo "wrote ${1:-snapshot.png}"
