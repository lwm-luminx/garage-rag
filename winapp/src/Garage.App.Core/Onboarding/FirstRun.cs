using System.Globalization;
using System.Text.Json;
using Garage.App.Core.Database;
using Garage.App.Core.Mcp;
using Garage.App.Core.Models;
using Garage.App.Core.Sources;

namespace Garage.App.Core.Onboarding;

/// <summary>The pages of the setup assistant, in order (the Mac's <c>FirstRunStep</c>).</summary>
public enum FirstRunStep
{
    /// <summary>Waiting for the database and the services.</summary>
    SettingUp,

    /// <summary>Picking the folders to index.</summary>
    SelectData,

    /// <summary>Picking the embedding and distillation models.</summary>
    SelectModels,

    /// <summary>Connecting the assistants.</summary>
    SetupAgent,
}

/// <summary>The steps' wording and order.</summary>
public static class FirstRunSteps
{
    /// <summary>Every step, in order.</summary>
    public static IReadOnlyList<FirstRunStep> All { get; } = [FirstRunStep.SettingUp, FirstRunStep.SelectData, FirstRunStep.SelectModels, FirstRunStep.SetupAgent];

    /// <summary>The step's title.</summary>
    public static string Title(this FirstRunStep step) => step switch
    {
        FirstRunStep.SettingUp => "Setting things up",
        FirstRunStep.SelectData => "Select your data",
        FirstRunStep.SelectModels => "Select your models",
        FirstRunStep.SetupAgent => "Set up your assistant",
        _ => throw new ArgumentOutOfRangeException(nameof(step)),
    };

    /// <summary>The step after this one, or null on the last.</summary>
    public static FirstRunStep? Next(this FirstRunStep step) => step == FirstRunStep.SetupAgent ? null : step + 1;

    /// <summary>The step before this one, or null on the first.</summary>
    public static FirstRunStep? Previous(this FirstRunStep step) => step == FirstRunStep.SettingUp ? null : step - 1;
}

/// <summary>How far one row on the "Setting things up" page has got.</summary>
public enum FirstRunCheckState
{
    /// <summary>Waiting for something before it.</summary>
    Pending,

    /// <summary>Starting.</summary>
    InProgress,

    /// <summary>Up.</summary>
    Ready,

    /// <summary>Failed; the row's message says why.</summary>
    Failed,
}

/// <summary>A row on the "Setting things up" page.</summary>
public sealed record FirstRunServiceCheck(string Id, string Title, string Detail, FirstRunCheckState State, string? Message = null)
{
    /// <summary>Up.</summary>
    public bool IsReady => State == FirstRunCheckState.Ready;

    /// <summary>Failed.</summary>
    public bool IsFailed => State == FirstRunCheckState.Failed;
}

/// <summary>
/// The readiness checklist from the services' states, kept free of the app so it is unit-tested
/// (the Mac's <c>FirstRunReadiness</c>). The database is the app's own Postgres, or the server
/// <c>garage.json</c> names as the backend reaches it; the schema is whether the start-up
/// <c>InitDb</c> ran (null: not yet); the backend is the core service.
/// </summary>
public static class FirstRunReadiness
{
    private static readonly HashSet<string> RequiredIds = ["postgres", "schema", "grpc"];

