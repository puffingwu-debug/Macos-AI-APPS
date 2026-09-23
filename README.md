# Macos AI APPS

macOS 上的 AI 相关小工具集合。每个项目各自独立，均为原生 Swift / SwiftUI，
不依赖 Xcode 工程文件（`swift build` 即可）。

## 项目

| 项目 | 说明 |
|---|---|
| [AITokenBar](AITokenBar/) | 桌面小窗口，实时显示 ChatGPT / Codex 额度与重置倒计时、DeepSeek 余额与 token 用量。外观与吸附对齐系统桌面小组件。 |

## 约定

- 每个项目一个子目录，`Package.swift` 放在子目录内
- 每个项目自带 `build.sh`（编译 + 打包 `.app` + ad-hoc 签名）与 `README.md`
- 构建产物（`.build/`、`dist/`）不入库

## 推送到 GitHub

本机到 `github.com` 的 git HTTPS 端点不通（连接超时），但 `api.github.com` 正常，
所以用 `push-to-github.sh` 走 Git Data API 提交，等价于一次 `git push`：

```bash
./push-to-github.sh "提交说明"     # 省略说明则用时间戳
```

它读取远端当前 `main` 作为父提交，历史正常累积；以 git 索引为准，`.gitignore` 依然生效。

> 如果想让标准 `git push` 也能用：`github.com:22` 与 `ssh.github.com:443` 都是通的，
> 生成一把 SSH key 加到 GitHub（Settings → SSH keys）即可，之后就能正常 `git remote set-url` 换用 SSH。

## 环境

macOS 15+、Swift 6 工具链。部分项目额外需要 `brew install zstd`。
