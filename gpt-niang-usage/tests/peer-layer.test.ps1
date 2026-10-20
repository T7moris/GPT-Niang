param([string]$TestRoot=$PSScriptRoot,[string]$LayerSource,[string]$ResultFile,[switch]$PeerWorker,[string]$Mailbox,[long]$HostHandle)
$ErrorActionPreference='Stop'
if(!$LayerSource){$LayerSource=Join-Path (Split-Path $TestRoot -Parent) 'runtime/host-layer.ps1'}
$LayerSource=[IO.Path]::GetFullPath($LayerSource)
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. ([ScriptBlock]::Create([IO.File]::ReadAllText($LayerSource,[Text.Encoding]::UTF8)))
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class PeerLayerStudy {
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]static extern IntPtr GetWindow(IntPtr h,uint command);
 public static bool Above(IntPtr upper,IntPtr lower){for(IntPtr h=GetWindow(lower,3);h!=IntPtr.Zero;h=GetWindow(h,3))if(h==upper)return true;return false;}
}
'@
$fixtures=@();$rows=@();$foreground=[PeerLayerStudy]::GetForegroundWindow()
function Fixture([string]$Name,[bool]$Overlay=$false){
 $w=[Windows.Window]::new();$w.Title='Isolated layer study '+$Name;$w.Width=160;$w.Height=100;$w.Left=-10000;$w.Top=-10000
 $w.ShowActivated=$false;$w.ShowInTaskbar=$false;$w.Opacity=0;$w.Show();$script:fixtures+=,$w
 $h=[Windows.Interop.WindowInteropHelper]::new($w).Handle
 $ex=[GptWidgetZOrderNative]::GetWindowLongPtr($h,-20).ToInt64()
 $ex=if($Overlay){$ex-bor 0x08000080}else{$ex-band (-bnot 0x08000080)}
 [GptWidgetZOrderNative]::SetWindowLongPtr($h,-20,[IntPtr]$ex)|Out-Null
 return $h
}
function Place([IntPtr]$H,[IntPtr]$After){if(![GptWidgetZOrderNative]::SetWindowPos($H,$After,0,0,0,0,0x213)){throw 'Fixture placement failed'}}
function Own([IntPtr]$H,[IntPtr]$Owner){[GptWidgetZOrderNative]::SetWindowLongPtr($H,-8,$Owner)|Out-Null}
function Wait-PeerJson([string]$Path){
 $deadline=[DateTime]::UtcNow.AddSeconds(6)
 do{
  try{if(Test-Path -LiteralPath $Path){return [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)|ConvertFrom-Json}}catch{}
  Start-Sleep -Milliseconds 5
 }while([DateTime]::UtcNow-lt $deadline)
 throw ('Peer fixture response timed out: '+$Path)
}
if($PeerWorker){
 try{
  $h=Fixture 'cross-process peer' $true
  $initial=Set-WidgetAboveHost $h ([IntPtr]$HostHandle)
  if(!$initial.ok){throw 'Cross-process fixture could not attach to the isolated host'}
  [IO.File]::WriteAllText((Join-Path $Mailbox 'ready.json'),(@{pid=$PID;handle=$h.ToInt64()}|ConvertTo-Json))
  $next=0
  while(!(Test-Path -LiteralPath (Join-Path $Mailbox 'stop.flag'))){
   $request=Join-Path $Mailbox ('request-'+$next+'.json')
   if(!(Test-Path -LiteralPath $request)){Start-Sleep -Milliseconds 5;continue}
   $r=Set-WidgetAboveHost $h ([IntPtr]$HostHandle)
   [IO.File]::WriteAllText((Join-Path $Mailbox ('response-'+$next+'.json')),(@{ok=[bool]$r.ok;changed=[bool]$r.changed;pid=$PID}|ConvertTo-Json))
   $next++
  }
 }finally{[array]::Reverse($fixtures);foreach($w in $fixtures){$w.Close()}}
 return
}
$child=$null;$mailboxRoot=$null
try{
 $hostWindow=Fixture 'host' ;$a=Fixture 'A' $true;$b=Fixture 'B' $true;$lamp=Fixture 'known light' $true
 $dialog=Fixture 'ordinary dialog';$foreign=Fixture 'unrelated overlay' $true
 Own $a $hostWindow;Own $b $hostWindow;Own $dialog $hostWindow
 foreach($h in @($dialog,$foreign,$lamp)){[GptWidgetZOrderNative]::SetWindowPos($h,[IntPtr]::Zero,0,0,0,0,0x293)|Out-Null}
 foreach($topmost in @($false,$true)){
  foreach($h in @($a,$b,$hostWindow)){Place $h $(if($topmost){[IntPtr](-1)}else{[IntPtr](-2)})}
  [GptWidgetZOrderNative]::SetWindowPos($a,[IntPtr]::Zero,0,0,0,0,0x253)|Out-Null
  [GptWidgetZOrderNative]::SetWindowPos($b,[IntPtr]::Zero,0,0,0,0,0x253)|Out-Null
  Set-WidgetAboveHost $a $hostWindow|Out-Null;Set-WidgetAboveHost $b $hostWindow|Out-Null
  $changes=0;$failures=0
  for($i=0;$i-lt 60;$i++){foreach($h in @($a,$b)){$r=Set-WidgetAboveHost $h $hostWindow;if($r.changed){$changes++};if(!$r.ok){$failures++}}}
  $rows+=@{case='two overlays';hostTopmost=$topmost;ticks=120;layerChanges=$changes;failures=$failures;stable=($changes-eq 0 -and $failures-eq 0)}
 }
 foreach($h in @($a,$b,$hostWindow,$lamp)){Place $h ([IntPtr](-2))}
 [GptWidgetZOrderNative]::SetWindowPos($b,[IntPtr]::Zero,0,0,0,0,0x293)|Out-Null
 Set-WidgetAboveHost $a $hostWindow|Out-Null;Place $lamp $a
 [GptWidgetZOrderNative]::SetWindowPos($lamp,$a,0,0,0,0,0x253)|Out-Null
 $changes=0;$wrongOrder=0
 for($i=0;$i-lt 60;$i++){
  if([GptWidgetZOrderNative]::GetWindow($a,2)-ne $lamp){Place $lamp $a}
  $r=Set-WidgetAboveHost $a $hostWindow $lamp;if($r.changed){$changes++}
  if(![PeerLayerStudy]::Above($a,$lamp) -or ![PeerLayerStudy]::Above($lamp,$hostWindow)){$wrongOrder++}
 }
 $rows+=@{case='known light';ticks=60;layerChanges=$changes;wrongOrder=$wrongOrder;stable=($changes-eq 0 -and $wrongOrder-eq 0)}
 [GptWidgetZOrderNative]::SetWindowPos($b,[IntPtr]::Zero,0,0,0,0,0x253)|Out-Null
 Set-WidgetAboveHost $b $hostWindow|Out-Null
 $changes=0;$failures=0;$steadyChanges=0
 for($i=0;$i-lt 60;$i++){
  if([GptWidgetZOrderNative]::GetWindow($a,2)-ne $lamp){Place $lamp $a}
  $r=Set-WidgetAboveHost $a $hostWindow $lamp;if($r.changed){$changes++;if($i-gt 0){$steadyChanges++}};if(!$r.ok){$failures++}
  if([GptWidgetZOrderNative]::GetWindow($a,2)-ne $lamp){Place $lamp $a}
  $r=Set-WidgetAboveHost $b $hostWindow;if($r.changed){$changes++;if($i-gt 0){$steadyChanges++}};if(!$r.ok){$failures++}
 }
 $rows+=@{case='known light and peer';ticks=120;layerChanges=$changes;changesAfterFirstCycle=$steadyChanges;failures=$failures;stable=($changes-eq 0 -and $failures-eq 0);stableAfterSettling=($steadyChanges-eq 0 -and $failures-eq 0)}
 foreach($h in @($b,$lamp)){[GptWidgetZOrderNative]::SetWindowPos($h,[IntPtr]::Zero,0,0,0,0,0x293)|Out-Null}
 foreach($h in @($dialog,$foreign)){
  Set-WidgetAboveHost $a $hostWindow|Out-Null
  [GptWidgetZOrderNative]::SetWindowPos($h,$a,0,0,0,0,0x253)|Out-Null
  $r=Set-WidgetAboveHost $a $hostWindow
  $protected=$r.ok -and $r.changed -and [PeerLayerStudy]::Above($h,$a)
  $rows+=@{case=$(if($h-eq $dialog){'ordinary dialog'}else{'unrelated overlay'});repairOccurred=[bool]$r.changed;remainsAboveWidget=[PeerLayerStudy]::Above($h,$a);protected=$protected}
  [GptWidgetZOrderNative]::SetWindowPos($h,[IntPtr]::Zero,0,0,0,0,0x293)|Out-Null
 }
 foreach($row in $rows){
  if($row.ContainsKey('protected')){if(!$row.protected){throw ('Window protection failed: '+$row.case)}}
  elseif($row.ContainsKey('stableAfterSettling')){if(!$row.stableAfterSettling -or $row.layerChanges-gt 2){throw 'Music light and peer keep reordering after initial placement'}}
  elseif(!$row.stable){throw ('Repeated layer changes: '+$row.case)}
 }
 # Use a second real process for the same-host overlay path. Neither host is
 # the user's Codex, and both overlay surfaces are transparent and off-screen.
 foreach($h in @($lamp,$dialog,$foreign,$b)){[GptWidgetZOrderNative]::SetWindowPos($h,[IntPtr]::Zero,0,0,0,0,0x293)|Out-Null}
 Set-WidgetAboveHost $a $hostWindow|Out-Null
 $mailboxRoot=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-peer-layer-'+[Guid]::NewGuid().ToString('N'))
 $null=[IO.Directory]::CreateDirectory($mailboxRoot)
 $shell=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
 $args='-NoProfile -STA -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -PeerWorker -Mailbox "'+$mailboxRoot+'" -HostHandle '+$hostWindow.ToInt64()+' -LayerSource "'+$LayerSource+'"'
 $child=Start-Process -FilePath $shell -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $mailboxRoot 'worker.log') -RedirectStandardError (Join-Path $mailboxRoot 'worker-errors.log')
 $ready=Wait-PeerJson (Join-Path $mailboxRoot 'ready.json')
 if($ready.pid-ne $child.Id -or $ready.pid-eq $PID){throw 'Cross-process fixture identity mismatch'}
 $crossChanges=0
 for($i=0;$i-lt 60;$i++){
  $r=Set-WidgetAboveHost $a $hostWindow
  if(!$r.ok){throw 'Parent overlay lost the shared host'}
  if($r.changed){$crossChanges++}
  [IO.File]::WriteAllText((Join-Path $mailboxRoot ('request-'+$i+'.json')),'{}')
  $response=Wait-PeerJson (Join-Path $mailboxRoot ('response-'+$i+'.json'))
  if(!$response.ok -or $response.pid-ne $child.Id){throw 'Child overlay lost the shared host'}
  if($response.changed){$crossChanges++}
 }
 if($crossChanges){throw ('Cross-process overlays keep reordering: '+$crossChanges)}
 if([PeerLayerStudy]::GetForegroundWindow()-eq [IntPtr]([long]$ready.handle)){throw 'Child overlay acquired foreground focus'}
 $rows+=@{case='cross-process overlays';ticks=120;layerChanges=$crossChanges;stable=$true;parentPid=$PID;childPid=$child.Id}
 foreach($w in $fixtures){if([PeerLayerStudy]::GetForegroundWindow()-eq [Windows.Interop.WindowInteropHelper]::new($w).Handle){throw 'A test fixture acquired foreground focus'}}
 $result=@{passed=$true;crossProcessOwnerTested=$true;variant=[IO.Path]::GetFileNameWithoutExtension($LayerSource);cases=$rows;foregroundUnchanged=([PeerLayerStudy]::GetForegroundWindow()-eq $foreground);userWindowsMoved=$false;isolatedWindowsOnly=$true}
 if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
 Write-Output 'PASS: same-host peers, topmost host, known music light, dialog/foreign barriers and 120 cross-process layer ticks without churn'
}finally{
 if($child){
  try{
   [IO.File]::WriteAllText((Join-Path $mailboxRoot 'stop.flag'),'stop')
   if(!$child.WaitForExit(3000)){$child.Kill();$child.WaitForExit()}
  }finally{$child.Dispose()}
 }
 [array]::Reverse($fixtures);foreach($w in $fixtures){$w.Close()}
 if($mailboxRoot){
  $resolved=[IO.Path]::GetFullPath($mailboxRoot);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-peer-layer-*'){throw 'Unsafe peer-fixture cleanup path'}
  if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
 }
}
