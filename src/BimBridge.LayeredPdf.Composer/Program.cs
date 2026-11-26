using BimBridge.LayeredPdf.Core.Jobs;

namespace BimBridge.LayeredPdf.Composer;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length == 2 && string.Equals(args[0], "--sample", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                SamplePdfGenerator.Create(args[1]);
                Console.WriteLine(Path.GetFullPath(args[1]));
                return 0;
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine(exception);
                return 1;
            }
        }

        if (args.Length != 1)
        {
            Console.Error.WriteLine("Usage: BimBridge.LayeredPdf.Composer <job.xml> | --sample <output.pdf>");
            return 2;
        }

        try
        {
            var job = LayeredPdfJobSerializer.Read(args[0]);
            LayeredPdfComposer.Compose(job);
            Console.WriteLine(job.OutputPath);
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
    }
}
