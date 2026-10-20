using System.Text.Json;
using System.Text.Json.Serialization;
using ImageCompressor.Domain;

namespace ImageCompressor.Infrastructure;

public sealed class AppSettings
{
    public int SchemaVersion { get; set; } = 1;

    public string SelectedPresetId { get; set; } = Presets.DefaultId;

    public PresetOverrides Overrides { get; set; } = new();

    public string InputPath { get; set; } = string.Empty;

    public List<string> InputPaths { get; set; } = [];

    public string OutputPath { get; set; } = string.Empty;

    public bool TargetSizeEnabled { get; set; }

    public int TargetKilobytes { get; set; } = 500;

    public CollisionPolicy CollisionPolicy { get; set; } = CollisionPolicy.AutoRename;

    public LargerOutputPolicy LargerOutputPolicy { get; set; } = LargerOutputPolicy.Skip;

    public AlreadyWithinTargetPolicy AlreadyWithinTargetPolicy { get; set; } =
        AlreadyWithinTargetPolicy.Copy;

    public TargetNonJpegPolicy TargetNonJpegPolicy { get; set; } =
        TargetNonJpegPolicy.ConvertToJpeg;

    public bool IncludeSubfolders { get; set; }

    public bool PreserveHierarchy { get; set; }

    public bool JpegBackgroundBlack { get; set; }

    public int? WindowX { get; set; }

    public int? WindowY { get; set; }

    public int? WindowWidth { get; set; }

    public int? WindowHeight { get; set; }
}

public sealed class SettingsStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        AllowTrailingCommas = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public SettingsStore(string executableDirectory)
    {
        var portable = Path.Combine(Path.GetFullPath(executableDirectory), "settings.json");
        SettingsPath = File.Exists(portable)
            ? portable
            : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ImageCompressor",
                "settings.json");
    }

    public string SettingsPath { get; }

    public AppSettings Load(out string? warning)
    {
        warning = null;
        if (!File.Exists(SettingsPath))
        {
            return new();
        }

        try
        {
            var settings = JsonSerializer.Deserialize<AppSettings>(
                File.ReadAllText(SettingsPath),
                Options) ?? new();
            if (settings.SchemaVersion != 1)
            {
                warning = $"未対応の設定schemaVersion={settings.SchemaVersion}のため既定値を使用します。";
                return new();
            }

            settings.SelectedPresetId = Presets.GetOrDefault(settings.SelectedPresetId).Id;
            settings.TargetKilobytes = Math.Max(1, settings.TargetKilobytes);
            return settings;
        }
        catch (JsonException exception)
        {
            warning = $"設定を読み込めないため既定値を使用します: {exception.Message}";
            return new();
        }
        catch (IOException exception)
        {
            warning = $"設定を読み込めないため既定値を使用します: {exception.Message}";
            return new();
        }
        catch (UnauthorizedAccessException exception)
        {
            warning = $"設定を読み込めないため既定値を使用します: {exception.Message}";
            return new();
        }
    }

    public void Save(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        settings.SchemaVersion = 1;
        settings.SelectedPresetId = Presets.GetOrDefault(settings.SelectedPresetId).Id;
        var directory = Path.GetDirectoryName(SettingsPath)
            ?? throw new InvalidOperationException("設定directoryを解決できません。");
        try
        {
            Directory.CreateDirectory(directory);
            var temporary = SettingsPath + $".{Guid.NewGuid():N}.tmp";
            var json = JsonSerializer.Serialize(settings, Options);
            try
            {
                File.WriteAllText(temporary, json);
                _ = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(temporary), Options)
                    ?? throw new JsonException("保存後の設定検証に失敗しました。");
                File.Move(temporary, SettingsPath, overwrite: true);
            }
            finally
            {
                if (File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new UnauthorizedAccessException(
                $"設定を書き込めません: {SettingsPath}。書き込み可能なフォルダへportable版を移動してください。",
                exception);
        }
    }
}
