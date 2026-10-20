function Initialize-WidgetQuoteLayouts([string]$AppDir){
  $script:quoteLayoutMap=@{};$script:quoteLayoutHints=@{};$script:quoteLayoutCache=@{}
  $file=Join-Path $AppDir 'assets\quote-layouts.json'
  if(![IO.File]::Exists($file)){return}
  try{
    $profiles=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8)|ConvertFrom-Json
    foreach($row in $profiles.quotes){
      if($row.text-isnot [string] -or $row.display-isnot [string]){continue}
      if(($row.text-replace '\s','')-cne ($row.display-replace '\s','')){continue}
      $script:quoteLayoutMap[$row.text]=$row.display
      if($row.layout){$script:quoteLayoutHints[$row.display]=$row.layout}
    }
  }catch{}
}

function Measure-WidgetQuoteLayout([string]$Value,$TextBlock,$Typeface,[double]$Size,[double]$Width,[int]$ExpectedLines=0){
  $formatted=[Windows.Media.FormattedText]::new($Value,[Globalization.CultureInfo]::CurrentCulture,[Windows.FlowDirection]::LeftToRight,$Typeface,$Size,$TextBlock.Foreground)
  $formatted.MaxTextWidth=$Width;$formatted.TextAlignment=[Windows.TextAlignment]::Center;$formatted.LineHeight=$Size*1.15
  if($formatted.Height-gt 134){return}
  $geometry=$formatted.BuildGeometry([Windows.Point]::new(155-$Width/2,85-$formatted.Height/2))
  if($geometry.Bounds.IsEmpty){return}
  $offsetX=155-($geometry.Bounds.Left+$geometry.Bounds.Width/2)
  $offset=85-($geometry.Bounds.Top+$geometry.Bounds.Height/2)
  $geometry.Transform=[Windows.Media.TranslateTransform]::new($offsetX,$offset)
  $interior=[Windows.Media.EllipseGeometry]::new([Windows.Point]::new(155,85),116,67)
  if($interior.FillContainsWithDetail($geometry)-ne [Windows.Media.IntersectionDetail]::FullyContains){return}
  $rows=@{};$indices=[Globalization.StringInfo]::ParseCombiningCharacters($Value)
  for($i=0;$i-lt $indices.Length;$i++){
    $start=$indices[$i];$end=if($i+1-lt $indices.Length){$indices[$i+1]}else{$Value.Length}
    $highlight=$formatted.BuildHighlightGeometry([Windows.Point]::new(0,0),$start,$end-$start)
    if(!$highlight -or $highlight.Bounds.IsEmpty){continue}
    $rect=$highlight.Bounds;$key=[Math]::Round($rect.Top,2)
    if(!$rows.ContainsKey($key)){$rows[$key]=@{left=$rect.Left;right=$rect.Right}}
    else{$rows[$key].left=[Math]::Min($rows[$key].left,$rect.Left);$rows[$key].right=[Math]::Max($rows[$key].right,$rect.Right)}
  }
  if($ExpectedLines-gt 0 -and $rows.Count-ne $ExpectedLines){return}
  $lengths=@($rows.Values|ForEach-Object{$_.right-$_.left})
  $maximum=($lengths|Measure-Object -Maximum).Maximum;$minimum=($lengths|Measure-Object -Minimum).Minimum
  $imbalance=if($maximum-gt 0){1-$minimum/$maximum}else{0}
  $score=$Size*10-[Math]::Max(0,$rows.Count-2)*26-($rows.Count-1)*8-$imbalance*55
  [pscustomobject]@{fontSize=$Size;width=$Width;lineHeight=$Size*1.15;offsetX=$offsetX;offsetY=$offset;lines=$rows.Count;score=$score}
}

