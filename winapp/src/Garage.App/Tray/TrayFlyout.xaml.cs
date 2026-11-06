using System.ComponentModel;
using Garage.App.Core.Library;
using Garage.App.Core.Navigation;
using Garage.App.Core.Presentation;
using Garage.App.Core.Search;
using Garage.App.Core.Tray;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Garage.App.Tray;

/// <summary>What the flyout's rows do; the app supplies them.</summary>
internal sealed record TrayActions(
    Action Open,
    Action Quit,
    Action<AppSection> Show,
    Action<string> SearchAll,
    Func<Task> IngestNow,
    Action Stop,
    Action Dismiss);

/// <summary>The flyout's content, drawn from <see cref="TrayViewModel"/>.</summary>
internal sealed partial class TrayFlyout : UserControl
{
    private readonly TrayViewModel _model;
    private readonly TrayActions _actions;
    private bool _showing;

    public TrayFlyout(TrayViewModel model, TrayActions actions)
    {
        _model = model;
        _actions = actions;
        InitializeComponent();
        _model.PropertyChanged += OnModelChanged;
        _model.Results.CollectionChanged += (_, _) => Show();
        Unloaded += (_, _) => _model.PropertyChanged -= OnModelChanged;
        Show();
    }

    /// <summary>Raised when the content's height may have changed, so the window can fit it.</summary>
    public event EventHandler? ContentChanged;

