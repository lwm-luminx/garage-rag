using System.Text.Json;
using System.Text.Json.Nodes;

namespace Garage.App.Core.State;

/// <summary>
/// The app's own settings (the Mac's <c>UserDefaults</c>): how the app behaves, not what Garage indexes,
/// which stays in <c>garage.json</c>.
/// </summary>
public interface IPreferences
{
    /// <summary>The stored value of <paramref name="key"/>, or <paramref name="fallback"/>.</summary>
    T Read<T>(string key, T fallback);

    /// <summary>Stores <paramref name="value"/> under <paramref name="key"/>.</summary>
    void Write<T>(string key, T value);
}

/// <summary>Preferences kept in memory only: tests, and a data folder that cannot be written.</summary>
public sealed class MemoryPreferences : IPreferences
{
    private readonly Dictionary<string, object?> _values = new(StringComparer.Ordinal);

    /// <inheritdoc/>
    public T Read<T>(string key, T fallback) => _values.TryGetValue(key, out object? value) && value is T typed ? typed : fallback;

    /// <inheritdoc/>
    public void Write<T>(string key, T value) => _values[key] = value;
}

/// <summary>Preferences in a JSON file (<c>app-settings.json</c> in the data folder), written on every change.</summary>
public sealed class JsonPreferences(string path) : IPreferences
{
    private readonly Lock _lock = new();
    private JsonObject? _values;

    /// <summary>The file.</summary>
    public string Path { get; } = path;

    /// <inheritdoc/>
    public T Read<T>(string key, T fallback)
    {
        lock (_lock)
        {
            try
            {
                return Load()[key] is { } node ? node.Deserialize<T>() ?? fallback : fallback;
            }
            catch (Exception ex) when (ex is JsonException or InvalidOperationException or FormatException)
            {
                return fallback;
            }
        }
    }

    /// <inheritdoc/>
    public void Write<T>(string key, T value)
    {
        lock (_lock)
        {
            JsonObject values = Load();
            values[key] = JsonSerializer.SerializeToNode(value);
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
            string temp = Path + ".tmp";
            File.WriteAllText(temp, values.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temp, Path, overwrite: true);
        }
    }

    private JsonObject Load()
    {
        if (_values is not null)
        {
            return _values;
        }
        try
        {
            _values = File.Exists(Path) ? JsonNode.Parse(File.ReadAllText(Path)) as JsonObject ?? [] : [];
        }
        catch (Exception ex) when (ex is JsonException or IOException)
        {
            // A damaged file loses its settings, not the app.
            _values = [];
        }
        return _values;
    }
}
