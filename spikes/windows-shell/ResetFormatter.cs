using System.Globalization;

namespace OpenUsageShell;

/// <summary>
/// Compact reset countdown labels matching macOS OpenUsage ("Resets in 1h 46m", "Resets in 6d 4h").
/// </summary>
internal static class ResetFormatter
{
    private const int ImminentSeconds = 5 * 60;

    public static string? FormatResetRelative(double? resetsAtUnix)
    {
        if (resetsAtUnix is not double unix)
        {
            return null;
        }

        var resetsAt = DateTimeOffset.FromUnixTimeSeconds((long)Math.Floor(unix));
        var seconds = (resetsAt - DateTimeOffset.UtcNow).TotalSeconds;
        if (seconds <= ImminentSeconds)
        {
            return "Resets soon";
        }

        var duration = CompactDuration(seconds);
        return duration is null ? null : $"Resets in {duration}";
    }

    /// <summary>Xd Yh / Xh Ym / Xm — mirrors <c>Formatters.compactDuration</c> in windows-core.</summary>
    private static string? CompactDuration(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds <= 0)
        {
            return null;
        }

        var totalMinutes = Math.Max(1, (int)Math.Ceiling(seconds / 60.0));
        var days = totalMinutes / (24 * 60);
        var hours = (totalMinutes % (24 * 60)) / 60;
        var minutes = totalMinutes % 60;

        if (days > 0)
        {
            return $"{days.ToString(CultureInfo.InvariantCulture)}d {hours.ToString(CultureInfo.InvariantCulture)}h";
        }

        if (hours > 0)
        {
            return minutes > 0
                ? $"{hours.ToString(CultureInfo.InvariantCulture)}h {minutes.ToString(CultureInfo.InvariantCulture)}m"
                : $"{hours.ToString(CultureInfo.InvariantCulture)}h";
        }

        return $"{minutes.ToString(CultureInfo.InvariantCulture)}m";
    }
}
