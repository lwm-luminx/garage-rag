namespace Garage.App.Core.Navigation;

/// <summary>
/// The app's pages, in navigation order: the counterpart of <c>AppSection</c> in the Mac app's
/// <c>Views/ContentView.swift</c>. The order is held by a test, as it is on the Mac.
/// </summary>
public enum AppSection
{
    /// <summary>Services, library and indexing at a glance.</summary>
    Status,

    /// <summary>The folders and stores Garage indexes.</summary>
    Sources,

    /// <summary>Embedding and generating models.</summary>
    Models,

    /// <summary>MCP client registration and the optional HTTP server.</summary>
    Mcp,

    /// <summary>Indexed documents.</summary>
    Documents,

    /// <summary>Distilled facts and their prompts.</summary>
    Facts,

    /// <summary>Hybrid search over the corpus.</summary>
    Search,

    /// <summary>Schema, contents and reset.</summary>
    Database,

    /// <summary>App and service logs.</summary>
    Logs,
}

/// <summary>The navigation groups under Status: the Mac's <c>SidebarGroup</c>.</summary>
public enum SidebarGroup
{
    /// <summary>Sources, Models, MCP Server.</summary>
    Configuration,

    /// <summary>Documents, Facts, Search.</summary>
    Data,

    /// <summary>Database, Logs.</summary>
    Advanced,
}

/// <summary>Titles and grouping for <see cref="AppSection"/> and <see cref="SidebarGroup"/>.</summary>
public static class AppSections
{
    /// <summary>The page shown above every group.</summary>
    public const AppSection Top = AppSection.Status;

    /// <summary>The groups in navigation order.</summary>
    public static IReadOnlyList<SidebarGroup> Groups { get; } =
        [SidebarGroup.Configuration, SidebarGroup.Data, SidebarGroup.Advanced];

    /// <summary>Every page in navigation order: <see cref="Top"/>, then each group's pages.</summary>
    public static IReadOnlyList<AppSection> NavigationOrder { get; } =
        [Top, .. Groups.SelectMany(SectionsIn)];

    /// <summary>A group's pages, in order.</summary>
    public static IReadOnlyList<AppSection> SectionsIn(SidebarGroup group) => group switch
    {
        SidebarGroup.Configuration => [AppSection.Sources, AppSection.Models, AppSection.Mcp],
        SidebarGroup.Data => [AppSection.Documents, AppSection.Facts, AppSection.Search],
        SidebarGroup.Advanced => [AppSection.Database, AppSection.Logs],
        _ => throw new ArgumentOutOfRangeException(nameof(group), group, null),
    };

    /// <summary>The page title, as the Mac app spells it.</summary>
    public static string Title(this AppSection section) => section switch
    {
        AppSection.Status => "Status",
        AppSection.Sources => "Sources",
        AppSection.Models => "Models",
        AppSection.Mcp => "MCP Server",
        AppSection.Documents => "Documents",
        AppSection.Facts => "Facts",
        AppSection.Search => "Search",
        AppSection.Database => "Database",
        AppSection.Logs => "Logs",
        _ => throw new ArgumentOutOfRangeException(nameof(section), section, null),
    };

    /// <summary>The group heading.</summary>
    public static string Title(this SidebarGroup group) => group.ToString();

    /// <summary>The page for Ctrl+<paramref name="number"/> (1-based, navigation order), or null.</summary>
    public static AppSection? ForShortcut(int number) =>
        number >= 1 && number <= NavigationOrder.Count ? NavigationOrder[number - 1] : null;
}
