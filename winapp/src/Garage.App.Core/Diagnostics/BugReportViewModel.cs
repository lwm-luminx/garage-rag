using System.Globalization;
using System.Runtime.InteropServices;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Database;
using Garage.App.Core.Logging;
using Garage.App.Core.Models;
using Garage.App.Core.Operations;
using Garage.App.Core.Services;
using Garage.App.Core.Sources;
using Garage.App.Core.State;

namespace Garage.App.Core.Diagnostics;

/// <summary>The facts about this PC and build a report carries.</summary>
/// <param name="Version">"Version 1.5.0 (build 80)".</param>
/// <param name="OperatingSystem">"Windows 11 Home 10.0.26200".</param>
/// <param name="Architecture">"x64".</param>
/// <param name="MemoryGb">Installed memory.</param>
/// <param name="Distribution">"Unpackaged", "Microsoft Store", "App Installer".</param>
public sealed record AppEnvironment(string Version, string OperatingSystem, string Architecture, long MemoryGb, string Distribution)
{
    /// <summary>This process's.</summary>
    public static AppEnvironment Current(string distribution)
    {
        string version = typeof(AppEnvironment).Assembly.GetName().Version is { } v
            ? string.Create(CultureInfo.InvariantCulture, $"Version {v.Major}.{v.Minor}.{v.Build}")
            : "unknown";
        long memory = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / 1_073_741_824;
        return new(version, RuntimeInformation.OSDescription, RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant(), memory, distribution);
    }
}

/// <summary>
/// Gathers what a maintainer needs to reproduce a bug (the Mac's <c>BugReportDiagnosticsCollector</c>):
/// the PC, the build, the shape of the corpus (counts, model slugs, service states). Deliberately
/// absent: source roots and slugs, document titles, queries, anything derived from the corpus.
/// </summary>
public static class BugReportDiagnostics
{
    /// <summary>The sections, empty ones left out.</summary>
    public static IReadOnlyList<DiagnosticSection> Collect(
        AppEnvironment environment,
        string database,
        IReadOnlyList<RegisteredSource> sources,
        CorpusCounts? counts,
        IReadOnlyList<ModelItem> models,
        IReadOnlyList<(string Name, string State)> services)
    {
        ArgumentNullException.ThrowIfNull(environment);
        ArgumentNullException.ThrowIfNull(sources);
        ArgumentNullException.ThrowIfNull(models);
        ArgumentNullException.ThrowIfNull(services);
        List<DiagnosticSection> sections =
        [
            new("Application",
            [
                new("Garage", environment.Version),
                new("Windows", environment.OperatingSystem),
                new("Architecture", environment.Architecture),
                new("Memory", string.Create(CultureInfo.InvariantCulture, $"{environment.MemoryGb} GB")),
                new("Distribution", environment.Distribution),
            ]),
            new("Database", [new("Postgres", database)]),
            new("Corpus",
            [
                new("Sources", sources.Count.ToString(CultureInfo.InvariantCulture)),
                new("Documents", (counts?.Documents ?? 0).ToString(CultureInfo.InvariantCulture)),
                new("Chunks", (counts?.Chunks ?? 0).ToString(CultureInfo.InvariantCulture)),
                new("Corpus classes", ClassBreakdown(sources)),
            ]),
            new("Models", models.Count == 0
                ? [new("Registered", "none")]
                : [.. models.Select(m => new DiagnosticField(
                    m.Slug + (m.IsDefault ? " (default)" : ""),
                    string.Create(CultureInfo.InvariantCulture, $"{m.Provider.CliValue()}, {m.Dims} dims, {m.StorageKind}")))]),
            new("Services", [.. services.Select(s => new DiagnosticField(s.Name, s.State))]),
        ];
        return [.. sections.Where(s => s.Fields.Count > 0)];
    }

    /// <summary>"code: 1, document: 3": how the corpus is split, naming no source.</summary>
    public static string ClassBreakdown(IReadOnlyList<RegisteredSource> sources)
    {
        ArgumentNullException.ThrowIfNull(sources);
        return sources.Count == 0
            ? "none"
            : string.Join(", ", sources.GroupBy(s => s.CorpusClass, StringComparer.Ordinal).OrderBy(g => g.Key, StringComparer.Ordinal)
                .Select(g => string.Create(CultureInfo.InvariantCulture, $"{g.Key}: {g.Count()}")));
    }

    /// <summary>A service's state in a few words.</summary>
    public static string Describe(ServiceProcess service)
    {
        ArgumentNullException.ThrowIfNull(service);
        string state = service.State.ToString();
        return service.Error is { Length: > 0 } error ? $"{state}: {error}" : state;
    }
}

