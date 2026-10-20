using System.Diagnostics;

namespace ImageCompressor.App;

public static class CancelRequestHandler
{
    public static TimeSpan Request(
        CancellationTokenSource? cancellation,
        Action updateUi)
    {
        ArgumentNullException.ThrowIfNull(updateUi);
        var stopwatch = Stopwatch.StartNew();
        cancellation?.Cancel();
        updateUi();
        stopwatch.Stop();
        return stopwatch.Elapsed;
    }
}
