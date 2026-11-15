import Foundation

public enum ToolDescriber {
    public struct Description {
        public var kind: ToolKind
        public var title: String
        public var detail: String?
    }

    public static func describe(tool: String, input: [String: Any]) -> Description {
        func str(_ k: String) -> String? { input[k] as? String }
        func file(_ k: String = "file_path") -> String {
            (str(k).map { ($0 as NSString).lastPathComponent }) ?? "file"
        }

        switch tool {
        case "Bash":
            let cmd = str("command")
            let title = str("description") ?? ("Run " + shorten(firstLine(cmd ?? "command"), 48))
            return .init(kind: .terminal, title: title, detail: cmd)
        case "Read":
            return .init(kind: .read, title: "Read \(file())", detail: str("file_path"))
        case "Edit", "MultiEdit":
            return .init(kind: .edit, title: "Edit \(file())", detail: str("file_path"))
        case "Write":
            return .init(kind: .edit, title: "Write \(file())", detail: str("file_path"))
        case "NotebookEdit":
            return .init(kind: .edit, title: "Edit \(file("notebook_path"))", detail: str("notebook_path"))
        case "Glob":
            return .init(kind: .search, title: "Find \(shorten(str("pattern") ?? "files", 40))", detail: str("pattern"))
        case "Grep":
            return .init(kind: .search, title: "Search \(shorten(str("pattern") ?? "code", 40))", detail: str("pattern"))
        case "WebFetch":
            let host = str("url").flatMap { URL(string: $0)?.host } ?? "page"
            return .init(kind: .web, title: "Fetch \(host)", detail: str("url"))
        case "WebSearch":
            return .init(kind: .web, title: "Search the web: \(shorten(str("query") ?? "", 40))", detail: str("query"))
        case "Task", "Agent":
            return .init(kind: .agent, title: "Subagent: \(shorten(str("description") ?? "working", 44))", detail: str("prompt"))
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet":
            return .init(kind: .plan, title: "Update plan", detail: nil)
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                let last = parts.last.map(String.init) ?? tool
                return .init(kind: .other, title: "Use \(last.replacingOccurrences(of: "-", with: " "))", detail: nil)
            }
            return .init(kind: .other, title: "Use \(tool)", detail: nil)
        }
    }

    /// What we show inside a permission card.
    public static func permissionDetail(tool: String, input: [String: Any]) -> String {
        if tool == "Bash", let c = input["command"] as? String { return "Bash: \(shorten(c, 400))" }
        if let p = input["file_path"] as? String { return "\(tool): \(p)" }
        if let u = input["url"] as? String { return "\(tool): \(u)" }
        if let d = try? JSONSerialization.data(withJSONObject: input, options: [.withoutEscapingSlashes]),
           let s = String(data: d, encoding: .utf8), s != "{}" {
            return "\(tool): \(shorten(s, 300))"
        }
        return tool
    }

    public static func shorten(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n - 1)) + "…"
    }

    static func firstLine(_ s: String) -> String {
        s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? s
    }
}
