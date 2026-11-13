using System.Collections.Concurrent;
using ImageCompressor.Domain;
using ImageCompressor.Infrastructure;

namespace ImageCompressor.App;

public sealed class MainForm : Form
{
    private readonly TextBox inputPath = new() { Dock = DockStyle.Fill, AllowDrop = true };
    private readonly TextBox outputPath = new() { Dock = DockStyle.Fill };
    private readonly ComboBox preset = Combo(150);
    private readonly NumericUpDown maxWidth = Number(1, 100000, 1920);
    private readonly NumericUpDown maxHeight = Number(1, 100000, 1080);
    private readonly NumericUpDown quality = Number(1, 100, 75);
    private readonly ComboBox format = EnumCombo<OutputFormat>();
    private readonly CheckBox targetEnabled = new() { Text = "指定容量以下", AutoSize = true };
    private readonly NumericUpDown targetKibibytes = Number(1, 1048576, 500);
    private readonly ComboBox targetNonJpeg = Combo(120);
    private readonly ComboBox collision = EnumCombo<CollisionPolicy>();
    private readonly ComboBox largerPolicy = EnumCombo<LargerOutputPolicy>();
    private readonly ComboBox withinTarget = EnumCombo<AlreadyWithinTargetPolicy>();
    private readonly CheckBox includeSubfolders = new() { Text = "サブフォルダを含む", AutoSize = true };
    private readonly CheckBox preserveHierarchy = new() { Text = "階層を維持", AutoSize = true };
    private readonly CheckBox blackBackground = new() { Text = "JPEG透明背景を黒にする", AutoSize = true };
    private readonly DataGridView files = new()
    {
        Dock = DockStyle.Fill,
        ReadOnly = false,
        AllowUserToAddRows = false,
        RowTemplate = new AccessibleFileRow(),
        AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
        ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.AutoSize,
        AllowDrop = true,
    };
    private readonly TextBox log = new()
    {
        Dock = DockStyle.Fill,
        Multiline = true,
        ReadOnly = true,
        ScrollBars = ScrollBars.Vertical,
    };
    private readonly ProgressBar progressBar = new() { Dock = DockStyle.Fill };
    private readonly Label progressLabel = new() { Text = "待機中", AutoSize = true };
    private readonly Label summaryLabel = new() { Text = "対象 0件 / 0 KiB", AutoSize = true };
    private readonly Button scanButton = new() { Text = "一覧更新", AutoSize = true };
    private readonly Button runButton = new() { Text = "圧縮開始", AutoSize = true };
    private readonly Button cancelButton = new() { Text = "キャンセル", Enabled = false, AutoSize = true };
    private readonly List<Control> configurationControls = [];
    private readonly SettingsStore settingsStore;
    private readonly Func<string, string, MessageBoxButtons, MessageBoxIcon, DialogResult> showMessage;
    private List<string> inputPaths = [];
    private CancellationTokenSource? cancellation;
    private Task<IReadOnlyList<CompressionResult>>? processingTask;
    private bool applyingPreset;
    private readonly JobState job = new();
    private readonly ScanState scan = new();
    private bool promptingForClose;

    public MainForm(IReadOnlyList<string> startupPaths, bool minimized)
        : this(startupPaths, minimized, new SettingsStore(AppContext.BaseDirectory), null)
    {
    }

