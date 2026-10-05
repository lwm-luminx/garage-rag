using Garage.App.Core.Presentation;

namespace Garage.App.Core.Tests;

// Ported from macapp/Tests/GarageAppUnitTests/MainWindowSizingTests.swift (frames from the top left
// here, which the centring does not mind), plus the window's first frame and minimum, which Windows
// leaves to the app.
public sealed class MainWindowSizingTests
{
    private static readonly WindowFrame Screen = new(0, 0, 1728, 1080);
    private static readonly WindowSize Target = new(1100, 760);
    private static readonly WindowSize Assistant = new(920, 682);

    // ---- Growing when the assistant closes

    [Fact]
    public void Grows_to_the_working_size_around_the_same_centre()
    {
        var current = new WindowFrame(400, 300, 760, 520);

        WindowFrame frame = MainWindowSizing.FrameAfterFirstRun(current, Screen, Target)!.Value;

        Assert.Equal(Target, frame.Size);
        Assert.Equal(current.MidX, frame.MidX, 0.5);
        Assert.Equal(current.MidY, frame.MidY, 0.5);
    }

    [Fact]
    public void Never_shrinks_a_window_the_user_made_bigger() =>
        Assert.Null(MainWindowSizing.FrameAfterFirstRun(new WindowFrame(100, 100, 1400, 900), Screen, Target));

    [Fact]
    public void Grows_only_the_short_side()
    {
        WindowFrame frame = MainWindowSizing.FrameAfterFirstRun(new WindowFrame(100, 100, 1300, 520), Screen, Target)!.Value;

        Assert.Equal(1300, frame.Width);
        Assert.Equal(760, frame.Height);
    }

    [Fact]
    public void Stays_on_screen_near_an_edge()
    {
        WindowFrame frame = MainWindowSizing.FrameAfterFirstRun(new WindowFrame(1600, 0, 760, 520), Screen, Target)!.Value;

        Assert.True(frame.X + frame.Width <= Screen.X + Screen.Width);
        Assert.True(frame.Y >= Screen.Y);
        Assert.Equal(Target, frame.Size);
    }

    [Fact]
    public void Fits_a_small_screen()
    {
        var small = new WindowFrame(0, 25, 1024, 700);

        WindowFrame frame = MainWindowSizing.FrameAfterFirstRun(new WindowFrame(100, 100, 760, 520), small, Target)!.Value;

        Assert.Equal(new WindowSize(1024, 700), frame.Size);
        Assert.Equal((small.X, small.Y), (frame.X, frame.Y));
    }

    // ---- Sizing for the assistant

    [Fact]
    public void Shrinks_to_the_assistant_size_around_the_same_centre()
    {
        var current = new WindowFrame(200, 100, 1400, 900);

        WindowFrame frame = MainWindowSizing.FrameForFirstRun(current, Screen, Assistant)!.Value;

        Assert.Equal(Assistant, frame.Size);
        Assert.Equal(current.MidX, frame.MidX, 0.5);
        Assert.Equal(current.MidY, frame.MidY, 0.5);
    }

    [Fact]
    public void Grows_a_smaller_window_to_the_assistant_size()
    {
        WindowFrame frame = MainWindowSizing.FrameForFirstRun(new WindowFrame(400, 300, 760, 552), Screen, Assistant)!.Value;

        Assert.Equal(Assistant, frame.Size);
        Assert.True(frame.Y + frame.Height <= Screen.Y + Screen.Height);
    }

    [Fact]
    public void Does_nothing_when_already_at_the_assistant_size() =>
        Assert.Null(MainWindowSizing.FrameForFirstRun(new WindowFrame(300, 100, Assistant.Width, Assistant.Height), Screen, Assistant));

    [Fact]
    public void The_assistant_fits_a_small_screen()
    {
        var small = new WindowFrame(0, 25, 1024, 640);

        WindowFrame frame = MainWindowSizing.FrameForFirstRun(new WindowFrame(100, 100, 760, 552), small, Assistant)!.Value;

        Assert.Equal(new WindowSize(920, 640), frame.Size);
        Assert.True(frame.Y >= small.Y);
    }

    [Fact]
    public void The_assistant_sits_between_the_minimum_and_half_again()
    {
        WindowSize minimum = MainWindowSizing.MinimumSize;
        WindowSize size = MainWindowSizing.AssistantSize;
        Assert.True(size.Width > minimum.Width && size.Height > minimum.Height);
        Assert.True(size.Width < minimum.Width * 1.5 && size.Height < minimum.Height * 1.5);
    }

    // ---- The first frame and the minimum (Windows)

    [Fact]
    public void Opens_centred_in_the_work_area()
    {
        var work = new WindowFrame(0, 0, 2560, 1392);

        WindowFrame frame = MainWindowSizing.InitialFrame(MainWindowSizing.WorkingSize, work);

        Assert.Equal(MainWindowSizing.WorkingSize, frame.Size);
        Assert.Equal(work.MidX, frame.MidX, 0.5);
        Assert.Equal(work.MidY, frame.MidY, 0.5);
    }

    [Fact]
    public void Opens_no_bigger_than_a_portrait_display_at_150_percent()
    {
        // 1080 x 1872 physical pixels of work area, at 150%.
        WindowFrame work = new WindowFrame(-1080, 0, 1080, 1872).Scaled(1 / 1.5);

        WindowFrame frame = MainWindowSizing.InitialFrame(MainWindowSizing.WorkingSize, work);

        Assert.Equal(work.Width, frame.Width);
        Assert.Equal(MainWindowSizing.WorkingSize.Height, frame.Height);
        Assert.Equal(work.X, frame.X);
    }

    [Fact]
    public void The_minimum_never_exceeds_the_work_area()
    {
        var narrow = new WindowFrame(0, 0, 720, 1248);

        Assert.Equal(new WindowSize(720, 520), MainWindowSizing.MinimumFrame(MainWindowSizing.MinimumSize, narrow));
        Assert.Equal(MainWindowSizing.MinimumSize, MainWindowSizing.MinimumFrame(MainWindowSizing.MinimumSize, Screen));
    }

    [Fact]
    public void Scaling_converts_effective_to_physical_pixels()
    {
        WindowFrame physical = new WindowFrame(10, 20, 1100, 760).Scaled(1.5);

        Assert.Equal(new WindowFrame(15, 30, 1650, 1140), physical);
    }
}
