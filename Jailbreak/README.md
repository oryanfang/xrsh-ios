# 越狱版打包与安装

App 只有一份代码。运行时会先试着启动真的 shell（zsh / bash）：成功就是真终端，
失败就退回 App 自带的小命令行，并在开场白里写明原因。

真 shell 需要两样东西：

1. 手机是越狱环境（roothide / rootless / rootful 都会去找 shell）。
2. App 签上了 `SSH.entitlements` 里的特殊权限。普通的 Xcode 签名装出来的 App 没有这些权限，
   所以会退回小命令行。

## 先设置自己的信息

复制 `Jailbreak/local.env.example` 为 `Jailbreak/local.env`，填上你的 `TEAM_ID`（打包用）和
`PHONE_HOST`（一键部署用）。这个文件不会被提交到 git。

## 打包

```bash
./Jailbreak/package.sh
```

产物是 `Jailbreak/build/SSH.ipa`，里面的主程序已经用 `ldid` 签好权限。
也可以直接 `./Jailbreak/deploy.sh` 一步打包、传到手机并用 TrollStoreLite 安装。

## 安装

把 `SSH.ipa` 放到手机上，用你平时给 roothide 越狱装 App 的方式装（Filza / TrollStore / 手动放进
越狱目录的 Applications 再执行 `uicache -p`）。装好后打开 App，点"进入本机终端"。

## 看是不是真 shell

进入本机终端后，如果开场白里没有灰色的"真 shell 不可用：……"，就是真的了。
输入 `whoami`（root 或 mobile）、`uname -a`、`ps aux` 试试。

灰色提示里会写原因，把它原样发给开发者就能判断哪一步没通过。
