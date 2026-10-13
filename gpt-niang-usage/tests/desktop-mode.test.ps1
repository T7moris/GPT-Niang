param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime\sharp-text.ps1')
. (Join-Path $appDir 'runtime\host-layer.ps1')
. (Join-Path $appDir 'runtime\host-follow.ps1')
# Save preferences through the real widget code, including existing color and sound settings.
$tokens=$null;$parseErrors=$null
$source=[IO.File]::ReadAllText((Join-Path $appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors|Out-String)}
foreach($name in @('Write-WidgetJson','Save-Settings','Set-Appearance','Set-WidgetFollowHost','Set-WidgetPixelSize','Test-WidgetPlacementFrame')){
  $definition=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq $name},$true)
  . ([ScriptBlock]::Create($definition.Extent.Text))
}
$settingsFile=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-desktop-settings-'+[Guid]::NewGuid().ToString('N')+'.json')
$preferences=@{scale=0.6;soundOn=$false;soundVolume=0.4;hideMenu=$true;colorMode='mixed';colorChance=0.5;colorTextChance=3;colorPaused=$true;followHost=$false;desktopTopmost=$false;desktopLeft=-700;desktopTop=200}
try{
  foreach($key in $preferences.Keys){Set-Variable -Scope Script -Name $key -Value $preferences[$key]}
  Save-Settings
  $saved=Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8|ConvertFrom-Json
  foreach($key in $preferences.Keys){if($saved.$key-ne $preferences[$key]){throw "Preference lost during desktop save: $key"}}
  Write-Output 'PASS: desktop positions and original scale, sound, menu and color preferences persist'
}finally{if(Test-Path -LiteralPath $settingsFile){Remove-Item -LiteralPath $settingsFile}}
# Exercise ownership with real isolated windows; never move or minimize the user's chat.
$owner=New-Object Windows.Window;$owner.Title='Desktop mode test host';$owner.Width=200;$owner.Height=200
$pet=New-Object Windows.Window;$pet.Title='Desktop mode test pet';$pet.Width=100;$pet.Height=100
$follower=$null
foreach($window in @($owner,$pet)){$window.ShowActivated=$false;$window.ShowInTaskbar=$false;$window.Opacity=0}
try{
  $owner.Show();$pet.Show()
  $ownerHandle=([Windows.Interop.WindowInteropHelper]::new($owner)).Handle
  $petHandle=([Windows.Interop.WindowInteropHelper]::new($pet)).Handle
  $follower=[GptWidgetHostFollower]::new($petHandle)
  $bounds=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $follower.Configure($ownerHandle,$bounds.Left,$bounds.Top,$bounds.Right,$bounds.Bottom,100,100,0,0,0,'right',$true)
  $follower.Detach()
  if($follower.Ready -or $follower.Synchronize()){throw 'Detached follower still controls desktop placement'}
  $null=Set-WidgetAboveHost $petHandle $ownerHandle
  if([GptWidgetZOrderNative]::GetWindowLongPtr($petHandle,-8)-ne $ownerHandle){throw 'Follow mode ownership failed'}
  Set-WidgetDesktopLayer $petHandle $true
  if([GptWidgetZOrderNative]::GetWindowLongPtr($petHandle,-8)-ne [IntPtr]::Zero){throw 'Desktop pet still owned by chat'}
  if(![GptWidgetZOrderNative]::Topmost($petHandle)){throw 'Desktop topmost failed'}
  $owner.WindowState=[Windows.WindowState]::Minimized
  if(![GptWidgetZOrderNative]::IsWindowVisible($petHandle)){throw 'Pet hidden with minimized chat'}
  $owner.Close()
  if(![GptWidgetZOrderNative]::IsWindow($petHandle)){throw 'Pet destroyed with closed chat'}
  Set-WidgetDesktopLayer $petHandle $false
  if([GptWidgetZOrderNative]::Topmost($petHandle)){throw 'Topmost toggle failed'}
  # Use the real appearance and mode-switch functions with deterministic geometry.
  $script:window=$pet;$script:widgetHandle=$petHandle;$script:hostHandle=[IntPtr]::Zero;$script:hostFollower=$follower
  $script:ui=@{Root=(New-Object Windows.Controls.Grid)};$script:scale=2.5;$script:followHost=$false;$script:desktopTopmost=$true
  function Get-WidgetPlacementFrame{return [pscustomobject]@{Left=0;Top=0;Right=1280;Bottom=680}}
  function Get-WidgetPlacementDpi{return 1.0}
  function Set-Facing {}
  function Save-Settings {}
  function Tick-Widget {}
  $script:designWidth=378;$script:designHeight=378
  Set-Appearance
  $matrix=[Windows.PresentationSource]::FromVisual($pet).CompositionTarget.TransformToDevice
  if([Math]::Abs($pet.Height*$matrix.M22-680)-gt 1 -or [Math]::Abs($script:displayScale-680/378)-gt 0.001){throw 'Desktop physical scaling exceeds the work area'}
  Set-WidgetDesktopLayer $petHandle $true
  Set-WidgetFollowHost $true
  if([GptWidgetZOrderNative]::Topmost($petHandle)){throw 'Returning to window mode retained desktop topmost'}
  if(!$script:desktopTopmost){throw 'Window mode lost the remembered desktop preference'}
  Set-WidgetFollowHost $false
  if(![GptWidgetZOrderNative]::Topmost($petHandle)){throw 'Returning to desktop mode lost its topmost setting'}
  Write-Output 'PASS: detached pet survives host minimization and closure; topmost toggle works'
  Write-Output 'PASS: desktop work-area scaling and immediate topmost cancellation on mode switches'
}finally{if($follower){$follower.Dispose()};$pet.Close();$owner.Close()}
