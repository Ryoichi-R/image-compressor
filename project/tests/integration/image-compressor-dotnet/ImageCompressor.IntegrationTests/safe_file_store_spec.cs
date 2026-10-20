using System.Drawing;
using System.Drawing.Imaging;
using System.Diagnostics;
using ImageCompressor.Domain;
using ImageCompressor.Infrastructure;

namespace ImageCompressor.IntegrationTests;

public sealed class SafeFileStoreSpec : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"image-compressor-tests-{Guid.NewGuid():N}");

    [Fact]
    public void SaveBytesSafely_validates_then_commits_without_temp_residue()
    {
        Directory.CreateDirectory(root);
        var target = Path.Combine(root, "nested", "output.png");
        var bytes = CreatePng(12, 8);
        var store = new SafeFileStore("11111111111111111111111111111111");

        store.SaveBytesSafely(bytes, target, false, 12, 8);

        Assert.True(File.Exists(target));
        Assert.Empty(Directory.EnumerateFiles(root, ".image-compressor-*.tmp", SearchOption.AllDirectories));
    }

    [Fact]
    public void CleanupOrphans_recurses_and_removes_current_instance_immediately()
    {
        var nested = Path.Combine(root, "a", "b");
        Directory.CreateDirectory(nested);
        var store = new SafeFileStore("11111111111111111111111111111111");
        var orphan = Path.Combine(
            nested,
            ".image-compressor-11111111111111111111111111111111-22222222222222222222222222222222.tmp");
        File.WriteAllText(orphan, "orphan");

        var removed = store.CleanupOrphans(root);

        Assert.Contains(orphan, removed);
        Assert.False(File.Exists(orphan));
    }

    [Fact]
    public void CleanupOrphans_leaves_locked_and_foreign_prefix_files()
    {
        Directory.CreateDirectory(root);
        var store = new SafeFileStore("11111111111111111111111111111111");
        var locked = store.CreateTemporaryPathForTest(
            root,
            "22222222222222222222222222222222");
        var foreign = Path.Combine(root, ".another-tool-file.tmp");
        File.WriteAllText(locked, "locked");
        File.WriteAllText(foreign, "foreign");
        using var lockStream = new FileStream(
            locked,
            FileMode.Open,
            FileAccess.ReadWrite,
            FileShare.None);

        var removed = store.CleanupOrphans(root);

        Assert.DoesNotContain(locked, removed);
        Assert.True(File.Exists(locked));
        Assert.True(File.Exists(foreign));
    }

    [Fact]
    public void CleanupOrphans_applies_one_hour_network_grace_to_other_instances()
    {
        Directory.CreateDirectory(root);
        var now = new DateTimeOffset(2026, 7, 29, 10, 0, 0, TimeSpan.Zero);
        var store = new SafeFileStore(
            "11111111111111111111111111111111",
            new FixedTimeProvider(now));
        var recent = store.CreateTemporaryPathForTest(
            root,
            "22222222222222222222222222222222");
        var old = store.CreateTemporaryPathForTest(
            root,
            "33333333333333333333333333333333");
        File.WriteAllText(recent, "recent");
        File.WriteAllText(old, "old");
        File.SetLastWriteTimeUtc(recent, now.AddMinutes(-30).UtcDateTime);
        File.SetLastWriteTimeUtc(old, now.AddHours(-2).UtcDateTime);

        var removed = store.CleanupOrphans(root, driveTypeOverride: DriveType.Network);

        Assert.True(File.Exists(recent));
        Assert.Contains(old, removed);
    }

    [Fact]
    public void CleanupOrphans_does_not_follow_directory_symbolic_link()
    {
        var outside = Path.Combine(Path.GetTempPath(), $"image-compressor-link-{Guid.NewGuid():N}");
        var link = Path.Combine(root, "link");
        Directory.CreateDirectory(root);
        Directory.CreateDirectory(outside);
        var store = new SafeFileStore("11111111111111111111111111111111");
        var orphan = store.CreateTemporaryPathForTest(outside);
        File.WriteAllText(orphan, "outside");
        try
        {
            try
            {
                CreateDirectoryLink(link, outside);
            }
            catch (Exception exception) when (
                exception is UnauthorizedAccessException or IOException or PlatformNotSupportedException)
            {
                throw new InvalidOperationException(
                    "reparse point検証用symbolic linkを作成できません。",
                    exception);
            }

            Assert.True(
                (File.GetAttributes(link) & FileAttributes.ReparsePoint) != 0,
                "作成したdirectory linkがreparse pointではありません。");
            var removed = store.CleanupOrphans(root);

            Assert.DoesNotContain(orphan, removed);
            Assert.True(File.Exists(orphan));
        }
        finally
        {
            if (Directory.Exists(link))
            {
                Directory.Delete(link);
            }

            if (Directory.Exists(outside))
            {
                Directory.Delete(outside, recursive: true);
            }
        }
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }

        GC.SuppressFinalize(this);
    }

    private static byte[] CreatePng(int width, int height)
    {
        using var bitmap = new Bitmap(width, height);
        using var stream = new MemoryStream();
        bitmap.Save(stream, ImageFormat.Png);
        return stream.ToArray();
    }

    private static void CreateDirectoryLink(string link, string target)
    {
        try
        {
            Directory.CreateSymbolicLink(link, target);
            return;
        }
        catch (IOException)
        {
            // A junction is available without SeCreateSymbolicLinkPrivilege.
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = "cmd.exe",
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            UseShellExecute = false,
        };
        startInfo.ArgumentList.Add("/d");
        startInfo.ArgumentList.Add("/c");
        startInfo.ArgumentList.Add("mklink");
        startInfo.ArgumentList.Add("/J");
        startInfo.ArgumentList.Add(link);
        startInfo.ArgumentList.Add(target);
        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("junction作成processを開始できません。");
        process.WaitForExit();
        if (process.ExitCode != 0)
        {
            throw new IOException(
                $"junctionを作成できません: {process.StandardError.ReadToEnd()}");
        }
    }

    private sealed class FixedTimeProvider(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }
}
