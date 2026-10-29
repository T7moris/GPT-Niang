param(
 [string]$WidgetSource,
 [string]$ResourceApp=(Split-Path $PSScriptRoot -Parent),
 [int]$Iterations=3000,
 [string]$ResultFile,
 [int]$MaxRetainedGrowthMB=32
)
$ErrorActionPreference='Stop'
if(!$WidgetSource){$WidgetSource=Join-Path $ResourceApp 'widget.ps1'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$source=[IO.File]::ReadAllText($WidgetSource,[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in @('Reset-Label','Format-ResetTime','Format-ResetDisplay','Get-QuotaWindowLabel','Get-QuotaRows','Set-QuotaResetText','Update-BubbleTooltip','Update-Quota')){
 $definition=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq $name},$true)
 if(!$definition){throw ('Missing real widget function: '+$name)}
 . ([scriptblock]::Create($definition.Extent.Text))
}
. (Join-Path $ResourceApp 'runtime\sharp-text.ps1')
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $ResourceApp 'runtime\quote-layout.ps1'),[Text.Encoding]::UTF8)))
$script:window=[Windows.Markup.XamlReader]::Parse((ConvertTo-SmoothWidgetXaml ([IO.File]::ReadAllText((Join-Path $ResourceApp 'widget.xaml'),[Text.Encoding]::UTF8))))
$script:ui=@{}
foreach($name in @('Root','Bubble','SceneText','QuoteText','QuotaText','Refresh','Header','Status','LiveDot','ShortRow','ShortLabel','ShortLeft','ShortUsed','ShortReset','ShortBar','WeekRow','WeekLabel','WeekLeft','WeekUsed','WeekReset','WeekBar')){$script:ui[$name]=$script:window.FindName($name)}
$script:widgetColors=$null;$script:bubbleMode='quota';$script:resetTimeMode='countdown'
$script:dataDir=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-memory-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($script:dataDir)
$script:statusStamp=0;$script:status=$null
function Write-Snapshot([int]$ShortUsed=25,[switch]$Business){
 $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
 $windows=@(@{minutes=300;used=$ShortUsed;remaining=(100-$ShortUsed);resetsAt=($now+3600)},@{minutes=10080;used=10;remaining=90;resetsAt=($now+345600)})
 if($Business){$windows=@(@{kind='individual';minutes=0;used=52;remaining=48;resetsAt=($now+1800);total=4000;amountUsed=2080;amountRemaining=1920})+$windows}
 $snapshot=@{ok=$true;queryOk=$true;planLabel='Pro';observedAt=($now*1000);windows=$windows}
 [IO.File]::WriteAllText((Join-Path $script:dataDir 'status.json'),($snapshot|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
 $script:statusStamp=0
}
function Render-Text {
 $view=$script:window.Content
 $view.Measure([Windows.Size]::new(378,378));$view.Arrange([Windows.Rect]::new(0,0,378,378));$view.UpdateLayout()
}
function Read-Memory([string]$Phase,[int]$Iteration){
 [GC]::Collect();[GC]::WaitForPendingFinalizers();[GC]::Collect()
 $p=[Diagnostics.Process]::GetCurrentProcess();$p.Refresh()
 [pscustomobject]@{phase=$Phase;iteration=$Iteration;retainedMB=[Math]::Round([GC]::GetTotalMemory($false)/1MB,2);privateMB=[Math]::Round($p.PrivateMemorySize64/1MB,2);typeCounts=@($script:status.windows|ForEach-Object{$_.PSObject.TypeNames.Count});draws=[GPTNiang.SmoothTextBlock]::VectorDraws}
}
$result=@{source=$WidgetSource;passed=$false;samples=@();failures=@();iterations=$Iterations}
try{
 Write-Snapshot
 for($i=0;$i-lt 50;$i++){Update-Quota;Render-Text}
 $baseline=Read-Memory 'warmup' 50;$result.samples+=@($baseline)
 for($i=1;$i-le $Iterations;$i++){
  Update-Quota
  if($i%10-eq 0){Render-Text}
  if($i%100-eq 0 -or $i-eq $Iterations){
   $sample=Read-Memory 'cached-status' $i;$result.samples+=@($sample)
   if($i%500-eq 0){$sample|ConvertTo-Json -Compress|Write-Output}
   if($sample.privateMB-gt 768){throw 'Isolated memory guard reached 768 MB'}
   if(@($sample.typeCounts|Where-Object{$_-ne 2}).Count){throw 'Quota refresh is growing cached object type metadata'}
   if($sample.retainedMB-$baseline.retainedMB-gt $MaxRetainedGrowthMB){throw 'Retained heap grows beyond the warmup allowance'}
  }
 }
 foreach($business in @($false,$true)){
  foreach($mode in @('countdown','fixed')){
   Write-Snapshot -Business:$business -ShortUsed 37;$script:resetTimeMode=$mode
   for($i=0;$i-lt 100;$i++){Update-Quota;if($i%10-eq 0){Render-Text}}
   if(@($script:status.windows|Where-Object{$_.PSObject.TypeNames.Count-ne 2}).Count){throw 'Business or fixed-time refresh mutates cached metadata'}
   if(!$business -and $script:ui.ShortLeft.Text-ne '63%'){throw 'Updated quota value stopped refreshing'}
   if($script:ui.ShortReset.Text-match '[\r\n]'){throw 'Reset text is no longer single-line'}
  }
 }
 $sample=Read-Memory 'changed-status-and-business' 400;$result.samples+=@($sample)
 if($sample.retainedMB-$baseline.retainedMB-gt $MaxRetainedGrowthMB){throw 'Changed snapshots retain unbounded memory'}
 $draw=[Windows.Media.VisualTreeHelper]::GetDrawing($script:ui.Header)
 if(!@($draw.Children|Where-Object{$_-is [Windows.Media.GeometryDrawing]}).Count){throw 'Vector text rendering was lost'}
 $result.passed=$true
 Write-Output ('PASS: '+$Iterations+' cached-status refreshes, 400 changed/Business/fixed-time refreshes, unchanged metadata and bounded retained heap; vector text preserved')
}catch{
 $result.failures+=@($_.Exception.Message)
 throw
}finally{
 if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
 $script:window.Close()
 $resolved=[IO.Path]::GetFullPath($script:dataDir);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved)-notlike 'gpt-niang-memory-*'){throw 'Unsafe memory-test cleanup path'}
 [IO.File]::Delete((Join-Path $resolved 'status.json'));[IO.Directory]::Delete($resolved)
}