using ImageCompressor.Infrastructure;

namespace ImageCompressor.App;

internal sealed class ScanConditions
{
    private ScanConditions(string[] inputs, bool recurse, string?[] exclusions)
    {
        Inputs = inputs;
        Recurse = recurse;
        Exclusions = exclusions;
    }

    public IReadOnlyList<string> Inputs { get; }
    private bool Recurse { get; }
    private string?[] Exclusions { get; }

    public static ScanConditions Create(IEnumerable<string> inputs, string output, bool recurse)
    {
        var paths = inputs.Select(path => Path.TrimEndingDirectorySeparator(Path.GetFullPath(path)))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        var outputRoot = Path.GetFullPath(output);
        var exclusions = paths.Select(path => recurse && Directory.Exists(path)
            ? FileScanner.GetExcludedOutputRoot(path, outputRoot) : null).ToArray();
        return new(paths, recurse, exclusions);
    }

    public bool Matches(ScanConditions other) => Recurse == other.Recurse &&
        Inputs.SequenceEqual(other.Inputs, StringComparer.OrdinalIgnoreCase) &&
        Exclusions.SequenceEqual(other.Exclusions, StringComparer.OrdinalIgnoreCase);
}

internal sealed class ScanState
{
    private enum Status { Unscanned, Current, Stale, Failed }

    private ScanConditions? lastScan;
    private Status status;

    public bool IsUnscanned => status == Status.Unscanned;
    public bool CanStart => status is Status.Unscanned or Status.Current;
    public bool RequiresRefresh => !CanStart;

    public bool MatchesLastScan(ScanConditions conditions) => lastScan?.Matches(conditions) == true;

    public void Recheck(ScanConditions? conditions)
    {
        if (status == Status.Current && (conditions is null || !MatchesLastScan(conditions)))
        {
            status = Status.Stale;
        }
    }

    public void Succeeded(ScanConditions conditions)
    {
        lastScan = conditions;
        status = Status.Current;
    }

    public void Failed() => status = Status.Failed;
}

internal sealed class JobState
{
    private long generation;

    public bool IsRunning { get; private set; }
    public bool CloseRequested { get; private set; }

    public long Begin()
    {
        IsRunning = true;
        return ++generation;
    }

    public bool RequestClose()
    {
        if (!IsRunning || CloseRequested)
        {
            return false;
        }

        CloseRequested = true;
        return true;
    }

    public bool AcceptsProgress(long id) => IsRunning && !CloseRequested && generation == id;

    public bool Finish()
    {
        IsRunning = false;
        var close = CloseRequested;
        CloseRequested = false;
        return close;
    }
}
