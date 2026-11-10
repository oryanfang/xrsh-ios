import Darwin
import Foundation

/// 启动本机进程要用到的小工具。这几个函数在 iOS 头文件里被标成不可用或不公开，只能运行时查找
nonisolated enum SpawnHelpers {
    /// 让子进程从指定目录开始；找不到函数就算了
    static func changeDirectory(_ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>, to path: String) {
        typealias AddChdir = @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t?>, UnsafePointer<CChar>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "posix_spawn_file_actions_addchdir_np") else { return }
        _ = unsafeBitCast(symbol, to: AddChdir.self)(actions, path)
    }

    /// 让子进程以 root 身份运行；找不到函数就不用 root
    static func applyRootPersona(_ attributes: UnsafeMutablePointer<posix_spawnattr_t?>) -> Bool {
        typealias SetPersona = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, uid_t, UInt32) -> Int32
        typealias SetID = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, uid_t) -> Int32
        guard let persona = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "posix_spawnattr_set_persona_np"),
              let uid = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "posix_spawnattr_set_persona_uid_np"),
              let gid = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "posix_spawnattr_set_persona_gid_np") else { return false }
        let setPersona = unsafeBitCast(persona, to: SetPersona.self)
        let setUID = unsafeBitCast(uid, to: SetID.self)
        let setGID = unsafeBitCast(gid, to: SetID.self)
        // 99 是越狱环境里常用的系统 persona，1 表示覆盖原有身份
        return setPersona(attributes, 99, 1) == 0 && setUID(attributes, 0) == 0 && setGID(attributes, 0) == 0
    }
}
