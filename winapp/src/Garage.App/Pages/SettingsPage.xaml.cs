using System.ComponentModel;
using Garage.App.Core.Settings;
using Garage.App.Core.Store;
using Garage.App.Platform;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Garage.App.Pages;

/// <summary>Settings, in the navigation footer: the model servers and models, and the backend.</summary>
public sealed partial class SettingsPage : Page
{
    private SettingsViewModel _model = null!;
    private PageModels _pages = null!;
    private AppOptionsViewModel _options = null!;
    private TipJarViewModel? _tips;
    private bool _showingOptions;

    /// <summary>Creates the page.</summary>
    public SettingsPage() => InitializeComponent();

    /// <inheritdoc/>
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        var pages = (PageModels)e.Parameter;
        _pages = pages;
        _model = pages.Settings;
        _options = pages.Options;
        BackendDescription.Text = pages.State.Backend.Description;
        ShowOptions();
        _ = ShowTipJarAsync();
        _model.PropertyChanged += OnChanged;
        await _model.LoadAsync().ConfigureAwait(true);
        BuildFields();
        Show();
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e) => _model.PropertyChanged -= OnChanged;

    // One editor per field: a picker for a closed set, a text box otherwise, bound both ways to the field.
    private void BuildFields()
    {
        FieldsPanel.Children.Clear();
        foreach (SettingField field in _model.Fields)
        {
            var panel = new StackPanel { Spacing = 4 };
            if (field.Choices is { } choices)
            {
                var picker = new ComboBox { Header = field.Label, ItemsSource = choices.Select(c => c.Length == 0 ? "(same as distillation)" : c).ToList(), MinWidth = 240 };
                picker.SelectedIndex = Math.Max(0, choices.ToList().IndexOf(field.Value));
                picker.SelectionChanged += (_, _) => field.Value = choices[Math.Max(0, picker.SelectedIndex)];
                AutomationIds(picker, field);
                panel.Children.Add(picker);
            }
            else
            {
                var box = new TextBox { Header = field.Label, Text = field.Value, MinWidth = 420 };
                box.TextChanged += (_, _) => field.Value = box.Text;
                field.PropertyChanged += (_, args) =>
                {
                    if (args.PropertyName == nameof(SettingField.Value) && box.Text != field.Value)
                    {
                        box.Text = field.Value;
                    }
                };
                AutomationIds(box, field);
                panel.Children.Add(box);
            }
            panel.Children.Add(new TextBlock
            {
                Text = $"{field.Description}  ({field.Name})",
                TextWrapping = TextWrapping.Wrap,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            });
            FieldsPanel.Children.Add(panel);
        }
    }

    private static void AutomationIds(FrameworkElement element, SettingField field) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(element, "settings." + field.Name);

    private void OnChanged(object? sender, PropertyChangedEventArgs e) => Show();

    private void Show()
    {
        string? message = _model.ErrorMessage ?? _model.LastResult;
        ResultBar.IsOpen = message is not null;
        ResultBar.Severity = _model.ErrorMessage is not null ? InfoBarSeverity.Error : InfoBarSeverity.Success;
        ResultBar.Title = _model.ErrorMessage is not null ? "Not saved" : "Saved";
        ResultBar.Message = message ?? "";
    }

    private void ShowOptions()
    {
        _showingOptions = true;
        StartupSwitch.IsOn = _options.LaunchAtStartup;
        StartupSwitch.IsEnabled = _options.CanLaunchAtStartup;
        ChannelBox.ItemsSource = Enum.GetValues<UpdateChannel>().Select(c => c.Title()).ToList();
        ChannelBox.SelectedIndex = (int)_options.Channel;
        ChannelBox.IsEnabled = _options.CanChooseChannel;
        ChannelText.Text = _options.UpdateExplanation;
        OptionsBar.IsOpen = _options.ErrorMessage is not null;
        OptionsBar.Message = _options.ErrorMessage ?? "";
        string version = typeof(App).Assembly.GetName().Version?.ToString(3) ?? "unknown";
        AboutText.Text = $"Garage {version} for Windows ({_options.Distribution.Title()}), with Garage {_pages.State.ServerVersion ?? "(not connected)"} running its services.";
        _showingOptions = false;
    }

    private void OnStartupToggled(object sender, RoutedEventArgs e)
    {
        if (!_showingOptions)
        {
            _options.LaunchAtStartup = StartupSwitch.IsOn;
            ShowOptions();
        }
    }

    private void OnChannelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_showingOptions && ChannelBox.SelectedIndex >= 0)
        {
            _options.Channel = (UpdateChannel)ChannelBox.SelectedIndex;
            ShowOptions();
        }
    }

    private void OnSetupAssistant(object sender, RoutedEventArgs e) => _pages.FirstRun.Begin(force: true);

    private async void OnReportBug(object sender, RoutedEventArgs e) =>
        await Dialogs.BugReportDialog.ShowAsync(XamlRoot, await _pages.NewBugReportAsync().ConfigureAwait(true)).ConfigureAwait(true);

    private void OnNotices(object sender, RoutedEventArgs e)
    {
        string notices = Path.Combine(AppContext.BaseDirectory, "THIRD_PARTY_NOTICES.txt");
        if (File.Exists(notices))
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(notices) { UseShellExecute = true })?.Dispose();
        }
    }

    // The tip jar is the Store build's only; the other builds have no Store to buy through.
    private async Task ShowTipJarAsync()
    {
        if (_options.Distribution != AppDistribution.Store)
        {
            return;
        }
        _tips ??= new TipJarViewModel(new StoreTipStore(App.Current!.MainWindowHandle));
        _tips.PropertyChanged += (_, _) => ShowTips();
        await _tips.LoadAsync().ConfigureAwait(true);
    }

    private void ShowTips()
    {
        if (_tips is null)
        {
            return;
        }
        TipJarPanel.Visibility = Look.VisibleWhen(_tips.IsOffered && _tips.Phase != TipJarPhase.Loading);
        TipButtons.Children.Clear();
        foreach (TipProduct product in _tips.Products)
        {
            var button = new Button { Content = $"Tip {product.Price}", IsEnabled = _tips.Phase != TipJarPhase.Purchasing };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(button, "settings.tip." + product.OfferToken);
            button.Click += async (_, _) => await _tips.PurchaseAsync(product).ConfigureAwait(true);
            TipButtons.Children.Add(button);
        }
        TipNote.Text = _tips.Note ?? "";
    }

    private async void OnSave(object sender, RoutedEventArgs e) => await _model.SaveAsync().ConfigureAwait(true);

    private void OnRevert(object sender, RoutedEventArgs e)
    {
        _model.Revert();
        BuildFields();
    }
}
