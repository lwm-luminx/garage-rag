using System.ComponentModel;
using Garage.App.Core.Facts;
using Garage.App.Core.Models;
using Garage.App.Core.Onboarding;
using Garage.App.Core.Operations;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;

namespace Garage.App.Pages;

/// <summary>
/// The Models page (the Mac's <c>ModelsView</c>): embedding models with Embed All, the distillation
/// model with Glean Facts and its Fact Prompts, and Test an Embedding. Local llama models arrive with
/// Garage's llama service.
/// </summary>
public sealed partial class ModelsPage : Page
{
    private PageModels _pages = null!;
    private ModelsViewModel _model = null!;
    private FactPromptsViewModel _prompts = null!;
    private EmbeddingTestViewModel _test = null!;
    private OperationRunner _operations = null!;
    private OperationRunner _backfill = null!;
    private OperationRunner _facts = null!;
    private bool _showing;

    /// <summary>Creates the page.</summary>
    public ModelsPage() => InitializeComponent();

    /// <inheritdoc/>
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        _pages = (PageModels)e.Parameter;
        _model = _pages.Models;
        _prompts = _pages.FactPrompts;
        _test = _pages.EmbeddingTest;
        _operations = _pages.State.Operations;
        _backfill = _pages.State.Backfill;
        _facts = _pages.State.Facts;
        ModelsList.ItemsSource = _model.Models;
        FactsProviderBox.ItemsSource = ModelProviders.All.Select(p => p.DisplayName()).ToList();
        PromptsExplanation.Text = FactPromptsViewModel.Explanation;
        _showing = true;
        TestTextBox.Text = _test.Text;
        TestDimsBox.Value = _test.Dimensions ?? 0;
        _showing = false;
        _model.PropertyChanged += OnChanged;
        _operations.PropertyChanged += OnChanged;
        _backfill.PropertyChanged += OnChanged;
        _facts.PropertyChanged += OnChanged;
        _pages.Facts.PropertyChanged += OnChanged;
        _prompts.PropertyChanged += OnPromptsChanged;
        _test.PropertyChanged += OnTestChanged;
        Show();
        ShowPrompts();
        ShowTest();
        await _model.LoadAsync().ConfigureAwait(true);
        FactsProviderBox.SelectedIndex = ModelProviders.All.ToList().IndexOf(_model.FactsProvider);
        FactsModelBox.Text = _model.FactsModel;
        FillTestModels();
        await _prompts.LoadAsync().ConfigureAwait(true);
        ShowPrompts();
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        _model.PropertyChanged -= OnChanged;
        _operations.PropertyChanged -= OnChanged;
        _backfill.PropertyChanged -= OnChanged;
        _facts.PropertyChanged -= OnChanged;
        _pages.Facts.PropertyChanged -= OnChanged;
        _prompts.PropertyChanged -= OnPromptsChanged;
        _test.PropertyChanged -= OnTestChanged;
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

        bool gleaning = _facts.IsRunning;
        GleanButton.IsEnabled = !gleaning;
        StopGleanButton.Visibility = Look.VisibleWhen(gleaning);
        GleanPanel.Visibility = Look.VisibleIf(_pages.Facts.GleanProgress);
        GleanText.Text = _pages.Facts.GleanProgress ?? "";
        GleanBar.IsIndeterminate = _pages.Facts.GleanFraction is null;
        GleanBar.Value = Look.Percent(_pages.Facts.GleanFraction);

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

    // Glean Facts: every enabled prompt over every document with nothing from it yet, as on the Mac's Models page.
    private async void OnGlean(object sender, RoutedEventArgs e) =>
        await _pages.Facts.GleanAsync(_facts, _pages.State.Notifier).ConfigureAwait(true);

    private void OnStopGlean(object sender, RoutedEventArgs e) => _facts.Cancel();

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

