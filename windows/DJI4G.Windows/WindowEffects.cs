using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace DJI4G.Windows;

/// Win11 原生毛玻璃底色（Mica）。Win10 / 旧版本自动退化为普通纯色，不做自定义标题栏。
internal static class WindowEffects
{
    private const int DWMWA_SYSTEMBACKDROP_TYPE = 38; // Win11 22H2+
    private const int DWMWA_MICA_EFFECT = 1029;       // Win11 21H2

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    public static void Apply(Window window)
    {
        var source = PresentationSource.FromVisual(window) as HwndSource;
        if (source is null) return;

        // 先试 Win11 22H2 的系统背景类型（Mica=2），失败再回退到旧版 MICA 开关。
        var backdrop = 2;
        if (DwmSetWindowAttribute(source.Handle, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int)) == 0)
            return;

        var mica = 1;
        _ = DwmSetWindowAttribute(source.Handle, DWMWA_MICA_EFFECT, ref mica, sizeof(int));
    }
}
