using System.ComponentModel;
using Garage.App.Core.Corpus;
using Garage.App.Core.Library;
using Garage.App.Core.Operations;
using Garage.App.Core.Sources;
using Garage.App.Core.State;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Garage.App.Pages;

/// <summary>The Sources page (the Mac's <c>SourcesView</c>).</summary>
public sealed partial class SourcesPage : Page
{
    private SourcesViewModel _model = null!;
    private OperationRunner _runner = null!;
    private StatusViewModel _status = null!;

    /// <summary>Creates the page.</summary>
    public SourcesPage() => InitializeComponent();

    /// <inheritdoc/>
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        var pages = (PageModels)e.Parameter;
        _model = pages.Sources;
        _runner = pages.State.Operations;
        _status = pages.Status;
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

    private async void OnAdd(object sender, RoutedEventArgs e)
    {
        var root = new TextBox { Header = Strings.Get("Code_SourcesPage_Folder"), PlaceholderText = @"C:\Users\you\Documents" };
        var browse = new Button { Content = Strings.Get("Code_SourcesPage_Browse"), VerticalAlignment = VerticalAlignment.Bottom };
        var slug = new TextBox { Header = Strings.Get("Code_SourcesPage_Name"), PlaceholderText = "notes" };
        var corpusClass = new ComboBox { Header = Strings.Get("Code_SourcesPage_Class"), ItemsSource = CorpusTaxonomy.CorpusClasses, SelectedIndex = 0, MinWidth = 160 };
        var trust = new ComboBox { Header = Strings.Get("Code_SourcesPage_Trust"), ItemsSource = CorpusTaxonomy.TrustTiers, SelectedIndex = 0, MinWidth = 160 };
        bool slugEdited = false;
        root.TextChanged += (_, _) =>
        {
            if (!slugEdited)
            {
                slug.Text = SourceSlugSuggestion.Suggest(root.Text, "filesystem", _model.TakenSlugs);
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

        var rootRow = new Grid { ColumnSpacing = 8 };
        rootRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        rootRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        rootRow.Children.Add(root);
        Grid.SetColumn(browse, 1);
        rootRow.Children.Add(browse);
        var classes = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        classes.Children.Add(corpusClass);
        classes.Children.Add(trust);
        var form = new StackPanel { Spacing = 12, MinWidth = 440 };
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
            Title = Strings.Get("Code_SourcesPage_AddSource"),
            Content = form,
            PrimaryButtonText = Strings.Get("Code_SourcesPage_Add"),
            CloseButtonText = Strings.Get("Code_SourcesPage_Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && root.Text.Trim().Length > 0 && slug.Text.Trim().Length > 0)
        {
            await _model.AddAsync(new NewSource(slug.Text, root.Text,
                CorpusClass: corpusClass.SelectedItem as string ?? "document",
                TrustTier: trust.SelectedItem as string ?? "authored")).ConfigureAwait(true);
        }
    }
}
