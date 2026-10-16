param([string]$TestRoot=$PSScriptRoot,[string]$PreviewDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime\quotes.ps1')
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime\ui-settings.ps1'),[Text.Encoding]::UTF8)))
function Assert-Equal($Actual,$Expected,[string]$Message){if($Actual-cne $Expected){throw "$Message : expected '$Expected', got '$Actual'"}}
$script:dataDir=Join-Path $TestRoot ('quote-editor-fixture-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($script:dataDir)
$script:window=[Windows.Window]::new();$script:window.Left=-32000;$script:window.Top=-32000;$script:window.Opacity=0;$script:window.Show()
function Click($Button){$Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
function Save-EditorPreview($Editor,[string]$Name){
  if(!$PreviewDirectory){return};$null=[IO.Directory]::CreateDirectory($PreviewDirectory)
  $Editor.UpdateLayout();$render=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$Editor.ActualWidth,[int]$Editor.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$render.Render($Editor)
  $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render));$stream=[IO.File]::Create((Join-Path $PreviewDirectory $Name));try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
try{
  $null=Save-WidgetQuotes $script:dataDir @('正常语录不变')
  Open-QuoteEditor
  $normal=$script:quoteEditor;$normal.Left=-32000;$normal.Top=-32000
  $manager=$normal.FindName('LowQuotaManager')
  Assert-Equal $manager.Visibility Visible 'Normal editor exposes low quota manager'
  $managerPoint=$manager.TranslatePoint([Windows.Point]::new(0,0),$normal)
  Assert-Equal ($managerPoint.X-lt $normal.ActualWidth/2 -and $managerPoint.Y-gt $normal.ActualHeight/2) $true 'Management button is at lower left'
  Click $manager
  $low=$script:lowQuoteEditor;$low.Left=-32000;$low.Top=-32000
  Assert-Equal $low.Title 'GPT 娘 · 额度耗尽语录' 'Low editor has explicit title'
  Assert-Equal $low.FindName('LowQuotaManager').Visibility Collapsed 'Low editor does not recursively show manager'
  $normalBefore=[IO.File]::ReadAllText((Join-Path $script:dataDir 'quotes.json'))
  $low.FindName('Lines').Text="3 | 需要重置……`n测试耗尽台词"
  Click $low.FindName('Save')
  $saved=Get-WidgetQuoteSettings $script:dataDir -LowQuota
  Assert-Equal $saved.source custom 'Low pool saved independently'
  Assert-Equal $saved.quotes.Count 2 'Low editor parses two lines'
  Assert-Equal $saved.quotes[0].weight 3 'Low editor retains weight'
  Assert-Equal ([IO.File]::ReadAllText((Join-Path $script:dataDir 'quotes.json'))) $normalBefore 'Saving low quotes does not change normal pool'
  for($i=0;$i-lt 20;$i++){if((Get-WidgetQuote $script:dataDir -LowQuota)-notin $saved.quotes.text){throw 'Low quote selection ignored custom pool'}}
  $low.FindName('Lines').Text=''
  Click $low.FindName('Save')
  Assert-Equal (Get-WidgetQuoteSettings $script:dataDir -LowQuota).quotes.Count 2 'Empty save retains previous low pool'
  Click $low.FindName('Defaults')
  Assert-Equal (Get-WidgetQuoteSettings $script:dataDir -LowQuota).source 'built-in' 'Low reset restores bundled low pool'
  Assert-Equal ([IO.File]::Exists((Join-Path $script:dataDir 'quotes-low-quota.json.bak'))) $true 'Low reset preserves backup'
  Assert-Equal ([IO.File]::ReadAllText((Join-Path $script:dataDir 'quotes.json'))) $normalBefore 'Low reset leaves normal quotes untouched'
  Save-EditorPreview $normal 'normal-quotes-editor.png';Save-EditorPreview $low 'low-quota-quotes-editor.png'
  Click $low.FindName('Done')
  Assert-Equal $normal.IsVisible $true 'Closing low editor does not close normal editor'
  Open-QuoteEditor -LowQuota
  Assert-Equal $script:lowQuoteEditor.IsVisible $true 'Closed low editor can reopen'
  Click $normal.FindName('Done')
  Assert-Equal $script:lowQuoteEditor.IsVisible $true 'Closing normal editor does not close independent low editor'
  Write-Output 'PASS: lower-left management action, real save/reset/reopen, weighted custom low pool, empty-save rejection and isolation from normal quotes'
}finally{
  if($script:lowQuoteEditor){$script:lowQuoteEditor.Close()};if($script:quoteEditor){$script:quoteEditor.Close()};$script:window.Close()
  $resolved=[IO.Path]::GetFullPath($script:dataDir);$allowed=[IO.Path]::GetFullPath($TestRoot).TrimEnd('\')+'\'
  if(!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe editor fixture path'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
