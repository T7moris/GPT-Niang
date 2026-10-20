param([string]$TestRoot=$PSScriptRoot,[string]$ResultFile)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
$app=Split-Path $TestRoot -Parent
. (Join-Path $app 'runtime/completion-notifications.ps1')
. (Join-Path $app 'runtime/host-layer.ps1')
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class CompletionRestoreProbe {
 [DllImport("user32.dll")]public static extern IntPtr GetWindow(IntPtr h,uint command);
 [DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int command);
 [DllImport("user32.dll")]public static extern bool IsIconic(IntPtr h);
 public static bool Above(IntPtr upper,IntPtr lower){
  for(IntPtr h=GetWindow(lower,3);h!=IntPtr.Zero;h=GetWindow(h,3))if(h==upper)return true;
  return false;
 }
}
'@
$script:checks=0;$script:cases=@();$script:hostFollower=$null
function Assert($Value,[string]$Message){$script:checks++;if(!$Value){throw $Message}}
function Reset-WidgetAutoQuoteSchedule {}
function Save-Settings {}
function Test-WidgetCompletionHostForeground{return $script:testForeground}
function Test-CompletionFullscreen([IntPtr]$Handle){return $script:testFullscreen}
function Hide-Quota([switch]$KeepCompletion){
 if(!$KeepCompletion){Dismiss-CompletionNotification}
 $script:collapsed=$true;$script:sceneDeadline=0
}
function Drain([int]$Ms){
 $script:drainFrame=[Windows.Threading.DispatcherFrame]::new()
 $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds($Ms)
 $timer.Add_Tick({param($sender,$event)$sender.Stop();$script:drainFrame.Continue=$false})
 $timer.Start();[Windows.Threading.Dispatcher]::PushFrame($script:drainFrame)
}
function New-Fixture([string]$Title,[bool]$Topmost=$false){
 $w=[Windows.Window]::new();$w.Title='Completion layer regression: '+$Title
 $w.Width=120;$w.Height=120;$w.ShowActivated=$false;$w.ShowInTaskbar=$false;$w.Opacity=0
 $w.Topmost=$Topmost;$w.Show();return $w
}
function Handle($W){return ([Windows.Interop.WindowInteropHelper]::new($W)).Handle}
function Place([IntPtr]$W,[IntPtr]$After){
 Assert ([CompletionWindowLayer]::SetWindowPos($W,$After,0,0,0,0,0x213)) 'Fixture placement failed'
}
function Rect-Key([IntPtr]$Handle){
 $r=New-Object CompletionWindowLayer+Rect
 $null=[CompletionWindowLayer]::GetWindowRect($Handle,[ref]$r)
 return "$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
}
function Snapshot($Handles){
 $pairs=@();$rects=@{};$styles=@{}
 foreach($h in $Handles){
  if(![CompletionWindowLayer]::IsWindow($h)){continue}
  $rects[$h.ToInt64()]=Rect-Key $h
  $styles[$h.ToInt64()]=[CompletionWindowLayer]::GetWindowLongPtr($h,-20)
  foreach($other in $Handles){
   if($h-ne $other -and [CompletionWindowLayer]::IsWindow($other)){
    $pairs+=@{upper=$h;lower=$other;above=[CompletionRestoreProbe]::Above($h,$other)}
   }
  }
 }
 return @{pairs=$pairs;rects=$rects;styles=$styles}
}
function Assert-Snapshot($Snapshot,[string]$Case){
 foreach($pair in $Snapshot.pairs){
  Assert ([CompletionRestoreProbe]::Above($pair.upper,$pair.lower)-eq $pair.above) ($Case+': changed another window stacking order')
 }
 foreach($key in $Snapshot.rects.Keys){
  Assert ((Rect-Key ([IntPtr]$key))-eq $Snapshot.rects[$key]) ($Case+': moved or resized another window')
  Assert ([CompletionWindowLayer]::GetWindowLongPtr([IntPtr]$key,-20)-eq $Snapshot.styles[$key]) ($Case+': changed another window extended style')
 }
}
foreach($case in @('timeout','return','fullscreen-exit','disable','originally-hidden','owner-minimized','owner-closed','cover-closed','cover-order-changed','host-already-topmost','desktop-normal','desktop-topmost','repeat')){
 $fixtures=@();$script:window=$null
 try{
  Initialize-CompletionNotificationState @{taskCompletionBubble=$true}
  $script:testForeground=$false;$script:testFullscreen=($case-eq 'fullscreen-exit')
  $script:collapsed=$false;$script:bubbleMode='completion';$script:sceneDeadline=0
  $topmost=$case-in @('host-already-topmost','desktop-topmost')
  $desktop=$case-in @('desktop-normal','desktop-topmost')
  $hostFixture=New-Fixture 'host' $topmost;$fixtures+=,$hostFixture
  $middle=New-Fixture 'middle' $topmost;$fixtures+=,$middle
  $cover=New-Fixture 'cover' $topmost;$fixtures+=,$cover
  $script:window=New-Fixture 'widget';$fixtures+=,$script:window
  $owner=Handle $hostFixture;$middleHandle=Handle $middle;$coverHandle=Handle $cover
  $script:widgetHandle=Handle $script:window
  if($desktop){Set-WidgetDesktopLayer $script:widgetHandle $topmost}
  else{$null=Set-WidgetAboveHost $script:widgetHandle $owner}
  Place $owner $(if($topmost){[IntPtr](-1)}else{[IntPtr]::Zero})
  Place $script:widgetHandle $(if($topmost){[IntPtr](-1)}else{[IntPtr]::Zero})
  Place $middleHandle $(if($topmost){[IntPtr](-1)}else{[IntPtr]::Zero})
  Place $coverHandle $(if($topmost){[IntPtr](-1)}else{[IntPtr]::Zero})
  if($case-eq 'originally-hidden'){$script:window.Hide()}
  $beforeVisible=$script:window.IsVisible
  $beforeRect=Rect-Key $script:widgetHandle
  $beforeStyle=[CompletionWindowLayer]::GetWindowLongPtr($script:widgetHandle,-20)
  $foreground=[CompletionWindowLayer]::GetForegroundWindow()
  $handles=@($owner,$middleHandle,$coverHandle)
  $beforeStart=Snapshot $handles
  $repeats=if($case-eq 'repeat'){8}else{1}
  foreach($iteration in 1..$repeats){
   Assert (Start-TemporaryCompletion) ($case+': reminder did not start')
   Assert-Snapshot $beforeStart ($case+' start')
   Assert ((Rect-Key $script:widgetHandle)-eq $beforeRect) ($case+': reminder moved the widget')
   Assert ([CompletionRestoreProbe]::Above($script:widgetHandle,$coverHandle)) ($case+': reminder failed to rise above the cover')
   if($case-eq 'owner-minimized'){
    # Minimize the fixture without activating a different test window.
    [void][CompletionRestoreProbe]::ShowWindow($owner,7)
    Assert ([CompletionRestoreProbe]::IsIconic($owner)) 'Fixture host did not minimize without activation'
   }
   if($case-eq 'owner-closed'){$hostFixture.Close()}
   if($case-eq 'cover-closed'){$cover.Close()}
   if($case-eq 'cover-order-changed'){Place $middleHandle $(if($topmost){[IntPtr](-1)}else{[IntPtr]::Zero})}
   $beforeEnd=Snapshot $handles
   if($case-eq 'return'){$script:testForeground=$true;Drain 160}
   elseif($case-eq 'fullscreen-exit'){$script:testFullscreen=$false;Drain 160}
   elseif($case-eq 'disable'){Set-CompletionNotificationEnabled $false}
   else{$script:sceneDeadline=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-1;Drain 160}
   Assert (!$script:completionTemporary) ($case+': temporary layer remained')
   Assert-Snapshot $beforeEnd ($case+' end')
   Assert ((Rect-Key $script:widgetHandle)-eq $beforeRect) ($case+': restoration moved or resized the widget')
   Assert ([CompletionWindowLayer]::GetWindowLongPtr($script:widgetHandle,-20)-eq $beforeStyle) ($case+': widget style was not restored')
   $expectedOwner=if(!$desktop -and [CompletionWindowLayer]::IsWindow($owner)){$owner}else{[IntPtr]::Zero}
   Assert ([CompletionWindowLayer]::GetWindowLongPtr($script:widgetHandle,-8)-eq $expectedOwner) ($case+': owner was not safely restored')
   if($case-ne 'owner-minimized'){Assert ($script:window.IsVisible-eq $beforeVisible) ($case+': widget visibility was not restored')}
   foreach($covering in @($middleHandle,$coverHandle)){
    if([CompletionWindowLayer]::IsWindow($covering)){
     Assert ([CompletionRestoreProbe]::Above($covering,$script:widgetHandle)) ($case+': widget was not returned behind the covering window')
    }
   }
   if(!$desktop -and [CompletionWindowLayer]::IsWindow($owner)){
    $null=Set-WidgetAboveHost $script:widgetHandle $owner
    Assert-Snapshot $beforeEnd ($case+' next follow tick')
   }
   $currentForeground=[CompletionWindowLayer]::GetForegroundWindow()
   Assert (!(@($script:widgetHandle,$owner,$middleHandle,$coverHandle)-contains $currentForeground)) ($case+': a test window stole the foreground')
   $script:collapsed=$false;$script:sceneDeadline=0
  }
  $script:cases+=@{case=$case;passed=$true;cycles=$repeats}
 }finally{
  Stop-TemporaryCompletion
  foreach($w in @($fixtures|Select-Object -Last 1)+@($fixtures|Select-Object -SkipLast 1)){if($w){$w.Close()}}
 }
}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,(@{checks=$script:checks;cases=$script:cases;passed=$true;actualUserWindowsMoved=$false;crossProcessOwnerTested=$false}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
Write-Output ('PASS: '+$script:checks+' completion layer checks in 13 scenarios / 20 cycles; covered host order, foreground, coordinates, timeout, early exit, hidden/minimized/closed owners, topmost and desktop modes')