    internal MainForm(
        IReadOnlyList<string> startupPaths,
        bool minimized,
        SettingsStore settingsStore,
        Func<string, string, MessageBoxButtons, MessageBoxIcon, DialogResult>? showMessage)
    {
        SuspendLayout();
        AutoScaleDimensions = new(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        Text = "Image Compressor";
        MinimumSize = new(900, 680);
        Size = new(1100, 800);
        AllowDrop = true;
        this.settingsStore = settingsStore;
        this.showMessage = showMessage ?? ((message, caption, buttons, icon) =>
            MessageBox.Show(this, message, caption, buttons, icon));
        BuildLayout();
        ResumeLayout(performLayout: true);
        WireEvents();
        LoadSettings();
        ApplyStartupPaths(startupPaths);
        ScanOptionsChanged();
        if (minimized)
        {
            WindowState = FormWindowState.Minimized;
        }
    }

    protected override void OnShown(EventArgs e)
    {
        ConstrainToWorkingArea(Screen.FromControl(this).WorkingArea);
        RefreshFileRowHeights();
        base.OnShown(e);
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        if (!e.Cancel)
        {
            ConstrainToWorkingArea(Screen.FromControl(this).WorkingArea);
            RefreshFileRowHeights();
        }
    }

    internal void RefreshFileRowHeights()
    {
        if (!files.IsHandleCreated || files.IsDisposed)
        {
            return;
        }

        using var graphics = files.CreateGraphics();
        var textHeight = TextRenderer.MeasureText(graphics, "Ag国", files.Font,
            Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Height;
        var padding = (8 * files.DeviceDpi + 95) / 96;
        var minimumHeight = (22 * files.DeviceDpi + 95) / 96;
        var height = Math.Max(minimumHeight, textHeight + padding);
        files.SuspendLayout();
        try
        {
            files.RowTemplate.Height = height;
            foreach (DataGridViewRow row in files.Rows)
            {
                if (row.Height != height)
                {
                    row.Height = height;
                }
            }
        }
        finally
        {
            files.ResumeLayout();
        }
    }

    internal void ConstrainToWorkingArea(Rectangle workingArea)
    {
        if (WindowState != FormWindowState.Normal)
        {
            return;
        }

        // A scaled minimum must not force the window below the taskbar or off screen.
        MinimumSize = new(
            Math.Min(LogicalToDeviceUnits(900), workingArea.Width),
            Math.Min(LogicalToDeviceUnits(680), workingArea.Height));
        var width = Math.Min(Width, workingArea.Width);
        var height = Math.Min(Height, workingArea.Height);
        Bounds = new(
            Math.Clamp(Left, workingArea.Left, workingArea.Right - width),
            Math.Clamp(Top, workingArea.Top, workingArea.Bottom - height),
            width,
            height);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (job.IsRunning)
        {
            var systemClosing = e.CloseReason is CloseReason.WindowsShutDown or CloseReason.TaskManagerClosing;
            e.Cancel = !systemClosing;
            if (systemClosing)
            {
                RequestClose();
                try
                {
                    processingTask?.Wait(TimeSpan.FromMilliseconds(250));
                }
                catch (AggregateException exception)
                {
                    System.Diagnostics.Trace.TraceError(exception.GetBaseException().Message);
                }

                base.OnFormClosing(e);
                return;
            }

            if (!job.CloseRequested && !promptingForClose)
            {
                promptingForClose = true;
                try
                {
                    var answer = showMessage(
                        "処理をキャンセルして、完了を待ってから終了しますか？",
                        "処理中です", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                    if (answer == DialogResult.Yes)
                    {
                        RequestClose();
                    }
                }
                finally
                {
                    promptingForClose = false;
                }
            }

            return;
        }

        try
        {
            SaveSettings();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            showMessage(exception.Message, "設定保存エラー", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        base.OnFormClosing(e);
    }

    private void RequestClose()
    {
        if (job.RequestClose())
        {
            progressLabel.Text = "終了のためキャンセル待機中";
            cancellation?.Cancel();
        }
    }

    private void BuildLayout()
    {
        files.Columns.Add(new DataGridViewCheckBoxColumn
        {
            CellTemplate = new AccessibleCheckBoxCell(),
            Name = "Target",
            HeaderText = "対象",
            FillWeight = 35,
        });
        files.Columns.Add("Name", "ファイル");
        files.Columns.Add("Extension", "拡張子");
        files.Columns.Add("Size", "容量");
        files.Columns.Add("Dimensions", "寸法");
        files.Columns.Add("Frames", "フレーム");
        files.Columns.Add("Status", "状態");
        foreach (DataGridViewColumn column in files.Columns)
        {
            if (column.Name != "Target")
            {
                column.CellTemplate = new AccessibleTextBoxCell();
                column.ReadOnly = true;
            }
        }

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 6,
            Padding = new(8),
        };
        root.ColumnStyles.Add(new(SizeType.Percent, 100));
        root.RowStyles.Add(new(SizeType.AutoSize));
        root.RowStyles.Add(new(SizeType.AutoSize));
        root.RowStyles.Add(new(SizeType.AutoSize));
        root.RowStyles.Add(new(SizeType.Percent, 62));
        root.RowStyles.Add(new(SizeType.Percent, 38));
        root.RowStyles.Add(new(SizeType.AutoSize));
        root.Controls.Add(BuildPathsPanel(), 0, 0);
        root.Controls.Add(BuildOptionsPanel(), 0, 1);
        root.Controls.Add(summaryLabel, 0, 2);
        root.Controls.Add(files, 0, 3);
        root.Controls.Add(log, 0, 4);
        root.Controls.Add(BuildActionsPanel(), 0, 5);
        Controls.Add(root);
    }

    private TableLayoutPanel BuildPathsPanel()
    {
        var panel = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 3 };
        panel.ColumnStyles.Add(new(SizeType.AutoSize));
        panel.ColumnStyles.Add(new(SizeType.Percent, 100));
        panel.ColumnStyles.Add(new(SizeType.AutoSize));
        var inputBrowse = BrowseButton(inputPath, "入力フォルダを選択", isInput: true);
        var outputBrowse = BrowseButton(outputPath, "出力フォルダを選択", isInput: false);
        panel.Controls.Add(new Label { Text = "入力:", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 0);
        panel.Controls.Add(inputPath, 1, 0);
        panel.Controls.Add(inputBrowse, 2, 0);
        panel.Controls.Add(new Label { Text = "出力:", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 1);
        panel.Controls.Add(outputPath, 1, 1);
        panel.Controls.Add(outputBrowse, 2, 1);
        configurationControls.AddRange([inputPath, outputPath, inputBrowse, outputBrowse]);
        return panel;
    }

    private FlowLayoutPanel BuildOptionsPanel()
    {
        targetNonJpeg.Items.AddRange(["JPEGへ変換", "保存しない"]);
        targetNonJpeg.SelectedIndex = 0;
        var panel = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = true };
        AddOption(panel, "プリセット", preset);
        AddOption(panel, "最大幅", maxWidth);
        AddOption(panel, "最大高", maxHeight);
        AddOption(panel, "品質", quality);
        AddOption(panel, "形式", format);
        panel.Controls.Add(targetEnabled);
        AddOption(panel, "KiB", targetKibibytes);
        AddOption(panel, "非JPEG", targetNonJpeg);
        AddOption(panel, "衝突", collision);
        AddOption(panel, "容量増加", largerPolicy);
        AddOption(panel, "既に容量内", withinTarget);
        panel.Controls.Add(includeSubfolders);
        panel.Controls.Add(preserveHierarchy);
        panel.Controls.Add(blackBackground);
        configurationControls.AddRange(
        [
            preset,
            maxWidth,
            maxHeight,
            quality,
            format,
            targetEnabled,
            targetKibibytes,
            targetNonJpeg,
            collision,
            largerPolicy,
            withinTarget,
            includeSubfolders,
            preserveHierarchy,
            blackBackground,
        ]);
        return panel;
    }

    private TableLayoutPanel BuildActionsPanel()
    {
        var panel = new TableLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, ColumnCount = 5 };
        panel.ColumnStyles.Add(new(SizeType.AutoSize));
        panel.ColumnStyles.Add(new(SizeType.AutoSize));
        panel.ColumnStyles.Add(new(SizeType.AutoSize));
        panel.ColumnStyles.Add(new(SizeType.Percent, 100));
        panel.ColumnStyles.Add(new(SizeType.AutoSize));
        panel.Controls.Add(scanButton, 0, 0);
        panel.Controls.Add(runButton, 1, 0);
        panel.Controls.Add(cancelButton, 2, 0);
        panel.Controls.Add(progressBar, 3, 0);
        panel.Controls.Add(progressLabel, 4, 0);
        return panel;
    }

    private void WireEvents()
    {
        files.HandleCreated += (_, _) => RefreshFileRowHeights();
        files.FontChanged += (_, _) => RefreshFileRowHeights();
        files.DpiChangedAfterParent += (_, _) => RefreshFileRowHeights();
        preset.DataSource = Presets.Items.ToList();
        preset.DisplayMember = nameof(PresetDefinition.DisplayName);
        preset.SelectedIndexChanged += (_, _) => ApplySelectedPreset();
        scanButton.Click += (_, _) => Scan();
        inputPath.TextChanged += (_, _) => ScanOptionsChanged();
        outputPath.TextChanged += (_, _) => ScanOptionsChanged();
        includeSubfolders.CheckedChanged += (_, _) => ScanOptionsChanged();
        runButton.Click += async (_, _) => await RunAsync();
        cancelButton.Click += (_, _) =>
        {
            var elapsed = CancelRequestHandler.Request(
                cancellation,
                () => progressLabel.Text = "キャンセル要求済み");
            AppendLog($"Cancel UI応答: {elapsed.TotalMilliseconds:N3} ms");
        };
        files.CurrentCellDirtyStateChanged += (_, _) =>
        {
            if (files.IsCurrentCellDirty)
            {
                files.CommitEdit(DataGridViewDataErrorContexts.Commit);
            }
        };
        files.CellValueChanged += (_, e) =>
        {
            if (files.Columns["Target"] is { } targetColumn &&
                e.ColumnIndex == targetColumn.Index)
            {
                UpdateSummary();
            }
        };
        WireDropTarget(this);
        WireDropTarget(inputPath);
        WireDropTarget(files);
    }

    private void WireDropTarget(Control control)
    {
        control.AllowDrop = true;
        control.DragEnter += (_, e) =>
        {
            e.Effect = IsRunning || e.Data?.GetDataPresent(DataFormats.FileDrop) != true
                ? DragDropEffects.None
                : DragDropEffects.Copy;
        };
        control.DragDrop += (_, e) =>
        {
            if (IsRunning)
            {
                showMessage("処理中は入力を変更できません。", "D&D", MessageBoxButtons.OK, MessageBoxIcon.None);
                return;
            }

            if (e.Data?.GetData(DataFormats.FileDrop) is string[] paths)
            {
                ApplyStartupPaths(paths);
            }
        };
    }

    private string[] DisplayedInputPaths() => inputPath.Text
        .Split(" | ", StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private ScanConditions ReadScanConditions()
    {
        var paths = DisplayedInputPaths();
        if (paths.Length == 0 || string.IsNullOrWhiteSpace(outputPath.Text))
        {
            throw new ArgumentException("入力と出力を指定してください。");
        }

        return ScanConditions.Create(paths, outputPath.Text, includeSubfolders.Checked);
    }

    private bool RefreshScanValidity()
    {
        ScanConditions? conditions;
        try
        {
            conditions = ReadScanConditions();
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or NotSupportedException)
        {
            conditions = null;
        }

        scan.Recheck(conditions);
        return conditions is not null && scan.CanStart;
    }

    private void ScanOptionsChanged()
    {
        if (!applyingPreset && !IsRunning)
        {
            runButton.Enabled = RefreshScanValidity();
            if (scan.RequiresRefresh)
            {
                progressLabel.Text = "一覧更新が必要";
            }
        }
    }

    private bool Scan()
    {
        try
        {
            var conditions = ReadScanConditions();
            if (conditions.Inputs.Any(path => !File.Exists(path) && !Directory.Exists(path)))
            {
                throw new DirectoryNotFoundException("存在しない入力が含まれています。");
            }

            if (File.Exists(outputPath.Text))
            {
                throw new IOException("出力先にファイルが存在します。");
            }

            var selections = scan.MatchesLastScan(conditions)
                ? files.Rows.Cast<DataGridViewRow>()
                    .Where(row => row.Tag is SourceItem)
                    .GroupBy(row => ((SourceItem)row.Tag!).FullPath, StringComparer.OrdinalIgnoreCase)
                    .ToDictionary(group => group.Key, group => group.Any(row => row.Cells["Target"].Value is true),
                        StringComparer.OrdinalIgnoreCase)
                : null;
            var result = FileScanner.ScanInputs(conditions.Inputs, outputPath.Text,
                includeSubfolders.Checked, AppendLog);
            RenderFileList(result, selections);
            scan.Succeeded(conditions);
            inputPaths = [.. conditions.Inputs];
            runButton.Enabled = true;
            progressLabel.Text = "待機中";
            AppendLog($"対象候補 {result.Sources.Count}件、除外 {result.Skipped.Count}件を読み込みました。");
            return true;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            scan.Failed();
            runButton.Enabled = false;
            progressLabel.Text = "一覧更新が必要";
            showMessage(exception.Message, "一覧更新エラー", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
    }

    private void RenderFileList(FileScanResult result, IReadOnlyDictionary<string, bool>? selections)
    {
        files.Rows.Clear();
        RefreshFileRowHeights();
        foreach (var source in result.Sources)
        {
            var index = files.Rows.Add(
                selections?.GetValueOrDefault(source.FullPath, true) ?? true,
                source.RelativePath,
                source.Extension,
                $"{source.Length / 1024d:N1} KiB",
                $"{source.Width} × {source.Height}",
                source.FrameCount,
                "対象");
            files.Rows[index].Tag = source;
        }

        foreach (var skipped in result.Skipped)
        {
            var index = files.Rows.Add(
                false,
                skipped.FullPath,
                Path.GetExtension(skipped.FullPath),
                string.Empty,
                string.Empty,
                string.Empty,
                $"Skipped: {skipped.Reason}");
            files.Rows[index].Cells["Target"].ReadOnly = true;
        }

        UpdateSummary();
    }

    private async Task RunAsync()
    {
        if (IsRunning)
        {
            return;
        }

        var generation = 0L;
        try
        {
            if (!RefreshScanValidity())
            {
                ScanOptionsChanged();
                return;
            }

            if (scan.IsUnscanned && !Scan())
            {
                return;
            }

            var selected = GetSelectedSources();
            if (selected.Length == 0)
            {
                throw new ArgumentException("処理対象の画像が選択されていません。");
            }

            var protectedSources = files.Rows.Cast<DataGridViewRow>()
                .Select(row => row.Tag).OfType<SourceItem>().ToArray();
            var request = CreateRequest();
            var protection = new InputProtection(protectedSources);
            var plans = OutputPlanner.Create(selected, request, fileExists: null, protectedSources: protectedSources,
                isProtectedAlias: protection.BlocksReplacement);
            var confirmed = ConfirmOverwrites(plans);
            if (IsDisposed || Disposing)
            {
                return;
            }

            generation = job.Begin();
            var jobLogs = new ConcurrentQueue<string>();
            SetRunning(true);
            progressBar.Maximum = Math.Max(1, plans.Count);
            progressBar.Value = 0;
            progressLabel.Text = "処理中";
            cancellation = new();
            var token = cancellation.Token;
            var rows = files.Rows.Cast<DataGridViewRow>().Where(row => row.Tag is SourceItem)
                .ToLookup(row => (SourceItem)row.Tag!);
            foreach (var source in selected)
            {
                foreach (var row in rows[source])
                {
                    row.Cells["Status"].Value = "待機中";
                }
            }

            var uiProgress = new Progress<CompressionProgress>(value =>
            {
                if (IsDisposed || Disposing || !job.AcceptsProgress(generation))
                {
                    return;
                }

                DrainLogs(jobLogs);
                progressBar.Value = Math.Min(progressBar.Maximum, value.Completed);
                var percent = value.Total == 0 ? 100 : (int)Math.Round(value.Completed * 100d / value.Total);
                progressLabel.Text = $"{value.Completed}/{value.Total} ({percent}%)";
            });
            processingTask = Task.Run(() => new CompressionService().Process(
                plans, request, plan => confirmed.GetValueOrDefault(plan.OutputPath),
                uiProgress, jobLogs.Enqueue, protectedSources, token));
            IReadOnlyList<CompressionResult> results;
            try
            {
                results = await processingTask;
            }
            finally
            {
                if (!IsDisposed && !Disposing)
                {
                    DrainLogs(jobLogs);
                }
            }

            if (IsDisposed || Disposing)
            {
                return;
            }

            var wasCancelled = token.IsCancellationRequested || results.Any(x => x.Status == ResultStatus.Cancelled);
            if (wasCancelled)
            {
                foreach (var source in selected)
                {
                    foreach (var row in rows[source])
                    {
                        row.Cells["Status"].Value = "キャンセル";
                    }
                }
            }

            foreach (var result in results)
            {
                foreach (var row in rows[result.Source])
                {
                    row.Cells["Status"].Value = result.Warnings is { Count: > 0 }
                        ? "警告あり" : result.Status.ToString();
                }
            }

            var status = wasCancelled ? "キャンセル" : "完了";
            progressLabel.Text = $"{status} / 警告 {results.Sum(x => x.Warnings?.Count ?? 0)}件";
            AppendLog(
                $"{progressLabel.Text}: 出力 {results.Count(x => x.Status is ResultStatus.Success or ResultStatus.Copied)}" +
                $" / スキップ {results.Count(x => x.Status == ResultStatus.Skipped)}" +
                $" / 失敗 {results.Count(x => x.Status == ResultStatus.Failed)} / 合計 {results.Count}");
        }
        catch (Exception exception)
        {
            if (!IsDisposed && !Disposing)
            {
                if (generation != 0)
                {
                    progressLabel.Text = "処理エラー";
                }

                AppendLog($"[ERROR] {exception.Message}");
                if (!job.CloseRequested)
                {
                    showMessage(exception.Message, "処理エラー", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }
        finally
        {
            if (generation != 0)
            {
                cancellation?.Dispose();
                cancellation = null;
                processingTask = null;
                var close = job.Finish();
                if (!IsDisposed && !Disposing)
                {
                    SetRunning(false);
                    if (close)
                    {
                        Close();
                    }
                }
            }
        }
    }

    private void DrainLogs(ConcurrentQueue<string> messages)
    {
        while (messages.TryDequeue(out var message))
        {
            AppendLog(message);
        }
    }

    private SourceItem[] GetSelectedSources() =>
        files.Rows
            .Cast<DataGridViewRow>()
            .Where(row => row.Tag is SourceItem && row.Cells["Target"].Value is true)
            .Select(row => (SourceItem)row.Tag!)
            .ToArray();

    private Dictionary<string, bool> ConfirmOverwrites(IEnumerable<OutputPlan> plans)
    {
        var confirmed = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        foreach (var plan in plans.Where(x => x.Action == PlanAction.Confirm))
        {
            confirmed[plan.OutputPath] = showMessage(
                $"{plan.OutputPath}\nを上書きしますか？",
                "上書き確認",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question) == DialogResult.Yes;
        }

        return confirmed;
    }

    private CompressionRequest CreateRequest()
    {
        if (inputPaths.Count == 0 || string.IsNullOrWhiteSpace(outputPath.Text) || File.Exists(outputPath.Text))
        {
            throw new ArgumentException("入力と出力を指定してください。");
        }

        var selectedFormat = (OutputFormat)format.SelectedItem!;
        var nonJpegPolicy = targetNonJpeg.SelectedIndex == 0
            ? TargetNonJpegPolicy.ConvertToJpeg
            : TargetNonJpegPolicy.Skip;
        return new()
        {
            InputRoot = ResolveInputRoot(inputPaths[0]),
            OutputRoot = Path.GetFullPath(outputPath.Text),
            MaxWidth = (int)maxWidth.Value,
            MaxHeight = (int)maxHeight.Value,
            Quality = (int)quality.Value,
            OutputFormat = selectedFormat,
            TargetSizeEnabled = targetEnabled.Checked,
            TargetBytes = checked((long)targetKibibytes.Value * 1024),
            TargetNonJpegPolicy = nonJpegPolicy,
            CollisionPolicy = (CollisionPolicy)collision.SelectedItem!,
            LargerOutputPolicy = (LargerOutputPolicy)largerPolicy.SelectedItem!,
            AlreadyWithinTargetPolicy = (AlreadyWithinTargetPolicy)withinTarget.SelectedItem!,
            IncludeSubfolders = includeSubfolders.Checked,
            PreserveHierarchy = preserveHierarchy.Checked,
            JpegBackgroundBlack = blackBackground.Checked,
        };
    }

    private void ApplySelectedPreset()
    {
        if (applyingPreset || preset.SelectedItem is not PresetDefinition selected)
        {
            return;
        }

        maxWidth.Value = selected.MaxWidth;
        maxHeight.Value = selected.MaxHeight;
        quality.Value = selected.Quality;
        format.SelectedItem = selected.Format;
    }

    private void LoadSettings()
    {
        applyingPreset = true;
        var settings = settingsStore.Load(out var warning);
        var definition = Presets.GetOrDefault(settings.SelectedPresetId);
        preset.SelectedItem = Presets.Items.Single(x => x.Id == definition.Id);
        maxWidth.Value = settings.Overrides.MaxWidth ?? definition.MaxWidth;
        maxHeight.Value = settings.Overrides.MaxHeight ?? definition.MaxHeight;
        quality.Value = settings.Overrides.Quality ?? definition.Quality;
        format.SelectedItem = settings.Overrides.Format ?? definition.Format;
        inputPaths = settings.InputPaths.Count > 0
            ? settings.InputPaths
            : string.IsNullOrWhiteSpace(settings.InputPath) ? [] : [settings.InputPath];
        UpdateInputDisplay();
        outputPath.Text = settings.OutputPath;
        targetEnabled.Checked = settings.TargetSizeEnabled;
        targetKibibytes.Value = Math.Clamp(settings.TargetKilobytes, 1, 1048576);
        targetNonJpeg.SelectedIndex =
            settings.TargetNonJpegPolicy == TargetNonJpegPolicy.ConvertToJpeg ? 0 : 1;
        collision.SelectedItem = settings.CollisionPolicy;
        largerPolicy.SelectedItem = settings.LargerOutputPolicy;
        withinTarget.SelectedItem = settings.AlreadyWithinTargetPolicy;
        includeSubfolders.Checked = settings.IncludeSubfolders;
        preserveHierarchy.Checked = settings.PreserveHierarchy;
        blackBackground.Checked = settings.JpegBackgroundBlack;
        RestoreWindow(settings);
        applyingPreset = false;
        if (warning is not null)
        {
            AppendLog(warning);
        }
    }

    private void SaveSettings()
    {
        var selected = preset.SelectedItem as PresetDefinition ?? Presets.Items[0];
        var displayedPaths = DisplayedInputPaths();
        var bounds = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
        settingsStore.Save(new()
        {
            SelectedPresetId = selected.Id,
            Overrides = new(
                (int)maxWidth.Value == selected.MaxWidth ? null : (int)maxWidth.Value,
                (int)maxHeight.Value == selected.MaxHeight ? null : (int)maxHeight.Value,
                (int)quality.Value == selected.Quality ? null : (int)quality.Value,
                (OutputFormat)format.SelectedItem! == selected.Format
                    ? null
                    : (OutputFormat)format.SelectedItem!),
            InputPath = displayedPaths.FirstOrDefault() ?? string.Empty,
            InputPaths = [.. displayedPaths],
            OutputPath = outputPath.Text,
            TargetSizeEnabled = targetEnabled.Checked,
            TargetKilobytes = (int)targetKibibytes.Value,
            TargetNonJpegPolicy = targetNonJpeg.SelectedIndex == 0
                ? TargetNonJpegPolicy.ConvertToJpeg
                : TargetNonJpegPolicy.Skip,
            CollisionPolicy = (CollisionPolicy)collision.SelectedItem!,
            LargerOutputPolicy = (LargerOutputPolicy)largerPolicy.SelectedItem!,
            AlreadyWithinTargetPolicy = (AlreadyWithinTargetPolicy)withinTarget.SelectedItem!,
            IncludeSubfolders = includeSubfolders.Checked,
            PreserveHierarchy = preserveHierarchy.Checked,
            JpegBackgroundBlack = blackBackground.Checked,
            WindowX = bounds.X,
            WindowY = bounds.Y,
            WindowWidth = bounds.Width,
            WindowHeight = bounds.Height,
        });
    }

    private void RestoreWindow(AppSettings settings)
    {
        if (settings.WindowX is not int x || settings.WindowY is not int y ||
            settings.WindowWidth is not int width || settings.WindowHeight is not int height ||
            width < MinimumSize.Width || height < MinimumSize.Height)
        {
            return;
        }

        var candidate = new Rectangle(x, y, width, height);
        if (WindowPlacement.IsVisible(
            new(x, y, width, height),
            Screen.AllScreens.Select(screen => new ScreenBounds(
                screen.WorkingArea.X,
                screen.WorkingArea.Y,
                screen.WorkingArea.Width,
                screen.WorkingArea.Height))))
        {
            StartPosition = FormStartPosition.Manual;
            Bounds = candidate;
        }
    }

    private void ApplyStartupPaths(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0)
        {
            return;
        }

        inputPaths = paths
            .Where(path => File.Exists(path) || Directory.Exists(path))
            .Select(Path.GetFullPath)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (inputPaths.Count == 0)
        {
            return;
        }

        UpdateInputDisplay();
        if (string.IsNullOrWhiteSpace(outputPath.Text))
        {
            outputPath.Text = Path.Combine(ResolveInputRoot(inputPaths[0]), "compressed");
        }

        Scan();
    }

    private void UpdateInputDisplay() =>
        inputPath.Text = string.Join(" | ", inputPaths);

    private void UpdateSummary()
    {
        var selected = GetSelectedSources();
        summaryLabel.Text = $"対象 {selected.Length}件 / {selected.Sum(x => x.Length) / 1024d:N1} KiB";
    }

    private void SetRunning(bool running)
    {
        foreach (var control in configurationControls)
        {
            control.Enabled = !running;
        }

        files.Enabled = !running;
        runButton.Enabled = !running && RefreshScanValidity();
        scanButton.Enabled = !running;
        cancelButton.Enabled = running;
    }

    private Button BrowseButton(TextBox target, string description, bool isInput)
    {
        var button = new Button { Text = "参照", AutoSize = true };
        button.Click += (_, _) =>
        {
            using var dialog = new FolderBrowserDialog
            {
                Description = description,
                SelectedPath = Directory.Exists(target.Text) ? target.Text : string.Empty,
            };
            if (dialog.ShowDialog(this) != DialogResult.OK)
            {
                return;
            }

            if (isInput)
            {
                inputPaths = [dialog.SelectedPath];
                UpdateInputDisplay();
                Scan();
            }
            else
            {
                target.Text = dialog.SelectedPath;
            }
        };
        return button;
    }

    private static string ResolveInputRoot(string path) =>
        Directory.Exists(path)
            ? Path.GetFullPath(path)
            : Path.GetDirectoryName(Path.GetFullPath(path))
                ?? throw new ArgumentException("入力rootを解決できません。", nameof(path));

    private static void AddOption(Control panel, string caption, Control control)
    {
        panel.Controls.Add(new Label { Text = caption, AutoSize = true, Margin = new(6, 7, 2, 0) });
        panel.Controls.Add(control);
    }

    private static NumericUpDown Number(decimal min, decimal max, decimal value) =>
        new() { Minimum = min, Maximum = max, Value = value, Width = 78 };

    private static ComboBox Combo(int width) =>
        new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = width };

    private static ComboBox EnumCombo<T>()
        where T : struct, Enum
    {
        var combo = Combo(120);
        combo.DataSource = Enum.GetValues<T>();
        return combo;
    }

    private bool IsRunning => job.IsRunning;

    private void AppendLog(string message) =>
        log.AppendText($"[{DateTime.Now:HH:mm:ss}] {message}{Environment.NewLine}");
}
