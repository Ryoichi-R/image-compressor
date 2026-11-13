using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.ExceptionServices;
using ImageCompressor.App;

namespace ImageCompressor.IntegrationTests;

public sealed class AccessibilityTests(Xunit.Abstractions.ITestOutputHelper output)
{
    private static readonly int[] RowCounts = [3, 100, 1000];

    [Fact]
    public void Fixed_names_are_faster_than_standard_names_for_a_thousand_rows() => RunSta(() =>
    {
        var measurements = new List<object>();
        var lastStandard = 0d;
        var lastFixed = 0d;
        foreach (var count in RowCounts)
        {
            using var standard = CreateGrid(useStandardCells: true);
            using var fixedGrid = CreateGrid();
            foreach (var grid in new[] { standard, fixedGrid })
            {
                for (var column = 2; column < 7; column++)
                {
                    grid.Columns.Add(new DataGridViewTextBoxColumn
                    {
                        CellTemplate = grid == standard ? new DataGridViewTextBoxCell() : new AccessibleTextBoxCell(),
                    });
                }

                for (var index = 0; index < count; index++)
                {
                    grid.Rows.Add(true, "synthetic", "jpg", "size", "dimensions", "frames", "status");
                }
            }

            var standardTimes = new List<double>();
            var fixedTimes = new List<double>();
            for (var trial = 0; trial < 3; trial++)
            {
                standardTimes.Add(SweepNames(standard));
                fixedTimes.Add(SweepNames(fixedGrid));
            }

            lastStandard = standardTimes.Order().ElementAt(1);
            lastFixed = fixedTimes.Order().ElementAt(1);
            measurements.Add(new { rows = count, standard_ms = standardTimes, fixed_ms = fixedTimes });
        }

        output.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { measurements, scope = "in-process cell/row/header Name and sibling navigation; not UIA transport or cancel latency" }));
        Assert.True(lastFixed < lastStandard * 0.5, $"Fixed {lastFixed}ms; standard {lastStandard}ms");
    });

    [Fact]
    public void Names_follow_visible_order_sorting_and_mutations() => RunSta(() =>
    {
        using var grid = CreateGrid();
        grid.Rows.Add(true, "C");
        grid.Rows.Add(false, "A");
        grid.Rows.Add(true, "B");
        var original = grid.Rows[2].Cells[1].AccessibilityObject;
        Assert.Contains("行 3", original.Name);
        Assert.Equal("行 3", grid.Rows[2].AccessibilityObject.Name);
        Assert.Equal(grid.Rows[2].AccessibilityObject.Name, grid.Rows[2].HeaderCell.AccessibilityObject.Name);
        grid.Rows[0].Visible = false;
        Assert.Contains("行 2", original.Name);
        Assert.Same(grid.Rows[2].AccessibilityObject,
            grid.Rows[1].AccessibilityObject.Navigate(AccessibleNavigation.Next));
        Assert.Same(grid.Rows[1].AccessibilityObject,
            grid.Rows[2].AccessibilityObject.Navigate(AccessibleNavigation.Previous));
        grid.Rows[0].Visible = true;
        Assert.Contains("行 3", original.Name);
        grid.Sort(grid.Columns[1], ListSortDirection.Ascending);
        Assert.Contains("行 2", original.Name);
        Assert.Contains("昇順", original.Name);
        grid.Rows.Insert(0, false, "0");
        Assert.Contains("行 3", original.Name);
        grid.Rows.RemoveAt(0);
        Assert.Contains("行 2", original.Name);
        grid.Columns[1].HeaderText = "変更後";
        Assert.StartsWith("変更後", original.Name);
        grid.Rows.Clear();
        grid.Rows.Add(false, "new");
        Assert.Contains("行 1", grid.Rows[0].Cells[1].AccessibilityObject.Name);
    });

    [Fact]
    public void Standard_checkbox_action_value_focus_and_navigation_are_preserved() => RunSta(() =>
    {
        using var grid = CreateGrid();
        grid.Rows.Add(false, "value");
        using var form = new Form();
        form.Controls.Add(grid);
        _ = form.Handle;
        _ = grid.Handle;
        grid.CurrentCell = grid.Rows[0].Cells[0];
        var checkbox = grid.CurrentCell.AccessibilityObject;
        using var standard = CreateGrid(useStandardCells: true);
        standard.Rows.Add(false, "value");
        var standardCheckbox = standard.Rows[0].Cells[0].AccessibilityObject;
        Assert.Equal(standardCheckbox.Role, checkbox.Role);
        Assert.NotNull(checkbox.Parent);
        Assert.NotNull(checkbox.DefaultAction);
        checkbox.DoDefaultAction();
        grid.EndEdit();
        Assert.Equal(true, grid.CurrentCell.Value);
        Assert.Equal("value", grid.Rows[0].Cells[1].AccessibilityObject.Value);
        Assert.Contains("対象 行 1", checkbox.Name);
        Assert.True((checkbox.State & AccessibleStates.Focusable) != 0);
    });

    [Fact]
    public void A_thousand_row_name_sweep_completes_without_nested_visible_search() => RunSta(() =>
    {
        using var grid = CreateGrid();
        for (var index = 0; index < 1000; index++)
        {
            grid.Rows.Add(index % 2 == 0, index.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }

        var timer = Stopwatch.StartNew();
        foreach (DataGridViewRow row in grid.Rows)
        {
            Assert.False(string.IsNullOrWhiteSpace(row.AccessibilityObject.Name));
            Assert.False(string.IsNullOrWhiteSpace(row.HeaderCell.AccessibilityObject.Name));
            _ = row.AccessibilityObject.Navigate(AccessibleNavigation.Next);
            foreach (DataGridViewCell cell in row.Cells)
            {
                Assert.False(string.IsNullOrWhiteSpace(cell.AccessibilityObject.Name));
            }
        }

        Assert.True(timer.Elapsed < TimeSpan.FromSeconds(5), $"Name sweep took {timer.Elapsed}");
        Assert.Contains("行 1000", grid.Rows[999].Cells[0].AccessibilityObject.Name);
        Assert.Contains("行 1000", grid.Rows[999].Cells[1].AccessibilityObject.Name);
    });

    private static double SweepNames(DataGridView grid)
    {
        var timer = Stopwatch.StartNew();
        foreach (DataGridViewRow row in grid.Rows)
        {
            Assert.False(string.IsNullOrWhiteSpace(row.AccessibilityObject.Name));
            Assert.False(string.IsNullOrWhiteSpace(row.HeaderCell.AccessibilityObject.Name));
            _ = row.AccessibilityObject.Navigate(AccessibleNavigation.Next);
            foreach (DataGridViewCell cell in row.Cells)
            {
                Assert.False(string.IsNullOrWhiteSpace(cell.AccessibilityObject.Name));
            }
        }

        return timer.Elapsed.TotalMilliseconds;
    }

    private static DataGridView CreateGrid(bool useStandardCells = false)
    {
        var grid = new DataGridView { AllowUserToAddRows = false };
        if (!useStandardCells)
        {
            grid.RowTemplate = new AccessibleFileRow();
        }
        grid.Columns.Add(new DataGridViewCheckBoxColumn
        {
            Name = "Target",
            HeaderText = "対象",
            CellTemplate = useStandardCells ? new DataGridViewCheckBoxCell() : new AccessibleCheckBoxCell(),
        });
        grid.Columns.Add(new DataGridViewTextBoxColumn
        {
            Name = "File",
            HeaderText = "ファイル",
            CellTemplate = useStandardCells ? new DataGridViewTextBoxCell() : new AccessibleTextBoxCell(),
        });
        return grid;
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
        Assert.True(thread.Join(TimeSpan.FromSeconds(90)), "STA test timed out");
        if (error is not null)
        {
            ExceptionDispatchInfo.Capture(error).Throw();
        }
    }
}
