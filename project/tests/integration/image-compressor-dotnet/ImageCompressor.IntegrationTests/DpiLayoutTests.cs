using System.Runtime.ExceptionServices;
using ImageCompressor.App;

namespace ImageCompressor.IntegrationTests;

public sealed class DpiLayoutTests
{
    private static readonly float[] ScaleSequence = [1.5F, 2F, 1.75F, 1F, 2F, 1F];
    private static readonly float[] RowScaleSequence = [1F, 1.5F, 2F, 1.5F, 1F, 2F, 1F];
    private static readonly object[] SampleRow = [true, "fixture-0000.png", ".png", "44.7 KiB", "1920 × 1080", 1, "対象"];

    [Theory]
    [InlineData(true, 1000)]
    [InlineData(false, 1000)]
    [InlineData(false, 1)]
    public void Data_rows_fit_scaled_fonts_when_loaded_before_or_after_change(bool loadedBefore, int count) => RunSta(() =>
    {
        using var seed = new PortableSeed();
        using var form = new MainForm([], false);
        var grid = Descendants(form).OfType<DataGridView>().Single();
        _ = grid.Handle;
        var baselineFont = grid.Font;
        var baselineHeight = grid.RowTemplate.Height;
        if (loadedBefore)
        {
            for (var index = 0; index < count; index++) grid.Rows.Add(SampleRow);
        }

        foreach (var scale in RowScaleSequence)
        {
            if (!loadedBefore) grid.Rows.Clear();
            using var scaledFont = new Font(baselineFont.FontFamily, baselineFont.SizeInPoints * scale);
            grid.Font = scaledFont;
            if (!loadedBefore)
            {
                for (var index = 0; index < count; index++) grid.Rows.Add(SampleRow);
            }

            form.PerformLayout();
            foreach (var index in new[] { 0, count / 2, count - 1 }.Distinct())
            {
                var row = grid.Rows[index];
                var preferred = row.Cells.Cast<DataGridViewCell>().Max(cell => cell.PreferredSize.Height);
                Assert.True(row.Height >= preferred,
                    $"scale {scale}, row {index}: height {row.Height}, preferred {preferred}");
                Assert.Equal(grid.RowTemplate.Height, row.Height);
            }

            Assert.Equal(count, grid.Rows.Count);
            grid.Font = baselineFont;
        }

        Assert.Equal(baselineHeight, grid.RowTemplate.Height);
    });

    [Theory]
    [InlineData(0)]
    [InlineData(1000)]
    public void Column_headers_follow_scaled_header_fonts_without_clipping(int rows) => RunSta(() =>
    {
        using var seed = new PortableSeed();
        using var form = new MainForm([], false);
        var grid = Descendants(form).OfType<DataGridView>().Single();
        Assert.Equal(7, grid.Columns.Count);
        if (rows > 0)
        {
            grid.Rows.Add(rows);
        }

        _ = grid.Handle;
        var baselineFont = form.Font;
        var baselineHeight = grid.ColumnHeadersHeight;
        foreach (var scale in ScaleSequence)
        {
            using var scaledFont = new Font(baselineFont.FontFamily, baselineFont.SizeInPoints * scale);
            // Isolate the header-content resize contract from synthetic Form.Scale font caching.
            // Existing tests cover whole-form scaling; actual DPI changes remain an ARM gate.
            grid.ColumnHeadersDefaultCellStyle.Font = scaledFont;
            form.PerformLayout();
            var preferredHeight = grid.Columns.Cast<DataGridViewColumn>()
                .Max(column => column.HeaderCell.PreferredSize.Height);
            Assert.True(grid.ColumnHeadersHeight >= preferredHeight,
                $"scale {scale}: header {grid.ColumnHeadersHeight}, preferred {preferredHeight}");
            Assert.Equal(rows, grid.Rows.Count);
            grid.ColumnHeadersDefaultCellStyle.Font = baselineFont;
        }

        Assert.Equal(baselineHeight, grid.ColumnHeadersHeight);
    });

    [Fact]
    public void Form_scales_numeric_fields_from_a_96_dpi_baseline() => RunSta(() =>
    {
        using var seed = new PortableSeed();
        using var form = new MainForm([], false);
        Assert.Equal(AutoScaleMode.Dpi, form.AutoScaleMode);
        var numbers = Descendants(form).OfType<NumericUpDown>().ToArray();
        Assert.Equal(4, numbers.Length);
        var values = numbers.Select(control => control.Value).ToArray();
        var baselineFont = form.Font;
        var previousScale = 1F;
        foreach (var scale in ScaleSequence)
        {
            // Exercise control layout ratios; actual monitor DPI changes need GUI acceptance.
            var factor = scale / previousScale;
            form.Scale(new SizeF(factor, factor));
            using var scaledFont = new Font(baselineFont.FontFamily, baselineFont.SizeInPoints * scale);
            form.Font = scaledFont;
            for (var index = 0; index < numbers.Length; index++)
            {
                Assert.Equal(values[index], numbers[index].Value);
                Assert.Equal(0, numbers[index].DecimalPlaces);
                AssertMaximumFits(numbers[index]);
            }

            form.Font = baselineFont;
            previousScale = scale;
        }
    });

