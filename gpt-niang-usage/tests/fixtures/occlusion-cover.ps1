param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference='Stop'
$resolved=(Resolve-Path -LiteralPath $Root).Path
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf)-notmatch '^gpt-niang-occlusion-[0-9a-f]{32}$'){throw 'Expected isolated occlusion test directory'}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class OcclusionCoverNative {
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int z,uint flags);
}
'@
$holder=New-Object Windows.Forms.NativeWindow
$parameters=New-Object Windows.Forms.CreateParams;$parameters.Style=0;$parameters.Width=32;$parameters.Height=32
$holder.CreateHandle($parameters)
$cover=New-Object Windows.Forms.NativeWindow
$parameters=New-Object Windows.Forms.CreateParams
$parameters.Parent=$holder.Handle;$parameters.Style=-1879048192;$parameters.ExStyle=0x08000008
$parameters.X=-10020;$parameters.Y=-10020;$parameters.Width=200;$parameters.Height=200
$cover.CreateHandle($parameters)
try{
 [IO.File]::WriteAllText((Join-Path $resolved 'ready.json'),(@{pid=$PID;hwnd=$cover.Handle.ToInt64()}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 $deadline=[DateTime]::UtcNow.AddSeconds(30);$last=$null
 while([DateTime]::UtcNow-lt $deadline -and !(Test-Path -LiteralPath (Join-Path $resolved 'stop.flag'))){
  [Windows.Forms.Application]::DoEvents()
  $request=Get-Content -LiteralPath (Join-Path $resolved 'request.txt') -Raw -ErrorAction SilentlyContinue
  if($request -and $request-ne $last){
   $last=$request
   $x=-10020;$y=-10020;$size=200
   if($request-eq 'partial'){$size=80}
   elseif($request-eq 'expose'){$x=-30000;$y=-30000}
   elseif($request-ne 'full'){throw 'Unknown coverage request'}
   if(![OcclusionCoverNative]::SetWindowPos($cover.Handle,[IntPtr](-1),$x,$y,$size,$size,0x10)){throw 'Fixture placement failed'}
   [IO.File]::WriteAllText((Join-Path $resolved 'ack.txt'),$request)
  }
  Start-Sleep -Milliseconds 10
 }
}finally{$cover.DestroyHandle();$holder.DestroyHandle()}
