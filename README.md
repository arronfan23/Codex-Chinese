# Codex 桌面版中文汉化工具（Localize）

为 Codex 桌面版（Microsoft Store 版 / 官网安装版）开启**官方内置多语言**，默认简体中文，中英自由切换。
纯 PowerShell 实现，无第三方依赖，不需要管理员权限，不修改原版安装。

> 原理参考并改编自 [Yaozhu666/Codex-Chinese](https://github.com/Yaozhu666/Codex-Chinese)（MIT License），
> 在其基础上更新补丁规则以适配 **Codex 26.930.7945.0（Store 版，2026-10 实测）**。

## 原理

Codex 桌面版官方自带完整的简体中文翻译包（app.asar 内含 `zh-CN.json` 等 60+ 语言），
但主界面的多语言开关 `enable_i18n` 被实验开关默认关闭，界面因此永远是英文。

本工具只做一件事：解包 `app.asar`，把 `.get(\`enable_i18n\`,!1)` 改为 `.get(\`enable_i18n\`,!0)`，
再原样重打包。补丁按**内容**匹配（不依赖带哈希的文件名），因此跨版本更稳：
即便混淆变量名变化（如旧版 `a?.get(...)` 变为新版 `s?.get(...)`）也能命中。

## 使用

1. 下载本仓库（Code → Download ZIP，或 `git clone`）；
2. 双击 `install.cmd`，按提示完成（Store 版首次会复制约 1~2GB 副本，仅一次）；
3. 用桌面新建的 **「Codex 本地化版」** 快捷方式启动；
4. 在 设置 → General → Language 中选 **中文（中国）** 或 **English**，立即生效。

想恢复原版？直接启动原来的 Codex 图标即可，两者互不影响。
Codex 更新后无需手动处理：启动器检测到版本变化会自动重新打补丁。

## 与上游的差异

- 关键补丁规则泛化为 `.get(\`enable_i18n\`,!1)`：26.930.x 版本中混淆变量名已从 `a?` 变为 `s?`，
  上游规则会未命中，本规则兼容两种写法；
- 默认语言回退规则更新为 `getLocale():\`en\`` → `getLocale():\`zh-CN\``（26.930.x 实测命中 1 处）；
- 安装器关闭进程时只针对补丁目标，**不会结束正在运行的原版 Codex**（副本模式）；
- `install.cmd` / `launch.cmd` 放在仓库根目录，路径已相应修正。

## 目录结构

```
├── install.cmd        # 双击安装
├── launch.cmd         # 手动启动本地化版（一般用桌面快捷方式即可）
└── src/
    ├── install.ps1        # 安装器（检测/复制/补丁/配置）
    ├── launch.ps1         # 启动器（自动适配更新后启动）
    ├── patch-rules.ps1    # 补丁规则库（按内容匹配，跨版本）
    └── asar-util.ps1      # asar 解包/打包（纯 .NET）
```

## 注意

- 本工具只改界面语言，**不解决网络问题**（API 访问请自行配置）。
- Codex 自动更新后如界面回到英文，重新运行一次 `install.cmd` 即可。
- 仅供学习交流，非官方方案，使用前请自行核对。
