using Avalonia;
using Avalonia.Headless;
using CcRan.Ui.Tests;

[assembly: AvaloniaTestApplication(typeof(TestAppBuilder))]

namespace CcRan.Ui.Tests;

public class TestAppBuilder
{
    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>().UseHeadless(new AvaloniaHeadlessPlatformOptions());
}
