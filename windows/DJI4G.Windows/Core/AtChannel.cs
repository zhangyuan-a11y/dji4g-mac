using System.IO.Ports;

namespace DJI4G.Windows.Core;

/// 走模块枚举出的 COM 口（Quectel 驱动装好后是 "Quectel USB AT Port"）。
/// M0 阶段只做「找到能回 AT 的口 + 收发一行命令」。
public sealed class AtChannel : IDisposable
{
    private readonly SerialPort _port;

    private AtChannel(string portName)
    {
        _port = new SerialPort(portName, 115200, Parity.None, 8, StopBits.One)
        {
            ReadTimeout = 1500,
            WriteTimeout = 1500,
            NewLine = "\r\n",
        };
    }

    public static AtChannel Open()
    {
        foreach (var name in SerialPort.GetPortNames())
        {
            try
            {
                var channel = new AtChannel(name);
                channel._port.Open();
                if (channel.Command("AT").Trim().Contains("OK"))
                    return channel;
                channel.Dispose();
            }
            catch
            {
                // 不是 AT 口，继续试下一个。
            }
        }
        throw new InvalidOperationException("未找到模块的 AT 口。请确认模块已连接且驱动已安装。");
    }

    public string Command(string at)
    {
        _port.DiscardInBuffer();
        _port.WriteLine(at);
        var parts = new List<string>();
        var deadline = DateTime.UtcNow.AddMilliseconds(_port.ReadTimeout * 2);
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                var line = _port.ReadLine().TrimEnd('\r', '\n').Trim();
                if (line.Length == 0) continue;
                parts.Add(line);
                if (line is "OK" or "ERROR" or "+CME ERROR" || line.StartsWith("+CME ERROR"))
                    break;
            }
            catch (TimeoutException)
            {
                break;
            }
        }
        return string.Join("\n", parts);
    }

    public void Dispose() => _port.Dispose();
}
