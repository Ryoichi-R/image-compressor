using System.Diagnostics;
using System.Reflection;
using System.Runtime.ExceptionServices;
using ImageCompressor.App;
using ImageCompressor.Domain;
using ImageCompressor.Infrastructure;

namespace ImageCompressor.IntegrationTests;

public sealed class MainFormWorkflowSpec
{
    private static readonly int[] SuggestedBounds = [0, 0, 4000, 4000];
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Shown_and_synthetic_dpi_event_apply_work_area_constraint_unless_cancelled(bool cancel) => Sta(() =>
    {
        using var test = new Fixture();
        using var form = test.Form();
        form.Bounds = new(0, 0, 4000, 4000);
        Call(form, "OnShown", EventArgs.Empty);
        Assert.True(Screen.FromControl(form).WorkingArea.Contains(form.Bounds));
        form.Bounds = new(0, 0, 4000, 4000);
        var beforeEvent = form.Bounds;
        form.DpiChanged += (_, args) => args.Cancel = cancel;
        var rectangle = System.Runtime.InteropServices.Marshal.AllocHGlobal(16);
        try
        {
            System.Runtime.InteropServices.Marshal.Copy(SuggestedBounds, 0, rectangle, 4);
            var message = Message.Create(IntPtr.Zero, 0x02E0, new IntPtr(144 | (144 << 16)), rectangle);
            var constructor = typeof(DpiChangedEventArgs).GetConstructors(BindingFlags.Instance | BindingFlags.NonPublic).Single();
            var args = (DpiChangedEventArgs)constructor.Invoke([96, message]);
            Call(form, "OnDpiChanged", args);
            Assert.Equal(cancel, args.Cancel);
            if (!cancel) { Assert.True(Screen.FromControl(form).WorkingArea.Contains(form.Bounds)); }
            else { Assert.Equal(beforeEvent, form.Bounds); }
        }
        finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(rectangle); }
    });

    [Fact]
    public void Startup_scan_excludes_broken_images_and_selection_controls_the_summary() => Sta(() =>
    {
        using var test = new Fixture();
        var image = test.Image("valid.png");
        File.WriteAllText(Path.Combine(test.Input, "broken.png"), "not an image");
        using var form = test.Form([test.Input, test.Input, Path.Combine(test.Root, "missing")]);
        var grid = Field<DataGridView>(form, "files");
        Assert.Equal(2, grid.Rows.Count);
        var valid = grid.Rows.Cast<DataGridViewRow>().Single(row => row.Tag is SourceItem);
        var skipped = grid.Rows.Cast<DataGridViewRow>().Single(row => row.Tag is null);
        Assert.True(skipped.Cells["Target"].ReadOnly);
        Assert.Contains("Skipped", skipped.Cells["Status"].Value?.ToString());
        Assert.Contains("対象 1件", Field<Label>(form, "summaryLabel").Text);
        valid.Cells["Target"].Value = false;
        Assert.Contains("対象 0件", Field<Label>(form, "summaryLabel").Text);
        typeof(Control).GetMethod("OnClick", BindingFlags.Instance | BindingFlags.NonPublic)!
            .Invoke(Field<Button>(form, "scanButton"), [EventArgs.Empty]);
        Assert.Contains("対象 1件", Field<Label>(form, "summaryLabel").Text);
        Assert.True(File.Exists(image));
    });

    [Fact]
    public void Preset_changes_and_individual_overrides_round_trip_with_all_policies() => Sta(() =>
    {
        using var test = new Fixture();
        test.Store.Save(new()
        {
            SelectedPresetId = "hd",
            Overrides = new(111, 222, 44, OutputFormat.Png),
            InputPath = test.Input,
            OutputPath = test.Output,
            TargetKilobytes = 42,
            TargetSizeEnabled = true,
            TargetNonJpegPolicy = TargetNonJpegPolicy.Skip,
            IncludeSubfolders = true,
            PreserveHierarchy = true,
            JpegBackgroundBlack = true,
            WindowX = 40,
            WindowY = 50,
            WindowWidth = 1000,
            WindowHeight = 700,
        });
        using var form = test.Form();
        Assert.Equal(111, Field<NumericUpDown>(form, "maxWidth").Value);
        Assert.Equal(42, Field<NumericUpDown>(form, "targetKibibytes").Value);
        Assert.Equal(1, Field<ComboBox>(form, "targetNonJpeg").SelectedIndex);
        Field<ComboBox>(form, "preset").SelectedIndex = 0;
        Field<NumericUpDown>(form, "quality").Value = 51;
        Field<ComboBox>(form, "format").SelectedItem = OutputFormat.Bmp;
        Call(form, "SaveSettings");
        var saved = test.Store.Load(out var warning);
        Assert.Null(warning);
        Assert.Equal(51, saved.Overrides.Quality);
        Assert.Equal(OutputFormat.Bmp, saved.Overrides.Format);
        Assert.Equal(new[] { test.Input }, saved.InputPaths);
        Assert.True(saved.IncludeSubfolders && saved.PreserveHierarchy && saved.JpegBackgroundBlack);
        Assert.Equal(TargetNonJpegPolicy.Skip, saved.TargetNonJpegPolicy);
    });

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Conversion_uses_selected_rows_and_restores_controls(bool target) => Sta(() =>
    {
        using var test = new Fixture();
        test.Image("one.png");
        test.Image("two.png");
        using var form = test.Form([test.Input]);
        var grid = Field<DataGridView>(form, "files");
        grid.Rows[1].Cells["Target"].Value = false;
        Field<CheckBox>(form, "targetEnabled").Checked = target;
        Field<NumericUpDown>(form, "targetKibibytes").Value = 10;
        Field<ComboBox>(form, "largerPolicy").SelectedItem = LargerOutputPolicy.Save;
        Pump((Task)Call(form, "RunAsync")!);
        Assert.Single(Directory.GetFiles(test.Output, "*.jpg"));
        Assert.Contains("出力 1", Field<TextBox>(form, "log").Text);
        Assert.True(Field<Button>(form, "runButton").Enabled);
        Assert.True(Field<TextBox>(form, "inputPath").Enabled);
        Assert.False(Field<Button>(form, "cancelButton").Enabled);
        using var output = System.Drawing.Image.FromFile(Directory.GetFiles(test.Output, "*.jpg").Single());
        Assert.Equal(new Size(32, 16), output.Size);
    });

    [Fact]
    public void Overwrite_confirmation_refusal_preserves_existing_output_then_acceptance_replaces_it() => Sta(() =>
    {
        using var test = new Fixture();
        test.Image("one.png");
        var output = Path.Combine(test.Output, "one.jpg");
        File.WriteAllText(output, "synthetic existing file");
        using var form = test.Form([test.Input]);
        Field<ComboBox>(form, "collision").SelectedItem = CollisionPolicy.Confirm;
        Field<ComboBox>(form, "largerPolicy").SelectedItem = LargerOutputPolicy.Save;
        test.Answer = DialogResult.No;
        Pump((Task)Call(form, "RunAsync")!);
        Assert.Equal("synthetic existing file", File.ReadAllText(output));
        Assert.Contains(test.Messages, message => message.Caption == "上書き確認");
        test.Answer = DialogResult.Yes;
        Pump((Task)Call(form, "RunAsync")!);
        using var decoded = System.Drawing.Image.FromFile(output);
        Assert.Equal(new Size(32, 16), decoded.Size);
    });

    [Fact]
    public void Missing_output_and_empty_selection_report_errors_without_leaving_running_controls() => Sta(() =>
    {
        using var test = new Fixture();
        using var form = test.Form();
        Field<TextBox>(form, "outputPath").Text = string.Empty;
        Call(form, "Scan");
        Assert.Contains(test.Messages, message => message.Caption == "一覧更新エラー");
        Field<TextBox>(form, "outputPath").Text = test.Output;
        Pump((Task)Call(form, "RunAsync")!);
        Assert.Contains(test.Messages, message => message.Caption == "処理エラー");
        Assert.True(Field<Button>(form, "scanButton").Enabled);
        Assert.False(Field<Button>(form, "cancelButton").Enabled);
        Field<TextBox>(form, "inputPath").Text = test.Input;
        Assert.Throws<ArgumentException>(() => Call(form, "CreateRequest"));
    });

    [Fact]
    public void Synthetic_file_drop_accepts_files_and_rejects_changes_while_processing() => Sta(() =>
    {
        using var test = new Fixture();
        var image = test.Image("drop.png");
        using var form = test.Form();
        Field<TextBox>(form, "outputPath").Text = string.Empty;
        var data = new DataObject(DataFormats.FileDrop, new[] { image });
        var drag = new DragEventArgs(data, 0, 0, 0, DragDropEffects.Copy, DragDropEffects.None);
        CallControl(form, "OnDragEnter", drag);
        Assert.Equal(DragDropEffects.Copy, drag.Effect);
        CallControl(form, "OnDragDrop", drag);
        Assert.Single(Field<DataGridView>(form, "files").Rows.Cast<DataGridViewRow>());
        Assert.Equal(Path.Combine(test.Input, "compressed"), Field<TextBox>(form, "outputPath").Text);
        var blocked = new TaskCompletionSource<IReadOnlyList<CompressionResult>>();
        Set(form, "processingTask", blocked.Task);
        CallControl(form, "OnDragEnter", drag);
        Assert.Equal(DragDropEffects.None, drag.Effect);
        CallControl(form, "OnDragDrop", drag);
        Assert.Contains(test.Messages, message => message.Caption == "D&D");
        blocked.SetResult([]);
        CallControl(form, "OnDragEnter", new DragEventArgs(new DataObject("text"), 0, 0, 0, DragDropEffects.Copy, DragDropEffects.None));
        Call(form, "ApplyStartupPaths", (object)new[] { Path.Combine(test.Root, "missing") });
        Assert.Single(Field<DataGridView>(form, "files").Rows.Cast<DataGridViewRow>());
    });

    [Fact]
    public void Cancel_requests_the_token_and_close_waits_for_processing_before_saving() => Sta(() =>
    {
        using var test = new Fixture();
        using var form = test.Form();
        using var token = new CancellationTokenSource();
        Set(form, "cancellation", token);
        Call(form, "SetRunning", true);
        typeof(Control).GetMethod("OnClick", BindingFlags.Instance | BindingFlags.NonPublic)!
            .Invoke(Field<Button>(form, "cancelButton"), [EventArgs.Empty]);
        Assert.True(token.IsCancellationRequested);
        Assert.Contains("キャンセル要求済み", Field<Label>(form, "progressLabel").Text);
        var processing = new TaskCompletionSource<IReadOnlyList<CompressionResult>>();
        Set(form, "processingTask", processing.Task);
        test.Answer = DialogResult.No;
        var declined = new FormClosingEventArgs(CloseReason.UserClosing, false);
        Call(form, "OnFormClosing", declined);
        Assert.True(declined.Cancel);
        Assert.False(Field<bool>(form, "closeAfterProcessing"));
        test.Answer = DialogResult.Yes;
        var accepted = new FormClosingEventArgs(CloseReason.UserClosing, false);
        Call(form, "OnFormClosing", accepted);
        Assert.True(accepted.Cancel);
        Assert.True(Field<bool>(form, "closeAfterProcessing"));
        processing.SetResult([]);
        Pump((Task)Call(form, "CloseWhenProcessingStopsAsync")!);
        Application.DoEvents();
        Assert.True(File.Exists(test.Store.SettingsPath));
    });

    [Fact]
    public void Closing_a_cancelled_processing_task_still_reaches_normal_close() => Sta(() =>
    {
        using var test = new Fixture();
        using var form = test.Form();
        Set(form, "processingTask", Task.FromCanceled<IReadOnlyList<CompressionResult>>(new CancellationToken(true)));
        Pump((Task)Call(form, "CloseWhenProcessingStopsAsync")!);
        Assert.True(form.IsDisposed);
    });

    [Fact]
    public void Invalid_settings_warn_and_failed_settings_save_is_reported() => Sta(() =>
    {
        using var test = new Fixture();
        File.WriteAllText(test.Store.SettingsPath, "invalid JSON");
        using var form = test.Form(minimized: true);
        Assert.Equal(FormWindowState.Minimized, form.WindowState);
        form.ConstrainToWorkingArea(new(0, 0, 300, 200));
        Assert.Equal(FormWindowState.Minimized, form.WindowState);
        Assert.Contains("既定値", Field<TextBox>(form, "log").Text);
        File.Delete(test.Store.SettingsPath);
        Directory.CreateDirectory(test.Store.SettingsPath);
        Call(form, "OnFormClosing", new FormClosingEventArgs(CloseReason.UserClosing, false));
        Assert.Contains(test.Messages, message => message.Caption == "設定保存エラー");
    });

    private static T Field<T>(object target, string name) =>
        (T)target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(target)!;

    private static void Set(object target, string name, object value) =>
        target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(target, value);

    private static object? Call(object target, string name, params object[] args)
    {
        try { return target.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(target, args); }
        catch (TargetInvocationException exception) when (exception.InnerException is not null)
        { ExceptionDispatchInfo.Capture(exception.InnerException).Throw(); throw; }
    }

    private static void CallControl(Control control, string name, DragEventArgs args) =>
        typeof(Control).GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(control, [args]);

    private static void Pump(Task task)
    {
        var timer = Stopwatch.StartNew();
        while (!task.IsCompleted && timer.Elapsed < TimeSpan.FromSeconds(15))
        { Application.DoEvents(); Thread.Sleep(1); }
        Assert.True(task.IsCompleted, "Synthetic workflow timed out");
        task.GetAwaiter().GetResult();
        Application.DoEvents();
    }

    private static void Sta(Action action)
    {
        Exception? error = null;
        var thread = new Thread(() =>
        {
            try { action(); }
            catch (Exception exception) { error = exception; }
        })
        { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(30)), "STA workflow timed out");
        if (error is not null) { ExceptionDispatchInfo.Capture(error).Throw(); }
    }

    private sealed class Fixture : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), $"ic-workflow-{Guid.NewGuid():N}");
        public string Input => Path.Combine(Root, "input");
        public string Output => Path.Combine(Root, "output");
        public SettingsStore Store { get; }
        public DialogResult Answer { get; set; } = DialogResult.No;
        public List<(string Caption, string Message)> Messages { get; } = [];

        public Fixture()
        {
            Directory.CreateDirectory(Input);
            Directory.CreateDirectory(Output);
            File.WriteAllText(Path.Combine(Root, "settings.json"), "{}");
            Store = new(Root);
            Store.Save(new() { OutputPath = Output });
        }

        public MainForm Form(IReadOnlyList<string>? paths = null, bool minimized = false)
        {
            var form = new MainForm(paths ?? [], minimized, Store, (message, caption, _, _) =>
            { Messages.Add((caption, message)); return Answer; });
            _ = form.Handle;
            return form;
        }

        public string Image(string name)
        {
            var path = Path.Combine(Input, name);
            using var bitmap = new Bitmap(32, 16);
            bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            return path;
        }

        public void Dispose() => Directory.Delete(Root, recursive: true);
    }
}
