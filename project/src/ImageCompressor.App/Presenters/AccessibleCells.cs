using System.Globalization;

namespace ImageCompressor.App;

// Keep the standard providers (including checkbox Toggle, selection and focus).
// Only the name avoids WinForms' repeated visible-row searches on large lists.
internal sealed class AccessibleTextBoxCell : DataGridViewTextBoxCell
{
    public AccessibleTextBoxCell() { }

    protected override AccessibleObject CreateAccessibilityInstance() => new CellAccessibleObject(this);

    private sealed class CellAccessibleObject(DataGridViewCell cell) : DataGridViewTextBoxCellAccessibleObject(cell)
    {
        public override string? Name => Owner is { } owner ? AccessibleCellNames.GetName(owner) : string.Empty;
    }
}

internal sealed class AccessibleCheckBoxCell : DataGridViewCheckBoxCell
{
    public AccessibleCheckBoxCell() { }

    protected override AccessibleObject CreateAccessibilityInstance() => new CellAccessibleObject(this);

    private sealed class CellAccessibleObject(DataGridViewCell cell) : DataGridViewCheckBoxCellAccessibleObject(cell)
    {
        public override string? Name => Owner is { } owner ? AccessibleCellNames.GetName(owner) : string.Empty;
    }
}

internal sealed class AccessibleFileRow : DataGridViewRow
{
    public AccessibleFileRow() { }

    protected override AccessibleObject CreateAccessibilityInstance() => new RowAccessibleObject(this);

    private sealed class RowAccessibleObject(DataGridViewRow row) : DataGridViewRowAccessibleObject(row)
    {
        public override string Name => Owner is { Visible: true } owner
            ? string.Format(CultureInfo.CurrentCulture, "行 {0}", AccessibleCellNames.GetVisibleIndex(owner) + 1)
            : "行 -1";

        public override AccessibleObject? Navigate(AccessibleNavigation direction)
        {
            if (Owner is not { Visible: true, DataGridView: { } grid } owner)
            {
                return null;
            }

            if (direction is AccessibleNavigation.Next or AccessibleNavigation.Down)
            {
                var next = grid.Rows.GetNextRow(owner.Index, DataGridViewElementStates.Visible);
                return next >= 0 ? grid.Rows[next].AccessibilityObject : null;
            }

            if (direction is AccessibleNavigation.Previous or AccessibleNavigation.Up)
            {
                var previous = grid.Rows.GetPreviousRow(owner.Index, DataGridViewElementStates.Visible);
                return previous >= 0 ? grid.Rows[previous].AccessibilityObject
                    : grid.ColumnHeadersVisible ? Parent?.GetChild(0) : null;
            }

            return base.Navigate(direction);
        }
    }
}

internal static class AccessibleCellNames
{
    internal static string GetName(DataGridViewCell cell)
    {
        var grid = cell.DataGridView;
        var column = cell.OwningColumn;
        var row = cell.OwningRow;
        if (grid is null || column is null || row is null || row.Index < 0)
        {
            return string.Empty;
        }

        var visibleIndex = GetVisibleIndex(row);
        var name = string.Format(CultureInfo.CurrentCulture, "{0} 行 {1}", column.HeaderText, visibleIndex + 1);
        if (column.SortMode != DataGridViewColumnSortMode.NotSortable)
        {
            name += grid.SortedColumn == column && grid.SortOrder != SortOrder.None
                ? grid.SortOrder == SortOrder.Ascending ? ", 昇順" : ", 降順"
                : ", 未ソート";
        }

        return name;
    }

    internal static int GetVisibleIndex(DataGridViewRow row)
    {
        if (row is not { Visible: true, Index: >= 0, DataGridView: { } grid })
        {
            return -1;
        }

        // WinForms invalidates its own count on visibility/order mutations.
        // The common all-visible case needs no scan and no application cache.
        if (grid.Rows.GetRowCount(DataGridViewElementStates.Visible) == grid.Rows.Count)
        {
            return row.Index;
        }

        var visibleIndex = -1;
        for (var index = 0; index <= row.Index; index++)
        {
            if ((grid.Rows.GetRowState(index) & DataGridViewElementStates.Visible) != 0)
            {
                visibleIndex++;
            }
        }

        return visibleIndex;
    }
}
