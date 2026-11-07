import Citadel
import Combine
import Foundation
import NIO

/// 文件传输：通过已经连上的 SSH 连接打开 SFTP，浏览对方的文件夹、下载、上传
@MainActor
final class SFTPBrowser: ObservableObject {
    struct Entry: Identifiable {
        let name: String
        let isDirectory: Bool
        let size: UInt64?
        let modified: Date?
        var id: String { name }
    }

    struct DownloadedFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    struct Transfer {
        let name: String
        let isUpload: Bool
        var fraction: Double
    }

    /// 打开传文件时默认进入的位置；对方没有这个文件夹（比如 Linux）就进家目录
    private static let startFolder = "/Users"
    private static let chunk = 32_000

    @Published private(set) var path = ""
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoading = true
    @Published private(set) var transfer: Transfer?
    @Published var notice: String?
    /// 刚下载完的文件；界面据此弹出系统的"存储到…"面板
    @Published var downloaded: DownloadedFile?
    @Published var errorText: String?

    let host: String
    private let session: SSHSession
    private var sftp: SFTPClient?
    private var homeDir = "/"

    init(session: SSHSession) {
        self.session = session
        host = session.host
    }

    var isAtRoot: Bool { path == "/" }
    var isAtHome: Bool { path == homeDir }

    /// 手机上存放下载文件的文件夹（越狱版没有沙盒，实际是 /var/mobile/Documents/Downloads，
    /// "文件"App 看不到，所以下载完会弹出"存储到…"面板）
    var downloadsFolder: URL { AppFolders.downloads }

    // MARK: - 打开与浏览

    func start() async {
        isLoading = true
        do {
            let client = try await session.openSFTP()
            sftp = client
            homeDir = try await client.getRealPath(atPath: ".")
            let startExists = (try? await client.getAttributes(at: Self.startFolder)) != nil
            await load(startExists ? Self.startFolder : homeDir)
        } catch {
            isLoading = false
            errorText = tr("打开文件传输失败：{0}", Self.describe(error))
        }
    }

    func load(_ target: String) async {
        guard let sftp else { return }
        isLoading = true
        do {
            let names = try await sftp.listDirectory(atPath: target)
            let items = names.flatMap(\.components).compactMap { component -> Entry? in
                guard component.filename != ".", component.filename != ".." else { return nil }
                let permissions = component.attributes.permissions ?? 0
                let isDirectory = permissions & 0o170000 == 0o040000 || component.longname.first == "d"
                return Entry(
                    name: component.filename,
                    isDirectory: isDirectory,
                    size: component.attributes.size,
                    modified: component.attributes.accessModificationTime?.modificationTime
                )
            }
            entries = items.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                let (a, b) = (Self.priority($0), Self.priority($1))
                if a != b { return a < b }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            path = target
        } catch {
            errorText = tr("打开文件夹失败：{0}", Self.describe(error))
        }
        isLoading = false
    }

    /// 常用文件夹排在前面（数字越小越靠前），其余文件夹按名字排
    private static let pinnedFolders = [
        "desktop", "documents", "downloads", "pictures", "music", "movies", "videos", "public",
    ]

    private static func priority(_ entry: Entry) -> Int {
        guard entry.isDirectory else { return pinnedFolders.count }
        return pinnedFolders.firstIndex(of: entry.name.lowercased()) ?? pinnedFolders.count
    }

    func enter(_ entry: Entry) async {
        await load(join(path, entry.name))
    }

    func goUp() async {
        guard !isAtRoot else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await load(parent.isEmpty ? "/" : parent)
    }

    /// 跳到用户输入的路径；支持 ~ 开头（对方的家目录）和相对当前位置的写法
    func go(to typed: String) async {
        var target = typed.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        if target == "~" || target.hasPrefix("~/") {
            target = homeDir + target.dropFirst()
        } else if !target.hasPrefix("/") {
            target = join(path, target)
        }
        await load(target)
    }

    func goHome() async {
        await load(homeDir)
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }

    // MARK: - 下载

    func download(_ entry: Entry) async {
        guard let sftp, transfer == nil else { return }
        transfer = Transfer(name: entry.name, isUpload: false, fraction: 0)
        defer { transfer = nil }

        do {
            try FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
            let destination = uniqueURL(for: entry.name)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }

            let file = try await sftp.openFile(filePath: join(path, entry.name), flags: .read)
            let total = (try? await file.readAttributes().size) ?? entry.size ?? 0
            var offset: UInt64 = 0
            do {
                while true {
                    let buffer = try await file.read(from: offset, length: UInt32(Self.chunk))
                    if buffer.readableBytes == 0 { break }
                    try output.write(contentsOf: Data(buffer.readableBytesView))
                    offset += UInt64(buffer.readableBytes)
                    if total > 0 { transfer?.fraction = min(1, Double(offset) / Double(total)) }
                }
            } catch {
                try? await file.close()
                throw error
            }
            try await file.close()
            downloaded = DownloadedFile(url: destination)
        } catch {
            errorText = tr("下载失败：{0}", Self.describe(error))
        }
    }

    /// 本地已经有同名文件就加个序号，不覆盖
    private func uniqueURL(for name: String) -> URL {
        var url = downloadsFolder.appendingPathComponent(name)
        var index = 1
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = downloadsFolder.appendingPathComponent(ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)")
            index += 1
        }
        return url
    }

    // MARK: - 上传

    func upload(_ urls: [URL]) async {
        guard let sftp, transfer == nil else { return }
        var done: [String] = []

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                errorText = tr("暂时不支持上传文件夹：{0}", url.lastPathComponent)
                continue
            }

            transfer = Transfer(name: url.lastPathComponent, isUpload: true, fraction: 0)
            do {
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                let total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0

                let file = try await sftp.openFile(
                    filePath: join(path, url.lastPathComponent),
                    flags: [.write, .create, .truncate]
                )
                var offset: UInt64 = 0
                do {
                    while let data = try input.read(upToCount: Self.chunk), !data.isEmpty {
                        try await file.write(ByteBuffer(bytes: data), at: offset)
                        offset += UInt64(data.count)
                        if total > 0 { transfer?.fraction = min(1, Double(offset) / Double(total)) }
                    }
                } catch {
                    try? await file.close()
                    throw error
                }
                try await file.close()
                done.append(url.lastPathComponent)
            } catch {
                errorText = tr("上传「{0}」失败：{1}", url.lastPathComponent, Self.describe(error))
            }
        }
        transfer = nil

        if !done.isEmpty {
            notice = tr("已上传 {0} 个文件到 {1}", done.count, path)
            await load(path)
        }
    }

    // MARK: - 收尾

    func close() {
        let client = sftp
        sftp = nil
        Task { try? await client?.close() }
    }

    private static func describe(_ error: Error) -> String {
        if let status = error as? SFTPMessage.Status {
            if status.errorCode == .permissionDenied { return tr("没有权限") }
            if status.errorCode == .noSuchFile { return tr("文件或文件夹不存在") }
            return status.message
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
