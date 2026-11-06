using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows;

internal static class DirectoryLensLauncher
{
    [STAThread]
    private static void Main()
    {
        try
        {
            string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Directory-Lens-GUI.ps1");
            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (PowerShell shell = PowerShell.Create())
                {
                    shell.Runspace = runspace;
                    shell.AddCommand(script);
                    shell.Invoke();
                    if (shell.HadErrors)
                        MessageBox.Show(shell.Streams.Error.ToString(), "Directory Lens - startup error");
                }
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message + "\n\nKeep the application, scripts, database and lib folder together.", "Directory Lens - startup error");
        }
    }
}
