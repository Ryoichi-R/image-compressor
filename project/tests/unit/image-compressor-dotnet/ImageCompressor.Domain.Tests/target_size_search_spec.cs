using ImageCompressor.Domain;

namespace ImageCompressor.Domain.Tests;

public sealed class TargetSizeSearchSpec
{
    [Fact]
    public void Search_returns_best_tested_quality_under_target_and_memoizes()
    {
        var calls = new Dictionary<(int Width, int Height, int Quality), int>();
        EncodedCandidate Encoder(int width, int height, int quality)
        {
            var key = (width, height, quality);
            calls[key] = calls.GetValueOrDefault(key) + 1;
            var size = quality == 73 ? 900 : quality * 20;
            return new(new byte[size], width, height, quality);
        }

        var result = TargetSizeSearch.Search(
            new(1024, 100, 100, 90, LocalSweepCount: 3),
            Encoder);

        Assert.NotNull(result.Candidate);
        Assert.True(result.Candidate.Bytes.Length <= 1024);
        Assert.All(calls.Values, count => Assert.Equal(1, count));
    }

    [Fact]
    public void Search_honors_attempt_limit()
    {
        var result = TargetSizeSearch.Search(
            new(1024, 100, 100, 100, MaximumAttempts: 2),
            (width, height, quality) => new(new byte[2048], width, height, quality));

        Assert.True(result.LimitReached);
        Assert.Equal(2, result.Attempts);
    }
}
