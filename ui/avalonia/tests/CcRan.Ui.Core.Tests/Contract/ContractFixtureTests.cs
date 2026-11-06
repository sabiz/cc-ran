using System.Text.Json;

namespace CcRan.Ui.Core.Tests.Contract;

public class ContractFixtureTests
{
    private const string Sentinel = "CCRAN_SECRET_SENTINEL_";

    private static string HookInputs => Path.Combine(ContractPaths.Fixtures, "hook-inputs");
    private static string SessionFiles => Path.Combine(ContractPaths.Fixtures, "session-files");
    private static string Transcripts => Path.Combine(ContractPaths.Fixtures, "transcripts");

    private static IEnumerable<string> Files(string dir, string pattern) =>
        Directory.EnumerateFiles(dir, pattern);

    private static JsonElement ReadJson(string path)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        return doc.RootElement.Clone();
    }

    private static bool IsValidJson(string text)
    {
        try
        {
            using var doc = JsonDocument.Parse(text);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    [Fact]
    public void All_json_fixtures_parse_except_broken()
    {
        var files = Files(HookInputs, "*.json")
            .Concat(Files(SessionFiles, "*.json"))
            .Where(f => Path.GetFileName(f) != "broken.json")
            .ToList();

        Assert.NotEmpty(files);
        Assert.All(files, f => Assert.True(IsValidJson(File.ReadAllText(f)), f));
    }

    [Fact]
    public void Broken_session_file_is_really_broken()
    {
        Assert.False(IsValidJson(File.ReadAllText(Path.Combine(SessionFiles, "broken.json"))));
    }

    [Fact]
    public void All_jsonl_fixtures_parse_except_broken()
    {
        var files = Files(Transcripts, "*.jsonl")
            .Where(f => Path.GetFileName(f) != "broken-line.jsonl")
            .ToList();

        Assert.NotEmpty(files);
        Assert.All(files, f => Assert.All(File.ReadAllLines(f), line => Assert.True(IsValidJson(line), f)));
    }

    [Fact]
    public void Broken_line_transcript_really_has_a_broken_line()
    {
        var lines = File.ReadAllLines(Path.Combine(Transcripts, "broken-line.jsonl"));

        Assert.Contains(lines, line => !IsValidJson(line));
        Assert.Contains(lines, IsValidJson);
    }

    [Theory]
    [InlineData("SessionStart")]
    [InlineData("SessionEnd")]
    [InlineData("UserPromptSubmit")]
    [InlineData("PreToolUse")]
    [InlineData("PostToolUse")]
    [InlineData("PostToolUseFailure")]
    [InlineData("SubagentStart")]
    [InlineData("SubagentStop")]
    [InlineData("PreCompact")]
    [InlineData("PermissionRequest")]
    [InlineData("Notification")]
    [InlineData("Stop")]
    [InlineData("StopFailure")]
    public void Hook_inputs_cover_subscribed_events(string hookEvent)
    {
        var matching = Files(HookInputs, "*.json")
            .Where(f => ReadJson(f).GetProperty("hook_event_name").GetString() == hookEvent);

        Assert.NotEmpty(matching);
    }

    [Theory]
    [InlineData("permission_prompt")]
    [InlineData("idle_prompt")]
    [InlineData("elicitation_dialog")]
    [InlineData("elicitation_url_dialog")]
    [InlineData("agent_needs_input")]
    [InlineData("agent_completed")]
    [InlineData("auth_success")]
    public void Hook_inputs_cover_notification_types(string notificationType)
    {
        var path = Path.Combine(HookInputs, $"Notification.{notificationType}.json");

        Assert.Equal(notificationType, ReadJson(path).GetProperty("notification_type").GetString());
    }

    [Theory]
    [InlineData("startup")]
    [InlineData("resume")]
    [InlineData("clear")]
    [InlineData("compact")]
    [InlineData("fork")]
    public void Hook_inputs_cover_session_start_sources(string source)
    {
        var path = Path.Combine(HookInputs, $"SessionStart.{source}.json");

        Assert.Equal(source, ReadJson(path).GetProperty("source").GetString());
    }

    [Fact]
    public void Hook_inputs_have_required_fields()
    {
        Assert.All(Files(HookInputs, "*.json"), f =>
        {
            var json = ReadJson(f);
            Assert.False(string.IsNullOrEmpty(json.GetProperty("session_id").GetString()), f);
            Assert.False(string.IsNullOrEmpty(json.GetProperty("hook_event_name").GetString()), f);
            Assert.False(string.IsNullOrEmpty(json.GetProperty("cwd").GetString()), f);
            Assert.False(string.IsNullOrEmpty(json.GetProperty("transcript_path").GetString()), f);
        });
    }

    /// <summary>監視側のプライバシーテストは、本文の項目に入れた目印が DB に残らないことを確かめる。その前提を保証する。</summary>
    [Theory]
    [InlineData("prompt")]
    [InlineData("tool_input")]
    [InlineData("tool_response")]
    [InlineData("last_assistant_message")]
    [InlineData("message")]
    [InlineData("error_details")]
    [InlineData("custom_instructions")]
    [InlineData("session_title")]
    public void Body_fields_carry_a_sentinel_wherever_they_appear(string field)
    {
        var values = Files(HookInputs, "*.json")
            .Select(ReadJson)
            .Where(json => json.TryGetProperty(field, out _))
            .Select(json => json.GetProperty(field).GetRawText())
            .ToList();

        Assert.NotEmpty(values);
        Assert.All(values, value => Assert.Contains(Sentinel, value));
    }

    /// <summary>実際の Hook 入力（2026-11-06 に観測）に合わせる。SessionStart にはまだ prompt_id がない。</summary>
    [Theory]
    [InlineData("startup")]
    [InlineData("resume")]
    [InlineData("clear")]
    [InlineData("compact")]
    [InlineData("fork")]
    public void Session_start_has_no_prompt_id_yet(string source)
    {
        var json = ReadJson(Path.Combine(HookInputs, $"SessionStart.{source}.json"));

        Assert.False(json.TryGetProperty("prompt_id", out _));
    }

    [Fact]
    public void All_hook_inputs_carry_scratchpad_dir()
    {
        Assert.All(Files(HookInputs, "*.json"), f => Assert.True(ReadJson(f).TryGetProperty("scratchpad_dir", out _), f));
    }

    /// <summary>内部エージェントの SubagentStop は Stop の後に届き、SubagentStart も last_assistant_message もない。</summary>
    [Fact]
    public void Internal_subagent_stop_has_no_last_assistant_message()
    {
        var json = ReadJson(Path.Combine(HookInputs, "SubagentStop.internal.json"));

        Assert.False(json.TryGetProperty("last_assistant_message", out _));
        Assert.False(string.IsNullOrEmpty(json.GetProperty("agent_id").GetString()));
    }

    [Theory]
    [InlineData("PreToolUse.subagent")]
    [InlineData("PostToolUse.subagent")]
    [InlineData("PermissionRequest.subagent")]
    public void Subagent_inputs_carry_an_agent_id(string fixture)
    {
        var json = ReadJson(Path.Combine(HookInputs, $"{fixture}.json"));

        Assert.False(string.IsNullOrEmpty(json.GetProperty("agent_id").GetString()));
    }

    [Fact]
    public void Post_tool_use_failure_error_text_carries_a_sentinel()
    {
        var json = ReadJson(Path.Combine(HookInputs, "PostToolUseFailure.json"));

        Assert.Contains(Sentinel, json.GetProperty("error").GetString());
    }

    [Fact]
    public void Transcript_message_content_carries_a_sentinel()
    {
        var text = File.ReadAllText(Path.Combine(Transcripts, "last-assistant.jsonl"));

        Assert.Contains(Sentinel, text);
    }

    [Fact]
    public void Fixtures_never_contain_the_current_user_name()
    {
        var files = Directory.EnumerateFiles(ContractPaths.Fixtures, "*", SearchOption.AllDirectories).ToList();

        Assert.NotEmpty(files);
        Assert.DoesNotContain(
            files,
            f => File.ReadAllText(f).Contains(Environment.UserName, StringComparison.OrdinalIgnoreCase));
    }

    [Theory]
    [InlineData("claude-fable-5-1", 1_000_000)]
    [InlineData("claude-fable-5", 1_000_000)]
    [InlineData("claude-mythos-5-1", 1_000_000)]
    [InlineData("claude-mythos-5", 1_000_000)]
    [InlineData("claude-opus-5-5", 1_000_000)]
    [InlineData("claude-opus-5", 1_000_000)]
    [InlineData("claude-opus-4-8", 1_000_000)]
    [InlineData("claude-opus-4-7", 1_000_000)]
    [InlineData("claude-sonnet-5-5", 1_000_000)]
    [InlineData("claude-sonnet-5", 1_000_000)]
    [InlineData("claude-haiku-5-5", 1_000_000)]
    [InlineData("claude-opus-4-6", 200_000)]
    [InlineData("claude-sonnet-4-6", 200_000)]
    [InlineData("claude-haiku-4-5", 200_000)]
    [InlineData("claude-opus-4-5", 200_000)]
    [InlineData("claude-sonnet-4-5", 200_000)]
    [InlineData("claude-opus-4-1", 200_000)]
    [InlineData("claude-sonnet-4", 200_000)]
    [InlineData("claude-opus-4", 200_000)]
    public void Models_json_has_all_spec_models(string id, int window)
    {
        var models = ReadJson(ContractPaths.ModelsJson).GetProperty("models").EnumerateArray();

        var model = Assert.Single(models, m => m.GetProperty("id").GetString() == id);
        Assert.Equal(window, model.GetProperty("window").GetInt32());
    }

    [Fact]
    public void Models_json_records_its_provenance_and_defaults()
    {
        var json = ReadJson(ContractPaths.ModelsJson);

        Assert.Equal(200_000, json.GetProperty("default_window").GetInt32());
        Assert.Equal(1_000_000, json.GetProperty("one_million").GetInt32());
        Assert.False(string.IsNullOrEmpty(json.GetProperty("verified_at").GetString()));
        Assert.NotEmpty(json.GetProperty("sources").EnumerateArray());
    }

    [Fact]
    public void Fixtures_use_lf_only()
    {
        var files = Directory.EnumerateFiles(ContractPaths.Contracts, "*", SearchOption.AllDirectories).ToList();

        Assert.NotEmpty(files);
        Assert.All(files, f => Assert.DoesNotContain((byte)'\r', File.ReadAllBytes(f)));
    }
}
