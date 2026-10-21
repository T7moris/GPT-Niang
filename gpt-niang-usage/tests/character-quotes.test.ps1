param([string]$TestRoot=$PSScriptRoot,[string]$WidgetPath)
$ErrorActionPreference='Stop'
if(!$WidgetPath){$WidgetPath=Join-Path (Split-Path $TestRoot -Parent) 'widget.ps1'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$tokens=$null;$errors=$null
$source=[IO.File]::ReadAllText($WidgetPath,[Text.Encoding]::UTF8)
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in @('Show-NextCharacterQuote','Switch-Scene','Click-Character','Next-Bubble','Set-AnimatedValue')){
  $definition=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq $name},$true)
  if(!$definition){throw "Missing function: $name"}
  . ([ScriptBlock]::Create($definition.Extent.Text))
}
function Assert-Equal($actual,$expected,[string]$message){if($actual-ne $expected){throw "$message : expected '$expected', got '$actual'"}}
function Pump-Events([int]$milliseconds){
  $script:testFrame=[Windows.Threading.DispatcherFrame]::new()
  $timer=[Windows.Threading.DispatcherTimer]::new()
  $timer.Interval=[TimeSpan]::FromMilliseconds($milliseconds)
  $timer.Add_Tick({param($sender,$event)$sender.Stop();$script:testFrame.Continue=$false})
  $timer.Start();[Windows.Threading.Dispatcher]::PushFrame($script:testFrame)
}
function Animate-Value($target,$property,[double]$to,[int]$duration,[int]$delay=0){
  $from=[double]$target.GetValue($property)
  $target.BeginAnimation($property,$null);$target.SetValue($property,$from)
  $animation=[Windows.Media.Animation.DoubleAnimation]::new($from,$to,[Windows.Duration]::new([TimeSpan]::FromMilliseconds($duration)))
  $animation.BeginTime=[TimeSpan]::FromMilliseconds($delay)
  $target.BeginAnimation($property,$animation)
}
$script:ui=@{SceneText=[Windows.Controls.Grid]::new();QuoteText=[Windows.Controls.TextBlock]::new()}
$script:ui.SceneText.Children.Add($script:ui.QuoteText)|Out-Null
$script:ui.QuoteText.Text='previous quote'
$script:quoteSelections=0;$script:layoutCalls=0;$script:preparations=0;$script:visibleTextChanges=0;$script:readableRestarts=0
$script:sceneRevision=0;$script:bubbleMode='quota';$script:collapsed=$false;$script:bubbleTapAdvance=$true;$script:characterQuoteRepeat=$true
$script:quoteLayoutMap=@{}
function Get-WidgetBubbleQuote([string]$dataDir){$script:quoteSelections++;return "quote-$script:quoteSelections"}
function Fit-QuoteText {$script:layoutCalls++;$script:ui.QuoteText.Tag=$script:ui.QuoteText.Text}
function Get-WidgetQuoteLayout([string]$full,$text,[int]$expectedLines=0){
  $beforeText=$script:ui.QuoteText.Text;$beforeOpacity=$script:ui.SceneText.Opacity
  Start-Sleep -Milliseconds 80
  Assert-Equal $script:ui.QuoteText.Text $beforeText 'Slow preparation retains the outgoing text'
  Assert-Equal $script:ui.SceneText.Opacity $beforeOpacity 'Fade-out starts after preparation'
  $script:preparations++
  return [pscustomobject]@{width=200;fontSize=20;lineHeight=23;offsetX=0;offsetY=0}
}
function Apply-Scene { }
function Restart-SceneTtl([int]$renderDelay=0){$script:readableRestarts++}
function Reset-WidgetAutoQuoteSchedule { }
function Dismiss-CompletionNotification { }
function Show-Quota {$script:collapsed=$false;$script:bubbleMode='quota'}
function Hide-Quota {$script:collapsed=$true;if($script:sceneTimer){$script:sceneTimer.Stop()}}
$textDescriptor=[ComponentModel.DependencyPropertyDescriptor]::FromProperty([Windows.Controls.TextBlock]::TextProperty,[Windows.Controls.TextBlock])
$textChanged=[EventHandler]{if($script:ui.SceneText.Opacity-gt 0.001){$script:visibleTextChanges++}}
$textDescriptor.AddValueChanged($script:ui.QuoteText,$textChanged)
try{
  # A slow physical click must not expose the replacement quote before fade-out.
  Click-Character
  Assert-Equal $script:quoteSelections 1 'One quote is prepared before fading starts'
  Assert-Equal $script:ui.QuoteText.Text 'previous quote' 'Outgoing text remains unchanged'
  Assert-Equal $script:bubbleMode 'quota' 'Outgoing scene remains active until hidden'
  Pump-Events 330
  Assert-Equal $script:quoteSelections 1 'One click selects one quote'
  Assert-Equal $script:ui.QuoteText.Text 'quote-1' 'Selected quote is displayed'
  Assert-Equal $script:visibleTextChanges 0 'Text changes only while hidden'
  foreach($click in 1..4){
    $before=$script:quoteSelections
    Click-Character
    Assert-Equal $script:quoteSelections ($before+1) 'Repeat click prepares exactly one quote'
    Assert-Equal $script:ui.QuoteText.Text "quote-$before" 'Repeat click does not expose the prepared quote immediately'
    Pump-Events 330
    Assert-Equal $script:quoteSelections ($before+1) 'Repeat click selects exactly one quote'
    Assert-Equal $script:collapsed $false 'Repeat click keeps the bubble open'
  }
  Assert-Equal $script:visibleTextChanges 0 'Repeated quotes never change while visible'
  # New input during a transition replaces the pending request, without drawing unseen quotes.
  $before=$script:quoteSelections
  Click-Character;Pump-Events 20;Click-Character;Pump-Events 20;Click-Character
  Assert-Equal $script:quoteSelections ($before+1) 'Rapid input reuses the pending quote'
  Pump-Events 330
  Assert-Equal $script:quoteSelections ($before+1) 'Only the current transition commits'
  Assert-Equal $script:layoutCalls $script:quoteSelections 'Each selected quote is laid out once'
  Next-Bubble
  Assert-Equal $script:collapsed $true 'Clicking the quote bubble still closes it'
  $applied=$script:layoutCalls
  Show-Quota;Click-Character;Hide-Quota;Pump-Events 330
  Assert-Equal $script:layoutCalls $applied 'Closing cancels pending quote presentation'
  Assert-Equal $script:preparations $script:quoteSelections 'Each quote is prepared only once'
  $script:characterQuoteRepeat=$false;$script:bubbleTapAdvance=$false;Show-Quota
  $before=$script:readableRestarts;Click-Character
  Assert-Equal $script:readableRestarts ($before+1) 'Disabled option extends the quota display'
  $script:bubbleTapAdvance=$true;Click-Character;Pump-Events 330
  Assert-Equal $script:bubbleMode 'quote' 'Original advance option moves quota to quote'
  Click-Character
  Assert-Equal $script:collapsed $true 'Original advance option still closes a quote'
  $script:characterQuoteRepeat=$true;Show-Quota;Click-Character;Pump-Events 330;Click-Character;Pump-Events 330
  Assert-Equal $script:collapsed $false 'Repeat option takes priority when both toggles are enabled'
  $savedFunction=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Save-Settings'},$true)
  . ([ScriptBlock]::Create($savedFunction.Extent.Text))
  function Write-WidgetJson($file,$value){$script:savedClickSettings=$value}
  Save-Settings
  Assert-Equal $script:savedClickSettings.characterQuoteRepeat $true 'Repeat option is persisted independently'
  Assert-Equal $script:savedClickSettings.bubbleTapAdvance $true 'Saving repeat mode preserves the original advance option'
  Write-Output 'PASS: independent repeat toggle, original advance cycle, persistence, prepared transitions, rapid input, cancellation and close'
}finally{if($script:sceneTimer){$script:sceneTimer.Stop()};$textDescriptor.RemoveValueChanged($script:ui.QuoteText,$textChanged)}
