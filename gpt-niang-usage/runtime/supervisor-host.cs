using System;
using System.Diagnostics;
using System.IO;
using System.Text;

// Compiled as a Windows application: neither this host nor its child creates
// a console window. Waiting and forwarding the exit code keeps Task Scheduler's
// instance tracking and restart-on-failure behavior intact.
internal static class GptNiangSupervisorHost
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 1 || args[0] != "-Supervisor") return 64;
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string diagnostic = Path.Combine(root, "supervisor-launch-error.txt");
        try
        {
            string script = Path.Combine(root, "update-agent.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("Stable update agent is missing.", script);
            var start = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                    @"System32\WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \""
                    + script + "\" -Supervisor",
                WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardErrorEncoding = Encoding.Default
            };
            using (Process child = Process.Start(start))
            {
                try { File.Delete(diagnostic); } catch { }
                var errors = new StringBuilder();
                child.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs line)
                {
                    if (line.Data == null) return;
                    lock (errors)
                    {
                        errors.AppendLine(line.Data);
                        if (errors.Length > 16384) errors.Remove(0, errors.Length - 16384);
                    }
                };
                child.StandardInput.Close();
                // Drain both pipes asynchronously so output cannot block exit.
                child.BeginOutputReadLine();
                child.BeginErrorReadLine();
                child.WaitForExit();
                if (child.ExitCode != 0)
                {
                    try { lock (errors) File.WriteAllText(diagnostic,
                        "Supervisor exit code: " + child.ExitCode + Environment.NewLine + errors, new UTF8Encoding(false)); } catch { }
                }
                return child.ExitCode;
            }
        }
        catch (Exception error)
        {
            try { File.WriteAllText(diagnostic, error.ToString(), new UTF8Encoding(false)); } catch { }
            return 1;
        }
    }
}
