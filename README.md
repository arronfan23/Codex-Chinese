# Codex-Chinese · Codex 桌面版中文汉化工具

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-lightgrey.svg)]()
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)]()
[![Release](https://img.shields.io/github/v/release/arronfan23/Codex-Chinese)](https://github.com/arronfan23/Codex-Chinese/releases/latest)

一键开启 Codex 桌面版（Microsoft Store / 官网 MSIX / 官网安装版）**官方内置的简体中文界面**，
中英自由切换。纯 PowerShell 实现，无第三方依赖，不需要管理员权限，不修改原版安装。

![中文界面实测](docs/images/ui-zh.png)

## 原理

Codex 桌面版官方自带 60+ 语言翻译包（`app.asar` 内含 `zh-CN.json` 等），但多语言开关
`enable_i18n` 被实验开关默认关闭，界面永远是英文。本工具做的事：

```
Store/MSIX 版（受保护目录）        官网安装版（可写目录）
        │                                │
        │ 复制可写副本                    │ 直接补丁（自动备份）
        ▼                                ▼
  解包 app.asar ──▶ 开启 enable_i18n ──▶ 重打包（逐文件 integrity 校验哈希）
                          │
        ┌─────────────────┼──────────────────────────┐
        ▼                 ▼                          ▼
  默认语言回退       同步 exe 内嵌的              启动时借用已安装包的
  en → zh-CN       asar 完整性哈希              MSIX 包身份启动副本
```

- 补丁按**内容**匹配（不依赖带哈希的文件名），混淆变量名变化也能命中，跨版本更稳；
- 新版 Electron 的 `EnableEmbeddedAsarIntegrityValidation` 已适配：重打包时为每个文件重新生成
  SHA256 校验（整文件 + 4MB 分块），并把新的头部哈希同步写回 `ChatGPT.exe`（原文件自动备份）；
- MSIX 包身份检查已适配：启动器通过 `Invoke-CommandInDesktopPackage` 借用已安装包的标识符
  启动副本，规避 "ChatGPT failed to start / 该进程没有程序包标识符"；
- 已实测版本：**26.930.7945.0（Store 版）**、**26.915.4065.0（MSIX 安装包）**，均验证启动 + 全中文界面。

## 快速开始

1. **安装 Codex**（没装的电脑）：
   [Release v1.1.0](https://github.com/arronfan23/Codex-Chinese/releases/tag/v1.1.0) 里附带了官方
   MSIX 安装包（26.915.4065.0，已实测兼容），或用 Microsoft Store / 官网安装任意版本；
2. **下载本工具**：[最新 Release](https://github.com/arronfan23/Codex-Chinese/releases/latest)
   里的 zip，解压；
3. **双击 `install.cmd`**，全程有进度条；Store 版首次会复制约 1~2GB 副本，仅一次；
4. 用桌面新建的 **「Codex」** 快捷方式启动（指向本地化副本，原版开始菜单入口不受影响）；
5. 在 **设置 → General → Language** 选 **中文（中国）** 或 **English**，立即生效，随时切换。

想恢复原版？直接启动原来的 Codex 图标即可，两者互不影响。
Codex 更新后无需手动处理：启动器检测到版本变化会自动重新打补丁。

## 命令行（可选）

```powershell
# 只检测，不操作
powershell -NoProfile -ExecutionPolicy Bypass -File "src\install.ps1" -DryRun

# 手动指定安装路径（自动检测失败时）
powershell -NoProfile -ExecutionPolicy Bypass -File "src\install.ps1" -InstallPath "C:\path\to\codex\app"

# 强制重新本地化后启动
powershell -NoProfile -ExecutionPolicy Bypass -File "src\launch.ps1" -ForceUpdate
```

## 常见问题

| 问题 | 解决 |
|---|---|
| 启动报 "该进程没有程序包标识符" | 旧版工具的已知问题，下载 v1.2.0+ 重跑 `install.cmd` 即可（自动修复旧副本） |
| 双击后进程一闪而过/没反应 | 同上，v1.2.0+ 已适配 asar 完整性校验 |
| Codex 更新后界面回到英文 | 启动器会自动重打补丁；也可手动重跑 `install.cmd` |
| 补丁点未命中 | 安装器会自动打印上下文片段，发 Issue 附上即可 |
| 完全卸载 | 删除 `%USERPROFILE%\.codex\codex-localized` 和桌面快捷方式，原版不受影响 |

## 目录结构

```
├── install.cmd        # 双击安装（纯 ASCII + CRLF，兼容所有区域设置）
├── launch.cmd         # 手动启动本地化版
├── docs/images/       # README 截图
└── src/
    ├── install.ps1        # 安装器（检测/复制/补丁/完整性同步/配置）
    ├── launch.ps1         # 启动器（自动适配更新 + 包身份注入启动）
    ├── patch-rules.ps1    # 补丁规则库（按内容匹配，附未命中自动诊断）
    ├── asar-util.ps1      # asar 解包/打包（纯 .NET，长路径/对齐/逐文件 integrity）
    └── smo-banner.ps1     # 终端横幅（SMO 像素字渐变）
```

## 更新日志

- **v1.2.0** 修复三大启动障碍：asar 完整性校验（exe 哈希同步 + 逐文件 integrity）、
  asar 头部 4 字节对齐、MSIX 包身份注入启动；旧版副本自动还原重打
- **v1.1.0** 实测适配 26.915.4065.0（MSIX），Release 附带官方安装包
- **v1.0.0** 首个版本：补丁规则泛化（兼容 26.930 混淆变量名变化）、长路径支持

## 致谢

原理与框架参考 [Yaozhu666/Codex-Chinese](https://github.com/Yaozhu666/Codex-Chinese)（MIT），
在此之上修复了 asar 对齐 / 完整性校验 / 包身份三个新版启动障碍。
终端横幅来自 smo-terminal-banner 技能（MiniMax 风格像素字渐变）。

## License

[MIT](LICENSE)。仅供学习交流，非官方方案；Codex 为 OpenAI 产品，本仓库不包含其任何代码。
