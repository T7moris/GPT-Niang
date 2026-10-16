# Separate dock positions from the normal pet's placement preferences.
function ConvertTo-WidgetDock($Value){
  if(!$Value -or $Value.edge-notin @('left','right','top','bottom')){return $null}
  try{
    $along=[double]$Value.along
    if([double]::IsNaN($along) -or [double]::IsInfinity($along)){return $null}
    # Earlier versions initialized an unmarked bottom corner. Discard only that
    # legacy default; deliberate four-edge positions continue to be remembered.
    if($null-eq $Value.dragged -and $Value.edge-eq 'bottom' -and ($along-eq 0 -or $along-eq 1)){return $null}
    return @{edge=[string]$Value.edge;along=[Math]::Max(0.0,[Math]::Min(1.0,$along));monitorX=$Value.monitorX;monitorY=$Value.monitorY;dragged=($null-eq $Value.dragged -or [bool]$Value.dragged)}
  }catch{return $null}
}
function Get-LowPowerDock {
  $name=if($script:followHost){'lowPowerHostDock'}else{'lowPowerDesktopDock'}
  $dock=Get-Variable -Name $name -Scope Script -ValueOnly -ErrorAction SilentlyContinue
  if(!$dock){
    $dock=@{edge=$(if($script:side-eq 'left'){'left'}else{'right'});along=0.5;monitorX=$null;monitorY=$null;dragged=$false}
    Set-Variable -Name $name -Scope Script -Value $dock
  }
  return $dock
}
function Set-LowPowerDockFromPoint($Frame,[double]$X,[double]$Y,[double]$Dpi){
  $dock=Get-LowPowerDock
  $distances=@{left=[Math]::Abs($X-$Frame.Left);right=[Math]::Abs($X-$Frame.Right);top=[Math]::Abs($Y-$Frame.Top);bottom=[Math]::Abs($Y-$Frame.Bottom)}
  $edge=$dock.edge
  foreach($candidate in @('left','right','top','bottom')){
    if($distances[$candidate]-lt $distances[$edge]){$edge=$candidate}
  }
  $size=208*$script:displayScale*$Dpi
  $span=if($edge-in @('top','bottom')){$Frame.Right-$Frame.Left-$size}else{$Frame.Bottom-$Frame.Top-$size}
  $offset=if($edge-in @('top','bottom')){$X-$Frame.Left-$size/2}else{$Y-$Frame.Top-$size/2}
  # Double bounds are essential in Windows PowerShell: integer bounds select the
  # integer Math overload and round a fractional position to an endpoint.
  $dock.edge=$edge;$dock.along=if($span-gt 0){[Math]::Max(0.0,[Math]::Min(1.0,($offset/$span)))}else{0.0};$dock.dragged=$true
}
function Get-LowPowerSide {
  $dock=Get-LowPowerDock
  if($dock.edge-in @('left','right')){return $dock.edge}
  if($dock.along-lt 0.5){return 'left'}else{return 'right'}
}
function Get-LowPowerGeometry($Frame,[double]$Dpi){
  $dock=Get-LowPowerDock
  $side=Get-LowPowerSide
  $unit=$script:displayScale*$Dpi
  $size=208*$unit;$width=$script:designWidth*$unit;$height=$script:designHeight*$unit
  $left=$Frame.Left+$dock.along*[Math]::Max(0,($Frame.Right-$Frame.Left-$size))
  $top=$Frame.Top+$dock.along*[Math]::Max(0,($Frame.Bottom-$Frame.Top-$size))
  switch($dock.edge){
    'left'{$left=$Frame.Left}
    'right'{$left=$Frame.Right-$size}
    'top'{$top=$Frame.Top}
    'bottom'{$top=$Frame.Bottom-$size}
  }
  # Keep the HWND inside the usable frame, moving the picture within its transparent
  # animation padding when necessary. This permits docking right into all four corners.
  $preferredX=$left-$(if($side-eq 'left'){0}else{170*$unit})
  $x=[int][Math]::Max($Frame.Left,[Math]::Min($Frame.Right-$width,$preferredX))
  $y=[int][Math]::Max($Frame.Top,[Math]::Min($Frame.Bottom-$height,$top-170*$unit))
  $canvasLeft=($left-$x)/$unit-14
  if($side-eq 'left'){$canvasLeft=350-$canvasLeft-208}
  return [pscustomobject]@{X=$x;Y=$y;ImageLeft=$left;ImageTop=$top;CanvasLeft=$canvasLeft;CanvasTop=($top-$y)/$unit-14;Edge=$dock.edge;FromTop=($dock.edge-eq 'top')}
}
function Get-LowPowerLeadingInset($Bitmap){
  # Include the asset's transparent leading margin in a horizontal peek, otherwise
  # the idle strip would contain no visible pixels and could not be grabbed.
  $scaled=[Windows.Media.Imaging.TransformedBitmap]::new($Bitmap,[Windows.Media.ScaleTransform]::new((208.0/$Bitmap.PixelWidth),(208.0/$Bitmap.PixelWidth)))
  $pixels=[Windows.Media.Imaging.FormatConvertedBitmap]::new($scaled,[Windows.Media.PixelFormats]::Bgra32,$null,0)
  $stride=$pixels.PixelWidth*4;$bytes=New-Object byte[] ($stride*$pixels.PixelHeight)
  $pixels.CopyPixels($bytes,$stride,0)
  for($x=0;$x-lt $pixels.PixelWidth;$x++){
    for($y=0;$y-lt $pixels.PixelHeight;$y++){if($bytes[$y*$stride+$x*4+3]-gt 10){return [double]$x}}
  }
  return 0.0
}
function Set-LowPowerControls {
  if(!$script:lowPowerGeometry){return}
  $left=$script:lowPowerGeometry.CanvasLeft;$top=$script:lowPowerGeometry.CanvasTop+20
  $side=Get-LowPowerSide
  [Windows.Controls.Canvas]::SetLeft($script:ui.MinimizeButton,($left+$(if($side-eq 'left'){178}else{6})))
  [Windows.Controls.Canvas]::SetLeft($script:ui.MenuButton,($left+$(if($side-eq 'left'){6}else{178})))
  foreach($name in @('MinimizeButton','MenuButton')){[Windows.Controls.Canvas]::SetTop($script:ui[$name],$top)}
}
function Set-LowPowerLayout($Geometry){
  $old=$script:lowPowerGeometry
  $script:lowPowerGeometry=$Geometry
  Set-Facing
  if(!$old -or [Math]::Abs($old.CanvasTop-$Geometry.CanvasTop)-gt 0.01 -or [Math]::Abs($old.CanvasLeft-$Geometry.CanvasLeft)-gt 0.01 -or $old.Edge-ne $Geometry.Edge){
    Set-LowPowerReveal $script:lowPowerReveal -Immediate
  }
}

