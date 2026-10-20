param([string]$TestRoot=$PSScriptRoot,[string]$WidgetSource,[string]$ResultFile,[switch]$RequireLiveHost)
$ErrorActionPreference='Stop'
$app=Split-Path $TestRoot -Parent
if(!$WidgetSource){$WidgetSource=Join-Path $app 'widget.ps1'}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($WidgetSource,[Text.Encoding]::UTF8),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Widget did not parse'}
$native=$ast.Find({param($n)$n-is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('public static class GptWidgetNative {')},$true).Value
Add-Type -TypeDefinition $native
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class HostIdentityProbe {
 [DllImport("user32.dll")]public static extern bool PostMessage(IntPtr h,uint msg,IntPtr w,IntPtr l);
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
}
'@
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-host-id-'+[Guid]::NewGuid().ToString('N'))
$children=@();$checks=0;$fakeCount=0;$realHandle=[IntPtr]::Zero;$foregroundBefore=[HostIdentityProbe]::GetForegroundWindow()
function Assert-Host([bool]$Value,[string]$Message){if(!$Value){throw $Message};$script:checks++}
try{
 $null=[IO.Directory]::CreateDirectory($fixture)
 $stub=@'
using System;using System.IO;using System.ComponentModel;using System.Runtime.InteropServices;
public static class HostIdentityFixture {
 delegate IntPtr WindowProc(IntPtr h,uint msg,IntPtr w,IntPtr l);
 static readonly WindowProc Callback=Proc;
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct WndClass {
  public uint Size,Style;public IntPtr Proc;public int ClassExtra,WindowExtra;public IntPtr Instance,Icon,Cursor,Background;
  public string Menu,Name;public IntPtr SmallIcon;
 }
 [StructLayout(LayoutKind.Sequential)]struct Msg {public IntPtr Window;public uint Message;public UIntPtr W;public IntPtr L;public uint Time;public int X,Y;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)]static extern IntPtr GetModuleHandle(string name);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern ushort RegisterClassEx(ref WndClass c);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern IntPtr CreateWindowEx(uint ex,string cls,string title,uint style,int x,int y,int w,int height,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr arg);
 [DllImport("user32.dll")]static extern IntPtr DefWindowProc(IntPtr h,uint msg,IntPtr w,IntPtr l);
 [DllImport("user32.dll")]static extern void PostQuitMessage(int code);
 [DllImport("user32.dll")]static extern int GetMessage(out Msg msg,IntPtr h,uint first,uint last);
 [DllImport("user32.dll")]static extern bool TranslateMessage(ref Msg msg);
 [DllImport("user32.dll")]static extern IntPtr DispatchMessage(ref Msg msg);
 static IntPtr Proc(IntPtr h,uint msg,IntPtr w,IntPtr l){if(msg==2){PostQuitMessage(0);return IntPtr.Zero;}return DefWindowProc(h,msg,w,l);}
 public static void Main(string[] args){
  var c=new WndClass{Size=(uint)Marshal.SizeOf(typeof(WndClass)),Instance=GetModuleHandle(null),Name="Chrome_WidgetWin_1",Proc=Marshal.GetFunctionPointerForDelegate(Callback)};
  if(RegisterClassEx(ref c)==0)throw new Win32Exception(Marshal.GetLastWin32Error());
  var h=CreateWindowEx(0x40000,c.Name,"Isolated host identity fixture",0x00CF0000,-20000,-20000,300,200,IntPtr.Zero,IntPtr.Zero,c.Instance,IntPtr.Zero);
  if(h==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
  File.WriteAllText(args[0],h.ToInt64().ToString());
  Msg message;while(GetMessage(out message,IntPtr.Zero,0,0)>0){TranslateMessage(ref message);DispatchMessage(ref message);}
 }
}
'@
 $first=Join-Path $fixture 'ChatGPT.exe';Add-Type -TypeDefinition $stub -OutputAssembly $first -OutputType WindowsApplication
 Copy-Item -LiteralPath $first -Destination (Join-Path $fixture 'Codex.exe')
 foreach($name in @('ChatGPT','Codex')){
  $ready=Join-Path $fixture ($name+'.ready');$exe=Join-Path $fixture ($name+'.exe')
  $child=Start-Process -FilePath $exe -ArgumentList ('"'+$ready+'"') -WindowStyle Hidden -PassThru
  $children+=@{process=$child;handle=[IntPtr]::Zero}
  $deadline=[DateTime]::UtcNow.AddSeconds(5)
  while(!(Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow-lt $deadline){if($child.HasExited){throw 'Identity fixture exited before creating its window'};Start-Sleep -Milliseconds 30}
  if(!(Test-Path -LiteralPath $ready)){throw 'Identity fixture did not publish its window'}
  $handle=[IntPtr]([long]([IO.File]::ReadAllText($ready)));$children[-1].handle=$handle
  Assert-Host ([GptWidgetNative]::ProcessId($handle)-eq $child.Id) 'Fixture HWND belongs to a different process'
  Assert-Host (!$child.HasExited -and $child.ProcessName-eq $name) 'Fixture did not have the required executable name'
  Assert-Host (![HostIdentityProbe]::IsWindowVisible($handle)) 'Test fixture must stay hidden'
  Assert-Host (![GptWidgetNative]::IsCodex($handle)) ('Unrelated executable with matching name/class/style was accepted: '+$name)
  Assert-Host ([GptWidgetNative]::ForegroundHost($handle)-eq [IntPtr]::Zero) 'Window switching accepted an unrelated fixture'
  $fakeCount++
 }
 $paths=@(
  @{path='C:\Program Files\WindowsApps\OpenAI.Codex_26.1013.3656.0_x64__example\app\ChatGPT.exe';allowed=$true},
  @{path='C:\Program Files\WindowsApps\OpenAI.Codex_99.9999.0_x64__example\app\Codex.exe';allowed=$true},
  @{path='C:\Users\Example\AppData\Local\OpenAI\Codex\bin\new-version\Codex.exe';allowed=$true},
  @{path='c:\users\example\appdata\local\openai\codex\ChatGPT.exe';allowed=$true},
  @{path='C:\Apps\Codex\Codex.exe';allowed=$false},
  @{path='C:\Downloads\ChatGPT.exe';allowed=$false},
  @{path='';allowed=$false},@{path=$null;allowed=$false}
 )
 foreach($row in $paths){Assert-Host ([GptWidgetNative]::CodexExecutable($row.path)-eq $row.allowed) ('Unexpected installation-path classification: '+$row.path)}
 Assert-Host (![GptWidgetNative]::IsCodex([IntPtr]::Zero)) 'Null HWND was accepted'
 $realHandle=[GptWidgetNative]::FindCodex();$live=$realHandle-ne [IntPtr]::Zero
 if($RequireLiveHost -and !$live){throw 'A real running Codex host is required for this local check'}
 if($live){
  $process=Get-Process -Id ([GptWidgetNative]::ProcessId($realHandle))
  Assert-Host ([GptWidgetNative]::IsCodex($realHandle)) 'Real Codex was rejected'
  Assert-Host ([GptWidgetNative]::ForegroundHost($realHandle)-eq $realHandle) 'Real main window could not be used during window switching'
  Assert-Host ($process.SessionId-eq (Get-Process -Id $PID).SessionId) 'Real host is in another Windows login session'
  Assert-Host ([GptWidgetNative]::CodexExecutable($process.Path)) 'Real installation path was rejected'
  # Compile an isolated copy with a different expected login-session number.
  # The real HWND/process stays unchanged; no Windows account is created.
  $other=$native.Replace('GptWidgetNative','HostIdentityOtherSession')
  Assert-Host ($other.Contains('static readonly int Session=CurrentSession();')) 'Missing login-session guard'
  $other=$other.Replace('static readonly int Session=CurrentSession();','static readonly int Session=CurrentSession()+1;')
  Add-Type -TypeDefinition $other
  Assert-Host (![HostIdentityOtherSession]::IsCodex($realHandle)) 'Mismatched login session was accepted'
 }
 foreach($item in $children){
  Assert-Host ([HostIdentityProbe]::GetForegroundWindow()-ne $item.handle) 'Test fixture acquired foreground focus'
 }
 $result=@{passed=$true;checks=$checks;unrelatedNativeProcessesRejected=$fakeCount;pathCases=$paths.Count;realHostChecked=$live;realHost=$realHandle.ToInt64();simulatedSessionMismatchChecked=$live;actualSecondLoginSessionTested=$false;userHostMovedOrActivated=$false;foregroundUnchanged=([HostIdentityProbe]::GetForegroundWindow()-eq $foregroundBefore)}
 if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
 Write-Output ('PASS: '+$checks+' host identity checks; '+$fakeCount+' native same-name windows rejected, real-host checked='+$live)
}finally{
 foreach($item in $children){
  $child=$item.process
  try{
   if(!$child.HasExited -and $item.handle-ne [IntPtr]::Zero -and [GptWidgetNative]::ProcessId($item.handle)-eq $child.Id){[HostIdentityProbe]::PostMessage($item.handle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null}
   if(!$child.WaitForExit(2000)){$child.Kill();$child.WaitForExit()}
  }finally{$child.Dispose()}
 }
 $resolved=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-host-id-*'){throw 'Unsafe test-fixture cleanup path'}
 if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
