# HiveWarden — Architecture

> A tiny always-on-top control panel for macOS that shows every Claude Code agent
> running on your machine, lets you answer their permission prompts and questions
> **without switching windows**, and jumps you to the right terminal/editor tab when
> you do want to look.

## 1. The problem

You run several Claude Code sessions at once (VS Code terminals, iTerm tabs, the
Claude extension…). Each one silently blocks on a permission prompt or a question,
and the only way to know is to cycle through windows. You can't answer *"What are
they doing?"* at a glance.

## 2. The idea

One small floating panel that lists every live session as a
little coloured mascot with:

| Element | Meaning |
|---|---|
| Mascot colour | stable identity of the session (matches across list / detail) |
| Title | project folder (renameable) |
| Status line | what it's doing right now ("Rendering animations", "Running `npm test`") |
| `5/7` + bar | progress through the agent's own todo list |
| Lime outline | **needs you** — permission request or question, answerable inline |
| ↗ button | jump to the terminal/editor that owns the session |
| ✕ | stop tracking this session |

Click a row → **detail view**: the full checklist, recent tool calls, and the
last command in a terminal-style block. A collapse chevron shrinks the panel to its
header; a menu-bar item brings it back.

## 3. How we get the data: Claude Code hooks

We do **not** scrape terminals or parse transcripts. Claude Code already has a
first-class extension point — *hooks* — that run a command on lifecycle events and
pipe a JSON payload on stdin. We register one tiny shim for the events we care
about:

| Hook event | What we learn | Blocking? |
|---|---|---|
| `SessionStart` / `SessionEnd` | session appears / disappears | no |
| `UserPromptSubmit` | agent is now *working*; first prompt | no |
| `PreToolUse` | current tool → status line + tool list | no (**yes** for `AskUserQuestion`) |
| `PostToolUse` | tool finished; `TodoWrite` / `TaskCreate` / `TaskUpdate` → progress | no |
| `PermissionRequest` | a permission dialog is about to show | **yes** — we may decide |
| `Notification` | `idle_prompt` → waiting for you | no |
| `Stop` | turn finished → *idle*, last assistant message | no |

Payload fields we rely on (verified against Claude Code 2.1): `session_id`, `cwd`,
`hook_event_name`, `tool_name`, `tool_input`, `tool_response`, `prompt`,
`message`, `notification_type`, `last_assistant_message`.

The hook's **parent PID is the `claude` process**, which gives us liveness
(`kill(pid, 0)`), the owning terminal (walk the process tree to the first GUI app)
and the TTY.

## 4. Components

```
 ┌────────────────────────── Claude Code sessions ───────────────────────────┐
 │  claude (iTerm tab)     claude (VS Code term)     claude (Terminal.app)   │
 └───────┬──────────────────────────┬─────────────────────────┬──────────────┘
         │ hook JSON on stdin       │                         │
         ▼                          ▼                         ▼
   hivewarden-hook.sh  (curl → http://127.0.0.1:<port>/event, token header)
         │   ▲ stdout = hook reply JSON (allow / deny / answer) or empty
         ▼   │
 ┌───────────┴───────────────── HiveWarden.app ────────────────────────────┐
 │  HookServer (Network.framework, loopback only)                            │
 │      │  parse → HookEvent + HookMeta{ppid,tty}                            │
 │      ▼                                                                    │
 │  SessionStore  (@MainActor @Observable)   ← pure reducer, unit-tested     │
 │      sessions[] ─ AgentSession{state, todos, tools, pending…}             │
 │      ▲                       │                                            │
 │      │ user taps Allow/Deny  │ observation                                │
 │  FloatingPanel (NSPanel, floating, all Spaces) ── SwiftUI views             │
 │  MenuBarController · TerminalJumper · HookInstaller · Sound               │
 └───────────────────────────────────────────────────────────────────────────┘
```

Two SwiftPM targets:

* **`ClaudeWorkersCore`** — no UI. `HookEvent`, models, `SessionStore` (the reducer),
  `ToolDescriber`, `HookReply`, `SettingsMerger`. Everything testable.
* **`ClaudeWorkers`** — the app: server, panel, SwiftUI views, jumper, installer.

"ClaudeWorkers" is the internal code name. The product people see is **HiveWarden**:
that name lives in `AppInfo.name` (UI text) and `scripts/build-app.sh` (the bundle).

