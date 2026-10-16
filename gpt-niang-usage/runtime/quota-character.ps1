# Two bundled quota poses; no dependency on a separate character gallery.
$script:quotaCharacterCache=@{}
function Set-WidgetQuotaCharacter([ValidateSet('normal','low')][string]$Mood) {
  if($script:quotaCharacterState-eq $Mood -and $script:ui.Girl.Source){return}
  if(!$script:quotaCharacterCache.ContainsKey($Mood)){
    $file=if($Mood-eq 'low'){'gpt-dragon-low-quota.png'}else{'gpt-dragon-niang-bust.png'}
    $image=[Windows.Media.Imaging.BitmapImage]::new()
    $image.BeginInit();$image.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $image.UriSource=[Uri](Join-Path $script:appDir ('assets\'+$file));$image.EndInit();$image.Freeze()
    $alpha=[Windows.Media.Imaging.FormatConvertedBitmap]::new($image,[Windows.Media.PixelFormats]::Bgra32,$null,0)
    $stride=$image.PixelWidth*4;$pixels=New-Object byte[] ($stride*$image.PixelHeight)
    $alpha.CopyPixels($pixels,$stride,0)
    $script:quotaCharacterCache[$Mood]=@{image=$image;alpha=$alpha;stride=$stride;pixels=$pixels}
  }
  $pose=$script:quotaCharacterCache[$Mood]
  $size=208.0;$left=142.0;$top=142.0
  if($Mood-eq 'low'){$size=228.0;$left=132.0;$top=129.0}
  # Decode and prepare the alpha hit map before changing the visible image.
  $script:bitmap=$pose.image;$script:alphaBitmap=$pose.alpha
  $script:alphaStride=$pose.stride;$script:alphaPixels=$pose.pixels
  $script:ui.Girl.Source=$pose.image
  $script:ui.Girl.Width=$size;$script:ui.Girl.Height=$size
  [Windows.Controls.Canvas]::SetLeft($script:ui.Girl,$left)
  [Windows.Controls.Canvas]::SetTop($script:ui.Girl,$top)
  if($script:widgetColors){
    foreach($overlay in @($script:widgetColors.halo,$script:widgetColors.tint)){
      if(!$overlay){continue}
      $overlay.Width=$size;$overlay.Height=$size
      [Windows.Controls.Canvas]::SetLeft($overlay,$left);[Windows.Controls.Canvas]::SetTop($overlay,$top)
      if($overlay.OpacityMask){$overlay.OpacityMask.ImageSource=$pose.image;$overlay.OpacityMask.Stretch=[Windows.Media.Stretch]::Uniform}
    }
  }
  $script:quotaCharacterState=$Mood
}
