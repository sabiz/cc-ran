// spike：Task 11 で削除する。プロダクトコードではない。
// 確かめること：Native AOT で Microsoft.Data.Sqlite が読み取り専用で動くか、
// data_version で他の接続の書き込みを検知できるか、存在しない DB を開いたときの例外。
using Microsoft.Data.Sqlite;

var dir = args[0];
var sql = File.ReadAllText(args[1]);
Directory.CreateDirectory(dir);
var dbPath = Path.Combine(dir, "probe.db");
foreach (var suffix in new[] { "", "-wal", "-shm" })
{
    File.Delete(dbPath + suffix);
}

using (var writer = new SqliteConnection($"Data Source={dbPath};Mode=ReadWriteCreate;Pooling=False"))
{
    writer.Open();
    Exec(writer, "PRAGMA journal_mode=WAL");
    Exec(writer, sql);
    writer.Close();
}

Console.WriteLine($"files after writer closed: {string.Join(",", Directory.GetFiles(dir).Select(Path.GetFileName))}");

using var reader = new SqliteConnection($"Data Source={dbPath};Mode=ReadOnly;Pooling=False");
reader.Open();
Console.WriteLine($"sqlite_version={Scalar(reader, "SELECT sqlite_version()")}");
Console.WriteLine($"v_monitor contract_version={Scalar(reader, "SELECT contract_version FROM v_monitor")} daemon_alive={Scalar(reader, "SELECT daemon_alive FROM v_monitor")}");

var before = Scalar(reader, "PRAGMA data_version");
Console.WriteLine($"data_version before={before}");

using (var writer = new SqliteConnection($"Data Source={dbPath};Mode=ReadWrite;Pooling=False"))
{
    writer.Open();
    Exec(writer, "UPDATE monitor_state SET hooks_seen = 1");
}

var after = Scalar(reader, "PRAGMA data_version");
Console.WriteLine($"data_version after={after} changed={!Equals(before, after)}");
Console.WriteLine($"hooks_seen={Scalar(reader, "SELECT hooks_seen FROM v_monitor")}");

try
{
    Exec(reader, "UPDATE monitor_state SET hooks_seen = 0");
    Console.WriteLine("write on read-only connection: UNEXPECTEDLY SUCCEEDED");
}
catch (SqliteException e)
{
    Console.WriteLine($"write on read-only connection: SqliteException code={e.SqliteErrorCode}");
}

var missing = Path.Combine(dir, "missing.db");
try
{
    using var none = new SqliteConnection($"Data Source={missing};Mode=ReadOnly;Pooling=False");
    none.Open();
    Console.WriteLine("open missing db: UNEXPECTEDLY SUCCEEDED");
}
catch (Exception e)
{
    var code = e is SqliteException s ? s.SqliteErrorCode : -1;
    Console.WriteLine($"open missing db: {e.GetType().FullName} code={code} created={File.Exists(missing)}");
}

Console.WriteLine("PROBE OK");
return 0;

static void Exec(SqliteConnection connection, string sql)
{
    using var command = connection.CreateCommand();
    command.CommandText = sql;
    command.ExecuteNonQuery();
}

static object? Scalar(SqliteConnection connection, string sql)
{
    using var command = connection.CreateCommand();
    command.CommandText = sql;
    return command.ExecuteScalar();
}
