function New-WidgetCharacterFrame($Bitmap,[int]$Duration=280) {
  $alpha=[Windows.Media.Imaging.FormatConvertedBitmap]::new($Bitmap,[Windows.Media.PixelFormats]::Bgra32,$null,0)
  $stride=$Bitmap.PixelWidth*4;$pixels=New-Object byte[] ($stride*$Bitmap.PixelHeight)
  $alpha.CopyPixels($pixels,$stride,0);$alpha.Freeze()
  return @{Bitmap=$Bitmap;Alpha=$alpha;Pixels=$pixels;Stride=$stride;Duration=$Duration}
}

function Set-WidgetCharacterFrame($Frame) {
  $script:bitmap=$Frame.Bitmap;$script:alphaBitmap=$Frame.Alpha
  $script:alphaPixels=$Frame.Pixels;$script:alphaStride=$Frame.Stride
  $script:ui.Girl.Source=$Frame.Bitmap
}

function Write-WidgetCharacterAnimationError([string]$Message) {
  try {
    $file=Join-Path $script:dataDir 'character-error.txt'
    $line='['+[DateTime]::UtcNow.ToString('o')+'] '+$Message+[Environment]::NewLine
    [IO.File]::AppendAllText($file,$line,[Text.UTF8Encoding]::new($false))
  } catch {}
}

