param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
$sourceAppDir=$appDir
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime\character-theme.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime\characters.ps1'),[Text.Encoding]::UTF8)))
function Assert-Equal($Actual,$Expected,[string]$Message){if($Actual-ne $Expected){throw "$Message : expected '$Expected', got '$Actual'"}}
function Assert-Throws([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};if(!$failed){throw $Message}}
function Write-TestCharacterImage([string]$Path,[int]$Width=3,[int]$Height=2,[string]$Format='png'){
  $stride=$Width*4;$pixels=New-Object byte[] ($stride*$Height)
  for($i=0;$i-lt $pixels.Length;$i+=4){$pixels[$i]=57;$pixels[$i+1]=99;$pixels[$i+2]=180;$pixels[$i+3]=255}
  $pixels[3]=0
  if($pixels.Length-ge 8){$pixels[7]=127}
  $image=[Windows.Media.Imaging.BitmapSource]::Create($Width,$Height,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$pixels,$stride)
  $encoder=switch($Format){
    'jpg'{[Windows.Media.Imaging.JpegBitmapEncoder]::new()}
    'bmp'{[Windows.Media.Imaging.BmpBitmapEncoder]::new()}
    'gif'{[Windows.Media.Imaging.GifBitmapEncoder]::new()}
    default{[Windows.Media.Imaging.PngBitmapEncoder]::new()}
  }
  $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($image))
  $stream=[IO.File]::Create($Path);try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
