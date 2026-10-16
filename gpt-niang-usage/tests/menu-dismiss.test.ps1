$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\runtime\menu-dismiss.ps1')
function Assert($ok,$message){if(!$ok){throw $message}}
$bounds=@(@{Left=10;Top=10;Right=338;Bottom=500},@{Left=338;Top=90;Right=638;Bottom=400})
function Pointer([int]$x,[int]$y,[int]$mask=1){@{Valid=$true;X=$x;Y=$y;Mask=$mask}}
Assert (Test-SettingsMenuOutsidePress (Pointer 900 600) 0 $bounds) 'Desktop left click did not dismiss'
Assert (Test-SettingsMenuOutsidePress (Pointer -900 20 2) 0 $bounds) 'Other-monitor right click did not dismiss'
Assert (Test-SettingsMenuOutsidePress (Pointer 900 20 4) 0 $bounds) 'Middle click did not dismiss'
Assert (!(Test-SettingsMenuOutsidePress (Pointer 50 50) 0 $bounds)) 'Menu click dismissed'
Assert (!(Test-SettingsMenuOutsidePress (Pointer 500 150) 0 $bounds)) 'Submenu click dismissed'
Assert (!(Test-SettingsMenuOutsidePress (Pointer 900 600) 1 $bounds)) 'Slider drag leaving bounds dismissed'
Assert (!(Test-SettingsMenuOutsidePress (Pointer 900 600 0) 1 $bounds)) 'Button release dismissed'
Assert (!(Test-SettingsMenuOutsidePress (Pointer 900 600) 1 $bounds)) 'Opening press dismissed'
Assert (!(Test-SettingsMenuOutsidePress (Pointer 900 600) 0 @())) 'Unknown bounds dismissed'
Assert (!(Test-SettingsMenuOutsidePress @{Valid=$false;Mask=1;X=900;Y=600} 0 $bounds)) 'Invalid cursor dismissed'
Assert (Test-SettingsMenuOutsidePress (Pointer 338 500) 0 $bounds) 'Outside border not dismissed'
$negative=@(@{Left=-1920;Top=-100;Right=-1592;Bottom=600})
Assert (!(Test-SettingsMenuOutsidePress (Pointer -1800 50) 0 $negative)) 'Negative monitor coordinates failed'
# Real WPF/native initialization, without opening a window or moving the pointer.
Add-Type -AssemblyName PresentationFramework
$script:context=New-Object Windows.Controls.ContextMenu
$script:settingsSubmenus=@()
Initialize-SettingsMenuDismiss
Assert (!$script:settingsMenuDismissTimer.IsEnabled -and !$script:context.StaysOpen) 'Timer/normal dismiss initialization failed'
$nativePointer=Get-SettingsMenuPointer
Assert ($nativePointer.Mask-ge 0 -and $nativePointer.Mask-le 7) 'Native pointer read failed'
# Drive only the close decision with synthetic input; no desktop automation.
$script:context=[pscustomobject]@{IsOpen=$true}
function Get-SettingsMenuPointer {Pointer 900 600}
function Get-SettingsMenuBounds {$bounds}
$script:settingsMenuPointerMask=0
Invoke-SettingsMenuDismissTick
Assert (!$script:context.IsOpen) 'Dismiss tick failed to close menu'
Invoke-SettingsMenuDismissTick
Assert (!$script:settingsMenuDismissTimer.IsEnabled) 'Closed menu continued polling'
Write-Output 'PASS: external presses, root/submenu bounds, slider drag, opening/release, invalid/negative coordinates, real WPF/native initialization, close decision and cleanup'
