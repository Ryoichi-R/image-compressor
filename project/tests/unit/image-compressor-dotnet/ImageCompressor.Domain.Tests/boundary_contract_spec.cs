using ImageCompressor.Domain;

namespace ImageCompressor.Domain.Tests;

public sealed class BoundaryContractSpec
{
    [Fact]
    public void Planner_rejects_rooted_hierarchy_and_invalid_format_and_preserves_skip_reason()
    {
        var root = Path.GetFullPath("synthetic-input");
        var source = new SourceItem(root, Path.Combine(root, "one.png"), "one.png", ".png", 10, 1, 1, 1);
        var request = new CompressionRequest { InputRoot = root, OutputRoot = Path.GetFullPath("synthetic-output"), PreserveHierarchy = true, CollisionPolicy = CollisionPolicy.Skip };
        var plan = Assert.Single(OutputPlanner.Create([source], request, _ => true));
        Assert.Equal(PlanAction.Skip, plan.Action);
        Assert.True(plan.TargetExisted);
        Assert.Contains("既存", plan.Reason);
        Assert.Throws<InvalidOperationException>(() => OutputPlanner.Create([source with { RelativePath = Path.Combine(root, "outside", "one.png") }], request));
        Assert.Throws<ArgumentOutOfRangeException>(() => OutputPlanner.GetExtension((OutputFormat)999));
    }
    [Fact]
    public void Requests_reject_empty_roots_invalid_dimensions_quality_and_target()
    {
        Assert.Throws<ArgumentException>(() => new CompressionRequest { InputRoot = " ", OutputRoot = "output" }.Validate());
        Assert.Throws<ArgumentException>(() => new CompressionRequest { InputRoot = "input", OutputRoot = " " }.Validate());
        Assert.Throws<ArgumentOutOfRangeException>(() => new CompressionRequest { InputRoot = "input", OutputRoot = "output", MaxWidth = 0 }.Validate());
        Assert.Throws<ArgumentOutOfRangeException>(() => new CompressionRequest { InputRoot = "input", OutputRoot = "output", MaxHeight = 0 }.Validate());
        Assert.Throws<ArgumentOutOfRangeException>(() => new CompressionRequest { InputRoot = "input", OutputRoot = "output", Quality = 101 }.Validate());
        Assert.Throws<ArgumentOutOfRangeException>(() => new CompressionRequest { InputRoot = "input", OutputRoot = "output", TargetSizeEnabled = true, TargetBytes = 1023 }.Validate());
    }

    [Fact]
    public void Invalid_resize_inputs_and_zero_original_size_are_reported()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => ResizeCalculator.Calculate(0, 1, 1, 1));
        Assert.Throws<ArgumentOutOfRangeException>(() => ResizeCalculator.Calculate(1, 1, 0, 1));
        Assert.Contains("計算できません", SizeChangeFormatter.Format(0, 10));
        Assert.Contains("増加", SizeChangeFormatter.Format(10, 20));
    }

    [Fact]
    public void Search_reports_unreachable_target_and_invalid_contract_without_unbounded_work()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => TargetSizeSearch.Search(new(1023, 1, 1, 75), (_, _, _) => throw new InvalidOperationException()));
        var result = TargetSizeSearch.Search(new(1024, 1, 1, 75), (width, height, quality) => new(new byte[1025], width, height, quality));
        Assert.Null(result.Candidate);
        Assert.False(result.LimitReached);
        Assert.InRange(result.Attempts, 1, 64);
    }
}