# A native mouse callback only posts coordinates. No PowerShell runs in the global
# hook, and input is never swallowed. Install it only while the image is expanded.
if(!('GptWidgetOutsideClick' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public sealed class GptWidgetOutsideClick : IDisposable {
 public const int Message=0x8051;
 [StructLayout(LayoutKind.Sequential)] struct Point {public int X,Y;}
 [StructLayout(LayoutKind.Sequential)] struct MouseData {public Point Point;public uint Data,Flags,Time;public UIntPtr Extra;}
 delegate IntPtr MouseProc(int code,IntPtr message,IntPtr data);
 [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetWindowsHookEx(int id,MouseProc proc,IntPtr module,uint thread);
 [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
 [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr message,IntPtr data);
 [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd,int msg,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
 readonly IntPtr widget;readonly uint process;readonly MouseProc callback;IntPtr hook;
 public bool Enabled {get{return hook!=IntPtr.Zero;}}
 public GptWidgetOutsideClick(IntPtr widget){this.widget=widget;GetWindowThreadProcessId(widget,out process);callback=OnMouse;}
 public void SetEnabled(bool enabled){
  if(enabled&&!Enabled){hook=SetWindowsHookEx(14,callback,GetModuleHandle(null),0);if(!Enabled)throw new System.ComponentModel.Win32Exception();}
  if(!enabled&&Enabled){UnhookWindowsHookEx(hook);hook=IntPtr.Zero;}
 }
 IntPtr OnMouse(int code,IntPtr message,IntPtr data){
  long msg=message.ToInt64();
  if(code>=0&&(msg==0x201||msg==0x204||msg==0x207||msg==0x20B)){
   var value=(MouseData)Marshal.PtrToStructure(data,typeof(MouseData));
   IntPtr target=WindowFromPoint(value.Point);uint pid;GetWindowThreadProcessId(target,out pid);
   // Owned menus/editors are part of the pet, not outside clicks.
   if(target==widget||pid!=process)PostMessage(widget,target==widget?Message:Message+1,new IntPtr(value.Point.X),new IntPtr(value.Point.Y));
  }
  return CallNextHookEx(hook,code,message,data);
 }
 public void Dispose(){SetEnabled(false);GC.KeepAlive(callback);}
}
'@
}
