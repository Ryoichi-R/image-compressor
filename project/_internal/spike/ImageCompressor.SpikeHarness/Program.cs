using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using ImageCompressor.App;
using ImageCompressor.Domain;
using ImageCompressor.Infrastructure;

var options = Arguments.Parse(args);
var sources = FileScanner.Scan(options.Input, options.Output, includeSubfolders: true);
if (sources.Count == 0)
{
    throw new InvalidOperationException("fixtureに画像がありません。");
}

var process = Process.GetCurrentProcess();
using var minimumPrepared = SystemDrawingImageEngine.Prepare(sources[0].FullPath);
var minimumCandidates = Enumerable.Range(1, 100)
    .Select(quality => SystemDrawingImageEngine.Encode(
        minimumPrepared,
        1,
        1,
        quality,
        OutputFormat.Jpeg,
        jpegBackgroundBlack: false))
    .ToArray();
var minimumObserved = minimumCandidates.MinBy(candidate => candidate.Bytes.Length)!;
var warmupRequest = CreateRequest(
    options,
    Path.Combine(options.Output, "warmup"));
_ = new CompressionService().Process(
    OutputPlanner.Create(sources.Take(10), warmupRequest),
    warmupRequest);
GC.Collect();
GC.WaitForPendingFinalizers();
GC.Collect();
var runs = new List<RunMeasurement>();
var allAttempts = new List<int>();
for (var run = 1; run <= options.Runs; run++)
{
    var output = Path.Combine(options.Output, $"run-{run:00}");
    var request = CreateRequest(options, output);
    var plans = OutputPlanner.Create(sources, request);
    process.Refresh();
    var privateBefore = process.PrivateMemorySize64;
    var handlesBefore = process.HandleCount;
    var gdiBefore = NativeMethods.GetGuiResources(process.Handle, 0);
    var privateByteSamples = new List<long>();
    var sampleProgress = new InlineProgress<CompressionProgress>(progress =>
    {
        if (progress.Completed % 100 == 0)
        {
            process.Refresh();
            privateByteSamples.Add(process.PrivateMemorySize64);
        }
    });
    var stopwatch = Stopwatch.StartNew();
    var results = new CompressionService().Process(plans, request, progress: sampleProgress);
    stopwatch.Stop();
    process.Refresh();
    var privateAfter = process.PrivateMemorySize64;
    GC.Collect();
    GC.WaitForPendingFinalizers();
    GC.Collect();
    process.Refresh();
    var privateAfterGc = process.PrivateMemorySize64;
    var privateAfterGcLimit = privateByteSamples[0] +
        Math.Max(128L * 1024 * 1024, (long)Math.Ceiling(privateByteSamples[0] * 0.2));
    allAttempts.AddRange(results.Select(result => result.EncodeAttempts));
    runs.Add(new(
        run,
        stopwatch.Elapsed.TotalMilliseconds,
        privateBefore,
        privateAfter,
        privateAfterGc,
        handlesBefore,
        process.HandleCount,
        gdiBefore,
        NativeMethods.GetGuiResources(process.Handle, 0),
        results.Count(result => result.Status is ResultStatus.Success or ResultStatus.Copied),
        results.Count(result => result.Status == ResultStatus.Failed),
        privateByteSamples,
        HasFourConsecutiveLargeIncreases(privateByteSamples),
        privateAfterGcLimit,
        privateAfterGc <= privateAfterGcLimit));
}