function Resolve-WidgetCharacterAssetPath([string]$Root,[string]$Base,[string]$Relative) {
  if([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative-match '(^|[\\/])\.\.([\\/]|$)'){throw 'Animation paths must be relative and remain inside the pixel-dragon asset directory.'}
  $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
  $full=[IO.Path]::GetFullPath((Join-Path $Base $Relative))
  if(!$full.StartsWith($rootPath+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Animation path escaped the pixel-dragon asset directory.'}
  for($current=$full;$current -and $current.StartsWith($rootPath,[StringComparison]::OrdinalIgnoreCase);$current=Split-Path $current -Parent){
    if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes-band [IO.FileAttributes]::ReparsePoint)){throw 'Animation assets may not use links.'}
    if($current-ieq $rootPath){break}
  }
  return $full
}

function Read-WidgetCharacterClip([string]$Root,[string]$ManifestRelative,[string]$ActionId,[string]$Playback) {
  if($ActionId-notmatch '^[a-z][a-z0-9_-]{0,31}$' -or $Playback-notin @('loop','once')){throw 'Invalid character action registration.'}
  $manifestFile=Resolve-WidgetCharacterAssetPath $Root $Root $ManifestRelative
  if(!(Test-Path -LiteralPath $manifestFile -PathType Leaf)){throw ('Missing action manifest: '+$ManifestRelative)}
  $manifest=Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
  if([int]$manifest.width-ne 192 -or [int]$manifest.height-ne 192){throw ('Action canvas must be 192x192: '+$ActionId)}
  if([int]$manifest.anchor.x-ne 85 -or [int]$manifest.anchor.y-ne 184){throw ('Action anchor mismatch: '+$ActionId)}
  $entries=@($manifest.frames)
  if($entries.Count-eq 0){throw ('Action contains no frames: '+$ActionId)}
  $frames=@(foreach($entry in $entries){
    $duration=0
    if($null-eq $entry.durationMs -or ![int]::TryParse([string]$entry.durationMs,[ref]$duration) -or $duration-lt 40 -or $duration-gt 2000){throw ('Invalid frame duration in action: '+$ActionId)}
    $file=Resolve-WidgetCharacterAssetPath $Root (Split-Path $manifestFile -Parent) ([string]$entry.file)
    if(!(Test-Path -LiteralPath $file -PathType Leaf)){throw ('Missing action frame: '+$entry.file)}
    $image=[Windows.Media.Imaging.BitmapImage]::new()
    $image.BeginInit();$image.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $image.CreateOptions=[Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
    $image.UriSource=[Uri]$file;$image.EndInit();$image.Freeze()
    if($image.PixelWidth-ne 192 -or $image.PixelHeight-ne 192){throw ('Action frame canvas mismatch: '+$entry.file)}
    New-WidgetCharacterFrame $image $duration
  })
  return @{Id=$ActionId;Frames=$frames;Playback=$Playback}
}

function Get-WidgetLegacyCharacterRegistry {
  return @{schemaVersion=1;defaultAction='idle';actions=@{idle=@{manifest='idle.json';playback='loop'}}}
}

function Read-WidgetCharacterActions([string]$AppDir) {
  $root=Join-Path $AppDir 'assets\pixel-dragon'
  $registryFile=Join-Path $root 'animations.json'
  $legacy=!(Test-Path -LiteralPath $registryFile -PathType Leaf)
  if($legacy){$registry=Get-WidgetLegacyCharacterRegistry}
  else {
    try {
      $registry=Get-Content -LiteralPath $registryFile -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
      if([int]$registry.schemaVersion-ne 1 -or $registry.defaultAction-ne 'idle' -or !$registry.actions){throw 'Unsupported character animation registry.'}
    } catch {
      Write-WidgetCharacterAnimationError ('Animation registry invalid; using legacy idle manifest: '+$_.Exception.Message)
      $registry=Get-WidgetLegacyCharacterRegistry
    }
  }
  $clips=@{}
  $actionEntries=@()
  if($registry.actions-is [System.Collections.IDictionary]){
    foreach($id in $registry.actions.Keys){$actionEntries+=@(@{Name=[string]$id;Value=$registry.actions[$id]})}
  }else{
    foreach($property in $registry.actions.PSObject.Properties){$actionEntries+=@(@{Name=[string]$property.Name;Value=$property.Value})}
  }
  foreach($property in $actionEntries){
    $id=$property.Name;$registration=$property.Value
    try {
      $clip=Read-WidgetCharacterClip $root ([string]$registration.manifest) $id ([string]$registration.playback)
      if($id-in @('idle','click','complete') -and $clip.Playback-ne 'once' -and $id-ne 'idle'){throw ('Action must play once: '+$id)}
      if($id-eq 'idle' -and $clip.Playback-ne 'loop'){throw 'Idle action must loop.'}
      $clips[$id]=$clip
    } catch {
      Write-WidgetCharacterAnimationError ('Action '+$id+' unavailable: '+$_.Exception.Message)
      if($id-eq 'idle'){throw}
    }
  }
  if(!$clips.ContainsKey('idle')){throw 'The required idle action is not registered.'}
  return $clips
}

function Get-WidgetCharacterAction([string]$ActionId) {
  $state=$script:characterAnimation
  if(!$state -or !$state.Loaded -or !$state.Clips.ContainsKey($ActionId)){return $null}
  return $state.Clips[$ActionId]
}

function Set-WidgetCharacterFrameAt([int]$Index) {
  $state=$script:characterAnimation
  $clip=Get-WidgetCharacterAction $state.CurrentAction
  if(!$clip -or $Index-lt 0 -or $Index-ge $clip.Frames.Count){throw 'Character animation frame is unavailable.'}
  $state.Index=$Index
  if($state.CurrentAction-eq 'idle'){$state.IdleIndex=$Index}
  if($state.CurrentAction-eq 'working'){$state.WorkingIndex=$Index}
  Set-WidgetCharacterFrame $clip.Frames[$Index]
}

function Start-WidgetCharacterAction([string]$ActionId,[int]$StartIndex=0) {
  $clip=Get-WidgetCharacterAction $ActionId
  if(!$clip){return $false}
  $state=$script:characterAnimation
  $state.Timer.Stop();$state.CurrentAction=$ActionId;$state.Finished=$false
  if($ActionId-eq 'idle'){$StartIndex=[Math]::Max(0,[Math]::Min($StartIndex,$clip.Frames.Count-1));$state.IdleIndex=$StartIndex}
  elseif($ActionId-eq 'working'){$StartIndex=[Math]::Max(0,[Math]::Min($StartIndex,$clip.Frames.Count-1));$state.WorkingIndex=$StartIndex}
  else{$StartIndex=0}
  Set-WidgetCharacterFrameAt $StartIndex
  Update-WidgetCharacterPlayback
  return $true
}

function Restore-WidgetCharacterIdle {
  $state=$script:characterAnimation
  if(!$state -or $script:characterMode-ne 'pixel' -or !$state.Clips.ContainsKey('idle')){return}
  if($state.Working -and $state.Clips.ContainsKey('working')){
    $null=Start-WidgetCharacterAction 'working' $state.WorkingIndex
    return
  }
  $null=Start-WidgetCharacterAction 'idle' $state.IdleIndex
}

function Set-WidgetCharacterWorking([bool]$Working) {
  $state=$script:characterAnimation;if(!$state){return}
  if($state.Working-eq $Working){return}
  $state.Working=$Working
  if(!$Working){$state.WorkingIndex=0}
  if($script:characterMode-eq 'pixel' -and $state.Interaction-eq 'idle' -and $state.CurrentAction-in @('idle','working')){Restore-WidgetCharacterIdle}
}

function Update-WidgetCharacterPlayback {
  $state=$script:characterAnimation;if(!$state){return}
  if($script:window.IsVisible -and $state.CompletePending -and $state.Interaction-eq 'idle' -and $state.CurrentAction-in @('idle','working') -and (Get-WidgetCharacterActionAvailable 'complete')){
    $state.CompletePending=$false;$null=Start-WidgetCharacterAction 'complete'
    return
  }
  $clip=Get-WidgetCharacterAction $state.CurrentAction
  $canPlay=$script:characterMode-eq 'pixel' -and $script:window.IsVisible -and !$script:runtimeClosed -and !$state.Finished -and $clip -and (!$state.Pressed -or $state.CurrentAction-in @('press','drag'))
  if($canPlay){
    if(!$state.Timer.IsEnabled){$state.Timer.Interval=[TimeSpan]::FromMilliseconds($clip.Frames[$state.Index].Duration);$state.Timer.Start()}
  }else{$state.Timer.Stop()}
}

function Get-WidgetCharacterActionAvailable([string]$ActionId) {
  return ($null-ne (Get-WidgetCharacterAction $ActionId))
}

function Get-WidgetCharacterFrameCount {
  if($script:characterMode-ne 'pixel'){return 1}
  $clip=Get-WidgetCharacterAction $script:characterAnimation.CurrentAction
  if($clip){return $clip.Frames.Count}
  return 0
}

function Set-WidgetCharacterInteraction([ValidateSet('idle','press','drag')][string]$State,[bool]$Click=$false) {
  $animation=$script:characterAnimation;if(!$animation){return $false}
  if($State-ne 'idle' -and $animation.Interaction-eq $State){
    Update-WidgetCharacterPlayback
    return ($script:characterMode-eq 'pixel' -and $animation.CurrentAction-eq $State -and (Get-WidgetCharacterActionAvailable $State))
  }
  if($animation.CurrentAction-eq 'complete' -and ($State-ne 'idle' -or $Click)){$animation.CompletePending=$true}
  $animation.Interaction=$State;$animation.Pressed=$State-ne 'idle'
  if($State-ne 'idle'){
    $action=if($State-eq 'drag'){'drag'}else{'press'}
    if($script:characterMode-eq 'pixel' -and (Get-WidgetCharacterActionAvailable $action)){return (Start-WidgetCharacterAction $action)}
    Restore-WidgetCharacterIdle
    $animation.Pressed=$true;Update-WidgetCharacterPlayback
    return $false
  }
  if($Click -and (Get-WidgetCharacterActionAvailable 'click')){
    return (Start-WidgetCharacterAction 'click')
  }
  Restore-WidgetCharacterIdle
  if($animation.CompletePending){$animation.CompletePending=$false;$null=Start-WidgetCharacterAction 'complete'}
  return $false
}

function Request-WidgetCharacterAction([string]$ActionId,[bool]$Success=$true) {
  if($script:characterMode-ne 'pixel' -or !$Success -or !(Get-WidgetCharacterActionAvailable $ActionId)){return $false}
  $state=$script:characterAnimation
  if($ActionId-eq 'complete'){
    if($state.CurrentAction-eq 'complete' -or $state.CompletePending){return $true}
    if(!$script:window.IsVisible -or $state.Interaction-ne 'idle' -or $state.CurrentAction-eq 'click'){$state.CompletePending=$true;return $true}
  }elseif($state.Interaction-ne 'idle'){return $false}
  if($state.CurrentAction-eq 'complete' -and $ActionId-ne 'complete'){$state.CompletePending=$true}
  return (Start-WidgetCharacterAction $ActionId)
}

function Set-WidgetCharacterMode([string]$Mode) {
  if($Mode-notin @('original','pixel')){$Mode='original'}
  $state=$script:characterAnimation;if(!$state){return}
  $state.Timer.Stop()
  if($Mode-eq 'pixel'){
    try{
      if(!$state.Loaded){$state.Clips=Read-WidgetCharacterActions $script:appDir;$state.Loaded=$true;$state.Frames=$state.Clips.idle.Frames}
      $state.Interaction='idle';$state.Pressed=$false;$state.CompletePending=$false
      $script:characterMode='pixel';$state.IdleIndex=0;$state.WorkingIndex=0
      Restore-WidgetCharacterIdle
    }catch{
      $Mode='original';$state.Frames=@();$state.Clips=@{};$state.Loaded=$false
      Write-WidgetCharacterAnimationError ('Required idle animation unavailable: '+$_.Exception.Message)
    }
  }else{
    $state.Interaction='idle';$state.Pressed=$false;$state.CompletePending=$false;$state.CurrentAction='idle';$state.Finished=$false
    Set-WidgetCharacterFrame $state.Original
  }
  $script:characterMode=$Mode
  $size=if($Mode-eq 'pixel'){192}else{208};$offset=142+(208-$size)/2
  $script:ui.Girl.Width=$size;$script:ui.Girl.Height=$size
  [Windows.Controls.Canvas]::SetLeft($script:ui.Girl,$offset);[Windows.Controls.Canvas]::SetTop($script:ui.Girl,$offset)
  [Windows.Media.RenderOptions]::SetBitmapScalingMode($script:ui.Girl,$(if($Mode-eq 'pixel'){[Windows.Media.BitmapScalingMode]::NearestNeighbor}else{[Windows.Media.BitmapScalingMode]::Unspecified}))
  Update-WidgetCharacterPlayback
  if(Get-Command Update-CompletionMonitor -ErrorAction SilentlyContinue){Update-CompletionMonitor}
}

function Advance-WidgetCharacterAnimation {
  $state=$script:characterAnimation;$clip=Get-WidgetCharacterAction $state.CurrentAction
  if(!$clip -or $state.Index-ge $clip.Frames.Count){throw 'Current character action became unavailable.'}
  if($state.Index-lt $clip.Frames.Count-1){
    Set-WidgetCharacterFrameAt ($state.Index+1)
  }elseif($clip.Playback-eq 'loop'){
    Set-WidgetCharacterFrameAt 0
  }elseif($state.Interaction-in @('press','drag')){
    $state.Finished=$true;$state.Timer.Stop();return
  }else{
    Restore-WidgetCharacterIdle
    if($state.CompletePending){$state.CompletePending=$false;$null=Start-WidgetCharacterAction 'complete'}
  }
  $current=Get-WidgetCharacterAction $state.CurrentAction
  if($current){$state.Timer.Interval=[TimeSpan]::FromMilliseconds($current.Frames[$state.Index].Duration)}
  Update-WidgetCharacterPlayback
}

function Set-WidgetCharacterPressed([bool]$Pressed) {
  if($Pressed){$null=Set-WidgetCharacterInteraction 'press'}
  else{$null=Set-WidgetCharacterInteraction 'idle'}
}

function Stop-WidgetCharacterAnimation {
  if($script:characterAnimation){
    $state=$script:characterAnimation;$state.Timer.Stop();$state.Pressed=$false;$state.Interaction='idle';$state.CompletePending=$false;$state.Finished=$false;$state.Working=$false;$state.WorkingIndex=0
  }
}

function Initialize-WidgetCharacter {
  $timer=[Windows.Threading.DispatcherTimer]::new()
  $script:characterAnimation=@{Original=(New-WidgetCharacterFrame $script:bitmap);Frames=@();Clips=@{};Loaded=$false;CurrentAction='idle';Index=0;IdleIndex=0;Working=$false;WorkingIndex=0;Interaction='idle';Pressed=$false;Finished=$false;CompletePending=$false;Timer=$timer}
  $timer.Add_Tick({
    $state=$script:characterAnimation
    if(!$state){return}
    try {
      Advance-WidgetCharacterAnimation
    }catch{
      $failed=$state.CurrentAction;$state.Timer.Stop()
      if($failed-eq 'idle'){
        $state.Loaded=$false;$state.Clips=@{};$state.Frames=@()
        Set-WidgetCharacterMode 'original'
      }else{
        $state.Clips.Remove($failed);$state.CurrentAction='idle';$state.Finished=$false
        Write-WidgetCharacterAnimationError ('Action '+$failed+' stopped: '+$_.Exception.Message)
        Restore-WidgetCharacterIdle
      }
    }
  })
  $script:window.Add_IsVisibleChanged({
    if(!$script:window.IsVisible -and $script:characterAnimation.Interaction-ne 'idle'){
      $script:characterAnimation.Interaction='idle';$script:characterAnimation.Pressed=$false
      if($script:characterAnimation.CurrentAction-in @('press','drag')){Restore-WidgetCharacterIdle}
    }
    Update-WidgetCharacterPlayback
  })
  Set-WidgetCharacterMode $script:characterMode
}
