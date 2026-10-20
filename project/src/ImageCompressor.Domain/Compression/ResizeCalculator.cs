namespace ImageCompressor.Domain;

public sealed record ResizeDimensions(int Width, int Height, double Scale);

public static class ResizeCalculator
{
    public static ResizeDimensions Calculate(int width, int height, int maxWidth, int maxHeight)
    {
        if (width < 1 || height < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(width), "入力画像の幅と高さは1以上である必要があります。");
        }

        if (maxWidth < 1 || maxHeight < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(maxWidth), "最大幅と最大高さは1以上である必要があります。");
        }

        var scale = Math.Min((double)maxWidth / width, (double)maxHeight / height);
        scale = Math.Min(1d, scale);
        return new(
            Math.Max(1, (int)Math.Round(width * scale, MidpointRounding.ToEven)),
            Math.Max(1, (int)Math.Round(height * scale, MidpointRounding.ToEven)),
            scale);
    }
}

public static class SizeChangeFormatter
{
    public static string Format(long originalBytes, long outputBytes)
    {
        if (originalBytes <= 0)
        {
            return "変化率を計算できません";
        }

        var percent = Math.Round(
            Math.Abs((outputBytes - originalBytes) / (double)originalBytes) * 100d,
            1,
            MidpointRounding.ToEven);

        if (outputBytes < originalBytes)
        {
            return $"{percent:N1}%削減";
        }

        if (outputBytes > originalBytes)
        {
            return $"{percent:N1}%増加";
        }

        return "変化なし";
    }
}
