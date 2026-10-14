if(!('GptWidgetZOrderNative' -as [type])){
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class GptWidgetZOrderNative {
 [DllImport("user32.dll")]public static extern IntPtr GetWindow(IntPtr h,uint command);
 [DllImport("user32.dll")]public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]public static extern IntPtr GetWindowLongPtr(IntPtr h,int index);
 [DllImport("user32.dll",EntryPoint="SetWindowLongPtrW")]public static extern IntPtr SetWindowLongPtr(IntPtr h,int index,IntPtr value);
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("dwmapi.dll")]static extern int DwmGetWindowAttribute(IntPtr h,int attribute,out uint value,int size);
 public static bool Topmost(IntPtr h){return (GetWindowLongPtr(h,-20).ToInt64()&8)!=0;}
 public static bool VisibleSurface(IntPtr h){uint cloaked;return IsWindowVisible(h)&&(DwmGetWindowAttribute(h,14,out cloaked,4)!=0||cloaked==0);}
 public static IntPtr PreviousVisible(IntPtr h){
  IntPtr prior=GetWindow(h,3);for(int n=0;n<10000&&prior!=IntPtr.Zero;n++){
   if(VisibleSurface(prior))return prior;prior=GetWindow(prior,3);
  }return IntPtr.Zero;
 }
}
'@
}
$script:gptZOrderBands=@{}
function Set-WidgetDesktopLayer([IntPtr]$Widget,[bool]$Topmost=$true){
  # A desktop pet must not be owned (and destroyed or minimized) by the chat window.
  if([GptWidgetZOrderNative]::GetWindowLongPtr($Widget,-8)-ne [IntPtr]::Zero){
    [GptWidgetZOrderNative]::SetWindowLongPtr($Widget,-8,[IntPtr]::Zero)|Out-Null
  }
  if([GptWidgetZOrderNative]::Topmost($Widget)-ne $Topmost){
    $band=if($Topmost){[IntPtr](-1)}else{[IntPtr](-2)}
    [GptWidgetZOrderNative]::SetWindowPos($Widget,$band,0,0,0,0,0x13)|Out-Null
  }
}
function Set-WidgetAboveHost([IntPtr]$Widget,[IntPtr]$HostWindowHandle){
  if(![GptWidgetZOrderNative]::IsWindow($Widget) -or ![GptWidgetZOrderNative]::IsWindow($HostWindowHandle)){
    return [pscustomobject]@{ok=$false;changed=$false;reason='invalid-window'}
  }
  if(![GptWidgetZOrderNative]::VisibleSurface($HostWindowHandle) -or [GptWidgetZOrderNative]::IsIconic($HostWindowHandle)){
    return [pscustomobject]@{ok=$false;changed=$false;reason='host-not-visible'}
  }
  $key=$Widget.ToInt64().ToString();$changed=$false
  # A scheduler-owned background process cannot reliably insert an unowned
  # overlay above the active app. Native ownership keeps both in one layer.
  # WPF receives Closed when its owner is destroyed; the supervisor recreates
  # the GUI for the next real main window.
  if([GptWidgetZOrderNative]::GetWindowLongPtr($Widget,-8)-ne $HostWindowHandle){
    [GptWidgetZOrderNative]::SetWindowLongPtr($Widget,-8,$HostWindowHandle)|Out-Null
    if([GptWidgetZOrderNative]::GetWindowLongPtr($Widget,-8)-ne $HostWindowHandle){
      return [pscustomobject]@{ok=$false;changed=$false;reason='owner-attachment-failed'}
    }
    $changed=$true
  }
  $hostBand=[GptWidgetZOrderNative]::Topmost($HostWindowHandle)
  $widgetBand=[GptWidgetZOrderNative]::Topmost($Widget)
  if(!$script:gptZOrderBands.ContainsKey($key) -or $script:gptZOrderBands[$key]-ne $hostBand -or $widgetBand-ne $hostBand){
    $band=if($hostBand){[IntPtr](-1)}else{[IntPtr](-2)}
    # SWP_NOOWNERZORDER keeps this overlay correction from synchronously
    # reordering its foreign owner. This flag alone did not resolve stale occlusion.
    if(![GptWidgetZOrderNative]::SetWindowPos($Widget,$band,0,0,0,0,0x213)){
      return [pscustomobject]@{ok=$false;changed=$false;reason='band-change-failed'}
    }
    $script:gptZOrderBands[$key]=$hostBand;$changed=$true
  }
  # WPF may create invisible owner windows. Visible adjacency, rather than raw
  # HWND adjacency, avoids reordering forever against an invisible owner.
  $previous=[GptWidgetZOrderNative]::PreviousVisible($HostWindowHandle)
  if($previous-eq $Widget){return [pscustomobject]@{ok=$true;changed=$changed;adjacent=$true;hostTopmost=$hostBand}}
  $after=$previous
  if($after-eq [IntPtr]::Zero -or (!$hostBand -and [GptWidgetZOrderNative]::Topmost($after))){$after=[IntPtr]::Zero}
  if(![GptWidgetZOrderNative]::SetWindowPos($Widget,$after,0,0,0,0,0x213)){
    return [pscustomobject]@{ok=$false;changed=$changed;reason='placement-failed'}
  }
  $adjacent=[GptWidgetZOrderNative]::PreviousVisible($HostWindowHandle)-eq $Widget
  [pscustomobject]@{ok=$adjacent;changed=$true;adjacent=$adjacent;hostTopmost=$hostBand}
}
