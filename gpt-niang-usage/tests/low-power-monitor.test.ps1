param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime\low-power-dock.ps1')
$source=[IO.File]::ReadAllText((Join-Path $appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$native=$ast.Find({param($n)$n-is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('public static class GptWidgetNative {')},$true)
Add-Type -TypeDefinition $native.Value
$null=[GptWidgetNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
foreach($name in @('Set-AnimatedValue','Set-BubbleState','Set-Facing','Set-MenuVisible','Set-LowPowerReveal','Set-LowPowerMode','Sync-LowPowerDesktopMonitor','Get-WidgetPlacementFrame')){
  $fn=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq $name},$true)
  . ([ScriptBlock]::Create($fn.Extent.Text))
}
function Save-Settings {throw 'The isolated test must not save real preferences'}
function Assert($condition,[string]$message){if(!$condition){throw $message}}
$script:window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml'),[Text.Encoding]::UTF8))
$script:ui=@{}
foreach($name in @('Root','Girl','LowPowerViewport','LowPowerGirl','MenuButton','MinimizeButton','Bubble','Tail','TailNear','SceneText','PressScale','FacingScale','TextFacingScale','Refresh')){$script:ui[$name]=$script:window.FindName($name)}
$script:ui.LowPowerGirl.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $appDir 'assets\gpt-low-power.png'))
$script:window.Opacity=0;$script:window.ShowActivated=$false;$script:window.ShowInTaskbar=$false
$script:followHost=$false;$script:side='right';$script:lowPower=$false;$script:hideMenu=$false
$script:designWidth=378;$script:designHeight=378;$script:displayScale=1
$screens=@([Windows.Forms.Screen]::AllScreens|Sort-Object {$_.Bounds.Left})
$stale=$screens[0].WorkingArea
$checks=0
try{
  $script:window.Show()
  $handle=([Windows.Interop.WindowInteropHelper]::new($script:window)).Handle
  foreach($screen in $screens){
    $area=$screen.WorkingArea
    foreach($fraction in @(0.2,0.7)){
      Set-LowPowerMode $false -NoSave
      # Move only an isolated invisible HWND; do not touch the real pet or Codex.
      $x=[int]($area.Left+($area.Width-500)*$fraction);$y=[int]($area.Top+($area.Height-500)/2)
      $null=[GptWidgetNative]::SetWindowPos($handle,[IntPtr]::Zero,$x,$y,0,0,0x15)
      $script:window.UpdateLayout()
      $script:window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
      $point=$script:ui.Girl.PointToScreen([Windows.Point]::new(($script:ui.Girl.ActualWidth/2),($script:ui.Girl.ActualHeight/2)))
      $expected=[Windows.Forms.Screen]::FromPoint([Drawing.Point]::new([int]$point.X,[int]$point.Y))
      Assert ($expected.DeviceName-eq $screen.DeviceName) 'Test pet was not moved onto the intended screen'
      # Both stored positions deliberately point at the old/left monitor.
      $script:desktopLeft=$stale.Left+20;$script:desktopTop=$stale.Top+20
      $script:lowPowerDesktopDock=@{edge='right';along=0.35;dragged=$true;monitorX=($stale.Left+100);monitorY=($stale.Top+100)}
      Set-LowPowerMode $true -NoSave
      $actual=Get-WidgetPlacementFrame
      Assert ($actual.Equals($expected.WorkingArea)) 'Entering low-power mode selected the stale monitor instead of the visible pet monitor'
      $dock=Get-LowPowerDock
      Assert ($dock.monitorX-eq $point.X -and $dock.monitorY-eq $point.Y) 'Monitor anchor was not refreshed from physical pet coordinates'
      Assert ($dock.edge-eq 'right' -and $dock.along-eq 0.35) 'Refreshing the monitor lost the deliberate dock position'
      Assert ($script:desktopLeft-eq ($stale.Left+20) -and $script:desktopTop-eq ($stale.Top+20)) 'Monitor synchronization overwrote the normal mode position'
      $geometry=Get-LowPowerGeometry $actual 1
      Assert ([Math]::Abs($geometry.ImageLeft+208-$area.Right)-lt 1) 'Low-power image did not dock at the current screen edge'
      # Startup/reapplying low-power mode must retain a subsequent dock drag.
      $dock.monitorX=$stale.Left+100;$dock.monitorY=$stale.Top+100
      Set-LowPowerMode $true -NoSave
      Assert ((Get-WidgetPlacementFrame).Equals($stale)) 'Reapplying low-power mode overwrote its saved monitor'
      $checks++
    }
  }
  Set-LowPowerMode $false -NoSave
  $script:followHost=$true
  $script:lowPowerDesktopDock=@{edge='left';along=0.5;dragged=$false;monitorX=17;monitorY=23}
  Set-LowPowerMode $true -NoSave
  Assert ($script:lowPowerDesktopDock.monitorX-eq 17 -and $script:lowPowerDesktopDock.monitorY-eq 23) 'Application mode changed the desktop monitor selection'
  Write-Output "PASS: $checks physical-window entry transitions across $($screens.Count) monitors ignore stale docking data, preserve explicit dock positions, and leave application/startup behavior intact"
}finally{$script:window.Close()}
