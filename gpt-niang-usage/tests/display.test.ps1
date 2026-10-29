param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime\sharp-text.ps1')
$script:ui=@{}
. (Join-Path $appDir 'runtime\host-follow.ps1')
$source=[IO.File]::ReadAllText((Join-Path $appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Widget syntax errors'}
$native=$ast.Find({param($n) $n-is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('public static class GptWidgetNative {')},$true)
Add-Type -TypeDefinition $native.Value
try{[GptWidgetNative]::SetThreadDpiAwarenessContext([IntPtr](-4))|Out-Null}catch{}
$definition=$ast.Find({param($n) $n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq 'Set-WidgetPixelSize'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
# Reject reintroducing the feedback loop in either dragging or timer placement.
if($source-match '\$script:window\.(Width|Height)\s*\*\s*\$dpi'){throw 'Native size must not be derived from mutable WPF dimensions'}
if($source-match 'SetWindowPos\(\$script:widgetHandle,[^\r\n]*0x14\)'){throw 'WPF must own widget sizing'}
function Pump-Display {
 $script:window.UpdateLayout()
 $script:window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
}
$script:designWidth=378;$script:designHeight=378
$script:window=New-Object Windows.Window
$script:window.WindowStyle='None';$script:window.ResizeMode='NoResize'
$script:window.AllowsTransparency=$true;$script:window.Background=[Windows.Media.Brushes]::Transparent
$script:window.Opacity=0;$script:window.ShowInTaskbar=$false;$script:window.ShowActivated=$false
$handle=([Windows.Interop.WindowInteropHelper]::new($script:window)).EnsureHandle()
$checks=0
try{
 $script:window.Show()
 foreach($screen in [Windows.Forms.Screen]::AllScreens){
  $area=$screen.WorkingArea
  [GptWidgetNative]::SetWindowPos($handle,[IntPtr]::Zero,($area.Left+20),($area.Top+20),0,0,0x15)|Out-Null
  Pump-Display
  foreach($dpi in @(1,1.25,1.5,2,2.5)){
   foreach($scale in @(0.6,1,2.5)){
    # WPF Slider.Value and persisted scale are doubles. An integer first
    # argument selects Math.Min(int,int) and rounds a fractional work-area fit.
    $script:displayScale=[Math]::Min([double]$scale,[Math]::Min($area.Width,$area.Height)/378/$dpi)
    # The old loop grew on every update when host and renderer DPI differed.
    foreach($iteration in 1..8){
     $pixels=Set-WidgetPixelSize $dpi
     Pump-Display
     $r=New-Object GptWidgetNative+Rect
     [GptWidgetNative]::GetWindowRect($handle,[ref]$r)|Out-Null
     if([Math]::Abs(($r.Right-$r.Left)-$pixels)-gt 1 -or [Math]::Abs(($r.Bottom-$r.Top)-$pixels)-gt 1){
      throw "Size drift on $($screen.DeviceName), host DPI $dpi, scale $scale, tick ${iteration}: $($r.Right-$r.Left)x$($r.Bottom-$r.Top), expected $pixels"
     }
     $checks++
    }
   }
  }
  [GptWidgetNative]::SetWindowPos($handle,[IntPtr]::Zero,($area.Left+20),($area.Top+20),0,0,0x15)|Out-Null
  Pump-Display
  $bounded=[GptWidgetHostFollower]::VisibleBounds($handle,($area.Left-50),($area.Top-50),($area.Right+50),($area.Bottom+50))
  if(($bounded -join ',')-ne (@($area.Left,$area.Top,$area.Right,$area.Bottom)-join ',')){throw 'Visible bounds must exclude off-screen edges and the taskbar'}
  $offscreen=[GptWidgetHostFollower]::VisibleBounds($handle,100000,100000,101000,101000)
  if(($offscreen -join ',')-ne ($bounded -join ',')){throw 'Disconnected/off-screen position must recover into monitor work area'}
 }
 "PASS: $checks repeated WPF/native size checks across $([Windows.Forms.Screen]::AllScreens.Count) monitors, five DPI factors and three scales; work-area and off-screen recovery"
}finally{$script:window.Close()}
