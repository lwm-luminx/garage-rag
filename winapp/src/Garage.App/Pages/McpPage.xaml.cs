using System.ComponentModel;
using Garage.App.Core.Mcp;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Garage.App.Pages;

/// <summary>The MCP Server page (the Mac's <c>MCPServerView</c>; the HTTP server comes with Garage's MCP service).</summary>
public sealed partial class McpPage : Page
{
    private McpViewModel _model = null!;

    /// <summary>Creates the page.</summary>
    public McpPage() => InitializeComponent();

    /// <inheritdoc/>
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        _model = ((PageModels)e.Parameter).Mcp;
        RowsList.ItemsSource = _model.Rows;
        _model.PropertyChanged += OnChanged;
        Show();
        await _model.LoadAsync().ConfigureAwait(true);
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e) => _model.PropertyChanged -= OnChanged;

    private void OnChanged(object? sender, PropertyChangedEventArgs e) => Show();

    private bool _showing;

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
        _showing = false;
        SummaryText.Text = _model.Summary;
        ConnectAllButton.IsEnabled = _model.CanConnectAll;
        CommandText.Text = _model.ServerCommand;
        string? message = _model.ErrorMessage ?? _model.LastResult;
        ResultBar.IsOpen = message is not null;
        ResultBar.Severity = _model.ErrorMessage is not null ? InfoBarSeverity.Error : InfoBarSeverity.Informational;
        ResultBar.Message = message ?? "";
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
}
