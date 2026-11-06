$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'Launcher.cs'
$outDir=$PSScriptRoot
New-Item -ItemType Directory -Force $outDir | Out-Null
$options=New-Object CodeDom.Compiler.CompilerParameters
$options.GenerateExecutable=$true
$options.GenerateInMemory=$false
$options.OutputAssembly=Join-Path $outDir 'Directory-Lens.exe'
$options.CompilerOptions='/target:winexe /platform:anycpu /win32icon:"'+(Join-Path $PSScriptRoot 'design\directory-icon\DirectoryIcon.ico')+'"'
$references=@('System.dll','System.Core.dll',[System.Management.Automation.PowerShell].Assembly.Location,'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\PresentationFramework.dll','C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\PresentationCore.dll','C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\WindowsBase.dll','C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Xaml.dll')
foreach ($reference in $references) { [void]$options.ReferencedAssemblies.Add($reference) }
[void]$options.EmbeddedResources.Add((Join-Path $PSScriptRoot 'design\directory-icon\DirectoryIcon.png'))
$compiler=New-Object Microsoft.CSharp.CSharpCodeProvider
try {
    $result=$compiler.CompileAssemblyFromFile($options,$source)
    if ($result.Errors.HasErrors) { throw ($result.Errors | Out-String) }
} finally { $compiler.Dispose() }
Write-Output $options.OutputAssembly
