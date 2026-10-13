param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime\sharp-text.ps1')
$script:ui=@{}
$source=[IO.File]::ReadAllText((Join-Path $appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$native=[regex]::Match($source,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if(!$native.Success){throw 'Missing widget native API definition.'}
Add-Type -TypeDefinition $native.Groups[1].Value
$null=[GptWidgetNative]::SetProcessDpiAwarenessContext([IntPtr](-4))
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors|Out-String)}
$follow=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Tick-Widget'},$true)
$drag=$ast.Find({param($node)$node-is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text-eq '$pressMove'},$true)
$paths=@{follow=$follow;drag=$drag}
$resizeExpressions=@{}
foreach($entry in $paths.GetEnumerator()){
  if(!$entry.Value){throw ('Missing resize path: '+$entry.Key)}
  $assignments=@($entry.Value.FindAll({param($node)$node-is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text-in @('$w','$h')},$true))
  if($assignments.Count-ne 2){throw ('Expected width and height assignments for '+$entry.Key)}
  $resizeExpressions[$entry.Key]=[scriptblock]::Create(($assignments|ForEach-Object{$_.Extent.Text})-join "`n")
}
$designAssignments=@($ast.FindAll({param($node)$node-is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text-in @('$script:designWidth','$script:designHeight')},$true))
function Pump-SizeTest {
  $frame=[Windows.Threading.DispatcherFrame]::new()
  $timer=[Windows.Threading.DispatcherTimer]::new()
  $timer.Interval=[TimeSpan]::FromMilliseconds(20)
  $timer.Tag=$frame
  $timer.Add_Tick({param($sender,$event)$sender.Stop();$sender.Tag.Continue=$false})
  $timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)
}
$size=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq 'Set-WidgetPixelSize'},$true)
. ([ScriptBlock]::Create($size.Extent.Text))
$checks=0
# Run the production resize expressions against a real invisible WPF HWND.
# Its mutable Width/Height must never become the next update's size baseline.
foreach($layout in @(@{width=378;height=378},@{width=480;height=300})){
  $script:window=[Windows.Markup.XamlReader]::Parse((ConvertTo-SmoothWidgetXaml ([IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml'),[Text.Encoding]::UTF8)) -AppDir $appDir))
  $stage=$script:window.FindName('AnimationStage')
  $stage.Width=$layout.width;$stage.Height=$layout.height
  $script:designWidth=$null;$script:designHeight=$null
  foreach($assignment in $designAssignments){. ([scriptblock]::Create($assignment.Extent.Text))}
  $script:window.Opacity=0;$script:window.IsHitTestVisible=$false;$script:window.Title='GPT Niang size regression (invisible)'
  try{
    $script:window.Show()
    $handle=([Windows.Interop.WindowInteropHelper]::new($script:window)).Handle
    Pump-SizeTest
    $workArea=[Windows.Forms.Screen]::FromHandle($handle).WorkingArea
    $availableWidth=[Math]::Min(900,$workArea.Width-32)
    $availableHeight=[Math]::Min(900,$workArea.Height-32)
    foreach($path in @('follow','drag')){
      foreach($monitorDpi in @(120,144)){
        foreach($requestedScale in @(0.6,0.7,0.8,1.0,1.4,2.5)){
          $dpi=$monitorDpi/96.0
          # Model the existing fit-to-host behavior and stay within a CI desktop.
          $script:displayScale=[Math]::Min($requestedScale,[Math]::Min($availableWidth/$dpi/$layout.width,$availableHeight/$dpi/$layout.height))
          $script:window.Width=$layout.width*$script:displayScale
          $script:window.Height=$layout.height*$script:displayScale
          Pump-SizeTest
          $expectedWidth=[int]($layout.width*$script:displayScale*$dpi)
          $expectedHeight=[int]($layout.height*$script:displayScale*$dpi)
          for($iteration=0;$iteration-lt 6;$iteration++){
            . $resizeExpressions[$path]
            $null=Set-WidgetPixelSize $dpi
            if(![GptWidgetNative]::SetWindowPos($handle,[IntPtr]::Zero,0,0,0,0,0x15)){throw 'Native move failed.'}
            Pump-SizeTest
            $actual=[GptWidgetNative+Rect]::new()
            if(![GptWidgetNative]::GetWindowRect($handle,[ref]$actual)){throw 'Cannot read resized HWND.'}
            $width=$actual.Right-$actual.Left;$height=$actual.Bottom-$actual.Top
            if([Math]::Abs($width-$expectedWidth)-gt 1 -or [Math]::Abs($height-$expectedHeight)-gt 1){
              throw "Size drift: $path DPI=$monitorDpi scale=$requestedScale iteration=$iteration expected=${expectedWidth}x${expectedHeight}, actual=${width}x${height}"
            }
            $checks++
          }
        }
      }
    }
  }finally{$script:window.Close()}
}
Write-Output "PASS: $checks WPF physical size updates with move-only native placement; follow/drag, 120/144 DPI, six scales and square/non-square XAML designs"
