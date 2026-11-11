using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Text;
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
            // Run the bundled scripts with a process-only Bypass policy, like
            // powershell.exe -ExecutionPolicy Bypass. Downloaded copies carry the
            // internet zone mark, which RemoteSigned machines otherwise refuse.
            // Group Policy settings still take precedence.
            InitialSessionState state = InitialSessionState.CreateDefault();
            state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (Runspace runspace = RunspaceFactory.CreateRunspace(state))
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
                    {
                        // Streams.Error is a collection; its ToString() is only the type name.
                        StringBuilder details = new StringBuilder();
                        foreach (ErrorRecord record in shell.Streams.Error)
                        {
                            details.AppendLine(record.ToString());
                            if (record.InvocationInfo != null && !String.IsNullOrEmpty(record.InvocationInfo.PositionMessage))
                                details.AppendLine(record.InvocationInfo.PositionMessage);
                        }
                        if (details.Length == 0)
                            details.Append("The startup script reported an error without details.");
                        MessageBox.Show(details.ToString(), "Directory Lens - startup error");
                    }
                }
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message + "\n\nKeep the application, scripts, database and lib folder together.", "Directory Lens - startup error");
        }
    }
}
