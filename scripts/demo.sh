#!/bin/bash
# Replays a four-agent scenario against a running HiveWarden, for demos and visual checks.
#   scripts/demo.sh            full scenario (a permission request + a question appear after a few seconds)
#   scripts/demo.sh static     just four working agents, then exit
#   scripts/demo.sh clear      remove the fake agents (they have no process, so they never end on their own)
DIR="$HOME/Library/Application Support/HiveWarden"
[ -r "$DIR/port" ] || { echo "HiveWarden isn't running."; exit 1; }
PORT=$(<"$DIR/port"); TOKEN=$(<"$DIR/token")
post() { curl -s -X POST -H "X-HiveWarden-Token: $TOKEN" --data-binary "$1" "http://127.0.0.1:$PORT/event?ppid=$$&tty=ttys000"; }
ev() { # ev <sid> <cwd> <event> [json-fragment]
  post "{\"session_id\":\"$1\",\"cwd\":\"/Users/demo/$2\",\"hook_event_name\":\"$3\"${4:+,$4}}"
}
todos() { # todos <sid> <cwd> <done> <total> <activeForm>
  local arr="" i
  for ((i=0;i<$4;i++)); do
    local st=pending; ((i<$3)) && st=completed; ((i==$3)) && st=in_progress
    local name=${STEPS[$i]:-Step $((i+1))}
    arr+="{\"content\":\"$name\",\"activeForm\":\"$5\",\"status\":\"$st\"},"
  done
  ev "$1" "$2" PostToolUse "\"tool_name\":\"TodoWrite\",\"tool_input\":{\"todos\":[${arr%,}]}"
}

if [ "$1" = clear ]; then
  for sid in d1 d2 d3 d4; do ev "$sid" x SessionEnd >/dev/null; done
  echo "Demo agents removed."; exit 0
fi

STEPS=("Read the failing test" "Find the root cause" "Write the fix" "Add a regression test" "Run the full suite" "Update the changelog" "Open the pull request")
# id | folder | steps done | steps total | what it is doing now | current command
A=("d1|api-server|5|7|Updating the changelog|git log --oneline v1.4.0..HEAD"
   "d2|web-app|2|5|Writing the fix|npm run typecheck"
   "d3|data-pipeline|4|6|Running the full suite|python -m pytest tests/"
   "d4|docs-site|3|5|Adding a regression test|npm test -- links")
for row in "${A[@]}"; do
  IFS='|' read -r sid name done total act cmd <<<"$row"
  ev "$sid" "$name" SessionStart '"source":"startup"' >/dev/null
  ev "$sid" "$name" UserPromptSubmit '"prompt":"go"' >/dev/null
  todos "$sid" "$name" "$done" "$total" "$act" >/dev/null
  ev "$sid" "$name" PreToolUse "\"tool_name\":\"Bash\",\"tool_use_id\":\"t-$sid\",\"tool_input\":{\"command\":\"$cmd\",\"description\":\"$act\"}" >/dev/null
done
echo "4 agents running. Remove them with: scripts/demo.sh clear"
[ "$1" = static ] && exit 0

sleep 4
echo "data-pipeline asks permission…"
( R=$(ev d3 "data-pipeline" PermissionRequest '"tool_name":"Bash","tool_input":{"command":"python scripts/backfill.py --apply --since 2024-01-01"}'); echo "  → data-pipeline got: ${R:-<passthrough>}" ) &
sleep 5
echo "web-app asks a question…"
( R=$(ev d2 "web-app" PreToolUse '"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Approach","question":"How should I fix the stale state?","multiSelect":false,"options":[{"label":"Add the missing dependency","description":"Smallest change"},{"label":"Move state up","description":"Cleaner, touches two components"},{"label":"Use a reducer","description":"Biggest refactor"}]}]}'); echo "  → web-app got: ${R:-<passthrough>}" ) &
wait
