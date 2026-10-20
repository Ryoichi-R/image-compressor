using ImageCompressor.Domain;

namespace ImageCompressor.Domain.Tests;

public sealed class ContractsSpec
{
    [Fact]
    public void Validate_accepts_minimum_target_and_rejects_one_byte_less()
    {
        Request(CompressionRequest.MinimumTargetBytes).Validate();

        Assert.Throws<ArgumentOutOfRangeException>(
            () => Request(CompressionRequest.MinimumTargetBytes - 1).Validate());
    }

    [Fact]
    public void Target_search_observes_target_byte_boundary()
    {
        var result = TargetSizeSearch.Search(
            new(1024, 10, 10, 11, MinimumQuality: 10),
            (width, height, quality) =>
                new(new byte[quality == 11 ? 1025 : 1024], width, height, quality));

        Assert.NotNull(result.Candidate);
        Assert.Equal(1024, result.Candidate.Bytes.Length);
        Assert.Equal(10, result.Candidate.Quality);
    }

    [Fact]
    public void Output_planner_rejects_parent_path_escape()
    {
        var source = new SourceItem(
            Path.GetFullPath("input"),
            Path.GetFullPath("input/photo.png"),
            Path.Combine("..", "photo.png"),
            ".png",
            1,
            1,
            1,
            1);
        var request = new CompressionRequest
        {
            InputRoot = Path.GetFullPath("input"),
            OutputRoot = Path.GetFullPath("output"),
            PreserveHierarchy = true,
        };

        Assert.Throws<InvalidOperationException>(
            () => OutputPlanner.Create([source], request, _ => false));
    }

    [Theory]
    [InlineData(0, 0, 900, 700, true)]
    [InlineData(1856, 0, 900, 700, true)]
    [InlineData(1857, 0, 900, 700, false)]
    public void Window_visibility_requires_64_pixel_intersection(
        int x,
        int y,
        int width,
        int height,
        bool expected)
    {
        var visible = WindowPlacement.IsVisible(
            new(x, y, width, height),
            [new(0, 0, 1920, 1080)]);

        Assert.Equal(expected, visible);
    }

    [Fact]
    public void Effective_output_format_converts_non_jpeg_target_mode_in_domain()
    {
        var request = new CompressionRequest
        {
            InputRoot = Path.GetFullPath("input"),
            OutputRoot = Path.GetFullPath("output"),
            OutputFormat = OutputFormat.Png,
            TargetSizeEnabled = true,
            TargetNonJpegPolicy = TargetNonJpegPolicy.ConvertToJpeg,
        };

        Assert.Equal(OutputFormat.Jpeg, request.GetEffectiveOutputFormat());
        var plan = Assert.Single(OutputPlanner.Create(
            [
                new(
                    request.InputRoot,
                    Path.Combine(request.InputRoot, "photo.png"),
                    "photo.png",
                    ".png",
                    100,
                    10,
                    10,
                    1),
            ],
            request,
            _ => false));
        Assert.EndsWith(".jpg", plan.OutputPath, StringComparison.OrdinalIgnoreCase);
    }

    private static CompressionRequest Request(long targetBytes) =>
        new()
        {
            InputRoot = Path.GetFullPath("input"),
            OutputRoot = Path.GetFullPath("output"),
            TargetSizeEnabled = true,
            TargetBytes = targetBytes,
        };
}
