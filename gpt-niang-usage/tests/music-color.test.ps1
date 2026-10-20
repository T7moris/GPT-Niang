param([string]$ResultFile)
$ErrorActionPreference='Stop';$app=Split-Path $PSScriptRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $app 'runtime/music.ps1'))))
$script:widgetMusic=[pscustomobject]@{Enabled=$true;ColorEnabled=$false;draws=0}
$script:widgetMusic|Add-Member ScriptMethod Redraw {$this.draws++}
$script:roll=.5;$script:rollCalls=0
function Get-WidgetColorRoll {$script:rollCalls++;return $script:roll}
$cases=0
foreach($chance in @(0,.1,.5,3,30)){
 foreach($mode in @('mixed','original')){
  foreach($roll in @(0,.004,.008,.011,.05,.59,.61,.999)){
   $script:colorChance=$chance;$script:colorMode=$mode;$script:roll=$roll
   $before=$script:rollCalls;Set-WidgetMusicPickupColor
   $expected=$mode-ne 'original' -and $chance-gt 0 -and $roll-lt [Math]::Min(1.0,$chance*2/100)
   if($script:widgetMusic.ColorEnabled-ne $expected -or $script:musicColorEnabled-ne $expected -or $script:colorChance-ne $chance){throw ('Pickup color boundary failed: chance='+$chance+' mode='+$mode+' roll='+$roll+' expected='+$expected+' actual='+$script:widgetMusic.ColorEnabled+' saved='+$script:colorChance)}
   $expectedRolls=if($mode-ne 'original' -and $chance-gt 0){1}else{0}
   if($script:rollCalls-$before-ne $expectedRolls){throw 'Color must draw at most once per pickup, never each animation frame'}
   $cases++
  }
 }
}
$r=@{passed=$true;cases=$cases;doubledProbability=$true;oneRollPerPickup=$true;originalModeRespected=$true;savedProbabilityUnchanged=$true}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($r|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
Write-Output ('PASS: '+$cases+' pickup color boundaries; doubled chance, original mode, no preference mutation')
