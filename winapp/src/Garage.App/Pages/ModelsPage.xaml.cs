using System.ComponentModel;
using Garage.App.Core.Models;
using Garage.App.Core.Operations;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Garage.App.Pages;

/// <summary>The Models page (the Mac's <c>ModelsView</c>, embedding and distillation; local llama models later).</summary>
public sealed partial class ModelsPage : Page
{
    private ModelsViewModel _model = null!;
    private OperationRunner _operations = null!;
    private OperationRunner _backfill = null!;

    /// <summary>Creates the page.</summary>
    public ModelsPage() => InitializeComponent();

    /// <inheritdoc/>
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        var pages = (PageModels)e.Parameter;
        _model = pages.Models;
        _operations = pages.State.Operations;
        _backfill = pages.State.Backfill;
        ModelsList.ItemsSource = _model.Models;
        FactsProviderBox.ItemsSource = ModelProviders.All.Select(p => p.DisplayName()).ToList();
        _model.PropertyChanged += OnChanged;
        _operations.PropertyChanged += OnChanged;
        _backfill.PropertyChanged += OnChanged;
        Show();
        await _model.LoadAsync().ConfigureAwait(true);
        FactsProviderBox.SelectedIndex = ModelProviders.All.ToList().IndexOf(_model.FactsProvider);
        FactsModelBox.Text = _model.FactsModel;
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        _model.PropertyChanged -= OnChanged;
        _operations.PropertyChanged -= OnChanged;
        _backfill.PropertyChanged -= OnChanged;
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e) => Show();

    private void Show()
    {
        if (_model.Headline is { } headline)
        {
            HeadlineCircle.Background = Look.TintBrush(headline.Tint);
            HeadlineGlyph.Glyph = Look.StatusGlyph(headline.Symbol);
            HeadlineTitle.Text = headline.Title;
            HeadlineDetail.Text = headline.Detail;
            HeadlineProgress.Visibility = Look.VisibleWhen(headline.Progress is not null);
            HeadlineProgress.Value = Look.Percent(headline.Progress);
        }
        SummaryText.Text = _model.Summary;
        bool embedding = _backfill.IsRunning;
        EmbedAllButton.IsEnabled = !embedding && _model.Models.Count > 0;
        CancelEmbedButton.Visibility = Look.VisibleWhen(embedding);
        RegisterButton.IsEnabled = !_operations.IsRunning;
        BackfillPanel.Visibility = Look.VisibleIf(_model.BackfillProgress);
        BackfillText.Text = _model.BackfillProgress ?? "";
        BackfillBar.IsIndeterminate = _model.BackfillFraction is null;
        BackfillBar.Value = Look.Percent(_model.BackfillFraction);
        string? message = _model.ErrorMessage ?? _model.LastResult;
        ResultBar.IsOpen = message is not null;
        ResultBar.Severity = _model.ErrorMessage is not null ? InfoBarSeverity.Error : InfoBarSeverity.Informational;
        ResultBar.Message = message ?? "";
    }

    private async void OnEmbedAll(object sender, RoutedEventArgs e) => await _model.EmbedAsync().ConfigureAwait(true);

    private async void OnEmbedOne(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string slug })
        {
            await _model.EmbedAsync(slug).ConfigureAwait(true);
        }
    }

    private void OnCancelEmbed(object sender, RoutedEventArgs e) => _model.CancelEmbed();

    private async void OnMakeDefault(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string slug })
        {
            await _model.SetDefaultAsync(slug).ConfigureAwait(true);
        }
    }

    private async void OnDrop(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string slug })
        {
            return;
        }
        var confirm = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = $"Drop {slug}?",
            Content = Strings.Get("Code_ModelsPage_ThisDeregistersTheModelAndDeletes"),
            PrimaryButtonText = Strings.Get("Code_ModelsPage_Drop"),
            CloseButtonText = Strings.Get("Code_ModelsPage_Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await confirm.ShowAsync() == ContentDialogResult.Primary)
        {
            await _model.DropAsync(slug).ConfigureAwait(true);
        }
    }

    private async void OnRegister(object sender, RoutedEventArgs e)
    {
        var slug = new TextBox { Header = Strings.Get("Code_ModelsPage_Name"), PlaceholderText = "bge-m3" };
        var provider = new ComboBox { Header = Strings.Get("Code_ModelsPage_Provider"), ItemsSource = ModelProviders.All.Select(p => p.DisplayName()).ToList(), SelectedIndex = 1, MinWidth = 170 };
        var modelRef = new TextBox { Header = Strings.Get("Code_ModelsPage_ModelNameOnTheServerIf"), PlaceholderText = "bge-m3" };
        var dims = new NumberBox { Header = Strings.Get("Code_ModelsPage_Dimensions0FromTheModelCatalog"), Value = 0, Minimum = 0, Maximum = 16384, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var makeDefault = new CheckBox { Content = Strings.Get("Code_ModelsPage_MakeItTheDefaultForSearch") };
        var form = new StackPanel { Spacing = 12, MinWidth = 420 };
        foreach (UIElement child in new UIElement[] { slug, provider, modelRef, dims, makeDefault })
        {
            form.Children.Add(child);
        }
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Strings.Get("Code_ModelsPage_RegisterModel"),
            Content = form,
            PrimaryButtonText = Strings.Get("Code_ModelsPage_Register"),
            CloseButtonText = Strings.Get("Code_ModelsPage_Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && slug.Text.Trim().Length > 0)
        {
            await _model.RegisterAsync(new NewModel(
                slug.Text,
                ModelProviders.All[Math.Max(0, provider.SelectedIndex)],
                double.IsNaN(dims.Value) ? 0 : (int)dims.Value,
                modelRef.Text,
                makeDefault.IsChecked == true)).ConfigureAwait(true);
        }
    }

    private async void OnSaveFacts(object sender, RoutedEventArgs e)
    {
        ModelProvider provider = ModelProviders.All[Math.Max(0, FactsProviderBox.SelectedIndex)];
        await _model.SaveFactsModelAsync(provider, FactsModelBox.Text).ConfigureAwait(true);
    }
}
