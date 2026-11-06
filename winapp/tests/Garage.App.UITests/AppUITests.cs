using System.Diagnostics;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.WindowsAPI;

namespace Garage.App.UITests;

// The UI tests windows-ui.md §5 lists, mirroring macapp/Tests/GarageAppUITests (SetupAssistant,
// Pages, MenuBarAsk, Sources, Logs). Automation ids match the Mac's accessibilityIdentifiers where
// both apps have the control (menubar.*, status.*, firstRun.*).
public sealed class AppUITests
{
    private static string Name(AutomationElement element) => element.Name ?? "";

    [Fact]
    public async Task The_setup_assistant_walks_from_services_to_assistants()
    {
        string oneDrive = Path.Combine(Path.GetTempPath(), "garage-uitest-onedrive-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(oneDrive);
        try
        {
            await using AppSession session = await AppSession.StartAsync(firstRunDone: false, environment: new Dictionary<string, string> { ["OneDrive"] = oneDrive });
            Window main = session.Main;
            AppSession.Until(() => Name(AppSession.Find(main, "firstRun.title")) == "Select your data", "the assistant did not reach the data page");

            // Only the test's own folder: Documents is this PC's real one.
            CheckBox documents = AppSession.Find(main, "firstRun.source.documents").AsCheckBox();
            if (documents.IsChecked == true)
            {
                documents.Toggle();
            }
            AppSession.Find(main, "firstRun.source.onedrive").AsCheckBox().Toggle();
            AppSession.Find(main, "firstRun.continue").AsButton().Invoke();

            AppSession.Until(() => Name(AppSession.Find(main, "firstRun.title")) == "Select your models", "the assistant did not reach the models page");
            Assert.True(AppSession.Find(main, "firstRun.embedding.bge-m3").AsCheckBox().IsChecked, "the featured embedding model is picked to begin with");
            AppSession.Find(main, "firstRun.distillation").AsTextBox().Text = "gemma2:2b";
            AppSession.Find(main, "firstRun.continue").AsButton().Invoke();

            AppSession.Until(() => Name(AppSession.Find(main, "firstRun.title")) == "Set up your assistant", "the assistant did not reach the agent page");
            Assert.True(AppSession.Find(main, "firstRun.client.claude-desktop").AsCheckBox().IsChecked, "an installed, unconnected assistant is picked");
            AppSession.Find(main, "firstRun.connect").AsButton().Invoke();
            AppSession.Until(() => Name(AppSession.Find(main, "firstRun.summary")).StartsWith("✓ Claude Desktop", StringComparison.Ordinal), "the assistant was not connected");
            AppSession.Find(main, "firstRun.continue").AsButton().Invoke();

            // The pages come back, and the backend got what the assistant chose.
            AppSession.Find(main, "status.refresh");
            AddSourceRequest added = Assert.Single(session.Backend.Garage.Requests.OfType<AddSourceRequest>());
            Assert.Equal(("onedrive", oneDrive), (added.Slug, added.Root));
            RegisterModelRequest model = Assert.Single(session.Backend.Garage.Requests.OfType<RegisterModelRequest>());
            Assert.Equal(("bge-m3", "ollama", true), (model.Slug, model.Provider, model.MakeDefault));
            Assert.Contains(session.Backend.Garage.Requests.OfType<SetSettingRequest>(), s => s.Name == "facts.model" && s.Value == "gemma2:2b");
            Assert.Equal("claude-desktop", Assert.Single(session.Backend.Garage.Requests.OfType<McpInstallRequest>()).Target);
            Assert.Contains("\"firstRun.completed\": true", File.ReadAllText(Path.Combine(session.DataDirectory, "app-settings.json")), StringComparison.Ordinal);
        }
        finally
        {
            Directory.Delete(oneDrive, recursive: true);
        }
    }

    [Fact]
    public async Task Search_runs_the_query_and_lists_the_hits()
    {
        await using AppSession session = await AppSession.StartAsync();
        session.ShowPage("Search");
        Window main = session.Main;
        AppSession.Find(main, "search.query").AsTextBox().Text = "workbench";
        AppSession.Find(main, "search.run").AsButton().Invoke();
        AppSession.Until(() => Name(AppSession.Find(main, "search.status")).StartsWith("2 results for 'workbench'", StringComparison.Ordinal), "the search did not report its results");
        Assert.Equal(2, AppSession.Find(main, "search.results").FindAllChildren().Length);
        Assert.Contains(session.Backend.Garage.Requests.OfType<SearchRequest>(), r => r.Query == "workbench");
    }

    [Fact]
    public async Task Ask_Garage_from_the_tray_shows_the_answer_and_its_sources()
    {
        await using AppSession session = await AppSession.StartAsync();
        _ = session.Main;
        // The jump list's Ask Garage task: a second launch hands it over and the flyout opens.
        session.Relaunch("--do", "ask");
        Window flyout = FlaUI.Core.Tools.Retry.WhileNull(() => session.FindWindow("Garage Search"), AppSession.Timeout, throwOnTimeout: true).Result!;
        AppSession.Find(flyout, "menubar.search").AsTextBox().Text = "Where is the workbench?";
        AppSession.Find(flyout, "menubar.ask").AsButton().Invoke();
        AppSession.Until(() => Name(AppSession.Find(flyout, "menubar.answer.text")) == FakeBackend.Answer, "the answer did not show");
        Assert.Equal("Searched once · deterministic", Name(AppSession.Find(flyout, "menubar.answer.footnote")));
        Assert.NotNull(AppSession.Find(flyout, "menubar.answer.citation"));
        Assert.Equal(["Where is the workbench?"], session.Backend.Questions);
    }

    [Fact]
    public async Task Add_Source_from_the_jump_list_registers_the_folder()
    {
        await using AppSession session = await AppSession.StartAsync();
        _ = session.Main;
        session.Relaunch("--do", "add-source");
        Window main = session.Main;
        TextBox folder = FlaUI.Core.Tools.Retry.WhileNull(
            () => main.FindFirstDescendant(cf => cf.ByName("Folder").And(cf.ByControlType(ControlType.Edit)))?.AsTextBox(),
            AppSession.Timeout, throwOnTimeout: true).Result!;
        folder.Text = @"C:\fake\Projects";
        AppSession.Until(() => main.FindFirstDescendant(cf => cf.ByName("Name").And(cf.ByControlType(ControlType.Edit)))?.AsTextBox().Text == "projects",
            "the name was not suggested from the folder");
        AppSession.Find(main, "PrimaryButton").AsButton().Invoke();
        AppSession.Until(() => session.Backend.Garage.Requests.OfType<AddSourceRequest>().Any(), "the source was not added");
        AddSourceRequest added = session.Backend.Garage.Requests.OfType<AddSourceRequest>().Single();
        Assert.Equal(("projects", @"C:\fake\Projects"), (added.Slug, added.Root));
    }

    [Fact]
    public async Task The_logs_status_bar_counts_the_entries()
    {
        await using AppSession session = await AppSession.StartAsync();
        Window main = session.Main;
        session.ShowPage("Logs");
        AppSession.Until(() => System.Text.RegularExpressions.Regex.IsMatch(Name(AppSession.Find(main, "logs.count")), @"^\d+ of \d+ entr"), "the status bar did not count the entries");
        AppSession.Find(main, "logs.filter").AsTextBox().Text = "no line says this";
        AppSession.Until(() => Name(AppSession.Find(main, "logs.count")).StartsWith("0 of ", StringComparison.Ordinal), "the filter was not counted");
    }

    [Fact]
    public async Task Documents_scroll_through_a_large_corpus_a_page_at_a_time()
    {
        // The size of the Google Drive example (windows-ui.md §7).
        await using AppSession session = await AppSession.StartAsync(documents: 25_000);
        session.ShowPage("Documents");
        Window main = session.Main;
        var clock = Stopwatch.StartNew();
        AppSession.Until(() => Name(AppSession.Find(main, "documents.count")) == "200 of 25,000 documents", "the first page did not load");
        TimeSpan firstPage = clock.Elapsed;
        Assert.True(firstPage < TimeSpan.FromSeconds(10), $"the first page took {firstPage}");

        // Scrolling to the end of the list asks for the next page, and no more than that.
        AutomationElement list = AppSession.Find(main, "documents.list");
        list.Focus();
        Keyboard.Press(VirtualKeyShort.END);
        Keyboard.Release(VirtualKeyShort.END);
        AppSession.Until(() => Name(AppSession.Find(main, "documents.count")).StartsWith("400 of", StringComparison.Ordinal), "scrolling did not load the next page");
        Assert.True(session.Backend.Garage.Requests.OfType<ListDocumentsRequest>().Max(r => r.Offset) < 25_000 - 200, "the whole corpus was requested");
    }

    // Accessibility Insights' automated "name" rule, on every page: each control a keyboard or
    // Narrator user lands on says what it is.
    [Fact]
    public async Task Every_control_on_every_page_has_a_name()
    {
        await using AppSession session = await AppSession.StartAsync();
        Window main = session.Main;
        ControlType[] interactive = [ControlType.Button, ControlType.CheckBox, ControlType.Edit, ControlType.ComboBox, ControlType.RadioButton, ControlType.Hyperlink, ControlType.Slider, ControlType.Spinner];
        List<string> unnamed = [];
        foreach (string page in (string[])["Status", "Sources", "Models", "MCP Server", "Search", "Documents", "Facts", "Database", "Logs", "Settings"])
        {
            session.ShowPage(page);
            Thread.Sleep(1500);
            foreach (AutomationElement element in main.FindAllDescendants(cf => cf.ByControlType(ControlType.Button).Or(cf.ByControlType(ControlType.CheckBox)).Or(cf.ByControlType(ControlType.Edit))
                .Or(cf.ByControlType(ControlType.ComboBox)).Or(cf.ByControlType(ControlType.RadioButton)).Or(cf.ByControlType(ControlType.Hyperlink))))
            {
                if (element.Properties.IsOffscreen.ValueOrDefault || !interactive.Contains(element.Properties.ControlType.ValueOrDefault))
                {
                    continue;
                }
                if (string.IsNullOrWhiteSpace(element.Properties.Name.ValueOrDefault))
                {
                    unnamed.Add($"{page}: {element.Properties.ControlType.ValueOrDefault} {element.Properties.AutomationId.ValueOrDefault} ({element.Properties.ClassName.ValueOrDefault})");
                }
            }
        }
        Assert.True(unnamed.Count == 0, "Controls without an accessible name:" + Environment.NewLine + string.Join(Environment.NewLine, unnamed.Distinct()));
    }
}
