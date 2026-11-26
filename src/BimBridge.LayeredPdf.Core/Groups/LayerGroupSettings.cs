using System;
using System.Collections.Generic;
using System.Linq;
using System.Xml.Serialization;

namespace BimBridge.LayeredPdf.Core.Groups;

public sealed class LayerGroupSettings
{
    public bool Enabled { get; set; }
    public string ProjectKey { get; set; } = string.Empty;
    [XmlArrayItem("Group")]
    public List<LayerGroup> Groups { get; set; } = new();

    public LayerGroupSettings Clone() => new()
    {
        Enabled = Enabled, ProjectKey = ProjectKey,
        Groups = Groups.Select(g => new LayerGroup { Id = g.Id, Name = g.Name, ViewKeys = g.ViewKeys.ToList() }).ToList()
    };

    public string GroupNameFor(string viewKey) => Groups.FirstOrDefault(g => g.ViewKeys.Contains(viewKey))?.Name ?? string.Empty;

    public LayerGroup AddGroup(string name)
    {
        name = CheckName(name);
        var group = new LayerGroup { Id = Guid.NewGuid().ToString("N"), Name = name };
        Groups.Add(group);
        return group;
    }

    public void RenameGroup(string id, string name) => Groups.Single(g => g.Id == id).Name = CheckName(name, id);
    public void DeleteGroup(string id) => Groups.RemoveAll(g => g.Id == id);

    public void Assign(IEnumerable<string> viewKeys, string? groupId)
    {
        var target = groupId == null ? null : Groups.Single(g => g.Id == groupId);
        var keys = new HashSet<string>(viewKeys, StringComparer.Ordinal);
        if (keys.Any(string.IsNullOrWhiteSpace)) throw new ArgumentException("A view identifier is required.");
        foreach (var group in Groups) group.ViewKeys.RemoveAll(keys.Contains);
        if (target != null) target.ViewKeys.AddRange(keys);
    }

    private string CheckName(string name, string? exceptId = null)
    {
        name = (name ?? string.Empty).Trim();
        if (name.Length == 0 || name.Length > 120) throw new ArgumentException("Enter a group name between 1 and 120 characters.");
        if (Groups.Any(g => g.Id != exceptId && string.Equals(g.Name, name, StringComparison.OrdinalIgnoreCase)))
            throw new ArgumentException("A group with that name already exists.");
        return name;
    }

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(ProjectKey)) throw new ArgumentException("The preset requires a project identifier.");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var keys = new HashSet<string>(StringComparer.Ordinal);
        foreach (var group in Groups)
        {
            if (string.IsNullOrWhiteSpace(group.Id) || !ids.Add(group.Id)) throw new ArgumentException("Group identifiers must be unique.");
            if (string.IsNullOrWhiteSpace(group.Name) || group.Name != group.Name.Trim() || group.Name.Length > 120 || !names.Add(group.Name))
                throw new ArgumentException("Group names must be non-empty and unique.");
            foreach (var key in group.ViewKeys)
                if (string.IsNullOrWhiteSpace(key) || !keys.Add(key)) throw new ArgumentException("Each view can belong to only one group.");
        }
    }
}

public sealed class LayerGroup
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    [XmlArrayItem("View")]
    public List<string> ViewKeys { get; set; } = new();
}

public sealed class LayerViewOption
{
    public string Key { get; set; } = string.Empty;
    public long SheetId { get; set; }
    public string DisplayName { get; set; } = string.Empty;
    public override string ToString() => DisplayName;
}
