using System.Globalization;
using Garage.App.Core.Presentation;

namespace Garage.App.Core.Services;

/// <summary>
/// A service the Services page draws in red or orange: one that can't be reached, or one that runs but
/// fails its self tests. The Mac's <c>StatusHealth.ServiceIssue</c>; the Status page names a service only
/// when it is one of these.
/// </summary>
public sealed record ServiceIssue(string Id, string Name, string Detail, bool IsUnreachable)
{
    /// <summary>
    /// The issue a Services row stands for, or null when the row is healthy or on its way somewhere
    /// (checking, restarting, stopped, not checked yet).
    /// </summary>
    public static ServiceIssue? From(ServiceRowPresentation row)
    {
        ArgumentNullException.ThrowIfNull(row);
        return row.State switch
        {
            ServiceState.Unreachable => new(row.Id, row.Name, row.Detail, true),
            ServiceState.Running when row.DetailIsError => new(row.Id, row.Name, row.Detail, false),
            _ => null,
        };
    }
}

/// <summary>What the Status page says about the services: nothing while they are all well.</summary>
public static class ServiceIssues
{
    /// <summary>
    /// The issues among <paramref name="rows"/>. While the database can't be reached, the other
    /// services' failures are its consequences, so only the database is named, as on the Mac.
    /// </summary>
    public static IReadOnlyList<ServiceIssue> From(IEnumerable<ServiceRowPresentation> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        List<ServiceIssue> issues = [.. rows.Select(ServiceIssue.From).OfType<ServiceIssue>()];
        ServiceIssue? database = issues.FirstOrDefault(i => i.Id == "postgres" && i.IsUnreachable);
        return database is null ? issues : [database];
    }

    /// <summary>Red when a service can't be reached, orange when one only fails its tests.</summary>
    public static StatusSeverity Severity(IReadOnlyList<ServiceIssue> issues)
    {
        ArgumentNullException.ThrowIfNull(issues);
        return issues.Any(i => i.IsUnreachable) ? StatusSeverity.Error : StatusSeverity.Warning;
    }

    /// <summary>"Ingest can't be reached", "Embeddings fails its self tests", or "3 services need attention".</summary>
    public static string Title(IReadOnlyList<ServiceIssue> issues)
    {
        ArgumentNullException.ThrowIfNull(issues);
        return issues.Count switch
        {
            0 => "",
            1 when issues[0].IsUnreachable => $"{issues[0].Name} can't be reached",
            1 => $"{issues[0].Name} fails its self tests",
            _ => string.Create(CultureInfo.CurrentCulture, $"{issues.Count} services need attention"),
        };
    }

    /// <summary>Each issue's row detail, one per line, as the Services page shows it.</summary>
    public static string Message(IReadOnlyList<ServiceIssue> issues)
    {
        ArgumentNullException.ThrowIfNull(issues);
        return issues.Count == 1
            ? issues[0].Detail
            : string.Join("\n", issues.Select(i => $"{i.Name}: {i.Detail}"));
    }
}
