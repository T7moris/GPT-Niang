param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'supervisor-task.ps1')
$appDir=Split-Path $PSScriptRoot -Parent
$info=Get-WidgetSupervisorInfo $appDir
if(!('GptWidgetSupervisorNative' -as [type])){
Add-Type -TypeDefinition @'
using System;using System.Collections.Generic;using System.Diagnostics;using System.Runtime.InteropServices;using System.Text;
public sealed class GptWidgetSupervisorHost {public long handle;public int pid;public long started;public bool visible;}
public static class GptWidgetSupervisorNative {
 static readonly int Session=CurrentSession();
 static int CurrentSession(){using(var process=Process.GetCurrentProcess())return process.SessionId;}
 public delegate bool EnumProc(IntPtr h,IntPtr p);
 [DllImport("user32.dll")]static extern bool EnumWindows(EnumProc cb,IntPtr p);
 [DllImport("user32.dll")]public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")]static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]static extern IntPtr GetWindowLongPtr(IntPtr h,int index);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetClassName(IntPtr h,StringBuilder text,int size);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetWindowText(IntPtr h,StringBuilder text,int size);
 [DllImport("dwmapi.dll")]static extern int DwmGetWindowAttribute(IntPtr h,int attribute,out uint value,int size);
 public static bool MainWindowStyle(long style,long extended){return (extended&0x80)==0&&(extended&0x08000000)==0&&(extended&0x40000)!=0&&(style&0x10000)!=0;}
 public static int ProcessId(IntPtr h){uint value;GetWindowThreadProcessId(h,out value);return (int)value;}
 static bool CodexProcess(Process process){
  if(process.SessionId!=Session)return false;
  if(!process.ProcessName.Equals("ChatGPT",StringComparison.OrdinalIgnoreCase)&&!process.ProcessName.Equals("Codex",StringComparison.OrdinalIgnoreCase))return false;
  string file=process.MainModule.FileName;
  return file.IndexOf("\\OpenAI.Codex_",StringComparison.OrdinalIgnoreCase)>=0||file.IndexOf("\\OpenAI\\Codex\\",StringComparison.OrdinalIgnoreCase)>=0;
 }
 public static GptWidgetSupervisorHost Inspect(IntPtr h){
  try{
   if(!IsWindow(h)||!MainWindowStyle(GetWindowLongPtr(h,-16).ToInt64(),GetWindowLongPtr(h,-20).ToInt64()))return null;
   var text=new StringBuilder(256);GetWindowText(h,text,256);if(text.Length==0)return null;
   var cls=new StringBuilder(128);GetClassName(h,cls,128);if(cls.ToString()!="Chrome_WidgetWin_1")return null;
   using(var process=Process.GetProcessById(ProcessId(h))){
    if(!CodexProcess(process))return null;
    uint cloaked;bool visible=IsWindowVisible(h)&&!IsIconic(h)&&(DwmGetWindowAttribute(h,14,out cloaked,4)!=0||cloaked==0);
    return new GptWidgetSupervisorHost{handle=h.ToInt64(),pid=process.Id,started=process.StartTime.ToUniversalTime().Ticks,visible=visible};
   }
  }catch{return null;}
 }
 public static GptWidgetSupervisorHost[] Hosts(){var hosts=new List<GptWidgetSupervisorHost>();EnumWindows((h,p)=>{var host=Inspect(h);if(host!=null)hosts.Add(host);return true;},IntPtr.Zero);return hosts.ToArray();}
}
'@
}

function Test-WidgetSupervisorPause($Pause,$Hosts){
  if(!$Pause){return $false}
  if($Pause.awaitNewHost -or $Pause.desktop){
    $cutoff=0L
    try{if($Pause.exitedAtTicks){$cutoff=[long]$Pause.exitedAtTicks}else{$cutoff=([DateTime]$Pause.at).ToUniversalTime().Ticks}}catch{return $true}
    if($cutoff-le 0){return $true}
    foreach($item in @($Hosts)){if([long]$item.started-gt $cutoff){return $false}}
    return $true
  }
  foreach($item in @($Hosts)){
    if([long]$Pause.host-gt 0 -and [long]$item.handle-eq [long]$Pause.host){
      if([int]$Pause.hostPid-gt 0 -and [int]$item.pid-ne [int]$Pause.hostPid){continue}
      if([long]$Pause.hostStarted-gt 0 -and [long]$item.started-ne [long]$Pause.hostStarted){continue}
      return $true
    }
  }
  return $false
}

function Get-WidgetSupervisorRunningGui([string]$DataDir,[string]$ExpectedAppDir){
  $process=$null
  try{
    $runtime=Get-Content -LiteralPath (Join-Path $DataDir 'runtime.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $handle=[IntPtr]([long]$runtime.widget)
    if(![GptWidgetSupervisorNative]::IsWindow($handle) -or [GptWidgetSupervisorNative]::ProcessId($handle)-ne [int]$runtime.pid){return $false}
    $process=Get-Process -Id ([int]$runtime.pid) -ErrorAction Stop
    if($process.ProcessName-notin @('powershell','pwsh')){return $false}
    if($runtime.processStartedAt){
      if(([DateTime]$runtime.processStartedAt).ToUniversalTime()-ne $process.StartTime.ToUniversalTime()){return $false}
    }else{
      $recorded=([DateTime]$runtime.startedAt).ToUniversalTime()
      $gap=($recorded-$process.StartTime.ToUniversalTime()).TotalSeconds
      if($gap-lt 0 -or $gap-gt 120){return $false}
    }
    $command=(Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$runtime.pid) -ErrorAction Stop).CommandLine
    $scriptFile=Join-Path $ExpectedAppDir 'widget.ps1'
    return $command.IndexOf(('"'+$scriptFile+'"'),[StringComparison]::OrdinalIgnoreCase)-ge 0
  }catch{return $false}finally{if($process){$process.Dispose()}}
}

