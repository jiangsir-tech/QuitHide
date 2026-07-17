# QuitHide

[English](README.en.md)

QuitHide 是一个原生 macOS 菜单栏工具，可以在 App 离开前台一段时间后，按独立规则自动隐藏或正常退出它。

## 功能

- 为每个正在运行的 App 分别设置“隐藏”“退出”或“不处理”
- 为每条自动规则单独设置等待时间
- 显示剩余时间和即将执行的动作
- App 重新激活后开始新的计时周期
- 一键提前隐藏或退出符合规则的 App
- 随时暂停自动处理
- 可选登录时启动
- 首次运行时所有 App 都处于“未设置”状态，不会被自动操作

## 系统要求

- macOS 13 Ventura 或更高版本
- Apple Silicon 或 Intel Mac（Universal 2）

## 下载与安装

1. 从 [GitHub Releases](https://github.com/1551255004/QuitHide/releases) 下载最新的 `.dmg`。
2. 打开 DMG，把 `QuitHide.app` 拖到“应用程序”文件夹。
3. 启动 QuitHide，然后点击菜单栏图标设置规则。

当前 Beta 版本尚未经过 Apple Developer ID 签名和公证。macOS 如果阻止首次打开，请在“系统设置 → 隐私与安全性”中确认来源后选择“仍要打开”。只应从本仓库的 Releases 页面下载安装包。

## 使用说明

在 App 右侧选择动作并设置等待时间。每个 App 的时间和动作会独立保存；设置页面中的时间只作为新规则的默认值。

底部的“立即隐藏”和“立即退出”会提前执行当前正在运行 App 的对应规则，不会修改规则或等待时间。即使自动处理已暂停，手动执行仍然可用。

“退出”使用 macOS 的正常退出请求，不会强制结束进程；未保存内容是否提示由目标 App 自己决定。

## 隐私

QuitHide 在本机运行，不包含网络请求、分析服务或第三方依赖，也不会上传正在运行的 App 列表和用户规则。

## 从源码构建

需要 Apple Swift 工具链。构建 Universal 2 App：

```sh
./scripts/build-app.sh
```

生成供 GitHub Releases 分发的 DMG 和 SHA-256 校验文件：

```sh
./scripts/build-dmg.sh
```

构建结果位于 `dist/`。

## 许可证

[MIT License](LICENSE)
