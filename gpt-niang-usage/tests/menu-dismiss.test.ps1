param([string]$ResultPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $PSScriptRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime\ui-settings.ps1'),[Text.Encoding]::UTF8)))
$script:assertions=0
function Assert($Condition,[string]$Message){$script:assertions++;if(!$Condition){throw $Message}}
function Pointer([double]$X,[double]$Y,[int]$Mask=1){@{Valid=$true;X=$X;Y=$Y;Mask=$Mask}}
function Pump {
  $frame=New-Object Windows.Threading.DispatcherFrame
  $null=[Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background,[Action]{$frame.Continue=$false})
  [Windows.Threading.Dispatcher]::PushFrame($frame)
}
$bounds=@(@{Left=10;Top=10;Right=338;Bottom=500},@{Left=338;Top=90;Right=638;Bottom=400})
foreach($mask in @(1,2,4)){
  Assert (Test-SettingsMenuOutsidePress (Pointer 900 600 $mask) 0 $bounds) 'Outside button press did not dismiss'
  Assert (!(Test-SettingsMenuOutsidePress (Pointer 50 50 $mask) 0 $bounds)) 'Root menu click dismissed'
  Assert (!(Test-SettingsMenuOutsidePress (Pointer 500 150 $mask) 0 $bounds)) 'Submenu click dismissed'
  Assert (!(Test-SettingsMenuOutsidePress (Pointer 900 600 $mask) $mask $bounds)) 'Held drag/opening press dismissed'
}
Assert (!(Test-SettingsMenuOutsidePress (Pointer 900 600 0) 1 $bounds)) 'Release dismissed'
Assert (!(Test-SettingsMenuOutsidePress (Pointer 900 600 0) 0 $bounds)) 'Hover dismissed'
Assert (Test-SettingsMenuOutsidePress (Pointer 900 600 3) 1 $bounds) 'New second button press was missed'
Assert (!(Test-SettingsMenuOutsidePress (Pointer 900 600) 0 @())) 'Missing geometry dismissed'
Assert (!(Test-SettingsMenuOutsidePress @{Valid=$false;X=900;Y=600;Mask=1} 0 $bounds)) 'Invalid pointer dismissed'
Assert (Test-SettingsMenuOutsidePress (Pointer 338 500) 0 $bounds) 'Outside border was treated as inside'
foreach($dpi in @(1.0,1.25,1.5,2.0)){
  $rect=@{Left=-1920*$dpi;Top=-100*$dpi;Right=-1592*$dpi;Bottom=600*$dpi}
  Assert (!(Test-SettingsMenuOutsidePress (Pointer (-1800*$dpi) (50*$dpi)) 0 @($rect))) 'Physical negative-coordinate point rejected'
  Assert (Test-SettingsMenuOutsidePress (Pointer (-1500*$dpi) (50*$dpi)) 0 @($rect)) 'Physical outside point accepted'
}
$fixture=New-Object Windows.Window
$fixture.ShowActivated=$false;$fixture.ShowInTaskbar=$false;$fixture.Width=160;$fixture.Height=100
$fixture.Left=100;$fixture.Top=100;$fixture.WindowStyle=[Windows.WindowStyle]::None
$script:context=New-Object Windows.Controls.ContextMenu
$script:context.Focusable=$false
$script:context.PlacementTarget=$fixture
$parent=New-Object Windows.Controls.MenuItem;$parent.Header='Parent'
$nested=New-Object Windows.Controls.MenuItem;$nested.Header='Nested'
$slider=New-Object Windows.Controls.Slider;$slider.Width=120;$slider.Minimum=0;$slider.Maximum=100
$sliderItem=New-Object Windows.Controls.MenuItem;$sliderItem.StaysOpenOnClick=$true;$sliderItem.Header=$slider
$null=$nested.Items.Add($sliderItem);$null=$parent.Items.Add($nested);$null=$script:context.Items.Add($parent)
$script:settingsSubmenus=@($parent,$nested)
Initialize-SettingsMenuDismiss
Assert (!$script:settingsMenuDismissTimer.IsEnabled -and !$script:context.StaysOpen) 'Initialization started polling or disabled native dismissal'
$native=Get-SettingsMenuPointer
Assert ($native.Mask-ge 0 -and $native.Mask-le 7) 'Native pointer read failed'
# Read the actual API once, then use synthetic state; do not send input or move the cursor.
$script:testPointer=Pointer 99999 99999 1
function Get-SettingsMenuPointer {$script:testPointer}
try{
  $fixture.Show();$fixture.UpdateLayout()
  $script:context.IsOpen=$true;Pump
  Assert ($script:context.IsOpen -and $script:settingsMenuDismissTimer.IsEnabled) 'Opening press closed the menu or failed to start polling'
  Invoke-SettingsMenuDismissTick
  Assert $script:context.IsOpen 'Same opening press was treated as new'
  $script:testPointer=Pointer 99999 99999 0
  Invoke-SettingsMenuDismissTick
  Assert $script:context.IsOpen 'Releasing opening button closed menu'
  $parent.IsSubmenuOpen=$true;Pump
  $nested.IsSubmenuOpen=$true;Pump
  $rects=@(Get-SettingsMenuBounds)
  Assert ($rects.Count-eq 3) 'Root plus two nested native popup bounds were not found'
  foreach($rect in $rects){
    $script:testPointer=Pointer (($rect.Left+$rect.Right)/2) (($rect.Top+$rect.Bottom)/2) 1
    $script:settingsMenuPointerMask=0
    Invoke-SettingsMenuDismissTick
    Assert $script:context.IsOpen 'Real popup interior dismissed menu'
  }
  $script:settingsMenuPointerMask=1
  $script:testPointer=Pointer 99999 99999 1
  Invoke-SettingsMenuDismissTick
  Assert $script:context.IsOpen 'Held slider drag outside native popup closed menu'
  $script:testPointer=Pointer 99999 99999 0
  Invoke-SettingsMenuDismissTick
  Assert $script:context.IsOpen 'Slider release outside closed menu'
  $script:testPointer=Pointer 99999 99999 1
  Invoke-SettingsMenuDismissTick;Pump
  Assert (!$script:context.IsOpen -and !$script:settingsMenuDismissTimer.IsEnabled) 'New outside click did not close menu and stop timer'
  Assert ($script:settingsMenuPointerMask-eq 0) 'Closed menu retained previous input state'
  $script:context.IsOpen=$true;Pump
  Invoke-SettingsMenuDismissTick
  Assert $script:context.IsOpen 'Reopened menu inherited previous press'
  $script:context.IsOpen=$false;Pump
  Assert (!$script:settingsMenuDismissTimer.IsEnabled) 'Manual close continued polling'
  $script:settingsMenuDismissTimer.Start()
  Invoke-SettingsMenuDismissTick
  Assert (!$script:settingsMenuDismissTimer.IsEnabled) 'Closed-menu tick did not stop timer'
  # Execute real runtime teardown with empty process/hook state; never touch live widget processes.
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $appDir 'widget.ps1'),[Text.Encoding]::UTF8),[ref]$tokens,[ref]$errors)
  Assert ($errors.Count-eq 0) 'Entrypoint syntax errors'
  $definition=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Stop-WidgetRuntime'},$true)
  . ([ScriptBlock]::Create($definition.Extent.Text))
  function Stop-WidgetMusic {}
  function Stop-CompletionMonitor {}
  function Clear-CompletionNotifications {}
  function Close-WidgetAudio {}
  $script:runtimeClosed=$false;$script:worker=$null;$script:eventHooks=@();$script:mutexOwned=$false
  $script:dataDir=Join-Path ([IO.Path]::GetTempPath()) ('gpt-menu-missing-'+[Guid]::NewGuid().ToString('N'))
  $script:settingsMenuDismissTimer.Start()
  Stop-WidgetRuntime
  Assert (!$script:settingsMenuDismissTimer.IsEnabled) 'Runtime shutdown continued polling'
  $result=@{passed=$true;assertions=$script:assertions;nativePointerRead=$true;realPopupCount=$rects.Count;pointerInputSynthetic=$true;inputSent=$false;cursorMoved=$false;runtimeTeardownExecuted=$true;wholeLiveMenuVerified=$false}
  if($ResultPath){[IO.File]::WriteAllText($ResultPath,($result|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))}
  Write-Output ('PASS: menu dismissal '+$script:assertions+' assertions; native root/nested popup geometry, synthetic input edges, open/close/reopen and real runtime teardown')
}finally{
  $script:context.IsOpen=$false
  if($script:settingsMenuDismissTimer){$script:settingsMenuDismissTimer.Stop()}
  $fixture.Close()
}