if($CheckOnly){return [pscustomobject]@{ok=$true;info=$info;hosts=@([GptWidgetSupervisorNative]::Hosts())}}

$mutex=[Threading.Mutex]::new($false,('Local\GPTNiangSupervisor-'+$info.Sid))
$owned=$false
try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
if(!$owned){$mutex.Dispose();exit 0}
$pauseFile=Join-Path $info.DataDir 'supervisor-pause.json'
$nextLaunch=[DateTime]::MinValue
$nextStatus=[DateTime]::MinValue
$lastVisibleHostKey=''
$pendingGui=$null
$sessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId
$bootTicks=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().Ticks
$launchSessionKey=('{0}:{1}'-f $bootTicks,$sessionId)
$launchSessionFile=Join-Path $info.DataDir 'supervisor-launch-session.json'
$desktopActivated=$false
try{$previous=Get-Content -LiteralPath $launchSessionFile -Raw -Encoding UTF8|ConvertFrom-Json;$desktopActivated=$previous.key-eq $launchSessionKey -and [bool]$previous.activated}catch{}
$supervisorProcess=Get-Process -Id $PID
try{$processStartedAt=$supervisorProcess.StartTime.ToUniversalTime().ToString('o')}finally{$supervisorProcess.Dispose()}
try{
  while($true){
    if((Test-Path -LiteralPath (Join-Path $info.DataDir 'supervisor-disabled.flag')) -or (Test-Path -LiteralPath (Join-Path $info.DataDir 'supervisor-stop.flag'))){break}
    try{
      $hosts=@([GptWidgetSupervisorNative]::Hosts())
      $settings=$null;try{$settings=Get-Content -LiteralPath (Join-Path $info.DataDir 'settings.json') -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
      $desktop=$settings -and $null-ne $settings.followHost -and !$settings.followHost
      $pause=$null;try{$pause=Get-Content -LiteralPath $pauseFile -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
      $paused=Test-WidgetSupervisorPause $pause $hosts
      if($pause -and !$paused){Remove-Item -LiteralPath $pauseFile -ErrorAction SilentlyContinue}
      $visible=@($hosts|Where-Object{$_.visible})
      $visibleHostKey=(@($visible|Sort-Object handle|ForEach-Object{'{0}:{1}:{2}'-f $_.handle,$_.pid,$_.started}) -join '|')
      if($visibleHostKey-ne $lastVisibleHostKey){$nextLaunch=[DateTime]::MinValue;$lastVisibleHostKey=$visibleHostKey}
      $running=Get-WidgetSupervisorRunningGui $info.DataDir $info.AppDir
      if(!$desktopActivated -and ($hosts.Count-gt 0 -or $running)){
        $desktopActivated=$true
        Write-WidgetSupervisorJson $launchSessionFile @{key=$launchSessionKey;activated=$true;at=[DateTime]::UtcNow.ToString('o')}
      }
      # Retain the launch handle until startup finishes, so slow WPF startup
      # cannot create another GUI process before runtime.json is available.
      if($pendingGui -and ($running -or $pendingGui.HasExited)){$pendingGui.Dispose();$pendingGui=$null}
      if(!$paused -and (($desktop -and $desktopActivated) -or $visible.Count-gt 0) -and !$running -and !$pendingGui -and [DateTime]::UtcNow-ge $nextLaunch){
        $nextLaunch=[DateTime]::UtcNow.AddSeconds(10)
        $powerShell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $pendingGui=Start-Process -FilePath $powerShell -ArgumentList @('-NoLogo','-NoProfile','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+(Join-Path $info.AppDir 'runtime\start-widget.ps1')+'"'),'-WidgetPath',('"'+(Join-Path $info.AppDir 'widget.ps1')+'"')) -WindowStyle Hidden -PassThru
      }
      if([DateTime]::UtcNow-ge $nextStatus){
        Write-WidgetSupervisorJson (Join-Path $info.DataDir 'supervisor-status.json') @{pid=$PID;processStartedAt=$processStartedAt;at=[DateTime]::UtcNow.ToString('o');mainWindows=$hosts.Count;visibleWindows=$visible.Count;paused=$paused;desktopActivated=$desktopActivated;widgetRunning=$running;taskName=$info.TaskName}
        $nextStatus=[DateTime]::UtcNow.AddSeconds(5)
      }
    }catch{try{[IO.File]::WriteAllText((Join-Path $info.DataDir 'supervisor-error.txt'),$_.Exception.Message)}catch{}}
    Start-Sleep -Milliseconds 1500
  }
}finally{
  if($pendingGui){$pendingGui.Dispose()}
  try{
    $statusFile=Join-Path $info.DataDir 'supervisor-status.json'
    $status=Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8|ConvertFrom-Json
    if([int]$status.pid-eq $PID){Remove-Item -LiteralPath $statusFile -ErrorAction SilentlyContinue}
  }catch{}
  try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()
}
