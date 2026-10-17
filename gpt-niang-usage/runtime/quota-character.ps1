# Quota poses share the gallery renderer; the saved normal character survives low quota.
$script:quotaCharacterCache=@{}
function Set-WidgetQuotaCharacter([ValidateSet('normal','low')][string]$Mood,[switch]$Force) {
  if(!$Force -and $script:quotaCharacterState-eq $Mood -and $script:ui.Girl.Source){return}
  $file=if($Mood-eq 'low'){'gpt-dragon-low-quota.png'}else{'gpt-dragon-niang-bust.png'}
  $path=Join-Path $script:appDir ('assets\'+$file)
  if($Mood-eq 'normal' -and $script:activeCharacter){$path=$script:activeCharacter.path}
  $key=$path+'|'+[IO.File]::GetLastWriteTimeUtc($path).Ticks
  if(!$script:quotaCharacterCache.ContainsKey($key)){
    if($script:quotaCharacterCache.Count-ge 8){$script:quotaCharacterCache.Clear()}
    if(Get-Command Read-WidgetCharacterImage -ErrorAction SilentlyContinue){
      try{$image=Read-WidgetCharacterImage $path}
      catch{
        if($Mood-ne 'normal' -or !$script:activeCharacter -or $script:activeCharacter.id-eq 'gpt-dragon'){throw}
        $script:characterLoadNotice='选中的角色图片无法读取，暂用龙娘1；请在角色库重新选择。'
        $image=Read-WidgetCharacterImage (Join-Path $script:appDir 'assets\gpt-dragon-niang-bust.png')
      }
    }else{
      $image=[Windows.Media.Imaging.BitmapImage]::new()
      $image.BeginInit();$image.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $image.UriSource=[Uri]$path;$image.EndInit();$image.Freeze()
    }
    $alpha=[Windows.Media.Imaging.FormatConvertedBitmap]::new($image,[Windows.Media.PixelFormats]::Bgra32,$null,0)
    $stride=$image.PixelWidth*4;$pixels=New-Object byte[] ($stride*$image.PixelHeight)
    $alpha.CopyPixels($pixels,$stride,0)
    $script:quotaCharacterCache[$key]=@{image=$image;alpha=$alpha;stride=$stride;pixels=$pixels}
  }
  $pose=$script:quotaCharacterCache[$key]
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
