using Garage.App.Core.Navigation;

namespace Garage.App.Core.Tests;

public sealed class NavigationTests
{
    // The Mac app's order (macapp/Sources/GarageApp/Views/ContentView.swift: AppSection, SidebarGroup).
    // A change there is a change here; the two apps list their pages the same way.
    [Fact]
    public void Pages_follow_the_mac_sidebar()
    {
        Assert.Equal(
            [
                AppSection.Status,
                AppSection.Sources, AppSection.Models, AppSection.Mcp,
                AppSection.Documents, AppSection.Facts, AppSection.Search,
                AppSection.Database, AppSection.Logs,
            ],
            AppSections.NavigationOrder);
    }

    [Fact]
    public void Groups_hold_the_mac_pages()
    {
        Assert.Equal([SidebarGroup.Configuration, SidebarGroup.Data, SidebarGroup.Advanced], AppSections.Groups);
        Assert.Equal([AppSection.Sources, AppSection.Models, AppSection.Mcp], AppSections.SectionsIn(SidebarGroup.Configuration));
        Assert.Equal([AppSection.Documents, AppSection.Facts, AppSection.Search], AppSections.SectionsIn(SidebarGroup.Data));
        Assert.Equal([AppSection.Database, AppSection.Logs], AppSections.SectionsIn(SidebarGroup.Advanced));
    }

    [Fact]
    public void Every_page_appears_exactly_once()
    {
        Assert.Equal(Enum.GetValues<AppSection>().Order(), AppSections.NavigationOrder.Order());
    }

    [Theory]
    [InlineData(AppSection.Mcp, "MCP Server")]
    [InlineData(AppSection.Status, "Status")]
    [InlineData(AppSection.Logs, "Logs")]
    public void Titles_are_spelled_as_on_the_mac(AppSection section, string title) =>
        Assert.Equal(title, section.Title());

    [Fact]
    public void Ctrl_number_follows_navigation_order()
    {
        Assert.Equal(AppSection.Status, AppSections.ForShortcut(1));
        Assert.Equal(AppSection.Mcp, AppSections.ForShortcut(4));
        Assert.Equal(AppSection.Logs, AppSections.ForShortcut(9));
        Assert.Null(AppSections.ForShortcut(0));
        Assert.Null(AppSections.ForShortcut(10));
    }
}
