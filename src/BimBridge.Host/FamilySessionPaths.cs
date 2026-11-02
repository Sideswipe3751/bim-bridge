using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace BimBridge.Host;

// File-system policy only; no Autodesk dependencies. No caller-supplied output path.
public static class FamilySessionPaths
{
    public static void ValidateName(string value)
    {
        if (value == null || !Regex.IsMatch(value, "\\A[A-Za-z0-9][A-Za-z0-9_-]{0,79}\\z", RegexOptions.CultureInvariant))
            throw new ArgumentException("family_name_invalid");
        var stem = value.Split('.')[0].ToUpperInvariant();
        if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" ||
            (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && stem[3] >= '0' && stem[3] <= '9'))
            throw new ArgumentException("family_name_reserved");
    }

    public static string Resolve(string workspace, string jobId, string documentName)
    {
        ValidateName(jobId); ValidateName(documentName);
        var root = Path.GetFullPath(workspace);
        var path = Path.GetFullPath(Path.Combine(root, jobId, documentName + ".rfa"));
        if (!path.StartsWith(root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("family_path_outside_workspace");
        AssertNoLinks(path);
        return path;
    }

    // Check every existing ancestor, including the workspace anchor. Cloud placeholders
    // are not directory links; only mount-point and symlink tags redirect resolution.
    public static void AssertNoLinks(string path)
    {
        var current = Path.GetFullPath(path);
        while (!string.IsNullOrEmpty(current))
        {
            if (File.Exists(current) || Directory.Exists(current))
            {
                var attributes = File.GetAttributes(current);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    WIN32_FIND_DATA data;
                    var handle = FindFirstFile(current, out data);
                    if (handle == new IntPtr(-1)) throw new IOException("family_path_link_check_failed");
                    try
                    {
                        if (data.Reserved0 == 0xA0000003 || data.Reserved0 == 0xA000000C)
                            throw new IOException("family_path_link_refused");
                        if (data.Reserved0 == 0) throw new IOException("family_path_link_tag_unknown");
                    }
                    finally { FindClose(handle); }
                }
            }
            var parent = Path.GetDirectoryName(current);
            if (string.Equals(parent, current, StringComparison.OrdinalIgnoreCase)) break;
            current = parent;
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WIN32_FIND_DATA
    {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, AccessTime, WriteTime;
        public uint SizeHigh, SizeLow, Reserved0, Reserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string FileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string AlternateFileName;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindFirstFile(string name, out WIN32_FIND_DATA data);
    [DllImport("kernel32.dll")] private static extern bool FindClose(IntPtr handle);
}
