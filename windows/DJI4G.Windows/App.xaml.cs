using System.Windows;
using System.Windows.Forms;

namespace DJI4G.Windows;

/// 单实例托盘程序：关闭主窗只隐藏到托盘，托盘菜单退出才真正结束。
public partial class App : System.Windows.Application
{
    private static Mutex? _single;
    private NotifyIcon? _tray;
    private MainWindow? _main;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _single = new Mutex(true, @"Local\DJI4G.SingleInstance", out bool isNew);
        if (!isNew)
        {
            Shutdown();
            return;
        }

        _tray = new NotifyIcon
        {
            Text = "DJI 4G",
            Visible = true,
            // M4 补图标：Icon = System.Drawing.Icon.ExtractAssociatedIcon(...)
        };
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开面板", null, (_, _) => ShowMain());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => ExitApp());
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => ShowMain();

        ShowMain();
    }

    private void ShowMain()
    {
        _main ??= new MainWindow();
        if (!_main.IsVisible) _main.Show();
        _main.WindowState = WindowState.Normal;
        _main.Activate();
        _main.Topmost = true;
        _main.Topmost = false;
    }

    private void ExitApp()
    {
        _tray?.Dispose();
        Shutdown();
    }
}
