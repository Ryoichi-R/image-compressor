namespace ImageCompressor.Domain;

public sealed record ScreenBounds(int X, int Y, int Width, int Height);

public static class WindowPlacement
{
    public static bool IsVisible(
        ScreenBounds candidate,
        IEnumerable<ScreenBounds> workingAreas,
        int minimumVisiblePixels = 64)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        ArgumentNullException.ThrowIfNull(workingAreas);
        return workingAreas.Any(area =>
        {
            var left = Math.Max(candidate.X, area.X);
            var top = Math.Max(candidate.Y, area.Y);
            var right = Math.Min(candidate.X + candidate.Width, area.X + area.Width);
            var bottom = Math.Min(candidate.Y + candidate.Height, area.Y + area.Height);
            return right - left >= minimumVisiblePixels &&
                bottom - top >= minimumVisiblePixels;
        });
    }
}
