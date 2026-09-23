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

## 环境

macOS 15+、Swift 6 工具链。部分项目额外需要 `brew install zstd`。
