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
    public void CleanupOrphans_recurses_and_removes_an_unowned_pair()
    {
        var nested = Path.Combine(root, "a", "b");
        Directory.CreateDirectory(nested);
        var store = new SafeFileStore("11111111111111111111111111111111");
        var orphan = store.CreateTemporaryPathForTest(nested);
        File.WriteAllText(orphan, "orphan");
        File.WriteAllText(Path.ChangeExtension(orphan, ".lease"), string.Empty);

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
            Path.ChangeExtension(locked, ".lease"),
            FileMode.CreateNew,
            FileAccess.ReadWrite,
            FileShare.Delete);

        var removed = store.CleanupOrphans(root);

        Assert.DoesNotContain(locked, removed);
        Assert.True(File.Exists(locked));
        Assert.True(File.Exists(foreign));
    }

    [Fact]
    public void CleanupOrphans_retains_legacy_and_unpaired_temp_but_removes_lease_only()
    {
        Directory.CreateDirectory(root);
        var store = new SafeFileStore();
        var legacy = Path.Combine(root, $".image-compressor-{Guid.NewGuid():N}-{Guid.NewGuid():N}.tmp");
        var unpaired = store.CreateTemporaryPathForTest(root);
        var leaseOnly = Path.ChangeExtension(store.CreateTemporaryPathForTest(root), ".lease");
        File.WriteAllText(legacy, "old");
        File.WriteAllText(unpaired, "unknown");
        File.WriteAllText(leaseOnly, string.Empty);

        var warnings = new List<string>();
        var removed = store.CleanupOrphans(root, warnings.Add);

        Assert.Empty(removed);
        Assert.True(File.Exists(legacy));
        Assert.True(File.Exists(unpaired));
        Assert.False(File.Exists(leaseOnly));
        Assert.Equal(2, warnings.Count);
    }

    [Fact]
    public void Active_overwrite_survives_cleanup_before_commit()
    {
        Directory.CreateDirectory(root);
        var target = Path.Combine(root, "output.png");
        File.WriteAllText(target, "old");
        var writer = new SafeFileStore();
        var cleaner = new SafeFileStore();

        writer.SaveBytesSafely(CreatePng(12, 8), target, true, 12, 8, blocksReplacement: _ =>
        {
            var temporary = Assert.Single(Directory.GetFiles(root, "*.tmp"));
            Assert.Empty(cleaner.CleanupOrphans(root));
            Assert.True(File.Exists(temporary));
            return false;
        });

        using var image = Image.FromFile(target);
        Assert.Equal(new Size(12, 8), image.Size);
        Assert.Empty(Directory.EnumerateFiles(root, ".image-compressor-*"));
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
        File.WriteAllText(Path.ChangeExtension(orphan, ".lease"), string.Empty);
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

}
