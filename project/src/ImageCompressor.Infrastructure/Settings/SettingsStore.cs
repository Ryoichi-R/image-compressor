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

    private bool needsBackup;
    private bool readFailed;

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
        needsBackup = false;
        readFailed = false;
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(SettingsPath), new()
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip,
            });
            var root = ReadProperties(document.RootElement);
            var invalid = new List<string>();
            var schema = Read(root, "schemaVersion", 1, invalid);
            if (schema != 1 || invalid.Count != 0)
            {
                needsBackup = true;
                warning = "未対応の設定schemaVersionのため既定値を使用します。";
                return new();
            }

            var defaults = new AppSettings();
            var presetId = Read(root, "selectedPresetId", defaults.SelectedPresetId, invalid);
            var preset = Presets.GetOrDefault(presetId);
            if (preset.Id != presetId)
            {
                invalid.Add("selectedPresetId");
            }

            var overrides = new PresetOverrides();
            if (root.TryGetValue("overrides", out var overrideElement))
            {
                if (overrideElement.ValueKind == JsonValueKind.Object)
                {
                    var fields = ReadProperties(overrideElement);
                    overrides = new(
                        ReadRange(fields, "maxWidth", null, 1, 100000, invalid),
                        ReadRange(fields, "maxHeight", null, 1, 100000, invalid),
                        ReadRange(fields, "quality", null, 1, 100, invalid),
                        Read<OutputFormat?>(fields, "format", null, invalid,
                            value => value is null || Enum.IsDefined(value.Value)));
                }
                else
                {
                    invalid.Add("overrides");
                }
            }

            var inputs = Read(root, "inputPaths", defaults.InputPaths, invalid);
            if (inputs.RemoveAll(string.IsNullOrWhiteSpace) > 0)
            {
                invalid.Add("inputPaths");
            }

            var settings = new AppSettings
            {
                SelectedPresetId = preset.Id,
                Overrides = overrides,
                InputPath = Read(root, "inputPath", defaults.InputPath, invalid),
                InputPaths = inputs,
                OutputPath = Read(root, "outputPath", defaults.OutputPath, invalid),
                TargetSizeEnabled = Read(root, "targetSizeEnabled", defaults.TargetSizeEnabled, invalid),
                TargetKilobytes = ReadRange(root, "targetKilobytes", defaults.TargetKilobytes, 1, 1048576, invalid)!.Value,
                CollisionPolicy = Read(root, "collisionPolicy", defaults.CollisionPolicy, invalid, Enum.IsDefined),
                LargerOutputPolicy = Read(root, "largerOutputPolicy", defaults.LargerOutputPolicy, invalid, Enum.IsDefined),
                AlreadyWithinTargetPolicy = Read(root, "alreadyWithinTargetPolicy", defaults.AlreadyWithinTargetPolicy, invalid, Enum.IsDefined),
                TargetNonJpegPolicy = Read(root, "targetNonJpegPolicy", defaults.TargetNonJpegPolicy, invalid, Enum.IsDefined),
                IncludeSubfolders = Read(root, "includeSubfolders", defaults.IncludeSubfolders, invalid),
                PreserveHierarchy = Read(root, "preserveHierarchy", defaults.PreserveHierarchy, invalid),
                JpegBackgroundBlack = Read(root, "jpegBackgroundBlack", defaults.JpegBackgroundBlack, invalid),
                WindowX = Read<int?>(root, "windowX", null, invalid),
                WindowY = Read<int?>(root, "windowY", null, invalid),
                WindowWidth = ReadRange(root, "windowWidth", null, 1, 100000, invalid),
                WindowHeight = ReadRange(root, "windowHeight", null, 1, 100000, invalid),
            };
            if (invalid.Count > 0)
            {
                needsBackup = true;
                warning = $"不正な設定項目を既定値へ戻しました: {string.Join(", ", invalid)}";
            }

            return settings;
        }
        catch (FileNotFoundException)
        {
            return new();
        }
        catch (DirectoryNotFoundException)
        {
            return new();
        }
        catch (JsonException)
        {
            needsBackup = true;
            warning = "設定JSONが不正なため既定値を使用します。";
            return new();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            readFailed = true;
            warning = "設定を読み取れないため既定値を使用します。元の設定は保持します。";
            return new();
        }
    }

    private static Dictionary<string, JsonElement> ReadProperties(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new JsonException("設定はJSON objectである必要があります。");
        }

        var fields = new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in element.EnumerateObject())
        {
            fields[property.Name] = property.Value;
        }

        return fields;
    }

    private static T Read<T>(Dictionary<string, JsonElement> fields, string name, T fallback,
        List<string> invalid, Func<T, bool>? isValid = null)
    {
        if (!fields.TryGetValue(name, out var element))
        {
            return fallback;
        }

        try
        {
            var value = element.Deserialize<T>(Options);
            if ((value is not null || fallback is null) && (isValid?.Invoke(value!) ?? true))
            {
                return value!;
            }
        }
        catch (JsonException)
        {
            // The field is invalid. Keep the remaining fields.
        }

        invalid.Add(name);
        return fallback;
    }

    private static int? ReadRange(Dictionary<string, JsonElement> fields, string name,
        int? fallback, int minimum, int maximum, List<string> invalid) =>
        Read(fields, name, fallback, invalid,
            value => value is null ? fallback is null : value >= minimum && value <= maximum);

    public void Save(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (readFailed)
        {
            throw new IOException("元の設定を読み取れないため、上書きできません。");
        }

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
                if (needsBackup)
                {
                    var backup = SettingsPath + $".{Guid.NewGuid():N}.bak";
                    File.Replace(temporary, SettingsPath, backup);
                    needsBackup = false;
                }
                else
                {
                    File.Move(temporary, SettingsPath, overwrite: true);
                }
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
