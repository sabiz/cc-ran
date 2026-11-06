//! Attention state の状態遷移（spec §3）。I/O を持たない純粋な関数だけを置く。

const model = @import("model.zig");

const AttentionState = model.AttentionState;
const EventRow = model.EventRow;
const FileStatus = model.FileStatus;

/// 新しいセッションの最初の状態（idle）。
pub fn initial(at: i64) !AttentionState {
    _ = at;
    return error.NotImplemented;
}

/// イベントを 1 件適用した後の状態を返す。
/// 状態が変わらないときは since も agent_id も変えない。遷移の規則は plan 01 の Task 2 の表のとおり。
pub fn apply(state: AttentionState, event: EventRow) !AttentionState {
    _ = state;
    _ = event;
    return error.NotImplemented;
}

/// Stop はユーザーの中断では発火しないので、セッションファイルの status で working を補正する。
/// working かつ status が idle かつ status_updated_at > since かつ now - status_updated_at >= 3000 のとき、
/// idle（since = status_updated_at）を返す。それ以外は変えない。
pub fn reconcile(state: AttentionState, status: FileStatus, status_updated_at: ?i64, now: i64) !AttentionState {
    _ = state;
    _ = status;
    _ = status_updated_at;
    _ = now;
    return error.NotImplemented;
}