    // Register Model, with the catalog's presets (the Mac's Add Model list): picking one fills the form
    // for the chosen provider, and shows its description, maker and model card.
    private async void OnRegister(object sender, RoutedEventArgs e)
    {
        HashSet<string> registered = [.. _model.Models.Select(m => m.Slug)];
        List<ModelPreset> presets = [.. FirstRunModelPlan.Ordered(_pages.FirstRun.Catalog.Embedding).Where(p => !registered.Contains(p.Slug))];
        var preset = new ComboBox
        {
            Header = Strings.Get("Code_ModelsPage_Preset"),
            PlaceholderText = Strings.Get("Code_ModelsPage_ChoosePreset"),
            ItemsSource = presets,
            DisplayMemberPath = nameof(ModelPreset.Name),
            MinWidth = 260,
            Visibility = Look.VisibleWhen(presets.Count > 0),
        };
        var about = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] };
        var card = new HyperlinkButton { Content = Strings.Get("Code_ModelsPage_ModelCard"), Visibility = Visibility.Collapsed, Padding = new Thickness(0) };
        var slug = new TextBox { Header = Strings.Get("Code_ModelsPage_Name"), PlaceholderText = "bge-m3" };
        var provider = new ComboBox { Header = Strings.Get("Code_ModelsPage_Provider"), ItemsSource = ModelProviders.All.Select(p => p.DisplayName()).ToList(), SelectedIndex = 1, MinWidth = 170 };
        var modelRef = new TextBox { Header = Strings.Get("Code_ModelsPage_ModelNameOnTheServerIf"), PlaceholderText = "bge-m3" };
        var dims = new NumberBox { Header = Strings.Get("Code_ModelsPage_Dimensions0FromTheModelCatalog"), Value = 0, Minimum = 0, Maximum = 16384, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var makeDefault = new CheckBox { Content = Strings.Get("Code_ModelsPage_MakeItTheDefaultForSearch"), IsChecked = _model.Models.Count == 0 };

        void Apply()
        {
            if (preset.SelectedItem is not ModelPreset chosen)
            {
                return;
            }
            ModelProvider selected = ModelProviders.All[Math.Max(0, provider.SelectedIndex)];
            slug.Text = chosen.Slug;
            modelRef.Text = chosen.ReferenceFor(selected) == chosen.Slug ? "" : chosen.ReferenceFor(selected);
            dims.Value = chosen.NativeDims ?? 0;
            about.Text = string.Join(" · ", new[] { chosen.Description, chosen.OriginSummary.Length > 0 ? $"Made by {chosen.OriginSummary}" : "" }.Where(p => p.Length > 0));
            about.Visibility = Look.VisibleIf(about.Text);
            card.Visibility = Look.VisibleIf(chosen.ModelCardUrl);
            card.NavigateUri = Uri.TryCreate(chosen.ModelCardUrl, UriKind.Absolute, out Uri? link) && link.Scheme == Uri.UriSchemeHttps ? link : null;
        }
        preset.SelectionChanged += (_, _) => Apply();
        provider.SelectionChanged += (_, _) => Apply();

        var form = new StackPanel { Spacing = 12, MinWidth = 420 };
        foreach (UIElement child in new UIElement[] { preset, about, card, slug, provider, modelRef, dims, makeDefault })
        {
            form.Children.Add(child);
        }
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Strings.Get("Code_ModelsPage_RegisterModel"),
            Content = new ScrollViewer { Content = form },
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
            FillTestModels();
        }
    }

    private async void OnSaveFacts(object sender, RoutedEventArgs e)
    {
        ModelProvider provider = ModelProviders.All[Math.Max(0, FactsProviderBox.SelectedIndex)];
        await _model.SaveFactsModelAsync(provider, FactsModelBox.Text).ConfigureAwait(true);
    }

    // MARK: Fact Prompts

    private void OnPromptsChanged(object? sender, PropertyChangedEventArgs e) => ShowPrompts();

    private void ShowPrompts()
    {
        PromptsError.Text = _prompts.Error ?? "";
        PromptsError.Visibility = Look.VisibleIf(_prompts.Error);
        PromptsPanel.Children.Clear();
        if (_prompts.Prompts.Count == 0)
        {
            PromptsPanel.Children.Add(new TextBlock
            {
                Text = _prompts.IsLoaded ? Strings.Get("Code_ModelsPage_NoPrompts") : Strings.Get("Code_ModelsPage_LoadingPrompts"),
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            });
            return;
        }
        foreach (FactPromptItem prompt in _prompts.Prompts)
        {
            PromptsPanel.Children.Add(PromptRow(prompt));
        }
    }

    private Border PromptRow(FactPromptItem prompt)
    {
        var enabled = new ToggleSwitch { IsOn = prompt.Enabled, OnContent = "", OffContent = "", MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(enabled, $"{prompt.Name} enabled");
        ToolTipService.SetToolTip(enabled, prompt.Enabled ? Strings.Get("Code_ModelsPage_PromptEnabledHelp") : Strings.Get("Code_ModelsPage_PromptDisabledHelp"));
        enabled.Toggled += async (_, _) =>
        {
            if (enabled.IsOn != prompt.Enabled)
            {
                await _prompts.SetEnabledAsync(prompt.Name, enabled.IsOn).ConfigureAwait(true);
            }
        };

        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        title.Children.Add(new TextBlock { Text = prompt.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        if (prompt.Badge.Length > 0)
        {
            title.Children.Add(Badge(prompt.Badge, Look.TintBrush(Core.Presentation.Tint.Blue)));
        }
        if (!prompt.Enabled)
        {
            title.Children.Add(Badge(Strings.Get("Code_ModelsPage_Disabled"), Look.TintBrush(Core.Presentation.Tint.Secondary)));
        }
        var text = new StackPanel { Spacing = 2 };
        text.Children.Add(title);
        text.Children.Add(new TextBlock { Text = prompt.Caption, FontFamily = new FontFamily("Consolas"), FontSize = 11, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
        text.Children.Add(new TextBlock { Text = prompt.Description, TextWrapping = TextWrapping.Wrap, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 12 });

        var run = new Button { Content = Strings.Get("Code_ModelsPage_Run"), IsEnabled = !_facts.IsRunning };
        ToolTipService.SetToolTip(run, Strings.Get("Code_ModelsPage_RunPromptHelp"));
        run.Click += async (_, _) => await FactPromptsViewModel.RunAsync(_pages.Facts, _facts, prompt.Name, _pages.State.Notifier).ConfigureAwait(true);
        var edit = new Button { Content = Strings.Get("Code_ModelsPage_Edit") };
        edit.Click += async (_, _) => await EditPromptAsync(prompt with { ExamplesJson = FactPromptConfig.PrettyExamples(prompt.ExamplesJson) }, prompt.Name).ConfigureAwait(true);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        actions.Children.Add(run);
        actions.Children.Add(edit);
        if (!prompt.Builtin || prompt.Customized)
        {
            var remove = new Button { Content = prompt.Builtin ? Strings.Get("Code_ModelsPage_Restore") : Strings.Get("Code_ModelsPage_Delete") };
            if (prompt.Builtin)
            {
                ToolTipService.SetToolTip(remove, Strings.Get("Code_ModelsPage_RestoreHelp"));
            }
            remove.Click += async (_, _) => await _prompts.RemoveAsync(prompt.Name).ConfigureAwait(true);
            actions.Children.Add(remove);
        }

        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(enabled);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        Grid.SetColumn(actions, 2);
        grid.Children.Add(actions);
        return new Border
        {
            Child = grid,
            Padding = new Thickness(10, 8, 10, 8),
            CornerRadius = new CornerRadius(6),
            Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
        };

        static Border Badge(string label, Brush brush) => new()
        {
            Padding = new Thickness(6, 1, 6, 1),
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(1),
            BorderBrush = brush,
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock { Text = label, FontSize = 10, Foreground = brush },
        };
    }

    private async void OnNewPrompt(object sender, RoutedEventArgs e) =>
        await EditPromptAsync(FactPromptItem.Blank(_prompts.Names), null).ConfigureAwait(true);

    // The Mac's FactPromptEditor, as a dialog: name, on/off, classes, sources, instructions and examples.
    // A failed save keeps the dialog open with the reason under the form.
    private async Task EditPromptAsync(FactPromptItem prompt, string? originalName)
    {
        var name = new TextBox { Header = Strings.Get("Code_ModelsPage_PromptName"), Text = prompt.Name, IsEnabled = !prompt.Builtin };
        ToolTipService.SetToolTip(name, prompt.Builtin ? Strings.Get("Code_ModelsPage_BuiltinKeepsName") : Strings.Get("Code_ModelsPage_PromptNameHelp"));
        var enabled = new CheckBox { Content = Strings.Get("Code_ModelsPage_Enabled"), IsChecked = prompt.Enabled };
        var classes = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        List<CheckBox> classBoxes = [];
        foreach (string corpusClass in FactPromptConfig.CorpusClasses)
        {
            var box = new CheckBox { Content = corpusClass, IsChecked = prompt.CorpusClasses.Contains(corpusClass), Tag = corpusClass, MinWidth = 0 };
            classBoxes.Add(box);
            classes.Children.Add(box);
        }
        classes.Children.Add(new TextBlock { Text = Strings.Get("Code_ModelsPage_NoneCheckedAll"), VerticalAlignment = VerticalAlignment.Center, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
        var sources = new TextBox { Header = Strings.Get("Code_ModelsPage_PromptSources"), Text = string.Join(", ", prompt.Sources), PlaceholderText = Strings.Get("Code_ModelsPage_PromptSourcesPlaceholder") };
        var description = new TextBox { Header = Strings.Get("Code_ModelsPage_Instructions"), Text = prompt.Description, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 90 };
        var examples = new TextBox { Header = Strings.Get("Code_ModelsPage_Examples"), Text = prompt.ExamplesJson, AcceptsReturn = true, FontFamily = new FontFamily("Consolas"), MinHeight = 140 };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Look.TintBrush(Core.Presentation.Tint.Red), Visibility = Visibility.Collapsed };
        var classRow = new StackPanel { Spacing = 4 };
        classRow.Children.Add(new TextBlock { Text = Strings.Get("Code_ModelsPage_CorpusClasses") });
        classRow.Children.Add(classes);
        var form = new StackPanel { Spacing = 10, MinWidth = 520 };
        foreach (UIElement child in new UIElement[] { name, enabled, classRow, sources, description, examples, error })
        {
            form.Children.Add(child);
        }
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = originalName is null ? Strings.Get("Code_ModelsPage_NewFactPrompt") : Strings.Get("Code_ModelsPage_EditFactPrompt"),
            Content = new ScrollViewer { Content = form, MaxHeight = 560 },
            PrimaryButtonText = Strings.Get("Code_ModelsPage_Save"),
            CloseButtonText = Strings.Get("Code_ModelsPage_Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            ContentDialogButtonClickDeferral deferral = args.GetDeferral();
            FactPromptItem edited = prompt with
            {
                Name = name.Text.Trim(),
                Enabled = enabled.IsChecked == true,
                CorpusClasses = [.. classBoxes.Where(b => b.IsChecked == true).Select(b => (string)b.Tag)],
                Sources = [.. sources.Text.Split(',').Select(s => s.Trim()).Where(s => s.Length > 0)],
                Description = description.Text,
                ExamplesJson = examples.Text,
            };
            string? failure = await _prompts.SaveAsync(edited, originalName).ConfigureAwait(true);
            if (failure is not null)
            {
                args.Cancel = true;
                error.Text = failure;
                error.Visibility = Visibility.Visible;
            }
            deferral.Complete();
        };
        await dialog.ShowAsync();
    }

    // MARK: Test an Embedding

    private void OnTestChanged(object? sender, PropertyChangedEventArgs e) => ShowTest();

    private void FillTestModels()
    {
        _showing = true;
        List<TestModelChoice> choices = [new("", Strings.Get("Code_ModelsPage_DefaultModel")), .. _model.Models.Select(m => new TestModelChoice(m.Slug, m.Slug))];
        TestModelBox.ItemsSource = choices;
        TestModelBox.DisplayMemberPath = nameof(TestModelChoice.Title);
        TestModelBox.SelectedItem = choices.FirstOrDefault(c => c.Slug == _test.Model) ?? choices[0];
        _showing = false;
    }

    private void OnTestModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_showing && TestModelBox.SelectedItem is TestModelChoice choice)
        {
            _test.Model = choice.Slug;
        }
    }

    private void OnTestDimsChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_showing)
        {
            _test.Dimensions = double.IsNaN(args.NewValue) || args.NewValue <= 0 ? null : (int)args.NewValue;
        }
    }

    private void OnTestTextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_showing)
        {
            _test.Text = TestTextBox.Text;
        }
    }

    private async void OnTestEmbed(object sender, RoutedEventArgs e) => await _test.RunAsync().ConfigureAwait(true);

    private void OnTestCopyCsv(object sender, RoutedEventArgs e) => Clipboard.Copy(_test.Result?.Csv());

    private void OnTestCopyJson(object sender, RoutedEventArgs e) => Clipboard.Copy(_test.Result?.Json());

    private void ShowTest()
    {
        TestEmbedButton.IsEnabled = _test.CanRun;
        TestProgress.IsActive = _test.IsRunning;
        TestError.Text = _test.Error ?? "";
        TestError.Visibility = Look.VisibleIf(_test.Error);
        EmbeddingInspection? result = _test.Result;
        TestResultPanel.Visibility = Look.VisibleWhen(result is not null);
        TestCopyCsvButton.IsEnabled = TestCopyJsonButton.IsEnabled = result is not null;
        if (result is null)
        {
            return;
        }
        TestCaption.Text = result.Caption;
        TestFigures.Children.Clear();
        foreach ((string title, string value) in result.Figures)
        {
            var figure = new StackPanel { Spacing = 0 };
            figure.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
            figure.Children.Add(new TextBlock { Text = value, FontFamily = new FontFamily("Consolas") });
            TestFigures.Children.Add(figure);
        }
        TestPreview.Text = result.Preview();
    }

    private sealed record TestModelChoice(string Slug, string Title);
}
