# Static character palettes. Image sampling is bounded and runs only on a cache miss.
$script:characterThemeState=@{version=1;mode='default';characters=@{}}
$script:characterThemePalette=$null
$script:characterThemeBrushes=@{}
$script:characterThemeResources=[Collections.Generic.List[WeakReference]]::new()
$script:characterThemeFile=$null

function Test-WidgetThemeColor([string]$Color){return $Color-match '^#[0-9a-fA-F]{6}$'}
function Get-WidgetThemeHsl([string]$Hex){
  $color=[Windows.Media.ColorConverter]::ConvertFromString($Hex)
  $r=$color.R/255.0;$g=$color.G/255.0;$b=$color.B/255.0
  $max=[Math]::Max($r,[Math]::Max($g,$b));$min=[Math]::Min($r,[Math]::Min($g,$b));$delta=$max-$min;$light=($max+$min)/2
  $hue=0.0;$sat=0.0
  if($delta-gt 0){
    $sat=$delta/(1-[Math]::Abs(2*$light-1))
    if($max-eq $r){$hue=60*(($g-$b)/$delta%6)}elseif($max-eq $g){$hue=60*(($b-$r)/$delta+2)}else{$hue=60*(($r-$g)/$delta+4)}
    if($hue-lt 0){$hue+=360}
  }
  return @{H=$hue;S=$sat;L=$light}
}
function ConvertFrom-WidgetThemeHsl([double]$Hue,[double]$Saturation,[double]$Lightness){
  $c=(1-[Math]::Abs(2*$Lightness-1))*$Saturation;$h=$Hue/60;$x=$c*(1-[Math]::Abs($h%2-1));$m=$Lightness-$c/2
  if($h-lt 1){$r=$c;$g=$x;$b=0}elseif($h-lt 2){$r=$x;$g=$c;$b=0}elseif($h-lt 3){$r=0;$g=$c;$b=$x}elseif($h-lt 4){$r=0;$g=$x;$b=$c}elseif($h-lt 5){$r=$x;$g=0;$b=$c}else{$r=$c;$g=0;$b=$x}
  return '#{0:X2}{1:X2}{2:X2}' -f [int][Math]::Round(($r+$m)*255),[int][Math]::Round(($g+$m)*255),[int][Math]::Round(($b+$m)*255)
}
function Get-WidgetThemeLuminance([string]$Hex){
  $color=[Windows.Media.ColorConverter]::ConvertFromString($Hex);$sum=0.0
  foreach($channel in @(@{value=$color.R;weight=0.2126},@{value=$color.G;weight=0.7152},@{value=$color.B;weight=0.0722})){
    $v=$channel.value/255.0;$linear=if($v-le 0.04045){$v/12.92}else{[Math]::Pow(($v+0.055)/1.055,2.4)};$sum+=$linear*$channel.weight
  }
  return $sum
}
function Get-WidgetThemeContrast([string]$First,[string]$Second){
  $a=Get-WidgetThemeLuminance $First;$b=Get-WidgetThemeLuminance $Second
  return ([Math]::Max($a,$b)+0.05)/([Math]::Min($a,$b)+0.05)
}
function New-WidgetCharacterPalette([string]$Color){
  if(!(Test-WidgetThemeColor $Color)){$Color='#9B86C1'}
  $hsl=Get-WidgetThemeHsl $Color
  # Neutral images/overrides still produce a readable, restrained theme.
  $sat=if($hsl.S-lt 0.04){0.0}else{[Math]::Max(0.32,[Math]::Min(0.65,$hsl.S))}
  $palette=@{
    Accent=(ConvertFrom-WidgetThemeHsl $hsl.H $sat 0.40)
    Ink=(ConvertFrom-WidgetThemeHsl $hsl.H ($sat*0.65) 0.23)
    Muted=(ConvertFrom-WidgetThemeHsl $hsl.H ($sat*0.50) 0.35)
    Surface=(ConvertFrom-WidgetThemeHsl $hsl.H ($sat*0.55) 0.97)
    MenuSurface=(ConvertFrom-WidgetThemeHsl $hsl.H ($sat*0.45) 0.985)
    Border=(ConvertFrom-WidgetThemeHsl $hsl.H ($sat*0.65) 0.79)
    Hover=(ConvertFrom-WidgetThemeHsl $hsl.H ($sat*0.65) 0.92)
  }
  return $palette
}
function Get-WidgetImageThemeColors($Image){
  if(!$Image){return '#9B86C1'}
  $longest=[Math]::Max($Image.PixelWidth,$Image.PixelHeight)
  $sample=$Image
  if($longest-gt 64){$ratio=64.0/$longest;$sample=[Windows.Media.Imaging.TransformedBitmap]::new($Image,[Windows.Media.ScaleTransform]::new($ratio,$ratio))}
  $sample=[Windows.Media.Imaging.FormatConvertedBitmap]::new($sample,[Windows.Media.PixelFormats]::Bgra32,$null,0)
  $pixels=New-Object byte[] ($sample.PixelWidth*$sample.PixelHeight*4);$sample.CopyPixels($pixels,$sample.PixelWidth*4,0)
  $bins=@{}
  for($i=0;$i-lt $pixels.Length;$i+=4){
    $alpha=[int]$pixels[$i+3];if($alpha-lt 64){continue}
    $r=[double]$pixels[$i+2];$g=[double]$pixels[$i+1];$b=[double]$pixels[$i]
    $max=[Math]::Max($r,[Math]::Max($g,$b));$min=[Math]::Min($r,[Math]::Min($g,$b));$delta=$max-$min;$light=($max+$min)/510.0
    # Ignore line art, white clothing and nearly gray pixels; keep pastel hair.
    if($light-lt 0.12 -or $light-gt 0.97 -or $delta-lt 12){continue}
    $sat=$delta/255.0/(1-[Math]::Abs(2*$light-1))
    if($max-eq $r){$hue=60*(($g-$b)/$delta%6)}elseif($max-eq $g){$hue=60*(($b-$r)/$delta+2)}else{$hue=60*(($r-$g)/$delta+4)}
    if($hue-lt 0){$hue+=360}
    $weight=($alpha/255.0)*(0.5+0.5*$sat)
    # Reduce bright low-saturation peach, without excluding saturated orange hair.
    if($r-gt $g -and $g-gt $b -and $light-gt 0.72 -and $sat-lt 0.65 -and ($r-$g)-lt 45){$weight*=0.12}
    $key=[int][Math]::Floor($hue/20)
    if(!$bins.ContainsKey($key)){$bins[$key]=@{key=$key;weight=0.0;r=0.0;g=0.0;b=0.0}}
    $bin=$bins[$key];$bin.weight+=$weight;$bin.r+=$r*$weight;$bin.g+=$g*$weight;$bin.b+=$b*$weight
  }
  $ranked=@($bins.Values|Sort-Object @{Expression={$_.weight};Descending=$true},@{Expression={$_.key};Descending=$false})
  if(!$ranked.Count){return '#9B86C1'}
  foreach($bin in @($ranked|Select-Object -First 3)){
    '#{0:X2}{1:X2}{2:X2}' -f [int][Math]::Round($bin.r/$bin.weight),[int][Math]::Round($bin.g/$bin.weight),[int][Math]::Round($bin.b/$bin.weight)
  }
}
function Initialize-WidgetCharacterTheme([string]$DataDir){
  $script:characterThemeFile=Join-Path $DataDir 'character-themes.json'
  $state=@{version=1;mode='default';characters=@{}}
  try{
    if([IO.File]::Exists($script:characterThemeFile)){
      if(([IO.FileInfo]::new($script:characterThemeFile)).Length-gt 1MB){throw 'Theme file too large'}
      $saved=[IO.File]::ReadAllText($script:characterThemeFile,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
      if($saved.version-ne 1 -or $saved.mode-notin @('default','character')){throw 'Invalid theme state'}
      $state.mode=$saved.mode
      foreach($property in @($saved.characters.PSObject.Properties|Select-Object -First 256)){
        if($property.Name-notmatch '^[a-z][a-z0-9-]{0,63}$'){continue}
        $row=$property.Value;$colors=@($row.candidates|Where-Object{$_-is [string] -and (Test-WidgetThemeColor $_)}|Select-Object -First 3)
        $manual=if($row.manualColor-is [string] -and (Test-WidgetThemeColor $row.manualColor)){$row.manualColor.ToUpperInvariant()}else{$null}
        $state.characters[$property.Name]=@{signature=[string]$row.signature;candidates=$colors;manualColor=$manual}
      }
    }
  }catch{$state=@{version=1;mode='default';characters=@{}}}
  $script:characterThemeState=$state
}
function Save-WidgetCharacterTheme {
  if(!$script:characterThemeFile){return}
  $temp=$script:characterThemeFile+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
  try{
    [IO.File]::WriteAllText($temp,($script:characterThemeState|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($script:characterThemeFile)){[IO.File]::Replace($temp,$script:characterThemeFile,($script:characterThemeFile+'.bak'),$true)}else{[IO.File]::Move($temp,$script:characterThemeFile)}
  }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Resolve-WidgetCharacterTheme($Character,$Image,[switch]$Refresh){
  if(!$Character -or !$Image){return $null}
  $file=[IO.FileInfo]::new($Character.path);$signature=([string]$file.Length)+':'+$file.LastWriteTimeUtc.Ticks
  $entry=$script:characterThemeState.characters[$Character.id]
  if(!$Refresh -and $entry -and $entry.signature-eq $signature -and $entry.candidates.Count){return $entry}
  $manual=if($entry){$entry.manualColor}else{$null}
  $entry=@{signature=$signature;candidates=@(Get-WidgetImageThemeColors $Image);manualColor=$manual}
  $script:characterThemeState.characters[$Character.id]=$entry
  # A read-only disk must not make an otherwise valid character unavailable.
  try{Save-WidgetCharacterTheme}catch{$script:characterThemeNotice='主题色暂时无法保存。'}
  return $entry
}
function Get-WidgetThemeMappedColor([string]$Original){
  if($Original-eq 'BubbleSurface'){if($script:characterThemePalette){return $script:characterThemePalette.Surface};return '#FFFFFF'}
  if(!$script:characterThemePalette){return $Original}
  $hsl=Get-WidgetThemeHsl $Original
  if($hsl.H-lt 230 -or $hsl.H-gt 315 -or $hsl.S-lt 0.04){return $Original}
  $role=if($hsl.L-lt 0.55){'Ink'}elseif($hsl.L-lt 0.70){if($hsl.S-gt 0.30){'Accent'}else{'Muted'}}elseif($hsl.L-lt 0.86){'Border'}elseif($hsl.L-lt 0.95){'Hover'}else{'MenuSurface'}
  return $script:characterThemePalette[$role]
}
function Get-WidgetThemeBrush([string]$Original){
  $key=$Original.ToUpperInvariant()
  if(!$script:characterThemeBrushes.ContainsKey($key)){
    $color=Get-WidgetThemeMappedColor $Original
    $script:characterThemeBrushes[$key]=[Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($color))
  }
  return $script:characterThemeBrushes[$key]
}
function Register-WidgetThemeResources($Resources){
  foreach($reference in $script:characterThemeResources){if([Object]::ReferenceEquals($reference.Target,$Resources)){return}}
  $script:characterThemeResources.Add([WeakReference]::new($Resources))
}
function Set-WidgetThemeProperty($Element,[string]$Property,[string]$Original){
  $key='CharacterTheme'+$Original.TrimStart('#').ToUpperInvariant()
  $Element.Resources[$key]=Get-WidgetThemeBrush $Original
  Register-WidgetThemeResources $Element.Resources
  $field=$Element.GetType().GetField(($Property+'Property'),([Reflection.BindingFlags]::Public-bor [Reflection.BindingFlags]::Static-bor [Reflection.BindingFlags]::FlattenHierarchy))
  if(!$field){throw ('Unknown theme property: '+$Property)}
  $Element.SetResourceReference($field.GetValue($null),$key)
}
function Read-WidgetThemedXaml([string]$Xaml){
  $keys=@{}
  foreach($match in [regex]::Matches($Xaml,'#[0-9A-Fa-f]{6}(?![0-9A-Fa-f])')){
    $hex=$match.Value.ToUpperInvariant();$hsl=Get-WidgetThemeHsl $hex
    if($hsl.H-ge 230 -and $hsl.H-le 315 -and $hsl.S-ge 0.04){$keys[$hex]=$true}
  }
  foreach($hex in $keys.Keys){$Xaml=[regex]::Replace($Xaml,[regex]::Escape($hex),('{DynamicResource CharacterTheme'+$hex.Substring(1)+'}'),[Text.RegularExpressions.RegexOptions]::IgnoreCase)}
  $result=[Windows.Markup.XamlReader]::Parse($Xaml)
  # Template lookups use the parent control's resources. Keep mutable palettes
  # outside sealed templates: WPF may freeze brushes while sealing a style.
  if($result-isnot [Windows.FrameworkTemplate]){
    $resources=if($result-is [Windows.ResourceDictionary]){$result}else{$result.Resources}
    foreach($hex in $keys.Keys){$resources['CharacterTheme'+$hex.Substring(1)]=Get-WidgetThemeBrush $hex}
    Register-WidgetThemeResources $resources
  }
  return $result
}
function Set-WidgetCharacterBubbleTheme {
  if(!$script:ui -or !$script:ui.BubbleShape){return}
  foreach($name in @('BubbleShape','Tail','TailNear')){
    if($script:ui[$name]){$script:ui[$name].Fill=Get-WidgetThemeBrush 'BubbleSurface';$script:ui[$name].Stroke=Get-WidgetThemeBrush '#745A98'}
  }
  foreach($binding in @(@('Header','#7D6B91'),@('QuoteText','#745A98'),@('Refresh','#79659A'),@('MenuButton','#79659A'))){if($script:ui[$binding[0]]){$script:ui[$binding[0]].Foreground=Get-WidgetThemeBrush $binding[1]}}
  if($script:ui.MenuButton){$script:ui.MenuButton.Background=Get-WidgetThemeBrush '#EDE7F6'}
  if(Get-Command Get-QuotaRows -ErrorAction SilentlyContinue){
    foreach($row in (Get-QuotaRows)){
      $q=$row.window;$expired=$q -and $q.resetsAt -and [double]$q.resetsAt-le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      if($q -and !$expired -and [double]$q.used-lt 75){
        $script:ui[$row.prefix+'Left'].Foreground=Get-WidgetThemeBrush '#745A98'
        $script:ui[$row.prefix+'Bar'].Background=Get-WidgetThemeBrush '#9B86C1'
      }
    }
  }
}
function Update-WidgetCharacterTheme {
  if($script:characterThemeEditor -and $script:activeCharacter -and $script:characterThemeEditor.Tag-ne $script:activeCharacter.id){$script:characterThemeEditor.Close()}
  $script:characterThemePalette=$null
  if($script:characterThemeState.mode-eq 'character' -and $script:activeCharacter -and $script:bitmap){
    $entry=Resolve-WidgetCharacterTheme $script:activeCharacter $script:bitmap
    $color=if($entry.manualColor){$entry.manualColor}else{$entry.candidates[0]}
    $script:characterThemePalette=New-WidgetCharacterPalette $color
  }
  foreach($key in @($script:characterThemeBrushes.Keys)){
    $original=if($key-eq 'BUBBLESURFACE'){'BubbleSurface'}else{$key}
    $brush=[Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString((Get-WidgetThemeMappedColor $original)));$brush.Freeze()
    $script:characterThemeBrushes[$key]=$brush
  }
  for($i=$script:characterThemeResources.Count-1;$i-ge 0;$i--){
    $resources=$script:characterThemeResources[$i].Target
    if($null-eq $resources){$script:characterThemeResources.RemoveAt($i);continue}
    foreach($key in $script:characterThemeBrushes.Keys){$resources['CharacterTheme'+$key.TrimStart('#')]=$script:characterThemeBrushes[$key]}
  }
  if($script:widgetColors){Update-WidgetColorScene}else{Set-WidgetCharacterBubbleTheme}
}
function Set-WidgetCharacterThemeMode([ValidateSet('default','character')][string]$Mode){
  $script:characterThemeState.mode=$Mode;Save-WidgetCharacterTheme;Update-WidgetCharacterTheme
  if($script:settingsMenuUi){Update-WidgetSettingsMenu}
}
function Set-WidgetCharacterThemeColor([string]$Color){
  if(!(Test-WidgetThemeColor $Color)){throw '请输入 #RRGGBB 格式的颜色，例如 #79A890。'}
  $entry=Resolve-WidgetCharacterTheme $script:activeCharacter $script:bitmap
  if(!$entry){throw '请先选择一个角色。'}
  $entry.manualColor=$Color.ToUpperInvariant();$script:characterThemeState.mode='character';Save-WidgetCharacterTheme;Update-WidgetCharacterTheme
  if($script:settingsMenuUi){Update-WidgetSettingsMenu}
}
function Reset-WidgetCharacterThemeColor {
  $entry=Resolve-WidgetCharacterTheme $script:activeCharacter $script:bitmap -Refresh
  if($entry){$entry.manualColor=$null};$script:characterThemeState.mode='character';Save-WidgetCharacterTheme;Update-WidgetCharacterTheme
  if($script:settingsMenuUi){Update-WidgetSettingsMenu}
}
function Get-WidgetCharacterThemeStatus {
  $entry=if($script:activeCharacter){$script:characterThemeState.characters[$script:activeCharacter.id]}else{$null}
  $color=if($entry -and $entry.manualColor){$entry.manualColor}elseif($entry -and $entry.candidates.Count){$entry.candidates[0]}else{$null}
  return @{mode=$script:characterThemeState.mode;color=$color;automatic=![bool]($entry -and $entry.manualColor)}
}
function Open-WidgetCharacterThemeEditor {
  if($script:characterThemeEditor -and $script:characterThemeEditor.IsVisible){$script:characterThemeEditor.Activate()|Out-Null;return}
  $entry=Resolve-WidgetCharacterTheme $script:activeCharacter $script:bitmap
  $editor=Read-WidgetThemedXaml @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="角色主题色" Width="430" SizeToContent="Height" MinHeight="280" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner" FontFamily="Microsoft YaHei UI" FontSize="14" Background="#FAF8FD">
 <StackPanel Margin="24">
  <TextBlock Text="选择图片中的颜色，或输入自定义颜色" Foreground="#443552" FontWeight="SemiBold"/>
  <StackPanel x:Name="Candidates" Orientation="Horizontal" Margin="0,14,0,14"/>
  <TextBox x:Name="Hex" Padding="8" MaxLength="7" FontFamily="Consolas" FontSize="17"/>
  <TextBlock x:Name="Feedback" Text="仅改变界面配色，保留角色图片原色。" Foreground="#745A98" TextWrapping="Wrap" Margin="0,10,0,14"/>
  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="Apply" Content="应用" Padding="18,6" Margin="0,0,10,0"/><Button x:Name="Done" Content="关闭" Padding="18,6"/></StackPanel>
 </StackPanel>
</Window>
'@
  $script:characterThemeEditor=$editor;$editor.Owner=$script:window;$editor.Tag=$script:activeCharacter.id
  $editor.FindName('Hex').Text=if($entry.manualColor){$entry.manualColor}else{$entry.candidates[0]}
  foreach($color in $entry.candidates){
    $button=[Windows.Controls.Button]::new();$button.Width=84;$button.Height=34;$button.Margin=[Windows.Thickness]::new(0,0,10,0);$button.Tag=$color
    $button.Background=[Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($color));$button.ToolTip=$color
    [Windows.Automation.AutomationProperties]::SetName($button,('使用主题色 '+$color))
    $button.Add_Click({param($sender,$event)$script:characterThemeEditor.FindName('Hex').Text=[string]$sender.Tag;try{Set-WidgetCharacterThemeColor ([string]$sender.Tag);$script:characterThemeEditor.FindName('Feedback').Text='已应用，可在挂件和菜单查看效果。'}catch{$script:characterThemeEditor.FindName('Feedback').Text=$_.Exception.Message}})
    $editor.FindName('Candidates').Children.Add($button)|Out-Null
  }
  $editor.FindName('Apply').Add_Click({try{Set-WidgetCharacterThemeColor $script:characterThemeEditor.FindName('Hex').Text;$script:characterThemeEditor.FindName('Feedback').Text='已保存当前角色的主题色。'}catch{$script:characterThemeEditor.FindName('Feedback').Text=$_.Exception.Message}})
  $editor.FindName('Done').Add_Click({$script:characterThemeEditor.Close()})
  $editor.Add_KeyDown({param($sender,$event)if($event.Key-eq [Windows.Input.Key]::Escape){$sender.Close();$event.Handled=$true}})
  $editor.Add_Closed({$script:characterThemeEditor=$null})
  $editor.Show()
}
