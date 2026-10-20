namespace ImageCompressor.App;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        var minimized = args.Any(x => x.Equals("min", StringComparison.OrdinalIgnoreCase));
        var paths = args.Where(x => !x.Equals("min", StringComparison.OrdinalIgnoreCase)).ToArray();
        Application.Run(new MainForm(paths, minimized));
    }
}
