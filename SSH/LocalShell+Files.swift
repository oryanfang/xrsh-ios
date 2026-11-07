import Foundation
import UIKit

/// 文件命令：cd、ls、cat、echo、mkdir、rm、cp、mv、touch
extension LocalShell {
    // MARK: - 文件命令

    func cd(_ args: [String]) -> Out {
        let target = args.first.map(resolve) ?? home
        guard exists(target) else { return error(tr("cd: {0}: 没有这个目录", args.first ?? "")) }
        guard isDirectory(target) else { return error(tr("cd: {0}: 不是目录", args.first ?? "")) }
        cwd = target
        return ("", "")
    }

    func ls(_ args: [String]) -> Out {
        var long = false, all = false
        var paths: [String] = []
        for arg in args {
            if arg.hasPrefix("-"), arg.count > 1 {
                if arg.contains("l") { long = true }
                if arg.contains("a") { all = true }
            } else {
                paths.append(arg)
            }
        }
        if paths.isEmpty { paths = ["."] }

        var out = "", err = ""
        for (index, path) in paths.enumerated() {
            let url = resolve(path)
            guard exists(url) else {
                err += Color.red + tr("ls: {0}: 没有这个文件或目录", path) + Color.reset + "\n"
                continue
            }
            if paths.count > 1 { out += (index > 0 ? "\n" : "") + "\(path):\n" }
            if isDirectory(url) {
                var names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                if !all { names = names.filter { !$0.hasPrefix(".") } }
                names.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                out += listing(names, in: url, long: long)
            } else {
                out += listing([url.lastPathComponent], in: url.deletingLastPathComponent(), long: long)
            }
        }
        return (out, err)
    }

    func listing(_ names: [String], in dir: URL, long: Bool) -> String {
        guard !names.isEmpty else { return "" }
        func styled(_ name: String) -> String {
            isDirectory(dir.appendingPathComponent(name)) ? Color.blue + name + Color.reset : name
        }

        if long {
            let formatter = DateFormatter()
            formatter.dateFormat = tr("M月d日 HH:mm")
            formatter.locale = AppLanguage.locale
            let rows = names.map { name -> (String, String, String, String) in
                let url = dir.appendingPathComponent(name)
                let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
                let perms = (attrs[.posixPermissions] as? Int) ?? 0o644
                let size = (attrs[.size] as? Int) ?? 0
                let date = (attrs[.modificationDate] as? Date).map(formatter.string) ?? ""
                return ((isDir ? "d" : "-") + permissionString(perms), "\(size)", date, styled(name))
            }
            let sizeWidth = rows.map { $0.1.count }.max() ?? 1
            return rows.map { row in
                "\(row.0)  \(String(repeating: " ", count: sizeWidth - row.1.count))\(row.1)  \(row.2)  \(row.3)"
            }.joined(separator: "\n") + "\n"
        }

        // 按终端宽度排成多列
        let widths = names.map(Self.displayWidth)
        let cellWidth = (widths.max() ?? 1) + 2
        let perRow = max(1, cols / cellWidth)
        var out = ""
        for (index, name) in names.enumerated() {
            out += styled(name)
            let isRowEnd = (index + 1) % perRow == 0 || index == names.count - 1
            out += isRowEnd ? "\n" : String(repeating: " ", count: cellWidth - widths[index])
        }
        return out
    }

    func permissionString(_ mode: Int) -> String {
        let symbols = ["r", "w", "x"]
        return (0..<9).map { bit in
            mode & (1 << (8 - bit)) != 0 ? symbols[bit % 3] : "-"
        }.joined()
    }

    func cat(_ args: [String], stdin: String?) -> Out {
        if args.isEmpty { return (stdin ?? "", "") }
        var out = "", err = ""
        for path in args {
            let url = resolve(path)
            if !exists(url) {
                err += Color.red + tr("cat: {0}: 没有这个文件", path) + Color.reset + "\n"
            } else if isDirectory(url) {
                err += Color.red + tr("cat: {0}: 是目录", path) + Color.reset + "\n"
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                out += text
            } else {
                err += Color.red + tr("cat: {0}: 不是文本文件", path) + Color.reset + "\n"
            }
        }
        return (out, err)
    }

