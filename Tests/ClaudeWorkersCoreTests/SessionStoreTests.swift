import XCTest
@testable import ClaudeWorkersCore

@MainActor
final class SessionStoreTests: XCTestCase {
    func ev(_ name: String, sid: String = "s1", cwd: String = "/Users/me/proj", _ extra: [String: Any] = [:]) -> HookEvent {
        var d: [String: Any] = ["hook_event_name": name, "session_id": sid, "cwd": cwd]
        d.merge(extra) { $1 }
        return HookEvent(raw: d)
    }

    func testSessionLifecycleAndTitle() async {
        let store = SessionStore()
        _ = await store.handle(ev("SessionStart", ["source": "startup"]))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].title, "proj")
        XCTAssertEqual(store.sessions[0].state, .idle)

        _ = await store.handle(ev("UserPromptSubmit", ["prompt": "hello"]))
        XCTAssertEqual(store.sessions[0].state, .working)
        XCTAssertEqual(store.sessions[0].firstPrompt, "hello")

        _ = await store.handle(ev("Stop", ["last_assistant_message": "done!"]))
        XCTAssertEqual(store.sessions[0].state, .idle)
        XCTAssertEqual(store.sessions[0].lastAssistantMessage, "done!")

        _ = await store.handle(ev("SessionEnd"))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testDuplicateTitlesAndColors() async {
        let store = SessionStore()
        _ = await store.handle(ev("SessionStart", sid: "a"))
        _ = await store.handle(ev("SessionStart", sid: "b"))
        XCTAssertEqual(store.sessions.map(\.title), ["proj", "proj (2)"])
        XCTAssertEqual(Set(store.sessions.map(\.colorSlot)).count, 2)
    }

    func testToolTrackingAndStatusLine() async {
        let store = SessionStore()
        _ = await store.handle(ev("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t1",
                                                  "tool_input": ["command": "npm test", "description": "Run tests"]]))
        let s = store.sessions[0]
        XCTAssertEqual(s.statusLine, "Run tests")
        XCTAssertTrue(s.tools[0].running)
        _ = await store.handle(ev("PostToolUse", ["tool_name": "Bash", "tool_use_id": "t1",
                                                   "tool_input": ["command": "npm test"]]))
        XCTAssertFalse(s.tools[0].running)
    }

    func testRecentToolsAreCurrentTurnOnly() async {
        let store = SessionStore()
        let run: [String: Any] = ["tool_name": "Bash", "tool_use_id": "t1", "tool_input": ["command": "sleep 6", "description": "Step 1"]]
        _ = await store.handle(ev("UserPromptSubmit", ["prompt": "do five steps"]))
        _ = await store.handle(ev("PreToolUse", run))
        _ = await store.handle(ev("PostToolUse", run))
        _ = await store.handle(ev("Stop"))
        XCTAssertEqual(store.sessions[0].tools.count, 1, "still visible after the turn ends")
        _ = await store.handle(ev("UserPromptSubmit", ["prompt": "do five steps again"]))
        XCTAssertTrue(store.sessions[0].tools.isEmpty, "last turn's steps must not show as done in the new turn")
    }

    func testTodoWriteProgress() async {
        let store = SessionStore()
        let todos: [[String: Any]] = [
            ["content": "A", "activeForm": "Doing A", "status": "completed"],
            ["content": "B", "activeForm": "Doing B", "status": "in_progress"],
            ["content": "C", "activeForm": "Doing C", "status": "pending"],
        ]
        _ = await store.handle(ev("PostToolUse", ["tool_name": "TodoWrite", "tool_input": ["todos": todos]]))
        let s = store.sessions[0]
        XCTAssertEqual(s.progress?.done, 1)
        XCTAssertEqual(s.progress?.total, 3)
        XCTAssertEqual(s.statusLine, "Doing B")
    }

    func testTaskToolsBestEffort() async {
        let store = SessionStore()
        _ = await store.handle(ev("PostToolUse", ["tool_name": "TaskCreate",
                                                   "tool_input": ["subject": "Write code"],
                                                   "tool_response": "Task #1 created successfully"]))
        _ = await store.handle(ev("PostToolUse", ["tool_name": "TaskCreate",
                                                   "tool_input": ["subject": "Test it"],
                                                   "tool_response": "Task #2 created successfully"]))
        _ = await store.handle(ev("PostToolUse", ["tool_name": "TaskUpdate",
                                                   "tool_input": ["taskId": "1", "status": "completed"]]))
        let s = store.sessions[0]
        XCTAssertEqual(s.progress?.done, 1)
        XCTAssertEqual(s.progress?.total, 2)
    }

    func testPermissionAllowRoundTrip() async throws {
        let store = SessionStore()
        var attention = 0
        store.onAttention = { _ in attention += 1 }
        let req = ev("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]])
        let task = Task { await store.handle(req) }
        try await Task.sleep(nanoseconds: 50_000_000)

        let s = store.sessions[0]
        XCTAssertEqual(s.state, .needsPermission)
        XCTAssertEqual(s.permission?.detail, "Bash: rm -rf build")
        XCTAssertEqual(attention, 1)

        s.permission?.resolve(.allow)
        let reply = await task.value
        XCTAssertTrue(reply.contains("\"behavior\":\"allow\""), reply)
        XCTAssertNil(s.permission)
        XCTAssertEqual(s.state, .working)
    }

    func testPermissionCancelledWhenClientHangsUp() async throws {
        let store = SessionStore()
        let handle = RequestHandle()
        let task = Task { await store.handle(ev("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "ls"]]), request: handle) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(store.sessions[0].permission)
        handle.cancel()   // user answered in the terminal; Claude killed the hook
        let reply = await task.value
        XCTAssertEqual(reply, "")
        XCTAssertNil(store.sessions[0].permission)
    }

    func testQuestionAnswerRoundTrip() async throws {
        let store = SessionStore()
        let input: [String: Any] = ["questions": [[
            "question": "Which hook?", "header": "Hook", "multiSelect": false,
            "options": [["label": "The pain one", "description": "x"], ["label": "The number one", "description": "y"]],
        ]]]
        let task = Task { await store.handle(ev("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": input])) }
        try await Task.sleep(nanoseconds: 50_000_000)

        let s = store.sessions[0]
        let q = try XCTUnwrap(s.question)
        XCTAssertEqual(s.state, .asksQuestion)
        XCTAssertFalse(q.isComplete)
        q.toggle(question: q.questions[0], option: q.questions[0].options[1])
        XCTAssertTrue(q.isComplete)
        q.submit()

        let reply = await task.value
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let out = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(out["permissionDecision"] as? String, "allow")
        let updated = try XCTUnwrap(out["updatedInput"] as? [String: Any])
        XCTAssertEqual((updated["questions"] as? [[String: Any]])?.count, 1, "original questions echoed back")
        XCTAssertEqual((updated["answers"] as? [String: String])?["Which hook?"], "The number one")
        XCTAssertNil(s.question)
    }

    func testQuestionPassthroughReturnsEmpty() async throws {
        let store = SessionStore()
        let input: [String: Any] = ["questions": [["question": "?", "options": [["label": "a"]]]]]
        let task = Task { await store.handle(ev("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": input])) }
        try await Task.sleep(nanoseconds: 50_000_000)
        store.sessions[0].question?.passthrough()
        let reply = await task.value
        XCTAssertEqual(reply, "")
    }

    func testMatchingPostToolUseClearsStalePending() async throws {
        let store = SessionStore()
        let input: [String: Any] = ["command": "ls", "description": "List"]
        let task = Task { await store.handle(ev("PermissionRequest", ["tool_name": "Bash", "tool_input": input])) }
        try await Task.sleep(nanoseconds: 50_000_000)
        // The very same call completed, so it was answered elsewhere (key order differs on purpose).
        _ = await store.handle(ev("PostToolUse", ["tool_name": "Bash", "tool_input": ["description": "List", "command": "ls"]]))
        XCTAssertNil(store.sessions[0].permission, "card must go immediately")
        let reply = await task.value
        XCTAssertEqual(reply, "")
        XCTAssertEqual(store.sessions[0].state, .working)
    }

    func testUnrelatedToolActivityKeepsTheCard() async throws {
        let store = SessionStore()
        let task = Task { await store.handle(ev("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf x"]])) }
        try await Task.sleep(nanoseconds: 50_000_000)
        // A parallel tool call / subagent keeps working while this one waits for you.
        _ = await store.handle(ev("PreToolUse", ["tool_name": "Read", "tool_use_id": "r1", "tool_input": ["file_path": "/a"]]))
        _ = await store.handle(ev("PostToolUse", ["tool_name": "Read", "tool_use_id": "r1", "tool_input": ["file_path": "/a"]]))
        _ = await store.handle(ev("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "echo other"]]))

        let s = store.sessions[0]
        XCTAssertNotNil(s.permission, "card must survive unrelated events")
        XCTAssertEqual(s.state, .needsPermission)
        XCTAssertEqual(s.statusLine, "needs permission")
        s.permission?.resolve(.allow)
        let reply = await task.value
        XCTAssertTrue(reply.contains("\"behavior\":\"allow\""), reply)
    }

    func testParallelPermissionRequestsQueue() async throws {
        let store = SessionStore()
        let t1 = Task { await store.handle(ev("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "one"]])) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let t2 = Task { await store.handle(ev("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "two"]])) }
        try await Task.sleep(nanoseconds: 30_000_000)

        let s = store.sessions[0]
        XCTAssertEqual(s.permissionQueue.count, 2)
        XCTAssertEqual(s.permission?.detail, "Bash: one")
        XCTAssertEqual(s.statusLine, "needs permission (2)")

        s.permission?.resolve(.allow)
        let r1 = await t1.value
        XCTAssertTrue(r1.contains("allow"))
        XCTAssertEqual(s.permission?.detail, "Bash: two", "second request is shown next, not dropped")
        XCTAssertEqual(s.state, .needsPermission)

        s.permission?.resolve(.deny)
        let r2 = await t2.value
        XCTAssertTrue(r2.contains("\"behavior\":\"deny\""), r2)
        XCTAssertFalse(s.needsAttention)
        XCTAssertEqual(s.state, .working)
    }

    func testInTerminalChoiceKeepsSessionFlaggedUntilTheToolRuns() async throws {
        let store = SessionStore()
        let input: [String: Any] = ["command": "touch z"]
        let task = Task { await store.handle(ev("PermissionRequest", ["tool_name": "Bash", "tool_input": input])) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let s = store.sessions[0]
        s.permission?.resolve(.terminal)
        let reply = await task.value
        XCTAssertEqual(reply, "", "empty reply = Claude shows its own dialog")
        XCTAssertNil(s.permission)
        XCTAssertTrue(s.needsAttention, "Claude is still blocked on you, just in the terminal")
        XCTAssertEqual(s.statusLine, "Needs permission in the terminal")

        _ = await store.handle(ev("PostToolUse", ["tool_name": "Bash", "tool_input": input]))
        XCTAssertFalse(s.needsAttention)
        XCTAssertEqual(s.state, .working)
    }

    func testHangupDoesNotFlagTheTerminal() async throws {
        let store = SessionStore()
        let handle = RequestHandle()
        let task = Task { await store.handle(ev("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "ls"]]), request: handle) }
        try await Task.sleep(nanoseconds: 50_000_000)
        handle.cancel()
        _ = await task.value
        XCTAssertFalse(store.sessions[0].needsAttention)
    }

    func testPlanApprovalIsRoutedToTheTerminal() async {
        let store = SessionStore()
        var attention = 0
        store.onAttention = { _ in attention += 1 }
        let reply = await store.handle(ev("PermissionRequest", ["tool_name": "ExitPlanMode", "tool_input": ["plan": "do it"]]))
        XCTAssertEqual(reply, "", "a bare allow can't approve a plan, so we give no decision")
        let s = store.sessions[0]
        XCTAssertNil(s.permission)
        XCTAssertEqual(s.statusLine, "Plan ready for review")
        XCTAssertEqual(attention, 1)
        _ = await store.handle(ev("Stop"))
        XCTAssertFalse(s.needsAttention)
    }

    func testQuestionFreeTextAndTerminalChoice() async throws {
        let store = SessionStore()
        let input: [String: Any] = ["questions": [
            ["question": "Colour?", "multiSelect": false, "options": [["label": "Red"], ["label": "Blue"]]],
            ["question": "Extras?", "multiSelect": true, "options": [["label": "A"], ["label": "B"]]],
        ]]
        let task = Task { await store.handle(ev("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": input])) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let s = store.sessions[0]
        let q = try XCTUnwrap(s.question)
        let (q1, q2) = (q.questions[0], q.questions[1])

        q.toggle(question: q1, option: q1.options[0])
        q.setCustom(question: q1, text: "Teal")              // single choice: text replaces the option
        XCTAssertFalse(q.isComplete)
        q.toggle(question: q2, option: q2.options[0])
        q.setCustom(question: q2, text: " C ")               // multi: text is added
        XCTAssertTrue(q.isComplete)
        XCTAssertEqual(q.answers, ["Colour?": "Teal", "Extras?": "A, C"])
        q.toggle(question: q1, option: q1.options[1])        // and an option replaces the text
        XCTAssertEqual(q.answers["Colour?"], "Blue")

        q.typeInTerminal()
        let reply = await task.value
        XCTAssertEqual(reply, "")
        XCTAssertEqual(s.statusLine, "Asks a question in the terminal")
        _ = await store.handle(ev("PostToolUse", ["tool_name": "AskUserQuestion", "tool_input": input]))
        XCTAssertFalse(s.needsAttention)
    }

    func testTopicDistinguishesSessionsInOneFolder() async {
        let store = SessionStore()
        _ = await store.handle(ev("UserPromptSubmit", sid: "a", ["prompt": "/model"]))
        XCTAssertEqual(store.sessions[0].title, "proj", "slash commands aren't a topic")
        _ = await store.handle(ev("UserPromptSubmit", sid: "a", ["prompt": "go"]))
        XCTAssertEqual(store.sessions[0].title, "proj", "neither are one-word prompts")
        XCTAssertEqual(AgentSession.topic(from: "❯ Ask me a question"), "Ask me a question", "pasted prompt glyph is dropped")
        _ = await store.handle(ev("UserPromptSubmit", sid: "a", ["prompt": "Fix the jump button\nmore detail"]))
        _ = await store.handle(ev("UserPromptSubmit", sid: "b", ["prompt": "Write a very long prompt that keeps going and going"]))
        XCTAssertEqual(store.sessions[0].title, "proj · Fix the jump button")
        XCTAssertEqual(store.sessions[1].title, "proj · Write a very long prompt…")
        _ = await store.handle(ev("UserPromptSubmit", sid: "a", ["prompt": "something else"]))
        XCTAssertEqual(store.sessions[0].title, "proj · Fix the jump button", "topic is stable")
        store.sessions[0].customTitle = "Mine"
        XCTAssertEqual(store.sessions[0].title, "Mine")
    }

    func testDismissAndReappearOnPrompt() async {
        let store = SessionStore()
        _ = await store.handle(ev("SessionStart"))
        store.dismiss("s1")
        XCTAssertTrue(store.visibleSessions.isEmpty)
        _ = await store.handle(ev("UserPromptSubmit", ["prompt": "again"]))
        XCTAssertEqual(store.visibleSessions.count, 1)
    }

    func testPruneRemovesDeadProcesses() async {
        let store = SessionStore()
        _ = await store.handle(ev("SessionStart"))
        store.sessions[0].agentPID = 99999
        store.prune(isAlive: { _ in false })
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testToolDescriber() {
        let d = ToolDescriber.describe(tool: "Read", input: ["file_path": "/a/b/final-cut-transcript.md"])
        XCTAssertEqual(d.title, "Read final-cut-transcript.md")
        XCTAssertEqual(d.kind, .read)
        XCTAssertEqual(ToolDescriber.describe(tool: "mcp__figma__get-node", input: [:]).title, "Use get node")
    }
}

final class SettingsMergerTests: XCTestCase {
    let cmd = "\"$HOME/Library/Application Support/HiveWarden/hivewarden-hook.sh\""

    func testInstallPreservesForeignHooksAndIsIdempotent() {
        let foreign: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "echo mine"]]]
        let base: [String: Any] = ["model": "opus", "hooks": ["PreToolUse": [foreign]]]

        let once = SettingsMerger.install(into: base, command: cmd)
        let twice = SettingsMerger.install(into: once, command: cmd)
        XCTAssertTrue(SettingsMerger.isInstalled(once))
        XCTAssertEqual(once["model"] as? String, "opus")

        let pre = (twice["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(pre.count, 2, "foreign + exactly one of ours")
        XCTAssertEqual(pre[0]["matcher"] as? String, "Bash")
    }

    func testRemoveLeavesForeignHooks() {
        let foreign: [String: Any] = ["hooks": [["type": "command", "command": "echo mine"]]]
        let base: [String: Any] = ["hooks": ["Stop": [foreign]]]
        let cleaned = SettingsMerger.remove(from: SettingsMerger.install(into: base, command: cmd))
        XCTAssertFalse(SettingsMerger.isInstalled(cleaned))
        let hooks = cleaned["hooks"] as! [String: Any]
        XCTAssertEqual(Array(hooks.keys), ["Stop"])
        XCTAssertEqual((hooks["Stop"] as! [[String: Any]]).count, 1)
    }

    func testParseRefusesWhatItCannotUnderstand() throws {
        XCTAssertTrue(try SettingsMerger.parse(Data()).isEmpty)
        XCTAssertTrue(try SettingsMerger.parse(Data("  \n".utf8)).isEmpty)
        XCTAssertEqual(try SettingsMerger.parse(Data(#"{"model":"opus"}"#.utf8))["model"] as? String, "opus")
        // A half-edited file must never be read as "no settings" and then overwritten.
        XCTAssertThrowsError(try SettingsMerger.parse(Data(#"{"model":"opus","#.utf8)))
        XCTAssertThrowsError(try SettingsMerger.parse(Data("[1,2]".utf8)))
    }

    func testRemoveFromEmptyRemovesHooksKey() {
        let cleaned = SettingsMerger.remove(from: SettingsMerger.install(into: [:], command: cmd))
        XCTAssertNil(cleaned["hooks"])
    }
}

final class ProcessTreeTests: XCTestCase {
    func testParentOfSelfIsReadable() {
        let me = getpid()
        XCTAssertEqual(ProcessTree.parent(of: me), getppid())
    }

    func testParentOfSetuidLoginWorks() {
        // `login` is setuid; proc_pidinfo can't read it but sysctl can. Skip if none running.
        let p = Process(); let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-x", "login"]; p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        let txt = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let pid = txt.split(separator: "\n").first.flatMap({ Int32($0) }) else { return }
        XCTAssertNotNil(ProcessTree.parent(of: pid))
    }
}

@MainActor
final class PlanReportTests: XCTestCase {
    func ev(_ name: String, _ extra: [String: Any] = [:]) -> HookEvent {
        var d: [String: Any] = ["hook_event_name": name, "session_id": "s1", "cwd": "/Users/me/proj"]
        d.merge(extra) { $1 }
        return HookEvent(raw: d)
    }
    func bash(_ cmd: String, id: String) -> [String: Any] {
        ["tool_name": "Bash", "tool_use_id": id, "tool_input": ["command": cmd]]
    }

    func testParse() {
        let p = PlanReport.parse(command: #"echo HIVE_PLAN 1 '["Read the code","Write the fix","Run the tests"]'"#)
        XCTAssertEqual(p, PlanReport.Plan(done: 1, steps: ["Read the code", "Write the fix", "Run the tests"]))
        XCTAssertEqual(PlanReport.parse(command: #"echo HIVE_PLAN 9 "[\"a\",\"b\"]""#)?.done, 2, "clamped, double quotes ok")
        // Not plan reports: trailing shell, wrong shape, ordinary commands.
        XCTAssertNil(PlanReport.parse(command: #"echo HIVE_PLAN 1 '["a"]'; rm -rf ~"#))
        XCTAssertNil(PlanReport.parse(command: #"echo HIVE_PLAN 1 '["a"]' && echo '["b"]'"#))
        XCTAssertNil(PlanReport.parse(command: "echo HIVE_PLAN one '[]'"))
        XCTAssertNil(PlanReport.parse(command: "echo HIVE_PLAN 0 '[]'"))
        XCTAssertNil(PlanReport.parse(command: "echo hello"))
    }

    func testScanFindsReportsInsideCombinedCommands() throws {
        let plan = #"'["Initialize","Configure","Process"]'"#
        let steps = ["Initialize", "Configure", "Process"]

        // Report after the step: only true once the command has finished.
        let after = try XCTUnwrap(PlanReport.scan(command: #"sleep 6 && echo "Step 2: Configure done"; echo HIVE_PLAN 2 "# + plan))
        XCTAssertNil(after.leading)
        XCTAssertEqual(after.last, PlanReport.Plan(done: 2, steps: steps))
        XCTAssertEqual(after.remainder, #"sleep 6 && echo "Step 2: Configure done""#)

        // Report before and after: the first is "now", the last is "afterwards".
        let both = try XCTUnwrap(PlanReport.scan(command: "echo HIVE_PLAN 0 \(plan); sleep 6 && echo done; echo HIVE_PLAN 1 \(plan)"))
        XCTAssertEqual(both.leading?.done, 0)
        XCTAssertEqual(both.last.done, 1)
        XCTAssertEqual(both.remainder, "sleep 6 && echo done")

        // Nothing but the report.
        let pure = try XCTUnwrap(PlanReport.scan(command: "  echo HIVE_PLAN 3 \(plan)\n"))
        XCTAssertEqual(pure.leading?.done, 3)
        XCTAssertEqual(pure.remainder, "")

        // Spaces inside step names survive; ordinary commands aren't reports.
        XCTAssertEqual(PlanReport.scan(command: #"echo HIVE_PLAN 0 '["Two  spaces","b","c"]'"#)?.last.steps.first, "Two  spaces")
        XCTAssertNil(PlanReport.scan(command: "sleep 6 && echo done"))
        XCTAssertNil(PlanReport.scan(command: "echo HIVE_PLAN soon"))
    }

    func testCombinedCommandsDriveProgressLikeTheOtherAgentDid() async {
        // Replays what a real session sent: reports glued onto the step commands.
        let store = SessionStore()
        let plan = #"'["Initialize","Configure","Process","Validate","Finalize"]'"#
        _ = await store.handle(ev("UserPromptSubmit", ["prompt": "Do 5 steps, each with bash sleep 6."]))
        let s = store.sessions[0]

        let c1 = bash("echo HIVE_PLAN 0 \(plan); sleep 6 && echo \"Step 1: Initialize done\"; echo HIVE_PLAN 1 \(plan)", id: "c1")
        _ = await store.handle(ev("PreToolUse", c1))
        XCTAssertEqual(s.progress?.done, 0, "the trailing report must not count before the step ran")
        XCTAssertEqual(s.progress?.total, 5)
        XCTAssertEqual(s.statusLine, "Initialize")
        XCTAssertEqual(s.upcomingTodos.count, 4)
        XCTAssertEqual(s.tools.last?.detail, #"sleep 6 && echo "Step 1: Initialize done""#, "the report is hidden from the step")
        _ = await store.handle(ev("PostToolUse", c1))
        XCTAssertEqual(s.progress?.done, 1)
        XCTAssertFalse(s.tools[0].running)

        for n in 2...5 {
            let c = bash("sleep 6 && echo \"Step \(n) done\"; echo HIVE_PLAN \(n) \(plan)", id: "c\(n)")
            _ = await store.handle(ev("PreToolUse", c))
            XCTAssertEqual(s.progress?.done, n - 1, "step \(n) still running")
            _ = await store.handle(ev("PostToolUse", c))
            XCTAssertEqual(s.progress?.done, n)
        }
        XCTAssertTrue(s.upcomingTodos.isEmpty)
        XCTAssertEqual(s.turnToolCount, 5)
    }

    func testInstructionIsOnlyInjectedWhenEnabled() async throws {
        let store = SessionStore()
        let off = await store.handle(ev("SessionStart", ["source": "startup"]))
        XCTAssertEqual(off, "")
        store.planReporting = true
        let on = await store.handle(ev("SessionStart", ["source": "compact"]))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(on.utf8)) as? [String: Any])
        let out = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(out["hookEventName"] as? String, "SessionStart")
        XCTAssertTrue((out["additionalContext"] as? String ?? "").contains("HIVE_PLAN"))
    }

    func testOpenSessionsGetTheInstructionOnceOnTheirNextPrompt() async {
        let store = SessionStore()
        _ = await store.handle(ev("SessionStart", ["source": "startup"]))          // switch still off
        let before = await store.handle(ev("UserPromptSubmit", ["prompt": "hello there"]))
        XCTAssertEqual(before, "")

        store.planReporting = true                                                  // user flips it mid-session
        let first = await store.handle(ev("UserPromptSubmit", ["prompt": "do five steps"]))
        XCTAssertTrue(first.contains("\"hookEventName\":\"UserPromptSubmit\""), first)
        XCTAssertTrue(first.contains("HIVE_PLAN"))
        XCTAssertEqual(store.sessions[0].state, .working, "the turn still starts normally")
        let second = await store.handle(ev("UserPromptSubmit", ["prompt": "and again"]))
        XCTAssertEqual(second, "", "only once per session")
    }

    func testSessionStartedWithSwitchOnIsNotInstructedTwice() async {
        let store = SessionStore()
        store.planReporting = true
        let start = await store.handle(ev("SessionStart", ["source": "startup"]))
        XCTAssertTrue(start.contains("HIVE_PLAN"))
        let prompt = await store.handle(ev("UserPromptSubmit", ["prompt": "do five steps"]))
        XCTAssertEqual(prompt, "")
    }

    func testReportedPlanDrivesProgressAndUpcoming() async {
        let store = SessionStore()
        _ = await store.handle(ev("UserPromptSubmit", ["prompt": "fix the bug please"]))
        let plan0 = bash(#"echo HIVE_PLAN 0 '["Read","Fix","Test"]'"#, id: "p0")
        _ = await store.handle(ev("PreToolUse", plan0))
        _ = await store.handle(ev("PostToolUse", plan0))
        let s = store.sessions[0]
        XCTAssertEqual(s.progress?.done, 0)
        XCTAssertEqual(s.progress?.total, 3)
        XCTAssertEqual(s.statusLine, "Read")
        XCTAssertEqual(s.upcomingTodos.map(\.content), ["Fix", "Test"])
        XCTAssertTrue(s.tools.isEmpty, "the report itself is not a step")
        XCTAssertEqual(s.turnToolCount, 0)

        // A real step runs; the next report must not mark it finished by accident.
        _ = await store.handle(ev("PreToolUse", bash("sleep 30", id: "real")))
        let plan1 = bash(#"echo HIVE_PLAN 1 '["Read","Fix","Test"]'"#, id: "p1")
        _ = await store.handle(ev("PreToolUse", plan1))
        _ = await store.handle(ev("PostToolUse", plan1))
        XCTAssertEqual(s.tools.count, 1)
        XCTAssertTrue(s.tools[0].running, "the long-running step is still running")
        XCTAssertEqual(s.upcomingTodos.map(\.content), ["Test"])

        _ = await store.handle(ev("PreToolUse", bash(#"echo HIVE_PLAN 3 '["Read","Fix","Test"]'"#, id: "p3")))
        XCTAssertEqual(s.progress?.done, 3)
        XCTAssertTrue(s.upcomingTodos.isEmpty)
        _ = await store.handle(ev("Stop"))
        _ = await store.handle(ev("UserPromptSubmit", ["prompt": "thanks, one more thing"]))
        XCTAssertNil(s.progress, "a finished plan doesn't linger into the next request")
    }
}
