#!/bin/bash
# Smoke test for the blocking round-trip (HiveWarden must be running).
#   A) park a permission request, answer it via the control API -> reply carries "allow"
#   B) park another, hang up like Claude does when you answer in the terminal ->
#      the card is cleared (nothing left to decide)
DIR="$HOME/Library/Application Support/HiveWarden"
PORT=$(<"$DIR/port"); TOKEN=$(<"$DIR/token")
SID="e2e-$$"
REPLY=$(mktemp)
BODY="{\"session_id\":\"$SID\",\"cwd\":\"/x/E2E test\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}"
post()   { curl -s -X POST -H "X-HiveWarden-Token: $TOKEN" --data-binary "$1" "http://127.0.0.1:$PORT/event"; }
decide() { curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-HiveWarden-Token: $TOKEN" "http://127.0.0.1:$PORT/decide?session=$SID&choice=allow"; }
fail=0

post "$BODY" > "$REPLY" &
sleep 1
A=$(decide)
wait
if [ "$A" = 200 ] && grep -q '"behavior":"allow"' "$REPLY"; then
  echo "PASS A: parked request was answered and Claude would receive {allow}"
else
  echo "FAIL A: decide=$A reply=$(cat "$REPLY")"; fail=1
fi
rm -f "$REPLY"

# Run curl directly (not via a function) so $! is curl's own PID.
curl -s -X POST -H "X-HiveWarden-Token: $TOKEN" --data-binary "$BODY" "http://127.0.0.1:$PORT/event" > /dev/null 2>&1 &
CP=$!
sleep 1
kill "$CP" 2>/dev/null
wait "$CP" 2>/dev/null
sleep 1.5
B=$(decide)
if [ "$B" = 404 ]; then echo "PASS B: card cleared after the client hung up"; else echo "FAIL B: still pending (decide=$B)"; fail=1; fi

post "{\"session_id\":\"$SID\",\"hook_event_name\":\"SessionEnd\"}" > /dev/null
exit $fail
