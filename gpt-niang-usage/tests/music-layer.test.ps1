param([string]$ResultFile)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime/host-layer.ps1')
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class MusicLayerProbe{[DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();}
'@
$windows=@();$foreground=[MusicLayerProbe]::GetForegroundWindow()
try{
 foreach($n in 1..3){$w=[Windows.Window]::new();$w.Width=200;$w.Height=150;$w.Left=-5000;$w.Top=-5000;$w.ShowActivated=$false;$w.ShowInTaskbar=$false;$w.Show();$windows+=$w}
 $h=[Windows.Interop.WindowInteropHelper]::new($windows[0]).Handle;$w=[Windows.Interop.WindowInteropHelper]::new($windows[1]).Handle;$l=[Windows.Interop.WindowInteropHelper]::new($windows[2]).Handle
 [GptWidgetZOrderNative]::SetWindowPos($h,[IntPtr](1),0,0,0,0,0x213)|Out-Null
 Set-WidgetAboveHost $w $h|Out-Null
 [GptWidgetZOrderNative]::SetWindowPos($l,$w,0,0,0,0,0x213)|Out-Null
 for($i=0;$i-lt 120;$i++){
  $r=Set-WidgetAboveHost $w $h $l
  if(!$r.ok -or $r.changed -or [GptWidgetZOrderNative]::PreviousVisible($h)-ne $l -or [GptWidgetZOrderNative]::PreviousVisible($l)-ne $w){throw 'The ordinary layer tick fights the music light surface'}
 }
 $currentForeground=[MusicLayerProbe]::GetForegroundWindow()
 if($currentForeground-eq $h -or $currentForeground-eq $w -or $currentForeground-eq $l){throw 'Lighting changed foreground'}
 $result=@{passed=$true;cycles=120;noLayerChurn=$true;characterAboveLighting=$true;lightingAboveHost=$true;foregroundUnchanged=$true}
 if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
 Write-Output 'PASS: 120 native layer ticks keep character / lighting / host order without reordering or activation'
}finally{foreach($window in $windows){$window.Close()}}
