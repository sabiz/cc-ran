# cc-ran

**cc-ran**（Claude Code - Realtime Activity Notifier）は、起動中の Claude Code セッションの状態（承認待ち、入力待ち、完了、エラー、作業中、コンテキスト使用率）を一覧で表示する、Windows / macOS 向けのネイティブアプリです。

- 設計：[`docs/specs/2026-11-05-cc-ran-design.md`](docs/specs/2026-11-05-cc-ran-design.md)
- 実装計画：[`docs/plans/`](docs/plans/)

## 構成

| ディレクトリ | 内容 |
|---|---|
| `contracts/` | monitor と UI の唯一の接点（スキーマ、VIEW、fixtures） |
| `monitor/` | 監視側（Zig 0.17.1）。バイナリ名は `cc-ran` |
| `ui/avalonia/` | UI 側（.NET 10 + Avalonia 12.1）。バイナリ名は `cc-ran-ui` |

## ビルドとテスト

```sh
# monitor
cd monitor
zig build
zig build test
zig build -Dtarget=aarch64-macos

# UI
cd ui/avalonia
dotnet build
dotnet test
```
