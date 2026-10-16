param([string]$TestRoot=$PSScriptRoot,[string]$PreviewDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime\low-power-dock.ps1')
Add-Type -TypeDefinition @'
using System;
public static class GptWidgetNative {
 public struct Point {public int X,Y;}
 public static int CursorX,CursorY;
 public static bool GetCursorPos(out Point point){point=new Point{X=CursorX,Y=CursorY};return true;}
}
'@
$source=[IO.File]::ReadAllText((Join-Path $appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$easing=$ast.Find({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-eq 'Add-Type' -and $n.Extent.Text.Contains('public sealed class GptBezierEase')},$true)
. ([ScriptBlock]::Create($easing.Extent.Text))
foreach($name in @('Set-AnimatedValue','Animate-Value','Set-BubbleState','Set-Facing','Set-MenuVisible','Set-LowPowerReveal','Set-LowPowerMode','Sync-LowPowerDesktopMonitor','Enter-WidgetHover','Complete-WidgetHoverLeave','Close-LowPowerOnOutsideClick','Test-WidgetHit','Write-WidgetJson','Save-Settings')){
  $fn=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq $name},$true)
  . ([ScriptBlock]::Create($fn.Extent.Text))
}
function Assert($value,[string]$label){if(!$value){throw "FAIL: $label"}}
function Hide-Quota {$script:collapsed=$true;Set-BubbleState}
function Pump([int]$milliseconds=300){
  $frame=[Windows.Threading.DispatcherFrame]::new()
  $timer=[Windows.Threading.DispatcherTimer]::new()
  $timer.Interval=[TimeSpan]::FromMilliseconds($milliseconds)
  $timer.Tag=$frame
  $timer.Add_Tick({param($sender,$e)$sender.Stop();$sender.Tag.Continue=$false})
  $timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Save-Preview([string]$Name){
  if(!$PreviewDirectory){return}
  $null=New-Item -ItemType Directory -Path $PreviewDirectory -Force
  $stage=$script:window.FindName('AnimationStage')
  $stage.Measure([Windows.Size]::new(378,378));$stage.Arrange([Windows.Rect]::new(0,0,378,378));$stage.UpdateLayout()
  $render=[Windows.Media.Imaging.RenderTargetBitmap]::new(378,378,96,96,[Windows.Media.PixelFormats]::Pbgra32)
  $render.Render($stage)
  $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
  $stream=[IO.File]::Create((Join-Path $PreviewDirectory ($Name+'.png')))
  try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
$script:window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml'),[Text.Encoding]::UTF8))
$script:ui=@{}
foreach($name in @('Root','Girl','LowPowerViewport','LowPowerGirl','MenuButton','MinimizeButton','Bubble','Tail','TailNear','SceneText','PressScale','FacingScale','TextFacingScale','Refresh')){$script:ui[$name]=$script:window.FindName($name)}
$script:ui.Girl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $appDir 'assets\gpt-dragon-niang-bust.png'))
$script:ui.LowPowerGirl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $appDir 'assets\gpt-low-power.png'))
$script:context=[Windows.Controls.ContextMenu]::new()
$script:menuTimer=[Windows.Threading.DispatcherTimer]::new()
$script:hostEventTimer=[Windows.Threading.DispatcherTimer]::new()
$script:hostFollower=[pscustomobject]@{Suspends=0}
$script:hostFollower|Add-Member ScriptMethod Suspend {$this.Suspends++}
$script:dragMoves=0
function Move-LowPowerDrag([double]$X,[double]$Y){$script:dragMoves++;$script:lastDragPoint=@($X,$Y)}
$script:hideMenu=$false;$script:side='right';$script:lowPower=$false;$script:collapsed=$true
$script:offsetLeft=73;$script:offsetRight=91;$script:offsetBottom=45;$script:desktopLeft=-500;$script:desktopTop=100;$script:scale=1.4
$settingsFile=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-low-power-'+[Guid]::NewGuid().ToString('N')+'.json')
# Exercise the actual button and image-click handlers, not copies of their behavior.
foreach($prefix in @('$script:ui.MinimizeButton.Add_Click(')){
  $handler=$ast.Find({param($n)$n-is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith($prefix)},$true)
  . ([ScriptBlock]::Create($handler.Extent.Text))
}
foreach($variable in @('$lowPowerDown','$pressMove','$lowPowerUp')){
  $definition=$ast.Find({param($n)$n-is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text-eq $variable},$true)
  . ([ScriptBlock]::Create($definition.Extent.Text))
}
$script:ui.LowPowerViewport.Add_MouseLeftButtonDown($lowPowerDown)
$script:ui.LowPowerViewport.Add_MouseMove($pressMove)
$script:ui.LowPowerViewport.Add_MouseLeftButtonUp($lowPowerUp)
try{
  $script:window.Opacity=0;$script:window.Show();Set-BubbleState;Set-Facing
  Set-MenuVisible $true
  Assert ($script:ui.MinimizeButton.IsHitTestVisible -and $script:ui.MenuButton.IsHitTestVisible) 'normal hover shows both controls'
  Save-Preview 'normal-hover'
  $script:ui.MinimizeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert $script:lowPower 'minimize click enters low-power mode'
  Assert ($script:ui.Girl.Visibility-eq 'Collapsed' -and $script:ui.LowPowerViewport.Width-eq (14+$script:lowPowerLeadingInset) -and $script:ui.LowPowerViewport.Height-eq 208) 'side idle uses a narrow horizontal reveal'
  Assert (!$script:ui.MinimizeButton.IsHitTestVisible -and !$script:ui.MenuButton.IsHitTestVisible) 'idle has no controls'
  foreach($state in @('idle','peek','expanded')){
    Set-LowPowerReveal $state -Immediate
    [GptWidgetNative]::CursorX=50;[GptWidgetNative]::CursorY=60
    $down=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left)
    $down.RoutedEvent=[Windows.UIElement]::MouseLeftButtonDownEvent
    $script:ui.LowPowerViewport.RaiseEvent($down)
    Assert ($script:drag -and $script:ui.LowPowerViewport.IsMouseCaptured) "real mouse-down captures dragging in $state mode"
    [GptWidgetNative]::CursorX=52
    $move=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0)
    $move.RoutedEvent=[Windows.UIElement]::MouseMoveEvent
    $script:ui.LowPowerViewport.RaiseEvent($move)
    Assert (!$script:drag.moved) 'small hand movement remains a click'
    [GptWidgetNative]::CursorX=150;[GptWidgetNative]::CursorY=160
    $move=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0)
    $move.RoutedEvent=[Windows.UIElement]::MouseMoveEvent
    $script:ui.LowPowerViewport.RaiseEvent($move)
    Assert ($script:drag.moved -and $script:lastDragPoint[0]-eq 150 -and $script:lastDragPoint[1]-eq 160) "real mouse-move routes to edge dragging in $state mode"
    $up=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left)
    $up.RoutedEvent=[Windows.UIElement]::MouseLeftButtonUpEvent
    $script:ui.LowPowerViewport.RaiseEvent($up)
    Assert (!$script:drag -and !$script:ui.LowPowerViewport.IsMouseCaptured -and $script:lowPowerReveal-eq $state) 'drag release does not accidentally act as an expand click'
  }
  Assert ($script:dragMoves-eq 3 -and $script:hostFollower.Suspends-eq 3) 'all three low-power states support dragging'
  Set-LowPowerReveal 'idle' -Immediate
  $script:window.UpdateLayout()
  Assert (!(Test-WidgetHit ([Windows.Point]::new(200,200)))) 'hidden image cannot intercept clicks'
  $stripPoint=$script:ui.LowPowerViewport.TranslatePoint([Windows.Point]::new(($script:ui.LowPowerViewport.Width/2),100),$script:ui.Root)
  Assert (Test-WidgetHit $stripPoint) 'visible strip remains clickable'
  Save-Preview 'low-power-idle'
  Enter-WidgetHover;Pump
  Assert ([Math]::Abs($script:ui.LowPowerViewport.Width-(48+$script:lowPowerLeadingInset))-lt 0.01) 'side hover reveals a little more horizontally'
  Assert (!$script:ui.MenuButton.IsHitTestVisible) 'peek has no menu'
  Save-Preview 'low-power-peek'
  $event=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left)
  $event.RoutedEvent=[Windows.UIElement]::MouseLeftButtonUpEvent
  $script:drag=@{moved=$false}
  $script:ui.LowPowerViewport.RaiseEvent($event)
  Assert (!$script:ui.MinimizeButton.IsHitTestVisible) 'controls stay hidden during expansion'
  Pump
  Assert ($script:lowPowerReady -and [Math]::Abs($script:ui.LowPowerViewport.Height-208)-lt 0.01) 'click expands the full image'
  Assert ($script:ui.MenuButton.IsHitTestVisible -and $script:ui.MinimizeButton.IsHitTestVisible) 'full expansion exposes both controls'
  Save-Preview 'low-power-expanded-right'
  foreach($side in @('left','right')){
    $script:lowPowerDesktopDock=$null
    $script:side=$side;Set-Facing;$script:window.UpdateLayout()
    $stage=$script:window.FindName('AnimationStage')
    $min=$script:ui.MinimizeButton.TranslatePoint([Windows.Point]::new(12,12),$stage)
    $menu=$script:ui.MenuButton.TranslatePoint([Windows.Point]::new(12,12),$stage)
    Assert ($min.X-lt $menu.X) 'minimize stays visually left of the menu'
    $viewport=$script:ui.LowPowerViewport
    $bottom=$viewport.TranslatePoint([Windows.Point]::new(0,$viewport.Height),$stage)
    Assert ([Math]::Abs($bottom.Y-378)-lt 1) 'image is flush to the bottom within device-pixel rounding'
    $edge=if($side-eq 'left'){0}else{378}
    $corner=$viewport.TranslatePoint([Windows.Point]::new(208,208),$stage)
    Assert ([Math]::Abs($corner.X-$edge)-lt 1) 'image is flush to the appropriate side within device-pixel rounding'
  }
  $script:side='left';Set-Facing;Save-Preview 'low-power-expanded-left'
  $script:hideMenu=$true;Set-MenuVisible $true
  Assert (!$script:ui.MenuButton.IsHitTestVisible -and $script:ui.MinimizeButton.IsHitTestVisible) 'hide-menu preference cannot trap the pet in low-power mode'
  $script:hideMenu=$false
  $script:context.PlacementTarget=$script:ui.MinimizeButton;$script:context.IsOpen=$true
  Complete-WidgetHoverLeave
  Assert ($script:lowPowerReveal-eq 'expanded') 'open menu retains the expanded image'
  $script:context.IsOpen=$false;Complete-WidgetHoverLeave;Pump
  Assert ($script:lowPowerReveal-eq 'expanded' -and $script:ui.MinimizeButton.IsHitTestVisible) 'leaving across a transparent gap keeps the image and controls pinned'
  $inside=$script:ui.LowPowerViewport.PointToScreen([Windows.Point]::new(100,100))
  Close-LowPowerOnOutsideClick $inside
  Assert ($script:lowPowerReveal-eq 'expanded') 'clicking the pet is not an outside click'
  Close-LowPowerOnOutsideClick $inside $true
  Assert ($script:lowPowerReveal-eq 'idle') 'clicking an overlapping external window still retracts the pet'
  Set-LowPowerReveal 'expanded' -Immediate
  $outside=$script:ui.Root.PointToScreen([Windows.Point]::new(-100,-100))
  Close-LowPowerOnOutsideClick $outside;Pump
  Assert ($script:lowPowerReveal-eq 'idle' -and [Math]::Abs($script:ui.LowPowerViewport.Width-(14+$script:lowPowerLeadingInset))-lt 0.01) 'only an outside click retracts the expanded image'
  Set-LowPowerReveal 'expanded'
  Set-LowPowerReveal 'idle';Pump
  Assert (!$script:lowPowerReady -and !$script:ui.MinimizeButton.IsHitTestVisible) 'interrupted expansion cannot expose stale controls'
  Set-LowPowerReveal 'expanded' -Immediate
  $script:ui.MinimizeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert (!$script:lowPower -and $script:ui.Girl.Visibility-eq 'Visible' -and $script:ui.LowPowerViewport.Visibility-eq 'Collapsed') 'second minimize click restores normal pet'
  Assert ($script:offsetLeft-eq 73 -and $script:offsetRight-eq 91 -and $script:offsetBottom-eq 45 -and $script:desktopLeft-eq -500 -and $script:desktopTop-eq 100 -and $script:scale-eq 1.4) 'mode switches preserve placement and size preferences'
  Set-LowPowerMode $true
  $saved=Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8|ConvertFrom-Json
  Assert ($saved.lowPower -and $saved.bottom-eq 45 -and $saved.desktopLeft-eq -500) 'mode persists without overwriting normal placement'
  Assert (!(ConvertTo-WidgetDock @{edge='bottom';along=0})) 'legacy lower-left default is reset to side docking'
  Assert (!(ConvertTo-WidgetDock @{edge='bottom';along=1})) 'legacy lower-right default is reset to side docking'
  foreach($edge in @('top','bottom')){
    foreach($along in @(0,0.5,1)){
      $restored=ConvertTo-WidgetDock @{edge=$edge;along=$along;dragged=$true}
      Assert ($restored.edge-eq $edge -and $restored.along-eq $along -and $restored.dragged) 'deliberately dragged top/bottom positions survive reload'
    }
  }
  $script:designWidth=378;$script:designHeight=378;$script:displayScale=1
  $frame=[pscustomobject]@{Left=-1920;Top=0;Right=0;Bottom=1080}
  foreach($edge in @('left','right','top','bottom')){
    $dock=Get-LowPowerDock;$dock.edge=$edge;$dock.along=0.35
    Set-LowPowerLayout (Get-LowPowerGeometry $frame 1)
    foreach($state in @('idle','peek','expanded')){
      Set-LowPowerReveal $state
      Pump
      $extent=switch($state){'idle'{14.0};'peek'{48.0};'expanded'{208.0}}
      $viewport=$script:ui.LowPowerViewport;$geometry=$script:lowPowerGeometry
      if($edge-in @('left','right')){
        $expectedWidth=[Math]::Min(208.0,($extent+$script:lowPowerLeadingInset))
        Assert ([Math]::Abs($viewport.Width-$expectedWidth)-lt 0.01 -and [Math]::Abs($viewport.Height-208)-lt 0.01) "horizontal reveal dimensions on $edge in $state"
        Assert ([Math]::Abs([Windows.Controls.Canvas]::GetLeft($viewport)+$viewport.Width-$geometry.CanvasLeft-208)-lt 0.01) 'side reveal stays anchored to its edge'
        Assert ([Math]::Abs([Windows.Controls.Canvas]::GetTop($viewport)-$geometry.CanvasTop)-lt 0.01) 'horizontal reveal does not move vertically'
      }else{
        Assert ([Math]::Abs($viewport.Height-$extent)-lt 0.01 -and [Math]::Abs($viewport.Width-208)-lt 0.01) "vertical reveal dimensions on $edge in $state"
        $expectedTop=$geometry.CanvasTop+$(if($edge-eq 'bottom'){208-$extent}else{0})
        Assert ([Math]::Abs([Windows.Controls.Canvas]::GetTop($viewport)-$expectedTop)-lt 0.01) 'vertical reveal stays anchored to its edge'
        Assert ([Math]::Abs([Windows.Controls.Canvas]::GetLeft($viewport)-$geometry.CanvasLeft)-lt 0.01) 'vertical reveal does not move horizontally'
      }
      Assert ($script:ui.LowPowerGirl.Width-eq 208 -and $script:ui.LowPowerGirl.Height-eq 208) 'reveal clips the image without resizing it'
      Save-Preview ('reveal-'+$edge+'-'+$state)
    }
    Set-LowPowerReveal 'expanded' -Immediate
    $script:window.UpdateLayout()
    $stage=$script:window.FindName('AnimationStage')
    $min=$script:ui.MinimizeButton.TranslatePoint([Windows.Point]::new(12,12),$stage)
    $menu=$script:ui.MenuButton.TranslatePoint([Windows.Point]::new(12,12),$stage)
    Assert ($min.X-lt $menu.X -and $min.Y-ge 0 -and $min.Y-le 378) 'controls remain reachable on every dock edge'
    Save-Preview ('dock-'+$edge)
  }
  $dock.edge='right';Set-LowPowerLayout (Get-LowPowerGeometry $frame 1)
  Set-LowPowerReveal 'idle' -Immediate;Set-LowPowerReveal 'peek'
  $dock.edge='top';Set-LowPowerLayout (Get-LowPowerGeometry $frame 1);Pump
  Assert ($script:ui.LowPowerViewport.Width-eq 208 -and $script:ui.LowPowerViewport.Height-eq 48) 'crossing a corner cancels the old axis animation'
  $watcher=[GptWidgetOutsideClick]::new(([Windows.Interop.WindowInteropHelper]::new($script:window)).Handle)
  try{
    Assert (!$watcher.Enabled) 'outside-click hook is off by default'
    $watcher.SetEnabled($true);Assert $watcher.Enabled 'outside-click hook installs against a real HWND'
    $watcher.SetEnabled($false);Assert (!$watcher.Enabled) 'outside-click hook is removed when collapsed'
  }finally{$watcher.Dispose()}
  . ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime\color-theme.ps1'),[Text.Encoding]::UTF8)))
  function Get-QuotaRows {return @()}
  $script:widgetColors=@{original=@();phase=[Windows.Media.TranslateTransform]::new();running=$false;halo=[Windows.Shapes.Rectangle]::new();tint=[Windows.Shapes.Rectangle]::new()}
  Set-WidgetColorAnimation $true
  Assert $script:widgetColors.running 'fixture starts with flowing colors'
  Update-WidgetColorScene
  Assert (!$script:widgetColors.running -and $script:widgetColors.halo.Visibility-eq 'Collapsed' -and $script:widgetColors.tint.Visibility-eq 'Collapsed') 'low-power mode stops flowing colors and removes normal character overlays'
  Write-Output 'PASS: low-power click/hover/leave, clipping, animated control visibility, mirrored edge alignment, menu retention, restore and persistence'
}finally{
  if($script:lowPowerTimer){$script:lowPowerTimer.Stop()};$script:menuTimer.Stop();$script:hostEventTimer.Stop()
  $script:context.IsOpen=$false;$script:window.Close()
  foreach($file in @($settingsFile,($settingsFile+'.bak'))){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}}
}
