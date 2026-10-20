using ImageCompressor.Domain;
using ImageCompressor.Infrastructure;

namespace ImageCompressor.IntegrationTests;

public sealed class SettingsStoreSpec : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"image-compressor-settings-{Guid.NewGuid():N}");

    [Fact]
    public void Load_rejects_unknown_schema()
    {
        var store = StoreWith("""{"schemaVersion":999,"selectedPresetId":"hd"}""");

        var settings = store.Load(out var warning);

        Assert.Equal(Presets.DefaultId, settings.SelectedPresetId);
        Assert.Contains("未対応", warning, StringComparison.Ordinal);
    }

    [Fact]
    public void Load_invalid_json_returns_defaults()
    {
        var store = StoreWith("{invalid");

        var settings = store.Load(out var warning);

        Assert.Equal(Presets.DefaultId, settings.SelectedPresetId);
        Assert.NotNull(warning);
    }

    [Fact]
    public void Load_unknown_preset_falls_back_to_code_definition()
    {
        var store = StoreWith("""{"schemaVersion":1,"selectedPresetId":"removed"}""");

        var settings = store.Load(out var warning);

        Assert.Null(warning);
        Assert.Equal(Presets.DefaultId, settings.SelectedPresetId);
    }

    [Fact]
    public void Save_round_trips_only_selected_preset_and_overrides()
    {
        var store = StoreWith("{}");

        store.Save(new()
        {
            SelectedPresetId = "hd",
            Overrides = new(Quality: 88),
            InputPaths = ["C:\\images-a", "C:\\images-b"],
            TargetNonJpegPolicy = TargetNonJpegPolicy.Skip,
        });
        var loaded = store.Load(out var warning);

        Assert.Null(warning);
        Assert.Equal("hd", loaded.SelectedPresetId);
        Assert.Equal(88, loaded.Overrides.Quality);
        Assert.Equal(2, loaded.InputPaths.Count);
        Assert.Equal(TargetNonJpegPolicy.Skip, loaded.TargetNonJpegPolicy);
        Assert.Equal(Path.Combine(root, "settings.json"), store.SettingsPath);
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }

        GC.SuppressFinalize(this);
    }

    private SettingsStore StoreWith(string json)
    {
        Directory.CreateDirectory(root);
        File.WriteAllText(Path.Combine(root, "settings.json"), json);
        return new(root);
    }
}
