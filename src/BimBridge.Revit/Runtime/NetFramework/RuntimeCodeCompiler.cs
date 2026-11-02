using System;
using System.CodeDom.Compiler;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;
using Microsoft.CSharp;

namespace BimBridge.Revit;

internal sealed class RuntimeCodeCompiler : IRevitCodeCompiler
{
    public Assembly Compile(string source)
    {
        using (var provider = new CSharpCodeProvider(
            new Dictionary<string, string> { ["CompilerVersion"] = "v4.0" }))
        {
            var parameters = new CompilerParameters
            {
                GenerateExecutable = false,
                GenerateInMemory = true,
                IncludeDebugInformation = false,
                TreatWarningsAsErrors = false,
                CompilerOptions = "/optimize /langversion:5"
            };
            AddReference(parameters, typeof(object).Assembly);
            AddReference(parameters, typeof(System.ComponentModel.Component).Assembly);
            AddReference(parameters, typeof(Enumerable).Assembly);
            AddReference(parameters, typeof(UIApplication).Assembly);
            AddReference(parameters, typeof(Document).Assembly);

            var result = provider.CompileAssemblyFromSource(parameters, source);
            if (result.Errors.HasErrors)
            {
                var errors = result.Errors.Cast<CompilerError>()
                    .Where(error => !error.IsWarning)
                    .Select(error => error.ToString());
                throw new InvalidOperationException(
                    "Revit code compilation failed: " + string.Join("; ", errors));
            }
            return result.CompiledAssembly;
        }
    }

    private static void AddReference(CompilerParameters parameters, Assembly assembly)
    {
        if (!string.IsNullOrEmpty(assembly.Location) &&
            !parameters.ReferencedAssemblies.Contains(assembly.Location))
        {
            parameters.ReferencedAssemblies.Add(assembly.Location);
        }
    }
}