function Write-TestCharacterJson([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
$testDirectory=Join-Path $TestRoot ('character-fixture-'+[Guid]::NewGuid().ToString('N'))
$fixtureApp=Join-Path $testDirectory 'app';$fixtureData=Join-Path $testDirectory 'data';$fixtureAssets=Join-Path $fixtureApp 'assets'
$null=[IO.Directory]::CreateDirectory((Join-Path $fixtureAssets 'characters'))
$null=[IO.Directory]::CreateDirectory($fixtureData)
$sourcePath=Join-Path $testDirectory '我的透明角色.png'
try{
  Write-TestCharacterImage (Join-Path $fixtureAssets 'gpt-dragon-niang-bust.png')
  Write-TestCharacterImage (Join-Path $fixtureAssets 'characters\test-alternative.png') 2 4
  Write-TestCharacterJson (Join-Path $fixtureAssets 'characters.json') @{version=1;characters=@(@{id='gpt-dragon';name='龙娘1';file='gpt-dragon-niang-bust.png'},@{id='test-alternative';name='测试形象';file='characters/test-alternative.png'})}
  $catalog=@(Get-WidgetCharacters $fixtureApp $fixtureData)
  Assert-Equal $catalog.Count 2 'Bundled manifest exposes two characters'
  Assert-Equal $catalog[0].id 'gpt-dragon' 'Classic character is first and default'
  Assert-Equal $catalog[1].id 'test-alternative' 'Alternative built-in ID'
  Assert-Equal (Get-WidgetCharacter $fixtureApp $fixtureData 'unknown').id 'gpt-dragon' 'Missing selected ID falls back'
  Assert-Equal (Get-WidgetCharacter $fixtureApp $fixtureData 'test-alternative').name '测试形象' 'Named built-in selection'

  Write-TestCharacterImage $sourcePath
  $loaded=Read-WidgetCharacterImage $sourcePath
  Assert-Equal $loaded.IsFrozen $true 'Detached image can safely be reused by WPF'
  $exclusive=[IO.File]::Open($sourcePath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$exclusive.Dispose()
  $imported=Import-WidgetCharacter $fixtureData $sourcePath
  Assert-Equal $imported.kind 'custom' 'Imported gallery entry'
  Assert-Equal $imported.name '我的透明角色' 'Filename supplies the display name'
  Assert-Equal ([IO.Path]::GetDirectoryName($imported.path)) (Join-Path $fixtureData 'characters') 'Image is owned by user data directory'
  Assert-Equal ([IO.Path]::GetExtension($imported.path)) '.png' 'Imports normalize to PNG'
  $normalized=Read-WidgetCharacterImage $imported.path
  $pixels=New-Object byte[] 24;$normalized.CopyPixels($pixels,12,0)
  Assert-Equal $pixels[3] 0 'Transparent PNG pixel survives normalization'
  Assert-Equal $pixels[7] 127 'Partial alpha survives normalization'
  [IO.File]::Delete($sourcePath)
  Assert-Equal (Read-WidgetCharacterImage $imported.path).PixelWidth 3 'Removing the original cannot break the copied character'
  Assert-Equal (Get-WidgetCharacter $fixtureApp $fixtureData $imported.id).path $imported.path 'Import is persisted by stable ID'
  $manifestPath=Join-Path $fixtureData 'characters.json'
  $manifestBefore=[IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8)
  if($manifestBefore.Contains($testDirectory)){throw 'Custom manifest leaked an absolute source path'}

  foreach($format in @('jpg','bmp','gif')){
    $formatPath=Join-Path $testDirectory ('image.'+$format);Write-TestCharacterImage $formatPath 3 2 $format
    Assert-Equal (Read-WidgetCharacterImage $formatPath).PixelHeight 2 ('Supported '+$format+' decoding')
  }
  $corruptPath=Join-Path $testDirectory 'corrupt.png';[IO.File]::WriteAllText($corruptPath,'not an image')
  $imageCount=@([IO.Directory]::GetFiles((Join-Path $fixtureData 'characters'))).Count
  Assert-Throws {Import-WidgetCharacter $fixtureData $corruptPath} 'Corrupt image import must fail'
  Assert-Equal ([IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8)) $manifestBefore 'Corrupt import leaves previous manifest intact'
  Assert-Equal @([IO.Directory]::GetFiles((Join-Path $fixtureData 'characters'))).Count $imageCount 'Corrupt import leaves no owned image or temporary file'
  Assert-Throws {Import-WidgetCharacter $fixtureData 'https://example.invalid/character.png'} 'Remote URL import is rejected'
  $scriptPath=Join-Path $testDirectory 'character.ps1';[IO.File]::WriteAllText($scriptPath,'throw ''Never execute me''')
  Assert-Throws {Import-WidgetCharacter $fixtureData $scriptPath} 'Script import is rejected'
  $widePath=Join-Path $testDirectory 'too-wide.png';Write-TestCharacterImage $widePath 4097 1
  Assert-Throws {Import-WidgetCharacter $fixtureData $widePath} 'Dimension guard rejects oversized header before copy'
  Assert-Equal ([IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8)) $manifestBefore 'Rejected formats and dimensions leave manifest intact'

  # A fully transparent picture would pass every file/format check but make the
  # whole widget click-through, so the import must reject it before committing.
  $transparentPath=Join-Path $testDirectory 'fully-transparent.png'
  $transparentPixels=New-Object byte[] (4*4*4)
  $transparentImage=[Windows.Media.Imaging.BitmapSource]::Create(4,4,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$transparentPixels,16)
  $transparentEncoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
  $transparentEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($transparentImage))
  $transparentStream=[IO.File]::Create($transparentPath);try{$transparentEncoder.Save($transparentStream)}finally{$transparentStream.Dispose()}
  Assert-Throws {Import-WidgetCharacter $fixtureData $transparentPath} 'Fully transparent image import must fail'
  Assert-Equal ([IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8)) $manifestBefore 'Transparent image import leaves the manifest intact'

  # A normal phone photo is within the 20 MB source and 16 MP guards, but its
  # lossless normalization can exceed the 20 MB reader limit. The stored copy is
  # bounded and must stay re-readable by the same activation path.
  $phoneWidth=4032;$phoneHeight=3024
  $phonePixels=New-Object byte[] ($phoneWidth*$phoneHeight*4)
  $phoneRandom=[Random]::new(4242);$phoneRandom.NextBytes($phonePixels)
  $phoneImage=[Windows.Media.Imaging.BitmapSource]::Create($phoneWidth,$phoneHeight,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$phonePixels,$phoneWidth*4)
  $phonePath=Join-Path $testDirectory 'phone-photo.jpg'
  $phoneEncoder=[Windows.Media.Imaging.JpegBitmapEncoder]::new();$phoneEncoder.QualityLevel=60
  $phoneEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($phoneImage))
  $phoneStream=[IO.File]::Create($phonePath);try{$phoneEncoder.Save($phoneStream)}finally{$phoneStream.Dispose()}
  Assert-Equal (([IO.FileInfo]::new($phonePath)).Length-le 20MB) $true 'Phone photo source stays inside the accepted source limit'
  $phoneData=Join-Path $testDirectory 'phone-import';$null=[IO.Directory]::CreateDirectory($phoneData)
  $phoneImport=Import-WidgetCharacter $phoneData $phonePath
  $storedLength=([IO.FileInfo]::new($phoneImport.path)).Length
  Assert-Equal ($storedLength-le 20MB) $true 'Normalized phone photo stays inside the 20 MB reader limit'
  $storedPhone=Read-WidgetCharacterImage $phoneImport.path
  Assert-Equal ([Math]::Max($storedPhone.PixelWidth,$storedPhone.PixelHeight)) 2048 'Stored phone photo uses the bounded display resolution'
  Assert-Equal (Get-WidgetCharacter $fixtureApp $phoneData $phoneImport.id).path $phoneImport.path 'Phone photo import is selectable through the activation path'

  $unsafeId='custom-'+('a'*32)
  $saved=ConvertFrom-Json $manifestBefore
  Write-TestCharacterJson $manifestPath @{version=1;characters=@($saved.characters)+@(@{id=$unsafeId;name='unsafe';file='..\gpt-dragon-niang-bust.png'})}
  Assert-Equal @(Get-WidgetCharacters $fixtureApp $fixtureData).Count 3 'Custom manifest cannot traverse the characters directory'
  Assert-Throws {Resolve-WidgetCharacterPath $fixtureAssets '..\outside.png'} 'Built-in manifest traversal is rejected'
  Assert-Throws {Resolve-WidgetCharacterPath $fixtureAssets $sourcePath} 'Absolute manifest paths are rejected'
  [IO.File]::WriteAllText($manifestPath,'{ broken')
  Assert-Equal @(Get-WidgetCharacters $fixtureApp $fixtureData).Count 2 'Damaged custom catalog keeps built-ins available'
  $validPath=Join-Path $testDirectory 'valid.png';Write-TestCharacterImage $validPath
  Assert-Throws {Import-WidgetCharacter $fixtureData $validPath} 'Damaged catalog is not silently overwritten by import'
  Assert-Equal ([IO.File]::ReadAllText($manifestPath)) '{ broken' 'Failed catalog read retains original bytes'
  [IO.File]::WriteAllText($manifestPath,$manifestBefore,[Text.UTF8Encoding]::new($false))

  # Fail the atomic commit after image encoding, then verify file and catalog rollback.
  $manifestLock=[IO.File]::Open($manifestPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try{Assert-Throws {Import-WidgetCharacter $fixtureData $validPath} 'Locked catalog replacement should fail'}finally{$manifestLock.Dispose()}
  Assert-Equal ([IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8)) $manifestBefore 'Atomic commit failure retains the old catalog'
  Assert-Equal @([IO.Directory]::GetFiles((Join-Path $fixtureData 'characters'))).Count $imageCount 'Atomic commit failure removes the newly encoded image'
  Assert-Equal @([IO.Directory]::GetFiles($fixtureData,'*.tmp')).Count 0 'Atomic commit failure removes temporary manifests'

  # Removal owns only our normalized copy and keeps a recoverable history.
  $removalData=Join-Path $fixtureData 'removal-cases';$null=[IO.Directory]::CreateDirectory($removalData)
  $sourceBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($validPath))
  $removable=Import-WidgetCharacter $removalData $validPath
  $removalManifest=Join-Path $removalData 'characters.json';$removalBefore=[IO.File]::ReadAllText($removalManifest,[Text.Encoding]::UTF8)
  $removalLock=[IO.File]::Open($removalManifest,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try{Assert-Throws {Remove-WidgetCharacter $removalData $removable.id} 'Failed removal commit must roll back the image move'}finally{$removalLock.Dispose()}
  Assert-Equal ([IO.File]::Exists($removable.path)) $true 'Removal commit failure restores the owned image'
  Assert-Equal ([IO.File]::ReadAllText($removalManifest,[Text.Encoding]::UTF8)) $removalBefore 'Removal commit failure keeps the previous catalog'
  $removed=Remove-WidgetCharacter $removalData $removable.id
  Assert-Equal ([IO.File]::Exists($removable.path)) $false 'Successful removal leaves the active image directory'
  Assert-Equal ([IO.File]::Exists($removed.path)) $true 'Removed image remains recoverable'
  Assert-Equal @(Get-WidgetRemovedCharacters $removalData).Count 1 'Recovery history is persisted'
  Assert-Equal @(Get-WidgetCharacters $fixtureApp $removalData).Count 2 'Removed image disappears from the active catalog'
  $removedManifest=[IO.File]::ReadAllText($removalManifest,[Text.Encoding]::UTF8)
  $removalLock=[IO.File]::Open($removalManifest,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try{Assert-Throws {Restore-WidgetCharacter $removalData $removable.id} 'Failed restore commit must roll back the image move'}finally{$removalLock.Dispose()}
  Assert-Equal ([IO.File]::Exists($removed.path)) $true 'Restore commit failure puts the image back in recovery storage'
  Assert-Equal ([IO.File]::Exists($removable.path)) $false 'Restore commit failure does not activate an unlisted image'
  Assert-Equal ([IO.File]::ReadAllText($removalManifest,[Text.Encoding]::UTF8)) $removedManifest 'Restore commit failure retains recovery history'
  $secondImport=Import-WidgetCharacter $removalData $validPath
  Assert-Equal @(Get-WidgetRemovedCharacters $removalData).Count 1 'Later imports preserve recovery history'
  $restored=Restore-WidgetCharacter $removalData $removable.id
  Assert-Equal $restored.id $removable.id 'Restore preserves the stable ID'
  Assert-Equal $restored.path $removable.path 'Restore returns the same owned path'
  Assert-Equal @(Get-WidgetRemovedCharacters $removalData).Count 0 'Restored history entry is cleared'
  Assert-Equal @(Get-WidgetCharacters $fixtureApp $removalData).Count 4 'Restore retains all other imports'
  Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($validPath))) $sourceBytes 'Remove and restore never change the original source file'
  Assert-Throws {Remove-WidgetCharacter $removalData 'gpt-dragon'} 'Built-in characters cannot be removed'
  $unsafeCatalog=Read-WidgetCharacterCatalog $removalManifest
  @($unsafeCatalog.characters|Where-Object{$_.id-eq $removable.id})[0].file='..\outside.png'
  Write-WidgetCharacterCatalog $removalManifest $unsafeCatalog
  Assert-Throws {Remove-WidgetCharacter $removalData $removable.id} 'Removal rejects a manifest path outside the owned directory'
  Assert-Equal ([IO.File]::Exists($removable.path)) $true 'Rejected removal leaves the owned image intact'

  # Exercise the production switcher and settings writer without running widget.ps1.
  $widgetSource=[IO.File]::ReadAllText((Join-Path $sourceAppDir 'widget.ps1'),[Text.Encoding]::UTF8)
  $tokens=$null;$parseErrors=$null
  $widgetAst=[Management.Automation.Language.Parser]::ParseInput($widgetSource,[ref]$tokens,[ref]$parseErrors)
  if($parseErrors.Count){throw ($parseErrors|Out-String)}
  foreach($name in @('Write-WidgetJson','Save-Settings','Set-WidgetCharacter','Test-GirlAlpha')){
    $definition=$widgetAst.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq $name},$true)
    if(!$definition){throw ('Missing widget integration: '+$name)}
    . ([ScriptBlock]::Create($definition.Extent.Text))
  }
  $script:appDir=$fixtureApp;$script:dataDir=$fixtureData;$settingsFile=Join-Path $fixtureData 'settings.json'
  $script:settingsMenuUi=$null;$script:widgetColors=$null;$script:characterId='gpt-dragon';$script:activeCharacter=$null
  $script:bitmap=$null;$script:alphaBitmap=$null;$script:alphaStride=0;$script:alphaPixels=$null
  $root=[Windows.Controls.Canvas]::new();$root.Width=350;$root.Height=350
  $girl=[Windows.Controls.Image]::new();$girl.Width=208;$girl.Height=208;$girl.Stretch=[Windows.Media.Stretch]::Uniform
  [Windows.Controls.Canvas]::SetLeft($girl,142);[Windows.Controls.Canvas]::SetTop($girl,142);$root.Children.Add($girl)|Out-Null
  $script:ui=@{Root=$root;Girl=$girl}
  $null=Set-WidgetCharacter 'gpt-dragon' -NoSave
  Assert-Equal ([IO.File]::Exists($settingsFile)) $false 'Startup image load does not rewrite settings'
  $mask=[Windows.Media.ImageBrush]::new($script:bitmap)
  $halo=[Windows.Shapes.Rectangle]::new();$tint=[Windows.Shapes.Rectangle]::new();$halo.OpacityMask=$mask;$tint.OpacityMask=$mask
  $script:widgetColors=@{halo=$halo;tint=$tint}
  $switched=Set-WidgetCharacter 'test-alternative'
  Assert-Equal $switched.id 'test-alternative' 'Switcher returns the applied character'
  Assert-Equal $script:bitmap.PixelWidth 2 'Switch replaces the character pixels'
  Assert-Equal $script:alphaStride 8 'Switch replaces alpha stride for the new dimensions'
  Assert-Equal $script:alphaPixels.Length 32 'Switch replaces the complete alpha map'
  Assert-Equal $mask.Stretch Uniform 'Color silhouette preserves character proportions'
  Assert-Equal ([object]::ReferenceEquals($mask.ImageSource,$script:ui.Girl.Source)) $true 'Both color overlays follow the newly selected image'
  $persisted=[IO.File]::ReadAllText($settingsFile,[Text.Encoding]::UTF8)|ConvertFrom-Json
  Assert-Equal $persisted.characterId 'test-alternative' 'Actual settings writer persists the built-in choice'
  $null=Set-WidgetCharacter $persisted.characterId -NoSave
  Assert-Equal $script:characterId 'test-alternative' 'Saved selection can be restored at startup'
  $root.Measure([Windows.Size]::new(350,350));$root.Arrange([Windows.Rect]::new(0,0,350,350));$root.UpdateLayout()
  Assert-Equal (Test-GirlAlpha ([Windows.Point]::new(220,168))) $false 'Narrow image transparent pixel clicks through'
  Assert-Equal (Test-GirlAlpha ([Windows.Point]::new(272,168))) $true 'Narrow image partially opaque pixel accepts clicks'
  Assert-Equal (Test-GirlAlpha ([Windows.Point]::new(340,220))) $false 'Narrow image side letterbox clicks through'
  $null=Set-WidgetCharacter $imported.id
  Assert-Equal (([IO.File]::ReadAllText($settingsFile,[Text.Encoding]::UTF8)|ConvertFrom-Json).characterId) $imported.id 'Actual settings writer persists an imported ID'
  $root.Measure([Windows.Size]::new(350,350));$root.Arrange([Windows.Rect]::new(0,0,350,350));$root.UpdateLayout()
  Assert-Equal (Test-GirlAlpha ([Windows.Point]::new(176.666,211.333))) $false 'Wide image transparent pixel clicks through'
  Assert-Equal (Test-GirlAlpha ([Windows.Point]::new(315.333,211.333))) $true 'Wide image opaque pixel accepts clicks'
  Assert-Equal (Test-GirlAlpha ([Windows.Point]::new(200,150))) $false 'Wide image top letterbox clicks through'
  $beforeImage=$script:bitmap;$beforeAlpha=$script:alphaPixels;$beforeSettings=[IO.File]::ReadAllText($settingsFile,[Text.Encoding]::UTF8)
  $badId='custom-'+('b'*32);$badFile=$badId+'.png';[IO.File]::WriteAllText((Join-Path $fixtureData ('characters\'+$badFile)),'broken')
  Write-TestCharacterJson $manifestPath @{version=1;characters=@($saved.characters)+@(@{id=$badId;name='broken';file=$badFile})}
  Assert-Throws {Set-WidgetCharacter $badId} 'Corrupt selected image must reject the switch'
  Assert-Equal $script:characterId $imported.id 'Failed image switch retains the current ID'
  Assert-Equal ([object]::ReferenceEquals($script:bitmap,$beforeImage)) $true 'Failed image switch retains the visible image'
  Assert-Equal ([object]::ReferenceEquals($script:alphaPixels,$beforeAlpha)) $true 'Failed image switch retains click alpha map'
  Assert-Equal ([IO.File]::ReadAllText($settingsFile,[Text.Encoding]::UTF8)) $beforeSettings 'Failed image switch retains persisted selection'
  [IO.File]::WriteAllText($manifestPath,$manifestBefore,[Text.UTF8Encoding]::new($false))
  [IO.File]::Delete((Join-Path $fixtureData ('characters\'+$badFile)))
  $settingsLock=[IO.File]::Open($settingsFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try{Assert-Throws {Set-WidgetCharacter 'test-alternative'} 'Failed settings commit must reject the switch'}finally{$settingsLock.Dispose()}
  Assert-Equal $script:characterId $imported.id 'Failed settings commit restores current ID'
  Assert-Equal ([object]::ReferenceEquals($script:bitmap,$beforeImage)) $true 'Failed settings commit restores visible image'
  Assert-Equal ([object]::ReferenceEquals($script:alphaPixels,$beforeAlpha)) $true 'Failed settings commit restores click alpha map'
  Assert-Equal ([object]::ReferenceEquals($mask.ImageSource,$beforeImage)) $true 'Failed settings commit restores both color silhouettes'
  Assert-Equal ([IO.File]::ReadAllText($settingsFile,[Text.Encoding]::UTF8)) $beforeSettings 'Failed settings commit retains the previous persisted ID'
  $null=Set-WidgetCharacter 'missing-id'
  Assert-Equal $script:characterId 'gpt-dragon' 'Missing image ID safely selects the default'

  # Run the complete production gallery with an isolated off-screen WPF owner.
  # Routed events exercise callbacks without native input or the file picker.
  $gallerySource=[IO.File]::ReadAllText((Join-Path $sourceAppDir 'runtime\character-gallery.ps1'),[Text.Encoding]::UTF8)
  . ([ScriptBlock]::Create($gallerySource))
  $script:appDir=$fixtureApp;$script:dataDir=$fixtureData;$script:characterId=$imported.id
  $script:characterGallery=$null
  $script:window=[Windows.Window]::new();$script:window.Title='GPT character gallery test owner'
  $script:window.Width=50;$script:window.Height=50;$script:window.Left=-10000;$script:window.Top=-10000
  $script:window.ShowInTaskbar=$false;$script:window.ShowActivated=$false;$script:window.Show()
  $initialData=Join-Path $fixtureData 'initial-gallery';$null=[IO.Directory]::CreateDirectory($initialData)
  $script:dataDir=$initialData;$script:characterId='gpt-dragon'
  Open-WidgetCharacterGallery
  $initialCards=$script:characterGallery.FindName('CharacterCards')
  Assert-Equal $initialCards.Children.Count 3 'Initial gallery has two built-ins and one add placeholder'
  Assert-Equal $initialCards.Children[2].Tag 'add-character' 'Initial add placeholder follows both built-ins'
  $script:characterGallery.Close();$script:dataDir=$fixtureData;$script:characterId=$imported.id
  Open-WidgetCharacterGallery
  Assert-Equal $script:characterGallery.IsVisible $true 'Full production gallery opens successfully'
  Assert-Equal ([object]::ReferenceEquals($script:characterGallery.Owner,$script:window)) $true 'Gallery is owned by the shown widget window'
  $firstGallery=$script:characterGallery
  Open-WidgetCharacterGallery
  Assert-Equal ([object]::ReferenceEquals($script:characterGallery,$firstGallery)) $true 'Opening a visible gallery retains one instance'
  $cards=$script:characterGallery.FindName('CharacterCards')
  Assert-Equal $script:characterGallery.WindowStyle None 'Gallery has no system title bar'
  $closeButton=$script:characterGallery.FindName('CloseGallery')
  Assert-Equal ($closeButton.Content-is [Windows.Shapes.Path]) $true 'Close control uses a vector icon instead of font metrics'
  Assert-Equal $closeButton.Content.Data.GetFlattenedPathGeometry().Figures.Count 2 'Close vector contains two crossing lines'
  Assert-Equal ($null-eq $script:characterGallery.FindName('ImportCharacter')) $true 'Title area has no separate import button'
  Assert-Equal $script:characterGallery.FindName('TitleDragArea').Child.Text '选择你喜欢的形象' 'Title area has no old subtitle'
  Assert-Equal $script:characterGallery.FindName('CharacterFeedback').Text '添加新形象时，推荐使用透明背景PNG' 'Footer uses the requested exact hint'
  Assert-Equal ($null-ne $script:characterGallery.FindName('TitleDragArea')) $true 'Gallery exposes a draggable title area'
  $scrollStyle=$script:characterGallery.Resources[[Windows.Controls.Primitives.ScrollBar]]
  Assert-Equal @($scrollStyle.Setters|Where-Object{$_.Property.Name-eq 'Width'})[0].Value 8 'Gallery scrollbar is a custom thin track'
  $script:characterGallery.UpdateLayout()
  $closeBounds=$closeButton.Content.Data.Bounds
  $closeCenter=$closeButton.Content.TranslatePoint([Windows.Point]::new($closeBounds.X+$closeBounds.Width/2,$closeBounds.Y+$closeBounds.Height/2),$closeButton)
  if([Math]::Abs($closeCenter.X-$closeButton.ActualWidth/2)-gt 0.05 -or [Math]::Abs($closeCenter.Y-$closeButton.ActualHeight/2)-gt 0.05){throw 'Close vector is not centered in the button'}
  function Find-TestGalleryScrollBar($Node){
    if($Node-is [Windows.Controls.Primitives.ScrollBar] -and $Node.Visibility-eq [Windows.Visibility]::Visible){return $Node}
    for($i=0;$i-lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Node);$i++){
      $found=Find-TestGalleryScrollBar ([Windows.Media.VisualTreeHelper]::GetChild($Node,$i));if($found){return $found}
    }
  }
  $visibleBar=Find-TestGalleryScrollBar $script:characterGallery
  Assert-Equal ($null-ne $visibleBar) $true 'Overflowing cards display the custom scrollbar'
  Assert-Equal $visibleBar.Width 8 'Visible scrollbar uses the thin style'
  Assert-Equal $visibleBar.ActualWidth 8 'System theme minimum width cannot widen the scrollbar'
  $scrollTrack=$visibleBar.Template.FindName('PART_Track',$visibleBar)
  Assert-Equal ([object]::ReferenceEquals($scrollTrack.Thumb.Style,$script:characterGallery.Resources['LavenderScrollThumb'])) $true 'Visible scrollbar has the lavender thumb template'
  $scrollView=$script:characterGallery.FindName('CharacterScroll')
  $scrollView.ScrollToBottom();$scrollView.UpdateLayout()
  [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
  Assert-Equal ($scrollView.VerticalOffset-gt 0) $true 'Custom scrollbar allows scrolling to the last imported card'
  $scrollView.ScrollToTop();$scrollView.UpdateLayout()
  Assert-Equal $cards.Columns 2 'Gallery uses two preview columns'
  Assert-Equal $cards.Children.Count 4 'Gallery includes built-ins, imported choice and add placeholder'
  Assert-Equal $cards.Children[$cards.Children.Count-1].Tag 'add-character' 'Add placeholder always follows all character cards'
  $addButton=$cards.Children[$cards.Children.Count-1].Children[0]
  Assert-Equal $addButton.Content.Children[1].Text '添加形象' 'Add placeholder has a short caption'
  Assert-Equal ($addButton.Content.Children[0].Child-is [Windows.Shapes.Path]) $true 'Add placeholder uses a vector plus'
  $script:testPickerCalls=0
  function Open-WidgetCharacterPicker {$script:testPickerCalls++}
  $addButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert-Equal $script:testPickerCalls 1 'Whole add card invokes the shared file picker entry'
  Assert-Equal $script:characterGallery.IsVisible $true 'Cancelling the add picker leaves the gallery open'
  Assert-Equal $script:characterId $imported.id 'Cancelling the add picker retains the current selection'
  $selected=@($cards.Children|Where-Object{$_.Tag-eq $imported.id})[0]
  $selectedButton=$selected.Children[0]
  Assert-Equal $selectedButton.Content.Children[2].Text '✓ 当前使用' 'Imported selection has an explicit current indicator'
  Assert-Equal ([Windows.Media.RenderOptions]::GetBitmapScalingMode($selectedButton.Content.Children[0])) HighQuality 'Gallery previews use high quality scaling'
  Assert-Equal $selectedButton.Content.Children[0].Stretch Uniform 'Gallery preserves arbitrary picture proportions'
  Assert-Equal $selected.Children.Count 2 'Imported card has a separate remove control'
  Assert-Equal ($selected.Children[1].Content-is [Windows.Shapes.Path]) $true 'Imported remove control uses a vector minus'
  Assert-Equal $selected.Children[1].Content.Data.Bounds.Height 0 'Remove icon is one horizontal line rather than a close X'
  Assert-Equal @($cards.Children|Where-Object{$_.Tag-eq 'gpt-dragon'})[0].Children.Count 1 'Built-in card has no remove control'
  function Update-WidgetSettingsMenu {}
  $null=Set-WidgetCharacter $imported.id
  $beforeRemovalImage=$script:bitmap
  $settingsLock=[IO.File]::Open($settingsFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try{Assert-Throws {Remove-WidgetGalleryCharacter $imported.id} 'Failed fallback save must retain the selected imported character'}finally{$settingsLock.Dispose()}
  Assert-Equal ([IO.File]::Exists($imported.path)) $true 'Failed fallback leaves the imported copy intact'
  Assert-Equal $script:characterId $imported.id 'Failed fallback retains the selected ID'
  $catalogLock=[IO.File]::Open($manifestPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try{Assert-Throws {Remove-WidgetGalleryCharacter $imported.id} 'Failed removal commit restores a selected character after fallback'}finally{$catalogLock.Dispose()}
  Assert-Equal $script:characterId $imported.id 'Removal commit failure restores the previous selection'
  Assert-Equal ([IO.File]::Exists($imported.path)) $true 'Removal commit failure retains the imported copy'
  $selected.Children[1].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert-Equal $script:characterId 'gpt-dragon' 'Removing the selected imported card falls back to classic'
  Assert-Equal (([IO.File]::ReadAllText($settingsFile,[Text.Encoding]::UTF8)|ConvertFrom-Json).characterId) 'gpt-dragon' 'Removal fallback persists the default selection'
  Assert-Equal $script:characterGallery.IsVisible $true 'Removal keeps the gallery open for undo'
  Assert-Equal $script:characterGallery.FindName('UndoRemoval').Visibility Visible 'Removed image has a visible undo action'
  $script:characterGallery.FindName('UndoRemoval').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert-Equal ([IO.File]::Exists($imported.path)) $true 'Undo restores the imported image'
  Assert-Equal $script:characterGallery.FindName('UndoRemoval').Visibility Collapsed 'Undo action clears after restoring the only removed item'
  $cards=$script:characterGallery.FindName('CharacterCards')
  $builtInCard=@($cards.Children|Where-Object{$_.Tag-eq 'test-alternative'})[0]
  $builtInCard.Children[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert-Equal $script:characterId 'test-alternative' 'Gallery card invokes the actual character switcher'
  Assert-Equal (([IO.File]::ReadAllText($settingsFile,[Text.Encoding]::UTF8)|ConvertFrom-Json).characterId) 'test-alternative' 'Gallery click persists its choice'
  Assert-Equal ($null-eq $script:characterGallery) $true 'Successful character switch automatically closes the gallery'
  Open-WidgetCharacterGallery
  Assert-Throws {Import-WidgetGalleryCharacter $corruptPath} 'Rejected gallery import must remain open'
  Assert-Equal $script:characterGallery.IsVisible $true 'Failed gallery import keeps the choices visible'
  Import-WidgetGalleryCharacter $validPath
  Assert-Equal ($null-eq $script:characterGallery) $true 'Successful gallery import switches and automatically closes'
  Assert-Equal ($script:characterId-match '^custom-[0-9a-f]{32}$') $true 'Gallery import activates its new stable ID'
  Open-WidgetCharacterGallery
  $escape=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($script:characterGallery),0,[Windows.Input.Key]::Escape)
  $escape.RoutedEvent=[Windows.Input.Keyboard]::KeyDownEvent;$script:characterGallery.RaiseEvent($escape)
  Assert-Equal ($null-eq $script:characterGallery) $true 'Escape closes the gallery'
  Open-WidgetCharacterGallery
  $script:characterGallery.FindName('CloseGallery').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert-Equal ($null-eq $script:characterGallery) $true 'Complete button closes and clears the gallery instance'
  Assert-Equal $firstGallery.IsVisible $false 'Closed gallery has no visible window'
  $script:window.Close();$script:window=$null
  Write-Output 'PASS: catalog/import/remove/restore rollback, retained source, persisted switches, alpha/masks, frameless gallery, centered vector close, last add placeholder, picker dispatch, exact hint, minus remove, undo, auto-close and Escape'
}finally{
  if($script:characterGallery){$script:characterGallery.Close();$script:characterGallery=$null}
  if($script:window){$script:window.Close();$script:window=$null}
  $resolved=[IO.Path]::GetFullPath($testDirectory)
  $tempRoot=[IO.Path]::GetFullPath($TestRoot).TrimEnd([char[]]@('\','/'))+[IO.Path]::DirectorySeparatorChar
  if(!$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe character test cleanup path'}
  if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
