# Local character images are decoded into detached pixels before they reach WPF.
# Imports own a normalized PNG; selected IDs are saved by widget.ps1.
function Resolve-WidgetCharacterPath([string]$Root,[string]$File) {
  if(!$File -or [IO.Path]::IsPathRooted($File)){throw '角色图片路径必须位于角色目录中。'}
  $base=[IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))+[IO.Path]::DirectorySeparatorChar
  $path=[IO.Path]::GetFullPath((Join-Path $Root $File))
  if(!$path.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw '角色图片路径超出了角色目录。'}
  # A local manifest cannot use a link to point at another directory.
  $check=$path
  while($check.Length-ge $base.TrimEnd([char[]]@('\','/')).Length){
    if([IO.File]::Exists($check) -or [IO.Directory]::Exists($check)){
      if(([IO.File]::GetAttributes($check)-band [IO.FileAttributes]::ReparsePoint)-ne 0){throw '角色图片目录不能使用文件链接。'}
    }
    if([string]::Equals($check,$base.TrimEnd([char[]]@('\','/')),[StringComparison]::OrdinalIgnoreCase)){break}
    $check=[IO.Path]::GetDirectoryName($check)
    if(!$check){break}
  }
  return $path
}

function Read-WidgetCharacterCatalog([string]$Path) {
  if(![IO.File]::Exists($Path)){return [pscustomobject]@{version=1;characters=@();removed=@()}}
  if(([IO.FileInfo]::new($Path)).Length-gt 1MB){throw '角色清单过大。'}
  $value=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
  if($null-eq $value -or $value.version-ne 1 -or !$value.PSObject.Properties['characters']){throw '角色清单格式无效。'}
  if(!$value.PSObject.Properties['removed']){$value|Add-Member -NotePropertyName removed -NotePropertyValue @()}
  return $value
}

function Read-WidgetCharacterRows([string]$Path) {
  foreach($row in @((Read-WidgetCharacterCatalog $Path).characters)){$row}
}

function Write-WidgetCharacterCatalog([string]$Path,$Catalog) {
  $temp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
  try{
    [IO.File]::WriteAllText($temp,($Catalog|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,($Path+'.bak'),$true)}else{[IO.File]::Move($temp,$Path)}
  }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}

function Get-WidgetCharacters([string]$AppDir,[string]$DataDir) {
  $assets=Join-Path $AppDir 'assets'
  $rows=New-Object 'System.Collections.Generic.List[object]'
  $seen=@{}
  # The classic character remains available if either catalog is damaged.
  $rows.Add([pscustomobject]@{id='gpt-dragon';name='龙娘1';kind='built-in';path=(Join-Path $assets 'gpt-dragon-niang-bust.png')})
  $seen['gpt-dragon']=$true
  try{
    foreach($entry in @(Read-WidgetCharacterRows (Join-Path $assets 'characters.json'))){
      if($entry.id-isnot [string] -or $entry.id-notmatch '^[a-z][a-z0-9-]{0,63}$' -or $seen.ContainsKey($entry.id)){continue}
      if($entry.name-isnot [string] -or !$entry.name.Trim() -or $entry.name.Length-gt 80){continue}
      if($entry.file-isnot [string]){continue}
      try{$path=Resolve-WidgetCharacterPath $assets $entry.file}catch{continue}
      if(![IO.File]::Exists($path)){continue}
      $rows.Add([pscustomobject]@{id=$entry.id;name=$entry.name.Trim();kind='built-in';path=$path});$seen[$entry.id]=$true
    }
  }catch{}
  try{
    foreach($entry in @(Read-WidgetCharacterRows (Join-Path $DataDir 'characters.json'))){
      if($entry.id-isnot [string] -or $entry.id-notmatch '^custom-[0-9a-f]{32}$' -or $seen.ContainsKey($entry.id)){continue}
      if($entry.name-isnot [string] -or !$entry.name.Trim() -or $entry.name.Length-gt 80){continue}
      if($entry.file-isnot [string] -or $entry.file-ne ($entry.id+'.png')){continue}
      try{$path=Resolve-WidgetCharacterPath (Join-Path $DataDir 'characters') $entry.file}catch{continue}
      if(![IO.File]::Exists($path)){continue}
      $rows.Add([pscustomobject]@{id=$entry.id;name=$entry.name.Trim();kind='custom';path=$path});$seen[$entry.id]=$true
    }
  }catch{}
  foreach($row in $rows){$row}
}

function Get-WidgetCharacter([string]$AppDir,[string]$DataDir,[string]$Id) {
  $rows=@(Get-WidgetCharacters $AppDir $DataDir)
  foreach($row in $rows){if([string]::Equals($row.id,$Id,[StringComparison]::Ordinal)){return $row}}
  return $rows[0]
}

function Read-WidgetCharacterImage([string]$Path) {
  if(!$Path -or $Path-match '^[a-z][a-z0-9+.-]*://'){throw '请选择电脑上的图片文件。'}
  $extension=[IO.Path]::GetExtension($Path).ToLowerInvariant()
  if($extension-notin @('.png','.jpg','.jpeg','.bmp','.gif')){throw '支持 PNG、JPG、BMP 和 GIF 图片；GIF 使用第一帧。'}
  $stream=$null
  try{
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    if($stream.Length-eq 0 -or $stream.Length-gt 20MB){throw '图片不能为空，且不能超过 20 MB。'}
    # OnDemand reads the image header first, so the dimension guard precedes pixel allocation.
    $decoder=[Windows.Media.Imaging.BitmapDecoder]::Create($stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnDemand)
    if($decoder-isnot [Windows.Media.Imaging.PngBitmapDecoder] -and $decoder-isnot [Windows.Media.Imaging.JpegBitmapDecoder] -and $decoder-isnot [Windows.Media.Imaging.BmpBitmapDecoder] -and $decoder-isnot [Windows.Media.Imaging.GifBitmapDecoder]){throw '图片格式不受支持。'}
    if($decoder.Frames.Count-lt 1){throw '图片没有可用的画面。'}
    $frame=$decoder.Frames[0];$width=$frame.PixelWidth;$height=$frame.PixelHeight
    if($width-lt 1 -or $height-lt 1 -or $width-gt 4096 -or $height-gt 4096 -or ([long]$width*$height)-gt 16000000){throw '图片尺寸不能超过 4096 × 4096，且不能超过 1600 万像素。'}
    $converted=[Windows.Media.Imaging.FormatConvertedBitmap]::new($frame,[Windows.Media.PixelFormats]::Bgra32,$null,0)
    $stride=$width*4;$pixels=New-Object byte[] ($stride*$height)
    $converted.CopyPixels($pixels,$stride,0)
    $image=[Windows.Media.Imaging.BitmapSource]::Create($width,$height,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$pixels,$stride)
    $image.Freeze()
    return $image
  }catch{
    if($_.Exception.Message-match '^(请选择|支持 |图片)'){throw}
    throw '图片无法读取，请选择完整的 PNG、JPG、BMP 或 GIF 文件。'
  }finally{if($stream){$stream.Dispose()}}
}

function Import-WidgetCharacter([string]$DataDir,[string]$SourcePath) {
  # Validate fully before creating or changing user data.
  $image=Read-WidgetCharacterImage $SourcePath
  # Stored copies only need display resolution. A bounded lossless copy keeps
  # the normalized PNG inside the same 20 MB reader limit and keeps gallery
  # decoding and activation memory predictable instead of storing 12 MP photos.
  $longest=[Math]::Max($image.PixelWidth,$image.PixelHeight)
  if($longest-gt 2048){
    $ratio=2048.0/$longest
    $scaled=[Windows.Media.Imaging.TransformedBitmap]::new($image,[Windows.Media.ScaleTransform]::new($ratio,$ratio))
    $scaled.Freeze();$image=$scaled
  }
  # A fully transparent picture passes every file check but would make the whole
  # widget click-through, so reject it while the decoded pixels are available.
  $probe=[Windows.Media.Imaging.TransformedBitmap]::new($image,[Windows.Media.ScaleTransform]::new(32.0/$image.PixelWidth,32.0/$image.PixelHeight))
  $probePixels=New-Object byte[] ($probe.PixelWidth*$probe.PixelHeight*4)
  $probe.CopyPixels($probePixels,$probe.PixelWidth*4,0)
  $visible=$false
  for($i=3;$i-lt $probePixels.Length;$i+=4){if($probePixels[$i]-gt 10){$visible=$true;break}}
  if(!$visible){throw '图片没有可见像素，请换一张有内容的图片。'}
  $catalogPath=Join-Path $DataDir 'characters.json'
  $catalog=Read-WidgetCharacterCatalog $catalogPath
  $directory=Join-Path $DataDir 'characters'
  $id='custom-'+[Guid]::NewGuid().ToString('N');$file=$id+'.png'
  $path=Resolve-WidgetCharacterPath $directory $file
  $name=[IO.Path]::GetFileNameWithoutExtension($SourcePath).Trim()
  $name=$name-replace '[\x00-\x1f]',''
  if(!$name){$name='我的角色'};if($name.Length-gt 80){$name=$name.Substring(0,80)}
  $entry=[pscustomobject]@{id=$id;name=$name;file=$file}
  $imageTemp=$path+'.tmp'
  $created=$false;$stream=$null
  try{
    $null=[IO.Directory]::CreateDirectory($directory)
    $stream=[IO.File]::Create($imageTemp)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($image))
    $encoder.Save($stream);$stream.Dispose();$stream=$null
    [IO.File]::Move($imageTemp,$path);$created=$true
    # Re-read the committed file with the same guard used for every catalog
    # image, so a committed import can never point at an image that cannot be
    # activated later.
    $null=Read-WidgetCharacterImage $path
    $catalog.characters=@($catalog.characters)+@($entry)
    Write-WidgetCharacterCatalog $catalogPath $catalog
    $created=$false
    return [pscustomobject]@{id=$id;name=$name;kind='custom';path=$path}
  }finally{
    if($stream){$stream.Dispose()}
    if([IO.File]::Exists($imageTemp)){[IO.File]::Delete($imageTemp)}
    if($created -and [IO.File]::Exists($path)){[IO.File]::Delete($path)}
  }
}

function Get-WidgetRemovedCharacters([string]$DataDir) {
  try{
    $catalog=Read-WidgetCharacterCatalog (Join-Path $DataDir 'characters.json')
    foreach($entry in @($catalog.removed)){
      if($entry.id-isnot [string] -or $entry.id-notmatch '^custom-[0-9a-f]{32}$' -or $entry.file-ne ($entry.id+'.png')){continue}
      if($entry.name-isnot [string] -or !$entry.name.Trim() -or $entry.name.Length-gt 80){continue}
      try{$path=Resolve-WidgetCharacterPath (Join-Path $DataDir 'characters\removed') $entry.file}catch{continue}
      if(![IO.File]::Exists($path)){continue}
      [pscustomobject]@{id=$entry.id;name=$entry.name;kind='custom';path=$path;removedAt=$entry.removedAt}
    }
  }catch{}
}

function Remove-WidgetCharacter([string]$DataDir,[string]$Id) {
  if($Id-notmatch '^custom-[0-9a-f]{32}$'){throw '只能移除自己导入的角色。'}
  $catalogPath=Join-Path $DataDir 'characters.json';$catalog=Read-WidgetCharacterCatalog $catalogPath
  $matches=@($catalog.characters|Where-Object{$_.id-ceq $Id})
  if($matches.Count-ne 1 -or $matches[0].file-ne ($Id+'.png')){throw '找不到可移除的导入角色。'}
  $entry=$matches[0];$directory=Join-Path $DataDir 'characters'
  $source=Resolve-WidgetCharacterPath $directory $entry.file
  $removedDirectory=Join-Path $directory 'removed';$destination=Resolve-WidgetCharacterPath $removedDirectory $entry.file
  if(![IO.File]::Exists($source) -or [IO.File]::Exists($destination)){throw '角色图片无法移入恢复目录。'}
  $null=[IO.Directory]::CreateDirectory($removedDirectory)
  $moved=$false
  try{
    [IO.File]::Move($source,$destination);$moved=$true
    $removed=[pscustomobject]@{id=$Id;name=$entry.name;file=$entry.file;removedAt=[DateTime]::UtcNow.ToString('o')}
    $catalog.characters=@($catalog.characters|Where-Object{$_.id-cne $Id})
    $catalog.removed=@($catalog.removed)+@($removed)
    Write-WidgetCharacterCatalog $catalogPath $catalog
    $moved=$false
    return [pscustomobject]@{id=$Id;name=$entry.name;kind='custom';path=$destination;removedAt=$removed.removedAt}
  }finally{
    if($moved -and [IO.File]::Exists($destination)){[IO.File]::Move($destination,$source)}
  }
}

function Restore-WidgetCharacter([string]$DataDir,[string]$Id) {
  if($Id-notmatch '^custom-[0-9a-f]{32}$'){throw '找不到可恢复的导入角色。'}
  $catalogPath=Join-Path $DataDir 'characters.json';$catalog=Read-WidgetCharacterCatalog $catalogPath
  $matches=@($catalog.removed|Where-Object{$_.id-ceq $Id})
  if($matches.Count-ne 1 -or $matches[0].file-ne ($Id+'.png') -or @($catalog.characters|Where-Object{$_.id-ceq $Id}).Count-gt 0){throw '找不到可恢复的导入角色。'}
  $entry=$matches[0];$directory=Join-Path $DataDir 'characters'
  $source=Resolve-WidgetCharacterPath (Join-Path $directory 'removed') $entry.file
  $destination=Resolve-WidgetCharacterPath $directory $entry.file
  if(![IO.File]::Exists($source) -or [IO.File]::Exists($destination)){throw '角色图片无法从恢复目录取回。'}
  $moved=$false
  try{
    [IO.File]::Move($source,$destination);$moved=$true
    $catalog.characters=@($catalog.characters)+@([pscustomobject]@{id=$Id;name=$entry.name;file=$entry.file})
    $catalog.removed=@($catalog.removed|Where-Object{$_.id-cne $Id})
    Write-WidgetCharacterCatalog $catalogPath $catalog
    $moved=$false
    return [pscustomobject]@{id=$Id;name=$entry.name;kind='custom';path=$destination}
  }finally{
    if($moved -and [IO.File]::Exists($destination)){[IO.File]::Move($destination,$source)}
  }
}
