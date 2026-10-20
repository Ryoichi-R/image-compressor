namespace ImageCompressor.Domain;

public sealed record EncodedCandidate(
    byte[] Bytes,
    int Width,
    int Height,
    int Quality);

public sealed record TargetSizeSearchResult(
    EncodedCandidate? Candidate,
    int Attempts,
    bool LimitReached);

public sealed record TargetSizeSearchOptions(
    long TargetBytes,
    int InitialWidth,
    int InitialHeight,
    int MaximumQuality,
    int MinimumQuality = CompressionRequest.MinimumQuality,
    int MaximumAttempts = CompressionRequest.MaximumEncodeAttempts,
    int LocalSweepCount = CompressionRequest.LocalSweepCount,
    double DimensionScale = 0.85d);

public static class TargetSizeSearch
{
    public static TargetSizeSearchResult Search(
        TargetSizeSearchOptions options,
        Func<int, int, int, EncodedCandidate> encoder,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(encoder);
        if (options.TargetBytes < CompressionRequest.MinimumTargetBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(options), "目標容量が下限未満です。");
        }

        var cache = new Dictionary<(int Width, int Height, int Quality), EncodedCandidate>();
        EncodedCandidate? best = null;
        var attempts = 0;
        var width = Math.Max(1, options.InitialWidth);
        var height = Math.Max(1, options.InitialHeight);

        EncodedCandidate Encode(int candidateWidth, int candidateHeight, int quality)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var key = (candidateWidth, candidateHeight, quality);
            if (cache.TryGetValue(key, out var cached))
            {
                return cached;
            }

            if (attempts >= options.MaximumAttempts)
            {
                throw new AttemptLimitException();
            }

            var encoded = encoder(candidateWidth, candidateHeight, quality);
            cache.Add(key, encoded);
            attempts++;
            if (encoded.Bytes.LongLength <= options.TargetBytes &&
                (best is null ||
                 encoded.Width * (long)encoded.Height > best.Width * (long)best.Height ||
                 (encoded.Width == best.Width &&
                  encoded.Height == best.Height &&
                  encoded.Quality > best.Quality)))
            {
                best = encoded;
            }

            return encoded;
        }

        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var highCandidate = Encode(width, height, options.MaximumQuality);
                if (highCandidate.Bytes.LongLength <= options.TargetBytes)
                {
                    best = highCandidate;
                    break;
                }

                var low = options.MinimumQuality;
                var high = options.MaximumQuality - 1;
                while (low <= high)
                {
                    var quality = low + ((high - low) / 2);
                    var candidate = Encode(width, height, quality);
                    if (candidate.Bytes.LongLength <= options.TargetBytes)
                    {
                        low = quality + 1;
                    }
                    else
                    {
                        high = quality - 1;
                    }
                }

                if (best is not null && best.Width == width && best.Height == height)
                {
                    for (var quality = best.Quality + 1;
                         quality <= Math.Min(options.MaximumQuality, best.Quality + options.LocalSweepCount);
                         quality++)
                    {
                        Encode(width, height, quality);
                    }

                    break;
                }

                if (width == 1 && height == 1)
                {
                    break;
                }

                width = Math.Max(1, (int)Math.Floor(width * options.DimensionScale));
                height = Math.Max(1, (int)Math.Floor(height * options.DimensionScale));
            }
        }
        catch (AttemptLimitException)
        {
            return new(best, attempts, true);
        }

        return new(best, attempts, false);
    }

    private sealed class AttemptLimitException : Exception
    {
    }
}
