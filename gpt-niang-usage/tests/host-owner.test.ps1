param([string]$TestRoot=$PSScriptRoot,[string]$WidgetSource)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
$appDir=Split-Path $TestRoot -Parent
if(!$WidgetSource){$WidgetSource=Join-Path $appDir 'widget.ps1'}
. (Join-Path $appDir 'runtime\host-layer.ps1')
. (Join-Path $appDir 'runtime\host-occlusion.ps1')
$source=[IO.File]::ReadAllText($WidgetSource,[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$native=$ast.Find({param($node)$node-is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public static class GptWidgetNative')},$true)
Add-Type -TypeDefinition $native.Value
$tick=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Tick-Widget'},$true)
. ([ScriptBlock]::Create($tick.Extent.Text))
$validFrame=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Test-WidgetPlacementFrame'},$true)
. ([ScriptBlock]::Create($validFrame.Extent.Text))
$pixelSize=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Set-WidgetPixelSize'},$true)
. ([ScriptBlock]::Create($pixelSize.Extent.Text))
# Keep disk/quota/readiness work outside this ownership test. HWNDs, WPF showing,
# WindowInteropHelper and native ownership/layering all use their real implementations.
function Tick-Scene {}
function Tick-WidgetUpdater {}
function Ensure-QuotaWorker {}
function Test-WidgetHostReady {return $true}
function Set-Appearance {}
function Request-Refresh {}
function Get-WidgetPlacementFrame {return [GptWidgetNative]::Frame($script:hostHandle)}
function Get-WidgetPlacementDpi {return 1.0}
$first=New-Object Windows.Window;$second=New-Object Windows.Window
$pet=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml')))
foreach($window in @($first,$second,$pet)){$window.ShowActivated=$false;$window.ShowInTaskbar=$false;$window.Opacity=0}
$first.Width=600;$first.Height=500;$second.Width=600;$second.Height=500
try{
 $first.Show();$second.Show()
 $firstHandle=([Windows.Interop.WindowInteropHelper]::new($first)).Handle
 $secondHandle=([Windows.Interop.WindowInteropHelper]::new($second)).Handle
 $interop=[Windows.Interop.WindowInteropHelper]::new($pet)
 $script:widgetHandle=$interop.EnsureHandle();$script:window=$pet
 $script:occlusionRecovery=[GptWidgetOcclusionRecovery]::new($script:widgetHandle)
 $script:hostHandle=$firstHandle;$script:attachedHost=[IntPtr]::Zero
 $script:lastForeground=[GptWidgetNative]::GetAncestor([GptWidgetNative]::GetForegroundWindow(),2)
 $script:lastPresence=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()+3600000
 $script:hostReadiness=[pscustomobject]@{desktopStarted=$false}
 $script:followHost=$true;$script:drag=$null;$script:scale=1.0;$script:displayScale=1.0
 $script:designWidth=378;$script:designHeight=378
 $script:offsetLeft=0;$script:offsetRight=0;$script:offsetBottom=0;$script:anchor='right'
 $script:context=[pscustomobject]@{IsOpen=$false};$script:dataDir=$TestRoot
 $script:hostFollower=New-Object PSObject
 $script:hostFollower|Add-Member ScriptMethod Configure {}
 $script:hostFollower|Add-Member ScriptMethod Suspend {}
 $script:ownerAtShow=[IntPtr]::Zero;$script:frameworkOwnerAtShow=[IntPtr]::Zero
 $pet.Add_IsVisibleChanged({
  if($script:window.IsVisible){
   $script:ownerAtShow=[GptWidgetZOrderNative]::GetWindowLongPtr($script:widgetHandle,-8)
   $script:frameworkOwnerAtShow=$interop.Owner
  }
 })
 $foreground=[GptWidgetNative]::GetForegroundWindow()
 Tick-Widget
 if($script:ownerAtShow-ne $firstHandle -or $script:frameworkOwnerAtShow-ne $firstHandle){throw 'Widget became visible before WPF and native ownership matched its host.'}
 if([GptWidgetNative]::GetForegroundWindow()-ne $foreground){throw 'Showing the owned widget changed foreground focus.'}
 if([GptWidgetZOrderNative]::Topmost($script:widgetHandle)){throw 'Ordinary host uses unnecessary global topmost.'}
 Write-Output 'PASS: real placement tick establishes WPF/native ownership before showing, without activation or global topmost'
 # Repeated ticks preserve the attachment; switching hosts updates both representations.
 for($n=0;$n-lt 5;$n++){Tick-Widget}
 $script:hostHandle=$secondHandle;Tick-Widget
 if($interop.Owner-ne $secondHandle -or [GptWidgetZOrderNative]::GetWindowLongPtr($script:widgetHandle,-8)-ne $secondHandle){throw 'Changing hosts left stale framework or native ownership.'}
 $first.Close()
 if(![GptWidgetZOrderNative]::IsWindow($script:widgetHandle)){throw 'Closing the previous host destroyed the reattached pet.'}
 if([GptWidgetNative]::GetForegroundWindow()-ne $foreground){throw 'Owner synchronization changed foreground focus.'}
 Write-Output 'PASS: repeated ticks and host changes preserve matching ownership and foreground focus'
 # Native desktop detachment still works after a framework-managed foreign owner.
 Set-WidgetDesktopLayer $script:widgetHandle $false
 $second.Close()
 if([GptWidgetZOrderNative]::GetWindowLongPtr($script:widgetHandle,-8)-ne [IntPtr]::Zero -or ![GptWidgetZOrderNative]::IsWindow($script:widgetHandle)){throw 'Desktop detachment did not survive closure of the former host.'}
 Write-Output 'PASS: desktop detachment survives closure of a framework-managed former host'
}finally{if($script:occlusionRecovery){$script:occlusionRecovery.Dispose()};$pet.Close();$first.Close();$second.Close()}
