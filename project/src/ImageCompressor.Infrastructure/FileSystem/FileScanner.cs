using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using ImageCompressor.Domain;

namespace ImageCompressor.Infrastructure;

public sealed record SkippedInput(string FullPath, string Reason);

public sealed record FileScanResult(
    IReadOnlyList<SourceItem> Sources,
    IReadOnlyList<SkippedInput> Skipped);

public static class FileScanner
{
    private static readonly HashSet<string> SupportedExtensions =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ".jpg",
            ".jpeg",
            ".png",
            ".bmp",
            ".gif",
            ".tiff",
            ".tif",
        };

    public static IReadOnlyList<SourceItem> Scan(
        string inputRoot,
        string outputRoot,
        bool includeSubfolders,
        Action<string>? warning = null)
    {
        var normalizedInput = Path.GetFullPath(inputRoot);
        var normalizedOutput = Path.GetFullPath(outputRoot);
        if (!Directory.Exists(normalizedInput))
        {
            throw new DirectoryNotFoundException($"入力フォルダが見つかりません: {normalizedInput}");
        }

        return ScanInputs([normalizedInput], normalizedOutput, includeSubfolders, warning).Sources;
    }

    public static FileScanResult ScanInputs(
        IReadOnlyList<string> inputPaths,
        string outputRoot,
        bool includeSubfolders,
        Action<string>? warning = null)
    {
        ArgumentNullException.ThrowIfNull(inputPaths);
        if (inputPaths.Count == 0)
        {
            throw new ArgumentException("入力ファイルまたはフォルダを指定してください。", nameof(inputPaths));
        }

        var normalizedOutput = Path.GetFullPath(outputRoot);
        var roots = inputPaths
            .Select(Path.GetFullPath)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var files = new List<SourceItem>();
        var skipped = new List<SkippedInput>();
        foreach (var root in roots)
        {
            if (!Directory.Exists(root) && !File.Exists(root))
            {
                skipped.Add(new(root, "入力パスが存在しません"));
                continue;
            }

            var rootName = Directory.Exists(root)
                ? new DirectoryInfo(root).Name
                : Path.GetFileNameWithoutExtension(root);
            IEnumerable<string> candidatePaths = Directory.Exists(root)
                ? EnumerateFiles(root, includeSubfolders, normalizedOutput)
                : [root];
            foreach (var path in candidatePaths)
            {
                var extension = Path.GetExtension(path);
                if (!SupportedExtensions.Contains(extension))
                {
                    skipped.Add(new(path, "対応外の拡張子"));
                    continue;
                }

                try
                {
                    using var stream = new FileStream(
                        path,
                        FileMode.Open,
                        FileAccess.Read,
                        FileShare.ReadWrite | FileShare.Delete);
                    using var image = Image.FromStream(
                        stream,
                        useEmbeddedColorManagement: false,
                        validateImageData: true);
                    var frameCount = GetFrameCount(image);
                    var fileInfo = new FileInfo(path);
                    var inputRoot = Directory.Exists(root)
                        ? root
                        : Path.GetDirectoryName(root) ?? root;
                    var relative = Directory.Exists(root)
                        ? Path.GetRelativePath(root, fileInfo.FullName)
                        : fileInfo.Name;
                    if (roots.Length > 1)
                    {
                        relative = Path.Combine(rootName, relative);
                    }

                    files.Add(new(
                        inputRoot,
                        fileInfo.FullName,
                        relative,
                        extension.ToLowerInvariant(),
                        fileInfo.Length,
                        image.Width,
                        image.Height,
                        frameCount));
                }
                catch (Exception ex) when (ex is ArgumentException or ExternalException or IOException)
                {
                    var reason = $"画像を読み込めません: {ex.Message}";
                    skipped.Add(new(path, reason));
                    warning?.Invoke($"[WARN ] {reason}: {path}");
                }
            }
        }

        return new(
            files.OrderBy(x => x.RelativePath, StringComparer.OrdinalIgnoreCase).ToArray(),
            skipped.OrderBy(x => x.FullPath, StringComparer.OrdinalIgnoreCase).ToArray());
    }

    public static bool IsSupportedExtension(string path) =>
        SupportedExtensions.Contains(Path.GetExtension(path));

    private static IEnumerable<string> EnumerateFiles(
        string inputRoot,
        bool recurse,
        string outputRoot)
    {
        var stack = new Stack<string>();
        stack.Push(inputRoot);
        while (stack.Count > 0)
        {
            var current = stack.Pop();
            if (IsSameOrUnder(current, outputRoot) && !PathsEqual(current, inputRoot))
            {
                continue;
            }

            IEnumerable<string> files;
            try
            {
                files = Directory.EnumerateFiles(current);
            }
            catch (UnauthorizedAccessException)
            {
                continue;
            }

            foreach (var file in files)
            {
                yield return file;
            }

            if (!recurse)
            {
                continue;
            }

            IEnumerable<string> directories;
            try
            {
                directories = Directory.EnumerateDirectories(current);
            }
            catch (UnauthorizedAccessException)
            {
                continue;
            }

            foreach (var directory in directories)
            {
                try
                {
                    if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) == 0)
                    {
                        stack.Push(directory);
                    }
                }
                catch (IOException)
                {
                    // The entry disappeared during enumeration.
                }
            }
        }
    }

    private static int GetFrameCount(Image image)
    {
        var maximum = 1;
        foreach (var dimension in image.FrameDimensionsList)
        {
            maximum = Math.Max(maximum, image.GetFrameCount(new FrameDimension(dimension)));
        }

        return maximum;
    }

    private static bool PathsEqual(string left, string right) =>
        string.Equals(
            Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar),
            Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar),
            StringComparison.OrdinalIgnoreCase);

    private static bool IsSameOrUnder(string candidate, string root)
    {
        var normalizedCandidate = Path.GetFullPath(candidate)
            .TrimEnd(Path.DirectorySeparatorChar);
        var normalizedRoot = Path.GetFullPath(root)
            .TrimEnd(Path.DirectorySeparatorChar);
        return normalizedCandidate.Equals(normalizedRoot, StringComparison.OrdinalIgnoreCase) ||
            normalizedCandidate.StartsWith(
                normalizedRoot + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase);
    }
}
