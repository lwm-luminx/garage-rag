namespace Garage.App.Core.Navigation;

/// <summary>What a launch asks of Garage: the jump list's tasks, and starting quietly at sign-in.</summary>
public enum LaunchAction
{
    /// <summary>Open the window.</summary>
    Open,

    /// <summary>Start in the notification area only (launch at sign-in).</summary>
    Background,

    /// <summary>Open the Search page.</summary>
    Search,

    /// <summary>Open the tray flyout, ready to ask.</summary>
    Ask,

    /// <summary>Open the Sources page's Add Source dialog.</summary>
    AddSource,

    /// <summary>Run Update Everything.</summary>
    UpdateEverything,

    /// <summary>Open the bug report.</summary>
    ReportBug,
}

/// <summary>
/// The command line a launch carries, as a second launch hands it to the running instance (the
/// jump list starts Garage with <c>--do search</c> and the like).
/// </summary>
public static class LaunchCommand
{
    /// <summary>The switch before a jump-list task.</summary>
    public const string Switch = "--do";

    /// <summary>The switch launch at sign-in passes.</summary>
    public const string BackgroundSwitch = "--background";

    /// <summary>The jump list's tasks, in its order, with their titles and arguments.</summary>
    public static IReadOnlyList<(LaunchAction Action, string Title, string Description)> JumpListTasks { get; } =
    [
        (LaunchAction.Search, "Search", "Search your corpus"),
        (LaunchAction.Ask, "Ask Garage", "Ask a question of your corpus"),
        (LaunchAction.AddSource, "Add Source", "Add a folder for Garage to index"),
        (LaunchAction.UpdateEverything, "Update Everything", "Scan, read, index and glean every source"),
    ];

    /// <summary>The argument naming an action.</summary>
    public static string Name(LaunchAction action) => action switch
    {
        LaunchAction.Search => "search",
        LaunchAction.Ask => "ask",
        LaunchAction.AddSource => "add-source",
        LaunchAction.UpdateEverything => "update-everything",
        LaunchAction.ReportBug => "report-bug",
        LaunchAction.Background => "background",
        _ => "open",
    };

    /// <summary>The arguments that ask for <paramref name="action"/>.</summary>
    public static string Arguments(LaunchAction action) => action switch
    {
        LaunchAction.Open => "",
        LaunchAction.Background => BackgroundSwitch,
        _ => $"{Switch} {Name(action)}",
    };

    /// <summary>
    /// The action a command line asks for. Arguments are a whole command line (a redirected activation
    /// carries one string) or split ones; anything unknown opens the window.
    /// </summary>
    public static LaunchAction Parse(IEnumerable<string> arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        List<string> words = [.. arguments.SelectMany(a => a.Split(' ', StringSplitOptions.RemoveEmptyEntries)).Select(w => w.Trim('"'))];
        int at = words.FindIndex(w => w.Equals(Switch, StringComparison.OrdinalIgnoreCase));
        if (at >= 0 && at + 1 < words.Count)
        {
            string name = words[at + 1].ToLowerInvariant();
            foreach (LaunchAction action in Enum.GetValues<LaunchAction>())
            {
                if (Name(action) == name)
                {
                    return action;
                }
            }
        }
        return words.Any(w => w.Equals(BackgroundSwitch, StringComparison.OrdinalIgnoreCase)) ? LaunchAction.Background : LaunchAction.Open;
    }
}
