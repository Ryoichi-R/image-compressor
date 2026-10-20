using System.Drawing;
using System.Drawing.Imaging;
using ImageCompressor.Domain;
using ImageCompressor.Infrastructure;

namespace ImageCompressor.IntegrationTests;

public sealed class CompressionServiceSpec : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"image-compressor-service-{Guid.NewGuid():N}");

    [Fact]
    public void Process_encodes_to_valid_image_and_reports_dimensions()
    {
        var input = Path.Combine(root, "input");
        var output = Path.Combine(root, "output");
        Directory.CreateDirectory(input);
        var sourcePath = Path.Combine(input, "photo.png");
        CreateImage(sourcePath, 400, 200, ImageFormat.Png);
        var request = new CompressionRequest
        {
            InputRoot = input,
            OutputRoot = output,
            MaxWidth = 100,
            MaxHeight = 100,
            OutputFormat = OutputFormat.Jpeg,
            LargerOutputPolicy = LargerOutputPolicy.Save,
        };
        var plan = Assert.Single(OutputPlanner.Create(FileScanner.Scan(input, output, false), request));

        var result = Assert.Single(new CompressionService().Process([plan], request));

        Assert.Equal(ResultStatus.Success, result.Status);
        Assert.Equal(100, result.Width);
        Assert.Equal(50, result.Height);
        Assert.True(File.Exists(result.OutputPath));
        using var image = Image.FromFile(result.OutputPath);
        Assert.Equal(100, image.Width);
        Assert.Equal(50, image.Height);
    }

    [Fact]
    public void Process_copies_already_within_target_without_reencoding()
    {
        var input = Path.Combine(root, "copy-input");
        var output = Path.Combine(root, "copy-output");
        Directory.CreateDirectory(input);
        var sourcePath = Path.Combine(input, "plain.jpg");
        CreateImage(sourcePath, 2, 2, ImageFormat.Jpeg);
        var request = new CompressionRequest
        {
            InputRoot = input,
            OutputRoot = output,
            MaxWidth = 10,
            MaxHeight = 10,
            OutputFormat = OutputFormat.Jpeg,
            TargetSizeEnabled = true,
            TargetBytes = 100 * 1024,
            AlreadyWithinTargetPolicy = AlreadyWithinTargetPolicy.Copy,
        };
        var plan = Assert.Single(OutputPlanner.Create(FileScanner.Scan(input, output, false), request));

        var result = Assert.Single(new CompressionService().Process([plan], request));

        Assert.Equal(ResultStatus.Copied, result.Status);
        Assert.Equal(File.ReadAllBytes(sourcePath), File.ReadAllBytes(result.OutputPath!));
    }

    [Theory]
    [InlineData(1, 30, 20, "red")]
    [InlineData(2, 30, 20, "green")]
    [InlineData(3, 30, 20, "yellow")]
    [InlineData(4, 30, 20, "blue")]
    [InlineData(5, 20, 30, "red")]
    [InlineData(6, 20, 30, "blue")]
    [InlineData(7, 20, 30, "yellow")]
    [InlineData(8, 20, 30, "green")]
    public void Prepare_applies_all_exif_orientations_and_encode_strips_metadata(
        int orientation,
        int expectedWidth,
        int expectedHeight,
        string expectedTopLeft)
    {
        var path = Path.Combine(root, $"orientation-{orientation}.jpg");
        Directory.CreateDirectory(root);
        CreateJpegWithOrientation(path, orientation);

        using var prepared = SystemDrawingImageEngine.Prepare(path);
        var encoded = SystemDrawingImageEngine.Encode(
            prepared,
            prepared.Width,
            prepared.Height,
            90,
            OutputFormat.Jpeg,
            jpegBackgroundBlack: false);

        Assert.Equal(orientation, prepared.OriginalOrientation);
        Assert.Equal(expectedWidth, prepared.Width);
        Assert.Equal(expectedHeight, prepared.Height);
        using var stream = new MemoryStream(encoded.Bytes);
        using var output = new Bitmap(stream);
        Assert.DoesNotContain(0x0112, output.PropertyIdList);
        Assert.DoesNotContain(0x010F, output.PropertyIdList);
        AssertDominantColor(output.GetPixel(2, 2), expectedTopLeft);
    }

    [Theory]
    [InlineData(false, 240)]
    [InlineData(true, 15)]
    public void Encode_flattens_transparent_png_to_selected_jpeg_background(
        bool black,
        int expectedChannel)
    {
        var path = Path.Combine(root, $"alpha-{black}.png");
        Directory.CreateDirectory(root);
        using (var bitmap = new Bitmap(2, 2, PixelFormat.Format32bppArgb))
        {
            bitmap.SetPixel(0, 0, Color.Transparent);
            bitmap.Save(path, ImageFormat.Png);
        }

        using var prepared = SystemDrawingImageEngine.Prepare(path);
        var encoded = SystemDrawingImageEngine.Encode(
            prepared,
            2,
            2,
            100,
            OutputFormat.Jpeg,
            black);
        using var stream = new MemoryStream(encoded.Bytes);
        using var output = new Bitmap(stream);
        var pixel = output.GetPixel(0, 0);

        Assert.InRange(pixel.R, expectedChannel - 15, expectedChannel + 15);
        Assert.InRange(pixel.G, expectedChannel - 15, expectedChannel + 15);
        Assert.InRange(pixel.B, expectedChannel - 15, expectedChannel + 15);
    }

    [Fact]
    public void Process_honors_multi_frame_skip_and_first_frame_warning()
    {
        var input = Path.Combine(root, "multi-input");
        var output = Path.Combine(root, "multi-output");
        Directory.CreateDirectory(input);
        var path = Path.Combine(input, "multi.gif");
        CreateImage(path, 2, 2, ImageFormat.Gif);
        var scanned = Assert.Single(FileScanner.Scan(input, output, false));
        var multi = scanned with { FrameCount = 2 };
        var skipRequest = Request(input, output, MultiFramePolicy.SkipMultiFrame);
        var skipPlan = Assert.Single(OutputPlanner.Create([multi], skipRequest));

        var skipped = Assert.Single(new CompressionService().Process([skipPlan], skipRequest));

        Assert.Equal(ResultStatus.Skipped, skipped.Status);
        var warnRequest = Request(input, output, MultiFramePolicy.FirstFrameWithWarning);
        var warnPlan = Assert.Single(OutputPlanner.Create([multi], warnRequest));
        var warned = Assert.Single(new CompressionService().Process([warnPlan], warnRequest));
        Assert.Contains(
            warned.Warnings ?? [],
            warning => warning.Contains("先頭フレーム", StringComparison.Ordinal));
    }

    [Fact]
    public void Process_reports_cancelled_without_writing_when_token_is_pre_cancelled()
    {
        var input = Path.Combine(root, "cancel-input");
        var output = Path.Combine(root, "cancel-output");
        Directory.CreateDirectory(input);
        CreateImage(Path.Combine(input, "photo.png"), 20, 20, ImageFormat.Png);
        var request = Request(input, output, MultiFramePolicy.FirstFrameWithWarning);
        var plan = Assert.Single(OutputPlanner.Create(FileScanner.Scan(input, output, false), request));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var result = Assert.Single(
            new CompressionService().Process([plan], request, cancellationToken: cancellation.Token));

        Assert.Equal(ResultStatus.Cancelled, result.Status);
        Assert.False(File.Exists(plan.OutputPath));
    }

    [Fact]
    public void Process_skips_non_jpeg_target_mode_when_user_selects_do_not_save()
    {
        var input = Path.Combine(root, "non-jpeg-input");
        var output = Path.Combine(root, "non-jpeg-output");
        Directory.CreateDirectory(input);
        CreateImage(Path.Combine(input, "photo.png"), 20, 20, ImageFormat.Png);
        var request = new CompressionRequest
        {
            InputRoot = input,
            OutputRoot = output,
            OutputFormat = OutputFormat.Png,
            TargetSizeEnabled = true,
            TargetBytes = 10 * 1024,
            TargetNonJpegPolicy = TargetNonJpegPolicy.Skip,
        };
        var plan = Assert.Single(OutputPlanner.Create(FileScanner.Scan(input, output, false), request));

        var result = Assert.Single(new CompressionService().Process([plan], request));

        Assert.Equal(ResultStatus.Skipped, result.Status);
        Assert.False(File.Exists(plan.OutputPath));
    }

    [Fact]
    public void Process_converts_non_jpeg_target_mode_for_non_app_callers()
    {
        var input = Path.Combine(root, "convert-input");
        var output = Path.Combine(root, "convert-output");
        Directory.CreateDirectory(input);
        CreateImage(Path.Combine(input, "photo.png"), 20, 20, ImageFormat.Png);
        var request = new CompressionRequest
        {
            InputRoot = input,
            OutputRoot = output,
            OutputFormat = OutputFormat.Png,
            TargetSizeEnabled = true,
            TargetBytes = 10 * 1024,
            TargetNonJpegPolicy = TargetNonJpegPolicy.ConvertToJpeg,
            LargerOutputPolicy = LargerOutputPolicy.Save,
        };
        var plan = Assert.Single(OutputPlanner.Create(FileScanner.Scan(input, output, false), request));

        var result = Assert.Single(new CompressionService().Process([plan], request));

        Assert.Equal(ResultStatus.Success, result.Status);
        Assert.EndsWith(".jpg", result.OutputPath, StringComparison.OrdinalIgnoreCase);
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }

        GC.SuppressFinalize(this);
    }

    private static void CreateImage(string path, int width, int height, ImageFormat format)
    {
        using var bitmap = new Bitmap(width, height);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.CornflowerBlue);
        bitmap.Save(path, format);
    }

    private static CompressionRequest Request(
        string input,
        string output,
        MultiFramePolicy multiFramePolicy) =>
        new()
        {
            InputRoot = input,
            OutputRoot = output,
            OutputFormat = OutputFormat.Jpeg,
            LargerOutputPolicy = LargerOutputPolicy.Save,
            MultiFramePolicy = multiFramePolicy,
        };

    private static void CreateJpegWithOrientation(string path, int orientation)
    {
        byte[] jpeg;
        using (var bitmap = new Bitmap(30, 20))
        {
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.FillRectangle(Brushes.Red, 0, 0, 15, 10);
                graphics.FillRectangle(Brushes.Green, 15, 0, 15, 10);
                graphics.FillRectangle(Brushes.Blue, 0, 10, 15, 10);
                graphics.FillRectangle(Brushes.Yellow, 15, 10, 15, 10);
            }

            using var stream = new MemoryStream();
            bitmap.Save(stream, ImageFormat.Jpeg);
            jpeg = stream.ToArray();
        }

        var payload = new byte[]
        {
            0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
            0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00,
            0x02, 0x00,
            0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00,
            (byte)orientation, 0x00, 0x00, 0x00,
            0x0F, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00,
            0x41, 0x43, 0x4D, 0x45,
            0x00, 0x00, 0x00, 0x00,
        };
        using var output = File.Create(path);
        output.Write(jpeg, 0, 2);
        output.WriteByte(0xFF);
        output.WriteByte(0xE1);
        var segmentLength = payload.Length + 2;
        output.WriteByte((byte)(segmentLength >> 8));
        output.WriteByte((byte)segmentLength);
        output.Write(payload);
        output.Write(jpeg, 2, jpeg.Length - 2);
    }

    private static void AssertDominantColor(Color color, string expected)
    {
        switch (expected)
        {
            case "red":
                Assert.True(color.R > 180 && color.G < 100 && color.B < 100);
                break;
            case "green":
                Assert.True(color.G > 70 && color.R < 100 && color.B < 100);
                break;
            case "blue":
                Assert.True(color.B > 180 && color.R < 100 && color.G < 100);
                break;
            case "yellow":
                Assert.True(color.R > 180 && color.G > 180 && color.B < 100);
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(expected));
        }
    }
}