    /// <summary>The checklist.</summary>
    public static IReadOnlyList<FirstRunServiceCheck> Checks(
        PostgresStatus database,
        bool? schemaApplied,
        bool isApplyingSchema,
        McpServerStatus backend,
        McpServerStatus mcp,
        bool mcpHttpEnabled = true)
    {
        ArgumentNullException.ThrowIfNull(database);
        ArgumentNullException.ThrowIfNull(backend);
        ArgumentNullException.ThrowIfNull(mcp);
        (FirstRunCheckState state, string? message) db = database.State switch
        {
            PostgresState.Stopped => (FirstRunCheckState.Pending, null),
            PostgresState.Starting or PostgresState.Stopping => (FirstRunCheckState.InProgress, null),
            PostgresState.Running => (FirstRunCheckState.Ready, null),
            PostgresState.NeedsMigration => (FirstRunCheckState.InProgress, null),
            PostgresState.Failed => (FirstRunCheckState.Failed, database.FailureMessage),
            _ => (FirstRunCheckState.Pending, null),
        };
        (FirstRunCheckState state, string? message) schema = database.State switch
        {
            PostgresState.Running when schemaApplied == true && !isApplyingSchema => (FirstRunCheckState.Ready, null),
            PostgresState.Running or PostgresState.NeedsMigration when schemaApplied == false && !isApplyingSchema =>
                (FirstRunCheckState.Failed, "The schema could not be applied. Check Again on the Database page."),
            PostgresState.Running or PostgresState.NeedsMigration => (isApplyingSchema || schemaApplied is null ? FirstRunCheckState.InProgress : FirstRunCheckState.Pending, null),
            PostgresState.Failed => (FirstRunCheckState.Failed, database.FailureMessage),
            _ => (FirstRunCheckState.Pending, null),
        };
        bool databaseReady = db.state == FirstRunCheckState.Ready;
        List<FirstRunServiceCheck> checks =
        [
            new("postgres", "Database", "Starting Garage's PostgreSQL + pgvector", db.state, db.message),
            new("schema", "Schema", "Applying the schema", schema.state, schema.message),
            Service("grpc", "Index Manager", "Starting the service that runs ingest, search and models", backend, databaseReady),
        ];
        // With HTTP off there is no server to wait for: assistants start Garage themselves over stdio.
        if (mcpHttpEnabled)
        {
            checks.Add(Service("mcp", "MCP server", "Starting the local MCP endpoint your assistants connect to", mcp, databaseReady));
        }
        return checks;
    }

    /// <summary>Everything the rest of the assistant needs is up. The MCP server is not required: a port clash must not trap the user on the first page.</summary>
    public static bool IsReady(IReadOnlyList<FirstRunServiceCheck> checks) =>
        checks.Where(c => RequiredIds.Contains(c.Id)).All(c => c.IsReady);

    /// <summary>Any row failed, the optional MCP server included.</summary>
    public static bool HasFailure(IReadOnlyList<FirstRunServiceCheck> checks) => checks.Any(c => c.IsFailed);

    /// <summary>A row the assistant cannot go on without has failed.</summary>
    public static bool HasBlockingFailure(IReadOnlyList<FirstRunServiceCheck> checks) =>
        checks.Where(c => RequiredIds.Contains(c.Id)).Any(c => c.IsFailed);

    private static FirstRunServiceCheck Service(string id, string title, string detail, McpServerStatus status, bool databaseReady)
    {
        (FirstRunCheckState state, string? message) = status.State switch
        {
            McpServerState.Stopped => (databaseReady ? FirstRunCheckState.InProgress : FirstRunCheckState.Pending, (string?)null),
            McpServerState.Starting or McpServerState.Stopping => (FirstRunCheckState.InProgress, null),
            McpServerState.Running => (FirstRunCheckState.Ready, null),
            McpServerState.Failed => (FirstRunCheckState.Failed, status.FailureMessage),
            _ => (FirstRunCheckState.Pending, null),
        };
        return new(id, title, detail, state, message);
    }
}

