using Garage.App.Core.Database;
using Garage.App.Core.Library;
using Garage.App.Core.Mcp;
using Garage.App.Core.Models;
using Garage.App.Core.Onboarding;
using Garage.App.Core.Operations;
using Garage.App.Core.Sources;
using Garage.App.Core.State;
using Garage.App.Core.Tests.TestSupport;

namespace Garage.App.Core.Tests;

// Ported from macapp/Tests/GarageAppUnitTests/FirstRunTests.swift. The Windows templates are this
// PC's folders (OneDrive and Google Drive in place of iCloud Drive, no Mail or Messages), and the
// readiness rows read the app's own Postgres and services.
public sealed class FirstRunTests
{
    private static readonly McpServerStatus Up = new(McpServerState.Running);
    private static readonly McpServerStatus Down = new(McpServerState.Stopped);

    private static readonly FirstRunSourceTemplate.Folders TestFolders = new(
        @"C:\Users\tester", @"C:\Users\tester\Documents", @"C:\Users\tester\Desktop", @"C:\Users\tester\Downloads",
        @"C:\Users\tester\OneDrive", @"D:\Dropbox", null);

    // ---- Steps

    [Fact]
    public void Steps_are_ordered_and_linked()
    {
        Assert.Equal([FirstRunStep.SettingUp, FirstRunStep.SelectData, FirstRunStep.SelectModels, FirstRunStep.SetupAgent], FirstRunSteps.All);
        Assert.Equal(FirstRunStep.SelectData, FirstRunStep.SettingUp.Next());
        Assert.Equal(FirstRunStep.SelectModels, FirstRunStep.SelectData.Next());
        Assert.Equal(FirstRunStep.SetupAgent, FirstRunStep.SelectModels.Next());
        Assert.Null(FirstRunStep.SetupAgent.Next());
        Assert.Null(FirstRunStep.SettingUp.Previous());
        Assert.Equal(FirstRunStep.SelectModels, FirstRunStep.SetupAgent.Previous());
    }

    [Fact]
    public void Step_titles_match_the_flow()
    {
        Assert.Equal("Setting things up", FirstRunStep.SettingUp.Title());
        Assert.Equal("Select your data", FirstRunStep.SelectData.Title());
        Assert.Equal("Select your models", FirstRunStep.SelectModels.Title());
        Assert.Equal("Set up your assistant", FirstRunStep.SetupAgent.Title());
    }

    // ---- Readiness

    [Fact]
    public void Readiness_is_pending_while_everything_is_stopped()
    {
        IReadOnlyList<FirstRunServiceCheck> checks = FirstRunReadiness.Checks(new(PostgresState.Stopped), null, false, Down, Down);
        Assert.Equal(["postgres", "schema", "grpc", "mcp"], checks.Select(c => c.Id));
        Assert.All(checks, c => Assert.Equal(FirstRunCheckState.Pending, c.State));
        Assert.False(FirstRunReadiness.IsReady(checks));
        Assert.False(FirstRunReadiness.HasFailure(checks));
    }

    [Fact]
    public void Readiness_requires_database_schema_and_backend_but_not_mcp()
    {
        IReadOnlyList<FirstRunServiceCheck> checks = FirstRunReadiness.Checks(new(PostgresState.Running), true, false, Up, Down);
        Assert.True(FirstRunReadiness.IsReady(checks), "MCP is optional on the first page");
        Assert.Equal(FirstRunCheckState.InProgress, checks.Single(c => c.Id == "mcp").State);

        IReadOnlyList<FirstRunServiceCheck> withMcpFailure = FirstRunReadiness.Checks(new(PostgresState.Running), true, false, Up, new(McpServerState.Failed, "port in use"));
        Assert.True(FirstRunReadiness.IsReady(withMcpFailure));
        Assert.True(FirstRunReadiness.HasFailure(withMcpFailure));
        Assert.False(FirstRunReadiness.HasBlockingFailure(withMcpFailure), "an MCP port clash must not trap the user on page one");
    }

