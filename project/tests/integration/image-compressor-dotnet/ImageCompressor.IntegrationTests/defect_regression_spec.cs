using System.Drawing.Imaging;
using System.Security.Cryptography;
using System.Reflection;
using System.Runtime.ExceptionServices;
using ImageCompressor.App;
using ImageCompressor.Domain;
using ImageCompressor.Infrastructure;

namespace ImageCompressor.IntegrationTests;

public sealed class DefectRegressionSpec(Xunit.Abstractions.ITestOutputHelper output)
{
    [Fact]
    public void All_unchecked_should_not_process_any_image() => Sta(() =>
    {
        using var f = new Fixture();
        f.Image(f.Input, "one.png");
        using var form = f.Form();
        foreach (DataGridViewRow row in Field<DataGridView>(form, "files").Rows)
            row.Cells["Target"].Value = false;
        Pump((Task)Call(form, "RunAsync")!);
        Assert.Empty(Directory.GetFiles(f.Output));
    });

    [Fact]
    public void Changed_input_text_should_not_process_previous_folder() => Sta(() =>
    {
        using var f = new Fixture();
        f.Image(f.Input, "old.png");
        var next = Directory.CreateDirectory(Path.Combine(f.Root, "next")).FullName;
        f.Image(next, "new.png");
        using var form = f.Form();
        Field<TextBox>(form, "inputPath").Text = next;
        Pump((Task)Call(form, "RunAsync")!);
        Assert.False(File.Exists(Path.Combine(f.Output, "old.jpg")));
        Assert.Empty(Directory.GetFiles(f.Output));
        Assert.True((bool)Call(form, "Scan")!);
        Pump((Task)Call(form, "RunAsync")!);
        Assert.True(File.Exists(Path.Combine(f.Output, "new.jpg")));
    });

    [Theory]
    [InlineData("{\"overrides\":{\"maxWidth\":0}}")]
    [InlineData("{\"overrides\":null}")]
    [InlineData("{\"inputPaths\":null}")]
    public void Malformed_setting_values_should_recover_instead_of_breaking_startup(string json) => Sta(() =>
    {
        using var f = new Fixture();
        File.WriteAllText(f.Store.SettingsPath, json);
        using var form = f.Form();
    });

    [Fact]
    public void Replaced_input_after_scan_must_still_respect_target_bytes()
    {
        using var f = new Fixture();
        var path = Path.Combine(f.Input, "change.jpg");
        using (var small = new Bitmap(2, 2)) small.Save(path, ImageFormat.Jpeg);
        var scanned = FileScanner.Scan(f.Input, f.Output, false);
        using (var large = new Bitmap(400, 400))
        {
            var random = new Random(42);
            for (var y = 0; y < 400; y++)
                for (var x = 0; x < 400; x++)
                    large.SetPixel(x, y, Color.FromArgb(random.Next(256), random.Next(256), random.Next(256)));
            large.Save(path, ImageFormat.Jpeg);
        }
        var request = new CompressionRequest
        {
            InputRoot = f.Input,
            OutputRoot = f.Output,
            TargetSizeEnabled = true,
            TargetBytes = 10240,
            LargerOutputPolicy = LargerOutputPolicy.Save
        };
        var results = new CompressionService().Process(OutputPlanner.Create(scanned, request), request);
        var result = Assert.Single(results);
        Assert.Equal(new FileInfo(path).Length, result.OriginalBytes);
        if (result.OutputPath is { } output)
        {
            Assert.Equal(new FileInfo(output).Length, result.OutputBytes);
            Assert.InRange(result.OutputBytes, 1, request.TargetBytes);
        }
    }