/// <summary>A ready-made source the "Select your data" page offers (the Mac's <c>FirstRunSourceTemplate</c>).</summary>
public sealed record FirstRunSourceTemplate(
    string Id,
    string Title,
    string Subtitle,
    SourceSymbol Symbol,
    string Slug,
    string Root,
    string Kind,
    string CorpusClass,
    string Trust,
    bool IsAvailable,
    bool IsCustom)
{
    /// <summary>The registration <c>AddSource</c> takes, as the Sources page sends it.</summary>
    public NewSource Spec => new(Slug, Root, Kind, CorpusClass, Trust);

    /// <summary>Folders on this PC that are commonly indexed.</summary>
    public sealed record Folders(string Home, string Documents, string Desktop, string Downloads, string? OneDrive, string? Dropbox, string? GoogleDrive);

    /// <summary>
    /// The built-in templates, with availability checked against the file system: the Windows
    /// counterparts of the Mac's (Documents, Desktop, Downloads, Dropbox, a code folder), plus
    /// OneDrive and Google Drive for desktop in place of iCloud Drive. Mail and Messages have no
    /// Windows source. <paramref name="exists"/> is injectable for tests.
    /// </summary>
    public static IReadOnlyList<FirstRunSourceTemplate> BuiltIn(Folders folders, Func<string, bool>? exists = null)
    {
        ArgumentNullException.ThrowIfNull(folders);
        exists ??= Directory.Exists;
        FirstRunSourceTemplate Make(string id, string title, string subtitle, SourceSymbol symbol, string? root,
            string kind = "filesystem", string corpusClass = "document", string trust = "authored") =>
            new(id, title, subtitle, symbol, id, root ?? "", kind, corpusClass, trust, root is not null && exists(root), false);

        return
        [
            Make("documents", "Documents", "Your Documents folder", SourceSymbol.Documents, folders.Documents),
            Make("desktop", "Desktop", "Files kept on the desktop", SourceSymbol.Desktop, folders.Desktop),
            Make("downloads", "Downloads", "Received files and installers", SourceSymbol.Downloads, folders.Downloads, trust: "received"),
            Make("onedrive", "OneDrive", "Files synced through OneDrive", SourceSymbol.Cloud, folders.OneDrive),
            Make("dropbox", "Dropbox", "Your Dropbox folder", SourceSymbol.Cloud, folders.Dropbox),
            Make("google-drive", "Google Drive", "My Drive, through Google Drive for desktop", SourceSymbol.Cloud, folders.GoogleDrive),
            Make("repos", "Code", @"Repositories under ~\source\repos", SourceSymbol.Code, Path.Combine(folders.Home, "source", "repos"), kind: "git", corpusClass: "code"),
        ];
    }

    /// <summary>This account's folders: known folders, and the sync clients' own records of where they keep files.</summary>
    public static Folders ThisPc(Func<string, string?>? environment = null)
    {
        environment ??= Environment.GetEnvironmentVariable;
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string? oneDrive = environment("OneDrive") ?? environment("OneDriveConsumer") ?? environment("OneDriveCommercial");
        string? googleDrive = DriveInfo.GetDrives()
            .Where(d => d.DriveType is DriveType.Fixed or DriveType.Network)
            .Select(d => Path.Combine(d.Name, "My Drive"))
            .FirstOrDefault(Directory.Exists);
        return new Folders(
            home,
            Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
            Path.Combine(home, "Downloads"),
            string.IsNullOrWhiteSpace(oneDrive) ? null : oneDrive,
            DropboxFolder(environment("LOCALAPPDATA"), environment("APPDATA")) ?? Path.Combine(home, "Dropbox"),
            googleDrive);
    }

    /// <summary>
    /// Where Dropbox keeps its files, from its own <c>info.json</c> (the personal account first, then the
    /// business one), as the Mac's <c>DropboxFolder.locate</c> reads it; null without one.
    /// </summary>
    public static string? DropboxFolder(params string?[] appDataFolders)
    {
        ArgumentNullException.ThrowIfNull(appDataFolders);
        foreach (string? folder in appDataFolders)
        {
            if (string.IsNullOrEmpty(folder))
            {
                continue;
            }
            string info = Path.Combine(folder, "Dropbox", "info.json");
            try
            {
                if (!File.Exists(info))
                {
                    continue;
                }
                using JsonDocument json = JsonDocument.Parse(File.ReadAllText(info));
                foreach (string account in (string[])["personal", "business"])
                {
                    if (json.RootElement.TryGetProperty(account, out JsonElement entry)
                        && entry.TryGetProperty("path", out JsonElement path)
                        && path.GetString() is { Length: > 0 } value)
                    {
                        return value;
                    }
                }
            }
            catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
            {
                // An unreadable info.json is no Dropbox.
            }
        }
        return null;
    }

    /// <summary>A template for a folder picked with Add Folder…, with a slug no other source has.</summary>
    public static FirstRunSourceTemplate Custom(string folder, IReadOnlySet<string> takenSlugs, string? home = null)
    {
        ArgumentNullException.ThrowIfNull(folder);
        string trimmed = folder.TrimEnd('\\', '/');
        string name = Path.GetFileName(trimmed);
        if (name.Length == 0)
        {
            name = trimmed;
        }
        string slug = SourceSlugSuggestion.UniqueSlug(SourceSlugSuggestion.SlugForFolderNamed(name), takenSlugs);
        return new("custom:" + folder, name, AbbreviatedPath(folder, home), SourceSymbol.Folder, slug, folder, "filesystem", "document", "authored", true, true);
    }

    /// <summary>A path under the home folder shown as <c>~\…</c>, as the rest of the app shows it.</summary>
    public static string AbbreviatedPath(string path, string? home = null)
    {
        ArgumentNullException.ThrowIfNull(path);
        home ??= Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string trimmedHome = home.TrimEnd('\\', '/');
        return trimmedHome.Length > 0 && path.StartsWith(trimmedHome + "\\", StringComparison.OrdinalIgnoreCase)
            ? "~" + path[trimmedHome.Length..]
            : path;
    }
}

