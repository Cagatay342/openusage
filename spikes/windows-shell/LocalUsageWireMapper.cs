using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace OpenUsageShell;

/// <summary>Maps sidecar provider snapshots into the macOS local API JSON shape for /v1/usage.</summary>
internal static class LocalUsageWireMapper
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private static readonly Regex PercentRegex = new(@"(\d+(?:\.\d+)?)\s*%", RegexOptions.Compiled);
    private static readonly Regex SlashRegex = new(@"([^/]+)/([^/]+)$", RegexOptions.Compiled);

    public static byte[] ToUsageJson(IReadOnlyList<SidecarProvider> providers)
    {
        var snapshots = providers
            .Where(p => p.Status == "ok" && p.MetricLines.Count > 0)
            .Select(ToSnapshot)
            .ToList();
        return JsonSerializer.SerializeToUtf8Bytes(snapshots, JsonOptions);
    }

    public static byte[] ToProviderJson(SidecarProvider provider)
    {
        return JsonSerializer.SerializeToUtf8Bytes(ToSnapshot(provider), JsonOptions);
    }

    private static object ToSnapshot(SidecarProvider provider)
    {
        return new
        {
            providerId = provider.Id,
            displayName = provider.DisplayName,
            plan = provider.Plan,
            lines = provider.MetricLines.Select(MapLine).Where(l => l is not null).ToList(),
            fetchedAt = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture)
        };
    }

    private static object? MapLine(SidecarMetricLine line)
    {
        return line.Kind.ToLowerInvariant() switch
        {
            "progress" => MapProgress(line),
            "badge" => new
            {
                type = "badge",
                label = line.Label,
                text = StripLabelPrefix(line),
                color = (string?)null,
                subtitle = (string?)null
            },
            _ => new
            {
                type = "text",
                label = line.Label,
                value = StripLabelPrefix(line),
                color = (string?)null,
                subtitle = (string?)null
            }
        };
    }

    private static object? MapProgress(SidecarMetricLine line)
    {
        var display = line.Display;
        var percent = PercentRegex.Match(display);
        if (percent.Success
            && double.TryParse(percent.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var usedPct))
        {
            return new
            {
                type = "progress",
                label = line.Label,
                used = usedPct,
                limit = 100.0,
                format = new { kind = "percent" },
                resetsAt = ResetsAtIso(line.ResetsAt),
                periodDurationMs = (long?)null,
                color = (string?)null
            };
        }

        var value = StripLabelPrefix(line);
        var slash = SlashRegex.Match(value);
        if (!slash.Success)
        {
            return null;
        }

        var usedText = slash.Groups[1].Value.Trim();
        var limitText = slash.Groups[2].Value.Trim();
        if (usedText.Contains('$', StringComparison.Ordinal) || limitText.Contains('$', StringComparison.Ordinal))
        {
            if (!TryParseMoney(usedText, out var used) || !TryParseMoney(limitText, out var limit))
            {
                return null;
            }

            return new
            {
                type = "progress",
                label = line.Label,
                used,
                limit,
                format = new { kind = "dollars" },
                resetsAt = ResetsAtIso(line.ResetsAt),
                periodDurationMs = (long?)null,
                color = (string?)null
            };
        }

        if (!double.TryParse(usedText, NumberStyles.Float, CultureInfo.InvariantCulture, out var usedCount)
            || !double.TryParse(limitText, NumberStyles.Float, CultureInfo.InvariantCulture, out var limitCount))
        {
            return null;
        }

        return new
        {
            type = "progress",
            label = line.Label,
            used = usedCount,
            limit = limitCount,
            format = new { kind = "count", suffix = "" },
            resetsAt = ResetsAtIso(line.ResetsAt),
            periodDurationMs = (long?)null,
            color = (string?)null
        };
    }

    private static string StripLabelPrefix(SidecarMetricLine line)
    {
        var value = line.Display;
        var prefix = line.Label + ": ";
        if (value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return value[prefix.Length..].Trim();
        }

        return value.Trim();
    }

    private static string? ResetsAtIso(double? resetsAt)
    {
        if (resetsAt is not double seconds)
        {
            return null;
        }

        return DateTimeOffset.FromUnixTimeSeconds((long)seconds).UtcDateTime.ToString("o", CultureInfo.InvariantCulture);
    }

    private static bool TryParseMoney(string text, out double value)
    {
        var cleaned = text.Trim().TrimStart('$').Replace(",", "");
        return double.TryParse(cleaned, NumberStyles.Float, CultureInfo.InvariantCulture, out value);
    }
}
