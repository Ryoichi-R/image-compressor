using ImageCompressor.Domain;

namespace ImageCompressor.Domain.Tests;

public sealed class ResizeCalculatorSpec
{
    [Theory]
    [InlineData(4000, 2000, 1000, 1000, 1000, 500)]
    [InlineData(2, 1000, 1, 1, 1, 1)]
    [InlineData(200, 100, 400, 400, 200, 100)]
    public void Calculate_preserves_ratio_and_never_returns_zero(
        int width,
        int height,
        int maxWidth,
        int maxHeight,
        int expectedWidth,
        int expectedHeight)
    {
        var actual = ResizeCalculator.Calculate(width, height, maxWidth, maxHeight);

        Assert.Equal(expectedWidth, actual.Width);
        Assert.Equal(expectedHeight, actual.Height);
    }

    [Fact]
    public void SizeChangeFormatter_distinguishes_reduction_and_increase()
    {
        Assert.Contains("削減", SizeChangeFormatter.Format(100, 50), StringComparison.Ordinal);
        Assert.Contains("増加", SizeChangeFormatter.Format(100, 150), StringComparison.Ordinal);
    }
}
