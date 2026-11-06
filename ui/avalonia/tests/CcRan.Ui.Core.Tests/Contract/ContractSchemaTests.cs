using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace CcRan.Ui.Core.Tests.Contract;

public sealed class ContractSchemaTests : IDisposable
{
    private readonly SqliteConnection _db = new("Data Source=:memory:");

    public ContractSchemaTests() => _db.Open();

    public void Dispose() => _db.Dispose();

    private void ApplySchema() => Exec(File.ReadAllText(ContractPaths.InitSql));

    private void Exec(string sql)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private object? Scalar(string sql)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        return cmd.ExecuteScalar();
    }

    private void InsertSession(
        string sessionId = "s1",
        string attention = "working",
        string usedTokens = "NULL",
        string windowTokens = "NULL") =>
        Exec($"""
            INSERT INTO sessions(session_id, origin, display_name, kind, attention, attention_since,
                                 last_activity_at, context_used_tokens, context_window_tokens,
                                 context_level, window_source, sort_rank)
            VALUES ('{sessionId}', 'local', 'demo', 'interactive', '{attention}', 1, 1,
                    {usedTokens}, {windowTokens}, 'unknown', 'unknown', 0)
            """);

    private List<string> ViewColumns(string view)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = $"SELECT name FROM pragma_table_xinfo('{view}') ORDER BY cid";
        using var reader = cmd.ExecuteReader();
        var names = new List<string>();
        while (reader.Read())
        {
            names.Add(reader.GetString(0));
        }

        return names;
    }

    private static List<string> ContractColumns(string view)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(ContractPaths.ColumnsJson));
        return doc.RootElement.GetProperty("views").GetProperty(view).EnumerateArray()
            .Select(c => c.GetProperty("name").GetString()!)
            .ToList();
    }

    [Fact]
    public void Schema_applies_to_empty_db()
    {
        ApplySchema();

        Assert.Equal(1L, Scalar("PRAGMA user_version"));
    }

    [Fact]
    public void Schema_is_idempotent()
    {
        ApplySchema();
        ApplySchema();

        Assert.Equal(1L, Scalar("SELECT COUNT(*) FROM monitor_state"));
    }

    [Theory]
    [InlineData("v_sessions")]
    [InlineData("v_monitor")]
    public void View_columns_match_columns_json(string view)
    {
        ApplySchema();

        Assert.Equal(ContractColumns(view), ViewColumns(view));
    }

    [Fact]
    public void V_sessions_exposes_the_15_contract_columns()
    {
        Assert.Equal(
            [
                "session_id", "origin", "display_name", "cwd", "kind", "attention", "attention_since",
                "context_used_tokens", "context_window_tokens", "context_ratio", "context_level",
                "window_source", "model", "last_activity_at", "sort_rank",
            ],
            ContractColumns("v_sessions"));
    }

    [Fact]
    public void V_monitor_exposes_the_4_contract_columns()
    {
        Assert.Equal(
            ["contract_version", "daemon_alive", "daemon_heartbeat_at", "hooks_seen"],
            ContractColumns("v_monitor"));
    }

    [Fact]
    public void Monitor_view_has_single_row_with_contract_1_0()
    {
        ApplySchema();

        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT contract_version, daemon_alive, hooks_seen FROM v_monitor";
        using var reader = cmd.ExecuteReader();

        Assert.True(reader.Read());
        Assert.Equal("1.0", reader.GetString(0));
        Assert.Equal(0L, reader.GetInt64(1));
        Assert.Equal(0L, reader.GetInt64(2));
        Assert.False(reader.Read());
    }

    [Fact]
    public void Daemon_is_alive_when_heartbeat_is_within_stale_window()
    {
        ApplySchema();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        Exec($"UPDATE monitor_state SET daemon_heartbeat_at = {now}");

        Assert.Equal(1L, Scalar("SELECT daemon_alive FROM v_monitor"));
    }

    [Fact]
    public void Daemon_is_dead_when_heartbeat_is_older_than_stale_window()
    {
        ApplySchema();
        var old = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - 60_000;
        Exec($"UPDATE monitor_state SET daemon_heartbeat_at = {old}");

        Assert.Equal(0L, Scalar("SELECT daemon_alive FROM v_monitor"));
    }

    [Fact]
    public void Monitor_state_rejects_a_second_row()
    {
        ApplySchema();

        Assert.Throws<SqliteException>(
            () => Exec("INSERT INTO monitor_state(id, contract_version) VALUES (2, '1.0')"));
    }

    [Fact]
    public void Sessions_reject_unknown_attention()
    {
        ApplySchema();

        Assert.Throws<SqliteException>(() => InsertSession(attention: "bogus"));
    }

    [Theory]
    [InlineData("needs_permission")]
    [InlineData("needs_input")]
    [InlineData("error")]
    [InlineData("done")]
    [InlineData("working")]
    [InlineData("idle")]
    [InlineData("ended")]
    public void Sessions_accept_every_contract_attention(string attention)
    {
        ApplySchema();

        InsertSession(attention: attention);

        Assert.Equal(attention, Scalar("SELECT attention FROM v_sessions"));
    }

    [Fact]
    public void Context_ratio_is_used_over_window()
    {
        ApplySchema();

        InsertSession(usedTokens: "150000", windowTokens: "200000");

        Assert.Equal(0.75, Scalar("SELECT context_ratio FROM v_sessions"));
    }

    [Fact]
    public void Context_ratio_can_exceed_one()
    {
        ApplySchema();

        InsertSession(usedTokens: "300000", windowTokens: "200000");

        Assert.Equal(1.5, Scalar("SELECT context_ratio FROM v_sessions"));
    }

    [Theory]
    [InlineData("NULL", "200000")]
    [InlineData("150000", "NULL")]
    [InlineData("150000", "0")]
    public void Context_ratio_is_null_when_it_cannot_be_computed(string used, string window)
    {
        ApplySchema();

        InsertSession(usedTokens: used, windowTokens: window);

        Assert.Equal(DBNull.Value, Scalar("SELECT context_ratio FROM v_sessions"));
    }

    [Fact]
    public void Events_accept_unknown_event_name()
    {
        ApplySchema();

        Exec("""
            INSERT INTO events(received_at, origin, source, session_id, event)
            VALUES (1, 'local', 'hook', 's1', 'FutureEvent')
            """);

        Assert.Equal(1L, Scalar("SELECT COUNT(*) FROM events"));
    }

    /// <summary>並列のサブエージェントが、別のエージェントの承認待ちを解除しないようにするための列。</summary>
    [Fact]
    public void Sessions_record_which_agent_raised_the_attention()
    {
        ApplySchema();
        InsertSession(attention: "needs_permission");

        Exec("UPDATE sessions SET attention_agent_id = 'agent-1'");

        Assert.Equal("agent-1", Scalar("SELECT attention_agent_id FROM sessions"));
    }

    /// <summary>attention_agent_id は内部の列なので、公開 VIEW には出さない。</summary>
    [Fact]
    public void Attention_agent_id_is_not_part_of_the_public_contract()
    {
        ApplySchema();

        Assert.DoesNotContain("attention_agent_id", ViewColumns("v_sessions"));
    }

    /// <summary>spec §2.1 の許可リストにない列（本文など）が events に増えていないことを確かめる。</summary>
    [Fact]
    public void Events_only_have_allowlisted_columns()
    {
        ApplySchema();

        Assert.Equal(
            [
                "seq", "received_at", "origin", "source", "session_id", "event", "cwd",
                "transcript_path", "tool_name", "notification_type", "model", "disable_1m",
                "session_start_source", "agent_id",
            ],
            ViewColumns("events"));
    }
}
