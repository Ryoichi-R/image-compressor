using System.Drawing;
using System.Security.Cryptography;

namespace ImageCompressor.Infrastructure;

public sealed class SafeFileStore
{
    private const string Prefix = ".image-compressor-";
    private readonly TimeProvider timeProvider;

    public SafeFileStore(string? instanceId = null, TimeProvider? timeProvider = null)
    {
        InstanceId = instanceId ?? Guid.NewGuid().ToString("N");
        if (InstanceId.Length != 32 || !Guid.TryParseExact(InstanceId, "N", out _))
        {
            throw new ArgumentException("instanceIdはGUIDのN形式で指定してください。", nameof(instanceId));
        }

        this.timeProvider = timeProvider ?? TimeProvider.System;
    }

    public string InstanceId { get; }

    public string SaveBytesSafely(
        byte[] bytes,
        string finalPath,
        bool allowReplace,
        int expectedWidth,
        int expectedHeight)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        var finalFull = Path.GetFullPath(finalPath);
        var directory = Path.GetDirectoryName(finalFull)
            ?? throw new InvalidOperationException("出力directoryを解決できません。");
        Directory.CreateDirectory(directory);
        var temporary = CreateTemporaryPath(directory);
        try
        {
            File.WriteAllBytes(temporary, bytes);
            ValidateImage(temporary, expectedWidth, expectedHeight);
            Commit(temporary, finalFull, allowReplace);
            return finalFull;
        }
        finally
        {
            TryDelete(temporary);
        }
    }

    public string CopySourceSafely(string sourcePath, string finalPath, bool allowReplace)
    {
        var sourceFull = Path.GetFullPath(sourcePath);
        var finalFull = Path.GetFullPath(finalPath);
        var directory = Path.GetDirectoryName(finalFull)
            ?? throw new InvalidOperationException("出力directoryを解決できません。");
        Directory.CreateDirectory(directory);
        var temporary = CreateTemporaryPath(directory);
        try
        {
            File.Copy(sourceFull, temporary, overwrite: false);
            var sourceInfo = new FileInfo(sourceFull);
            var temporaryInfo = new FileInfo(temporary);
            if (sourceInfo.Length != temporaryInfo.Length ||
                !CryptographicOperations.FixedTimeEquals(
                    ComputeHash(sourceFull),
                    ComputeHash(temporary)))
            {
                throw new IOException("copy後の長さまたはSHA-256がsourceと一致しません。");
            }

            Commit(temporary, finalFull, allowReplace);
            return finalFull;
        }
        finally
        {
            TryDelete(temporary);
        }
    }

    public IReadOnlyList<string> CleanupOrphans(
        string outputRoot,
        Action<string>? warning = null,
        DriveType? driveTypeOverride = null)
    {
        var removed = new List<string>();
        if (!Directory.Exists(outputRoot))
        {
            return removed;
        }

        var driveType = driveTypeOverride ?? GetDriveType(outputRoot);
        foreach (var file in EnumerateWithoutReparsePoints(Path.GetFullPath(outputRoot)))
        {
            var name = Path.GetFileName(file);
            if (!name.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase) ||
                !name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (!TryParseInstanceId(name, out var ownerInstanceId))
            {
                continue;
            }

            var isCurrentInstance = ownerInstanceId.Equals(
                InstanceId,
                StringComparison.OrdinalIgnoreCase);
            if (!isCurrentInstance && driveType is DriveType.Network or DriveType.Unknown)
            {
                var lastWrite = new DateTimeOffset(File.GetLastWriteTimeUtc(file), TimeSpan.Zero);
                var age = timeProvider.GetUtcNow() - lastWrite;
                if (age < TimeSpan.FromHours(1))
                {
                    continue;
                }
            }

            try
            {
                using (new FileStream(file, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                {
                }

                File.Delete(file);
                removed.Add(file);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                warning?.Invoke($"[WARN ] 使用中の一時ファイルを保持します: {file} ({ex.Message})");
            }
        }

        return removed;
    }

    public string CreateTemporaryPathForTest(string directory, string? ownerInstanceId = null)
    {
        Directory.CreateDirectory(directory);
        return Path.Combine(
            directory,
            $"{Prefix}{ownerInstanceId ?? InstanceId}-{Guid.NewGuid():N}.tmp");
    }

    private string CreateTemporaryPath(string directory) =>
        CreateTemporaryPathForTest(directory);

    private static void Commit(string temporary, string finalPath, bool allowReplace)
    {
        if (!File.Exists(finalPath))
        {
            File.Move(temporary, finalPath);
            return;
        }

        if (!allowReplace)
        {
            throw new IOException($"保存直前に出力ファイルが作成されました: {finalPath}");
        }

        try
        {
            File.Replace(temporary, finalPath, destinationBackupFileName: null);
        }
        catch (PlatformNotSupportedException)
        {
            File.Move(temporary, finalPath, overwrite: true);
        }
    }

    private static void ValidateImage(string path, int width, int height)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length == 0)
        {
            throw new IOException("一時ファイルが空、または作成されませんでした。");
        }

        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var image = Image.FromStream(stream, useEmbeddedColorManagement: false, validateImageData: true);
        if (image.Width != width || image.Height != height)
        {
            throw new IOException("保存後の画像寸法が変換結果と一致しません。");
        }
    }

    private static byte[] ComputeHash(string path)
    {
        using var stream = File.OpenRead(path);
        return SHA256.HashData(stream);
    }

    private static bool TryParseInstanceId(string name, out string instanceId)
    {
        instanceId = string.Empty;
        var withoutPrefix = name[Prefix.Length..];
        var separator = withoutPrefix.IndexOf('-');
        if (separator != 32)
        {
            return false;
        }

        var candidate = withoutPrefix[..separator];
        if (!Guid.TryParseExact(candidate, "N", out _))
        {
            return false;
        }

        instanceId = candidate;
        return true;
    }

    private static IEnumerable<string> EnumerateWithoutReparsePoints(string root)
    {
        var stack = new Stack<string>();
        stack.Push(root);
        while (stack.Count > 0)
        {
            var current = stack.Pop();
            IEnumerable<string> files;
            try
            {
                files = Directory.EnumerateFiles(current, $"{Prefix}*.tmp");
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                continue;
            }

            foreach (var file in files)
            {
                yield return file;
            }

            IEnumerable<string> directories;
            try
            {
                directories = Directory.EnumerateDirectories(current);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
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
                    // The directory disappeared during traversal.
                }
            }
        }
    }

    private static DriveType GetDriveType(string path)
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(path));
            return root is null ? DriveType.Unknown : new DriveInfo(root).DriveType;
        }
        catch (IOException)
        {
            return DriveType.Unknown;
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (IOException)
        {
            // A later job-start cleanup owns crash/orphan recovery.
        }
    }
}
