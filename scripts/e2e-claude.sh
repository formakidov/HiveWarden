#!/bin/bash
# End-to-end test with a REAL Claude session (uses a little API credit).
# Needs: HiveWarden running, hooks installed. Runs `claude -p` in a temp dir, waits
# for the permission card, answers it through the control API, and checks the result.
#   scripts/e2e-claude.sh            allow + deny
#   scripts/e2e-claude.sh terminal   also the "In terminal" choice
DIR="$HOME/Library/Application Support/HiveWarden"
[ -r "$DIR/port" ] || { echo "HiveWarden isn't running."; exit 1; }
PORT=$(<"$DIR/port"); TOKEN=$(<"$DIR/token")
WORK=$(mktemp -d)
cd "$WORK" || exit 1
fail=0

decide() { curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-HiveWarden-Token: $TOKEN" "http://127.0.0.1:$PORT/decide?session=$1&choice=$2"; }

run() { # run <choice> <expect-file: yes|no>
  local choice=$1 expect=$2 sid i code delivered=no exists=no
  sid=$(uuidgen | tr 'A-Z' 'a-z')
  claude -p --model haiku --permission-mode default --session-id "$sid" \
    "Create an empty file named e2e-$choice.txt in the current directory with the bash touch command. Then reply with one word: DONE or DENIED." \
    > "out-$choice.txt" 2>&1 &
  local cp=$!
  for i in $(seq 1 90); do
    sleep 1
    code=$(decide "$sid" "$choice")
    if [ "$code" = 200 ]; then delivered="after ${i}s"; break; fi
    kill -0 "$cp" 2>/dev/null || break
  done
  wait "$cp"
  [ -e "e2e-$choice.txt" ] && exists=yes
  if [ "$delivered" != no ] && [ "$exists" = "$expect" ]; then
    echo "PASS $choice: decision delivered $delivered, file created: $exists"
  else
    echo "FAIL $choice: delivered=$delivered file=$exists (expected $expect). Claude said: $(head -c 200 "out-$choice.txt")"
    fail=1
  fi
}

run allow yes
run deny no
[ "$1" = terminal ] && run terminal no   # no terminal UI in -p mode, so Claude can't get approval

rm -rf "$WORK"
exit $fail
