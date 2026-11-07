# Building · 从源码编译

[English](#english) · [中文](#中文)

## English

Requires Xcode with the iOS 17+ SDK.

```bash
xcodebuild -project SSH.xcodeproj -scheme SSH -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

To run on a device, pick your own Team in Xcode (Signing & Capabilities → Team).

**Dependencies** (Swift Package Manager): Citadel and SwiftTerm. The versions are pinned on purpose, please don't upgrade them casually:
- swift-nio is pinned to 2.103.0: 2.104.0 uses non‑copyable generics, whose type casts fail on iOS 17, and opening file transfer (SFTP) crashes.
- SwiftTerm is pinned to 1.11.2: newer versions need either a build plugin (which must be trusted manually in Xcode) or the Metal toolchain component.

Third‑party licenses are in `SSH/Licenses/`.

**Jailbreak build.** A jailbroken device can run a real shell, which needs extra entitlements. Copy `Jailbreak/local.env.example` to `Jailbreak/local.env`, fill in your `TEAM_ID` (and `PHONE_HOST` for one‑step deploys), then run `./Jailbreak/package.sh` to produce `Jailbreak/build/SSH.ipa`. See [Jailbreak/README.md](Jailbreak/README.md).

**Demo data (Debug builds only).** To take screenshots without exposing your own network, a Debug build reads these UserDefaults flags: `xrshDemo` (fake device list) and `xrshDemoTerminal` (a canned SSH session). Release builds and the packaged ipa don't contain this code.

## 中文

需要 Xcode 和 iOS 17 以上的 SDK。

```bash
xcodebuild -project SSH.xcodeproj -scheme SSH -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

要装到真机，在 Xcode 里选你自己的开发者账号（Signing & Capabilities → Team）。

**依赖**（Swift Package Manager）：Citadel、SwiftTerm。版本是特意固定的，请不要随手升级：
- swift-nio 固定在 2.103.0：2.104.0 用了「不可复制泛型」，在 iOS 17 上类型转换失败，打开传文件（SFTP）就会崩溃。
- SwiftTerm 固定在 1.11.2：更新的版本要么带编译插件（要在 Xcode 里手动信任），要么需要 Metal 编译组件。

第三方许可见 `SSH/Licenses/`。

**越狱版。** 越狱环境下可以拿到真 shell，需要给 App 签上额外的权限。把 `Jailbreak/local.env.example` 复制成 `Jailbreak/local.env`，填上你的 `TEAM_ID`（一键部署还要填 `PHONE_HOST`），再运行 `./Jailbreak/package.sh`，产物是 `Jailbreak/build/SSH.ipa`。详见 [Jailbreak/README.md](Jailbreak/README.md)。

**演示数据（仅调试版）。** 为了截图时不暴露自己的网络，调试版会读两个 UserDefaults 开关：`xrshDemo`（假的设备列表）和 `xrshDemoTerminal`（一段预设的 SSH 会话）。正式版和打好的 ipa 里没有这段代码。
