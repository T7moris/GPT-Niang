param([string]$TestRoot=$PSScriptRoot,[string]$ResultFile)
$Candidate=$true
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
$app=Split-Path $TestRoot -Parent
$source=[IO.File]::ReadAllText((Join-Path $app 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Source parse failed'}
. (Join-Path $app 'runtime/host-follow.ps1')
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GptWidgetNative {
 public struct Rect {public int Left,Top,Right,Bottom;}
 public static Rect Host;
 public static uint Dpi=96;
 public static Rect Frame(IntPtr handle){return Host;}
 public static bool IsWindow(IntPtr handle){return true;}
 public static uint GetDpiForWindow(IntPtr handle){return Dpi;}
}
public static class FixedPositionProbeNative {
 [StructLayout(LayoutKind.Sequential)] public struct Rect {public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int z,uint flags);
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
 [DllImport("user32.dll")] public static extern int GetWindowRgn(IntPtr h,IntPtr region);
 [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int l,int t,int r,int b);
 [DllImport("gdi32.dll")] public static extern int GetRgnBox(IntPtr region,out Rect r);
 [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr h);
}
'@
$null=[FixedPositionProbeNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
foreach($name in @('Get-WidgetLayoutScale','Get-WidgetPlacementFrame','Get-WidgetPlacementDpi','Test-WidgetPlacementFrame','Get-WidgetVisibleFrame','Set-Appearance','Set-WidgetPixelSize','Set-WidgetIndependentLayout','Set-Facing','Limit-WidgetHorizontalPosition','Limit-WidgetVerticalPosition','Get-WidgetCharacterPixelBounds')){
 $fn=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq $name},$true)
 if(!$fn){throw ('Missing '+$name)}
 . ([scriptblock]::Create($fn.Extent.Text))
}
function Sync-WidgetCharacterColors {}
$tick=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq 'Tick-Widget'},$true).Extent.Text
$start=$tick.IndexOf('      $w=[int]($script:designWidth*')
$end=$tick.IndexOf('      $position=', $start)
if($start-lt 0 -or $end-lt 0){throw 'Missing production placement block'}
$place=[scriptblock]::Create($tick.Substring($start,$end-$start))
$script:window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $app 'widget.xaml'),[Text.Encoding]::UTF8))
$script:window.Opacity=0;$script:window.Left=-20000;$script:window.Top=-20000;$script:window.Show()
$script:ui=@{};foreach($name in @('Root','Girl','Bubble','Tail','TailNear','MenuButton','Refresh','FacingScale','TextFacingScale','PressScale')){$script:ui[$name]=$script:window.FindName($name)}
$script:ui.Girl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $app 'assets/gpt-dragon-niang-bust.png'))
$script:side='right'
$layoutFrame=[Windows.Threading.DispatcherFrame]::new();$layoutTimer=[Windows.Threading.DispatcherTimer]::new();$layoutTimer.Interval=[TimeSpan]::FromMilliseconds(20)
$layoutTimer.Add_Tick({param($sender,$event)$sender.Stop();$layoutFrame.Continue=$false});$layoutTimer.Start();[Windows.Threading.Dispatcher]::PushFrame($layoutFrame)
$script:hostHandle=[IntPtr]1;$script:followHost=$true;$script:hostEventTimer=$null
$script:designWidth=378;$script:designHeight=378;$script:scale=0.6;$script:bubbleScale=1
$script:offsetLeft=113.6;$script:offsetRight=80.4;$script:offsetBottom=208.8
$area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$hostW=[Math]::Min(900,$area.Width-80);$hostH=[Math]::Min(650,$area.Height-80)
$normalX=$area.Left+40;$normalY=$area.Top+40
$cases=@(
 @{name='normal';x=$normalX;y=$normalY},
 @{name='translate';x=($normalX+20);y=($normalY+20)},
 @{name='bottom-strip';x=$normalX;y=($area.Bottom-120)},
 @{name='right-strip';x=($area.Right-120);y=$normalY},
 @{name='top-strip';x=$normalX;y=($area.Top-$hostH+120)},
 @{name='left-strip';x=($area.Left-$hostW+120);y=$normalY},
 @{name='return';x=$normalX;y=$normalY}
)
$rows=@()
foreach($dpiFactor in @(1.0,1.5)){
 [GptWidgetNative]::Dpi=[uint32]($dpiFactor*96)
 foreach($anchorName in @('free','left','right')){
  $script:anchor=$anchorName
  foreach($case in $cases){
   $r=[GptWidgetNative+Rect]::new();$r.Left=$case.x;$r.Top=$case.y;$r.Right=$r.Left+$hostW;$r.Bottom=$r.Top+$hostH
   [GptWidgetNative]::Host=$r;$script:displayScale=1
   Set-Appearance
   $script:window.UpdateLayout()
   $frame=Get-WidgetPlacementFrame;$dpi=Get-WidgetPlacementDpi
   . $place
   $requested=378*$dpiFactor
   $expectedX=if($anchorName-eq 'right'){$r.Right-$requested-$script:offsetRight*$dpi}else{$r.Left+$script:offsetLeft*$dpi}
   $expectedY=$r.Bottom-$requested-$script:offsetBottom*$dpi
   $badScale=[Math]::Abs($script:displayScale-1)-gt 0.00001
   $badPosition=[Math]::Abs($x-$expectedX)-gt 1 -or [Math]::Abs($y-$expectedY)-gt 1
   $rows+=@{case=$case.name;anchor=$anchorName;dpi=$dpiFactor;displayScale=$script:displayScale;computedCharacterWidthPixels=(208*0.6*$script:displayScale*$dpiFactor);relative=@(($x-$r.Left),($y-$r.Top));expectedRelative=@(($expectedX-$r.Left),($expectedY-$r.Top));unwantedScale=$badScale;unwantedPosition=$badPosition}
  }
 }
}
$script:window.Close()
$nativeRows=@();$dummyHost=$null;$dummyWidget=$null;$follower=$null
try{
 $dummyHost=[Windows.Window]::new();$dummyWidget=[Windows.Window]::new()
 foreach($win in @($dummyHost,$dummyWidget)){$win.WindowStyle='None';$win.ResizeMode='NoResize';$win.AllowsTransparency=$true;$win.Background=[Windows.Media.Brushes]::Transparent;$win.Opacity=0;$win.ShowInTaskbar=$false;$win.ShowActivated=$false;$win.Left=-20000;$win.Top=-20000;$win.Show()}
 $hostHwnd=([Windows.Interop.WindowInteropHelper]::new($dummyHost)).Handle
 $widgetHwnd=([Windows.Interop.WindowInteropHelper]::new($dummyWidget)).Handle
 $follower=[GptWidgetHostFollower]::new($widgetHwnd)
 foreach($anchorName in @('free','left','right')){
  foreach($case in $cases){
   $null=[FixedPositionProbeNative]::SetWindowPos($hostHwnd,[IntPtr]::Zero,$case.x,$case.y,$hostW,$hostH,0x14)
   $null=[FixedPositionProbeNative]::SetWindowPos($widgetHwnd,[IntPtr]::Zero,$normalX,$normalY,378,378,0x14)
   $hr=[FixedPositionProbeNative+Rect]::new();$null=[FixedPositionProbeNative]::GetWindowRect($hostHwnd,[ref]$hr)
   $follower.Configure($hostHwnd,$hr.Left,$hr.Top,$hr.Right,$hr.Bottom,378,378,114,80,209,$anchorName,$true)
   $null=$follower.Synchronize()
   $wr=[FixedPositionProbeNative+Rect]::new();$null=[FixedPositionProbeNative]::GetWindowRect($widgetHwnd,[ref]$wr)
   $wantX=if($anchorName-eq 'right'){$hr.Right-378-80}else{$hr.Left+114};$wantY=$hr.Bottom-378-209
   $positionOk=$wr.Left-eq $wantX -and $wr.Top-eq $wantY
   $sizeOk=($wr.Right-$wr.Left)-eq 378 -and ($wr.Bottom-$wr.Top)-eq 378
   $region=[FixedPositionProbeNative]::CreateRectRgn(0,0,0,0)
   $rr=[FixedPositionProbeNative+Rect]::new()
   try{$kind=[FixedPositionProbeNative]::GetWindowRgn($widgetHwnd,$region);$null=[FixedPositionProbeNative]::GetRgnBox($region,[ref]$rr)}finally{$null=[FixedPositionProbeNative]::DeleteObject($region)}
   $screenArea=[Windows.Forms.Screen]::FromPoint([Drawing.Point]::new(($wantX+189),($wantY+189))).WorkingArea
   $hostRectangle=[Drawing.Rectangle]::new($hr.Left,$hr.Top,($hr.Right-$hr.Left),($hr.Bottom-$hr.Top))
   $visibleHost=[Drawing.Rectangle]::Intersect($hostRectangle,$screenArea)
   $wantedRectangle=[Drawing.Rectangle]::new($wantX,$wantY,378,378)
   $wantedVisible=[Drawing.Rectangle]::Intersect($wantedRectangle,$visibleHost)
   $expectedRegion=if($wantedVisible.Width-le 0 -or $wantedVisible.Height-le 0){@(0,0,0,0)}else{@(($wantedVisible.Left-$wantX),($wantedVisible.Top-$wantY),($wantedVisible.Right-$wantX),($wantedVisible.Bottom-$wantY))}
   $actualRegion=@($rr.Left,$rr.Top,$rr.Right,$rr.Bottom)
   $regionOk=($actualRegion-join ',')-eq ($expectedRegion-join ',')
   $nativeRows+=@{case=$case.name;anchor=$anchorName;positionOk=$positionOk;sizeOk=$sizeOk;regionOk=$regionOk;regionKind=$kind;region=$actualRegion;expectedRegion=$expectedRegion}
  }
 }
}finally{if($follower){$follower.Dispose()};if($dummyWidget){$dummyWidget.Close()};if($dummyHost){$dummyHost.Close()}}
$failures=@($rows|Where-Object {$_.unwantedScale -or $_.unwantedPosition}).Count
$nativeFailures=@($nativeRows|Where-Object {!$_.positionOk -or !$_.sizeOk -or !$_.regionOk}).Count
if($Candidate -and ($failures -or $nativeFailures)){throw "Candidate failures: calculations=$failures native=$nativeFailures"}
if(!$Candidate -and !$failures){throw 'Original edge behavior did not reproduce'}
$label=if($Candidate){'candidate'}else{'original'}
$report=@{date='2026-10-16';variant=$label;source=$app;calculationCases=$rows;nativeCases=$nativeRows;calculationFailures=$failures;nativeFailures=$nativeFailures;screenCount=[Windows.Forms.Screen]::AllScreens.Count;installed=$false;liveCodexWindowMoved=$false;limits=@('Production calculations use synthetic host frames and stub layout setters.','Native following uses newly created invisible WPF test windows; actual user mouse and multiple physical screens not tested.','No existing widget or settings modified.')}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($report|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))}
Write-Output "PASS: fixed relative position: $($rows.Count) calculation cases ($failures unwanted results); $($nativeRows.Count) real HWND cases ($nativeFailures unwanted results). No installed widget changes."
