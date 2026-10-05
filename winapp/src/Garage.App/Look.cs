using Garage.App.Core.Mcp;
using Garage.App.Core.Presentation;
using Garage.App.Core.Sources;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Garage.App;

/// <summary>
/// Core's presentation values in Windows terms: Segoe Fluent Icons glyphs for the Mac's SF Symbols,
/// brushes for its tints. Static so x:Bind can call them from item templates.
/// </summary>
public static class Look
{
    /// <summary>A status row's glyph.</summary>
    public static string StatusGlyph(StatusSymbol symbol) => symbol switch
    {
        StatusSymbol.Checkmark => "",
        StatusSymbol.Warning => "",
        StatusSymbol.Cross => "",
        StatusSymbol.Database => "",
        StatusSymbol.Resetting => "",
        StatusSymbol.Applying => "",
        StatusSymbol.Server => "",
        StatusSymbol.Terminal => "",
        StatusSymbol.Working => "",
        StatusSymbol.Download => "",
        StatusSymbol.Quote => "",
        StatusSymbol.Search => "",
        StatusSymbol.Clock => "",
        StatusSymbol.Paused => "",
        StatusSymbol.Tray => "",
        StatusSymbol.Pending => "",
        _ => "",
    };

    /// <summary>A source row's glyph.</summary>
    public static string SourceGlyph(SourceSymbol symbol) => symbol switch
    {
        SourceSymbol.Documents => "",
        SourceSymbol.Desktop => "",
        SourceSymbol.Downloads => "",
        SourceSymbol.Cloud => "",
        SourceSymbol.Code => "",
        SourceSymbol.Database => "",
        SourceSymbol.Message => "",
        SourceSymbol.Mail => "",
        SourceSymbol.Feed => "",
        _ => "",
    };

    /// <summary>An assistant row's glyph.</summary>
    public static string ClientGlyph(McpClientSymbol symbol) => symbol switch
    {
        McpClientSymbol.Chat => "",
        McpClientSymbol.Terminal => "",
        McpClientSymbol.Chip => "",
        McpClientSymbol.Editor => "",
        _ => "",
    };

    /// <summary>
    /// A tint as a brush that reads in light and dark themes: the design system's status and corpus
    /// colours (Theme/GarageTheme.xaml). Orange and yellow are both its warning, as every status is a word
    /// plus a colour. In high contrast every tint is the highlight colour, since the person's own colours
    /// replace the app's; the row's words carry its state.
    /// </summary>
    public static Brush TintBrush(Tint tint) => HighContrast
        ? Theme("SystemColorHighlightColorBrush", Colors.Yellow)
        : tint switch
        {
            Tint.Green => Theme("GarageSuccessBrush", Colors.SeaGreen),
            Tint.Orange or Tint.Yellow => Theme("GarageWarningBrush", Colors.DarkGoldenrod),
            Tint.Red => Theme("GarageDangerBrush", Colors.Firebrick),
            Tint.Blue => Theme("GarageCorpusDocumentBrush", Colors.RoyalBlue),
            Tint.Purple => Theme("GarageCorpusCodeBrush", Colors.SlateBlue),
            _ => Theme("GarageInkFaintBrush", Colors.Gray),
        };

    /// <summary>A source status tone as a brush.</summary>
    public static Brush ToneBrush(SourceTone tone) => tone switch
    {
        SourceTone.Active => TintBrush(Tint.Blue),
        SourceTone.Good => TintBrush(Tint.Green),
        SourceTone.Warning => TintBrush(Tint.Orange),
        SourceTone.Bad => TintBrush(Tint.Red),
        _ => Theme("TextFillColorSecondaryBrush", Colors.Gray),
    };

    /// <summary>A 0…1 fraction as a progress bar's 0…100, 0 when absent.</summary>
    public static double Percent(double? fraction) => (fraction ?? 0) * 100;

    /// <summary>Visible when the text has something to show.</summary>
    public static Visibility VisibleIf(string? text) => string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>Visible when true.</summary>
    public static Visibility VisibleWhen(bool value) => value ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Collapsed when <paramref name="value"/> is true.</summary>
    public static Visibility HiddenWhen(bool value) => value ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>The opposite of <paramref name="value"/>, for <c>IsEnabled</c> bindings.</summary>
    public static bool Not(bool value) => !value;

    private static readonly Windows.UI.ViewManagement.AccessibilitySettings Accessibility = new();

    private static bool HighContrast => Accessibility.HighContrast;

    private static Brush Theme(string key, Color fallback) =>
        Application.Current.Resources.TryGetValue(key, out object? value) && value is Brush brush ? brush : new SolidColorBrush(fallback);
}
