using System.Drawing;
using System.Drawing.Imaging;
using ImageCompressor.Infrastructure;

namespace ImageCompressor.IntegrationTests;

public sealed class FileScannerSpec : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"image-compressor-scanner-{Guid.NewGuid():N}");

    [Fact]
    public void ScanInputs_prefixes_root_names_and_reports_unsupported_files()
    {
        var first = Path.Combine(root, "first");
        var second = Path.Combine(root, "second");
        Directory.CreateDirectory(first);
        Directory.CreateDirectory(second);
        CreatePng(Path.Combine(first, "same.png"));
        CreatePng(Path.Combine(second, "same.png"));
        File.WriteAllText(Path.Combine(second, "note.webp"), "unsupported");

        var result = FileScanner.ScanInputs(
            [first, second],
            Path.Combine(root, "output"),
            includeSubfolders: true);

        Assert.Contains(result.Sources, x => x.RelativePath == Path.Combine("first", "same.png"));
        Assert.Contains(result.Sources, x => x.RelativePath == Path.Combine("second", "same.png"));
        Assert.Contains(result.Skipped, x => x.FullPath.EndsWith("note.webp", StringComparison.Ordinal));
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }

        GC.SuppressFinalize(this);
    }

    private static void CreatePng(string path)
    {
        using var bitmap = new Bitmap(2, 2);
        bitmap.Save(path, ImageFormat.Png);
    }
}
