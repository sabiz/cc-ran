namespace CcRan.Ui.Core.Tests.Contract;

/// <summary>リポジトリ直下の contracts/ を、テストの実行場所によらず見つける。</summary>
internal static class ContractPaths
{
    public static string Root { get; } = FindRepoRoot();

    public static string Contracts => Path.Combine(Root, "contracts");
    public static string InitSql => Path.Combine(Contracts, "schema", "001_init.sql");
    public static string ColumnsJson => Path.Combine(Contracts, "schema", "columns.json");
    public static string ModelsJson => Path.Combine(Contracts, "models.json");
    public static string Fixtures => Path.Combine(Contracts, "fixtures");

    private static string FindRepoRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            // .git はワークツリーではファイルになるので、種類を問わず存在だけを見る
            var git = Path.Combine(dir.FullName, ".git");
            if (Directory.Exists(git) || File.Exists(git))
            {
                return dir.FullName;
            }
        }

        throw new DirectoryNotFoundException("リポジトリのルートが見つかりません。");
    }
}
