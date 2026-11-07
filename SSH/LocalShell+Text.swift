import Foundation
import UIKit

/// 文本命令：head、tail、wc、grep
extension LocalShell {
    // MARK: - 文本命令

    /// 读取一个文件的文本，或者没有文件时用管道里的输入
    func inputText(file: String?, stdin: String?, command: String) -> (text: String?, err: String) {
        guard let file else { return (stdin ?? "", "") }
        let url = resolve(file)
        guard exists(url), !isDirectory(url), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (nil, Color.red + tr("{0}: {1}: 无法读取", command, file) + Color.reset + "\n")
        }
        return (text, "")
    }

    func headTail(_ args: [String], stdin: String?, head: Bool) -> Out {
        var count = 10
        var file: String?
        var index = 0
        while index < args.count {
            if args[index] == "-n", index + 1 < args.count, let n = Int(args[index + 1]) {
                count = n
                index += 1
            } else if args[index].hasPrefix("-"), let n = Int(args[index].dropFirst()) {
                count = n
            } else {
                file = args[index]
            }
            index += 1
        }
        let (text, err) = inputText(file: file, stdin: stdin, command: head ? "head" : "tail")
        guard let text else { return ("", err) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let body = lines.last == "" ? Array(lines.dropLast()) : lines
        let picked = head ? Array(body.prefix(count)) : Array(body.suffix(count))
        return (picked.isEmpty ? "" : picked.joined(separator: "\n") + "\n", "")
    }

    func wc(_ args: [String], stdin: String?) -> Out {
        let flags = args.filter { $0.hasPrefix("-") }
        let file = args.first { !$0.hasPrefix("-") }
        let (text, err) = inputText(file: file, stdin: stdin, command: "wc")
        guard let text else { return ("", err) }
        let lines = text.filter { $0 == "\n" }.count
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let chars = text.utf8.count
        var parts: [String] = []
        if flags.isEmpty {
            parts = ["\(lines)", "\(words)", "\(chars)"]
        } else {
            if flags.contains(where: { $0.contains("l") }) { parts.append("\(lines)") }
            if flags.contains(where: { $0.contains("w") }) { parts.append("\(words)") }
            if flags.contains(where: { $0.contains("c") }) { parts.append("\(chars)") }
        }
        return (parts.joined(separator: " ") + (file.map { " \($0)" } ?? "") + "\n", "")
    }

    func grep(_ args: [String], stdin: String?) -> Out {
        let ignoreCase = args.contains { $0.hasPrefix("-") && $0.contains("i") }
        let numbered = args.contains { $0.hasPrefix("-") && $0.contains("n") }
        let rest = args.filter { !$0.hasPrefix("-") }
        guard let pattern = rest.first else { return error(tr("grep: 用法：grep [-i] [-n] 关键词 [文件]")) }
        let files = Array(rest.dropFirst())

        func matching(_ text: String, prefix: String) -> String {
            var out = ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() {
                let hit = ignoreCase ? line.localizedCaseInsensitiveContains(pattern) : line.contains(pattern)
                if hit { out += prefix + (numbered ? "\(number + 1):" : "") + line + "\n" }
            }
            return out
        }

        if files.isEmpty { return (matching(stdin ?? "", prefix: ""), "") }
        var out = "", err = ""
        for file in files {
            let (text, problem) = inputText(file: file, stdin: nil, command: "grep")
            err += problem
            if let text { out += matching(text, prefix: files.count > 1 ? "\(file):" : "") }
        }
        return (out, err)
    }
}