    [Fact]
    public void Multi_frame_warning_must_reach_application_log()
    {
        using var f = new Fixture();
        var path = Path.Combine(f.Input, "animated.gif");
        WriteTwoFrameGif(path);
        var sources = FileScanner.Scan(f.Input, f.Output, false);
        Assert.Equal(2, Assert.Single(sources).FrameCount);
        var request = new CompressionRequest
        {
            InputRoot = f.Input,
            OutputRoot = f.Output,
            LargerOutputPolicy = LargerOutputPolicy.Save
        };
        var logs = new List<string>();
        var result = Assert.Single(new CompressionService().Process(OutputPlanner.Create(sources, request), request, log: logs.Add));
        Assert.NotEmpty(result.Warnings!);
        Assert.Contains(logs, line => line.Contains("先頭フレーム", StringComparison.Ordinal));
    }

    [Fact]
    public void Input_as_output_with_recursion_should_keep_nested_inputs()
    {
        using var f = new Fixture();
        f.Image(f.Input, "one.png");
        var nested = Directory.CreateDirectory(Path.Combine(f.Input, "nested")).FullName;
        f.Image(nested, "two.png");
        Assert.Equal(2, FileScanner.Scan(f.Input, f.Input, true).Count);
    }

    [Fact]
    public void In_place_conversion_must_not_replace_a_later_unprocessed_source()
    {
        using var f = new Fixture();
        foreach (var (name, color) in new[] { ("a.jpeg", Color.Red), ("a.jpg", Color.Blue) })
        {
            using var bitmap = new Bitmap(32, 16);
            using (var graphics = Graphics.FromImage(bitmap)) graphics.Clear(color);
            bitmap.Save(Path.Combine(f.Input, name), ImageFormat.Jpeg);
        }
        var originals = Directory.GetFiles(f.Input).ToDictionary(path => path,
            path => SHA256.HashData(File.ReadAllBytes(path)), StringComparer.OrdinalIgnoreCase);
        var request = new CompressionRequest
        {
            InputRoot = f.Input,
            OutputRoot = f.Input,
            CollisionPolicy = CollisionPolicy.Overwrite,
            LargerOutputPolicy = LargerOutputPolicy.Save
        };
        var plans = OutputPlanner.Create(FileScanner.Scan(f.Input, f.Input, false), request);
        var results = new CompressionService().Process(plans, request);
        Assert.Single(results, result => result.Status == ResultStatus.Skipped);
        Assert.Single(results, result => result.Status == ResultStatus.Success);
        foreach (var (path, hash) in originals)
        {
            Assert.Equal(hash, SHA256.HashData(File.ReadAllBytes(path)));
        }
        using var red = new Bitmap(Path.Combine(f.Input, "a.jpeg"));
        using var blue = new Bitmap(Path.Combine(f.Input, "a.jpg"));
        Assert.True(red.GetPixel(16, 8).R > red.GetPixel(16, 8).B);
        Assert.True(blue.GetPixel(16, 8).B > blue.GetPixel(16, 8).R);
    }

    [Fact]
    public void An_unselected_hard_link_target_is_protected_during_planning_and_execution()
    {
        using var f = new Fixture();
        f.Image(f.Input, "selected.png");
        f.Image(f.Input, "unselected.png");
        var sources = FileScanner.Scan(f.Input, f.Output, false);
        var selected = sources.Single(source => source.RelativePath == "selected.png");
        var unselected = sources.Single(source => source.RelativePath == "unselected.png");
        var alias = Path.Combine(f.Output, "selected.jpg");
        using var link = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("fsutil.exe")
        {
            ArgumentList = { "hardlink", "create", alias, unselected.FullPath },
            UseShellExecute = false,
            CreateNoWindow = true,
        })!;
        Assert.True(link.WaitForExit(5000));
        Assert.Equal(0, link.ExitCode);
        var hash = SHA256.HashData(File.ReadAllBytes(alias));
        var request = new CompressionRequest
        {
            InputRoot = f.Input,
            OutputRoot = f.Output,
            CollisionPolicy = CollisionPolicy.Confirm,
        };
        var protection = new InputProtection(sources);
        var plan = Assert.Single(OutputPlanner.Create([selected], request, null, sources, protection.BlocksReplacement));
        Assert.Equal(PlanAction.Skip, plan.Action);