    func echo(_ args: [String]) -> Out {
        var words = args
        var newline = true
        if words.first == "-n" {
            newline = false
            words.removeFirst()
        }
        return (words.joined(separator: " ") + (newline ? "\n" : ""), "")
    }

    func mkdir(_ args: [String]) -> Out {
        let parents = args.contains("-p")
        let paths = args.filter { !$0.hasPrefix("-") }
        if paths.isEmpty { return error(tr("mkdir: 缺少目录名")) }
        var err = ""
        for path in paths {
            do {
                try FileManager.default.createDirectory(at: resolve(path), withIntermediateDirectories: parents)
            } catch {
                err += Color.red + tr("mkdir: {0}: 创建失败（已存在，或上级目录不存在，可加 -p）", path) + Color.reset + "\n"
            }
        }
        return ("", err)
    }

    func rm(_ args: [String]) -> Out {
        let recursive = args.contains { $0.hasPrefix("-") && ($0.contains("r") || $0.contains("R")) }
        let force = args.contains { $0.hasPrefix("-") && $0.contains("f") }
        let paths = args.filter { !$0.hasPrefix("-") }
        if paths.isEmpty { return error(tr("rm: 缺少文件名")) }
        var err = ""
        for path in paths {
            let url = resolve(path)
            if url.path == home.path || url.path == "/" {
                err += Color.red + tr("rm: 不能删除 {0}", path) + Color.reset + "\n"
            } else if !exists(url) {
                if !force { err += Color.red + tr("rm: {0}: 没有这个文件", path) + Color.reset + "\n" }
            } else if isDirectory(url), !recursive {
                err += Color.red + tr("rm: {0}: 是目录（删除目录要加 -r）", path) + Color.reset + "\n"
            } else {
                do { try FileManager.default.removeItem(at: url) } catch {
                    err += Color.red + tr("rm: {0}: 删除失败", path) + Color.reset + "\n"
                }
            }
        }
        return ("", err)
    }

    func copyOrMove(_ args: [String], move: Bool) -> Out {
        let name = move ? "mv" : "cp"
        let paths = args.filter { !$0.hasPrefix("-") }
        guard paths.count >= 2 else { return error(tr("{0}: 用法：{1} 源 目标", name, name)) }
        let sources = paths.dropLast().map(resolve)
        var destination = resolve(paths.last!)
        let destIsDir = isDirectory(destination)
        if sources.count > 1, !destIsDir { return error(tr("{0}: 目标必须是目录", name)) }

        var err = ""
        for (source, text) in zip(sources, paths.dropLast()) {
            guard exists(source) else {
                err += Color.red + tr("{0}: {1}: 没有这个文件", name, text) + Color.reset + "\n"
                continue
            }
            if isDirectory(source), !move, !args.contains(where: { $0.hasPrefix("-") && ($0.contains("r") || $0.contains("R")) }) {
                err += Color.red + tr("cp: {0}: 是目录（复制目录要加 -r）", text) + Color.reset + "\n"
                continue
            }
            if destIsDir { destination = resolve(paths.last!).appendingPathComponent(source.lastPathComponent) }
            do {
                if exists(destination) { try FileManager.default.removeItem(at: destination) }
                if move {
                    try FileManager.default.moveItem(at: source, to: destination)
                } else {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
            } catch {
                err += Color.red + tr("{0}: {1}: 操作失败", name, text) + Color.reset + "\n"
            }
        }
        return ("", err)
    }

    func touch(_ args: [String]) -> Out {
        if args.isEmpty { return error(tr("touch: 缺少文件名")) }
        for path in args {
            let url = resolve(path)
            if exists(url) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            } else {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
        return ("", "")
    }
}
