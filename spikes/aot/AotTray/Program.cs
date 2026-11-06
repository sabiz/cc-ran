// spike：Task 11 で削除する。プロダクトコードではない。
// 確かめること：Native AOT で TrayIcon と NativeMenu が動くか、アイコンをコードから生成できるか。
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Themes.Fluent;

namespace AotTray;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args) =>
        AppBuilder.Configure<App>().UsePlatformDetect().StartWithClassicDesktopLifetime(args);
}

internal sealed class App : Application
{
    public override void Initialize() => Styles.Add(new FluentTheme());

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;

            var quit = new NativeMenuItem("終了");
            quit.Click += (_, _) => desktop.Shutdown();

            var open = new NativeMenuItem("一覧を開く");
            open.Click += (_, _) => new Window { Title = "cc-ran spike", Width = 320, Height = 200 }.Show();

            var tray = new TrayIcon
            {
                Icon = new WindowIcon(CreateIcon()),
                ToolTipText = "cc-ran spike",
                Menu = new NativeMenu { open, quit },
            };
            TrayIcon.SetIcons(this, new TrayIcons { tray });
        }

        base.OnFrameworkInitializationCompleted();
    }

    /// <summary>実物のトレイは状態の色でアイコンを変えるので、画像ファイルではなくコードから作れるかを確かめる。</summary>
    private static unsafe WriteableBitmap CreateIcon()
    {
        const int size = 32;
        var bitmap = new WriteableBitmap(
            new PixelSize(size, size), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Premul);
        using var buffer = bitmap.Lock();
        var pixels = (uint*)buffer.Address;
        for (var i = 0; i < size * size; i++)
        {
            pixels[i] = 0xFFD9534F;
        }

        return bitmap;
    }
}
