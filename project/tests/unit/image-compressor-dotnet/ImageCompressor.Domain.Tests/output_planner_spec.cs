using ImageCompressor.Domain;

namespace ImageCompressor.Domain.Tests;

public sealed class OutputPlannerSpec
{
    [Fact]
    public void Create_reserves_duplicate_names_with_three_digit_suffix()
    {
        var root = Path.GetFullPath("output");
        var sources = new[]
        {
            Source("a/photo.png"),
            Source("b/photo.jpg"),
        };
        var request = Request(root);

        var plans = OutputPlanner.Create(sources, request, _ => false);

        Assert.Equal("photo.jpg", plans[0].OutputName);
        Assert.Equal("photo_001.jpg", plans[1].OutputName);
    }

    [Fact]
    public void Create_preserves_relative_hierarchy()
    {
        var root = Path.GetFullPath("output");
        var request = Request(root, preserveHierarchy: true);

        var plan = Assert.Single(OutputPlanner.Create([Source("nested/photo.png")], request, _ => false));

        Assert.Equal(
            Path.Combine(root, "nested", "photo.jpg"),
            plan.OutputPath);
    }

    [Theory]
    [InlineData(CollisionPolicy.Skip, PlanAction.Skip)]
    [InlineData(CollisionPolicy.Overwrite, PlanAction.Overwrite)]
    [InlineData(CollisionPolicy.Confirm, PlanAction.Confirm)]
    public void Create_maps_existing_file_policy(CollisionPolicy policy, PlanAction action)
    {
        var request = Request(Path.GetFullPath("output"), policy: policy);

        var plan = Assert.Single(OutputPlanner.Create([Source("photo.png")], request, _ => true));

        Assert.Equal(action, plan.Action);
    }

    private static SourceItem Source(string relativePath) =>
        new(
            Path.GetFullPath("input"),
            Path.GetFullPath(Path.Combine("input", relativePath)),
            relativePath.Replace('/', Path.DirectorySeparatorChar),
            Path.GetExtension(relativePath),
            100,
            100,
            100,
            1);

    private static CompressionRequest Request(
        string output,
        bool preserveHierarchy = false,
        CollisionPolicy policy = CollisionPolicy.AutoRename) =>
        new()
        {
            InputRoot = Path.GetFullPath("input"),
            OutputRoot = output,
            PreserveHierarchy = preserveHierarchy,
            CollisionPolicy = policy,
        };
}
