namespace ImageCompressor.Domain;

public static class OutputPlanner
{
    public static IReadOnlyList<OutputPlan> Create(
        IEnumerable<SourceItem> sources,
        CompressionRequest request,
        Func<string, bool>? fileExists = null)
    {
        ArgumentNullException.ThrowIfNull(sources);
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();

        fileExists ??= File.Exists;
        var outputRoot = Path.GetFullPath(request.OutputRoot)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var reserved = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var plans = new List<OutputPlan>();
        var extension = GetExtension(request.GetEffectiveOutputFormat());

        foreach (var source in sources)
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

            while (true)
            {
                candidateName = suffix == 0
                    ? $"{baseName}{extension}"
                    : $"{baseName}_{suffix:000}{extension}";
                candidatePath = Path.GetFullPath(Path.Combine(targetDirectory, candidateName));
                EnsureUnderRoot(outputRoot, candidatePath);
                var reservedCollision = reserved.Contains(candidatePath);
                var diskCollision = fileExists(candidatePath);

                if (reservedCollision ||
                    (request.CollisionPolicy == CollisionPolicy.AutoRename && diskCollision))
                {
                    suffix++;
                    continue;
                }

                break;
            }

            reserved.Add(candidatePath);
            var exists = fileExists(candidatePath);
            var action = PlanAction.Write;
            var reason = suffix > 0
                ? $"出力名衝突を回避して {candidateName} を使用"
                : string.Empty;

            if (exists)
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
        var normalizedRoot = root.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        if (!candidate.Equals(normalizedRoot, StringComparison.OrdinalIgnoreCase) &&
            !candidate.StartsWith(
                normalizedRoot + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("出力先が出力root外です。");
        }
    }
}
