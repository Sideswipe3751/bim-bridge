# Third-party notices

BIM Bridge installs and interoperates with third-party providers. The
providers remain separate versioned components; their licenses and copyright
notices are included in each installed provider directory.

## mcp-servers-for-revit

- Source: https://github.com/mcp-servers-for-revit/mcp-servers-for-revit
- Pinned release: v1.0.0
- License: MIT
- Copyright: the mcp-servers-for-revit contributors

## AutoCAD MCP Pro

- Source: https://github.com/U-C4N/Autocad-MCP
- Pinned release: v1.5.1
- License: MIT
- Copyright: Umutcan Edizsalan and contributors

BIM Bridge itself is not endorsed by Autodesk or by either upstream project.

## Node.js runtime

- Source: https://github.com/nodejs/node
- Pinned release: v22.23.2 (Windows x64)
- License: MIT
- Copyright: Node.js contributors

The release build uses npm to assemble the provider, but the shipped runtime is
trimmed to Node.js and its license. Server dependencies and their license
metadata remain in the provider bundle.

## Python runtime and packages

- Source: https://www.python.org/
- Pinned runtime: CPython 3.12.10 embeddable package (Windows x64)
- License: Python Software Foundation License
- Copyright: Python Software Foundation and contributors

The private runtime contains the pinned AutoCAD provider and its Python
dependencies. Package metadata and license files are preserved under
`Lib/site-packages`; CPython's `LICENSE.txt` is preserved at the runtime root.

## BIM Bridge modifications

BIM Bridge applies documented compatibility and security patches while building
the pinned providers. The upstream components remain under their original MIT
licenses, and their copyright and license notices are preserved in source and
binary distributions.

## PDFsharp GDI (Layered PDF composer)

- Source: https://github.com/empira/PDFsharp/tree/v6.2.4
- Pinned package: PDFsharp-gdi 6.2.4
- License: MIT, as distributed at that exact tag and in the NuGet package metadata
- Copyright: (c) 2001-2026 empira Software GmbH, Troisdorf (Cologne Area), Germany
- Full notice: `src/BimBridge.LayeredPdf.Composer/PDFsharp-LICENSE.txt`

The license is version-specific; later upstream releases must be reviewed
independently. The composer runs outside Autodesk and retains the dependency's
original licensing. Its self-contained .NET runtime and Microsoft dependencies
remain under their respective distribution licenses.
