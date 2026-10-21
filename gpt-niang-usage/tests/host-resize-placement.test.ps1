param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
$app=Split-Path $TestRoot -Parent
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
$source=[IO.File]::ReadAllText((Join-Path $app 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Widget source did not parse'}
$native=$ast.Find({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-eq 'Add-Type' -and $n.Extent.Text.Contains('class GptWidgetNative')},$true)
. ([scriptblock]::Create($native.Extent.Text))
. (Join-Path $app 'runtime/host-follow.ps1')
$previousDpi=[GptWidgetNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
foreach($name in @('Get-WidgetLayoutScale','Get-WidgetPlacementFrame','Get-WidgetPlacementDpi','Test-WidgetPlacementFrame','Set-WidgetPixelSize','Set-WidgetIndependentLayout','Set-Appearance','Set-Facing','Limit-WidgetHorizontalPosition','Limit-WidgetVerticalPosition','Get-WidgetCharacterPixelBounds')){
 $fn=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq $name},$true)
 if($fn){. ([scriptblock]::Create($fn.Extent.Text))}
}
$tick=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq 'Tick-Widget'},$true).Extent.Text
$start=$tick.IndexOf('      $w=[int]($script:designWidth*');$end=$tick.IndexOf('      Update-WidgetMusicPlacement',$start)
if($start-lt 0 -or $end-lt 0){throw 'Missing production placement block'}
$place=[scriptblock]::Create($tick.Substring($start,$end-$start))
function Sync-WidgetCharacterColors {}
function Test-WidgetMusicActive {return $false}
function Assert($ok,[string]$message){$script:checks++;if(!$ok){throw $message}}
function Pump-Layout {
 $queue=[Windows.Threading.DispatcherFrame]::new();$timer=[Windows.Threading.DispatcherTimer]::new()
 $timer.Interval=[TimeSpan]::FromMilliseconds(20)
 $handler={param($sender,$event)$sender.Stop();$queue.Continue=$false}.GetNewClosure()
 $timer.Add_Tick($handler);$timer.Start();[Windows.Threading.Dispatcher]::PushFrame($queue);$timer.Remove_Tick($handler)
}
function Character-Bounds {
 Assert ($script:ui.Girl.ActualWidth-gt 0 -and $script:ui.Girl.ActualHeight-gt 0) 'Test character has not been laid out'
 $a=$script:ui.Girl.PointToScreen([Windows.Point]::new(0,0))
 $b=$script:ui.Girl.PointToScreen([Windows.Point]::new($script:ui.Girl.ActualWidth,$script:ui.Girl.ActualHeight))
 return @{Left=[Math]::Min($a.X,$b.X);Right=[Math]::Max($a.X,$b.X);Top=[Math]::Min($a.Y,$b.Y);Bottom=[Math]::Max($a.Y,$b.Y)}
}
function Assert-InHost([string]$Label){
 $r=[GptWidgetNative]::Frame($script:hostHandle);$b=Character-Bounds
 Assert ($b.Left-ge $r.Left-1 -and $b.Right-le $r.Right+1 -and $b.Top-ge $r.Top-1 -and $b.Bottom-le $r.Bottom+1) ($Label+': character escaped host; character='+($b|ConvertTo-Json -Compress)+' host='+($r|ConvertTo-Json -Compress))
}
function Place-Widget {
 Pump-Layout
 $script:window.UpdateLayout()
 $frame=Get-WidgetPlacementFrame;$dpi=Get-WidgetPlacementDpi
 $null=Set-WidgetPixelSize $dpi
 . $place
}
$hostWindow=$null;$script:window=$null;$script:hostFollower=$null;$script:checks=0
try{
 $hostWindow=[Windows.Window]::new();$hostWindow.WindowStyle='None';$hostWindow.ResizeMode='NoResize';$hostWindow.AllowsTransparency=$true;$hostWindow.Background=[Windows.Media.Brushes]::Transparent;$hostWindow.Opacity=0;$hostWindow.ShowInTaskbar=$false;$hostWindow.ShowActivated=$false;$hostWindow.Show()
 $script:hostHandle=[Windows.Interop.WindowInteropHelper]::new($hostWindow).Handle
 $script:window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $app 'widget.xaml'),[Text.Encoding]::UTF8))
 $script:window.Opacity=0;$script:widgetHandle=[Windows.Interop.WindowInteropHelper]::new($script:window).EnsureHandle()
 $script:ui=@{};foreach($name in @('Root','Girl','Bubble','Tail','TailNear','MenuButton','Refresh','FacingScale','TextFacingScale','PressScale')){$script:ui[$name]=$script:window.FindName($name)}
 $script:ui.Girl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $app 'assets/gpt-dragon-niang-bust.png'))
 $script:designWidth=378;$script:designHeight=378;$script:followHost=$true;$script:hostEventTimer=$null;$script:context=@{IsOpen=$false}
 $script:hostFollower=[GptWidgetHostFollower]::new($script:widgetHandle)
 $area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea;$large=$area.Width;$small=[int]($large*0.65);$height=[int]($area.Height*0.85)
 $null=[GptWidgetNative]::SetWindowPos($script:hostHandle,[IntPtr]::Zero,$area.Left,($area.Top+30),$large,$height,0x14)
 $script:scale=0.8;$script:bubbleScale=1;$script:displayScale=0;$script:side='right';$script:anchor='right';$script:offsetLeft=0;$script:offsetRight=-14;$script:offsetBottom=-14
 Set-Appearance;Place-Widget
 Assert (!$script:window.IsVisible) 'Initial placement unexpectedly showed the widget'
 # Like the runtime, refresh physical size after WPF connects its DPI target.
 $script:window.Show();Pump-Layout;Place-Widget;Assert-InHost 'First connected placement'
 foreach($sizing in @(@(0.8,1.0),@(0.6,1.4),@(1.0,1.0))){
  $script:scale=$sizing[0];$script:bubbleScale=$sizing[1];$script:displayScale=0
  foreach($facing in @('right','left')){
   $script:side=$facing
   foreach($anchorName in @('free','left','right')){
    $null=[GptWidgetNative]::SetWindowPos($script:hostHandle,[IntPtr]::Zero,$area.Left,($area.Top+30),$large,$height,0x14)
    $dpi=Get-WidgetPlacementDpi;$layout=Get-WidgetLayoutScale
    $script:anchor=$anchorName;$script:offsetRight=-14*$layout;$script:offsetBottom=-14*$layout
    $script:offsetLeft=if($facing-eq 'right'){($large/ $dpi)-364*$layout}else{-14*$layout}
    Set-Appearance;Place-Widget
    $prefs=@($script:offsetLeft,$script:offsetRight,$script:offsetBottom)-join ','
    Assert-InHost 'Original frame'
    $initial=[GptWidgetNative+Rect]::new();$null=[GptWidgetNative]::GetWindowRect($script:widgetHandle,[ref]$initial)
    $null=[GptWidgetNative]::SetWindowPos($script:hostHandle,[IntPtr]::Zero,$area.Left,($area.Top+30),$small,$height,0x14)
    Place-Widget
    Assert-InHost ('Shrink '+$anchorName+'/'+$facing)
    Assert ((@($script:offsetLeft,$script:offsetRight,$script:offsetBottom)-join ',')-eq $prefs) 'Resize rewrote saved drag offsets'
    $null=[GptWidgetNative]::SetWindowPos($script:hostHandle,[IntPtr]::Zero,$area.Left,($area.Top+30),$large,$height,0x14)
    Place-Widget
    $restored=[GptWidgetNative+Rect]::new();$null=[GptWidgetNative]::GetWindowRect($script:widgetHandle,[ref]$restored)
    Assert ($restored.Left-eq $initial.Left -and $restored.Top-eq $initial.Top) 'Expanding did not restore the requested position'
    # Native event following must constrain before a PowerShell layout tick too.
    $null=[GptWidgetNative]::SetWindowPos($script:hostHandle,[IntPtr]::Zero,$area.Left,($area.Top+30),$small,$height,0x14)
    $null=$script:hostFollower.Synchronize()
    Assert-InHost ('Immediate native shrink '+$anchorName+'/'+$facing)
    # Moving an unchanged host off screen must retain its relative placement.
    Place-Widget;$before=[GptWidgetNative+Rect]::new();$null=[GptWidgetNative]::GetWindowRect($script:widgetHandle,[ref]$before)
    $null=[GptWidgetNative]::SetWindowPos($script:hostHandle,[IntPtr]::Zero,($area.Left-200),($area.Top+30),$small,$height,0x14)
    $null=$script:hostFollower.Synchronize();$after=[GptWidgetNative+Rect]::new();$null=[GptWidgetNative]::GetWindowRect($script:widgetHandle,[ref]$after)
    Assert ($after.Left-eq $before.Left-200 -and $after.Top-eq $before.Top) 'Moving partly off screen changed the host-relative placement'
   }
  }
 }
 Write-Output ('PASS: '+$script:checks+' real WPF/native placement checks: bottom flush, shrink/grow, native resize, both facings, all anchors, independent scales and unchanged preferences')
}finally{
 if($script:hostFollower){$script:hostFollower.Dispose()}
 if($script:window){$script:window.Close()}
 if($hostWindow){$hostWindow.Close()}
 $null=[GptWidgetNative]::SetThreadDpiAwarenessContext($previousDpi)
}
