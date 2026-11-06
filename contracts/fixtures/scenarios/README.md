# scenarios

reducer の状態遷移のシナリオです。監視側のテスト（`monitor/tests/reducer_test.zig`）が読みます。

```json
{
  "name": "permission-approved",
  "description": "説明",
  "start": { "attention": "working", "since": 5 },
  "steps": [
    {
      "at": 20,
      "input": "PermissionRequest",
      "expect": { "attention": "needs_permission", "since": 20, "agent_id": null }
    }
  ]
}
```

- `input`：`../hook-inputs/` の fixture 名です。`at` が `received_at` になります。
- `event`：`input` の代わりに、イベント名を直接指定します（fixture のない、知らないイベントのため）。
- `expect`：その 1 ステップを適用した後の状態です。
- 状態が変わらないときは、`since` も `agent_id` も変わりません。
