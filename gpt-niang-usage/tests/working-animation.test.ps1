$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$app=Split-Path $PSScriptRoot -Parent
$testDir=Join-Path ([IO.Path]::GetTempPath()) ('gpt-working-animation-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testDir
function Assert($condition,[string]$message){if(!$condition){throw $message}}
function Pump([int]$ms){$f=[Windows.Threading.DispatcherFrame]::new();$t=[Windows.Threading.DispatcherTimer]::new();$t.Interval=[TimeSpan]::FromMilliseconds($ms);$t.Tag=$f;$t.Add_Tick({param($sender,$e)$sender.Stop();$sender.Tag.Continue=$false});$t.Start();[Windows.Threading.Dispatcher]::PushFrame($f)}
try{
 . (Join-Path $app 'runtime\character-animation.ps1')
 $script:appDir=$app;$script:dataDir=$testDir;$script:characterMode='pixel';$script:runtimeClosed=$false
 $script:window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $app 'widget.xaml'),[Text.Encoding]::UTF8))
 $script:window.Left=-10000;$script:window.Top=-10000;$script:window.ShowInTaskbar=$false;$script:window.ShowActivated=$false
 $script:ui=@{Girl=$script:window.FindName('Girl')};$script:bitmap=[Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $app 'assets\gpt-dragon-niang-bust.png'))
 Initialize-WidgetCharacter;$script:window.Show();$state=$script:characterAnimation
 Assert ($state.Clips.Keys.Count-eq 3 -and !$state.Clips.ContainsKey('complete')) 'Production registry includes an unwanted action'
 Assert ($state.Clips.working.Frames.Count-eq 12 -and $state.Clips.drag.Frames.Count-eq 12) 'New action frames did not load'
 Set-WidgetCharacterFrameAt 4;Set-WidgetCharacterWorking $true
 Assert ($state.CurrentAction-eq 'working' -and $state.Timer.IsEnabled) 'Work did not start'
 foreach($i in 1..3){Advance-WidgetCharacterAnimation};$workIndex=$state.Index
 Set-WidgetCharacterWorking $true
 Assert ($state.Index-eq $workIndex) 'Repeated busy event restarted working'
 $hasPress=Set-WidgetCharacterInteraction 'press'
 Assert (!$hasPress -and !$state.Timer.IsEnabled -and $state.Pressed) 'Missing press action did not retain pause feedback'
 $null=Set-WidgetCharacterInteraction 'drag';foreach($i in 1..3){Advance-WidgetCharacterAnimation};$dragIndex=$state.Index
 $null=Set-WidgetCharacterInteraction 'drag';$null=Set-WidgetCharacterInteraction 'drag'
 Assert ($state.CurrentAction-eq 'drag' -and $state.Index-eq $dragIndex -and $state.Timer.IsEnabled) 'Mouse moves restarted or paused drag'
 Assert ((Get-WidgetCharacterFrameCount)-eq 12) 'Active frame count was not reported'
 Assert ([object]::ReferenceEquals($script:ui.Girl.Source,$state.Clips.drag.Frames[$dragIndex].Bitmap) -and [object]::ReferenceEquals($script:alphaPixels,$state.Clips.drag.Frames[$dragIndex].Pixels)) 'Displayed image and hit-test alpha diverged'
 $null=Set-WidgetCharacterInteraction 'idle'
 Assert ($state.CurrentAction-eq 'working' -and $state.Index-eq $workIndex) 'Drag release did not restore the saved working frame'
 $null=Set-WidgetCharacterInteraction 'drag';Set-WidgetCharacterWorking $false
 Assert ($state.CurrentAction-eq 'drag') 'Work end interrupted dragging'
 $null=Set-WidgetCharacterInteraction 'idle'
 Assert ($state.CurrentAction-eq 'idle' -and $state.Index-eq 4) 'Work end while dragging did not restore idle position'
 $script:window.Hide();Set-WidgetCharacterWorking $true
 Assert ($state.CurrentAction-eq 'working' -and !$state.Timer.IsEnabled) 'Hidden work continued playing'
 $script:window.Show();Pump 220
 Assert ($state.CurrentAction-eq 'working' -and $state.Timer.IsEnabled -and $state.Index-gt 0) 'Showing did not resume work playback'
 $null=Set-WidgetCharacterMode 'original';$original=$script:ui.Girl.Source;$null=Set-WidgetCharacterInteraction 'drag'
 Assert ([object]::ReferenceEquals($script:ui.Girl.Source,$original)) 'Original mode displayed a pixel action'
 $null=Set-WidgetCharacterMode 'pixel'
 Assert ($state.CurrentAction-eq 'working') 'Pixel mode did not recover current work status'
 Set-WidgetCharacterWorking $false
 Assert ($state.CurrentAction-eq 'idle' -and (Get-WidgetCharacterFrameCount)-eq 9) 'Working completion did not return to nine-frame idle'
 Write-Output 'PASS: working/drag actual assets, loop continuity, press fallback, priority, resume, hidden pause, original mode and alpha synchronization'
}finally{
 if($script:window){Stop-WidgetCharacterAnimation;$script:window.Close()}
 $full=[IO.Path]::GetFullPath($testDir);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(!$full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full)-notlike 'gpt-working-animation-*'){throw 'Unsafe test cleanup'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
