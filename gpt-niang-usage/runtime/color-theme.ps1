# Native WPF flowing colours. One shared phase keeps every surface in sync.
$script:colorMode='mixed'
$script:colorChance=0.5
$script:colorTextChance=3
$script:colorPaused=$false
$script:widgetColors=$null
$script:widgetColorRandom=[Random]::new()
$script:colorSpecialQuotes=@('Token来，Token来')
$script:colorSceneScope='none';$script:colorSceneKey='';$script:colorSpecialLast=''

function Get-WidgetBubbleQuote([string]$DataDir){
  # Choose the text from its own pool before drawing an unrelated appearance.
  $text=Get-WidgetQuote $DataDir
  if($script:colorMode-ne 'mixed'){return $text}
  $roll=Get-WidgetColorRoll
  $scope=if($roll-lt ($script:colorChance/100.0)){'full'}elseif($roll-lt (($script:colorChance+$script:colorTextChance)/100.0)){'text'}else{'none'}
  $script:colorSceneScope=$scope;$script:colorSceneKey=([string]$script:sceneRevision)+'|'+$text
  return $text
}
function Get-WidgetColorScope([string]$Text){
  if($script:colorMode-eq 'mixed'){
    if(!$script:collapsed -and $script:bubbleMode-eq 'quote' -and $script:colorSceneKey-eq (([string]$script:sceneRevision)+'|'+$Text)){return $script:colorSceneScope}
    return 'none'
  }
  if(Test-WidgetColorActive $Text){return 'full'}
  return 'none'
}

