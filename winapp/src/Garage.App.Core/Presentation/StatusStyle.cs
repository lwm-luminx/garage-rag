namespace Garage.App.Core.Presentation;

/// <summary>A status row's colour (the Mac's tints).</summary>
public enum Tint
{
    /// <summary>Running, up to date.</summary>
    Green,

    /// <summary>Needs attention.</summary>
    Orange,

    /// <summary>Failed or destructive.</summary>
    Red,

    /// <summary>In progress; documents.</summary>
    Blue,

    /// <summary>Code.</summary>
    Purple,

    /// <summary>Inactive.</summary>
    Secondary,

    /// <summary>On its way up or down.</summary>
    Yellow,
}

/// <summary>A status row's symbol, named for what it means rather than the platform's glyph.</summary>
public enum StatusSymbol
{
    /// <summary>Done / running.</summary>
    Checkmark,

    /// <summary>Needs attention.</summary>
    Warning,

    /// <summary>Failed.</summary>
    Cross,

    /// <summary>The database.</summary>
    Database,

    /// <summary>Resetting.</summary>
    Resetting,

    /// <summary>Applying updates.</summary>
    Applying,

    /// <summary>A server or service.</summary>
    Server,

    /// <summary>A terminal: stdio, the command line.</summary>
    Terminal,

    /// <summary>Working, with an indeterminate end.</summary>
    Working,

    /// <summary>Something to download.</summary>
    Download,

    /// <summary>A text or quote: facts, distillation.</summary>
    Quote,

    /// <summary>Searching or scanning.</summary>
    Search,

    /// <summary>Waiting for its turn.</summary>
    Clock,

    /// <summary>Stopped on purpose.</summary>
    Paused,

    /// <summary>Empty: nothing added yet.</summary>
    Tray,

    /// <summary>Work left to do.</summary>
    Pending,
}
