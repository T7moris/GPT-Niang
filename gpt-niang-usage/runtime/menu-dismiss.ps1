# The widget is non-activating; focus loss alone cannot dismiss its menu.
# Observe button edges only while open. Never hook or consume mouse input.
$script:settingsMenuPointerMask=0
function Get-SettingsMenuPointer {
  $point=New-Object GptSettingsMenuPointer+Point
  $ok=[GptSettingsMenuPointer]::GetCursorPos([ref]$point)
  $mask=0
  if(([GptSettingsMenuPointer]::GetAsyncKeyState(1)-band 0x8000)-ne 0){$mask=$mask-bor 1}
  if(([GptSettingsMenuPointer]::GetAsyncKeyState(2)-band 0x8000)-ne 0){$mask=$mask-bor 2}
  if(([GptSettingsMenuPointer]::GetAsyncKeyState(4)-band 0x8000)-ne 0){$mask=$mask-bor 4}
  return @{Valid=$ok;X=$point.X;Y=$point.Y;Mask=$mask}
}
function Test-SettingsMenuOutsidePress($Pointer,[int]$PreviousMask,$Bounds) {
  if(!$Pointer.Valid -or (($Pointer.Mask-band (-bnot $PreviousMask))-eq 0)){return $false}
  if(@($Bounds).Count-eq 0){return $false}
  foreach($rect in $Bounds){
    if($Pointer.X-ge $rect.Left -and $Pointer.X-lt $rect.Right -and $Pointer.Y-ge $rect.Top -and $Pointer.Y-lt $rect.Bottom){return $false}
  }
  return $true
}
function Get-SettingsMenuBounds {
  $visuals=@($script:context)
  foreach($item in $script:settingsSubmenus){
    if($item.IsSubmenuOpen -and $item.Template){
      $popup=$item.Template.FindName('PART_Popup',$item)
      if($popup -and $popup.IsOpen -and $popup.Child){$visuals+=,$popup.Child}
    }
  }
  foreach($visual in $visuals){
    try{
      if(!$visual.IsVisible -or $visual.ActualWidth-le 0 -or $visual.ActualHeight-le 0){continue}
      # Physical coordinates include DPI and negative-coordinate monitors.
      $a=$visual.PointToScreen([Windows.Point]::new(0,0))
      $b=$visual.PointToScreen([Windows.Point]::new($visual.ActualWidth,$visual.ActualHeight))
      @{Left=$a.X;Top=$a.Y;Right=$b.X;Bottom=$b.Y}
    }catch{}
  }
}
function Invoke-SettingsMenuDismissTick {
  if(!$script:context.IsOpen){$script:settingsMenuDismissTimer.Stop();return}
  $pointer=Get-SettingsMenuPointer
  $previous=$script:settingsMenuPointerMask
  $script:settingsMenuPointerMask=$pointer.Mask
  if(Test-SettingsMenuOutsidePress $pointer $previous @(Get-SettingsMenuBounds)){
    foreach($item in @($script:settingsSubmenus)){if($item.IsSubmenuOpen){$item.IsSubmenuOpen=$false}}
    $script:context.IsOpen=$false
    $script:settingsMenuDismissTimer.Stop();$script:settingsMenuPointerMask=0
  }
}
function Stop-SettingsMenuDismiss {
  if($script:settingsMenuDismissTimer){$script:settingsMenuDismissTimer.Stop()}
  if($script:settingsMenuOpenObserver){
    $observer=$script:settingsMenuOpenObserver;$script:settingsMenuOpenObserver=$null
    $observer.Descriptor.RemoveValueChanged($observer.Menu,$observer.Handler)
  }
  $script:settingsMenuPointerMask=0
}
function Initialize-SettingsMenuDismiss {
  Stop-SettingsMenuDismiss
  if(-not ('GptSettingsMenuPointer' -as [type])){
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class GptSettingsMenuPointer {
  [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point p);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
}
'@
  }
  $script:context.StaysOpen=$false
  $script:settingsMenuDismissTimer=New-Object Windows.Threading.DispatcherTimer([Windows.Threading.DispatcherPriority]::Input)
  $script:settingsMenuDismissTimer.Interval=[TimeSpan]::FromMilliseconds(16)
  $script:settingsMenuDismissTimer.Add_Tick({Invoke-SettingsMenuDismissTick})
  $script:context.Add_Opened({
    $script:settingsMenuPointerMask=(Get-SettingsMenuPointer).Mask
    $script:settingsMenuDismissTimer.Start()
  })
  $script:context.Add_Closed({$script:settingsMenuDismissTimer.Stop();$script:settingsMenuPointerMask=0})
  # Native popup Closed can arrive after IsOpen already changed. Stop polling
  # synchronously for manual closes, including a menu with nested popups.
  $descriptor=[ComponentModel.DependencyPropertyDescriptor]::FromProperty([Windows.Controls.ContextMenu]::IsOpenProperty,[Windows.Controls.ContextMenu])
  $handler=[EventHandler]{param($sender,$event)if(!$sender.IsOpen){$script:settingsMenuDismissTimer.Stop();$script:settingsMenuPointerMask=0}}
  $descriptor.AddValueChanged($script:context,$handler)
  $script:settingsMenuOpenObserver=@{Descriptor=$descriptor;Menu=$script:context;Handler=$handler}

}
