using System;
using System.Collections.Generic;
using System.Linq;

namespace BimBridge.LayeredPdf.Core.Naming;

public static class LayerNameBuilder
{
    public static string BuildForExport(bool includeSheetAndDetail, string? sheetNumber, string? sheetName, string? detailNumber, string? viewName)
    {
        var name = Normalize(viewName);
        if (name.Length == 0) name = "Unnamed View";
        if (!includeSheetAndDetail) return name;
        return string.Join(" - ", new[] { Normalize(sheetNumber), Normalize(sheetName), Normalize(detailNumber), name }
            .Where(part => part.Length > 0));
    }

    public static string Build(string? detailNumber, string? viewName)
    {
        var detail = Normalize(detailNumber);
        var name = Normalize(viewName);

        if (detail.Length == 0)
        {
            return name.Length == 0 ? "Unnamed View" : name;
        }

        return name.Length == 0 ? detail : $"{detail} - {name}";
    }

    public static string SafeFileStem(string value)
    {
        var invalid = System.IO.Path.GetInvalidFileNameChars();
        var cleaned = new string(value.Select(c => invalid.Contains(c) ? '_' : c).ToArray());
        return Normalize(cleaned);
    }

    public static IReadOnlyList<string> MakeUnique(IEnumerable<string> names)
    {
        if (names is null)
        {
            throw new ArgumentNullException(nameof(names));
        }

        var counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<string>();
        foreach (var rawName in names)
        {
            var name = Normalize(rawName);
            if (name.Length == 0)
            {
                name = "Unnamed View";
            }

            counts.TryGetValue(name, out var count);
            string candidate;
            do { count++; candidate = count == 1 ? name : $"{name} ({count})"; } while (!used.Add(candidate));
            counts[name] = count;
            result.Add(candidate);
        }

        return result;
    }

    private static string Normalize(string? value) => string.IsNullOrWhiteSpace(value)
        ? string.Empty
        : string.Join(" ", value!.Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
}
