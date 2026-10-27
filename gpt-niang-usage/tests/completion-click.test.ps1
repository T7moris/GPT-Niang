param([string]$Source=(Join-Path $PSScriptRoot '../widget.ps1'))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($Source),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
Add-Type -TypeDefinition @'
using System;
public static class GptWidgetNative {
 public static bool Result=true, Dismissed=false, CalledAfterDismiss=false;
 public static int Calls=0;
 public static bool ActivateCodex(IntPtr h){Calls++;CalledAfterDismiss=Dismissed;return Result;}
}
'@
$definition=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq 'Click-Bubble'},$true)
. ([ScriptBlock]::Create($definition.Extent.Text))
function Hide-Quota {$script:collapsed=$true;[GptWidgetNative]::Dismissed=$true;$script:completionPending=$false}
function Next-Bubble {$script:nextCalls++}
function Assert($ok,$message){if(!$ok){throw $message};$script:checks++}
$script:checks=0;$script:nextCalls=0;$script:hostHandle=[IntPtr]123
$script:ui=@{Bubble=[Windows.Controls.Border]::new();Tail=[Windows.Controls.Border]::new();TailNear=[Windows.Controls.Border]::new()}
$binding=$ast.Find({param($n)$n-is [Management.Automation.Language.ForEachStatementAst] -and $n.Extent.Text.Contains('Click-Bubble;$event.Handled=$true')},$true)
if(!$binding){throw 'Missing bubble event binding'}
. ([ScriptBlock]::Create($binding.Extent.Text))
foreach($name in @('Bubble','Tail','TailNear')){
 $script:collapsed=$false;$script:bubbleMode='completion';$script:completionPending=$true
 [GptWidgetNative]::Dismissed=$false
 $before=[GptWidgetNative]::Calls
 $event=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left)
 $event.RoutedEvent=[Windows.UIElement]::MouseLeftButtonUpEvent
 $script:ui[$name].RaiseEvent($event)
 Assert ([GptWidgetNative]::Calls-eq $before+1) "$name click did not activate once"
 Assert ([GptWidgetNative]::CalledAfterDismiss -and !$script:completionPending -and $script:collapsed) "$name did not restore/dismiss before activation"
 Assert ($event.Handled) "$name event was not handled"
}
$before=[GptWidgetNative]::Calls
foreach($mode in @('quota','quote')){$script:collapsed=$false;$script:bubbleMode=$mode;Click-Bubble}
Assert ($script:nextCalls-eq 2 -and [GptWidgetNative]::Calls-eq $before) 'Normal bubble clicks changed behavior'
$script:collapsed=$true;$script:bubbleMode='completion';Click-Bubble
Assert ([GptWidgetNative]::Calls-eq $before) 'Collapsed bubble activated the host'
$script:collapsed=$false;[GptWidgetNative]::Result=$false;Click-Bubble
Assert ($script:completionLastError-eq 'CODEX_ACTIVATION_FAILED') 'Activation failure was not reported'
$script:collapsed=$false;[GptWidgetNative]::Result=$true;Click-Bubble
Assert ($null-eq $script:completionLastError) 'Successful activation did not clear old error'
Write-Output ('PASS: '+$script:checks+' completion click checks; actual WPF routed events, dismissal order, normal bubbles, hidden scene and failure recovery')