    [Fact]
    public void Readiness_leaves_out_mcp_when_http_is_off()
    {
        IReadOnlyList<FirstRunServiceCheck> checks = FirstRunReadiness.Checks(new(PostgresState.Running), true, false, Up, Down, mcpHttpEnabled: false);
        Assert.Equal(["postgres", "schema", "grpc"], checks.Select(c => c.Id));
        Assert.True(FirstRunReadiness.IsReady(checks));
    }

    [Fact]
    public void Readiness_tracks_the_schema()
    {
        IReadOnlyList<FirstRunServiceCheck> notYet = FirstRunReadiness.Checks(new(PostgresState.Running), null, false, Down, Down);
        Assert.Equal(FirstRunCheckState.InProgress, notYet.Single(c => c.Id == "schema").State);
        Assert.False(FirstRunReadiness.IsReady(notYet));

        IReadOnlyList<FirstRunServiceCheck> applying = FirstRunReadiness.Checks(new(PostgresState.Running), true, true, Up, Up);
        Assert.Equal(FirstRunCheckState.InProgress, applying.Single(c => c.Id == "schema").State);
        Assert.False(FirstRunReadiness.IsReady(applying));

        IReadOnlyList<FirstRunServiceCheck> failed = FirstRunReadiness.Checks(new(PostgresState.NeedsMigration), false, false, Up, Up);
        Assert.Equal(FirstRunCheckState.InProgress, failed.Single(c => c.Id == "postgres").State);
        Assert.Equal(FirstRunCheckState.Failed, failed.Single(c => c.Id == "schema").State);
        Assert.True(FirstRunReadiness.HasBlockingFailure(failed));
    }

    [Fact]
    public void Readiness_surfaces_a_postgres_failure()
    {
        IReadOnlyList<FirstRunServiceCheck> checks = FirstRunReadiness.Checks(new(PostgresState.Failed, "initdb failed"), null, false, Down, Down);
        Assert.Equal((FirstRunCheckState.Failed, "initdb failed"), (checks[0].State, checks[0].Message));
        Assert.Equal((FirstRunCheckState.Failed, "initdb failed"), (checks[1].State, checks[1].Message));
        Assert.True(FirstRunReadiness.HasFailure(checks));
        Assert.True(FirstRunReadiness.HasBlockingFailure(checks));
        Assert.False(FirstRunReadiness.IsReady(checks));
    }

    // ---- Source templates