        var handmade = plan with { Action = PlanAction.Overwrite };
        var result = Assert.Single(new CompressionService().Process([handmade], request, null, null, null, sources, default));
        Assert.Equal(ResultStatus.Skipped, result.Status);
        Assert.Equal(hash, SHA256.HashData(File.ReadAllBytes(alias)));
        Assert.Equal(hash, SHA256.HashData(File.ReadAllBytes(unselected.FullPath)));
    }

    [Fact]
    public void A_short_name_alias_of_another_input_is_protected_during_planning_and_execution()
    {
        using var f = new Fixture();
        var protectedInput = Path.Combine(f.Input, "longfilename-protected-input.jpg");
        using (var red = new Bitmap(32, 16))
        {
            using (var graphics = Graphics.FromImage(red)) graphics.Clear(Color.Red);
            red.Save(protectedInput, ImageFormat.Jpeg);
        }

        var shortName = Path.GetFileName(GetShortPath(protectedInput));
        if (string.Equals(shortName, Path.GetFileName(protectedInput), StringComparison.OrdinalIgnoreCase))
        {
            output.WriteLine("NOT_RUN: the test volume did not create an 8.3 short name.");
            return;
        }

        // The second input is named so that its planned output (<short stem>.jpg)
        // is the 8.3 alias of the first input rather than a new file.
        var twin = Path.Combine(f.Input, Path.GetFileNameWithoutExtension(shortName) + ".png");
        using (var blue = new Bitmap(32, 16))
        {
            using (var graphics = Graphics.FromImage(blue)) graphics.Clear(Color.Blue);
            blue.Save(twin, ImageFormat.Png);
        }

        var alias = Path.Combine(f.Input, Path.GetFileNameWithoutExtension(shortName) + ".jpg");
        Assert.True(File.Exists(alias));
        var originals = Directory.GetFiles(f.Input).ToDictionary(path => path,
            path => SHA256.HashData(File.ReadAllBytes(path)), StringComparer.OrdinalIgnoreCase);
        var sources = FileScanner.Scan(f.Input, f.Input, false);
        Assert.Equal(2, sources.Count);
        var request = new CompressionRequest
        {
            InputRoot = f.Input,
            OutputRoot = f.Input,
            CollisionPolicy = CollisionPolicy.Overwrite,
            LargerOutputPolicy = LargerOutputPolicy.Save
        };

        var protection = new InputProtection(sources);
        Assert.True(protection.BlocksReplacement(alias));

        // Planning may skip or move the twin to a free name, but never targets the alias.
        var guarded = OutputPlanner.Create(sources, request, null, sources, protection.BlocksReplacement);
        Assert.All(guarded, plan => Assert.True(
            plan.Action == PlanAction.Skip || !protection.BlocksReplacement(plan.OutputPath),
            $"{plan.Source.RelativePath} would write to protected input {plan.OutputPath}"));
        var twinPlan = guarded.Single(plan => plan.Source.FullPath == twin);
        Assert.NotEqual(alias, twinPlan.OutputPath, StringComparer.OrdinalIgnoreCase);

        var planned = new CompressionService().Process(guarded, request);
        Assert.DoesNotContain(planned, result => result.Status == ResultStatus.Failed);

        // A hand-made plan that overwrites the alias is refused at execution time.
        var handmade = twinPlan with
        {
            OutputPath = alias,
            OutputName = Path.GetFileName(alias),
            Action = PlanAction.Overwrite
        };
        var forced = Assert.Single(new CompressionService().Process([handmade], request, null, null, null, sources, default));
        Assert.Equal(ResultStatus.Skipped, forced.Status);

        foreach (var (path, hash) in originals)
        {
            Assert.Equal(hash, SHA256.HashData(File.ReadAllBytes(path)));
        }

        using var stillRed = new Bitmap(protectedInput);
        Assert.True(stillRed.GetPixel(16, 8).R > stillRed.GetPixel(16, 8).B);
    }

    [Theory]
    [InlineData(LargerOutputPolicy.Save)]
    [InlineData(LargerOutputPolicy.Warn)]
    public void Multi_page_tiff_warning_reaches_the_log_once(LargerOutputPolicy policy)
    {
        using var f = new Fixture();
        var path = Path.Combine(f.Input, "pages.tif");
        WriteTwoPageTiff(path);
        var sources = FileScanner.Scan(f.Input, f.Output, false);
        Assert.Equal(2, Assert.Single(sources).FrameCount);
        var request = new CompressionRequest
        {
            InputRoot = f.Input,
            OutputRoot = f.Output,
            LargerOutputPolicy = policy
        };
        var logs = new List<string>();
        var result = Assert.Single(new CompressionService().Process(OutputPlanner.Create(sources, request), request, log: logs.Add));

        Assert.Contains(result.Warnings!, warning => warning.Contains("先頭フレーム", StringComparison.Ordinal));
        var frameWarnings = logs.Where(line => line.Contains("先頭フレーム", StringComparison.Ordinal)).ToList();
        Assert.Single(frameWarnings);
        Assert.Contains("pages.tif", frameWarnings[0], StringComparison.OrdinalIgnoreCase);
        Assert.Equal(result.Warnings!.Count, logs.Count(line => result.Warnings!.Any(warning => line.Contains(warning, StringComparison.Ordinal))));
    }

    [Fact]
    public void Sorted_rows_show_the_result_of_their_own_image() => Sta(() =>
    {
        using var f = new Fixture();
        f.Image(f.Input, "a-plain.png");
        WriteTwoFrameGif(Path.Combine(f.Input, "b-animated.gif"));
        f.Image(f.Input, "c-plain.png");
        using var form = f.Form();
        var grid = Field<DataGridView>(form, "files");
        grid.Sort(grid.Columns["Name"]!, System.ComponentModel.ListSortDirection.Descending);
        var namesBefore = grid.Rows.Cast<DataGridViewRow>().Select(row => (string)row.Cells["Name"].Value!).ToList();
        Assert.Equal(["c-plain.png", "b-animated.gif", "a-plain.png"], namesBefore);

        Pump((Task)Call(form, "RunAsync")!);

        foreach (DataGridViewRow row in grid.Rows)
        {
            var source = Assert.IsType<SourceItem>(row.Tag);
            Assert.Equal(source.RelativePath, row.Cells["Name"].Value);
            var expected = source.Extension.Equals(".gif", StringComparison.OrdinalIgnoreCase)
                ? "警告あり" : ResultStatus.Success.ToString();
            Assert.Equal(expected, row.Cells["Status"].Value);
        }

        Assert.Contains("警告 1件", Field<Label>(form, "progressLabel").Text, StringComparison.Ordinal);
    });

    [Fact]
    public void Scan_state_ignores_external_output_changes_and_invalidates_on_exclusion_change()
    {
        using var f = new Fixture();
        var scan = new ScanState();
        scan.Succeeded(ScanConditions.Create([f.Input], f.Output, true));
        scan.Recheck(ScanConditions.Create([f.Input], Path.Combine(f.Root, "other"), true));
        Assert.True(scan.CanStart);
        scan.Recheck(ScanConditions.Create([f.Input], Path.Combine(f.Input, "excluded"), true));
        Assert.True(scan.RequiresRefresh);
    }

    [Fact]
    public async Task Parallel_cleanup_must_not_remove_another_active_writers_temporary_file()
    {
        using var f = new Fixture();
        byte[] bytes;
        using (var bitmap = new Bitmap(12, 8))
        using (var stream = new MemoryStream()) { bitmap.Save(stream, ImageFormat.Png); bytes = stream.ToArray(); }
        var writer = new SafeFileStore();
        var cleaner = new SafeFileStore();
        var control = Directory.CreateDirectory(Path.Combine(f.Root, "control")).FullName;
        for (var i = 0; i < 200; i++)
            writer.SaveBytesSafely(bytes, Path.Combine(control, $"image-{i}.png"), false, 12, 8);
        Assert.Equal(200, Directory.GetFiles(control).Length);
        var failures = new List<string>();
        using var cancellation = new CancellationTokenSource();
        var cleanup = Task.Run(() =>
        {
            while (!cancellation.IsCancellationRequested) cleaner.CleanupOrphans(f.Output);
        });
        try
        {
            for (var i = 0; i < 200; i++)
            {
                try { writer.SaveBytesSafely(bytes, Path.Combine(f.Output, $"image-{i}.png"), false, 12, 8); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { failures.Add(error.GetType().Name); }
            }
        }
        finally { cancellation.Cancel(); await cleanup; }
        Assert.True(failures.Count == 0, $"Concurrent cleanup caused {failures.Count}/200 writes to fail");
    }

    internal static void WriteTwoPageTiff(string path)
    {
        var codec = ImageCodecInfo.GetImageEncoders().Single(encoder => encoder.FormatID == ImageFormat.Tiff.Guid);
        using var first = new Bitmap(16, 16);
        using var second = new Bitmap(16, 16);
        using (var graphics = Graphics.FromImage(second)) graphics.Clear(Color.Green);
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.SaveFlag, (long)EncoderValue.MultiFrame);
        first.Save(path, codec, parameters);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.SaveFlag, (long)EncoderValue.FrameDimensionPage);
        first.SaveAdd(second, parameters);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.SaveFlag, (long)EncoderValue.Flush);
        first.SaveAdd(parameters);
    }

    private static string GetShortPath(string path)
    {
        var buffer = new char[1024];
        var length = GetShortPathName(path, buffer, buffer.Length);
        Assert.InRange(length, 1, buffer.Length - 1);
        return new string(buffer, 0, length);
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true, EntryPoint = "GetShortPathNameW")]
    private static extern int GetShortPathName(string longPath, [System.Runtime.InteropServices.Out] char[] shortPath, int bufferLength);

    internal static void WriteTwoFrameGif(string path)
    {
        byte[] header = [71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, 255, 255, 255];
        byte[] frame = [33, 249, 4, 0, 1, 0, 0, 0, 44, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 68, 1, 0];
        File.WriteAllBytes(path, [.. header, .. frame, .. frame, 59]);
    }

    private static T Field<T>(object target, string name) => (T)target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(target)!;
    private static object? Call(object target, string name, params object[] args)
    {
        try { return target.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(target, args); }
        catch (TargetInvocationException e) when (e.InnerException is not null) { ExceptionDispatchInfo.Capture(e.InnerException).Throw(); throw; }
    }
    private static void Pump(Task task)
    {
        var stop = DateTime.UtcNow.AddSeconds(15);
        while (!task.IsCompleted && DateTime.UtcNow < stop) { Application.DoEvents(); Thread.Sleep(1); }
        Assert.True(task.IsCompleted);
        task.GetAwaiter().GetResult();
        Application.DoEvents();
    }
    private static void Sta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() => { try { action(); } catch (Exception e) { failure = e; } }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(30)));
        if (failure is not null) ExceptionDispatchInfo.Capture(failure).Throw();
    }
    private sealed class Fixture : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "ic-review-" + Guid.NewGuid().ToString("N"));
        public string Input => Path.Combine(Root, "input");
        public string Output => Path.Combine(Root, "output");
        public SettingsStore Store { get; }
        public Fixture()
        {
            Directory.CreateDirectory(Input);
            Directory.CreateDirectory(Output);
            File.WriteAllText(Path.Combine(Root, "settings.json"), "{}");
            Store = new(Root);
            Store.Save(new() { OutputPath = Output, LargerOutputPolicy = LargerOutputPolicy.Save });
        }
        public MainForm Form()
        {
            var form = new MainForm([Input], false, Store, (_, _, _, _) => DialogResult.Yes);
            _ = form.Handle;
            return form;
        }
        public void Image(string directory, string name)
        {
            Assert.StartsWith(Root, directory, StringComparison.OrdinalIgnoreCase);
            using var image = new Bitmap(32, 16);
            image.Save(Path.Combine(directory, name), ImageFormat.Png);
        }
        public void Dispose() { Directory.Delete(Root, true); }
    }
}