## 5. The blocking round-trip (permissions & questions)

This is the interesting part.

```
claude                shim              HookServer            SessionStore         UI
  │ PermissionRequest   │                    │                     │                │
  ├────────────────────►│ POST /event        │                     │                │
  │                     ├───────────────────►│ handle(event)       │                │
  │                     │   (curl waits)     ├────────────────────►│ pending set    │
  │                     │                    │   (awaiting)        ├───────────────►│ row glows,
  │                     │                    │                     │                │ sound plays
  │                     │                    │                     │◄───────────────┤ user: Allow
  │                     │◄───────────────────┤ {"decision":allow}  │ resolve        │
  │◄────────────────────┤ stdout JSON        │                     │                │
  │ proceeds            │                    │                     │                │
```

* `PermissionRequest` reply → `{"hookSpecificOutput":{"hookEventName":
  "PermissionRequest","decision":{"behavior":"allow"|"deny","message":…}}}`.
* **"In terminal"** replies with an empty body → Claude falls through to its normal
  dialog, and we jump you to that terminal. The row stays flagged ("Needs permission
  in the terminal") until that tool call finishes or the turn ends, because Claude is
  still blocked on you.
* **Several requests at once** (parallel tool calls, subagents) queue per session and
  are shown one at a time; the status line reads "needs permission (2)".
* **Plan approvals** (`ExitPlanMode`) can't be approved by a bare "allow", so we give
  no decision and flag the row "Plan ready for review" with an *Open terminal* button.
* **Questions** (`AskUserQuestion`) arrive via `PreToolUse`. We reply
  `permissionDecision: "allow"` with `updatedInput` = the original `questions` plus an
  `answers` map keyed by question text (the documented way for a hook to answer the
  tool). *(v0.1 denied the call with the answer as the reason; that worked but Claude
  Code logged it as a "hook error".)* The card also has "Type in terminal".
* **When a card goes away without you.** If Claude stops waiting (you interrupted it,
  or answered some other way) it kills the hook → the socket closes → the server sees
  EOF and clears the card. As a backstop the card is also cleared by the
  `PostToolUse` of *that same call* (matched on tool name + canonical input, because
  `PermissionRequest` carries no `tool_use_id`) and by `Stop` / a new prompt.
  Unrelated tool events never clear it: other calls keep running while one waits.

### Fail-open guarantees

1. App not running → the shim finds no port file / connection refused → exits `0`
   with no output → Claude behaves exactly as if there were no hook. The port file is
   removed on quit, including `kill`/Ctrl-C (SIGTERM/SIGINT are routed to a normal quit).
2. Every non-blocking event is answered immediately (empty body).
3. **App hung** → the shim gives ordinary events 5 s, then exits `0`. Only permission
   requests and questions are allowed to wait (up to ~10 min).
4. Wrong/missing token → empty `401`, never a decision.
5. Installing hooks refuses to run if `settings.json` exists but isn't valid JSON, so
   a half-edited file is never overwritten.

## 6. Security model

* The listening socket is bound to **`127.0.0.1`** (not just filtered to loopback),
  on an ephemeral port written to `~/Library/Application Support/HiveWarden/port`.
* Every request needs `X-HiveWarden-Token`; the 256-bit token is created on first run
  (mode `0600`) next to the port file. Other local users can't read it; other
  processes of yours can, which is the same trust boundary as `~/.claude`.
* Decisions flow **app → Claude** only for requests that Claude itself initiated
  through a hook it was configured to run; the app can't inject commands.
* Installing hooks edits `~/.claude/settings.json` (a one-time
  `settings.json.hivewarden-backup` copy is made; entries are tagged by the shim path so
  uninstall removes exactly ours and nothing else).

## 7. Session lifecycle & state machine

```
            UserPromptSubmit / PreToolUse / PostToolUse
        ┌──────────────────────────────────────────────┐
        ▼                                              │
   ┌─────────┐  PermissionRequest   ┌─────────────────┐│
   │ working │─────────────────────►│ needsPermission ││
   │         │◄─────────────────────│  (blocking)     ││
   └────┬────┘   allow/deny/term    └─────────────────┘│
        │  AskUserQuestion          ┌─────────────────┐│
        ├──────────────────────────►│  asksQuestion   │┘
        │ Stop / idle_prompt        └─────────────────┘
        ▼
   ┌─────────┐    UserPromptSubmit → working
   │  idle   │    SessionEnd / process gone → removed
   └─────────┘
```

* **Progress** = completed / total of the latest todo list (`TodoWrite`, or
  `TaskCreate`/`TaskUpdate` — best effort, the shapes of those newer tools are
  inferred). No todos → an indeterminate shimmer while working.
* **Plan reporting (on by default).** Some Claude Code builds give the agent
  no todo tool at all, so there is nothing to derive progress or "what's next" from.
  Unless *Ask agents to report their plan* is switched off in the menu bar, the `SessionStart` reply carries
  `additionalContext` asking the agent to announce multi-step plans with a no-op
  `echo HIVE_PLAN <done> '<json array of step names>'`, re-sent after each step. We
  read it in `PreToolUse`, turn it into the same todo list `TodoWrite` would give, and
  hide it from the step list. Agents often glue the report onto the step itself
  (`sleep 6 && …; echo HIVE_PLAN 2 '[…]'`), so reports are found anywhere in a
  command: one in front is the state while the command runs, one after it is applied
  when the command finishes, and the report text is stripped from what the panel shows.
  We never auto-approve anything because of it. Cost: one extra tiny command per
  step. Sessions that were already open get the instruction once, with their next
  prompt (`UserPromptSubmit` → `additionalContext`); it is re-sent after compaction.
* **Upcoming steps**: pending todos show under a row as "Next: …", expandable in place.
* **Liveness**: sessions are removed on `SessionEnd`, or when their `claude` PID
  disappears (checked every 2 s), or after 12 h of silence.
* **Identity colour**: lowest free slot of a 6-colour palette among live sessions.
* **Title**: `folder · first few words of the first prompt` (so two sessions in one
  folder are tellable apart), or just the folder until a real prompt arrives;
  renameable from the row's context menu.

## 8. Jumping to the right place (`TerminalJumper`)

1. Walk the process tree up from the `claude` PID until a process maps to a regular
   GUI app (`NSRunningApplication`). Parents come from `sysctl(KERN_PROC_PID)`:
   `proc_pidinfo` is denied for the setuid `login` that sits between Terminal and
   your shell. Activation goes through LaunchServices, because
   `NSRunningApplication.activate()` is ignored when the caller isn't frontmost.
2. Per app:
   * **Terminal.app / iTerm2** → AppleScript selects the tab whose `tty` matches,
     run in an `osascript` child so the consent dialog can't freeze the hook server.
   * **VS Code / Cursor / Insiders** → `open -b <bundle> <cwd>` raises the window
     that has that folder open.
   * anything else → just activate the app.

AppleScript triggers the one-time macOS *Automation* prompt.

## 9. UI notes

* `NSPanel` (`.nonactivatingPanel`, `.floating`, `canJoinAllSpaces`,
  `fullScreenAuxiliary`) so clicking Allow never steals focus from what you're
  typing in. Draggable by its background; the top edge stays pinned while it grows.
* `NSHostingController` with `preferredContentSize` sizing; lists beyond ~560 pt
  scroll.
* Mascots are pure SwiftUI shapes driven by a `TimelineView`: bobbing while
  working, hopping when they need you, happy eyes when idle, periodic blink.
* App is an *accessory* (`LSUIElement`): no Dock icon, a menu-bar item instead,
  with show/hide, sound, install/uninstall hooks, launch at login.

## 10. Testing

* `ClaudeWorkersCoreTests` exercise the reducer with realistic payloads (progress maths,
  permission & question round trips, EOF cancel, dismissal) and the settings
  merger (idempotent install, preserves foreign hooks, clean uninstall).
* `scripts/demo.sh` replays a four-agent scenario against a running app for visual
  checks and demos.
* `scripts/e2e-eof.sh` checks the blocking round trip and the hang-up path over HTTP.
* `scripts/e2e-claude.sh` drives a **real** `claude -p` session through the installed
  hooks: allow creates the file, deny doesn't.

## 11. Non-goals / roadmap

* No transcript parsing, no token/cost accounting (possible later via
  `transcript_path`).
* No remote/other-machine agents; no non-Claude agents yet (the hook server is
  generic enough that a Codex/Gemini adapter is just another event mapper).
* Ideas: global hotkey, per-session mute, "always allow this" button, notification
  banners when the panel is hidden, exact VS Code terminal-tab focus via an
  extension.
