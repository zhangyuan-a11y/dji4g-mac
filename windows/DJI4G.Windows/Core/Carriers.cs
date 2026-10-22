namespace DJI4G.Windows.Core;

/// MCC/MNC → 运营商 + APN。直接从 Mac 版 `Sources/DJI4GCore/Carrier.swift` 移植，
/// 香港/澳门/台湾与常用国际卡按真机验证阶段再校准 APN 值。
public sealed record Carrier(string MccMnc, string Name, string ShortName, string Apn)
{
    public static readonly Carrier Unknown = new("", "未知运营商", "未知", "");
}

public static class CarrierCatalog
{
    private static readonly Dictionary<string, Carrier> Table = Build();

    private static Dictionary<string, Carrier> Build()
    {
        var map = new Dictionary<string, Carrier>();
        void Add(string[] codes, string name, string shortName, string apn)
        {
            foreach (var code in codes) map[code] = new Carrier(code, name, shortName, apn);
        }

        Add(new[] { "46000", "46002", "46004", "46007", "46008" }, "中国移动", "移动", "CMNET");
        Add(new[] { "46003", "46005", "46011", "46012" }, "中国电信", "电信", "CTNET");
        Add(new[] { "46001", "46006", "46009" }, "中国联通", "联通", "3GNET");
        Add(new[] { "46015", "46020" }, "中国广电", "广电", "CBNET");

        Add(new[] { "45400", "45402", "45410", "45418" }, "CMHK 中国移动香港", "CMHK", "CMNET");
        Add(new[] { "45412", "45413" }, "China Mobile HK", "CMHK", "CMNET");
        Add(new[] { "45403", "45404", "45405" }, "Hutchison HK", "3HK", "3gnet");
        Add(new[] { "45406", "45415", "45416" }, "SmarTone HK", "SMT", "smartone");
        Add(new[] { "45419" }, "CSL HK", "CSL", "csl");

        Add(new[] { "45500", "45501", "45502", "45503", "45504", "45505" }, "CTM 澳门电讯", "CTM", "ctmnet");
        Add(new[] { "46601", "46692", "46693" }, "Chunghwa 中华电信", "CHT", "internet");
        Add(new[] { "46697", "46699" }, "Taiwan Mobile 台湾大哥大", "TWM", "internet");
        Add(new[] { "46688", "46689" }, "FarEasTone 远传", "FET", "internet");

        return map;
    }

    public static Carrier For(string? mccMnc)
    {
        if (string.IsNullOrWhiteSpace(mccMnc)) return Carrier.Unknown;
        var digits = new string(mccMnc.Where(char.IsDigit).ToArray());
        if (Table.TryGetValue(digits, out var exact)) return exact;
        if (digits.Length >= 5 && Table.TryGetValue(digits[..5], out var shortCode)) return shortCode;
        return new Carrier(digits, "运营商 " + digits, digits, "");
    }

    /// 设置页的手动选择按钮，与 Mac 版一致。
    public static IReadOnlyList<Carrier> MainlandChina => new[]
    {
        For("46000"), For("46001"), For("46003"), For("46015"),
    };
}
