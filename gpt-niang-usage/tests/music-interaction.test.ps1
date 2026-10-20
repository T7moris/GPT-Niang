param([string]$ResultFile)
$ErrorActionPreference='Stop'
$script:appDir=Split-Path $PSScriptRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime/music.ps1'),[Text.Encoding]::UTF8)))
Initialize-WidgetMusicTypes
$cases=0
foreach($dpi in @(1.0,1.5,2.0)){
 foreach($dt in @((1.0/30),(1.0/60),(1.0/144))){
  $m=[GptMusicMotion]::new(500*$dpi,650*$dpi,1200*$dpi,650*$dpi,132*$dpi,$dpi);$m.Phase=2;$m.Props=1
  $m.BeginHold();$pressed=0.0
  for($t=0;$t-lt .8;$t+=$dt){$m.MoveHeld(560*$dpi,460*$dpi,$dt);$m.Step($dt,$false,$true,($t/.5),.5,1);$pressed=[Math]::Max($pressed,$m.Bend)}
  if(!$m.Held -or $m.Y-gt 470*$dpi -or $pressed-lt .015){throw 'Pickup did not lift and elastically respond'}
  $m.Release()
  for($t=0;$t-lt 4;$t+=$dt){$m.Step($dt,$false,$true,($t/.5),.5,1);if($m.Y-gt $m.Floor+.001){throw 'Released body passed through floor'}}
  if($m.Held -or $m.Impacts-ne 3 -or $m.Phase-ne 2){throw 'Release did not land with exactly two diminishing rebounds and resume music'}
  $cases++
 }
}
# Execute the actual widget handlers with isolated native/input stand-ins.
$source=[IO.File]::ReadAllText((Join-Path $script:appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
foreach($name in @('pressDown','pressMove','pressUp')){
 $definition=$ast.Find({param($node)$node-is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text-eq ('$'+$name)},$true)
 $body=$definition.Right.Extent.Text.Trim();Set-Variable -Name $name -Value ([ScriptBlock]::Create($body.Substring(1,$body.Length-2)))
}
Add-Type -TypeDefinition @'
public static class GptWidgetNative {
 public struct Point {public int X,Y;}public struct Rect {public int Left,Top,Right,Bottom;}
 public static bool GetCursorPos(out Point p){p=new Point{X=200,Y=300};return true;}
 public static bool GetWindowRect(System.IntPtr h,out Rect r){r=new Rect();return true;}
}
'@
function Test-WidgetMusicActive {return $true}
function Pause-CompletionNotification {}
function Reset-WidgetAutoQuoteSchedule {}
function Hide-Quota {}
function Play-WidgetPressSound {}
function Play-WidgetReleaseSound {}
$script:colorRollCalls=0;function Get-WidgetColorRoll {$script:colorRollCalls++;return .5}
function Stop-WidgetMusic {throw 'Music must remain enabled during pickup'}
function Animate-Press {throw 'Ordinary root scaling must not override music physics'}
function Click-Character {throw 'Music pickup must not switch to the ordinary quota click'}
$script:saved=0;function Save-Settings {$script:saved++}
$script:widgetHandle=[IntPtr](1)
$script:colorMode='mixed';$script:colorChance=.5
$script:widgetMusic=[pscustomobject]@{began=0;released=0;ColorEnabled=$false}
$script:widgetMusic|Add-Member ScriptMethod Redraw {}
$script:widgetMusic|Add-Member ScriptMethod BeginHold {param($x,$y)$this.began++}
$script:widgetMusic|Add-Member ScriptMethod EndHold {$this.released++}
$script:hostFollower=[pscustomobject]@{};$script:hostFollower|Add-Member ScriptMethod Suspend {throw 'Pickup must use the existing active follower'}
$script:hostEventTimer=[pscustomobject]@{};$script:hostEventTimer|Add-Member ScriptMethod Start {}
$sender=[pscustomobject]@{captured=$false};$sender|Add-Member ScriptMethod CaptureMouse {$this.captured=$true;return $true};$sender|Add-Member ScriptMethod ReleaseMouseCapture {$this.captured=$false}
$event=[pscustomobject]@{Handled=$false}
& $pressDown $sender $event
& $pressMove $sender $event
& $pressUp $sender $event
if($script:widgetMusic.began-ne 1 -or $script:widgetMusic.released-ne 1 -or $sender.captured -or $script:drag -or $script:saved){throw 'Music mouse routing changed settings, lost capture cleanup, or failed to release'}
if($script:colorRollCalls-ne 1){throw 'Actual mouse handlers must roll character color once on pickup and never on move or release'}
$throwCases=0;$glideCases=0;$minGlide=1e9
foreach($dpi in @(1.0,1.5,2.0)){
 foreach($dt in @((1.0/30),(1.0/60),(1.0/144))){
  $m=[GptMusicMotion]::new(200*$dpi,650*$dpi,900*$dpi,650*$dpi,132*$dpi,$dpi);$m.Phase=2;$m.BeginHold(200*$dpi,500*$dpi)
  for($t=0;$t-lt .35;$t+=$dt){
   $px=(200+1000*$t)*$dpi;$py=(500-500*$t)*$dpi
   $m.MoveHeld($px,$py,$dt,$px,$py);$m.Step($dt,$false,$true,($t/.5),.5,1)
  }
  $m.Release()
  if($m.Vx-lt 700*$dpi -or $m.Vy-gt -350*$dpi -or [Math]::Abs($m.Vx/$m.Vy+2)-gt .1){throw 'Release vector does not preserve recent pointer speed and direction'}
  $previous=$m.Vx;$bounced=$false
  for($t=0;$t-lt 8;$t+=$dt){
   $m.Step($dt,$false,$true,($t/.5),.5,1)
   if($m.X-lt $m.FlightMargin-.001 -or $m.X-gt $m.Width-$m.FlightMargin+.001 -or $m.Y-gt $m.Floor+.001){throw 'Thrown figure escaped the scene bounds'}
   if($m.Phase-eq 0 -and $previous-gt 0 -and $m.Vx-lt 0){$bounced=$true};$previous=$m.Vx
  }
  if(!$bounced -or $m.Phase-ne 2 -or $m.Impacts-ne 3){throw 'Throw did not bounce at a wall, land twice elastically, and resume rhythm'}
  $m.BeginHold(0,0)
  for($i=0;$i-lt 20;$i++){$m.SamplePointer(($i*1000),(-$i*1000),.005)}
  if([Math]::Sqrt($m.ThrowX*$m.ThrowX+$m.ThrowY*$m.ThrowY)-gt 2000*$dpi+.001){throw 'Throw speed is not bounded as a vector'}
  for($t=0;$t-lt .5;$t+=$dt){$m.SamplePointer(19000,-19000,$dt)}
  if([Math]::Abs($m.ThrowX)+[Math]::Abs($m.ThrowY)-gt 2*$dpi){throw 'A stationary hold retained stale throw momentum'}
  $throwCases++
  # A horizontal throw just above the floor used to lose most of its speed
  # through three floor multipliers, props fade, then automatic walking.
  $g=[GptMusicMotion]::new(600*$dpi,610*$dpi,5000*$dpi,650*$dpi,132*$dpi,$dpi);$g.Phase=2;$g.BeginHold(600*$dpi,610*$dpi)
  for($t=$dt;$t-lt .20;$t+=$dt){$g.SamplePointer((600+1000*$t)*$dpi,610*$dpi,$dt)}
  $g.Release();$origin=$g.X;$speed=$g.Vx;$contactSpeed=0.0;$contactSeen=$false
  for($t=0;$t-lt 1.0;$t+=$dt){
   $g.Step($dt,$false,$true,($t/.5),.5,1)
   if(!$contactSeen -and $g.Impacts-ge 1){$contactSeen=$true;$contactSpeed=$g.Vx}
  }
  $distance=($g.X-$origin)/$dpi;$minGlide=[Math]::Min($minGlide,$distance)
  if(!$contactSeen -or $contactSpeed-lt $speed*.80 -or $distance-lt 450 -or $g.Vx-lt 180*$dpi){throw 'Low throw was braked by landing or the automatic rhythm walk'}
  for($t=0;$t-lt 8;$t+=$dt){$g.Step($dt,$false,$false,0,.5,1)}
  if($g.Phase-ne 2 -or $g.Moving){throw 'Throw glide did not eventually settle after music stopped'}
  $glideCases++
 }
}
$result=@{passed=$true;physicsCases=$cases;throwCases=$throwCases;glideCases=$glideCases;minOneSecondGlideDip=$minGlide;recentPointerVector=$true;wallReflection=$true;vectorSpeedBound=$true;staleMomentumCleared=$true;actualHandlerRouting=$true;musicRemainsEnabled=$true;savedPositionUnchanged=$true}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
Write-Output ('PASS: '+$cases+' pickup/drop and '+$throwCases+' throw-vector cases; bounded speed, wall reflection, two rebounds, resumed rhythm and unchanged preferences')