    [Fact]
    public void Maximum_numeric_values_fit_at_a_synthetic_200_percent_scale() => RunSta(() =>
    {
        using var seed = new PortableSeed();
        using var form = new MainForm([], false);
        var current = form.CurrentAutoScaleDimensions;
        form.AutoScaleDimensions = new(current.Width / 2F, current.Height / 2F);
        form.PerformAutoScale();
        using var largeFont = new Font(form.Font.FontFamily, form.Font.SizeInPoints * 2F);
        form.Font = largeFont;
        foreach (var number in Descendants(form).OfType<NumericUpDown>())
        {
            AssertMaximumFits(number);
        }
    });

    [Theory]
    [InlineData(1.5F)]
    [InlineData(2F)]
    public void Scaled_layout_reflows_when_outer_window_is_constrained(float scale) => RunSta(() =>
    {
        using var seed = new PortableSeed();
        using var form = new MainForm([], false);
        var originalFont = form.Font;
        form.Scale(new SizeF(scale, scale));
        using var scaledFont = new Font(originalFont.FontFamily, originalFont.SizeInPoints * scale);
        form.Font = scaledFont;
        // Model the ARM display's width cap after the controls have scaled.
        form.Width = 2194;
        form.PerformLayout();
        var root = form.Controls.OfType<TableLayoutPanel>().Single();
        foreach (Control panel in root.Controls)
        {
            Assert.True(panel.Right <= root.ClientSize.Width, $"{panel.GetType().Name}: right {panel.Right}, client {root.ClientSize.Width}");
        }

        foreach (var button in Descendants(form).OfType<Button>())
        {
            Assert.True(button.Right <= button.Parent!.ClientSize.Width, $"{button.Text}: right {button.Right}, parent {button.Parent.ClientSize.Width}");
        }

        foreach (var number in Descendants(form).OfType<NumericUpDown>())
        {
            AssertMaximumFits(number);
        }

        form.Font = originalFont;
    });

    [Theory]
    [InlineData(0, 40, 2196, 1384)]
    [InlineData(-1280, 0, 1280, 720)]
    public void Oversized_restored_window_fits_the_selected_work_area(int x, int y, int width, int height) => RunSta(() =>
    {
        using var seed = new PortableSeed();
        using var form = new MainForm([], false);
        var numbers = Descendants(form).OfType<NumericUpDown>().ToArray();
        var values = numbers.Select(number => number.Value).ToArray();
        form.MinimumSize = new(2400, 1800);
        form.Bounds = new(x - 100, y + 100, 2600, 1900);
        var workingArea = new Rectangle(x, y, width, height);
        form.ConstrainToWorkingArea(workingArea);
        Assert.True(workingArea.Contains(form.Bounds), $"window {form.Bounds}, working area {workingArea}");
        Assert.True(form.MinimumSize.Width <= width && form.MinimumSize.Height <= height);
        Assert.Equal(values, numbers.Select(number => number.Value));
    });

    [Fact]
    public void Work_area_constraint_preserves_an_already_fitting_window() => RunSta(() =>
    {
        using var seed = new PortableSeed();
        using var form = new MainForm([], false);
        form.Bounds = new(60, 80, 1100, 800);
        var original = form.Bounds;
        form.ConstrainToWorkingArea(new(0, 40, 1920, 1040));
        Assert.Equal(original, form.Bounds);
    });

    private static void AssertMaximumFits(NumericUpDown number)
    {
        var previousValue = number.Value;
        number.Value = number.Maximum;
        var editor = number.Controls.OfType<TextBox>().Single();
        var textWidth = TextRenderer.MeasureText(editor.Text, editor.Font, Size.Empty, TextFormatFlags.NoPadding).Width;
        Assert.True(editor.ClientSize.Width >= textWidth, $"{number.Maximum}: editor {editor.ClientSize.Width}, text {textWidth}");
        Assert.Equal(number.Maximum, number.Value);
        number.Value = previousValue;
    }

    private static IEnumerable<Control> Descendants(Control parent)
    {
        foreach (Control control in parent.Controls)
        {
            yield return control;
            foreach (var child in Descendants(control))
            {
                yield return child;
            }
        }
    }

    private static void RunSta(Action action)
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
        Assert.True(thread.Join(TimeSpan.FromSeconds(30)), "STA layout test timed out");
        if (error is not null)
        {
            ExceptionDispatchInfo.Capture(error).Throw();
        }
    }

    private sealed class PortableSeed : IDisposable
    {
        private readonly string path = Path.Combine(AppContext.BaseDirectory, "settings.json");

        public PortableSeed()
        {
            using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write);
            stream.Write("{}"u8);
        }

        public void Dispose() => File.Delete(path);
    }
}