    [Fact]
    public void Built_in_templates_resolve_availability_on_this_pc()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "Windows paths: System.IO.Path follows the host's rules");
        HashSet<string> present = [@"C:\Users\tester\Documents", @"C:\Users\tester\OneDrive", @"C:\Users\tester\source\repos"];
        IReadOnlyList<FirstRunSourceTemplate> templates = FirstRunSourceTemplate.BuiltIn(TestFolders, present.Contains);
        Assert.All(templates, t => Assert.False(t.IsCustom));

        FirstRunSourceTemplate documents = templates.Single(t => t.Id == "documents");
        Assert.True(documents.IsAvailable);
        Assert.Equal(@"C:\Users\tester\Documents", documents.Root);
        Assert.Equal("document", documents.CorpusClass);

        Assert.False(templates.Single(t => t.Id == "dropbox").IsAvailable);
        Assert.True(templates.Single(t => t.Id == "onedrive").IsAvailable);
        Assert.False(templates.Single(t => t.Id == "google-drive").IsAvailable, "no Google Drive folder was found");
        Assert.Equal("received", templates.Single(t => t.Id == "downloads").Trust);

        FirstRunSourceTemplate code = templates.Single(t => t.Id == "repos");
        Assert.True(code.IsAvailable);
        Assert.Equal(("git", "code"), (code.Kind, code.CorpusClass));
    }

    [Fact]
    public void Template_slugs_and_ids_are_unique_and_match_the_macs()
    {
        IReadOnlyList<FirstRunSourceTemplate> templates = FirstRunSourceTemplate.BuiltIn(TestFolders, _ => true);
        Assert.Equal(templates.Count, templates.Select(t => t.Slug).Distinct().Count());
        Assert.Equal(templates.Count, templates.Select(t => t.Id).Distinct().Count());
        // A garage.json shared with a Mac names these sources the same way.
        Assert.Subset(templates.Select(t => t.Slug).ToHashSet(), new HashSet<string> { "documents", "desktop", "downloads", "dropbox" });
    }

    [Fact]
    public void Spec_matches_the_add_source_rpc()
    {
        FirstRunSourceTemplate documents = FirstRunSourceTemplate.BuiltIn(TestFolders, _ => true)[0];
        Assert.Equal(new NewSource("documents", @"C:\Users\tester\Documents", "filesystem", "document", "authored"), documents.Spec);
    }

    [Fact]
    public void Dropbox_is_found_through_its_info_json()
    {
        string folder = Path.Combine(Path.GetTempPath(), "garage-dropbox-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(folder, "Dropbox"));
        try
        {
            Assert.Null(FirstRunSourceTemplate.DropboxFolder(folder));
            File.WriteAllText(Path.Combine(folder, "Dropbox", "info.json"), """{"business": {"path": "E:\\Work Dropbox"}, "personal": {"path": "D:\\Dropbox"}}""");
            Assert.Equal(@"D:\Dropbox", FirstRunSourceTemplate.DropboxFolder(null, folder));
            File.WriteAllText(Path.Combine(folder, "Dropbox", "info.json"), "not json");
            Assert.Null(FirstRunSourceTemplate.DropboxFolder(folder));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void Custom_template_uses_the_folder_and_avoids_taken_slugs()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "Windows paths: System.IO.Path follows the host's rules");
        FirstRunSourceTemplate template = FirstRunSourceTemplate.Custom(@"E:\Archive\Old Notes", new HashSet<string> { "old-notes" }, @"C:\Users\tester");
        Assert.True(template.IsCustom);
        Assert.True(template.IsAvailable);
        Assert.Equal("Old Notes", template.Title);
        Assert.Equal("old-notes-2", template.Slug);
        Assert.Equal(@"E:\Archive\Old Notes", template.Root);
        Assert.Equal(@"E:\Archive\Old Notes", template.Subtitle);
        Assert.Equal(@"custom:E:\Archive\Old Notes", template.Id);
        Assert.Equal(@"~\Notes", FirstRunSourceTemplate.Custom(@"C:\Users\tester\Notes", new HashSet<string>(), @"C:\Users\tester").Subtitle);
    }

    // ---- Model plan

    private static ModelPreset Preset(string slug, string name, bool featured = false, int? dims = 1024, Dictionary<string, string>? refs = null, string[]? tags = null) =>
        new(slug, name, featured, dims, slug, refs ?? [], "", tags);

    [Fact]
    public void Ordered_puts_featured_presets_first_and_default_selects_the_first()
    {
        ModelPreset[] presets = [Preset("zeta", "Zeta"), Preset("beta", "Beta", true), Preset("alpha", "Alpha"), Preset("gamma", "Gamma", true)];
        Assert.Equal(["beta", "gamma", "alpha", "zeta"], FirstRunModelPlan.Ordered(presets).Select(p => p.Slug));
        Assert.Equal(["beta"], FirstRunModelPlan.DefaultSelection(presets));
        Assert.Empty(FirstRunModelPlan.DefaultSelection([]));
    }

    [Fact]
    public void A_preset_is_registered_under_the_name_its_provider_knows()
    {
        ModelPreset qwen = Preset("qwen3-embedding-0.6b", "Qwen", refs: new() { ["ollama"] = "qwen3-embedding:0.6b" });
        Assert.Equal(new NewModel("qwen3-embedding-0.6b", ModelProvider.Ollama, 1024, "qwen3-embedding:0.6b", true), FirstRunModelPlan.Registration(qwen, ModelProvider.Ollama, true));
        Assert.Equal("qwen3-embedding-0.6b", FirstRunModelPlan.Registration(qwen, ModelProvider.LmStudio, false).ModelRef);
        Assert.Equal([ModelProvider.Ollama, ModelProvider.LmStudio], FirstRunModelPlan.Providers);
    }

    [Fact]
    public void The_catalog_is_read_from_models_json()
    {
        ModelCatalog catalog = ModelCatalog.Parse("""
            {"text_embedding": [
              {"slug": "bge-m3", "name": "BGE-M3", "featured": true, "native_dims": 1024, "model_ref": "bge-m3"},
              {"slug": "no-dims", "name": "Not an embedder"}],
             "inference_models": [
              {"slug": "gemma2-2b", "name": "Gemma 2 2B", "featured": true, "provider_refs": {"ollama": "gemma2:2b"}},
              {"slug": "chat-only", "name": "Chat", "tags": ["inference"]}]}
            """);
        Assert.Equal(["bge-m3"], catalog.Embedding.Select(p => p.Slug));
        Assert.Equal(["gemma2-2b"], catalog.Distillation.Select(p => p.Slug));
        Assert.Equal("gemma2:2b", catalog.Inference[0].ReferenceFor(ModelProvider.Ollama));
    }

    [Fact]
    public void The_repositorys_catalog_loads()
    {
        ModelCatalog catalog = ModelCatalog.Load(AppContext.BaseDirectory, _ => null);
        Assert.Contains(catalog.Embedding, p => p.Slug == "bge-m3" && p.NativeDims == 1024 && p.Featured);
        Assert.NotEmpty(catalog.Distillation);
    }

    // ---- Coordinator

    private static FirstRunCoordinator Coordinator(IPreferences? preferences = null, bool persists = true, bool afterReset = false) =>
        new(preferences ?? new MemoryPreferences(), persists, afterReset) { Folders = () => TestFolders };

    [Fact]
    public void A_new_install_opens_on_the_assistant()
    {
        FirstRunCoordinator coordinator = Coordinator();
        Assert.True(coordinator.IsActive);
        Assert.False(coordinator.HasCompleted);
        Assert.Equal(FirstRunStep.SettingUp, coordinator.Step);
    }

    [Fact]
    public void A_completed_install_does_not()
    {
        var preferences = new MemoryPreferences();
        preferences.Write(FirstRunCoordinator.CompletedKey, true);
        Assert.False(Coordinator(preferences).IsActive);
    }

    [Fact]
    public void Relaunch_after_database_reset_opens_on_the_assistant()
    {
        var preferences = new MemoryPreferences();
        preferences.Write(FirstRunCoordinator.CompletedKey, true);
        FirstRunCoordinator coordinator = Coordinator(preferences, afterReset: true);
        Assert.True(coordinator.IsActive);
        Assert.True(coordinator.IsAfterDatabaseReset);
        Assert.Equal(FirstRunStep.SettingUp, coordinator.Step);
    }

    [Fact]
    public void Begin_and_finish_toggle_activity_and_remember_completion()
    {
        var preferences = new MemoryPreferences();
        FirstRunCoordinator coordinator = Coordinator(preferences);
        coordinator.Begin();
        Assert.True(coordinator.IsActive);
        Assert.NotEmpty(coordinator.SourceTemplates);

        coordinator.Finish();
        Assert.False(coordinator.IsActive);
        Assert.True(coordinator.HasCompleted);
        Assert.True(preferences.Read(FirstRunCoordinator.CompletedKey, false));

        // Once completed, a plain Begin is a no-op; force re-opens it.
        coordinator.Begin();
        Assert.False(coordinator.IsActive);
        coordinator.Begin(force: true);
        Assert.True(coordinator.IsActive);

        coordinator.Skip();
        Assert.False(coordinator.IsActive);
        Assert.True(coordinator.HasCompleted);

        coordinator.ResetCompletion();
        Assert.False(coordinator.HasCompleted);
    }

    [Fact]
    public void Completion_on_a_throwaway_data_folder_is_not_saved()
    {
        var preferences = new MemoryPreferences();
        FirstRunCoordinator coordinator = Coordinator(preferences, persists: false);
        coordinator.Begin();
        coordinator.Finish();
        Assert.True(coordinator.HasCompleted, "a finished assistant counts as completed for the rest of the launch");
        Assert.False(preferences.Read(FirstRunCoordinator.CompletedKey, false), "finishing saved the preference");
    }

    [Fact]
    public void After_database_reset_runs_even_when_completed_and_clears_on_skip()
    {
        FirstRunCoordinator coordinator = Coordinator();
        coordinator.Begin();
        coordinator.Finish();
        coordinator.Begin(afterDatabaseReset: true);
        Assert.True(coordinator.IsActive);
        Assert.True(coordinator.IsAfterDatabaseReset);

        coordinator.Skip();
        Assert.False(coordinator.IsActive);
        Assert.False(coordinator.IsAfterDatabaseReset);
        coordinator.Begin(force: true);
        Assert.False(coordinator.IsAfterDatabaseReset);
    }

    [Fact]
    public void Source_selection_ignores_unavailable_templates_and_dedupes_custom_folders()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "Windows paths: System.IO.Path follows the host's rules");
        FirstRunCoordinator coordinator = Coordinator();
        var available = new FirstRunSourceTemplate("documents", "Documents", "", SourceSymbol.Documents, "documents", @"C:\Docs", "filesystem", "document", "authored", true, false);
        var missing = new FirstRunSourceTemplate("dropbox", "Dropbox", "", SourceSymbol.Cloud, "dropbox", @"C:\Dropbox", "filesystem", "document", "authored", false, false);
        coordinator.SetSourceTemplatesForTesting([available, missing]);

        coordinator.ToggleSource(missing);
        Assert.Empty(coordinator.SelectedSourceIds);
        coordinator.ToggleSource(available);
        Assert.Equal(["documents"], coordinator.SelectedSources.Select(s => s.Slug));
        coordinator.ToggleSource(available);
        Assert.Empty(coordinator.SelectedSourceIds);

        coordinator.AddCustomFolder(@"C:\tmp\garage-first-run\Documents");
        coordinator.AddCustomFolder(@"C:\tmp\garage-first-run\Documents");
        FirstRunSourceTemplate custom = Assert.Single(coordinator.SourceTemplates, t => t.IsCustom);
        Assert.Equal("documents-2", custom.Slug);
        Assert.Contains(custom.Id, coordinator.SelectedSourceIds);

        coordinator.RemoveCustomFolder(custom);
        Assert.DoesNotContain(coordinator.SourceTemplates, t => t.IsCustom);
        Assert.DoesNotContain(custom.Id, coordinator.SelectedSourceIds);
        coordinator.RemoveCustomFolder(available);
        Assert.Equal(2, coordinator.SourceTemplates.Count);
    }

    [Fact]
    public void Model_and_client_toggles_and_back_navigation()
    {
        FirstRunCoordinator coordinator = Coordinator();
        ModelPreset embedding = Preset("bge-m3", "BGE-M3");
        ModelPreset gemma = Preset("gemma2-2b", "Gemma", dims: null, refs: new() { ["ollama"] = "gemma2:2b" });
        ModelPreset llama = Preset("llama-3.2-1b-instruct", "Llama", dims: null);

        coordinator.ToggleEmbedding(embedding);
        coordinator.ToggleDistillation(gemma);
        Assert.Equal(["bge-m3"], coordinator.SelectedEmbeddingSlugs);
        Assert.Equal("gemma2:2b", coordinator.DistillationModel);
        // A single slot: another replaces it, the same one again clears it.
        coordinator.ToggleDistillation(llama);
        Assert.Equal("llama-3.2-1b-instruct", coordinator.DistillationModel);
        coordinator.ToggleDistillation(llama);
        Assert.Equal("", coordinator.DistillationModel);
        coordinator.ToggleEmbedding(embedding);
        Assert.Empty(coordinator.SelectedEmbeddingSlugs);

        coordinator.ToggleClient("claude-desktop");
        Assert.Equal(["claude-desktop"], coordinator.SelectedClientKeys);
        coordinator.ToggleClient("claude-desktop");
        Assert.Empty(coordinator.SelectedClientKeys);

        coordinator.SetStepForTesting(FirstRunStep.SetupAgent);
        coordinator.GoBack();
        Assert.Equal(FirstRunStep.SelectModels, coordinator.Step);
        coordinator.GoBack();
        Assert.Equal(FirstRunStep.SelectData, coordinator.Step);
        coordinator.GoBack();
        Assert.Equal(FirstRunStep.SelectData, coordinator.Step);
    }

    [Fact]
    public async Task Commit_sources_without_the_sources_page_stays_put()
    {
        FirstRunCoordinator coordinator = Coordinator();
        coordinator.SetStepForTesting(FirstRunStep.SelectData);
        await coordinator.CommitSourcesAsync();
        Assert.Equal(FirstRunStep.SelectData, coordinator.Step);
    }

    [Fact]
    public void Looks_already_configured()
    {
        Assert.False(FirstRunCoordinator.LooksAlreadyConfigured(0, 0));
        Assert.True(FirstRunCoordinator.LooksAlreadyConfigured(1, 0));
        Assert.True(FirstRunCoordinator.LooksAlreadyConfigured(0, 1));
    }

    // ---- The walk, against the pages' own view models

    private sealed record Walk(FirstRunCoordinator Coordinator, FakeGarageClient Client, LibraryCoordinator Library);

    private static Walk Setup(Action<FakeGarageClient>? configure = null, IPreferences? preferences = null)
    {
        var client = new FakeGarageClient
        {
            OnMcpStatus = _ => new McpStatusResponse
            {
                Clients =
                {
                    new McpClientInfo { Key = "claude-desktop", Label = "Claude Desktop", Path = @"C:\cfg\claude.json", ConfigExists = true },
                    new McpClientInfo { Key = "cursor", Label = "Cursor", Path = @"C:\cfg\cursor.json", ConfigExists = false },
                },
            },
        };
        configure?.Invoke(client);
        var operations = new OperationRunner();
        var library = new LibraryCoordinator(client, NoIngestHost.Instance, LibraryJobs.None, new MemoryPreferences(), SilentNotifier.Instance);
        var coordinator = new FirstRunCoordinator(preferences ?? new MemoryPreferences())
        {
            Folders = () => TestFolders,
            FolderExists = _ => true,
            Sources = new SourcesViewModel(client, operations, checkAccess: _ => new SourceAccess(true, true, ""), library: library),
            Models = new ModelsViewModel(client, operations, new OperationRunner("backfill")),
            Mcp = new McpViewModel(client, operations, _ => null),
            Library = library,
            Catalog = ModelCatalog.Parse("""
                {"text_embedding": [{"slug": "bge-m3", "name": "BGE-M3", "featured": true, "native_dims": 1024},
                                    {"slug": "nomic-embed-text", "name": "Nomic", "native_dims": 768}],
                 "inference_models": [{"slug": "gemma2-2b", "name": "Gemma 2 2B", "provider_refs": {"ollama": "gemma2:2b"}}]}
                """),
            ReadServices = () => new(new(PostgresState.Running), true, false, Up, Down, false),
        };
        return new Walk(coordinator, client, library);
    }

    private static async Task Until(Func<bool> condition)
    {
        for (int i = 0; i < 200 && !condition(); i++)
        {
            await Task.Delay(25, TestContext.Current.CancellationToken);
        }
        Assert.True(condition());
    }

    [Fact]
    public async Task The_assistant_walks_from_services_to_assistants()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "Windows paths: System.IO.Path follows the host's rules");
        Walk walk = Setup();
        FirstRunCoordinator coordinator = walk.Coordinator;
        coordinator.Begin();
        await Until(() => coordinator.Step == FirstRunStep.SelectData);
        Assert.True(coordinator.ServicesReady);
        // Documents is picked to begin with, when it is there.
        Assert.Equal(["documents"], coordinator.SelectedSourceIds);
        coordinator.AddCustomFolder(@"E:\Projects");

        await coordinator.CommitSourcesAsync();
        Assert.Null(coordinator.ErrorMessage);
        Assert.Equal(FirstRunStep.SelectModels, coordinator.Step);
        AddSourceRequest[] added = [.. walk.Client.Requests.OfType<AddSourceRequest>()];
        Assert.Equal(["documents", "projects"], added.Select(a => a.Slug));
        Assert.Equal(@"C:\Users\tester\Documents", added[0].Root);
        // The featured preset is picked; the distillation preset as Ollama names it.
        Assert.Equal(["bge-m3"], coordinator.SelectedEmbeddingSlugs);
        coordinator.ToggleDistillation(coordinator.DistillationPresets[0]);

        await coordinator.CommitModelsAsync();
        Assert.Null(coordinator.ErrorMessage);
        Assert.Equal(FirstRunStep.SetupAgent, coordinator.Step);
        RegisterModelRequest registered = Assert.Single(walk.Client.Requests.OfType<RegisterModelRequest>());
        Assert.Equal(("bge-m3", "ollama", 1024, "bge-m3", true), (registered.Slug, registered.Provider, registered.Dims, registered.ModelRef, registered.MakeDefault));
        Assert.Contains(walk.Client.Requests.OfType<SetSettingRequest>(), s => s.Name == "facts.model" && s.Value == "gemma2:2b");
        Assert.Contains(walk.Client.Requests.OfType<SetSettingRequest>(), s => s.Name == "facts.provider" && s.Value == "ollama");

        // Installed, unconnected assistants are picked; one not on this PC is not.
        Assert.Equal(["claude-desktop"], coordinator.SelectedClientKeys);
        await coordinator.RegisterSelectedClientsAsync();
        McpInstallRequest install = Assert.Single(walk.Client.Requests.OfType<McpInstallRequest>());
        Assert.Equal(("claude-desktop", true), (install.Target, install.Stdio));
        Assert.StartsWith("✓ Claude Desktop", coordinator.RegistrationSummary, StringComparison.Ordinal);

        coordinator.Finish();
        Assert.False(coordinator.IsActive);
    }

    [Fact]
    public async Task An_install_with_sources_skips_the_assistant()
    {
        Walk walk = Setup(c => c.OnListSources = _ => new ListSourcesResponse { Sources = { new SourceInfo { Slug = "notes", Root = @"C:\notes", Kind = "filesystem", CorpusClass = "document", TrustTier = "authored", Enabled = true } } });
        bool finished = false;
        walk.Coordinator.Finished += (_, _) => finished = true;
        walk.Coordinator.Begin();
        await Until(() => !walk.Coordinator.IsActive);
        Assert.True(finished);
        Assert.True(walk.Coordinator.HasCompleted);
    }

    [Fact]
    public async Task A_failing_source_keeps_the_data_page_with_the_reason()
    {
        Walk walk = Setup(c => c.OnAddSource = _ => throw new global::Grpc.Core.RpcException(new global::Grpc.Core.Status(global::Grpc.Core.StatusCode.InvalidArgument, "root does not exist")));
        walk.Coordinator.Begin();
        await Until(() => walk.Coordinator.Step == FirstRunStep.SelectData);
        await walk.Coordinator.CommitSourcesAsync();
        Assert.Equal(FirstRunStep.SelectData, walk.Coordinator.Step);
        Assert.StartsWith("Some sources could not be added:\ndocuments: ", walk.Coordinator.ErrorMessage, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_service_that_failed_stops_on_page_one_until_retried()
    {
        Walk walk = Setup();
        bool failing = true;
        walk.Coordinator.ReadServices = () => failing
            ? new(new(PostgresState.Failed, "initdb failed"), null, false, Down, Down, false)
            : new(new(PostgresState.Running), true, false, Up, Down, false);
        walk.Coordinator.RestartServices = () =>
        {
            failing = false;
            return Task.CompletedTask;
        };
        walk.Coordinator.Begin();
        await Until(() => walk.Coordinator.ServicesFailed);
        Assert.Equal(FirstRunStep.SettingUp, walk.Coordinator.Step);
        await walk.Coordinator.RetryServicesAsync();
        await Until(() => walk.Coordinator.Step == FirstRunStep.SelectData);
    }

    [Fact]
    public async Task Maintenance_waits_until_the_assistant_closes()
    {
        Walk walk = Setup();
        walk.Coordinator.Begin();
        Assert.False(await walk.Library.RunScheduledAsync());
        Assert.True(walk.Library.IsDeferredForFirstRun);
        walk.Coordinator.Finish();
        Assert.False(walk.Library.IsDeferredForFirstRun);
    }
}
