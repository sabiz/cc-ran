using Avalonia.Controls;
using Avalonia.Headless.XUnit;

namespace CcRan.Ui.Tests;

public class SmokeTests
{
    [AvaloniaFact]
    public void Headless_platform_opens_a_window()
    {
        var window = new Window();
        window.Show();
        Assert.True(window.IsVisible);
    }
}