    /// <summary>Puts the cursor in the field, as the Mac's popover does each time it opens.</summary>
    public void FocusField()
    {
        if (_model.Status.CanSearch)
        {
            QueryBox.Focus(FocusState.Programmatic);
        }
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Show();

    private void Show()
    {
        TrayStatus status = _model.Status;
        _showing = true;
        if (QueryBox.Text != _model.Query)
        {
            QueryBox.Text = _model.Query;
        }
        _showing = false;
        QueryBox.IsEnabled = status.CanSearch;

        // The answer.
        AnswerCard.Visibility = Look.VisibleWhen(_model.ShowsAnswer);
        AskedText.Text = _model.AskedQuestion is { } asked ? $"“{asked}”" : "";
        AskingPanel.Visibility = Look.VisibleWhen(_model.IsAsking);
        AnswerText.Text = _model.Answer?.Answer ?? "";
        AnswerText.Visibility = Look.VisibleIf(AnswerText.Text);
        AskErrorText.Text = _model.AskError ?? "";
        AskErrorText.Visibility = Look.VisibleIf(AskErrorText.Text);
        FootnoteText.Text = _model.Answer?.Footnote ?? "";
        FootnoteText.Visibility = Look.VisibleIf(FootnoteText.Text);
        CitationsPanel.Children.Clear();
        foreach (AskAnswer.Citation citation in _model.ShownCitations)
        {
            CitationsPanel.Children.Add(Row(Look.SourceGlyph(Core.Sources.SourceSymbol.Documents), citation.DisplayTitle, citation.Snippet,
                () => OpenLocation(citation.FilePath(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile))), "menubar.answer.citation"));
        }

        // The hits, with Ask Garage first.
        ResultsPanel.Children.Clear();
        if (_model.ShowsAskRow)
        {
            ResultsPanel.Children.Add(Row("", $"Ask Garage: “{_model.TrimmedQuery}”", "The local model searches and reads your corpus, then answers",
                () => _ = _model.AskAsync(), "menubar.ask"));
        }
        foreach (SearchResultItem hit in _model.Results)
        {
            ResultsPanel.Children.Add(Row(Look.StatusGlyph(StatusSymbol.Search), hit.DisplayTitle, hit.Snippet,
                () => OpenLocation(QuickSearch.FilePathForUri(hit.Uri)), "menubar.search.result"));
        }
        if (_model.Results.Count > 0)
        {
            ResultsPanel.Children.Add(Row("", "See all results", null, () => _actions.SearchAll(_model.TrimmedQuery), "menubar.search.all"));
        }
        ResultsCard.Visibility = Look.VisibleWhen(ResultsPanel.Children.Count > 0);
        SearchNote.Text = _model.Results.Count > 0 ? "" : _model.SearchError ?? (_model.ShowsNoMatches ? "No matches" : "");
        SearchNote.Visibility = Look.VisibleIf(SearchNote.Text);

        // Services.
        TraySummary summary = status.Summary;
        SummaryCircle.Background = Look.TintBrush(summary.Tint);
        SummaryGlyph.Glyph = Look.StatusGlyph(summary.Symbol);
        SummaryTitle.Text = summary.Title;
        SummaryDetail.Text = summary.Detail;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(ServicesRow, $"{summary.Title}. {summary.Detail}");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(ServicesRow, status.AllSystemsGo ? "menubar.allSystemsGo" : "menubar.problem");

        // Activity.
        ActivityCard.Visibility = Look.VisibleWhen(status.Database.State == Core.Database.PostgresState.Running);
        ActivityDot.Visibility = Look.VisibleWhen(status.ShowsActivityDot);
        ActivityDot.Fill = Look.TintBrush(status.Tint);
        ActivityTitle.Text = status.ShowsActivityDot ? status.Headline : status.CorpusLine;
        ActivityPercent.Text = status.IngestFraction is { } fraction ? TrayStatus.Percent(fraction) : "";
        bool idle = status.Doing is TrayActivity.Idle;
        IngestButton.Visibility = Look.VisibleWhen(idle);
        IngestButton.IsEnabled = status.CanIngest;
        ToolTipService.SetToolTip(IngestButton, status.SourceCount == 0 ? "Add a source in Garage first." : "Scan and ingest every source.");
        StopButton.Visibility = Look.HiddenWhen(idle);
        StopButton.Content = status.IsCancellingIngest ? "Stopping…" : "Stop";
        StopButton.IsEnabled = !status.IsCancellingIngest;
        ActivityBar.Visibility = Look.VisibleWhen(status.IsBusy);
        ActivityBar.IsIndeterminate = status.IngestFraction is null;
        ActivityBar.Value = status.IngestFraction ?? 0;
        ActivityDetail.Text = status.IsBusy ? status.ActivityDetail ?? "" : "";
        ActivityDetail.Visibility = Look.VisibleIf(ActivityDetail.Text);
        ActivityItem.Text = status.CurrentItem is { } item ? TrayStatus.AbbreviatedPath(item, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)) : "";
        ActivityItem.Visibility = Look.VisibleIf(ActivityItem.Text);
        StageTrail.Text = status.IsBusy ? string.Join("  ›  ", status.StageTrail.Select(s => s == status.Stage ? $"[{Title(s)}]" : Title(s))) : "";
        StageTrail.Visibility = Look.VisibleIf(StageTrail.Text);
        AttentionPanel.Children.Clear();
        foreach (TrayAttention attention in status.Attentions.Where(a => a.Kind == TrayAttentionKind.IngestFailed))
        {
            AttentionPanel.Children.Add(Row("", $"Last ingest failed: {attention.Message}", null, () => _actions.Show(AppSection.Status), "menubar.attention"));
        }
        ContentChanged?.Invoke(this, EventArgs.Empty);
    }

    private static string Title(LibraryStage stage) => stage switch
    {
        LibraryStage.Scan => "Scan",
        LibraryStage.Read => "Read",
        LibraryStage.Index => "Index",
        _ => "Glean",
    };

    private static Button Row(string glyph, string title, string? detail, Action action, string automationId)
    {
        var text = new StackPanel { Spacing = 1 };
        text.Children.Add(new TextBlock { Text = title, TextTrimming = TextTrimming.CharacterEllipsis });
        if (!string.IsNullOrWhiteSpace(detail))
        {
            text.Children.Add(new TextBlock
            {
                Text = detail.ReplaceLineEndings(" "),
                TextTrimming = TextTrimming.CharacterEllipsis,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            });
        }
        var content = new Grid { ColumnSpacing = 8 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14, VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(text, 1);
        content.Children.Add(text);
        var button = new Button
        {
            Content = content,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Style = (Style)Application.Current.Resources["SubtleButtonStyle"],
            Padding = new Thickness(8, 5, 8, 5),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, title);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(button, automationId);
        button.Click += (_, _) => action();
        return button;
    }

    // A file opens in its own app; anything else (a message, a document without a path) goes to the
    // Search page, where the full text is.
    private void OpenLocation(string? path)
    {
        if (path is not null && File.Exists(path))
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true })?.Dispose();
            _actions.Dismiss();
            return;
        }
        _actions.SearchAll(_model.TrimmedQuery);
    }

    private void OnQueryChanged(object sender, TextChangedEventArgs e)
    {
        if (!_showing)
        {
            _model.Query = QueryBox.Text;
        }
    }

    // Enter opens every result on the Search page; Shift+Enter asks; Escape closes the flyout.
    private void OnQueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            bool shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (shift)
            {
                _ = _model.AskAsync();
            }
            else if (_model.TrimmedQuery.Length > 0)
            {
                _actions.SearchAll(_model.TrimmedQuery);
            }
        }
        else if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            _actions.Dismiss();
        }
    }

    private void OnClearAnswer(object sender, RoutedEventArgs e) => _model.ClearAnswer();

    private void OnOpen(object sender, RoutedEventArgs e) => _actions.Open();

    private void OnQuit(object sender, RoutedEventArgs e) => _actions.Quit();

    private void OnShowStatus(object sender, RoutedEventArgs e) => _actions.Show(AppSection.Status);

    private async void OnIngest(object sender, RoutedEventArgs e) => await _actions.IngestNow().ConfigureAwait(true);

    private void OnStop(object sender, RoutedEventArgs e) => _actions.Stop();
}
