using Garage.App.Core.Diagnostics;
using Garage.App.Platform;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace Garage.App.Dialogs;

/// <summary>
/// Report a Bug (the Mac's <c>BugReportView</c>): a form, the attachments the person agrees to, and a
/// preview of exactly what Copy, Save and Open Issue hand over. Garage sends nothing by itself.
/// </summary>
internal static class BugReportDialog
{
    public static async Task ShowAsync(XamlRoot root, BugReportViewModel model)
    {
        var form = new StackPanel { Spacing = 10, MinWidth = 560 };
        TextBox Field(string header, string automationId, bool multiline, Action<string> set)
        {
            var box = new TextBox
            {
                Header = header,
                AcceptsReturn = multiline,
                TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
                MinHeight = multiline ? 72 : 0,
            };
            AutomationProperties.SetAutomationId(box, automationId);
            box.TextChanged += (_, _) => set(box.Text);
            form.Children.Add(box);
            return box;
        }
        Field("Summary", "bugReport.title", false, v => model.Title = v);
        Field("What happened?", "bugReport.whatHappened", true, v => model.WhatHappened = v);
        Field("Steps to reproduce (optional)", "bugReport.steps", true, v => model.StepsToReproduce = v);
        Field("What did you expect? (optional)", "bugReport.expected", true, v => model.ExpectedBehavior = v);

        var diagnostics = new CheckBox { Content = Strings.Get("Code_BugReportDialog_IncludeDiagnosticsVersionsCountsAndService"), IsChecked = model.IncludeDiagnostics };
        AutomationProperties.SetAutomationId(diagnostics, "bugReport.includeDiagnostics");
        diagnostics.Click += (_, _) => model.IncludeDiagnostics = diagnostics.IsChecked == true;
        form.Children.Add(diagnostics);

        var logs = new CheckBox { Content = Strings.Get("Code_BugReportDialog_IncludeRecentLogLinesTheyCan"), IsChecked = model.IncludeLogs };
        AutomationProperties.SetAutomationId(logs, "bugReport.includeLogs");
        var logSource = new ComboBox { ItemsSource = model.LogSources, SelectedItem = model.LogSource, MinWidth = 160, IsEnabled = model.IncludeLogs };
        AutomationProperties.SetName(logSource, "Which log");
        logs.Click += (_, _) =>
        {
            model.IncludeLogs = logs.IsChecked == true;
            logSource.IsEnabled = model.IncludeLogs;
        };
        logSource.SelectionChanged += (_, _) => model.LogSource = logSource.SelectedItem as string ?? model.LogSource;
        var logRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        logRow.Children.Add(logs);
        logRow.Children.Add(logSource);
        form.Children.Add(logRow);

        var preview = new TextBlock { FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"), FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        AutomationProperties.SetAutomationId(preview, "bugReport.preview");
        form.Children.Add(new Expander
        {
            Header = Strings.Get("Code_BugReportDialog_PreviewWhatIsCopiedSavedOr"),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = new ScrollViewer { Content = preview, MaxHeight = 260 },
        });
        form.Children.Add(new TextBlock
        {
            Text = Strings.Get("Code_BugReportDialog_YourHomeFolderUserNameE"),
            TextWrapping = TextWrapping.Wrap,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        });

        var copy = new Button { Content = Strings.Get("Code_BugReportDialog_CopyReport") };
        AutomationProperties.SetAutomationId(copy, "bugReport.copy");
        var save = new Button { Content = Strings.Get("Code_BugReportDialog_Save") };
        AutomationProperties.SetAutomationId(save, "bugReport.save");
        var done = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] };
        AutomationProperties.SetLiveSetting(done, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        copy.Click += (_, _) =>
        {
            Clipboard.Copy(model.Document);
            done.Text = Strings.Get("Code_BugReportDialog_Copied");
        };
        save.Click += async (_, _) =>
        {
            if (await Pickers.SaveFileAsync(BugReportViewModel.SuggestedFileName(DateTimeOffset.Now), "Markdown", ".md").ConfigureAwait(true) is { } path)
            {
                await File.WriteAllTextAsync(path, model.Document).ConfigureAwait(true);
                done.Text = $"Saved to {path}.";
            }
        };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(copy);
        actions.Children.Add(save);
        actions.Children.Add(done);
        form.Children.Add(actions);

        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = Strings.Get("Code_BugReportDialog_ReportABug"),
            Content = new ScrollViewer { Content = form },
            PrimaryButtonText = Strings.Get("Code_BugReportDialog_OpenIssueOnGitHub"),
            CloseButtonText = Strings.Get("Code_BugReportDialog_Close"),
            DefaultButton = ContentDialogButton.Primary,
        };
        void Refresh()
        {
            preview.Text = model.Document;
            bool ready = model.IsSubmittable;
            dialog.IsPrimaryButtonEnabled = ready;
            copy.IsEnabled = ready;
            save.IsEnabled = ready;
        }
        model.PropertyChanged += (_, _) => Refresh();
        Refresh();
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            // The person's own browser, with the report filled in; they post it, or not.
            await Launcher.LaunchUriAsync(model.IssueUrl);
        }
    }
}
