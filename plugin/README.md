# cc-ran プラグイン

Claude Code のセッションイベントを、`cc-ran hook` で cc-ran の監視側に渡すプラグインです。

**cc-ran は Claude Code の設定ファイルを書き換えません。** プラグインの有効化は Claude Code 自身が管理します。

## 導入

1. `cc-ran` を PATH の通った場所に置きます。
   - Windows：`%LOCALAPPDATA%\cc-ran\bin\`
   - macOS：`~/.local/bin/`
2. Claude Code で次を実行します。

   ```text
   /plugin marketplace add <このリポジトリのパス、または GitHub のリポジトリ>
   /plugin install cc-ran@cc-ran
   ```

## 解除

`/plugin` から無効化するか、アンインストールします。データも消したい場合は、次のディレクトリを削除します。

- Windows：`%LOCALAPPDATA%\cc-ran\`
- macOS：`~/Library/Application Support/cc-ran/`

## 保存するもの

イベントの種別、`session_id`、受信時刻、`cwd`、`transcript_path`、`tool_name`、`notification_type`、`model`、`SessionStart` の `source`、サブエージェントの `agent_id`、`CLAUDE_CODE_DISABLE_1M_CONTEXT` が設定されているかどうか。

プロンプト、ツールの入出力、Claude の応答は保存しません。

## Claude の動作への影響

`cc-ran hook` は常に exit 0 で終わり、stdout に何も出しません。そのため Claude の動作をブロックしません。

`cc-ran` が PATH にない状態でプラグインを有効にすると、Hook の実行エラーが表示されることがあります。先に手順 1 を済ませてください。
