using System.Drawing.Imaging;
using ImageCompressor.Domain;
using ImageCompressor.Infrastructure;

namespace ImageCompressor.IntegrationTests;

public sealed class FailureRecoverySpec : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), $"ic-recovery-{Guid.NewGuid():N}");
    private string Input => Path.Combine(root, "input");
    private string Output => Path.Combine(root, "output");

    [Theory]
    [InlineData(OutputFormat.Png, ".png")]
    [InlineData(OutputFormat.Bmp, ".bmp")]
    public void NonJpeg_encode_outputs_decode_and_match_requested_format(OutputFormat format, string extension)
    {
        var request = Request(format: format);
        var plan = Plans(request)[0];
        var result = Assert.Single(new CompressionService().Process([plan], request));
        Assert.Equal(ResultStatus.Success, result.Status);
        Assert.EndsWith(extension, result.OutputPath);
        using var decoded = Image.FromFile(result.OutputPath!);
        Assert.Equal(format == OutputFormat.Png ? ImageFormat.Png.Guid : ImageFormat.Bmp.Guid, decoded.RawFormat.Guid);
        Assert.True(SystemDrawingImageEngine.MatchesOutputFormat(extension.ToUpperInvariant(), format));
        Assert.False(SystemDrawingImageEngine.MatchesOutputFormat(".png", (OutputFormat)999));
        Assert.Equal(1, result.EncodeAttempts);
    }

    [Fact]
    public void Cancelled_batch_stops_at_a_safe_point_and_reports_one_cancelled_result()
    {
        var request = Request();
        var plans = Plans(request);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var updates = new List<CompressionProgress>();
        var result = Assert.Single(new CompressionService().Process(plans, request,
            progress: new InlineProgress(updates.Add), cancellationToken: cancellation.Token));
        Assert.Equal(ResultStatus.Cancelled, result.Status);
        Assert.Null(result.OutputPath);
        Assert.Equal(1, Assert.Single(updates).Completed);
        Assert.Equal(plans.Length, updates[0].Total);
        Assert.Equal(plans[0].Source.RelativePath, updates[0].FileName);
        Assert.Same(result, updates[0].Result);
        Assert.Empty(Directory.GetFiles(Output));
    }

    [Fact]
    public void Missing_input_is_a_failed_result_and_does_not_abort_the_next_image()
    {
        var request = Request();
        var plans = Plans(request);
        File.Delete(plans[0].Source.FullPath);
        var messages = new List<string>();
        var results = new CompressionService().Process(plans, request, log: messages.Add);
        Assert.Equal(ResultStatus.Failed, results[0].Status);
        Assert.Equal(ResultStatus.Success, results[1].Status);
        Assert.Equal(2, messages.Count);
        Assert.Single(Directory.GetFiles(Output));
    }

    [Fact]
    public void Explicit_skip_and_multiframe_skip_do_not_write_outputs()
    {
        var request = Request(multiFrame: MultiFramePolicy.SkipMultiFrame);
        var plans = Plans(request);
        plans[0] = plans[0] with { Action = PlanAction.Skip, Reason = "planned exclusion" };
        plans[1] = plans[1] with { Source = plans[1].Source with { FrameCount = 2 } };
        var results = new CompressionService().Process(plans, request);
        Assert.All(results, result => Assert.Equal(ResultStatus.Skipped, result.Status));
        Assert.Equal("planned exclusion", results[0].Reason);
        Assert.Contains("複数フレーム", results[1].Reason);
        Assert.Empty(Directory.GetFiles(Output));
    }

    [Theory]
    [InlineData(LargerOutputPolicy.Skip, ResultStatus.Skipped)]
    [InlineData(LargerOutputPolicy.Warn, ResultStatus.Success)]
    public void Larger_output_policy_is_applied_and_warning_is_preserved(LargerOutputPolicy policy, ResultStatus expected)
    {
        var request = Request(larger: policy);
        var plans = Plans(request);
        // Simulate scanner metadata for a multi-frame source to test service policy,
        // independently of real multi-frame decoder acceptance.
        plans[0] = plans[0] with { Source = plans[0].Source with { FrameCount = 2 } };
        var result = Assert.Single(new CompressionService().Process([plans[0]], request));
        Assert.Equal(expected, result.Status);
        Assert.True(result.IsLarger);
        if (policy == LargerOutputPolicy.Warn)
        {
            Assert.Equal(2, result.Warnings!.Count);
            Assert.True(result.OutputBytes > result.OriginalBytes);
        }
        else { Assert.Empty(Directory.GetFiles(Output)); }
    }

    [Fact]
    public void NonJpeg_target_skip_and_already_within_target_skip_do_not_encode()
    {
        var request = Request(format: OutputFormat.Png, target: true, nonJpeg: TargetNonJpegPolicy.Skip);
        var pngPlan = Plans(request)[0];
        var png = Assert.Single(new CompressionService().Process([pngPlan], request));
        Assert.Equal(ResultStatus.Skipped, png.Status);
        Assert.Contains("非JPEG", png.Reason);
        var jpegPath = Path.Combine(Input, "within.jpg");
        using (var bitmap = new Bitmap(2, 2)) { bitmap.Save(jpegPath, ImageFormat.Jpeg); }
        var copyRequest = Request(target: true, within: AlreadyWithinTargetPolicy.Skip);
        var plan = OutputPlanner.Create(FileScanner.Scan(Input, Output, false), copyRequest).Single(item => item.Source.FullPath == jpegPath);
        var copy = Assert.Single(new CompressionService().Process([plan], copyRequest));
        Assert.Equal(ResultStatus.Skipped, copy.Status);
        Assert.Equal(0, copy.EncodeAttempts);
        Assert.Empty(Directory.GetFiles(Output));
    }

    [Fact]
    public void Own_orphan_is_cleaned_and_reported_before_batch_work()
    {
        var store = new SafeFileStore();
        var request = Request();
        Directory.CreateDirectory(Output);
        var orphan = store.CreateTemporaryPathForTest(Output);
        File.WriteAllText(orphan, "synthetic orphan");
        var messages = new List<string>();
        Assert.Empty(new CompressionService(store).Process([], request, log: messages.Add));
        Assert.False(File.Exists(orphan));
        Assert.Contains(messages, message => message.Contains("孤立", StringComparison.Ordinal));
    }

    [Fact]
    public void Cleanup_never_deletes_similarly_named_unowned_files_or_creates_missing_output()
    {
        var store = new SafeFileStore();
        Assert.Empty(store.CleanupOrphans(Output));
        Assert.False(Directory.Exists(Output));
        Directory.CreateDirectory(Output);
        var unknown = Path.Combine(Output, ".image-compressor-not-a-guid-x.tmp");
        var invalid = Path.Combine(Output, $".image-compressor-{new string('z', 32)}-x.tmp");
        File.WriteAllText(unknown, "synthetic user-owned file");
        File.WriteAllText(invalid, "synthetic user-owned file");
        Assert.Empty(store.CleanupOrphans(Output));
        Assert.True(File.Exists(unknown));
        Assert.True(File.Exists(invalid));
    }

    [Fact]
    public void Invalid_or_mismatched_image_never_replaces_existing_output_or_leaves_temporary_files()
    {
        Directory.CreateDirectory(Output);
        var output = Path.Combine(Output, "keep.png");
        File.WriteAllText(output, "original synthetic output");
        var store = new SafeFileStore();
        Assert.Throws<IOException>(() => store.SaveBytesSafely([], output, true, 1, 1));
        using var memory = new MemoryStream();
        using (var bitmap = new Bitmap(2, 2)) { bitmap.Save(memory, ImageFormat.Png); }
        Assert.Throws<IOException>(() => store.SaveBytesSafely(memory.ToArray(), output, true, 3, 3));
        Assert.Throws<IOException>(() => store.SaveBytesSafely(memory.ToArray(), output, false, 2, 2));
        Assert.Equal("original synthetic output", File.ReadAllText(output));
        Assert.Empty(Directory.GetFiles(Output, "*.tmp"));
        Assert.Throws<ArgumentException>(() => new SafeFileStore("invalid-instance"));
    }

    [Fact]
    public void Locked_settings_fall_back_without_reading_partial_content()
    {
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "settings.json");
        File.WriteAllText(path, "{}");
        var store = new SettingsStore(root);
        using var locked = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        var settings = store.Load(out var warning);
        Assert.NotNull(warning);
        Assert.Equal(Presets.DefaultId, settings.SelectedPresetId);
        Assert.Throws<ArgumentNullException>(() => store.Save(null!));
    }

    private CompressionRequest Request(
        MultiFramePolicy multiFrame = MultiFramePolicy.FirstFrameWithWarning,
        LargerOutputPolicy larger = LargerOutputPolicy.Save,
        OutputFormat format = OutputFormat.Jpeg,
        bool target = false,
        TargetNonJpegPolicy nonJpeg = TargetNonJpegPolicy.ConvertToJpeg,
        AlreadyWithinTargetPolicy within = AlreadyWithinTargetPolicy.Copy) => new()
        {
            InputRoot = Input,
            OutputRoot = Output,
            LargerOutputPolicy = larger,
            MultiFramePolicy = multiFrame,
            OutputFormat = format,
            TargetSizeEnabled = target,
            TargetNonJpegPolicy = nonJpeg,
            AlreadyWithinTargetPolicy = within,
        };

    private OutputPlan[] Plans(CompressionRequest request)
    {
        Directory.CreateDirectory(Input);
        foreach (var name in new[] { "one.png", "two.png" })
        {
            using var bitmap = new Bitmap(2, 2);
            bitmap.Save(Path.Combine(Input, name), ImageFormat.Png);
        }
        return OutputPlanner.Create(FileScanner.Scan(Input, Output, false), request).ToArray();
    }

    public void Dispose() { if (Directory.Exists(root)) { Directory.Delete(root, recursive: true); } }
    private sealed class InlineProgress(Action<CompressionProgress> action) : IProgress<CompressionProgress>
    { public void Report(CompressionProgress value) => action(value); }
}