/// <summary>A model the catalog (<c>data/models/models.json</c>) offers.</summary>
/// <param name="Slug">The catalog's name for it.</param>
/// <param name="Name">The display name.</param>
/// <param name="Featured">Listed first.</param>
/// <param name="NativeDims">Its width; null for a generative model.</param>
/// <param name="ModelRef">The name the built-in engine knows it by.</param>
/// <param name="ProviderRefs">The names other providers know it by (<c>ollama</c>, <c>lmstudio</c>).</param>
/// <param name="Description">A line about it.</param>
/// <param name="Tags">Its uses (<c>distillation</c>, <c>inference</c>); none means both.</param>
public sealed record ModelPreset(
    string Slug,
    string Name,
    bool Featured,
    int? NativeDims,
    string ModelRef,
    IReadOnlyDictionary<string, string> ProviderRefs,
    string Description = "",
    IReadOnlyList<string>? Tags = null)
{
    /// <summary>Whether it can distil facts: untagged models count, as on the Mac.</summary>
    public bool IsForDistillation => Tags is null || Tags.Contains("distillation");

    /// <summary>The name <paramref name="provider"/> knows it by: its own entry, else the catalog's reference.</summary>
    public string ReferenceFor(ModelProvider provider) =>
        ProviderRefs.TryGetValue(provider.CliValue(), out string? named) && named.Length > 0 ? named : ModelRef;
}

/// <summary>The model catalog: embedding presets and generative (distillation) presets.</summary>
public sealed record ModelCatalog(IReadOnlyList<ModelPreset> Embedding, IReadOnlyList<ModelPreset> Inference)
{
    /// <summary>An empty catalog: the assistant then registers nothing.</summary>
    public static ModelCatalog Empty { get; } = new([], []);

    /// <summary>The presets fit for distillation.</summary>
    public IReadOnlyList<ModelPreset> Distillation => [.. Inference.Where(p => p.IsForDistillation)];

    /// <summary>Parses <c>models.json</c>.</summary>
    /// <exception cref="JsonException">It is not the catalog.</exception>
    public static ModelCatalog Parse(string json)
    {
        using JsonDocument document = JsonDocument.Parse(json);
        return new(Read(document.RootElement, "text_embedding", requireDims: true), Read(document.RootElement, "inference_models", requireDims: false));
    }

