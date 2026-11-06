using System.ComponentModel;
using System.Globalization;
using Garage.App.Core.Mcp;
using Garage.App.Core.Models;
using Garage.App.Core.Onboarding;
using Garage.App.Platform;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Garage.App.FirstRun;

/// <summary>The setup assistant's pages, drawn from <see cref="FirstRunCoordinator"/>.</summary>
public sealed partial class FirstRunView : UserControl
{
    private readonly FirstRunCoordinator _model;
    private FirstRunStep? _built;

    /// <summary>Creates the view over the coordinator.</summary>
    public FirstRunView(FirstRunCoordinator model)
    {
        _model = model ?? throw new ArgumentNullException(nameof(model));
        InitializeComponent();
        _model.PropertyChanged += OnModelChanged;
        _model.SourceTemplates.CollectionChanged += (_, _) => Rebuild();
        _model.Clients.CollectionChanged += (_, _) => Rebuild();
        Show();
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(FirstRunCoordinator.ServiceChecks) && _model.Step == FirstRunStep.SettingUp)
        {
            Rebuild();
        }
        Show();
    }

    private void Rebuild()
    {
        _built = null;
        Show();
    }

    private void Show()
    {
        FirstRunStep step = _model.Step;
        StepsPanel.Children.Clear();
        foreach (FirstRunStep each in FirstRunSteps.All)
        {
            bool current = each == step;
            var label = new TextBlock
            {
                Text = string.Create(CultureInfo.CurrentCulture, $"{(int)each + 1}. {each.Title()}"),
                Style = (Style)Application.Current.Resources[current ? "BodyStrongTextBlockStyle" : "BodyTextBlockStyle"],
                Foreground = Brush(each <= step ? "TextFillColorPrimaryBrush" : "TextFillColorTertiaryBrush"),
            };
            AutomationProperties.SetName(label, current ? $"Step {(int)each + 1} of 4, {each.Title()}, current" : $"Step {(int)each + 1} of 4, {each.Title()}");
            StepsPanel.Children.Add(label);
        }
        StepTitle.Text = step.Title();
        StepIntro.Text = step switch
        {
            FirstRunStep.SettingUp => _model.IsAfterDatabaseReset
                ? "The database was reset. Garage is creating a new one and registering the sources garage.json lists again."
                : "Garage starts its own database and services on this PC. Nothing leaves it.",
            FirstRunStep.SelectData => "Pick the folders Garage should index. You can add and remove sources later on the Sources page.",
            FirstRunStep.SelectModels => "Embedding models turn your documents into vectors for search; a distillation model gleans facts from them. They run in Ollama or LM Studio on this PC (or the server set in Settings).",
            _ => "Connect the assistants you use, so they can search your corpus. Each starts Garage's MCP server itself when it needs it.",
        };
        if (_built != step)
        {
            _built = step;
            BuildPage(step);
        }

        ProgressPanel.Visibility = Look.VisibleIf(_model.ProgressMessage);
        ProgressText.Text = _model.ProgressMessage ?? "";
        ErrorBar.IsOpen = _model.ErrorMessage is not null;
        ErrorBar.Message = _model.ErrorMessage ?? "";
        SummaryText.Text = step == FirstRunStep.SetupAgent ? _model.RegistrationSummary ?? "" : "";
        SummaryText.Visibility = Look.VisibleIf(SummaryText.Text);

        bool working = _model.IsWorking;
        BackButton.Visibility = Look.VisibleWhen(step is FirstRunStep.SelectModels or FirstRunStep.SetupAgent);
        BackButton.IsEnabled = !working;
        RetryButton.Visibility = Look.VisibleWhen(step == FirstRunStep.SettingUp && (_model.ServicesFailed || _model.ErrorMessage is not null));
        SkipButton.IsEnabled = !working;
        ContinueButton.IsEnabled = !working && step != FirstRunStep.SettingUp;
        ContinueButton.Content = step switch
        {
            FirstRunStep.SettingUp => "Continue",
            FirstRunStep.SelectData => _model.SelectedSourceIds.Count == 0 ? "Skip This Step" : "Add Sources",
            FirstRunStep.SelectModels => "Continue",
            _ => "Finish",
        };
    }

    private void BuildPage(FirstRunStep step)
    {
        PagePanel.Children.Clear();
        switch (step)
        {
            case FirstRunStep.SettingUp:
                foreach (FirstRunServiceCheck check in _model.ServiceChecks)
                {
                    PagePanel.Children.Add(CheckRow(check));
                }
                break;
            case FirstRunStep.SelectData:
                BuildDataPage();
                break;
            case FirstRunStep.SelectModels:
                BuildModelsPage();
                break;
            default:
                BuildAgentPage();
                break;
        }
    }

    private static Grid CheckRow(FirstRunServiceCheck check)
    {
        (string glyph, string brush, string state) = check.State switch
        {
            FirstRunCheckState.Ready => ("", "SystemFillColorSuccessBrush", "ready"),
            FirstRunCheckState.Failed => ("", "SystemFillColorCriticalBrush", "failed"),
            FirstRunCheckState.InProgress => ("", "AccentFillColorDefaultBrush", "starting"),
            _ => ("", "TextFillColorTertiaryBrush", "waiting"),
        };
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(check.State == FirstRunCheckState.InProgress
            ? new ProgressRing { IsActive = true, Width = 18, Height = 18 }
            : new FontIcon { Glyph = glyph, FontSize = 18, Foreground = Brush(brush) });
        var text = new StackPanel();
        text.Children.Add(new TextBlock { Text = check.Title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        text.Children.Add(new TextBlock
        {
            Text = check.Message ?? check.Detail,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brush(check.IsFailed ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"),
        });
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        AutomationProperties.SetName(row, $"{check.Title}: {state}. {check.Message ?? check.Detail}");
        AutomationProperties.SetAutomationId(row, "firstRun.check." + check.Id);
        return row;
    }

    private void BuildDataPage()
    {
        foreach (FirstRunSourceTemplate template in _model.SourceTemplates)
        {
            var box = new CheckBox
            {
                IsChecked = _model.SelectedSourceIds.Contains(template.Id),
                IsEnabled = template.IsAvailable,
                Content = TwoLines(template.Title, template.IsAvailable ? template.Subtitle : $"{template.Subtitle} · not on this PC"),
            };
            AutomationProperties.SetName(box, template.IsAvailable ? $"{template.Title}, {template.Subtitle}" : $"{template.Title}, not on this PC");
            AutomationProperties.SetAutomationId(box, "firstRun.source." + template.Slug);
            box.Click += (_, _) =>
            {
                _model.ToggleSource(template);
                box.IsChecked = _model.SelectedSourceIds.Contains(template.Id);
            };
            if (template.IsCustom)
            {
                var remove = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, Padding = new Thickness(6), VerticalAlignment = VerticalAlignment.Center };
                AutomationProperties.SetName(remove, $"Remove {template.Title}");
                ToolTipService.SetToolTip(remove, $"Remove {template.Title}");
                remove.Click += (_, _) => _model.RemoveCustomFolder(template);
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                row.Children.Add(box);
                row.Children.Add(remove);
                PagePanel.Children.Add(row);
            }
            else
            {
                PagePanel.Children.Add(box);
            }
        }
        var add = new Button { Content = Strings.Get("Code_FirstRunView_AddFolder"), Margin = new Thickness(0, 6, 0, 0) };
        AutomationProperties.SetAutomationId(add, "firstRun.addFolder");
        add.Click += async (_, _) =>
        {
            if (await Pickers.FolderAsync().ConfigureAwait(true) is { } folder)
            {
                _model.AddCustomFolder(folder);
            }
        };
        PagePanel.Children.Add(add);
    }

    private void BuildModelsPage()
    {
        var providers = new RadioButtons { Header = Strings.Get("Code_FirstRunView_RunModelsWith"), MaxColumns = 2 };
        foreach (ModelProvider provider in FirstRunModelPlan.Providers)
        {
            providers.Items.Add(provider.DisplayName());
        }
        providers.SelectedIndex = Math.Max(0, FirstRunModelPlan.Providers.ToList().IndexOf(_model.Provider));
        AutomationProperties.SetAutomationId(providers, "firstRun.provider");
        providers.SelectionChanged += (_, _) =>
        {
            if (providers.SelectedIndex >= 0)
            {
                _model.Provider = FirstRunModelPlan.Providers[providers.SelectedIndex];
            }
        };
        PagePanel.Children.Add(providers);

        PagePanel.Children.Add(Heading("Embedding models"));
        if (_model.EmbeddingPresets.Count == 0)
        {
            PagePanel.Children.Add(Note("No model catalog was found; register models on the Models page."));
        }
        foreach (ModelPreset preset in _model.EmbeddingPresets)
        {
            string detail = string.Create(CultureInfo.CurrentCulture, $"{preset.NativeDims} dimensions") + (preset.Featured ? " · recommended" : "");
            var box = new CheckBox { IsChecked = _model.SelectedEmbeddingSlugs.Contains(preset.Slug), Content = TwoLines(preset.Name, detail) };
            AutomationProperties.SetName(box, $"{preset.Name}, {detail}");
            AutomationProperties.SetAutomationId(box, "firstRun.embedding." + preset.Slug);
            box.Click += (_, _) =>
            {
                _model.ToggleEmbedding(preset);
                box.IsChecked = _model.SelectedEmbeddingSlugs.Contains(preset.Slug);
            };
            PagePanel.Children.Add(box);
        }

        PagePanel.Children.Add(Heading("Distillation model"));
        PagePanel.Children.Add(Note("Gleans facts from your documents. Pick one, or type the name your provider gives a model; leave it empty to choose later."));
        var name = new TextBox { Header = Strings.Get("Code_FirstRunView_Model"), Text = _model.DistillationModel, PlaceholderText = "gemma2:2b", MaxWidth = 360, HorizontalAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetAutomationId(name, "firstRun.distillation");
        name.TextChanged += (_, _) => _model.DistillationModel = name.Text;
        var presets = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (ModelPreset preset in _model.DistillationPresets.Take(6))
        {
            var pick = new Button { Content = preset.Name };
            ToolTipService.SetToolTip(pick, $"Use {preset.Name} ({preset.ReferenceFor(_model.Provider)})");
            pick.Click += (_, _) =>
            {
                _model.ToggleDistillation(preset);
                name.Text = _model.DistillationModel;
            };
            presets.Children.Add(pick);
        }
        PagePanel.Children.Add(new ScrollViewer { Content = presets, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
        PagePanel.Children.Add(name);
    }

    private void BuildAgentPage()
    {
        foreach (McpClientRowPresentation client in _model.Clients)
        {
            var box = new CheckBox
            {
                IsChecked = _model.SelectedClientKeys.Contains(client.Client.Key),
                IsEnabled = !client.IsConnected,
                Content = TwoLines(client.Client.Label, client.Status),
            };
            AutomationProperties.SetName(box, $"{client.Client.Label}, {client.Status}");
            AutomationProperties.SetAutomationId(box, "firstRun.client." + client.Client.Key);
            box.Click += (_, _) =>
            {
                _model.ToggleClient(client.Client.Key);
                box.IsChecked = _model.SelectedClientKeys.Contains(client.Client.Key);
            };
            PagePanel.Children.Add(box);
        }
        var connect = new Button { Content = Strings.Get("Code_FirstRunView_ConnectSelected"), Margin = new Thickness(0, 6, 0, 0) };
        AutomationProperties.SetAutomationId(connect, "firstRun.connect");
        connect.Click += async (_, _) => await _model.RegisterSelectedClientsAsync().ConfigureAwait(true);
        PagePanel.Children.Add(connect);
    }

    private static StackPanel TwoLines(string title, string detail)
    {
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = title });
        panel.Children.Add(new TextBlock
        {
            Text = detail,
            TextWrapping = TextWrapping.Wrap,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = Brush("TextFillColorSecondaryBrush"),
        });
        return panel;
    }

    private static TextBlock Heading(string text)
    {
        var heading = new TextBlock { Text = text, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], Margin = new Thickness(0, 8, 0, 0) };
        AutomationProperties.SetHeadingLevel(heading, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level3);
        return heading;
    }

    private static TextBlock Note(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Foreground = Brush("TextFillColorSecondaryBrush"),
    };

    private static Brush Brush(string key) => (Brush)Application.Current.Resources[key];

    private void OnSkip(object sender, RoutedEventArgs e) => _model.Skip();

    private void OnBack(object sender, RoutedEventArgs e) => _model.GoBack();

    private async void OnRetry(object sender, RoutedEventArgs e) => await _model.RetryServicesAsync().ConfigureAwait(true);

    private async void OnContinue(object sender, RoutedEventArgs e)
    {
        switch (_model.Step)
        {
            case FirstRunStep.SelectData:
                await _model.CommitSourcesAsync().ConfigureAwait(true);
                break;
            case FirstRunStep.SelectModels:
                await _model.CommitModelsAsync().ConfigureAwait(true);
                break;
            case FirstRunStep.SetupAgent:
                _model.Finish();
                break;
            default:
                break;
        }
    }
}
