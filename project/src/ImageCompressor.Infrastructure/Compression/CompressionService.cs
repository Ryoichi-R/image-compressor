using ImageCompressor.Domain;
using System.Runtime.InteropServices;

namespace ImageCompressor.Infrastructure;

public sealed class CompressionService
{
    private readonly SafeFileStore fileStore;

    public CompressionService(SafeFileStore? fileStore = null)
    {
        this.fileStore = fileStore ?? new SafeFileStore();
    }

    public IReadOnlyList<CompressionResult> Process(
        IReadOnlyList<OutputPlan> plans,
        CompressionRequest request,
        Func<OutputPlan, bool>? confirmOverwrite = null,
        IProgress<CompressionProgress>? progress = null,
        Action<string>? log = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(plans);
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();
        Directory.CreateDirectory(request.OutputRoot);
        foreach (var removed in fileStore.CleanupOrphans(request.OutputRoot, log))
        {
            log?.Invoke($"孤立一時ファイルを削除: {removed}");
        }

        var results = new List<CompressionResult>(plans.Count);
        for (var index = 0; index < plans.Count; index++)
        {
            var plan = plans[index];
            CompressionResult result;
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                result = ProcessOne(plan, request, confirmOverwrite, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                result = Result(plan, ResultStatus.Cancelled, "キャンセルされました");
                results.Add(result);
                progress?.Report(new(index + 1, plans.Count, plan.Source.RelativePath, result));
                break;
            }
            catch (Exception exception) when (
                exception is IOException or UnauthorizedAccessException or
                ArgumentException or ExternalException)
            {
                result = Result(plan, ResultStatus.Failed, exception.Message);
            }

            results.Add(result);
            log?.Invoke($"{result.Status}: {plan.Source.RelativePath} - {result.Reason}");
            progress?.Report(new(index + 1, plans.Count, plan.Source.RelativePath, result));
        }

        return results;
    }

    private CompressionResult ProcessOne(
        OutputPlan plan,
        CompressionRequest request,
        Func<OutputPlan, bool>? confirmOverwrite,
        CancellationToken cancellationToken)
    {
        if (plan.Action == PlanAction.Skip)
        {
            return Result(plan, ResultStatus.Skipped, plan.Reason);
        }

        if (plan.Action == PlanAction.Confirm &&
            !(confirmOverwrite?.Invoke(plan) ?? false))
        {
            return Result(plan, ResultStatus.Skipped, "上書きが承認されませんでした");
        }

        if (plan.Source.FrameCount > 1 &&
            request.MultiFramePolicy == MultiFramePolicy.SkipMultiFrame)
        {
            return Result(plan, ResultStatus.Skipped, "複数フレーム画像のためスキップ");
        }

        using var prepared = SystemDrawingImageEngine.Prepare(plan.Source.FullPath);
        var effectiveFormat = request.GetEffectiveOutputFormat();
        var dimensions = ResizeCalculator.Calculate(
            prepared.Width,
            prepared.Height,
            request.MaxWidth,
            request.MaxHeight);
        var canCopy = request.TargetSizeEnabled &&
            plan.Source.Length <= request.TargetBytes &&
            dimensions.Width == prepared.Width &&
            dimensions.Height == prepared.Height &&
            prepared.OriginalOrientation == 1 &&
            !prepared.HadMetadata &&
            SystemDrawingImageEngine.MatchesOutputFormat(
                plan.Source.Extension,
                effectiveFormat);

        if (canCopy)
        {
            if (request.AlreadyWithinTargetPolicy == AlreadyWithinTargetPolicy.Skip)
            {
                return Result(plan, ResultStatus.Skipped, "既に目標容量・寸法以内");
            }

            fileStore.CopySourceSafely(
                plan.Source.FullPath,
                plan.OutputPath,
                plan.Action is PlanAction.Overwrite or PlanAction.Confirm);
            return Result(
                plan,
                ResultStatus.Copied,
                "再エンコードせずコピー",
                plan.Source.Length,
                prepared.Width,
                prepared.Height);
        }

        EncodedCandidate? candidate;
        var attempts = 1;
        if (request.TargetSizeEnabled)
        {
            if (effectiveFormat != OutputFormat.Jpeg)
            {
                return Result(plan, ResultStatus.Skipped, "指定容量モードで非JPEG出力を保存しない設定");
            }

            var search = TargetSizeSearch.Search(
                new(
                    request.TargetBytes,
                    dimensions.Width,
                    dimensions.Height,
                    request.Quality),
                (width, height, quality) => SystemDrawingImageEngine.Encode(
                    prepared,
                    width,
                    height,
                    quality,
                    effectiveFormat,
                    request.JpegBackgroundBlack),
                cancellationToken);
            candidate = search.Candidate;
            attempts = search.Attempts;
            if (candidate is null)
            {
                return Result(
                    plan,
                    ResultStatus.Failed,
                    search.LimitReached
                        ? "試行上限までに指定容量以下へ圧縮できませんでした"
                        : "最小寸法・最低品質でも指定容量以下へ圧縮できませんでした",
                    attempts: attempts);
            }
        }
        else
        {
            candidate = SystemDrawingImageEngine.Encode(
                prepared,
                dimensions.Width,
                dimensions.Height,
                request.Quality,
                effectiveFormat,
                request.JpegBackgroundBlack);
        }

        var isLarger = candidate.Bytes.LongLength > plan.Source.Length;
        if (isLarger && request.LargerOutputPolicy == LargerOutputPolicy.Skip)
        {
            return Result(
                plan,
                ResultStatus.Skipped,
                "出力が元ファイルより大きくなるためスキップ",
                candidate.Bytes.LongLength,
                candidate.Width,
                candidate.Height,
                attempts,
                true);
        }

        var warnings = new List<string>();
        if (plan.Source.FrameCount > 1)
        {
            warnings.Add("複数フレーム画像は先頭フレームのみ出力しました");
        }

        if (isLarger && request.LargerOutputPolicy == LargerOutputPolicy.Warn)
        {
            warnings.Add("出力ファイルが元ファイルより大きくなりました");
        }

        fileStore.SaveBytesSafely(
            candidate.Bytes,
            plan.OutputPath,
            plan.Action is PlanAction.Overwrite or PlanAction.Confirm,
            candidate.Width,
            candidate.Height);
        var reason = SizeChangeFormatter.Format(plan.Source.Length, candidate.Bytes.LongLength);
        return new(
            plan.Source,
            plan.OutputPath,
            ResultStatus.Success,
            reason,
            plan.Source.Length,
            candidate.Bytes.LongLength,
            candidate.Width,
            candidate.Height,
            attempts,
            isLarger,
            warnings);
    }

    private static CompressionResult Result(
        OutputPlan plan,
        ResultStatus status,
        string reason,
        long outputBytes = 0,
        int width = 0,
        int height = 0,
        int attempts = 0,
        bool isLarger = false) =>
        new(
            plan.Source,
            status is ResultStatus.Success or ResultStatus.Copied ? plan.OutputPath : null,
            status,
            reason,
            plan.Source.Length,
            outputBytes,
            width,
            height,
            attempts,
            isLarger);
}
