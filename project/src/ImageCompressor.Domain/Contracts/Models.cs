using System.Collections.ObjectModel;

namespace ImageCompressor.Domain;

public enum OutputFormat
{
    Jpeg,
    Png,
    Bmp,
}

public enum CollisionPolicy
{
    AutoRename,
    Skip,
    Overwrite,
    Confirm,
}

public enum LargerOutputPolicy
{
    Skip,
    Warn,
    Save,
}

public enum AlreadyWithinTargetPolicy
{
    Copy,
    Skip,
}

public enum MultiFramePolicy
{
    FirstFrameWithWarning,
    SkipMultiFrame,
}

public enum TargetNonJpegPolicy
{
    ConvertToJpeg,
    Skip,
}

public enum ResultStatus
{
    Success,
    Copied,
    Skipped,
    Failed,
    Cancelled,
}

public enum PlanAction
{
    Write,
    Skip,
    Overwrite,
    Confirm,
}

public sealed record PresetDefinition(
    string Id,
    string DisplayName,
    int MaxWidth,
    int MaxHeight,
    int Quality,
    OutputFormat Format);

public static class Presets
{
    public const string DefaultId = "default";

    private static readonly ReadOnlyCollection<PresetDefinition> ItemsValue =
        new(
        [
            new("default", "デフォルト", 1920, 1080, 75, OutputFormat.Jpeg),
            new("hd", "HD", 1280, 720, 80, OutputFormat.Jpeg),
            new("4k", "4K", 3840, 2160, 85, OutputFormat.Jpeg),
            new("high-quality", "高品質", 1920, 1080, 95, OutputFormat.Png),
            new("web", "Web最適化", 1200, 800, 60, OutputFormat.Jpeg),
            new("thumbnail", "サムネイル", 320, 240, 70, OutputFormat.Jpeg),
        ]);

    public static IReadOnlyList<PresetDefinition> Items => ItemsValue;

    public static PresetDefinition GetOrDefault(string? id) =>
        ItemsValue.FirstOrDefault(x => string.Equals(x.Id, id, StringComparison.Ordinal))
        ?? ItemsValue[0];
}

public sealed record PresetOverrides(
    int? MaxWidth = null,
    int? MaxHeight = null,
    int? Quality = null,
    OutputFormat? Format = null);

public sealed class CompressionRequest
{
    public const long MinimumTargetBytes = 1024;
    public const int MinimumQuality = 10;
    public const int MaximumEncodeAttempts = 64;
    public const int LocalSweepCount = 3;

    public required string InputRoot { get; init; }

    public required string OutputRoot { get; init; }

    public int MaxWidth { get; init; } = 1920;

    public int MaxHeight { get; init; } = 1080;

    public int Quality { get; init; } = 75;

    public OutputFormat OutputFormat { get; init; } = OutputFormat.Jpeg;

    public bool TargetSizeEnabled { get; init; }

    public long TargetBytes { get; init; } = 500 * 1024;

    public bool JpegBackgroundBlack { get; init; }

    public CollisionPolicy CollisionPolicy { get; init; } = CollisionPolicy.AutoRename;

    public LargerOutputPolicy LargerOutputPolicy { get; init; } = LargerOutputPolicy.Skip;

    public AlreadyWithinTargetPolicy AlreadyWithinTargetPolicy { get; init; } =
        AlreadyWithinTargetPolicy.Copy;

    public MultiFramePolicy MultiFramePolicy { get; init; } =
        MultiFramePolicy.FirstFrameWithWarning;

    public TargetNonJpegPolicy TargetNonJpegPolicy { get; init; } =
        TargetNonJpegPolicy.ConvertToJpeg;

    public bool IncludeSubfolders { get; init; }

    public bool PreserveHierarchy { get; init; }

    public OutputFormat GetEffectiveOutputFormat() =>
        TargetSizeEnabled &&
        OutputFormat != OutputFormat.Jpeg &&
        TargetNonJpegPolicy == TargetNonJpegPolicy.ConvertToJpeg
            ? OutputFormat.Jpeg
            : OutputFormat;

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(InputRoot))
        {
            throw new ArgumentException("入力フォルダが空です。", nameof(InputRoot));
        }

        if (string.IsNullOrWhiteSpace(OutputRoot))
        {
            throw new ArgumentException("出力フォルダが空です。", nameof(OutputRoot));
        }

        if (MaxWidth < 1 || MaxHeight < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(MaxWidth), "最大寸法は1px以上である必要があります。");
        }

        if (Quality is < 1 or > 100)
        {
            throw new ArgumentOutOfRangeException(nameof(Quality), "品質は1～100で指定してください。");
        }

        if (TargetSizeEnabled && TargetBytes < MinimumTargetBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(TargetBytes),
                $"目標容量は{MinimumTargetBytes} bytes以上で指定してください。");
        }
    }
}

public sealed record SourceItem(
    string InputRoot,
    string FullPath,
    string RelativePath,
    string Extension,
    long Length,
    int Width,
    int Height,
    int FrameCount);

public sealed record OutputPlan(
    SourceItem Source,
    string OutputName,
    string OutputPath,
    PlanAction Action,
    string Reason,
    bool TargetExisted);

public sealed record CompressionResult(
    SourceItem Source,
    string? OutputPath,
    ResultStatus Status,
    string Reason,
    long OriginalBytes,
    long OutputBytes,
    int Width,
    int Height,
    int EncodeAttempts,
    bool IsLarger,
    IReadOnlyList<string>? Warnings = null);

public sealed record CompressionProgress(
    int Completed,
    int Total,
    string FileName,
    CompressionResult? Result);
