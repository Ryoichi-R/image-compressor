using System.Drawing;
using System.Security.Cryptography;

namespace ImageCompressor.Infrastructure;

public sealed class SafeFileStore
{
    private const string LegacyPrefix = ".image-compressor-";
    private const string Prefix = LegacyPrefix + "v2-";

    public SafeFileStore(string? instanceId = null, TimeProvider? timeProvider = null)
    {
        InstanceId = instanceId ?? Guid.NewGuid().ToString("N");
        if (InstanceId.Length != 32 || !Guid.TryParseExact(InstanceId, "N", out _))
        {
            throw new ArgumentException("instanceIdはGUIDのN形式で指定してください。", nameof(instanceId));
        }

    }

    public string InstanceId { get; }

    public string SaveBytesSafely(
        byte[] bytes,
        string finalPath,
        bool allowReplace,
        int expectedWidth,
        int expectedHeight,
        Func<string, bool>? blocksReplacement = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        if (bytes.Length == 0)
        {
            throw new IOException("一時ファイルが空です。");
        }

        return Save(finalPath, allowReplace, temporary =>
        {
            using var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
            stream.Write(bytes);
            stream.Flush(flushToDisk: true);
            stream.Position = 0;
            using var image = Image.FromStream(stream, useEmbeddedColorManagement: false, validateImageData: true);
            if (image.Width != expectedWidth || image.Height != expectedHeight)
            {
                throw new IOException("保存後の画像寸法が変換結果と一致しません。");
            }
        }, blocksReplacement, cancellationToken);
    }

    public string CopySourceSafely(string sourcePath, string finalPath, bool allowReplace)
    {
        using var source = File.OpenRead(sourcePath);
        return CopySourceSafely(source, finalPath, allowReplace);
    }

    internal string CopySourceSafely(
        Stream source, string finalPath, bool allowReplace,
        Func<string, bool>? blocksReplacement = null, CancellationToken cancellationToken = default) =>
        Save(finalPath, allowReplace, temporary =>
        {
            using var target = new FileStream(temporary, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
            source.Position = 0;
            source.CopyTo(target);
            target.Flush(flushToDisk: true);
            source.Position = 0;
            target.Position = 0;
            if (source.Length != target.Length ||
                !CryptographicOperations.FixedTimeEquals(SHA256.HashData(source), SHA256.HashData(target)))
            {
                throw new IOException("copy後の長さまたはSHA-256がsourceと一致しません。");
            }
        }, blocksReplacement, cancellationToken);

    private string Save(string finalPath, bool allowReplace, Action<string> writeAndValidate,
        Func<string, bool>? blocksReplacement, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var finalFull = Path.GetFullPath(finalPath);
        var directory = Path.GetDirectoryName(finalFull)
            ?? throw new InvalidOperationException("出力directoryを解決できません。");
        Directory.CreateDirectory(directory);
        var temporary = CreateTemporaryPathForTest(directory);
        var leasePath = Path.ChangeExtension(temporary, ".lease");
        using var lease = new FileStream(leasePath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Delete);
        try
        {
            writeAndValidate(temporary);
            Commit(temporary, finalFull, allowReplace, blocksReplacement, cancellationToken);
            return finalFull;
        }
        finally
        {
            if (TryDelete(temporary))
            {
                TryDelete(leasePath);
            }
        }
    }

    [System.Diagnostics.CodeAnalysis.SuppressMessage("Performance", "CA1822",
        Justification = "Keep the existing instance API while cleanup uses lease ownership.")]
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

        foreach (var file in EnumerateWithoutReparsePoints(Path.GetFullPath(outputRoot)))
        {
            var name = Path.GetFileName(file);
            if (!IsTemporaryFile(file))
            {
                continue;
            }

            var leasePath = Path.ChangeExtension(file, ".lease");
            if (name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase))
            {
                if (!File.Exists(leasePath))
                {
                    warning?.Invoke($"[WARN ] 所有を確認できない一時ファイルを保持します: {file}");
                }

                continue;
            }

            try
            {
                if (File.GetAttributes(leasePath).HasFlag(FileAttributes.ReparsePoint))
                {
                    continue;
                }

                using var lease = new FileStream(leasePath, FileMode.Open, FileAccess.ReadWrite, FileShare.Delete);
                var temporary = Path.ChangeExtension(leasePath, ".tmp");
                if (File.Exists(temporary))
                {
                    if (File.GetAttributes(temporary).HasFlag(FileAttributes.ReparsePoint))
                    {
                        continue;
                    }

                    File.Delete(temporary);
                    removed.Add(temporary);
                }

                File.Delete(leasePath);
            }
            catch (FileNotFoundException)
            {
                // The owner or another cleanup removed the lease after enumeration.
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                warning?.Invoke($"[WARN ] 使用中または削除できない一時ファイルを保持します: {leasePath}");
            }
        }

        return removed;
    }

    internal static bool IsTemporaryFile(string path)
    {
        var name = Path.GetFileName(path);
        var extension = Path.GetExtension(name);
        var prefix = name.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase) ? Prefix : LegacyPrefix;
        if (!name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ||
            (!extension.Equals(".tmp", StringComparison.OrdinalIgnoreCase) &&
             !(prefix == Prefix && extension.Equals(".lease", StringComparison.OrdinalIgnoreCase))))
        {
            return false;
        }

        var stem = name.AsSpan(prefix.Length, name.Length - prefix.Length - extension.Length);
        return stem.Length == 65 && stem[32] == '-' &&
            Guid.TryParseExact(stem[..32], "N", out _) && Guid.TryParseExact(stem[33..], "N", out _);
    }

    public string CreateTemporaryPathForTest(string directory, string? ownerInstanceId = null)
    {
        Directory.CreateDirectory(directory);
        return Path.Combine(directory, $"{Prefix}{ownerInstanceId ?? InstanceId}-{Guid.NewGuid():N}.tmp");
    }

    private static void Commit(string temporary, string finalPath, bool allowReplace,
        Func<string, bool>? blocksReplacement, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!File.Exists(finalPath))
        {
            File.Move(temporary, finalPath);
            return;
        }

        if (!allowReplace)
        {
            throw new IOException($"保存直前に出力ファイルが作成されました: {finalPath}");
        }

        if (blocksReplacement?.Invoke(finalPath) == true)
        {
            throw new IOException(Domain.OutputPlanner.InputProtectionReason);
        }

        cancellationToken.ThrowIfCancellationRequested();
        File.Replace(temporary, finalPath, destinationBackupFileName: null);
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
                files = Directory.GetFiles(current, $"{LegacyPrefix}*");
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
                directories = Directory.GetDirectories(current);
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

    private static bool TryDelete(string path)
    {
        try
        {
            File.Delete(path);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}
