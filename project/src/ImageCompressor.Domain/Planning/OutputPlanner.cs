namespace ImageCompressor.Domain;

public static class OutputPlanner
{
    public static IReadOnlyList<OutputPlan> Create(
        IEnumerable<SourceItem> sources,
        CompressionRequest request,
        Func<string, bool>? fileExists = null) =>
        Create(sources, request, fileExists, null, null);

    public static IReadOnlyList<OutputPlan> Create(
        IEnumerable<SourceItem> sources,
        CompressionRequest request,
        Func<string, bool>? fileExists,
        IEnumerable<SourceItem>? protectedSources,
        Func<string, bool>? isProtectedAlias)
    {
        ArgumentNullException.ThrowIfNull(sources);
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();

        fileExists ??= File.Exists;
        var outputRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(request.OutputRoot));
        var selected = sources.ToArray();
        var protectedPaths = selected.Concat(protectedSources ?? [])
            .Select(source => Path.GetFullPath(source.FullPath))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var reserved = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var plans = new List<OutputPlan>();
        var extension = GetExtension(request.GetEffectiveOutputFormat());

        foreach (var source in selected)
        {
            var relativeDirectory = request.PreserveHierarchy
                ? Path.GetDirectoryName(source.RelativePath) ?? string.Empty
                : string.Empty;
            ValidateRelativeDirectory(relativeDirectory);

            var targetDirectory = Path.GetFullPath(Path.Combine(outputRoot, relativeDirectory));
            EnsureUnderRoot(outputRoot, targetDirectory);
            var baseName = Path.GetFileNameWithoutExtension(source.FullPath);
            var suffix = 0;
            string candidatePath;
            string candidateName;
            bool exists;
            bool protectsInput;

            while (true)
            {
                candidateName = suffix == 0
                    ? $"{baseName}{extension}"
                    : $"{baseName}_{suffix:000}{extension}";
                candidatePath = Path.GetFullPath(Path.Combine(targetDirectory, candidateName));
                EnsureUnderRoot(outputRoot, candidatePath);
                var reservedCollision = reserved.Contains(candidatePath);
                exists = fileExists(candidatePath);
                protectsInput = protectedPaths.Contains(candidatePath) ||
                    (exists && isProtectedAlias?.Invoke(candidatePath) == true);

                if (reservedCollision ||
                    (request.CollisionPolicy == CollisionPolicy.AutoRename && (exists || protectsInput)))
                {
                    suffix++;
                    continue;
                }

                break;
            }

            reserved.Add(candidatePath);
            var action = PlanAction.Write;
            var reason = suffix > 0
                ? $"出力名衝突を回避して {candidateName} を使用"
                : string.Empty;

            if (protectsInput)
            {
                (action, reason) = (PlanAction.Skip, InputProtectionReason);
            }
            else if (exists)
            {
                (action, reason) = request.CollisionPolicy switch
                {
                    CollisionPolicy.Skip => (PlanAction.Skip, "既存ファイルのためスキップ"),
                    CollisionPolicy.Overwrite => (PlanAction.Overwrite, "既存ファイルを安全に置換"),
                    CollisionPolicy.Confirm => (PlanAction.Confirm, "上書き確認が必要"),
                    _ => (action, reason),
                };
            }

            plans.Add(new(source, candidateName, candidatePath, action, reason, exists));
        }

        return plans;
    }

    public const string InputProtectionReason = "入力画像保護のためスキップ（別の出力先または自動連番を選択してください）";

    public static string GetExtension(OutputFormat format) => format switch
    {
        OutputFormat.Jpeg => ".jpg",
        OutputFormat.Png => ".png",
        OutputFormat.Bmp => ".bmp",
        _ => throw new ArgumentOutOfRangeException(nameof(format)),
    };

    private static void ValidateRelativeDirectory(string relativeDirectory)
    {
        if (Path.IsPathRooted(relativeDirectory))
        {
            throw new InvalidOperationException("相対出力パスがrooted pathです。");
        }

        var segments = relativeDirectory.Split(
            [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
            StringSplitOptions.RemoveEmptyEntries);
        if (segments.Any(x => x == ".."))
        {
            throw new InvalidOperationException("相対出力パスに..を含めることはできません。");
        }
    }

    private static void EnsureUnderRoot(string root, string candidate)
    {
        var normalizedRoot = Path.TrimEndingDirectorySeparator(root);
        var prefix = Path.EndsInDirectorySeparator(normalizedRoot)
            ? normalizedRoot : normalizedRoot + Path.DirectorySeparatorChar;
        if (!candidate.Equals(normalizedRoot, StringComparison.OrdinalIgnoreCase) &&
            !candidate.StartsWith(
                prefix,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("出力先が出力root外です。");
        }
    }
}