/// <summary>The bug report dialog: the draft, the attachments and the preview.</summary>
public sealed partial class BugReportViewModel : ObservableObject
{
    private readonly Func<IReadOnlyList<DiagnosticSection>> _diagnostics;
    private readonly IReadOnlyList<LogBuffer> _logs;

    /// <summary>Creates the dialog's model.</summary>
    /// <param name="diagnostics">Reads the diagnostics when the dialog opens.</param>
    /// <param name="logs">The logs a report can attach, by source.</param>
    /// <param name="redactor">The redactor; this account's by default.</param>
    public BugReportViewModel(Func<IReadOnlyList<DiagnosticSection>> diagnostics, IReadOnlyList<LogBuffer> logs, BugReportRedactor? redactor = null)
    {
        _diagnostics = diagnostics ?? throw new ArgumentNullException(nameof(diagnostics));
        _logs = logs ?? throw new ArgumentNullException(nameof(logs));
        Redactor = redactor ?? BugReportRedactor.ForThisAccount();
        Diagnostics = diagnostics();
        LogSource = logs.Count > 0 ? logs[0].Source : "app";
    }

    /// <summary>The redactor every piece of text goes through.</summary>
    public BugReportRedactor Redactor { get; }

    /// <summary>The diagnostics, read when the dialog opened.</summary>
    public IReadOnlyList<DiagnosticSection> Diagnostics { get; private set; }

    /// <summary>The log sources a report can attach.</summary>
    public IReadOnlyList<string> LogSources => [.. _logs.Select(l => l.Source)];

    /// <summary>The summary.</summary>
    [ObservableProperty]
    public partial string Title { get; set; } = "";

    /// <summary>What happened.</summary>
    [ObservableProperty]
    public partial string WhatHappened { get; set; } = "";

    /// <summary>Steps to reproduce.</summary>
    [ObservableProperty]
    public partial string StepsToReproduce { get; set; } = "";

    /// <summary>What was expected.</summary>
    [ObservableProperty]
    public partial string ExpectedBehavior { get; set; } = "";

    /// <summary>Attach the diagnostics.</summary>
    [ObservableProperty]
    public partial bool IncludeDiagnostics { get; set; } = true;

    /// <summary>Attach recent log lines (off by default).</summary>
    [ObservableProperty]
    public partial bool IncludeLogs { get; set; }

    /// <summary>Which log.</summary>
    [ObservableProperty]
    public partial string LogSource { get; set; } = "app";

    /// <summary>The draft as typed.</summary>
    public BugReportDraft Draft => new()
    {
        Title = Title,
        WhatHappened = WhatHappened,
        StepsToReproduce = StepsToReproduce,
        ExpectedBehavior = ExpectedBehavior,
        IncludeDiagnostics = IncludeDiagnostics,
        IncludeLogs = IncludeLogs,
        LogSource = LogSource,
    };

    /// <summary>Copy, Save and Open Issue need a title and a description.</summary>
    public bool IsSubmittable => Draft.IsSubmittable;

    /// <summary>The attached log lines.</summary>
    public IReadOnlyList<LogLine> LogLines => IncludeLogs && _logs.FirstOrDefault(l => l.Source == LogSource) is { } log
        ? BugReportLogDigest.Select([.. log])
        : [];

    /// <summary>The report as it will be copied or saved: what the preview shows.</summary>
    public string Document => BugReportComposer.Document(Draft, Diagnostics, LogLines, Redactor);

    /// <summary>The pre-filled issue form's address.</summary>
    public Uri IssueUrl => BugReportDestination.NewIssueUrl(
        BugReportComposer.Title(Draft, Redactor),
        BugReportComposer.Compose(Draft, Diagnostics, LogLines, Redactor));

    /// <summary>A file name for Save: "Garage bug report 2026-09-30.md".</summary>
    public static string SuggestedFileName(DateTimeOffset now) =>
        string.Create(CultureInfo.InvariantCulture, $"Garage bug report {now:yyyy-MM-dd}.md");

    /// <summary>Reads the diagnostics again.</summary>
    public void RefreshDiagnostics()
    {
        Diagnostics = _diagnostics();
        OnPropertyChanged(nameof(Document));
    }

    /// <inheritdoc/>
    protected override void OnPropertyChanged(System.ComponentModel.PropertyChangedEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        base.OnPropertyChanged(e);
        if (e.PropertyName is not (nameof(Document) or nameof(IsSubmittable) or nameof(IssueUrl) or nameof(LogLines)))
        {
            base.OnPropertyChanged(new System.ComponentModel.PropertyChangedEventArgs(nameof(Document)));
            base.OnPropertyChanged(new System.ComponentModel.PropertyChangedEventArgs(nameof(IsSubmittable)));
        }
    }
}
