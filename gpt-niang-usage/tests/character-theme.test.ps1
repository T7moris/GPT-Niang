param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
$module=Join-Path $appDir 'runtime\character-theme.ps1'
if(Test-Path -LiteralPath $module){. ([ScriptBlock]::Create([IO.File]::ReadAllText($module,[Text.Encoding]::UTF8)))}
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message}}
Assert ([bool](Get-Command Get-WidgetImageThemeColors -ErrorAction SilentlyContinue)) 'Character theme extraction is not implemented'
function New-ThemeFixture([string[]]$Colors,[int[]]$Counts){
  $width=100;$height=100;$pixels=New-Object byte[] ($width*$height*4);$position=0
  for($n=0;$n-lt $Colors.Count;$n++){
    $c=[Windows.Media.ColorConverter]::ConvertFromString($Colors[$n])
    for($j=0;$j-lt $Counts[$n];$j++){$i=$position*4;$pixels[$i]=$c.B;$pixels[$i+1]=$c.G;$pixels[$i+2]=$c.R;$pixels[$i+3]=$c.A;$position++}
  }
  $image=[Windows.Media.Imaging.BitmapSource]::Create($width,$height,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$pixels,$width*4);$image.Freeze();return $image
}
# Hidden saturated pixels, skin and outlines must not displace pastel green hair.
$green=New-ThemeFixture @('#00FF00FF','#FFB4D7B9','#FFFFE1CF','#FF78D4F5','#FF102016') @(5000,2800,1400,400,400)
$colors=@(Get-WidgetImageThemeColors $green)
Assert ($colors.Count-ge 1 -and $colors.Count-le 3) 'Return one to three candidates'
$main=[Windows.Media.ColorConverter]::ConvertFromString($colors[0])
Assert ($main.G-gt $main.R -and $main.G-gt $main.B) 'Pastel green hair wins over transparent pixels and skin'
$orange=New-ThemeFixture @('#FFFF944C','#FFFFE1CF','#FF281A16') @(5500,3500,1000)
$warm=@(Get-WidgetImageThemeColors $orange)
$c=[Windows.Media.ColorConverter]::ConvertFromString($warm[0])
Assert ($c.R-gt $c.G -and $c.G-gt $c.B -and ($c.R-$c.B)-gt 80) 'Orange hair remains eligible while skin is downweighted'
$neutral=New-ThemeFixture @('#FFFFFFFF','#FF000000','#FF999999') @(4000,3000,3000)
Assert ((@(Get-WidgetImageThemeColors $neutral))[0]-eq '#9B86C1') 'A monochrome picture has a stable purple fallback'
foreach($color in @('#B4D7B9','#FFFF00','#FF944C','#173ADD','#070707','#FFFFFF')){
  $palette=New-WidgetCharacterPalette $color
  Assert ((Get-WidgetThemeContrast $palette.Ink $palette.Surface)-ge 4.5) ('Readable bubble text for '+$color)
  Assert ((Get-WidgetThemeContrast $palette.Muted $palette.MenuSurface)-ge 4.5) ('Readable menu details for '+$color)
}
$fixture=Join-Path $TestRoot ('theme-fixture-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
try{
  Initialize-WidgetCharacterTheme $fixture
  $character=[pscustomobject]@{id='custom-0123456789abcdef0123456789abcdef';path=(Join-Path $fixture 'image.png');kind='custom'}
  [IO.File]::WriteAllText($character.path,'image signature fixture')
  $script:activeCharacter=$character;$script:bitmap=$green
  $entry=Resolve-WidgetCharacterTheme $character $green
  Assert ($entry.candidates.Count-ge 1) 'New character receives cached suggestions'
  Set-WidgetCharacterThemeColor '#CB6C34'
  Initialize-WidgetCharacterTheme $fixture
  Assert ($script:characterThemeState.characters[$character.id].manualColor-eq '#CB6C34') 'Manual color survives reload by character ID'
  Assert ($script:characterThemeState.mode-eq 'character') 'Manual selection enables character theme'
  Set-WidgetCharacterThemeMode 'default'
  Initialize-WidgetCharacterTheme $fixture
  Assert ($script:characterThemeState.mode-eq 'default') 'Default-purple preference survives restart'
  Assert ($script:characterThemeState.characters[$character.id].manualColor-eq '#CB6C34') 'Disabling theme keeps the per-character override'
  Set-WidgetCharacterThemeMode 'character'
  Reset-WidgetCharacterThemeColor
  Assert (!$script:characterThemeState.characters[$character.id].manualColor) 'Automatic reset removes only this character override'
  $other=[pscustomobject]@{id='gpt-dragon';path=$character.path;kind='built-in'}
  $entry=Resolve-WidgetCharacterTheme $other $orange
  Assert ($entry.candidates[0]-ne $script:characterThemeState.characters[$character.id].candidates[0]) 'Two characters retain independent palettes'
  [IO.File]::WriteAllText((Join-Path $fixture 'character-themes.json'),'{broken')
  Initialize-WidgetCharacterTheme $fixture
  Assert ($script:characterThemeState.mode-eq 'default') 'Invalid theme state fails back to original purple without damaging character settings'
}finally{[IO.Directory]::Delete($fixture,$true)}
Write-Output 'PASS: image alpha/skin/neutral handling, palette contrast, independent character overrides, automatic reset and persistence'
