using System.ComponentModel;
using Garage.App.Core.Database;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Garage.App.Pages;

/// <summary>The Database page: Garage's own Postgres, Reset Database, and the Contents box.</summary>
public sealed partial class DatabasePage : Page
{
    private DatabaseViewModel _model = null!;

    /// <summary>Creates the page.</summary>
    public DatabasePage() => InitializeComponent();

    /// <inheritdoc/>
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        _model = ((PageModels)e.Parameter).Database;
        _model.PropertyChanged += OnModelChanged;
        Show();
        await _model.RefreshAsync().ConfigureAwait(true);
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e) => _model.PropertyChanged -= OnModelChanged;

    private async void OnRefresh(object sender, RoutedEventArgs e) => await _model.RefreshAsync().ConfigureAwait(true);

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Show();

    private void Show()
    {
        ErrorBar.IsOpen = _model.ErrorMessage is not null;
        ErrorBar.Message = _model.ErrorMessage ?? "";
        Figures.ItemsSource = _model.Contents?.Figures;
        EmptyNote.Visibility = _model.Contents?.IsEmpty == true ? Visibility.Visible : Visibility.Collapsed;

        ServerCard.Visibility = _model.HasOwnServer ? Visibility.Visible : Visibility.Collapsed;
        ServerBar.IsOpen = !_model.HasOwnServer;
        if (_model.Headline is { } headline)
        {
            ServerCircle.Background = Look.TintBrush(headline.IsActive ? headline.Tint : Core.Presentation.Tint.Secondary);
            ServerGlyph.Glyph = Look.StatusGlyph(headline.Symbol);
            ServerTitle.Text = _model.IsFinishingReset ? "Setting up the new database…" : headline.Title;
            ServerDetail.Text = headline.Detail;
            ServerDetail.Foreground = headline.DetailIsError
                ? Look.TintBrush(Core.Presentation.Tint.Red)
                : (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
            ServerWhere.Text = _model.Postgres is { } postgres ? $"{postgres.Version ?? "PostgreSQL"} · {postgres.Layout.ClusterDirectory}" : "";
        }
        ResetButton.IsEnabled = !_model.IsResetting && !_model.IsFinishingReset && !_model.IsBackingUp;

        OwnServerBoxes.Visibility = _model.HasOwnServer ? Visibility.Visible : Visibility.Collapsed;
        if (_model.Schema is { } schema)
        {
            SchemaGlyph.Glyph = Look.StatusGlyph(schema.Symbol);
            SchemaGlyph.Foreground = Look.TintBrush(schema.IsActive ? schema.Tint : Core.Presentation.Tint.Secondary);
            SchemaTitle.Text = schema.Title;
            SchemaDetail.Text = schema.Detail;
            SchemaButton.Visibility = schema.Action == SchemaAction.Hidden ? Visibility.Collapsed : Visibility.Visible;
            SchemaButton.Content = schema.Action == SchemaAction.Apply ? "Apply Updates" : "Check Again";
            SchemaButton.Style = schema.Action == SchemaAction.Apply ? (Style)Application.Current.Resources["AccentButtonStyle"] : null;
        }
        Extensions.Text = _model.Details is { Extensions.Count: > 0 } details ? "Extensions: " + string.Join(", ", details.Extensions) : "";
        bool up = _model.Postgres?.Status.IsUp == true;
        BackupButton.IsEnabled = RestoreButton.IsEnabled = up && !_model.IsBackingUp && !_model.IsResetting;
        ActionBar.IsOpen = _model.ActionResult is not null;
        if (_model.ActionResult is { } action)
        {
            ActionBar.Severity = action.Succeeded ? InfoBarSeverity.Success : InfoBarSeverity.Error;
            ActionBar.Message = action.Message;
        }
        ResetBar.IsOpen = _model.ResetOutcome is not null;
        if (_model.ResetOutcome is { } outcome)
        {
            ResetBar.Severity = outcome.Succeeded ? InfoBarSeverity.Success : InfoBarSeverity.Error;
            ResetBar.Title = outcome.Succeeded ? "Database reset" : "Database reset did not finish";
            ResetBar.Message = outcome.Message;
        }
    }

    private async void OnApplySchema(object sender, RoutedEventArgs e) => await _model.ApplySchemaAsync().ConfigureAwait(true);

    private async void OnBackup(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FileSavePicker
        {
            SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.DocumentsLibrary,
            SuggestedFileName = $"Garage {DateTime.Now:yyyy-MM-dd HHmm}",
        };
        picker.FileTypeChoices.Add("Garage backup", [".garagedump"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.Current!.MainWindowHandle);
        if (await picker.PickSaveFileAsync() is { } file)
        {
            await _model.BackupAsync(file.Path).ConfigureAwait(true);
        }
    }

    private async void OnRestore(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker { SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".garagedump");
        picker.FileTypeFilter.Add(".dump");
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.Current!.MainWindowHandle);
        if (await picker.PickSingleFileAsync() is not { } file)
        {
            return;
        }
        var confirm = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Strings.Get("Code_DatabasePage_ReplaceTheDatabaseWithThisBackup"),
            Content = new TextBlock
            {
                Text = $"Everything Garage has indexed now is replaced by the contents of {file.Name}. Your original files are not touched.",
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = Strings.Get("Code_DatabasePage_ReplaceDatabase"),
            PrimaryButtonStyle = (Style)Application.Current.Resources["DangerButtonStyle"],
            CloseButtonText = Strings.Get("Code_DatabasePage_Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await confirm.ShowAsync() == ContentDialogResult.Primary)
        {
            await _model.RestoreAsync(file.Path).ConfigureAwait(true);
        }
    }

    // The Mac's DatabaseResetSheet, as a dialog: what goes, what stays, then Reset and Relaunch.
    private async void OnReset(object sender, RoutedEventArgs e)
    {
        if (_model.Postgres is not { } postgres)
        {
            return;
        }
        var content = new StackPanel { Spacing = 10, MaxWidth = 480 };
        content.Children.Add(new TextBlock
        {
            Text = Strings.Get("Code_DatabasePage_GarageDeletesItsDatabaseAndStarts"),
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(new TextBlock
        {
            Text = "Deleted: every document, chunk, embedding and fact, and the registered sources and models.\n"
                + "Kept: your files, garage.json, the models Ollama or LM Studio hold, and the app's settings.",
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(new TextBlock
        {
            Text = $"Garage stops its services, deletes {postgres.Layout.ClusterDirectory}, and relaunches. The new database gets the sources garage.json declares; register models again on the Models page.",
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            IsTextSelectionEnabled = true,
        });
        var confirm = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Strings.Get("Code_DatabasePage_ResetTheGarageDatabase"),
            Content = content,
            PrimaryButtonText = Strings.Get("Code_DatabasePage_ResetAndRelaunch"),
            PrimaryButtonStyle = (Style)Application.Current.Resources["DangerButtonStyle"],
            CloseButtonText = Strings.Get("Code_DatabasePage_Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await confirm.ShowAsync() == ContentDialogResult.Primary && App.Current is { } app)
        {
            await app.ResetDatabaseAndRelaunchAsync().ConfigureAwait(true);
        }
    }
}