var cancelP95Milliseconds = MeasureCancelUiP95();
var cancelToCancelledMilliseconds = MeasureCancelTransition(options, sources);
var ordered = runs.Select(run => run.ElapsedMilliseconds).Order().ToArray();
var report = new
{
    schemaVersion = 1,
    engine = options.Mode == "target" ? "csharp-system-drawing-target-size" : "csharp-system-drawing",
    measuredAt = DateTimeOffset.Now,
    host = new
    {
        machine = $"host-{Convert.ToHexString(SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(Environment.MachineName)))[..12]}",
        os = Environment.OSVersion.VersionString,
        framework = RuntimeInformation.FrameworkDescription,
        architecture = RuntimeInformation.ProcessArchitecture.ToString(),
        processorCount = Environment.ProcessorCount,
    },
    fixture = new
    {
        root = Path.GetFileName(Path.TrimEndingDirectorySeparator(options.Input)),
        count = sources.Count,
        sha256 = FixtureHash(options.Input),
    },
    settings = new
    {
        mode = options.Mode,
        targetBytes = options.TargetBytes,
        maxWidth = 1920,
        maxHeight = 1080,
        quality = 75,
    },
    runs,
    medianMilliseconds = Median(ordered),
    privateCheckpointGrowthGatePassed = runs.All(run => !run.PrivateCheckpointGrowthFailed),
    privateAfterGcGatePassed = runs.All(run => run.PrivateAfterGcPassed),
    maximumPrivateBytesDelta = runs.Max(run => run.PrivateBytesAfterGc - run.PrivateBytesBefore),
    maximumHandleDelta = runs.Max(run => run.HandlesAfter - run.HandlesBefore),
    maximumGdiHandleDelta = runs.Max(run => run.GdiHandlesAfter - run.GdiHandlesBefore),
    handleGatePassed = runs.Max(run => run.HandlesAfter - run.HandlesBefore) <= 10,
    resourceGatePassed =
        runs.All(run => !run.PrivateCheckpointGrowthFailed && run.PrivateAfterGcPassed) &&
        runs.Max(run => run.HandlesAfter - run.HandlesBefore) <= 10 &&
        runs.Max(run => run.GdiHandlesAfter - run.GdiHandlesBefore) <= 10,
    maximumEncodeAttempts = allAttempts.Count == 0 ? 0 : allAttempts.Max(),
    averageEncodeAttempts = allAttempts.Count == 0 ? 0 : allAttempts.Average(),
    engineContract = new
    {
        observedMinimumJpegBytes = minimumObserved.Bytes.Length,
        observedMinimumJpegQuality = minimumObserved.Quality,
        acceptedMinTargetBytes = CompressionRequest.MinimumTargetBytes,
        minimumQuality = CompressionRequest.MinimumQuality,
        maximumAttempts = CompressionRequest.MaximumEncodeAttempts,
        localSweepCount = CompressionRequest.LocalSweepCount,
        minimumDimension = 1,
        dimensionScale = 0.85,
    },
    cancelP95Milliseconds,
    cancelToCancelledMilliseconds,
    cancelTransitionWithinTwoSeconds = cancelToCancelledMilliseconds <= 2000,
};
var json = JsonSerializer.Serialize(
    report,
    new JsonSerializerOptions
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    });
Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(options.Report))!);
File.WriteAllText(options.Report, json);
Console.WriteLine(json);

static double Median(double[] values) =>
    values.Length % 2 == 1
        ? values[values.Length / 2]
        : (values[(values.Length / 2) - 1] + values[values.Length / 2]) / 2d;

static CompressionRequest CreateRequest(Arguments options, string output) =>
    new()
    {
        InputRoot = options.Input,
        OutputRoot = output,
        MaxWidth = 1920,
        MaxHeight = 1080,
        Quality = 75,
        OutputFormat = OutputFormat.Jpeg,
        TargetSizeEnabled = options.Mode == "target",
        TargetBytes = options.TargetBytes,
        LargerOutputPolicy = LargerOutputPolicy.Save,
        CollisionPolicy = CollisionPolicy.AutoRename,
        IncludeSubfolders = true,
        PreserveHierarchy = true,
    };

static bool HasFourConsecutiveLargeIncreases(IReadOnlyList<long> values)
{
    const long threshold = 5L * 1024 * 1024;
    var consecutive = 0;
    for (var index = 1; index < values.Count; index++)
    {
        consecutive = values[index] - values[index - 1] > threshold
            ? consecutive + 1
            : 0;
        if (consecutive >= 4)
        {
            return true;
        }
    }

    return false;
}

static double MeasureCancelUiP95()
{
    double result = 0;
    Exception? failure = null;
    var thread = new Thread(() =>
    {
        try
        {
            using var label = new System.Windows.Forms.Label();
            label.CreateControl();
            var samples = Enumerable.Range(0, 1000)
                .Select(index =>
                {
                    using var cancellation = new CancellationTokenSource();
                    return CancelRequestHandler.Request(
                        cancellation,
                        () => label.Text = $"キャンセル要求済み {index}")
                        .TotalMilliseconds;
                })
                .Order()
                .ToArray();
            result = samples[(int)Math.Ceiling(samples.Length * 0.95) - 1];
        }
        catch (Exception exception)
        {
            failure = exception;
        }
    });
    thread.SetApartmentState(ApartmentState.STA);
    thread.Start();
    thread.Join();
    if (failure is not null)
    {
        throw new InvalidOperationException("Cancel UI p95測定に失敗しました。", failure);
    }

    return result;
}

