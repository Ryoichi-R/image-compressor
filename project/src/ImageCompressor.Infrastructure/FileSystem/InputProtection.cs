using System.Runtime.InteropServices;
using ImageCompressor.Domain;
using Microsoft.Win32.SafeHandles;

namespace ImageCompressor.Infrastructure;

public sealed class InputProtection
{
    private readonly HashSet<string> paths;
    private readonly HashSet<FileIdentity> identities = [];
    private readonly bool allIdentitiesKnown;

    public InputProtection(IEnumerable<SourceItem> sources)
    {
        ArgumentNullException.ThrowIfNull(sources);
        paths = sources.Select(source => Path.GetFullPath(source.FullPath))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        allIdentitiesKnown = true;
        foreach (var path in paths)
        {
            if (TryGetIdentity(path) is { } identity)
            {
                identities.Add(identity);
            }
            else
            {
                allIdentitiesKnown = false;
            }
        }
    }

    public bool BlocksReplacement(string path) =>
        paths.Contains(Path.GetFullPath(path)) ||
        (File.Exists(path) && (!allIdentitiesKnown || TryGetIdentity(path) is not { } identity ||
            identities.Contains(identity)));

    private static FileIdentity? TryGetIdentity(string path)
    {
        try
        {
            using var handle = File.OpenHandle(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            if (GetFileInformationByHandle(handle, out var information))
            {
                return new(information.VolumeSerialNumber, information.FileIndexHigh, information.FileIndexLow);
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // An unidentifiable input or destination cannot be cleared for replacement.
        }

        return null;
    }

    [DllImport("kernel32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation information);

    private readonly record struct FileIdentity(uint Volume, uint High, uint Low);

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }
}
