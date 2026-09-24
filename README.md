# Macos AI APPS

macOS 上的 AI 相关小工具集合。多数项目为原生 Swift / SwiftUI，不依赖 Xcode 工程文件
（`swift build` 即可）；跨端项目另有微信小程序与云函数部分。

## 项目

| 项目 | 说明 |
|---|---|
| [AITokenBar](AITokenBar/) | 桌面小窗口，实时显示 ChatGPT / Codex 额度与重置倒计时、DeepSeek 余额与 token 用量。外观与吸附对齐系统桌面小组件。 |
| [QuickTodo](QuickTodo/) | macOS 桌面悬浮待办客户端：贴边隐藏悬浮球 + 全局快捷键 ⌘⇧A 区域截图 → 系统 Vision 本地 OCR → 云端 DeepSeek 结构化解析 → 一键导入；离线可用、多端增量同步。 |
| [quicktodo-weapp](quicktodo-weapp/) | QuickTodo 的微信端：原生小程序（常驻悬浮球、长按语音转文字、AI 拆分待办）+ 微信云开发云函数（`todo` / `ai` / `auth`，DeepSeek 密钥仅存云函数环境变量）。 |

跨端接口契约（Mac / 小程序 / 云函数三方共同的唯一真相来源）：
[docs/SYNC-PROTOCOL.md](docs/SYNC-PROTOCOL.md)

验证记录（实际跑过的命令与真实输出）：[docs/VERIFICATION.md](docs/VERIFICATION.md)

## 校验入口

```bash
node tools/check-contract.js                      # 跨端契约一致性（字段名/action/密钥边界），56 项

cd QuickTodo && ./build.sh release
./dist/QuickTodo.app/Contents/MacOS/QuickTodo --selftest        # Mac 端离线自检，40 项（含真实 Vision OCR）

cd quicktodo-weapp && node tools/cloud-harness.js               # 云函数自检（内存库，无需部署），103 项
node tools/miniprogram-tests.js                                 # 小程序端核心逻辑回归，105 项

# 跨端真实联调：真 Mac 客户端 ↔ 真云函数（HTTP 云接入形状），50 项
cd quicktodo-weapp && node tools/cloud-harness.js --serve 8787  # 终端 A，启动日志会打印预置 token
cd QuickTodo && ./dist/QuickTodo.app/Contents/MacOS/QuickTodo \
    --integration http://127.0.0.1:8787 <预置token>             # 终端 B
```

## 约定

- 每个项目一个子目录，`Package.swift` 放在子目录内
- 每个项目自带 `build.sh`（编译 + 打包 `.app` + ad-hoc 签名）与 `README.md`
- 构建产物（`.build/`、`dist/`）不入库
- 跨端项目：**先改契约再改代码**，契约版本号 +1，改完跑一遍 `node tools/check-contract.js`

## 推送到 GitHub

本机到 `github.com` 的 git HTTPS 端点不通（连接超时），但 `api.github.com` 正常，
所以用 `push-to-github.sh` 走 Git Data API 提交，等价于一次 `git push`：

```bash
./push-to-github.sh "提交说明"     # 省略说明则用时间戳
```

它读取远端当前 `main` 作为父提交，历史正常累积；以 git 索引为准，`.gitignore` 依然生效。

> 本地 `git` 历史与 GitHub 上的历史是**两条独立的时间线**（远端提交由 API 直接创建，
> SHA 与本地不同）。因为本机根本推不了 git 端点，这不影响使用——**以 GitHub 上
> 的内容为准，本地仓库只是工作副本**。若日后在能正常联网的环境里克隆一份，
> 一切照常。

> 如果想让标准 `git push` 也能用：`github.com:22` 与 `ssh.github.com:443` 都是通的，
> 生成一把 SSH key 加到 GitHub（Settings → SSH keys）即可，之后就能正常 `git remote set-url` 换用 SSH。

## 环境

macOS 15+、Swift 6 工具链。部分项目额外需要 `brew install zstd`。
