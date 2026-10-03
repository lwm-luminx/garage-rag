using System.Globalization;
using Garage.App.Core.State;

namespace Garage.App.Core.Presentation;

/// <summary>How serious a status line is; the app maps it to an <c>InfoBar</c> severity.</summary>
public enum StatusSeverity
{
    /// <summary>Neutral information.</summary>
    Informational,

    /// <summary>All is well.</summary>
    Success,

    /// <summary>Works, with a caveat.</summary>
    Warning,

    /// <summary>Not working.</summary>
    Error,
}

/// <summary>
/// The Status page's connection summary, as plain values: the Windows side of the Mac's
/// presentation types (<c>*Presentation.swift</c>), which keep wording and state rules out of the
/// views and under unit tests.
/// </summary>
public sealed record ConnectionPresentation(string Title, string Detail, StatusSeverity Severity)
{
    /// <summary>The summary for the state's current connection.</summary>
    public static ConnectionPresentation From(AppState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        return state.Connection switch
        {
            BackendConnection.Connected => Connected(state),
            BackendConnection.Unavailable => new(
                "Garage isn't reachable",
                state.ConnectionError ?? "The Garage service did not answer.",
                StatusSeverity.Error),
            BackendConnection.Connecting => new("Connecting…", state.Backend.Description, StatusSeverity.Informational),
            _ => new("Not connected yet", state.Backend.Description, StatusSeverity.Informational),
        };
    }

    private static ConnectionPresentation Connected(AppState state)
    {
        string version = string.IsNullOrEmpty(state.ServerVersion) ? "Garage" : $"Garage {state.ServerVersion}";
        string detail = state.Counts is { } counts
            ? string.Format(
                CultureInfo.CurrentCulture,
                "{0:N0} {1} · {2:N0} {3} · {4:N0} {5}",
                counts.Documents, counts.Documents == 1 ? "document" : "documents",
                counts.Chunks, counts.Chunks == 1 ? "chunk" : "chunks",
                counts.Sources, counts.Sources == 1 ? "source" : "sources")
            : state.Backend.Description;
        bool readOnly = state.Backend.Grpc.Token is null;
        return new(
            $"Connected to {version}",
            readOnly ? $"{detail}. No token: settings and sources are read-only." : detail,
            readOnly ? StatusSeverity.Warning : StatusSeverity.Success);
    }
}
