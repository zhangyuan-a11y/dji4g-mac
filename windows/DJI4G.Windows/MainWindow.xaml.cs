using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using DJI4G.Windows.Core;

namespace DJI4G.Windows;

/// 主面板骨架。M0 阶段先跑通「检测模块 → 读状态」，短信/电话/联网随后接上。
public partial class MainWindow : Window
{
    private readonly Modem _modem = new();

    public MainWindow()
    {
        InitializeComponent();
        WindowEffects.Apply(this);
        _ = RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        try
        {
            var info = await _modem.ReadStatusAsync();
            StatusDot.Fill = info.Registered
                ? (Brush)FindResource("SuccessBrush")
                : (Brush)FindResource("WarningBrush");
            StatusText.Text = info.Summary;
            CarrierText.Text = info.Carrier;
        }
        catch
        {
            StatusDot.Fill = Brushes.Gray;
            StatusText.Text = "未检测到模块";
            CarrierText.Text = "请确认模块已连接、驱动已安装";
        }
    }

    private async void RefreshButton_Click(object sender, RoutedEventArgs e) => await RefreshAsync();

    private void SmsButton_Click(object sender, RoutedEventArgs e) => MessageList.Items.Add("短信窗口（M1 接入）");

    private void CallButton_Click(object sender, RoutedEventArgs e) => MessageList.Items.Add("电话窗口（M1 接入）");

    private void NetButton_Click(object sender, RoutedEventArgs e) => MessageList.Items.Add("联网开关（M2 接入）");

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        // 关窗 = 缩回托盘，不退出程序（与 Windows 托盘应用习惯一致）。
        e.Cancel = true;
        Hide();
    }
}
