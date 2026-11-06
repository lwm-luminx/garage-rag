namespace Garage.App.Core.Presentation;

/// <summary>A size in effective pixels (the Mac's points).</summary>
public readonly record struct WindowSize(double Width, double Height)
{
    /// <summary>This size with <paramref name="other"/> added to each side's length.</summary>
    public WindowSize Plus(WindowSize other) => new(Width + other.Width, Height + other.Height);
}

/// <summary>A rectangle in effective pixels, from its top-left corner.</summary>
public readonly record struct WindowFrame(double X, double Y, double Width, double Height)
{
    /// <summary>The horizontal centre.</summary>
    public double MidX => X + (Width / 2);

    /// <summary>The vertical centre.</summary>
    public double MidY => Y + (Height / 2);

    /// <summary>The size.</summary>
    public WindowSize Size => new(Width, Height);

    /// <summary>Every coordinate times <paramref name="factor"/>: effective to physical pixels and back.</summary>
    public WindowFrame Scaled(double factor) => new(X * factor, Y * factor, Width * factor, Height * factor);
}

/// <summary>
/// The main window's size follows what it shows (the Mac's <c>MainWindowSizing</c>). The setup
/// assistant opens at <see cref="AssistantSize"/>, also in a window of another size (Settings' Setup
/// Assistant…, the relaunch after Reset Database). When it closes the window grows to
/// <see cref="WorkingSize"/> if it is smaller, and never shrinks one the person made bigger.
/// <para>
/// Sizes are effective pixels, which XAML lays out in. The window converts them with its display's
/// scale: Windows sizes windows in physical pixels, so at 150% a size given unconverted opens at two
/// thirds of what it should, too small for the pages. Every frame stays inside the display's work area,
/// which also caps a size on a small or portrait display.
/// </para>
/// </summary>
public static class MainWindowSizing
{
    /// <summary>The smallest content size the window allows, on any page.</summary>
    public static WindowSize MinimumSize { get; } = new(760, 520);

    /// <summary>
    /// The setup assistant's content size, between the minimum and 1.5 times it: wide enough for three
    /// columns of locations on the data page, and tall enough to show each page without clipping.
    /// </summary>
    public static WindowSize AssistantSize { get; } = new(920, 650);

    /// <summary>Roomy enough for Sources, Documents and Search beside the navigation pane.</summary>
    public static WindowSize WorkingSize { get; } = new(1100, 760);

    /// <summary>The frame the window opens at: <paramref name="target"/>, centred in <paramref name="visible"/>.</summary>
    public static WindowFrame InitialFrame(WindowSize target, WindowFrame visible) =>
        Centred(Math.Min(target.Width, visible.Width), Math.Min(target.Height, visible.Height), visible, visible);

    /// <summary>
    /// The smallest frame the window may be dragged to: <paramref name="minimum"/>, or the work area
    /// where that is smaller, so the window can always fit on its display.
    /// </summary>
    public static WindowSize MinimumFrame(WindowSize minimum, WindowFrame visible) =>
        new(Math.Min(minimum.Width, visible.Width), Math.Min(minimum.Height, visible.Height));

    /// <summary>
    /// The frame to grow to from <paramref name="current"/> when the assistant closes, or null when the
    /// window is already at least <paramref name="target"/>. It keeps its centre where it can, never
    /// shrinks, and stays inside <paramref name="visible"/>.
    /// </summary>
    public static WindowFrame? FrameAfterFirstRun(WindowFrame current, WindowFrame visible, WindowSize target)
    {
        double width = Math.Min(Math.Max(current.Width, target.Width), visible.Width);
        double height = Math.Min(Math.Max(current.Height, target.Height), visible.Height);
        return width > current.Width || height > current.Height ? Centred(width, height, current, visible) : null;
    }

    /// <summary>
    /// The frame for the assistant from <paramref name="current"/>, or null when the window is already
    /// that size. It keeps its centre and stays inside <paramref name="visible"/>, which also caps the
    /// size on a small display.
    /// </summary>
    public static WindowFrame? FrameForFirstRun(WindowFrame current, WindowFrame visible, WindowSize target)
    {
        double width = Math.Min(target.Width, visible.Width);
        double height = Math.Min(target.Height, visible.Height);
        return Math.Abs(width - current.Width) >= 1 || Math.Abs(height - current.Height) >= 1
            ? Centred(width, height, current, visible)
            : null;
    }

    private static WindowFrame Centred(double width, double height, WindowFrame around, WindowFrame visible)
    {
        double x = Math.Min(Math.Max(around.MidX - (width / 2), visible.X), visible.X + visible.Width - width);
        double y = Math.Min(Math.Max(around.MidY - (height / 2), visible.Y), visible.Y + visible.Height - height);
        return new WindowFrame(x, y, width, height);
    }
}
