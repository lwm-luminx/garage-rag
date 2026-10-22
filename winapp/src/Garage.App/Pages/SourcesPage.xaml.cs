using System.ComponentModel;
using Garage.App.Core.Corpus;
using Garage.App.Core.Facts;
using Garage.App.Core.Library;
using Garage.App.Core.Onboarding;
using Garage.App.Core.Operations;
using Garage.App.Core.Sources;
using Garage.App.Core.State;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Garage.App.Pages;

/// <summary>
/// The Sources page (the Mac's <c>SourcesView</c>): each row's Scan &amp; Ingest, and everything else a
/// source can do behind its More button, as the Mac's source menu: the rarer ingests, facts,
/// reconciling, Show in Explorer, editing and removing.
/// </summary>
public sealed partial class SourcesPage : Page
{
    /// <summary>The source kinds AddSource takes, as the Mac's form lists them.</summary>
    private static readonly string[] Kinds = ["filesystem", "git", "sqlite", "maildir", "feed"];

    private PageModels _pages = null!;
    private SourcesViewModel _model = null!;
    private OperationRunner _runner = null!;
    private StatusViewModel _status = null!;

    /// <summary>Creates the page.</summary>
    public SourcesPage() => InitializeComponent();

    /// <inheritdoc/>
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        _pages = (PageModels)e.Parameter;
        _model = _pages.Sources;
        _runner = _pages.State.Operations;
        _status = _pages.Status;
        RowsList.ItemsSource = _model.Rows;
        _model.PropertyChanged += OnModelChanged;
        _runner.PropertyChanged += OnModelChanged;
        _status.PropertyChanged += OnModelChanged;
        Show();
        await _model.LoadAsync().ConfigureAwait(true);
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        _model.PropertyChanged -= OnModelChanged;
        _runner.PropertyChanged -= OnModelChanged;
        _status.PropertyChanged -= OnModelChanged;
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Show();

    private void Show()
    {
        SummaryText.Text = _model.Summary;
        bool busy = _runner.IsRunning;
        bool running = _status.IsRunning;
        AddButton.IsEnabled = SyncButton.IsEnabled = !busy;
        ScanAllButton.IsEnabled = !running;
        UpdateEverythingButton.IsEnabled = _status.CanUpdateEverything;
        ToolTipService.SetToolTip(UpdateEverythingButton, _model.IngestUnavailable ?? "Update Everything: scan and read every source, index the new chunks with every model, then glean facts from the new documents");
        StopButton.Visibility = Look.VisibleWhen(running);
        StopButton.IsEnabled = !_status.IsStopping;
        StopText.Text = _status.IsStopping ? "Stopping…" : "Stop";

        LibraryHeadline activity = _status.Headline;
        ActivityCard.Visibility = Look.VisibleWhen(running);
        ActivityGlyph.Glyph = Look.StatusGlyph(activity.Symbol);
        ActivityTitle.Text = activity.Title;
        ActivityPercent.Text = activity.Percent ?? "";
        ActivityBar.IsIndeterminate = activity.IsIndeterminate;
        ActivityBar.Value = activity.Progress ?? 0;
        ActivityDetail.Text = activity.CurrentItem is { } item ? $"{activity.Detail}\n{item}" : activity.Detail ?? "";
        string? message = _model.ErrorMessage ?? _model.LastResult;
        ResultBar.IsOpen = message is not null;
        ResultBar.Severity = _model.ErrorMessage is not null ? InfoBarSeverity.Error : InfoBarSeverity.Informational;
        ResultBar.Title = _model.ErrorMessage is not null ? "Couldn't read the sources" : "";
        ResultBar.Message = message ?? "";
    }

    private async void OnScanAll(object sender, RoutedEventArgs e) => await _model.ScanAsync().ConfigureAwait(true);