function Get-WidgetQuoteLayout([string]$Value,$TextBlock,[int]$ExpectedLines=0){
  $key=(@($TextBlock.FontFamily.Source,$TextBlock.FontStyle,$TextBlock.FontWeight,$TextBlock.FontStretch,[Globalization.CultureInfo]::CurrentCulture.Name)-join '|')+"`n"+$Value
  if($script:quoteLayoutCache.ContainsKey($key)){return $script:quoteLayoutCache[$key]}
  $typeface=[Windows.Media.Typeface]::new($TextBlock.FontFamily,$TextBlock.FontStyle,$TextBlock.FontWeight,$TextBlock.FontStretch)
  $best=$null;$hint=$script:quoteLayoutHints[$Value]
  # Verify a reviewed profile against this machine's fonts before reusing it.
  if($hint -and $hint.fontSize-ge 10 -and $hint.fontSize-le 32 -and $hint.width-ge 140 -and $hint.width-le 236){$best=Measure-WidgetQuoteLayout $Value $TextBlock $typeface $hint.fontSize $hint.width $ExpectedLines}
  if(!$best){
    foreach($size in 32..6){
      if($best -and $best.score-gt $size*10){break}
      foreach($width in @(236,228,220,212,204,196,188,180,172,164,156,148,140)){
        $candidate=Measure-WidgetQuoteLayout $Value $TextBlock $typeface $size $width $ExpectedLines
        if($candidate -and (!$best -or $candidate.score-gt $best.score)){$best=$candidate}
      }
      if($size-eq 18 -and $best){break}
    }
  }
  if(!$best){throw 'Quote cannot fit inside the bubble'}
  if($script:quoteLayoutCache.Count-ge 200){$script:quoteLayoutCache.Clear()}
  $script:quoteLayoutCache[$key]=$best
  return $best
}

function Fit-QuoteText {
  $text=$script:ui.QuoteText;$full=$text.Text;$text.Tag=$full
  $text.HorizontalAlignment=[Windows.HorizontalAlignment]::Center;$text.VerticalAlignment=[Windows.VerticalAlignment]::Center
  $text.TextAlignment=[Windows.TextAlignment]::Center;$text.Margin=[Windows.Thickness]::new(0);$text.Padding=[Windows.Thickness]::new(0)
  $display=$full
  if($script:quoteLayoutMap.ContainsKey($full)){$display=$script:quoteLayoutMap[$full]}
  $expectedLines=if($display.Contains("`n")){($display-split "`n").Count}else{0}
  try{$script:quoteLayout=Get-WidgetQuoteLayout $display $text $expectedLines}
  catch{
    # Reflow only a failed display attempt; Tag retains the full original
    # for the tooltip and copy action, including its explicit line breaks.
    $display=($full-replace '\s+',' ').Trim()
    try{$script:quoteLayout=Get-WidgetQuoteLayout $display $text}
    catch{$display='…';$script:quoteLayout=Get-WidgetQuoteLayout $display $text}
  }
  $text.Text=$display;$text.Width=$script:quoteLayout.width;$text.FontSize=$script:quoteLayout.fontSize;$text.LineHeight=$script:quoteLayout.lineHeight
  $text.LineStackingStrategy=[Windows.LineStackingStrategy]::BlockLineHeight
  $text.RenderTransform=[Windows.Media.TranslateTransform]::new($script:quoteLayout.offsetX,$script:quoteLayout.offsetY)
}

function Set-WidgetSceneLayout {
  $scene=$script:ui.SceneText
  if($script:bubbleMode-in @('quote','completion') -and $script:quoteLayout){
    [Windows.Controls.Canvas]::SetLeft($scene,155-$script:quoteLayout.width/2);[Windows.Controls.Canvas]::SetTop($scene,18)
    $scene.Width=$script:quoteLayout.width;$scene.Height=134
  }else{
    [Windows.Controls.Canvas]::SetLeft($scene,63);[Windows.Controls.Canvas]::SetTop($scene,22)
    $scene.Width=184;$scene.Height=115
  }
}