    /// <summary>
    /// Finds and reads the catalog: <c>GARAGE_MODEL_MANIFEST</c>, then <c>data\models\models.json</c>
    /// beside the app, then in a checkout above it (as <c>garage_rag.db.catalog</c> finds it). Empty when none is readable.
    /// </summary>
    public static ModelCatalog Load(string appDirectory, Func<string, string?>? environment = null)
    {
        environment ??= Environment.GetEnvironmentVariable;
        List<string> candidates = [];
        if (environment("GARAGE_MODEL_MANIFEST") is { Length: > 0 } manifest)
        {
            candidates.Add(manifest);
        }
        for (DirectoryInfo? folder = new(appDirectory); folder is not null; folder = folder.Parent)
        {
            candidates.Add(Path.Combine(folder.FullName, "data", "models", "models.json"));
        }
        foreach (string candidate in candidates)
        {
            try
            {
                if (File.Exists(candidate))
                {
                    return Parse(File.ReadAllText(candidate));
                }
            }
            catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
            {
                // Try the next one.
            }
        }
        return Empty;
    }

    private static List<ModelPreset> Read(JsonElement root, string list, bool requireDims)
    {
        List<ModelPreset> presets = [];
        if (!root.TryGetProperty(list, out JsonElement entries) || entries.ValueKind != JsonValueKind.Array)
        {
            return presets;
        }
        foreach (JsonElement entry in entries.EnumerateArray())
        {
            string? slug = Text(entry, "slug");
            int? dims = entry.TryGetProperty("native_dims", out JsonElement d) && d.ValueKind == JsonValueKind.Number ? d.GetInt32() : null;
            if (slug is null || (requireDims && dims is null))
            {
                continue;
            }
            Dictionary<string, string> refs = new(StringComparer.Ordinal);
            if (entry.TryGetProperty("provider_refs", out JsonElement r) && r.ValueKind == JsonValueKind.Object)
            {
                foreach (JsonProperty p in r.EnumerateObject().Where(p => p.Value.ValueKind == JsonValueKind.String))
                {
                    refs[p.Name] = p.Value.GetString()!;
                }
            }
            List<string>? tags = entry.TryGetProperty("tags", out JsonElement t) && t.ValueKind == JsonValueKind.Array
                ? [.. t.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!)]
                : null;
            presets.Add(new ModelPreset(
                slug,
                Text(entry, "name") ?? slug,
                entry.TryGetProperty("featured", out JsonElement f) && f.ValueKind == JsonValueKind.True,
                dims,
                Text(entry, "model_ref") ?? slug,
                refs,
                Text(entry, "description") ?? "",
                tags));
        }
        return presets;
    }

    private static string? Text(JsonElement entry, string name) =>
        entry.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } text ? text : null;
}

/// <summary>The models page's plan (the Mac's <c>FirstRunModelPlan</c>).</summary>
public static class FirstRunModelPlan
{
    /// <summary>Featured presets first, then the rest by name: the order the picker shows them in.</summary>
    public static IReadOnlyList<ModelPreset> Ordered(IEnumerable<ModelPreset> presets) =>
        [.. presets.OrderByDescending(p => p.Featured).ThenBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase)];

    /// <summary>The embedding model picked to begin with: the first featured preset, else the first.</summary>
    public static IReadOnlySet<string> DefaultSelection(IEnumerable<ModelPreset> presets) =>
        Ordered(presets) is { Count: > 0 } ordered ? new HashSet<string>(StringComparer.Ordinal) { ordered[0].Slug } : new HashSet<string>(StringComparer.Ordinal);

    /// <summary>
    /// The providers the assistant offers on this PC: Ollama and LM Studio. The built-in engine
    /// joins them with Garage's own llama.cpp service (windows.md Phase 4).
    /// </summary>
    public static IReadOnlyList<ModelProvider> Providers { get; } = [ModelProvider.Ollama, ModelProvider.LmStudio];

    /// <summary>How a picked embedding preset is registered with <paramref name="provider"/>.</summary>
    public static NewModel Registration(ModelPreset preset, ModelProvider provider, bool makeDefault)
    {
        ArgumentNullException.ThrowIfNull(preset);
        return new NewModel(preset.Slug, provider, preset.NativeDims ?? 0, preset.ReferenceFor(provider), makeDefault);
    }

    /// <summary>"Registering BGE-M3…", worded as on the Mac.</summary>
    public static string Registering(string name) => string.Create(CultureInfo.CurrentCulture, $"Registering {name}…");
}