    private async void OnScanOne(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string slug })
        {
            await _model.ScanAsync(slug).ConfigureAwait(true);
        }
    }

    private async void OnSync(object sender, RoutedEventArgs e) => await _model.SyncAsync().ConfigureAwait(true);

    private void OnStop(object sender, RoutedEventArgs e) => _status.Stop();

    private async void OnUpdateEverything(object sender, RoutedEventArgs e) => await _model.UpdateEverythingAsync().ConfigureAwait(true);

    private async void OnScanAndIngest(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string slug })
        {
            await _model.ScanAndIngestAsync(slug).ConfigureAwait(true);
        }
    }

    private async void OnCancelOne(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string slug })
        {
            await _model.CancelAsync(slug).ConfigureAwait(true);
        }
    }

    // The More menu: what needs the pipeline idle, the facts runner free or the operations runner free.
    private void OnMoreOpening(object? sender, object e)
    {
        if (sender is not MenuFlyout menu)
        {
            return;
        }
        bool canIngest = !_status.IsRunning && _model.IngestUnavailable is null;
        foreach (MenuFlyoutItem item in menu.Items.OfType<MenuFlyoutItem>())
        {
            item.IsEnabled = AutomationProperties.GetAutomationId(item) switch
            {
                "sources.menu.scanOnly" => !_status.IsRunning,
                "sources.menu.includeCode" or "sources.menu.reindex" => canIngest,
                "sources.menu.glean" => !_pages.State.Facts.IsRunning,
                "sources.menu.checkDeleted" or "sources.menu.forgetDeleted" or "sources.menu.edit" => !_runner.IsRunning,
                _ => true,
            };
        }
    }

    private async void OnIngestIncludingCode(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string slug })
        {
            await _model.ScanAndIngestAsync(slug, includeCode: true).ConfigureAwait(true);
        }
    }

    private async void OnReindex(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string slug })
        {
            await _model.ScanAndIngestAsync(slug, force: true).ConfigureAwait(true);
        }
    }

    private async void OnGleanSource(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string slug })
        {
            await _pages.Facts.GleanAsync(_pages.State.Facts, _pages.State.Notifier, new GleanScope(Source: slug)).ConfigureAwait(true);
        }
    }

    private async void OnCheckDeleted(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string slug })
        {
            await _model.ReconcileAsync(slug, apply: false).ConfigureAwait(true);
        }
    }

    private async void OnForgetDeleted(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string slug })
        {
            return;
        }
        var confirm = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = $"Forget deleted files in {slug}?",
            Content = "Garage deletes the documents whose files are no longer there, with their chunks, embeddings and facts. Files that are still there are not touched.",
            PrimaryButtonText = "Forget Deleted Files",
            PrimaryButtonStyle = (Style)Application.Current.Resources["DangerButtonStyle"],
            CloseButtonText = Strings.Get("Code_SourcesPage_Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await confirm.ShowAsync() == ContentDialogResult.Primary)
        {
            await _model.ReconcileAsync(slug, apply: true).ConfigureAwait(true);
        }
    }

    private void OnShowInExplorer(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string slug } && _model.SourceFor(slug) is { } source)
        {
            Shell.ShowInExplorer(LocalAccess.Expand(source.Root));
        }
    }

    private async void OnEdit(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string slug } && _model.SourceFor(slug) is { } source)
        {
            await ShowSourceDialogAsync(source).ConfigureAwait(true);
        }
    }

    private async void OnRemove(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string slug })
        {
            return;
        }
        long documents = _model.SourceFor(slug)?.DocumentCount ?? 0;
        var confirm = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = $"Remove {slug}?",
            Content = $"This deletes its {SourceRowPresentation.Plural("document", documents)} ({documents:N0}), their chunks and every embedding of them. The files themselves are not touched.",
            PrimaryButtonText = Strings.Get("Code_SourcesPage_Remove"),
            PrimaryButtonStyle = (Style)Application.Current.Resources["DangerButtonStyle"],
            CloseButtonText = Strings.Get("Code_SourcesPage_Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await confirm.ShowAsync() == ContentDialogResult.Primary)
        {
            await _model.RemoveAsync(slug).ConfigureAwait(true);
        }
    }

    /// <summary>Opens Add Source once the page is in the window (the jump list's task).</summary>
    public void OpenAddSourceWhenLoaded()
    {
        if (IsLoaded)
        {
            OnAdd(this, new RoutedEventArgs());
            return;
        }
        void Open(object sender, RoutedEventArgs e)
        {
            Loaded -= Open;
            OnAdd(this, e);
        }
        Loaded += Open;
    }

    private async void OnAdd(object sender, RoutedEventArgs e) => await ShowSourceDialogAsync(null).ConfigureAwait(true);

    // Add Source, or Edit… of an existing one. Its name stays: AddSource under the same name updates it.
    private async Task ShowSourceDialogAsync(RegisteredSource? editing)
    {
        var root = new TextBox { Header = Strings.Get("Code_SourcesPage_Folder"), PlaceholderText = @"C:\Users\you\Documents", Text = editing?.Root ?? "" };
        var browse = new Button { Content = Strings.Get("Code_SourcesPage_Browse"), VerticalAlignment = VerticalAlignment.Bottom };
        var slug = new TextBox { Header = Strings.Get("Code_SourcesPage_Name"), PlaceholderText = "notes", Text = editing?.Slug ?? "", IsEnabled = editing is null };
        var kind = new ComboBox { Header = Strings.Get("Code_SourcesPage_Kind"), ItemsSource = Kinds, MinWidth = 140 };
        var corpusClass = new ComboBox { Header = Strings.Get("Code_SourcesPage_Class"), ItemsSource = CorpusTaxonomy.CorpusClasses, MinWidth = 160 };
        var trust = new ComboBox { Header = Strings.Get("Code_SourcesPage_Trust"), ItemsSource = CorpusTaxonomy.TrustTiers, MinWidth = 160 };
        kind.SelectedItem = editing?.Kind is { } k && Kinds.Contains(k) ? k : Kinds[0];
        corpusClass.SelectedItem = editing?.CorpusClass is { } c && CorpusTaxonomy.CorpusClasses.Contains(c) ? c : CorpusTaxonomy.CorpusClasses[0];
        trust.SelectedItem = editing?.TrustTier is { } t && CorpusTaxonomy.TrustTiers.Contains(t) ? t : CorpusTaxonomy.TrustTiers[0];
        ToolTipService.SetToolTip(kind, Strings.Get("Code_SourcesPage_KindHelp"));
        bool slugEdited = editing is not null;
        root.TextChanged += (_, _) =>
        {
            if (!slugEdited)
            {
                slug.Text = SourceSlugSuggestion.Suggest(root.Text, kind.SelectedItem as string ?? "filesystem", _model.TakenSlugs);
            }
        };
        slug.TextChanged += (_, _) => slugEdited = slug.FocusState != FocusState.Unfocused || slugEdited;
        browse.Click += async (_, _) =>
        {
            if (await Platform.Pickers.FolderAsync().ConfigureAwait(true) is { } folder)
            {
                root.Text = folder;
            }
        };

        var form = new StackPanel { Spacing = 12, MinWidth = 440 };
        if (editing is null)
        {
            // The common folders on this PC not added yet, as the Mac's "Choose preset…" menu offers its own.
            List<FirstRunSourceTemplate> presets = [.. FirstRunSourceTemplate.BuiltIn(FirstRunSourceTemplate.ThisPc())
                .Where(p => p.IsAvailable && !_model.TakenSlugs.Contains(p.Slug))];
            if (presets.Count > 0)
            {
                var preset = new ComboBox
                {
                    Header = Strings.Get("Code_SourcesPage_Preset"),
                    PlaceholderText = Strings.Get("Code_SourcesPage_ChoosePreset"),
                    ItemsSource = presets,
                    DisplayMemberPath = nameof(FirstRunSourceTemplate.Title),
                    MinWidth = 200,
                };
                preset.SelectionChanged += (_, _) =>
                {
                    if (preset.SelectedItem is FirstRunSourceTemplate chosen)
                    {
                        slugEdited = true;
                        root.Text = chosen.Root;
                        slug.Text = chosen.Slug;
                        kind.SelectedItem = Kinds.Contains(chosen.Kind) ? chosen.Kind : Kinds[0];
                        corpusClass.SelectedItem = chosen.CorpusClass;
                        trust.SelectedItem = chosen.Trust;
                    }
                };
                form.Children.Add(preset);
            }
        }
        var rootRow = new Grid { ColumnSpacing = 8 };
        rootRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        rootRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        rootRow.Children.Add(root);
        Grid.SetColumn(browse, 1);
        rootRow.Children.Add(browse);
        var classes = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        classes.Children.Add(kind);
        classes.Children.Add(corpusClass);
        classes.Children.Add(trust);
        form.Children.Add(rootRow);
        form.Children.Add(slug);
        form.Children.Add(classes);
        form.Children.Add(new TextBlock
        {
            Text = Strings.Get("Code_SourcesPage_ClassSaysWhatItIsTrust"),
            TextWrapping = TextWrapping.Wrap,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        });

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = editing is null ? Strings.Get("Code_SourcesPage_AddSource") : $"Edit {editing.Slug}",
            Content = form,
            PrimaryButtonText = editing is null ? Strings.Get("Code_SourcesPage_Add") : Strings.Get("Code_SourcesPage_Save"),
            CloseButtonText = Strings.Get("Code_SourcesPage_Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && root.Text.Trim().Length > 0 && slug.Text.Trim().Length > 0)
        {
            await _model.AddAsync(new NewSource(slug.Text, root.Text,
                Kind: kind.SelectedItem as string ?? "filesystem",
                CorpusClass: corpusClass.SelectedItem as string ?? "document",
                TrustTier: trust.SelectedItem as string ?? "authored")).ConfigureAwait(true);
        }
    }
}
