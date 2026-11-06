using System.ComponentModel;
using System.Globalization;
using Garage.App.Core.Mcp;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Navigation;

namespace Garage.App.Pages;

/// <summary>
/// The MCP Server page (the Mac's <c>MCPServerView</c>): the server with its switch, port, Test and
/// Restart; one row per assistant with Connect, Update and Disconnect; and Try It, which calls the
/// running server the way an assistant would.
/// </summary>
public sealed partial class McpPage : Page
{
    private PageModels _pages = null!;
    private McpViewModel _model = null!;
    private McpTryItViewModel _try = null!;
    private bool _showing;

    /// <summary>Creates the page.</summary>
    public McpPage() => InitializeComponent();

    /// <inheritdoc/>
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        _pages = (PageModels)e.Parameter;
        _model = _pages.Mcp;
        _try = _pages.McpTryIt;
        RowsList.ItemsSource = _model.Rows;
        _model.PropertyChanged += OnChanged;
        _try.PropertyChanged += OnTryChanged;
        _showing = true;
        TryPromptBox.Text = _try.Prompt;
        TryQueryBox.Text = _try.ToolQuery;
        TryDocumentBox.Text = _try.ToolDocumentId;
        TryJsonBox.Text = _try.ToolArgumentsJson;
        TryModeBar.SelectedItem = TryModeBar.Items.First(i => (string)i.Tag == _try.Mode.ToString());
        FillTools();
        _showing = false;
        Show();
        ShowTry();
        await _model.LoadAsync().ConfigureAwait(true);
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        _model.PropertyChanged -= OnChanged;
        _try.PropertyChanged -= OnTryChanged;
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        Show();
        ShowTry();
    }

    private async void OnHttpToggled(object sender, RoutedEventArgs e)
    {
        if (!_showing && HttpSwitch.IsOn != _model.HttpEnabled)
        {
            await _model.SetHttpEnabledAsync(HttpSwitch.IsOn).ConfigureAwait(true);
        }
    }

    private void Show()
    {
        if (_model.Headline is { } headline)
        {
            HeadlineCircle.Background = Look.TintBrush(headline.Tint);
            HeadlineGlyph.Glyph = Look.StatusGlyph(headline.Symbol);
            HeadlineTitle.Text = headline.Title;
            HeadlineDetail.Text = headline.Detail;
        }
        _showing = true;
        HttpPanel.Visibility = _model.CanServeHttp ? Visibility.Visible : Visibility.Collapsed;
        HttpSwitch.IsOn = _model.HttpEnabled;
        HttpSwitch.IsEnabled = !_model.IsSwitchingHttp;
        HttpUrlText.Text = _model.HttpUrl?.ToString() ?? "";
        CopyAddressButton.Visibility = Look.VisibleWhen(_model.HttpUrl is not null);
        PortBox.Value = _model.Port;
        PortBox.IsEnabled = !_model.IsSwitchingHttp;
        TestButton.IsEnabled = RestartButton.IsEnabled = _model.HttpUrl is not null && !_model.IsSwitchingHttp;
        _showing = false;
        SummaryText.Text = _model.Summary;
        ConnectAllButton.IsEnabled = _model.CanConnectAll;
        CommandText.Text = _model.ServerCommand;
        string? message = _model.ErrorMessage ?? _model.LastResult;
        ResultBar.IsOpen = message is not null;
        ResultBar.Severity = _model.ErrorMessage is not null ? InfoBarSeverity.Error : InfoBarSeverity.Informational;
        ResultBar.Message = message ?? "";
    }

    private void OnCopyAddress(object sender, RoutedEventArgs e) => Clipboard.Copy(_model.HttpUrl?.ToString());

    private async void OnPortChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_showing && !double.IsNaN(args.NewValue) && (int)args.NewValue != _model.Port)
        {
            await _model.SetPortAsync((int)args.NewValue).ConfigureAwait(true);
        }
    }

    private async void OnRandomPort(object sender, RoutedEventArgs e) => await _model.SetPortAsync(McpViewModel.RandomPort()).ConfigureAwait(true);

    private async void OnTest(object sender, RoutedEventArgs e)
    {
        TestButton.IsEnabled = false;
        ToolsText.Text = await _try.TestAsync().ConfigureAwait(true);
        TestButton.IsEnabled = _model.HttpUrl is not null;
        FillTools();
    }

    private async void OnRestart(object sender, RoutedEventArgs e) => await _model.RestartHttpAsync().ConfigureAwait(true);

    private async void OnLookAgain(object sender, RoutedEventArgs e) => await _model.CheckRegistrationsAsync().ConfigureAwait(true);

    private async void OnConnectFile(object sender, RoutedEventArgs e)
    {
        if (await Platform.Pickers.OpenFileAsync(".json").ConfigureAwait(true) is { } path)
        {
            await _model.ConnectConfigFileAsync(path).ConfigureAwait(true);
        }
    }

    private async void OnConnectAll(object sender, RoutedEventArgs e) => await _model.ConnectAllAsync().ConfigureAwait(true);

    private async void OnConnect(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string key })
        {
            await _model.ConnectAsync(key).ConfigureAwait(true);
        }
    }

    private async void OnDisconnect(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string key })
        {
            await _model.DisconnectAsync(key).ConfigureAwait(true);
        }
    }

    private void OnOpenConfig(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string path })
        {
            Shell.Open(path);
        }
    }

    private void OnShowConfig(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string path } && !Shell.ShowInExplorer(path))
        {
            Shell.ShowInExplorer(Path.GetDirectoryName(path));
        }
    }

    private void OnCopyPath(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string path })
        {
            Clipboard.Copy(path);
        }
    }

    // MARK: Try It

    private void OnTryChanged(object? sender, PropertyChangedEventArgs e) => ShowTry();

    private void FillTools()
    {
        bool showing = _showing;
        _showing = true;
        IReadOnlyList<McpToolInfo> tools = _try.AvailableTools;
        TryToolBox.ItemsSource = tools;
        TryToolBox.SelectedItem = tools.FirstOrDefault(t => t.Name == _try.ToolName) ?? (tools.Count > 0 ? tools[0] : null);
        if (TryToolBox.SelectedItem is McpToolInfo selected)
        {
            _try.ToolName = selected.Name;
        }
        _showing = showing;
    }

    private void OnTryModeChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (!_showing && sender.SelectedItem is { Tag: string tag } && Enum.TryParse(tag, out TryItMode mode))
        {
            _try.Mode = mode;
        }
    }

    private void OnTryToolChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_showing && TryToolBox.SelectedItem is McpToolInfo tool)
        {
            _try.ToolName = tool.Name;
        }
    }

    private void OnTryInputChanged(object sender, TextChangedEventArgs e)
    {
        if (_showing)
        {
            return;
        }
        _try.Prompt = TryPromptBox.Text;
        _try.ToolQuery = TryQueryBox.Text;
        _try.ToolDocumentId = TryDocumentBox.Text;
        _try.ToolArgumentsJson = TryJsonBox.Text;
        _try.Notify();
    }

    private void OnTryTokensChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_showing && !double.IsNaN(args.NewValue))
        {
            _try.MaxTokens = (int)args.NewValue;
        }
    }

    private void OnTryTemperatureChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (!_showing)
        {
            _try.Temperature = Math.Round(e.NewValue, 2);
        }
        TryTemperatureText.Text = e.NewValue.ToString("0.00", CultureInfo.CurrentCulture);
    }

    private async void OnTryRun(object sender, RoutedEventArgs e) => await _try.RunAsync().ConfigureAwait(true);

    private void OnTryCopy(object sender, RoutedEventArgs e) => Clipboard.Copy(_try.Answer?.DisplayText ?? _try.RawOutput);

    private void ShowTry()
    {
        bool showing = _showing;
        _showing = true;
        TryItMode mode = _try.Mode;
        bool tool = mode == TryItMode.Tool;
        TryExplanation.Text = McpTryItViewModel.Explanation(mode, _pages.Models.FactsModel);
        PromptPanel.Visibility = Look.HiddenWhen(tool);
        ToolPanel.Visibility = Look.VisibleWhen(tool);
        TryPromptBox.PlaceholderText = mode == TryItMode.Ask ? "What did I decide about the secure boot chain?" : "Write a haiku about a garage.";
        TryTokensBox.Value = _try.MaxTokens;
        TryTemperatureSlider.Value = _try.Temperature;
        TryTemperatureText.Text = _try.Temperature.ToString("0.00", CultureInfo.CurrentCulture);
        ToolArgumentKind kind = _try.ArgumentKind;
        TryQueryBox.Visibility = Look.VisibleWhen(kind == ToolArgumentKind.Query);
        TryDocumentBox.Visibility = Look.VisibleWhen(kind == ToolArgumentKind.DocumentId);
        TryJsonBox.Visibility = Look.VisibleWhen(kind == ToolArgumentKind.Json);
        TryToolDescription.Text = _try.ToolDescription;
        TryToolDescription.Visibility = Look.VisibleIf(_try.ToolDescription);
        TryRunButton.IsEnabled = _try.CanRun;
        TryProgress.IsActive = _try.IsRunning;
        TryStartServer.Visibility = Look.HiddenWhen(_try.ServerRunning);
        TryError.Text = _try.Error ?? "";
        TryError.Visibility = Look.VisibleIf(_try.Error);

        PlaygroundAnswer? answer = _try.Answer;
        string? output = answer?.DisplayText ?? _try.RawOutput;
        TryOutputPanel.Visibility = Look.VisibleWhen(!string.IsNullOrEmpty(output));
        TryOutputTitle.Text = answer is null ? tool ? "Response" : "Output" : mode == TryItMode.Ask ? "Answer" : "Completion";
        TryOutputModel.Text = answer?.ModelLine ?? "";
        TryOutputText.Text = output ?? "";
        TryOutputText.FontFamily = answer is null
            ? new Microsoft.UI.Xaml.Media.FontFamily("Consolas")
            : (Microsoft.UI.Xaml.Media.FontFamily)Application.Current.Resources["ContentControlThemeFontFamily"];
        IReadOnlyList<PlaygroundCitation> citations = answer?.Citations ?? [];
        TrySourcesTitle.Visibility = Look.VisibleWhen(citations.Count > 0);
        TrySourcesPanel.Children.Clear();
        foreach (PlaygroundCitation citation in citations)
        {
            var row = new StackPanel { Spacing = 2 };
            var title = new TextBlock { TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
            title.Text = string.Create(CultureInfo.CurrentCulture, $"{citation.N}. {citation.DisplayTitle}");
            if (citation.ScoreText.Length > 0)
            {
                title.Text += $"  ({citation.ScoreText})";
                ToolTipService.SetToolTip(title, "Retrieval score");
            }
            row.Children.Add(title);
            if (!string.IsNullOrEmpty(citation.Location))
            {
                row.Children.Add(new TextBlock { Text = citation.Location, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"), FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis });
            }
            if (!string.IsNullOrEmpty(citation.Snippet))
            {
                row.Children.Add(new TextBlock { Text = citation.Snippet, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontSize = 12 });
            }
            TrySourcesPanel.Children.Add(row);
        }
        _showing = showing;
    }
}
