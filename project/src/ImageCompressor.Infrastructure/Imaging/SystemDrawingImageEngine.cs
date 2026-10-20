using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using ImageCompressor.Domain;

namespace ImageCompressor.Infrastructure;

public sealed class PreparedImage : IDisposable
{
    internal PreparedImage(
        Bitmap bitmap,
        int orientation,
        bool hadMetadata,
        OutputFormat sourceFormat)
    {
        Bitmap = bitmap;
        OriginalOrientation = orientation;
        HadMetadata = hadMetadata;
        SourceFormat = sourceFormat;
    }

    internal Bitmap Bitmap { get; }

    public int Width => Bitmap.Width;

    public int Height => Bitmap.Height;

    public int OriginalOrientation { get; }

    public bool HadMetadata { get; }

    public OutputFormat SourceFormat { get; }

    public void Dispose() => Bitmap.Dispose();
}

public sealed class SystemDrawingImageEngine
{
    private const int ExifOrientationId = 0x0112;

    public static PreparedImage Prepare(string path)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete);
        using var source = Image.FromStream(stream, useEmbeddedColorManagement: false, validateImageData: true);
        var orientation = ReadOrientation(source);
        var hadMetadata = source.PropertyIdList.Any(IsUserMetadata);
        ApplyOrientation(source, orientation);

        var bitmap = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppArgb);
        bitmap.SetResolution(
            NormalizeDpi(source.HorizontalResolution),
            NormalizeDpi(source.VerticalResolution));
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.CompositingMode = CompositingMode.SourceCopy;
            graphics.DrawImage(source, 0, 0, source.Width, source.Height);
        }

        return new(bitmap, orientation, hadMetadata, GetSourceFormat(path));
    }

    public static EncodedCandidate Encode(
        PreparedImage prepared,
        int width,
        int height,
        int quality,
        OutputFormat format,
        bool jpegBackgroundBlack)
    {
        using var resized = Resize(prepared.Bitmap, width, height, format, jpegBackgroundBlack);
        using var stream = new MemoryStream();
        Save(resized, stream, format, quality);
        return new(stream.ToArray(), width, height, quality);
    }

    public static bool MatchesOutputFormat(string extension, OutputFormat format) =>
        format switch
        {
            OutputFormat.Jpeg => extension.Equals(".jpg", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals(".jpeg", StringComparison.OrdinalIgnoreCase),
            OutputFormat.Png => extension.Equals(".png", StringComparison.OrdinalIgnoreCase),
            OutputFormat.Bmp => extension.Equals(".bmp", StringComparison.OrdinalIgnoreCase),
            _ => false,
        };

    private static bool IsUserMetadata(int propertyId) =>
        propertyId is not (
            0x5090 or // JPEG luminance table
            0x5091 or // JPEG chrominance table
            0x5092 or // JPEG luminance DC/AC table
            0x5093);  // JPEG chrominance DC/AC table

    private static Bitmap Resize(
        Bitmap source,
        int width,
        int height,
        OutputFormat format,
        bool jpegBackgroundBlack)
    {
        var pixelFormat = format == OutputFormat.Jpeg
            ? PixelFormat.Format24bppRgb
            : PixelFormat.Format32bppArgb;
        var bitmap = new Bitmap(width, height, pixelFormat);
        bitmap.SetResolution(
            NormalizeDpi(source.HorizontalResolution),
            NormalizeDpi(source.VerticalResolution));
        using var graphics = Graphics.FromImage(bitmap);
        graphics.CompositingMode = CompositingMode.SourceCopy;
        graphics.CompositingQuality = CompositingQuality.HighQuality;
        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
        graphics.SmoothingMode = SmoothingMode.HighQuality;
        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
        if (format == OutputFormat.Jpeg)
        {
            graphics.CompositingMode = CompositingMode.SourceOver;
            graphics.Clear(jpegBackgroundBlack ? Color.Black : Color.White);
        }

        graphics.DrawImage(
            source,
            new Rectangle(0, 0, width, height),
            0,
            0,
            source.Width,
            source.Height,
            GraphicsUnit.Pixel);
        return bitmap;
    }

    private static void Save(Bitmap bitmap, Stream stream, OutputFormat format, int quality)
    {
        if (format != OutputFormat.Jpeg)
        {
            bitmap.Save(
                stream,
                format == OutputFormat.Png ? ImageFormat.Png : ImageFormat.Bmp);
            return;
        }

        var codec = ImageCodecInfo.GetImageEncoders()
            .Single(x => x.FormatID == ImageFormat.Jpeg.Guid);
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(Encoder.Quality, (long)quality);
        bitmap.Save(stream, codec, parameters);
    }

    private static int ReadOrientation(Image image)
    {
        try
        {
            var property = image.GetPropertyItem(ExifOrientationId);
            return property?.Value is { Length: > 0 } ? property.Value[0] : 1;
        }
        catch (ArgumentException)
        {
            return 1;
        }
    }

    private static void ApplyOrientation(Image image, int orientation)
    {
        var rotateFlip = orientation switch
        {
            2 => RotateFlipType.RotateNoneFlipX,
            3 => RotateFlipType.Rotate180FlipNone,
            4 => RotateFlipType.RotateNoneFlipY,
            5 => RotateFlipType.Rotate90FlipX,
            6 => RotateFlipType.Rotate90FlipNone,
            7 => RotateFlipType.Rotate270FlipX,
            8 => RotateFlipType.Rotate270FlipNone,
            _ => RotateFlipType.RotateNoneFlipNone,
        };
        image.RotateFlip(rotateFlip);
    }

    private static OutputFormat GetSourceFormat(string path) =>
        Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".jpg" or ".jpeg" => OutputFormat.Jpeg,
            ".png" => OutputFormat.Png,
            ".bmp" => OutputFormat.Bmp,
            _ => OutputFormat.Jpeg,
        };

    private static float NormalizeDpi(float dpi) =>
        float.IsFinite(dpi) && dpi > 0 ? dpi : 96f;
}
