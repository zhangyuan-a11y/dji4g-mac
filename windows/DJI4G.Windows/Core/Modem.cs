namespace DJI4G.Windows.Core;

public sealed record ModemStatus(bool Registered, string Summary, string Carrier);

/// 模块会话骨架。M0：检测 + 读信号/注册状态；M1 起接入短信、电话、通话记录。
public sealed class Modem
{
    public async Task<ModemStatus> ReadStatusAsync()
    {
        return await Task.Run(() =>
        {
            using var channel = AtChannel.Open();

            var csq = channel.Command("AT+CSQ");
            var creg = channel.Command("AT+CEREG?");
            var cops = channel.Command("AT+COPS?");

            var registered = creg.Contains(",1") || creg.Contains(",5");
            var signal = ParseCsq(csq);
            var carrier = ParseCops(cops);
            var summary = registered ? $"已注册 · 信号 {signal}" : "未注册";

            return new ModemStatus(registered, summary, carrier);
        });
    }

    private static string ParseCsq(string csq)
    {
        // +CSQ: <rssi>,<ber>
        var i = csq.IndexOf("+CSQ:", StringComparison.Ordinal);
        if (i < 0) return "—";
        var body = csq[(i + 5)..].Trim();
        var rssiText = body.Split(',')[0].Trim();
        if (!int.TryParse(rssiText, out var rssi) || rssi == 99) return "—";
        var dbm = -113 + rssi * 2;
        return $"{dbm} dBm";
    }

    private static string ParseCops(string cops)
    {
        // +COPS: 0,0,"CHN-CT",7
        var i = cops.IndexOf("+COPS:", StringComparison.Ordinal);
        if (i < 0) return CarrierCatalog.Unknown.Name;
        var body = cops[(i + 6)..].Trim();
        var parts = body.Split(',');
        var name = parts.Length > 2 ? parts[2].Trim('"') : "";
        return string.IsNullOrEmpty(name) ? CarrierCatalog.Unknown.Name : name;
    }
}
