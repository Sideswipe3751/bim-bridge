using BimBridge.LayeredPdf.Core.Groups;

namespace BimBridge.LayeredPdf.Core.Tests;

public sealed class LayerGroupSettingsTests
{
    [Fact]
    public void MovingAndDeletingGroupsNeverLosesViewsOrDuplicatesAssignments()
    {
        var settings = new LayerGroupSettings { ProjectKey = "project-a", Enabled = true };
        var existing = settings.AddGroup("Existing"); var proposed = settings.AddGroup("Proposed");
        settings.Assign(new[] { "view-1", "view-2" }, existing.Id);
        settings.Assign(new[] { "view-2", "view-2" }, proposed.Id);
        Assert.Equal(new[] { "view-1" }, existing.ViewKeys);
        Assert.Equal(new[] { "view-2" }, proposed.ViewKeys);
        settings.DeleteGroup(proposed.Id);
        Assert.Equal("", settings.GroupNameFor("view-2"));
        Assert.Equal("Existing", settings.GroupNameFor("view-1"));
        settings.Assign(new[] { "view-1" }, null);
        Assert.Empty(existing.ViewKeys);
        settings.Validate();
    }

    [Fact]
    public void EditingCloneDoesNotChangeSavedSettingsAndUnknownViewsRemainUnassigned()
    {
        var settings = new LayerGroupSettings { ProjectKey = "project-a" };
        var group = settings.AddGroup("Electrical"); settings.Assign(new[] { "stable-viewport-id" }, group.Id);
        var draft = settings.Clone(); draft.RenameGroup(group.Id, "Power"); draft.Assign(new[] { "stable-viewport-id" }, null);
        Assert.Equal("Electrical", settings.GroupNameFor("stable-viewport-id"));
        Assert.Equal("", settings.GroupNameFor("new-viewport"));
        Assert.Throws<ArgumentException>(() => settings.AddGroup(" electrical "));
        Assert.Throws<ArgumentException>(() => settings.AddGroup(" "));
    }

    [Fact]
    public void SavedPresetRetainsOrderAndAssignmentsOutsideCurrentSheetSelection()
    {
        var path = Path.Combine(Path.GetTempPath(), "LayerGroups-" + Guid.NewGuid().ToString("N") + ".xml");
        try
        {
            var settings = new LayerGroupSettings { ProjectKey = "project-a", Enabled = true };
            var first = settings.AddGroup("Power & Lighting"); var second = settings.AddGroup("Architecture");
            settings.Assign(new[] { "sheet-a-view", "unchecked-sheet-b-view" }, first.Id);
            LayerGroupSerializer.Write(path, settings);
            var loaded = LayerGroupSerializer.Read(path);
            Assert.True(loaded.Enabled); Assert.Equal("project-a", loaded.ProjectKey);
            Assert.Equal(new[] { first.Name, second.Name }, loaded.Groups.Select(g => g.Name));
            Assert.Equal("Power & Lighting", loaded.GroupNameFor("unchecked-sheet-b-view"));
            loaded.RenameGroup(first.Id, "Updated"); LayerGroupSerializer.Write(path, loaded);
            Assert.Equal("Updated", LayerGroupSerializer.Read(path).GroupNameFor("sheet-a-view"));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void InvalidPresetWithDuplicateAssignmentsCannotBeSaved()
    {
        var settings = new LayerGroupSettings { ProjectKey = "project-a" };
        settings.AddGroup("One").ViewKeys.Add("view-a"); settings.AddGroup("Two").ViewKeys.Add("view-a");
        Assert.Throws<ArgumentException>(() => settings.Validate());
    }
}