static double MeasureCancelTransition(
    Arguments options,
    IReadOnlyList<SourceItem> sources)
{
    using var cancellation = new CancellationTokenSource();
    using var firstCompleted = new ManualResetEventSlim();
    using var continueAfterCancel = new ManualResetEventSlim();
    var request = CreateRequest(options, Path.Combine(options.Output, "cancel-probe"));
    var plans = OutputPlanner.Create(sources, request);
    var progress = new InlineProgress<CompressionProgress>(value =>
    {
        if (value.Completed == 1)
        {
            firstCompleted.Set();
            continueAfterCancel.Wait();
        }
    });
    var task = Task.Run(() =>
        new CompressionService().Process(
            plans,
            request,
            progress: progress,
            cancellationToken: cancellation.Token));
    if (!firstCompleted.Wait(TimeSpan.FromSeconds(10)))
    {
        throw new TimeoutException("Cancel probeの最初のencodeが完了しませんでした。");
    }

    var stopwatch = Stopwatch.StartNew();
    cancellation.Cancel();
    continueAfterCancel.Set();
    if (!task.Wait(TimeSpan.FromSeconds(2)))
    {
        throw new TimeoutException("native encode復帰後2秒以内にCancelledへ遷移しませんでした。");
    }

    stopwatch.Stop();
    if (!task.Result.Any(result => result.Status == ResultStatus.Cancelled))
    {
        throw new InvalidOperationException("Cancel probeにCancelled resultがありません。");
    }

    return stopwatch.Elapsed.TotalMilliseconds;
}

static string FixtureHash(string root)
{
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
        .Order(StringComparer.OrdinalIgnoreCase))
    {
        var relative = Path.GetRelativePath(root, file).Replace('\\', '/');
        hash.AppendData(System.Text.Encoding.UTF8.GetBytes(relative));
        hash.AppendData(File.ReadAllBytes(file));
    }

    return Convert.ToHexString(hash.GetHashAndReset());
}

internal sealed record RunMeasurement(
    int Run,
    double ElapsedMilliseconds,
    long PrivateBytesBefore,
    long PrivateBytesAfter,
    long PrivateBytesAfterGc,
    int HandlesBefore,
    int HandlesAfter,
    int GdiHandlesBefore,
    int GdiHandlesAfter,
    int Succeeded,
    int Failed,
    IReadOnlyList<long> PrivateByteSamples,
    bool PrivateCheckpointGrowthFailed,
    long PrivateAfterGcLimit,
    bool PrivateAfterGcPassed);

internal sealed class InlineProgress<T>(Action<T> report) : IProgress<T>
{
    public void Report(T value) => report(value);
}

internal sealed record Arguments(
    string Mode,
    string Input,
    string Output,
    string Report,
    int Runs,
    long TargetBytes)
{
    public static Arguments Parse(string[] args)
    {
        string Value(string name, string? fallback = null)
        {
            var index = Array.IndexOf(args, name);
            if (index >= 0 && index + 1 < args.Length)
            {
                return args[index + 1];
            }

            return fallback ?? throw new ArgumentException($"{name}が必要です。");
        }

        var mode = Value("--mode", "conventional");
        if (mode is not ("conventional" or "target"))
        {
            throw new ArgumentException("--modeはconventionalまたはtargetです。");
        }

        return new(
            mode,
            Path.GetFullPath(Value("--input")),
            Path.GetFullPath(Value("--output")),
            Path.GetFullPath(Value("--report")),
            int.Parse(Value("--runs", "3"), System.Globalization.CultureInfo.InvariantCulture),
            long.Parse(Value("--target-bytes", "10240"), System.Globalization.CultureInfo.InvariantCulture));
    }
}

internal static partial class NativeMethods
{
    [LibraryImport("user32.dll")]
    internal static partial int GetGuiResources(IntPtr hProcess, int uiFlags);
}