function Read-WidgetColorTriggers {
  try{
    $file=Join-Path $script:dataDir 'color-triggers.json'
    if(Test-Path -LiteralPath $file){
      $saved=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json
      if($null-ne $saved.quotes){$script:colorSpecialQuotes=@(ConvertTo-WidgetQuoteRows $saved.quotes|ForEach-Object{$_.text})}
    }
  }catch{}
}
function Save-WidgetColorTriggers($Lines){
  $script:colorSpecialQuotes=@(ConvertTo-WidgetQuoteRows $Lines|ForEach-Object{$_.text})
  Write-WidgetJson (Join-Path $script:dataDir 'color-triggers.json') @{version=1;quotes=@($script:colorSpecialQuotes)}
  Update-WidgetColorScene
}
function Open-ColorTriggerEditor {
  if($script:colorTriggerEditor -and $script:colorTriggerEditor.IsVisible){$script:colorTriggerEditor.Activate()|Out-Null;return}
  $editor=Read-WidgetThemedXaml (@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="GPT 娘 · 特殊台词" Width="540" Height="430" MinWidth="440" MinHeight="330" ShowInTaskbar="False" FontFamily="Microsoft YaHei UI" FontSize="14" Background="#FAF8FD" WindowStartupLocation="CenterScreen">
 <Grid Margin="22"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TextBlock Text="一行一句。仅用于按台词匹配的变色模式；独立随机模式忽略此名单。台词请在我的语录中添加。" TextWrapping="Wrap" Foreground="#745A98" Margin="0,0,0,14"/>
  <TextBox x:Name="Lines" Grid.Row="1" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" FontSize="16" Padding="12" Background="White" BorderBrush="#DDD4EA"/>
  <TextBlock x:Name="Feedback" Grid.Row="2" Text="可以留空。这里不会改变台词的抽取概率。" TextWrapping="Wrap" Foreground="#745A98" Margin="0,12,0,10"/>
  <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="Save" Content="保存" Padding="20,6" Margin="0,0,10,0"/><Button x:Name="Done" Content="关闭" Padding="20,6"/></StackPanel>
 </Grid>
</Window>
'@)
  $script:colorTriggerEditor=$editor;$editor.Owner=$script:window
  $editor.FindName('Lines').Text=$script:colorSpecialQuotes-join [Environment]::NewLine
  $editor.FindName('Save').Add_Click({
    try{
      $rows=@($script:colorTriggerEditor.FindName('Lines').Text-split '\r?\n'|ForEach-Object{$_.Trim()}|Where-Object{$_})
      if(@(ConvertTo-WidgetQuoteRows $rows).Count-ne @($rows|Select-Object -Unique).Count){throw '台词不能超过200字。'}
      Save-WidgetColorTriggers $rows
      $script:colorTriggerEditor.FindName('Feedback').Text='已保存 '+$script:colorSpecialQuotes.Count+' 句特殊台词。'
    }catch{$script:colorTriggerEditor.FindName('Feedback').Text=$_.Exception.Message}
  })
  $editor.FindName('Done').Add_Click({$script:colorTriggerEditor.Close()})
  $editor.Add_KeyDown({param($sender,$event)if($event.Key-eq [Windows.Input.Key]::Escape){$sender.Close();$event.Handled=$true}})
  $editor.Show()
}
function Get-WidgetColorRoll {$script:widgetColorRandom.NextDouble()}
function Test-WidgetColorActive([string]$Text){
  if($script:colorMode-eq 'original'){return $false}
  if($script:colorMode-in @('linked','rainbow')){return $true}
  if($script:collapsed -or $script:bubbleMode-ne 'quote'){return $false}
  $special=$script:colorSpecialQuotes-contains $Text
  if($script:colorMode-eq 'special'){return $special}
  if($script:colorMode-eq 'surprise' -and $special){return $true}
  # Draw once per displayed quote, never once per quota refresh or animation tick.
  $key=([string]$script:sceneRevision)+'|'+$Text
  if($script:widgetColors.decisionKey-ne $key){
    $script:widgetColors.decisionKey=$key
    $script:widgetColors.lucky=(Get-WidgetColorRoll)-lt ($script:colorChance/100.0)
  }
  return $script:widgetColors.lucky
}
function Restore-WidgetOriginalColors([switch]$KeepAnimation) {
  foreach($binding in $script:widgetColors.original){$binding.element.($binding.property)=$binding.value}
  foreach($row in (Get-QuotaRows)){
    $q=$row.window
    $expired=$q -and $q.resetsAt -and [double]$q.resetsAt-le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $ink=if(!$q -or $expired){'#95889F'}elseif([double]$q.used-ge 90){'#B74839'}elseif([double]$q.used-ge 75){'#A06C1C'}else{'#745A98'}
    $bar=if(!$q){'#AA95CD'}elseif($expired){'#B3A7C0'}elseif([double]$q.used-ge 90){'#D77659'}elseif([double]$q.used-ge 75){'#D0A051'}else{'#9B86C1'}
    $script:ui[$row.prefix+'Left'].Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($ink)
    $script:ui[$row.prefix+'Bar'].Background=[Windows.Media.BrushConverter]::new().ConvertFromString($bar)
  }
  $script:widgetColors.halo.Visibility=[Windows.Visibility]::Collapsed
  $script:widgetColors.tint.Visibility=[Windows.Visibility]::Collapsed
  if(!$KeepAnimation){Set-WidgetColorAnimation $false}
  if(Get-Command Set-WidgetCharacterBubbleTheme -ErrorAction SilentlyContinue){Set-WidgetCharacterBubbleTheme}
}

function Get-WidgetColorPalette([string]$Name){
  switch($Name){
    'creeper' {@('#45986A','#90A84B','#58A897','#749E69','#B3AA54','#45986A');break}
    'token' {@('#D39B28','#E97869','#C9609E','#956CDA','#E49B41','#D39B28');break}
    'deepsea' {@('#368CCA','#37B5BD','#548BE0','#826BC5','#47B2CC','#368CCA');break}
    'claude' {@('#C17A4C','#D89864','#CA776B','#B06F96','#DEAA70','#C17A4C');break}
    'gemini' {@('#507BDB','#8370E4','#BE74CF','#529AD9','#57B5B2','#507BDB');break}
    default {@('#D773AD','#9A79DC','#579DCF','#43AE94','#DBA15C','#D773AD')}
  }
}
function Resolve-WidgetColorPalette([string]$Text){
  $modelCount=0
  foreach($pattern in @('Claude|克劳德','Gemini|双子','DeepSeek|鲸|肥鱼|白饭','GPT|ChatGPT')){if($Text-match $pattern){$modelCount++}}
  if($modelCount-ge 2){return 'rainbow'}
  if($Text-match 'Claude|克劳德|压缩|失忆|重构'){return 'claude'}
  if($Text-match 'Gemini|双子|吃醋|竞品'){return 'gemini'}
  if($Text-match 'DeepSeek|鲸|肥鱼|白饭|接住|等等'){return 'deepsea'}
  if($Text-match '苦力怕|甘蔗|土豆|打怪|存档|嘶——|屠龙'){return 'creeper'}
  if($Text-match 'token|额度|余额|充值'){return 'token'}
  return 'rainbow'
}
function Mix-WidgetColor($Color,$Other,[double]$Amount){
  [Windows.Media.Color]::FromRgb(
    [byte][Math]::Round($Color.R*(1-$Amount)+$Other.R*$Amount),
    [byte][Math]::Round($Color.G*(1-$Amount)+$Other.G*$Amount),
    [byte][Math]::Round($Color.B*(1-$Amount)+$Other.B*$Amount))
}
function New-WidgetFlowBrush([string]$Role){
  $brush=[Windows.Media.LinearGradientBrush]::new()
  $brush.StartPoint=[Windows.Point]::new(0,0.5);$brush.EndPoint=[Windows.Point]::new(1,0.5)
  $brush.SpreadMethod=[Windows.Media.GradientSpreadMethod]::Repeat
  $brush.RelativeTransform=$script:widgetColors.phase
  foreach($i in 0..10){$brush.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Colors]::White,$i/10.0))}
  $script:widgetColors.brushes[$Role]=$brush
  return $brush
}
function Set-WidgetColorAnimation([bool]$Running){
  if(!$script:widgetColors -or $script:widgetColors.running-eq $Running){return}
  $phase=$script:widgetColors.phase;$current=$phase.X
  $phase.BeginAnimation([Windows.Media.TranslateTransform]::XProperty,$null);$phase.X=$current
  if($Running){
    $animation=[Windows.Media.Animation.DoubleAnimation]::new($current,$current-1,[Windows.Duration]::new([TimeSpan]::FromSeconds(2.6)))
    $animation.RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever
    $phase.BeginAnimation([Windows.Media.TranslateTransform]::XProperty,$animation)
  }
  $script:widgetColors.running=$Running
}
function Set-WidgetColorPalette([string]$Name,[switch]$Immediate){
  if($script:widgetColors.palette-eq $Name -and !$Immediate){return}
  $keys=@(Get-WidgetColorPalette $Name | ForEach-Object {[Windows.Media.ColorConverter]::ConvertFromString($_)})
  foreach($role in @('accent','ink','surface')){
    $brush=$script:widgetColors.brushes[$role]
    foreach($i in 0..10){
      $position=$i/10.0*($keys.Count-1);$index=[Math]::Min($keys.Count-2,[int][Math]::Floor($position))
      $target=Mix-WidgetColor $keys[$index] $keys[$index+1] ($position-$index)
      if($role-eq 'ink'){$target=Mix-WidgetColor $target ([Windows.Media.ColorConverter]::ConvertFromString('#271938')) 0.44}
      elseif($role-eq 'surface'){$target=Mix-WidgetColor $target ([Windows.Media.Colors]::White) 0.92}
      $stop=$brush.GradientStops[$i];$from=$stop.Color
      $stop.BeginAnimation([Windows.Media.GradientStop]::ColorProperty,$null);$stop.Color=$target
      if(!$Immediate){
        $animation=[Windows.Media.Animation.ColorAnimation]::new($from,$target,[Windows.Duration]::new([TimeSpan]::FromMilliseconds(320)))
        $animation.FillBehavior=[Windows.Media.Animation.FillBehavior]::Stop
        $stop.BeginAnimation([Windows.Media.GradientStop]::ColorProperty,$animation)
      }
    }
  }
  $script:widgetColors.palette=$Name
}
function Sync-WidgetCharacterColors {
  if(!$script:widgetColors -or !$script:ui.Girl){return}
  foreach($name in @('halo','tint')){
    $overlay=$script:widgetColors[$name]
    if(!$overlay){continue}
    $overlay.Width=$script:ui.Girl.Width;$overlay.Height=$script:ui.Girl.Height
    [Windows.Controls.Canvas]::SetLeft($overlay,[Windows.Controls.Canvas]::GetLeft($script:ui.Girl))
    [Windows.Controls.Canvas]::SetTop($overlay,[Windows.Controls.Canvas]::GetTop($script:ui.Girl))
  }
}
function Initialize-WidgetColors {
  if($script:widgetColors){return}
  $script:widgetColors=@{phase=[Windows.Media.TranslateTransform]::new();brushes=@{};original=@();palette='';running=$false;active=$false;decisionKey='';lucky=$false}
  Read-WidgetColorTriggers
  foreach($binding in @(
    @('BubbleShape','Fill'),@('BubbleShape','Stroke'),@('Tail','Fill'),@('Tail','Stroke'),@('TailNear','Fill'),@('TailNear','Stroke'),
    @('Header','Foreground'),@('QuoteText','Foreground'),@('Refresh','Foreground'),@('MenuButton','Foreground'),@('MenuButton','Background'))){
    $element=$script:ui[$binding[0]];$property=$binding[1]
    $script:widgetColors.original+=@{element=$element;property=$property;value=$element.$property}
  }
  foreach($role in @('accent','ink','surface')){$null=New-WidgetFlowBrush $role}
  Set-WidgetColorPalette 'rainbow' -Immediate
  $mask=[Windows.Media.ImageBrush]::new($script:ui.Girl.Source)
  $mask.Stretch=[Windows.Media.Stretch]::Uniform
  $root=$script:ui.Root;$girlIndex=$root.Children.IndexOf($script:ui.Girl)
  $halo=[Windows.Shapes.Rectangle]::new();$halo.Width=$script:ui.Girl.Width;$halo.Height=$script:ui.Girl.Height
  $halo.Fill=$script:widgetColors.brushes.accent;$halo.Opacity=0.62;$halo.OpacityMask=$mask
  $halo.IsHitTestVisible=$false;$halo.Effect=[Windows.Media.Effects.BlurEffect]::new();$halo.Effect.Radius=7
  [Windows.Controls.Canvas]::SetLeft($halo,[Windows.Controls.Canvas]::GetLeft($script:ui.Girl))
  [Windows.Controls.Canvas]::SetTop($halo,[Windows.Controls.Canvas]::GetTop($script:ui.Girl))
  $root.Children.Insert($girlIndex,$halo)
  $tint=[Windows.Shapes.Rectangle]::new();$tint.Width=$script:ui.Girl.Width;$tint.Height=$script:ui.Girl.Height
  $tint.Fill=$script:widgetColors.brushes.accent;$tint.Opacity=0.34;$tint.OpacityMask=$mask;$tint.IsHitTestVisible=$false
  [Windows.Controls.Canvas]::SetLeft($tint,[Windows.Controls.Canvas]::GetLeft($script:ui.Girl))
  [Windows.Controls.Canvas]::SetTop($tint,[Windows.Controls.Canvas]::GetTop($script:ui.Girl))
  $root.Children.Insert($root.Children.IndexOf($script:ui.Girl)+1,$tint)
  $script:widgetColors.halo=$halo;$script:widgetColors.tint=$tint
  $script:window.Add_IsVisibleChanged({
    if($script:widgetColors){Update-WidgetColorScene}
  })
  $script:window.Add_Closed({if($script:widgetColors){Set-WidgetColorAnimation $false}})
  Update-WidgetColorScene
}
function Update-WidgetColorScene {
  if(!$script:widgetColors){return}
  if($script:widgetMusic -and $script:widgetMusic.Enabled){Restore-WidgetOriginalColors;return}
  $text=if($script:bubbleMode-eq 'quote'){[string]$script:ui.QuoteText.Tag}else{''}
  if(!$text -and $script:bubbleMode-eq 'quote'){$text=$script:ui.QuoteText.Text}
  $script:widgetColors.scope=Get-WidgetColorScope $text
  $script:widgetColors.active=$script:widgetColors.scope-ne 'none'
  if(!$script:widgetColors.active){Restore-WidgetOriginalColors;return}
  $palette=if($script:colorMode-eq 'rainbow' -or $script:bubbleMode-ne 'quote'){'rainbow'}else{Resolve-WidgetColorPalette $text}
  Set-WidgetColorPalette $palette
  $accent=$script:widgetColors.brushes.accent;$surface=$script:widgetColors.brushes.surface;$ink=$script:widgetColors.brushes.ink
  if($script:widgetColors.scope-eq 'text'){
    Restore-WidgetOriginalColors -KeepAnimation
    $script:ui.QuoteText.Foreground=$ink
    Set-WidgetColorAnimation ($script:window.IsVisible -and !$script:colorPaused)
    return
  }
  foreach($name in @('BubbleShape','Tail','TailNear')){$script:ui[$name].Stroke=$accent;$script:ui[$name].Fill=$surface}
  foreach($name in @('Header','QuoteText','Refresh','MenuButton')){$script:ui[$name].Foreground=$ink}
  $script:ui.MenuButton.Background=$surface
  foreach($row in (Get-QuotaRows)){
    $q=$row.window
    $expired=$q -and $q.resetsAt -and [double]$q.resetsAt-le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    # Preserve existing orange/red quota warnings and unavailable values.
    if($q -and !$expired -and [double]$q.used-lt 75){
      $script:ui[$row.prefix+'Left'].Foreground=$ink;$script:ui[$row.prefix+'Bar'].Background=$accent
    }
  }
  $script:widgetColors.halo.Visibility=[Windows.Visibility]::Visible
  $script:widgetColors.tint.Visibility=[Windows.Visibility]::Visible
  Set-WidgetColorAnimation ($script:window.IsVisible -and !$script:colorPaused)
}
function Set-WidgetColorMode([ValidateSet('original','linked','rainbow','surprise','rare','special','mixed')][string]$Mode){
  $script:colorMode=$Mode
  # Refresh quota semantic colours first, then apply the selected appearance.
  Update-Quota;Update-WidgetColorScene
}
