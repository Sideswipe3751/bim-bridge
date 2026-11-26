using PdfSharp.Pdf.Content;
using PdfSharp.Pdf.Content.Objects;
using PdfSharp.Pdf.IO;

namespace BimBridge.LayeredPdf.Composer;

internal static class RevitElementContentStripper
{
    public static string CreateCopyWithoutElements(
        string sourcePath,
        IReadOnlyCollection<long> elementIds)
    {
        if (elementIds.Count == 0)
        {
            return sourcePath;
        }

        var elementTags = elementIds
            .Select(id => $"/Element{id}")
            .ToHashSet(StringComparer.Ordinal);
        var outputPath = sourcePath + ".stripped.pdf";
        var removedBlocks = 0;
        using (var document = PdfReader.Open(sourcePath, PdfDocumentOpenMode.Modify))
        {
            foreach (var page in document.Pages)
            {
                var content = ContentReader.ReadContent(page);
                var filtered = new CSequence();
                var skipDepth = 0;
                foreach (var item in content)
                {
                    if (item is COperator operation)
                    {
                        if (skipDepth == 0 && IsTargetElementStart(operation, elementTags))
                        {
                            skipDepth = 1;
                            removedBlocks++;
                            continue;
                        }

                        if (skipDepth > 0)
                        {
                            if (operation.Name is "BMC" or "BDC")
                            {
                                skipDepth++;
                                continue;
                            }
                            else if (operation.Name == "EMC")
                            {
                                skipDepth--;
                                continue;
                            }
                            // Revit shares graphics/text state across element tags. In particular,
                            // a title block can restore a q opened by the preceding viewport.
                            // Suppress its painting, but retain state and path consumption.
                            SuppressPainting(filtered, operation);
                            continue;
                        }
                    }

                    filtered.Add(item);
                }

                if (skipDepth != 0)
                {
                    throw new InvalidDataException(
                        $"The Revit marked-content structure is unbalanced in source PDF '{sourcePath}'.");
                }

                page.Contents.ReplaceContent(filtered);
            }

            if (removedBlocks == 0)
            {
                throw new InvalidDataException(
                    $"The title block could not be identified in Revit source PDF '{sourcePath}'. " +
                    "The original source was retained for diagnostics.");
            }

            document.Save(outputPath);
        }

        return outputPath;
    }

    internal static void SuppressPainting(CSequence output, COperator operation)
    {
        if (operation.Name is "S" or "s" or "f" or "F" or "f*" or "B" or "B*" or "b" or "b*")
        {
            output.Add(ContentReader.ReadContent(System.Text.Encoding.ASCII.GetBytes("n"))[0]);
        }
        else if (operation.Name is "Do" or "sh")
        {
            // XObjects and shadings paint without changing the caller's graphics state.
        }
        else if (operation.Name is "Tj" or "TJ" or "'" or "\"")
        {
            // Invisible text still advances the text matrix. q/Q restores the rendering
            // mode but does not restore the text matrix, preserving subsequent placement.
            foreach (var item in ContentReader.ReadContent(System.Text.Encoding.ASCII.GetBytes("q 3 Tr"))) output.Add(item);
            output.Add(operation);
            output.Add(ContentReader.ReadContent(System.Text.Encoding.ASCII.GetBytes("Q"))[0]);
        }
        else output.Add(operation);
    }

    private static bool IsTargetElementStart(COperator operation, IReadOnlySet<string> elementTags)
    {
        return operation.Name == "BMC" &&
               operation.Operands.Count > 0 &&
               operation.Operands[0] is CName name &&
               elementTags.Contains(name.Name);
    }
}
