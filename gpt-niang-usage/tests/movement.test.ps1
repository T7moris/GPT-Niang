$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $PSScriptRoot -Parent
. (Join-Path $appDir 'runtime\movement.ps1')
function Assert($condition,[string]$message){if(!$condition){throw $message};Write-Output ('PASS '+$message)}
# Deterministic trajectory checks independent of the machine's display size.
foreach($bounds in @(@(-1920,-400),@(0,800),@(100,100),@(100,50))){
  foreach($seconds in @(0,2,4,8,12,16,3600)){
    $script:widgetMovement=@{Enabled=$true;Phase=0.0;Clock=@{Elapsed=@{TotalSeconds=$seconds}}}
    $x=Get-WidgetMovementX $bounds[0] $bounds[1] $bounds[1]
    Assert ($x-ge $bounds[0]-0.001 -and $x-le [Math]::Max($bounds[0],$bounds[1])+0.001) ('Horizontal bounds '+($bounds-join ',')+' at '+$seconds+'s')
  }
}
$script:widgetMovement=@{Enabled=$true;Phase=0.0;Clock=@{Elapsed=@{TotalSeconds=8}}}
Assert ([Math]::Abs((Get-WidgetMovementX 0 800 800)) -lt 0.001) 'One crossing reaches the opposite edge'
$script:widgetMovement.Clock.Elapsed.TotalSeconds=16
Assert ([Math]::Abs((Get-WidgetMovementX 0 800 800)-800) -lt 0.001) 'Return crossing reaches the original edge'
$script:widgetMovement=$null
$script:window=[Windows.Window]::new();$script:window.Width=100;$script:window.Height=100;$script:window.Opacity=0
$script:context=[Windows.Controls.ContextMenu]::new();$script:settingsMenuUi=@{Movement=[Windows.Controls.MenuItem]::new()}
$script:drag=$null;$script:tickCount=0;$script:offsetBottom=17;$script:desktopTop=350
function Tick-Widget {$script:tickCount++}
try{
  Set-WidgetMovement $true
  $m=$script:widgetMovement
  Assert (!$m.Timer.IsEnabled -and !$m.Clock.IsRunning) 'Hidden window does not run the movement timer'
  $script:window.Show()
  Assert ($m.Timer.IsEnabled -and $m.Clock.IsRunning) 'Showing the window resumes movement'
  $x=Get-WidgetMovementX 0 800 300
  Assert ([Math]::Abs($x-300)-lt 2) 'Enabling starts from the current horizontal position'
  $script:context.IsOpen=$true;Sync-WidgetMovement
  Assert (!$m.Timer.IsEnabled -and !$m.Clock.IsRunning) 'Open menu pauses movement'
  $script:context.IsOpen=$false;Sync-WidgetMovement
  Assert $m.Timer.IsEnabled 'Closing the menu resumes movement'
  $script:window.Hide()
  Assert (!$m.Timer.IsEnabled) 'Hiding stops movement'
  $script:window.Show()
  Assert $m.Timer.IsEnabled 'Restoring the window resumes movement'
  Set-WidgetMovement $false
  Assert (!$m.Timer.IsEnabled -and !$m.Clock.IsRunning -and !$script:settingsMenuUi.Movement.IsChecked) 'Disabling stops the clock and clears the menu check'
  Assert ((Get-WidgetMovementX 0 800 300)-eq 300) 'Disabling restores the resting horizontal position'
  for($i=0;$i-lt 5;$i++){Set-WidgetMovement $true;Set-WidgetMovement $false}
  Assert ([object]::ReferenceEquals($m,$script:widgetMovement)) 'Repeated toggles reuse one timer'
  Assert ($script:offsetBottom-eq 17 -and $script:desktopTop-eq 350) 'Movement does not modify saved heights'
}finally{Set-WidgetMovement $false -NoLayout;$script:context.IsOpen=$false;$script:window.Close()}
