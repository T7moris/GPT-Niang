param([switch]$CheckOnly,[switch]$Preview,[string]$AppDir=$PSScriptRoot)
$ErrorActionPreference='Stop'
$script:appDir=$AppDir
$script:configPath=Join-Path $script:appDir 'installation.json'
if(!(Test-Path -LiteralPath $script:configPath)){throw 'Please run Install.ps1 first.'}
$script:config=Get-Content -LiteralPath $script:configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:dataDir=$script:config.dataDir
$null=New-Item -ItemType Directory -Path $script:dataDir -Force
. (Join-Path $script:appDir 'runtime\quotes.ps1')
. (Join-Path $script:appDir 'runtime\completion-notifications.ps1')
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\ui-settings.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\characters.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\character-gallery.ps1'),[Text.Encoding]::UTF8)))
. (Join-Path $script:appDir 'runtime\audio.ps1')
. (Join-Path $script:appDir 'runtime\host-layer.ps1')
. (Join-Path $script:appDir 'runtime\host-follow.ps1')
. (Join-Path $script:appDir 'runtime\host-ready.ps1')
. (Join-Path $script:appDir 'runtime\host-occlusion.ps1')
. (Join-Path $script:appDir 'runtime\supervisor-task.ps1')
. (Join-Path $script:appDir 'runtime\update-common.ps1')
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\update-ui.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\color-theme.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\music.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\quote-layout.ps1'),[Text.Encoding]::UTF8)))
Initialize-WidgetQuoteLayouts $script:appDir
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Diagnostics;
public static class GptWidgetNative {
  static readonly int Session=CurrentSession();
  static int CurrentSession(){using(var process=Process.GetCurrentProcess())return process.SessionId;}
  public static bool CodexExecutable(string file){
    return !String.IsNullOrEmpty(file)&&(file.IndexOf("\\OpenAI.Codex_",StringComparison.OrdinalIgnoreCase)>=0||file.IndexOf("\\OpenAI\\Codex\\",StringComparison.OrdinalIgnoreCase)>=0);
  }
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
  public delegate bool EnumProc(IntPtr h,IntPtr p);
  public delegate void WinEventProc(IntPtr hook,uint ev,IntPtr h,int objectId,int childId,uint threadId,uint time);
  [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint first,uint last,IntPtr module,WinEventProc callback,uint processId,uint threadId,uint flags);
  [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hook);
  public static IntPtr Hook(uint first,uint last,WinEventProc callback){return SetWinEventHook(first,last,IntPtr.Zero,callback,0,0,2);}
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h,uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder b,int n);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int z,uint flags);
  [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h,int i);
  [DllImport("user32.dll",EntryPoint="SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr h,int i,IntPtr v);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h,int attr,out Rect r,int size);
  public static Rect Frame(IntPtr h){Rect r; if(DwmGetWindowAttribute(h,9,out r,16)!=0)GetWindowRect(h,out r); return r;}
  public static bool MainWindowStyle(long style,long extended){
    return (extended&0x80)==0&&(extended&0x08000000)==0&&(extended&0x40000)!=0&&(style&0x10000)!=0;
  }
  public static bool IsCodex(IntPtr h){
    if(h==IntPtr.Zero)return false;
    if(!MainWindowStyle(GetWindowLongPtr(h,-16).ToInt64(),GetWindowLongPtr(h,-20).ToInt64()))return false;
    var title=new StringBuilder(256);GetWindowText(h,title,256);if(title.Length==0)return false;
    var cls=new StringBuilder(128);GetClassName(h,cls,128);if(cls.ToString()!="Chrome_WidgetWin_1")return false;
    uint pid;GetWindowThreadProcessId(h,out pid);
    try{using(var p=Process.GetProcessById((int)pid)){var name=p.ProcessName;
      return p.SessionId==Session&&(name.Equals("Codex",StringComparison.OrdinalIgnoreCase)||name.Equals("ChatGPT",StringComparison.OrdinalIgnoreCase))&&CodexExecutable(p.MainModule.FileName);
    }}catch{return false;}
  }
  public static IntPtr FindCodex(){
    var f=GetAncestor(GetForegroundWindow(),2);if(IsCodex(f))return f;
    IntPtr found=IntPtr.Zero;
    EnumWindows((h,p)=>{if(IsWindowVisible(h)&&!IsIconic(h)&&IsCodex(h)){found=h;return false;}return true;},IntPtr.Zero);
    return found;
  }
  public static int ProcessId(IntPtr h){uint p;GetWindowThreadProcessId(h,out p);return (int)p;}
  public static IntPtr ForegroundHost(IntPtr h){var root=GetAncestor(h,2);return IsCodex(root)?root:IntPtr.Zero;}
  public static string Title(IntPtr h){var b=new StringBuilder(256);GetWindowText(h,b,256);return b.ToString();}
}
'@
Add-Type -TypeDefinition @'
using System;
using System.Windows;
using System.Windows.Media.Animation;
public sealed class GptBezierEase:EasingFunctionBase {
  public double X1=0.25,Y1=0.1,X2=0.25,Y2=1;
  static double Curve(double t,double a,double b){double u=1-t;return 3*u*u*t*a+3*u*t*t*b+t*t*t;}
  protected override double EaseInCore(double time){
    double low=0,high=1,t=time;
    for(int i=0;i<20;i++){t=(low+high)/2;if(Curve(t,X1,X2)<time)low=t;else high=t;}
    return Curve(t,Y1,Y2);
  }
  protected override Freezable CreateInstanceCore(){return new GptBezierEase{X1=X1,Y1=Y1,X2=X2,Y2=Y2};}
}
'@ -ReferencedAssemblies ([Windows.Media.Animation.EasingFunctionBase].Assembly.Location),([Windows.Freezable].Assembly.Location)
try{
  [GptWidgetNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
  # PowerShell may already have a process DPI context. Set the UI thread too,
  # so DWM, GetWindowRect and SetWindowPos all use physical screen pixels.
  [GptWidgetNative]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
}catch{}
. (Join-Path $script:appDir 'runtime\sharp-text.ps1')
$widgetXaml=ConvertTo-SmoothWidgetXaml ([IO.File]::ReadAllText((Join-Path $script:appDir 'widget.xaml'),[Text.Encoding]::UTF8)) -AppDir $script:appDir
$script:window=[Windows.Markup.XamlReader]::Parse($widgetXaml)
# Capture the unscaled XAML canvas before native resizing changes Window.Width/Height.
$script:designWidth=[double]$script:window.FindName('AnimationStage').Width
$script:designHeight=[double]$script:window.FindName('AnimationStage').Height
$script:ui=@{}
foreach($name in @('Root','Bubble','Tail','TailNear','SceneText','QuotaText','QuoteText','BubbleShape','Girl','PressScale','FacingScale','TextFacingScale','Header','Refresh','MenuButton','Status','LiveDot','ShortRow','WeekRow','ShortLabel','WeekLabel','ShortUsed','ShortLeft','ShortReset','ShortBar','WeekUsed','WeekLeft','WeekReset','WeekBar')){$script:ui[$name]=$script:window.FindName($name)}
$script:characterId='gpt-dragon';$script:activeCharacter=$null
$script:status=$null
$script:statusStamp=0
$script:offsetRight=0.0;$script:offsetBottom=0.0;$script:offsetLeft=$null;$script:anchor='right';$script:side='right';$script:scale=1.0;$script:bubbleScale=1.0;$script:collapsed=$true
$script:soundOn=$true;$script:soundVolume=0.9;$script:bubbleTapAdvance=$false;$script:hideMenu=$false
$script:followHost=$true;$script:desktopTopmost=$false;$script:desktopLeft=$null;$script:desktopTop=$null
$script:hostReadiness=New-WidgetReadinessState
$script:bubbleMode='quota';$script:sceneStartedAt=0;$script:sceneDeadline=0;$script:sceneTimer=$null;$script:sceneRevision=0
$script:resetTimeMode='countdown';$script:resetPhaseTimer=$null
$script:displayRequestToken=$null
$settingsFile=Join-Path $script:dataDir 'settings.json'
$script:settingsLoadFailed=$false
try{$settings=Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
  # Each field is read independently: one malformed value must not discard the
  # remaining valid preferences (and startup must not then overwrite them).
  if($null-ne $settings.right){try{$value=[double]$settings.right;if(![double]::IsNaN($value)-and ![double]::IsInfinity($value)-and [Math]::Abs($value)-le 100000){$script:offsetRight=[Math]::Max(0.0,$value)}}catch{}}
  if($null-ne $settings.bottom){
    try{$savedBottom=[double]$settings.bottom;if(![double]::IsNaN($savedBottom) -and ![double]::IsInfinity($savedBottom) -and [Math]::Abs($savedBottom)-le 100000){$script:offsetBottom=$savedBottom}}catch{}
  }
  if($null-ne $settings.scale){try{$savedScale=[double]$settings.scale;if($savedScale-ge 0.6 -and $savedScale-le 2.5){$script:scale=$savedScale}}catch{}}
  # Preserve the previous combined size until the bubble is adjusted separately.
  $script:bubbleScale=$script:scale
  try{$savedBubbleScale=[double]$settings.bubbleScale;if($savedBubbleScale-ge 0.6 -and $savedBubbleScale-le 2.5){$script:bubbleScale=$savedBubbleScale}}catch{}
  if($settings.layoutVersion-eq 2){
    if($null-ne $settings.left){
      try{$savedLeft=[double]$settings.left;if(![double]::IsNaN($savedLeft) -and ![double]::IsInfinity($savedLeft) -and [Math]::Abs($savedLeft)-le 100000){$script:offsetLeft=$savedLeft}}catch{}
    }
    if(@('left','right','free')-contains $settings.anchor){$script:anchor=$settings.anchor}
    if(@('left','right')-contains $settings.side){$script:side=$settings.side}
  }else{$script:offsetBottom=0;if($script:offsetRight-gt 18){$script:anchor='free'}}
  if($null-ne $settings.soundOn){$script:soundOn=($settings.soundOn-is [bool] -and $settings.soundOn)}
  if($null-ne $settings.soundVolume){try{$value=[double]$settings.soundVolume;if(![double]::IsNaN($value)-and ![double]::IsInfinity($value)){$script:soundVolume=[Math]::Min(1.0,[Math]::Max(0.0,$value))}}catch{}}
  if($null-ne $settings.bubbleTapAdvance){$script:bubbleTapAdvance=($settings.bubbleTapAdvance-is [bool] -and $settings.bubbleTapAdvance)}
  if($null-ne $settings.hideMenu){$script:hideMenu=($settings.hideMenu-is [bool] -and $settings.hideMenu)}
  if(@('original','linked','rainbow','surprise','rare','special','mixed')-contains $settings.colorMode){$script:colorMode=$settings.colorMode}
  if($null-ne $settings.colorChance){try{$chance=[double]$settings.colorChance;if(![double]::IsNaN($chance) -and $chance-ge 0 -and $chance-le 30){$script:colorChance=$chance}}catch{}}
  if($null-ne $settings.colorTextChance){try{$chance=[double]$settings.colorTextChance;if(![double]::IsNaN($chance) -and $chance-ge 0 -and $chance-le 30){$script:colorTextChance=$chance}}catch{}}
  if($null-ne $settings.colorPaused){$script:colorPaused=($settings.colorPaused-is [bool] -and $settings.colorPaused)}
  if($null-ne $settings.followHost){$script:followHost=($settings.followHost-is [bool] -and $settings.followHost)}
  if($null-ne $settings.desktopTopmost){$script:desktopTopmost=($settings.desktopTopmost-is [bool] -and $settings.desktopTopmost)}
  if($null-ne $settings.desktopLeft){try{$value=[double]$settings.desktopLeft;if(![double]::IsNaN($value)-and ![double]::IsInfinity($value)-and [Math]::Abs($value)-le 100000){$script:desktopLeft=$value}}catch{}}
  if($null-ne $settings.desktopTop){try{$value=[double]$settings.desktopTop;if(![double]::IsNaN($value)-and ![double]::IsInfinity($value)-and [Math]::Abs($value)-le 100000){$script:desktopTop=$value}}catch{}}
  if($settings.characterId-is [string]){$script:characterId=$settings.characterId}
}catch{$script:settingsLoadFailed=$true}
Initialize-WidgetAutoQuoteSettings $settings
Initialize-CompletionNotificationState $settings
function Write-WidgetJson($file,$value){
  $temp=$file+'.tmp';[IO.File]::WriteAllText($temp,($value|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
  if([IO.File]::Exists($file)){[IO.File]::Replace($temp,$file,($file+'.bak'),$true)}else{[IO.File]::Move($temp,$file)}
}
function Save-Settings {Write-WidgetJson $settingsFile @{layoutVersion=2;right=$script:offsetRight;left=$script:offsetLeft;bottom=$script:offsetBottom;anchor=$script:anchor;side=$script:side;scale=$script:scale;bubbleScale=$script:bubbleScale;collapsed=$script:collapsed;soundOn=$script:soundOn;soundVolume=$script:soundVolume;bubbleTapAdvance=$script:bubbleTapAdvance;hideMenu=$script:hideMenu;colorMode=$script:colorMode;colorChance=$script:colorChance;colorTextChance=$script:colorTextChance;colorPaused=$script:colorPaused;followHost=$script:followHost;desktopTopmost=$script:desktopTopmost;desktopLeft=$script:desktopLeft;desktopTop=$script:desktopTop;characterId=$script:characterId;autoQuoteEnabled=$script:autoQuoteEnabled;autoQuoteIntervalSeconds=$script:autoQuoteIntervalSeconds;taskCompletionBubble=$script:completionNotificationsEnabled}}
function Set-WidgetCharacter([string]$Id,[switch]$NoSave) {
  if($script:widgetMusic -and $script:widgetMusic.Enabled){Stop-WidgetMusic}
  $character=Get-WidgetCharacter $script:appDir $script:dataDir $Id
  # Decode and build the click-through map before replacing the current pose.
  $image=Read-WidgetCharacterImage $character.path
  $alpha=[Windows.Media.Imaging.FormatConvertedBitmap]::new($image,[Windows.Media.PixelFormats]::Bgra32,$null,0)
  $alpha.Freeze();$stride=$image.PixelWidth*4;$pixels=New-Object byte[] ($stride*$image.PixelHeight)
  $alpha.CopyPixels($pixels,$stride,0)
  $previous=@{bitmap=$script:bitmap;alpha=$script:alphaBitmap;stride=$script:alphaStride;pixels=$script:alphaPixels;id=$script:characterId;character=$script:activeCharacter}
  try{
    $script:bitmap=$image;$script:alphaBitmap=$alpha;$script:alphaStride=$stride;$script:alphaPixels=$pixels
    $script:characterId=$character.id;$script:activeCharacter=$character;$script:ui.Girl.Source=$image
    if($script:widgetColors){
      foreach($overlay in @($script:widgetColors.halo,$script:widgetColors.tint)){
        if($overlay -and $overlay.OpacityMask){$overlay.OpacityMask.ImageSource=$image;$overlay.OpacityMask.Stretch=[Windows.Media.Stretch]::Uniform}
      }
    }
    if(!$NoSave){Save-Settings}
  }catch{
    $script:bitmap=$previous.bitmap;$script:alphaBitmap=$previous.alpha;$script:alphaStride=$previous.stride;$script:alphaPixels=$previous.pixels
    $script:characterId=$previous.id;$script:activeCharacter=$previous.character;$script:ui.Girl.Source=$previous.bitmap
    if($script:widgetColors){foreach($overlay in @($script:widgetColors.halo,$script:widgetColors.tint)){if($overlay -and $overlay.OpacityMask){$overlay.OpacityMask.ImageSource=$previous.bitmap}}}
    throw
  }
  if($script:settingsMenuUi){Update-WidgetSettingsMenu}
  return $character
}
try{$null=Set-WidgetCharacter $script:characterId -NoSave}
catch{$script:characterLoadNotice='上次使用的图片无法读取，已恢复龙娘1。';$null=Set-WidgetCharacter 'gpt-dragon' -NoSave}
function Get-WidgetPlacementFrame {
  if($script:followHost){return [GptWidgetNative]::Frame($script:hostHandle)}
  $point=if($null-ne $script:desktopLeft -and $null-ne $script:desktopTop){[Drawing.Point]::new([int]$script:desktopLeft,[int]$script:desktopTop)}else{[Drawing.Point]::new(0,0)}
  return [Windows.Forms.Screen]::FromPoint($point).WorkingArea
}
function Get-WidgetPlacementDpi {
  $handle=if($script:followHost){$script:hostHandle}else{$script:widgetHandle}
  if(!$handle -or $handle-eq [IntPtr]::Zero){return 1.0}
  $dpi=[GptWidgetNative]::GetDpiForWindow($handle)/96.0
  if($dpi-le 0){$dpi=1};return $dpi
}
function Set-WidgetFollowHost([bool]$Follow) {
  if($script:widgetMusic -and $script:widgetMusic.Enabled){Stop-WidgetMusic}
  if(!$Follow -and $null-eq $script:desktopLeft){
    $frame=[GptWidgetNative]::Frame($script:widgetHandle)
    $script:desktopLeft=$frame.Left;$script:desktopTop=$frame.Top
  }
  $script:followHost=$Follow;$script:lastPosition=$null;$script:attachedHost=[IntPtr]::Zero
  if(!$Follow){$script:hostFollower.Detach();Set-WidgetDesktopLayer $script:widgetHandle $script:desktopTopmost}
  else{Set-WidgetDesktopLayer $script:widgetHandle $false}
  Set-Appearance;Save-Settings;Tick-Widget
}
function Set-Facing {
  $factor=if($script:side-eq 'left'){-1.0}else{1.0}
  $script:ui.FacingScale.ScaleX=$factor;$script:ui.TextFacingScale.ScaleX=$factor
  # Refresh now shares SceneText's mirror compensation with the title.
  $script:ui.Refresh.RenderTransform=[Windows.Media.Transform]::Identity
  $script:ui.MenuButton.RenderTransformOrigin=[Windows.Point]::new(0.5,0.5)
  $script:ui.MenuButton.RenderTransform=[Windows.Media.ScaleTransform]::new($factor,1)
}
function Get-WidgetLayoutScale {
  $bubble=if($script:bubbleScale-ge 0.6 -and $script:bubbleScale-le 2.5){[double]$script:bubbleScale}else{[double]$script:scale}
  return [Math]::Max([double]$script:scale,$bubble)
}
function Set-WidgetIndependentLayout {
  if(!$script:ui.Girl){return}
  $layoutScale=Get-WidgetLayoutScale
  $bubbleScale=if($script:bubbleScale-ge 0.6 -and $script:bubbleScale-le 2.5){[double]$script:bubbleScale}else{[double]$script:scale}
  if($script:ui.Girl){
    $character=$script:scale/$layoutScale;$bubble=$bubbleScale/$layoutScale
    $girlLeft=350-208*$character;$girlTop=350-208*$character
    $script:ui.Girl.Width=208*$character;$script:ui.Girl.Height=208*$character
    [Windows.Controls.Canvas]::SetLeft($script:ui.Girl,$girlLeft)
    [Windows.Controls.Canvas]::SetTop($script:ui.Girl,$girlTop)
    $script:ui.Bubble.LayoutTransform=[Windows.Media.ScaleTransform]::new($bubble,$bubble)
    $bubbleLeft=[Math]::Max(0,[Math]::Min(350-350*$bubble,$girlLeft+104*$character-246*$bubble))
    [Windows.Controls.Canvas]::SetLeft($script:ui.Bubble,$bubbleLeft)
    # A large bubble must stay inside the fixed design canvas; otherwise the
    # window clips its bottom edge for small characters with bubble scale 250%.
    $bubbleTop=[Math]::Max(0,[Math]::Min(350-239*$bubble,$girlTop-142*$bubble))
    [Windows.Controls.Canvas]::SetTop($script:ui.Bubble,$bubbleTop)
    $script:ui.Tail.Width=25*$character;$script:ui.Tail.Height=18*$character
    [Windows.Controls.Canvas]::SetLeft($script:ui.Tail,$girlLeft-34*$character)
    [Windows.Controls.Canvas]::SetTop($script:ui.Tail,$girlTop+40*$character)
    $script:ui.TailNear.Width=17*$character;$script:ui.TailNear.Height=12*$character
    [Windows.Controls.Canvas]::SetLeft($script:ui.TailNear,$girlLeft)
    [Windows.Controls.Canvas]::SetTop($script:ui.TailNear,$girlTop+72*$character)
    $script:ui.MenuButton.Width=24*$character;$script:ui.MenuButton.Height=24*$character
    if($script:ui.MenuButton.Content-is [Windows.Controls.Viewbox]){
      $script:ui.MenuButton.Content.Width=14*$character;$script:ui.MenuButton.Content.Height=14*$character
    }
    [Windows.Controls.Canvas]::SetLeft($script:ui.MenuButton,350-30*$character)
    [Windows.Controls.Canvas]::SetTop($script:ui.MenuButton,$girlTop+20*$character)
  }
  Sync-WidgetCharacterColors
  if($script:widgetMusic -and $script:widgetMusic.Enabled){$script:widgetMusic.CaptureBaseLayout()}
}
function Set-Appearance {
  $previousDisplayScale=$script:displayScale
  $actual=Get-WidgetLayoutScale
  if(!$script:followHost){
    $frame=Get-WidgetPlacementFrame;$dpi=Get-WidgetPlacementDpi
    if(Test-WidgetPlacementFrame $frame $dpi){$actual=[Math]::Min($actual,[Math]::Min(($frame.Right-$frame.Left)/$dpi/$script:designWidth,($frame.Bottom-$frame.Top)/$dpi/$script:designHeight))}
  }
  if($script:followHost -and $previousDisplayScale-gt 0 -and [Math]::Abs($actual-$previousDisplayScale)-gt 0.001){
    # Offsets that deliberately place the transparent window edge outside the
    # host were measured with the previous window size. Scale them with the
    # display size so a later resize keeps the character flush instead of
    # drifting by the transparent margin.
    $ratio=$actual/$previousDisplayScale
    if($script:offsetBottom-lt 0){$script:offsetBottom=[Math]::Round($script:offsetBottom*$ratio,3)}
    if($script:offsetRight-lt 0){$script:offsetRight=[Math]::Round($script:offsetRight*$ratio,3)}
    if($null-ne $script:offsetLeft -and $script:offsetLeft-lt 0){$script:offsetLeft=[Math]::Round($script:offsetLeft*$ratio,3)}
  }
  $script:displayScale=$actual
  # Transparent space around the original 350px pose contains press/rebound
  # overshoot without shrinking the character or exposing a rectangular cut.
  $null=Set-WidgetPixelSize (Get-WidgetPlacementDpi)
  Set-WidgetIndependentLayout
  # The Viewbox scales the completed pose, including the mirror origin and press motion.
  # Scaling and mirroring this same Canvas made its origin escape the native window.
  $script:ui.Root.LayoutTransform=[Windows.Media.Transform]::Identity
  Set-Facing
  $script:lastPosition=$null
  if($script:hostEventTimer -and !$script:hostEventTimer.IsEnabled){$script:hostEventTimer.Start()}
}
function Test-WidgetPlacementFrame($Frame,[double]$Dpi=1) {
  return $Frame -and $Dpi-gt 0 -and ($Frame.Right-$Frame.Left)-ge 64*$Dpi -and ($Frame.Bottom-$Frame.Top)-ge 64*$Dpi
}
function Limit-WidgetHorizontalPosition($Frame,[double]$Dpi,[double]$Left) {
  # Mirror-aware character bounds; transparent bubble space may extend outside.
  # Use the resting layout so press/rebound never changes the drag limits.
  $root=$script:ui.Root;$girl=$script:ui.Girl
  $rootOffset=[Windows.Media.VisualTreeHelper]::GetOffset($root)
  $girlOffset=[Windows.Media.VisualTreeHelper]::GetOffset($girl)
  $girlLeft=$girlOffset.X
  if($script:ui.FacingScale.ScaleX-lt 0){$girlLeft=$root.ActualWidth-$girlOffset.X-$girl.ActualWidth}
  $leftInStage=$rootOffset.X+$girlLeft
  $origin=$script:window.PointToScreen([Windows.Point]::new(0,0))
  $leftPoint=$root.Parent.PointToScreen([Windows.Point]::new($leftInStage,0))
  $rightPoint=$root.Parent.PointToScreen([Windows.Point]::new(($leftInStage+$girl.ActualWidth),0))
  $minimum=$Frame.Left-($leftPoint.X-$origin.X)
  $maximum=$Frame.Right-($rightPoint.X-$origin.X)
  if($maximum-lt $minimum){return [int][Math]::Round(($minimum+$maximum)/2)}
  return [int][Math]::Round([Math]::Max($minimum,[Math]::Min($maximum,$Left)))
}
function Limit-WidgetVerticalPosition($Frame,[double]$Dpi,[double]$Top) {
  # Keep the character inside the frame; the transparent space reserved for
  # its bubble may extend above it. Ignore transient press/rebound transforms.
  $root=$script:ui.Root;$girl=$script:ui.Girl
  $rootOffset=[Windows.Media.VisualTreeHelper]::GetOffset($root)
  $girlOffset=[Windows.Media.VisualTreeHelper]::GetOffset($girl)
  $left=$rootOffset.X+$girlOffset.X;$topInStage=$rootOffset.Y+$girlOffset.Y
  $origin=$script:window.PointToScreen([Windows.Point]::new(0,0))
  $topPoint=$root.Parent.PointToScreen([Windows.Point]::new($left,$topInStage))
  $bottomPoint=$root.Parent.PointToScreen([Windows.Point]::new($left,($topInStage+$girl.ActualHeight)))
  $minimum=$Frame.Top-($topPoint.Y-$origin.Y)
  $maximum=$Frame.Bottom-($bottomPoint.Y-$origin.Y)
  return [int][Math]::Round([Math]::Max($minimum,[Math]::Min($maximum,$Top)))
}
function Get-WidgetVisibleFrame {
  $frame=[GptWidgetNative]::Frame($script:hostHandle)
  $dpi=Get-WidgetPlacementDpi
  if(!(Test-WidgetPlacementFrame $frame $dpi)){return $frame}
  $width=$script:designWidth*$script:displayScale*$dpi;$height=$script:designHeight*$script:displayScale*$dpi
  $x=if($script:anchor-eq 'right'){$frame.Right-$width-$script:offsetRight*$dpi}else{$frame.Left+$script:offsetLeft*$dpi}
  $y=$frame.Bottom-$height-$script:offsetBottom*$dpi
  $bounds=[GptWidgetHostFollower]::VisibleBoundsAt($frame.Left,$frame.Top,$frame.Right,$frame.Bottom,[int]($x+$width/2),[int]($y+$height/2))
  $frame.Left=$bounds[0];$frame.Top=$bounds[1];$frame.Right=$bounds[2];$frame.Bottom=$bounds[3]
  return $frame
}
function Set-WidgetPixelSize([double]$dpi){
  # Only the immutable design canvas participates in physical size calculation.
  $pixels=$script:designWidth*$script:displayScale*$dpi
  $pixelHeight=$script:designHeight*$script:displayScale*$dpi
  $source=[Windows.PresentationSource]::FromVisual($script:window)
  $sx=1.0;$sy=1.0
  if($source -and $source.CompositionTarget){
    $matrix=$source.CompositionTarget.TransformToDevice;$sx=$matrix.M11;$sy=$matrix.M22
  }
  $width=$pixels/$sx;$height=$pixelHeight/$sy;$changed=$false
  if([Math]::Abs($script:window.Width-$width)-gt 0.01){$script:window.Width=$width;$changed=$true}
  if([Math]::Abs($script:window.Height-$height)-gt 0.01){$script:window.Height=$height;$changed=$true}
  if($changed){$script:window.UpdateLayout();Refresh-WidgetTextRaster}
  return [int][Math]::Round($pixels)
}
function Set-AnimatedValue($target,$property,[double]$value) {
  $target.BeginAnimation($property,$null);$target.SetValue($property,$value)
}
function Animate-Value($target,$property,[double]$to,[int]$duration,[int]$delay=0,[bool]$rebound=$false) {
  $from=[double]$target.GetValue($property)
  $target.BeginAnimation($property,$null);$target.SetValue($property,$from)
  $animation=New-Object Windows.Media.Animation.DoubleAnimation
  $animation.From=$from;$animation.To=$to
  $animation.Duration=[Windows.Duration]::new([TimeSpan]::FromMilliseconds($duration))
  $animation.BeginTime=[TimeSpan]::FromMilliseconds($delay)
  $ease=New-Object GptBezierEase
  if($rebound){$ease.X1=0.34;$ease.Y1=1.56;$ease.X2=0.64;$ease.Y2=1}
  $ease.EasingMode=[Windows.Media.Animation.EasingMode]::EaseIn;$animation.EasingFunction=$ease
  $target.BeginAnimation($property,$animation)
}
function Set-BubbleState {
  foreach($name in @('Bubble','Tail','TailNear')){
    $element=$script:ui[$name]
    $element.Visibility=if($script:collapsed -and !$script:settingsBubblePreview){[Windows.Visibility]::Hidden}else{[Windows.Visibility]::Visible}
    Set-AnimatedValue $element ([Windows.UIElement]::OpacityProperty) 1
    Set-AnimatedValue $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) 1
    Set-AnimatedValue $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) 1
  }
  Set-AnimatedValue $script:ui.SceneText ([Windows.UIElement]::OpacityProperty) 1
  $script:ui.Bubble.IsHitTestVisible=!$script:collapsed
}
$script:bubbleEpoch=0;$script:closeTimer=$null
function Restart-SceneTtl([int]$renderDelay=0,[long]$now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()){
  $script:sceneStartedAt=$now+$renderDelay;$script:sceneDeadline=$script:sceneStartedAt+5000
  Set-ResetTimeMode 'countdown' $now
  if($script:resetPhaseTimer){$script:resetPhaseTimer.Stop();$script:resetPhaseTimer=$null}
  if(!$script:collapsed -and $script:bubbleMode-eq 'quota'){
    $script:resetPhaseTimer=New-Object Windows.Threading.DispatcherTimer
    $script:resetPhaseTimer.Interval=[TimeSpan]::FromMilliseconds($renderDelay+2000)
    $script:resetPhaseTimer.Add_Tick({param($timer,$event)
      try{
        if($timer-ne $script:resetPhaseTimer){$timer.Stop();return}
        $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Tick-Scene $now
        if($script:collapsed -or $script:bubbleMode-ne 'quota'){$timer.Stop()}
        else{
          $next=if($script:resetTimeMode-eq 'fixed'){$script:sceneDeadline}else{$script:sceneStartedAt+2000}
          $timer.Interval=[TimeSpan]::FromMilliseconds([Math]::Max(1,$next-$now))
        }
      }catch{
        # A transient settings-write failure must not become an unhandled
        # dispatcher exception; stop this one-shot timer and keep the widget alive.
        $timer.Stop()
        try{[IO.File]::WriteAllText((Join-Path $script:dataDir 'display-error.txt'),$_.Exception.Message,[Text.UTF8Encoding]::new($false))}catch{}
      }
    })
    $script:resetPhaseTimer.Start()
  }
}
function Tick-Scene([long]$now){
  if($script:completionTemporary){return}
  if(!$script:collapsed -and $script:bubbleMode-eq 'completion' -and !(Test-CompletionDisplayAllowed ([bool]$script:window.IsVisible))){Pause-CompletionNotification;return}
  if($script:settingsSizePreview){return}
  if($script:collapsed -or $script:sceneDeadline-le 0){return}
  if($now-ge $script:sceneDeadline){Hide-Quota;return}
  if($script:bubbleMode-eq 'quota' -and $script:resetTimeMode-ne 'fixed' -and $now-ge $script:sceneStartedAt+2000){Set-ResetTimeMode 'fixed' $now}
}
function Read-DisplayRequest {
  try{
    $request=Get-Content -LiteralPath (Join-Path $script:dataDir 'display-request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($request.nonce -and $request.nonce-ne $script:displayRequestToken){
      Reset-WidgetAutoQuoteSchedule
      $script:displayRequestToken=$request.nonce
      if([Math]::Abs([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-[long]$request.at)-lt 10000){
        if($request.mode-eq 'quota'){Show-Quota}
        elseif($request.mode-eq 'quote'){Show-Quote}
        elseif($request.mode-eq 'completion'){
          Receive-CompletionMonitorLine ((@{type='completion';sessionId='widget-local-check';turnId=[string]$request.nonce;endedAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()}|ConvertTo-Json -Compress))
        }
        elseif($request.mode-eq 'menu' -and $script:window.IsVisible){Open-WidgetMenu}
        elseif($request.mode-eq 'characters' -and $script:window.IsVisible){Open-WidgetCharacterGallery}
        elseif($request.mode-eq 'close-menu'){$script:context.IsOpen=$false}
        elseif($request.mode-eq 'music-on'){Set-WidgetMusicEnabled $true}
        elseif($request.mode-eq 'music-off'){Set-WidgetMusicEnabled $false}
      }
    }
  }catch{}
}
function Apply-Scene {
  Set-WidgetSceneLayout
  if($script:widgetColors){Update-WidgetColorScene}
  $quota=$script:bubbleMode-eq 'quota'
  $script:ui.QuotaText.Visibility=if($quota){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
  $script:ui.QuoteText.Visibility=if($quota){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}
  $script:ui.Refresh.Visibility=$script:ui.QuotaText.Visibility;$script:ui.LiveDot.Visibility=[Windows.Visibility]::Collapsed
  Update-BubbleTooltip
}
function Update-BubbleTooltip {
  $copy=if($script:bubbleMode-in @('quote','completion')){$script:ui.QuoteText.Tag}else{
    $parts=@()
    if($script:status.planLabel){$parts+='当前套餐：'+$script:status.planLabel}
    foreach($row in (Get-QuotaRows)){
      if($script:ui[$row.prefix+'Row'].Visibility-ne [Windows.Visibility]::Collapsed){
        $reset=$script:ui[$row.prefix+'Reset']
        $detail=if($reset.ToolTip){[string]$reset.ToolTip}else{$reset.Text}
        $parts+="$($row.label)：$($script:ui[$row.prefix+'Used'].Text)，$detail"
        if($row.window.kind-eq 'individual'){
          $q=$row.window;$parts+='公司工作区内的个人限额（非公司总余额）'
          if($null-ne $q.total -and $null-ne $q.amountUsed){
            $parts+='额度上限 '+([double]$q.total).ToString('0.##')+' · 已用 '+([double]$q.amountUsed).ToString('0.##')+' · 剩余 '+([double]$q.amountRemaining).ToString('0.##')
          }
        }
      }
    }
    # If an individual cap coexists with both timed windows, the second row
    # shows the shortest timed window consistently; retain all others in the tooltip.
    $shown=@((Get-QuotaRows)|ForEach-Object{$_.window})
    foreach($q in @($script:status.windows|Where-Object{$null-ne $_ -and $_ -notin $shown})){
      $label=Get-QuotaWindowLabel $q ''
      $detail=if($q.resetsAt){Format-ResetTime ([long]$q.resetsAt) ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())}else{'未提供重置时间'}
      $parts+=$label+'：已用 '+([double]$q.used).ToString('0.#')+'%，'+$detail
    }
    ($parts+@($script:ui.Status.Text))-join "`n"
  }
  if(!$script:bubbleTooltipText){
    $script:bubbleTooltipText=New-Object Windows.Controls.TextBlock
    $script:bubbleTooltipText.TextWrapping=[Windows.TextWrapping]::Wrap
    $script:bubbleTooltipText.MaxWidth=320;$script:bubbleTooltipText.FontSize=15;$script:bubbleTooltipText.LineHeight=23
    $script:ui.Bubble.ToolTip=$script:bubbleTooltipText
    [Windows.Controls.ToolTipService]::SetShowDuration($script:ui.Bubble,20000)
  }
  $script:bubbleTooltipText.Text=[string]$copy
}

function Switch-Scene([string]$mode){
  if($script:collapsed){return}
  if($script:bubbleMode-eq 'completion' -and $mode-ne 'completion'){Dismiss-CompletionNotification}
  Reset-WidgetAutoQuoteSchedule
  $script:sceneRevision++;$script:bubbleMode=$mode
  if($mode-eq 'quote'){$script:ui.QuoteText.Text=Get-WidgetBubbleQuote $script:dataDir;Fit-QuoteText}
  if($script:sceneTimer){$script:sceneTimer.Stop()}
  Animate-Value $script:ui.SceneText ([Windows.UIElement]::OpacityProperty) 0 120
  $script:sceneTimer=New-Object Windows.Threading.DispatcherTimer
  $script:sceneTimer.Interval=[TimeSpan]::FromMilliseconds(120)
  $script:sceneTimer.Add_Tick({param($timer,$event)
    $timer.Stop()
    try{
      if($timer-eq $script:sceneTimer -and !$script:collapsed){
        Apply-Scene;Animate-Value $script:ui.SceneText ([Windows.UIElement]::OpacityProperty) 1 160
        Restart-SceneTtl 160
      }
    }catch{
      try{[IO.File]::WriteAllText((Join-Path $script:dataDir 'display-error.txt'),$_.Exception.Message,[Text.UTF8Encoding]::new($false))}catch{}
    }
  })
  $script:sceneTimer.Start();Restart-SceneTtl 280
}
function Next-Bubble {
  if($script:collapsed){return}
  if($script:bubbleMode-eq 'quota'){Switch-Scene 'quote'}else{Hide-Quota}
}
function Click-Character {
  if($script:collapsed){Show-Quota}
  elseif($script:bubbleTapAdvance){Next-Bubble}
  elseif($script:bubbleMode-ne 'quota'){Switch-Scene 'quota'}
  else{Restart-SceneTtl}
}
function Test-WidgetCompletionForeground {
  if(!$script:followHost){return $true}
  return Test-WidgetCompletionHostForeground
}
function Test-WidgetCompletionHostForeground {
  if($script:hostHandle-eq [IntPtr]::Zero){return $false}
  $foreground=[GptWidgetNative]::GetAncestor([GptWidgetNative]::GetForegroundWindow(),2)
  return $foreground-eq $script:hostHandle
}
function Tick-WidgetAutoQuote([long]$Now,[bool]$Visible) {
  $busy=($script:completionNotificationsEnabled -and $script:completionPending) -or !$script:collapsed -or [bool]$script:drag -or $script:context.IsOpen -or $script:settingsSizePreview -or ($script:closeTimer -and $script:closeTimer.IsEnabled) -or (Test-WidgetUpdateEditor)
  if(Test-WidgetAutoQuoteDue $Now $Visible ([bool]$busy)){Show-Quote;$script:autoQuoteDisplayCount++}
}
function Show-Quota {
  $wasCollapsed=$script:collapsed
  Open-WidgetBubble 'quota'
  if($wasCollapsed){Request-Refresh}
}
function Show-Quote {Open-WidgetBubble 'quote'}
function Open-WidgetBubble([ValidateSet('quota','quote','completion')][string]$Mode) {
  Reset-WidgetAutoQuoteSchedule
  if(!$script:collapsed){if($Mode-eq 'quote' -or $script:bubbleMode-ne $Mode){Switch-Scene $Mode}else{Restart-SceneTtl};return}
  $script:bubbleEpoch++;$script:collapsed=$false;$script:sceneRevision++
  $script:bubbleMode=$Mode
  if($Mode-eq 'quote'){$script:ui.QuoteText.Text=Get-WidgetBubbleQuote $script:dataDir;Fit-QuoteText}
  if($Mode-eq 'completion'){$script:ui.QuoteText.Text="Codex`n有回复已结束";Fit-QuoteText}
  Apply-Scene
  if($script:sceneTimer){$script:sceneTimer.Stop()}
  if($script:closeTimer){$script:closeTimer.Stop();$script:closeTimer=$null}
  foreach($stage in @(@{name='TailNear';delay=0},@{name='Tail';delay=130},@{name='Bubble';delay=260})){
    $element=$script:ui[$stage.name];$element.Visibility=[Windows.Visibility]::Visible
    Set-AnimatedValue $element ([Windows.UIElement]::OpacityProperty) 0
    Set-AnimatedValue $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) 0.7
    Set-AnimatedValue $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) 0.7
    Animate-Value $element ([Windows.UIElement]::OpacityProperty) 1 200 $stage.delay
    Animate-Value $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) 1 200 $stage.delay
    Animate-Value $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) 1 200 $stage.delay
  }
  Set-AnimatedValue $script:ui.SceneText ([Windows.UIElement]::OpacityProperty) 0
  Animate-Value $script:ui.SceneText ([Windows.UIElement]::OpacityProperty) 1 160 360
  $script:ui.Bubble.IsHitTestVisible=$true
  Restart-SceneTtl 520;Save-Settings
}
function Hide-Quota([switch]$KeepCompletion) {
  if($script:collapsed){return}
  if($script:bubbleMode-eq 'completion' -and !$KeepCompletion){Dismiss-CompletionNotification}
  Reset-WidgetAutoQuoteSchedule
  $script:collapsed=$true;$script:bubbleEpoch++
  if($script:widgetColors){Update-WidgetColorScene}
  $script:sceneDeadline=0
  if($script:resetPhaseTimer){$script:resetPhaseTimer.Stop();$script:resetPhaseTimer=$null}
  if($script:sceneTimer){$script:sceneTimer.Stop()}
  $script:ui.Bubble.IsHitTestVisible=$false
  Animate-Value $script:ui.SceneText ([Windows.UIElement]::OpacityProperty) 0 160
  foreach($stage in @(@{name='Bubble';delay=100},@{name='Tail';delay=200},@{name='TailNear';delay=300})){
    $element=$script:ui[$stage.name]
    Animate-Value $element ([Windows.UIElement]::OpacityProperty) 0 180 $stage.delay
    Animate-Value $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) 0.7 180 $stage.delay
    Animate-Value $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) 0.7 180 $stage.delay
  }
  if($script:closeTimer){$script:closeTimer.Stop()}
  $script:closeTimer=New-Object Windows.Threading.DispatcherTimer
  $script:closeTimer.Interval=[TimeSpan]::FromMilliseconds(510)
  $script:closeTimer.Add_Tick({param($timer,$event)
    $timer.Stop()
    if($script:collapsed -and $timer-eq $script:closeTimer){Set-BubbleState}
  })
  $script:closeTimer.Start();Save-Settings
}
function Animate-Press([bool]$down) {
  $x=if($down){1.05}else{1.0};$y=if($down){0.88}else{1.0}
  Animate-Value $script:ui.PressScale ([Windows.Media.ScaleTransform]::ScaleXProperty) $x 220 0 $true
  Animate-Value $script:ui.PressScale ([Windows.Media.ScaleTransform]::ScaleYProperty) $y 220 0 $true
}
function Request-Refresh {[IO.File]::WriteAllText((Join-Path $script:dataDir 'refresh.flag'),([DateTime]::UtcNow.ToString('o')+' '+[Guid]::NewGuid().ToString('N')))}
function Exit-WidgetForSession {
  if($script:followHost){Set-WidgetSupervisorPause -AppDir $script:appDir -HostHandle $script:hostHandle.ToInt64() -HostPid ([GptWidgetNative]::ProcessId($script:hostHandle))}
  else{Write-WidgetSupervisorJson (Join-Path $script:dataDir 'supervisor-pause.json') @{desktop=$true;at=[DateTime]::UtcNow.ToString('o')}}
  $script:window.Close()
}
function Set-MenuVisible([bool]$show){
  $show=$show -and !$script:hideMenu
  $script:ui.MenuButton.Opacity=if($show){1}else{0};$script:ui.MenuButton.IsHitTestVisible=$show
}
function Test-GirlAlpha([Windows.Point]$rootPoint){
  $point=$script:ui.Root.TranslatePoint($rootPoint,$script:ui.Girl)
  $fit=[Math]::Min($script:ui.Girl.ActualWidth/$script:bitmap.PixelWidth,$script:ui.Girl.ActualHeight/$script:bitmap.PixelHeight)
  if($fit-le 0){return $false}
  $x=[int][Math]::Floor(($point.X-($script:ui.Girl.ActualWidth-$script:bitmap.PixelWidth*$fit)/2)/$fit)
  $y=[int][Math]::Floor(($point.Y-($script:ui.Girl.ActualHeight-$script:bitmap.PixelHeight*$fit)/2)/$fit)
  if($x-lt 0 -or $y-lt 0 -or $x-ge $script:bitmap.PixelWidth -or $y-ge $script:bitmap.PixelHeight){return $false}
  return $script:alphaPixels[$y*$script:alphaStride+$x*4+3]-gt 10
}
function Test-WidgetHit([Windows.Point]$rootPoint){
  $hit=$script:ui.Root.InputHitTest($rootPoint)
  if(!$hit){return $false}
  if($hit-eq $script:ui.Girl){return Test-GirlAlpha $rootPoint}
  return $true
}
function Reset-Label($seconds){
  if($seconds-le 0){return '重置已到 · 等待刷新'}
  $minutes=[Math]::Ceiling($seconds/60)
  if($minutes-lt 60){return "$minutes 分钟后重置"}
  if($minutes-lt 1440){$h=[Math]::Floor($minutes/60);$m=$minutes%60;if($m-eq 0){return "$h 小时后重置"};return "$h 小时 $m 分后重置"}
  $d=[Math]::Floor($minutes/1440);$h=[Math]::Floor(($minutes%1440)/60);if($h-eq 0){return "$d 天后重置"};return "$d 天 $h 小时后重置"
}
function Format-ResetTime([long]$timestamp,[long]$now,[TimeZoneInfo]$timeZone=[TimeZoneInfo]::Local){
  if($timestamp-le $now){return '重置已到，等待更新'}
  $reset=[TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeSeconds($timestamp),$timeZone)
  $today=[TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeSeconds($now),$timeZone).Date
  $day=if($reset.Date-eq $today){'今日'}elseif($reset.Date-eq $today.AddDays(1)){'明日'}else{$reset.ToString('MM-dd')}
  return $day+' '+$reset.ToString('HH:mm')+' 重置'
}
function Format-ResetDisplay([long]$timestamp,[long]$now){
  $label=if($timestamp-le $now -or $script:resetTimeMode-eq 'fixed'){Format-ResetTime $timestamp $now}else{Reset-Label ($timestamp-$now)}
  return ($label -replace '小时','时' -replace '分钟','分' -replace '重置已到，等待更新','等待刷新')
}
function Set-QuotaResetText([string]$Prefix,[string]$Label,[string]$Value) {
  $element=$script:ui[$Prefix+'Reset']
  $quota=(Get-QuotaRows|Where-Object{$_.prefix-eq $Prefix}|Select-Object -First 1).window
  $element.ToolTip=if($quota -and $quota.resetsAt){$Label+' · '+$Value}else{$null}
  $isCountdown=$script:resetTimeMode-eq 'countdown' -and $Value-match '后重置$'
  if($isCountdown){$compact=($Value-replace '\s+','')-replace '重置$',''}
  elseif($quota -and $quota.resetsAt -and [double]$quota.resetsAt-gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()){
    $reset=[DateTimeOffset]::FromUnixTimeSeconds([long]$quota.resetsAt).ToLocalTime()
    $dateOnly=$quota.minutes-ge 1440 -or ($quota.kind-eq 'individual' -and $reset.Date-ne [DateTimeOffset]::Now.Date)
    $compact=if($dateOnly){$reset.ToString('MM/dd')+' 重置'}else{$reset.ToString('HH:mm')+' 重置'}
  }else{
    $compact=switch($Value){
      '未提供重置时间' {'无重置时间'}
      '额度读取异常' {'读取异常'}
      '暂无额度数据' {'暂无数据'}
      default {$Value-replace '\s+',' '}
    }
  }
  $baseSize=13.1
  $element.Text=$compact;$element.FontSize=$baseSize;$element.LineHeight=[double]::NaN
  $element.TextAlignment=[Windows.TextAlignment]::Right
  $face=[Windows.Media.Typeface]::new($element.FontFamily,$element.FontStyle,$element.FontWeight,$element.FontStretch)
  $measure=[Windows.Media.FormattedText]::new($compact,[Globalization.CultureInfo]::CurrentCulture,[Windows.FlowDirection]::LeftToRight,$face,$baseSize,$element.Foreground)
  if($measure.Width-gt 67){$element.FontSize=$baseSize*67/$measure.Width}
  $measure=[Windows.Media.FormattedText]::new($compact,[Globalization.CultureInfo]::CurrentCulture,[Windows.FlowDirection]::LeftToRight,$face,$element.FontSize,$element.Foreground)
  $bounds=$measure.BuildGeometry([Windows.Point]::new(0,0)).Bounds
  $number=$script:ui[$Prefix+'Left']
  $numberFace=[Windows.Media.Typeface]::new($number.FontFamily,$number.FontStyle,$number.FontWeight,$number.FontStretch)
  $numberMeasure=[Windows.Media.FormattedText]::new($number.Text,[Globalization.CultureInfo]::CurrentCulture,[Windows.FlowDirection]::LeftToRight,$numberFace,$number.FontSize,$number.Foreground)
  $numberBounds=$numberMeasure.BuildGeometry([Windows.Point]::new(0,0)).Bounds
  $centre=[Windows.Controls.Canvas]::GetTop($number)+$numberBounds.Top+$numberBounds.Height/2
  [Windows.Controls.Canvas]::SetTop($element,$centre-$bounds.Top-$bounds.Height/2)
}
function Get-QuotaWindowLabel($Window,[string]$Fallback){
  if(!$Window){return $Fallback}
  if($Window.kind-eq 'individual'){return '个人额度'}
  $minutes=[long]$Window.minutes
  if($minutes-eq 300){return '5小时'}
  if($minutes-eq 10080){return '1周'}
  if($minutes%1440-eq 0){return ([string]($minutes/1440))+' 天'}
  if($minutes%60-eq 0){return ([string]($minutes/60))+' 小时'}
  return ([string]$minutes)+' 分钟'
}
function Get-QuotaRows {
  # Reuse two visual rows and keep the original timed-window placement.
  $windows=@($script:status.windows|Where-Object{$null-ne $_}|Sort-Object minutes)
  # Select-Object -First 1 repeatedly adds type names to cached objects in Windows PowerShell 5.1.
  # Index filtered arrays instead to keep recurring refreshes from growing the type cache.
  $individual=@($windows|Where-Object{$_.kind-eq 'individual'})[0]
  if($individual){
    $timed=@($windows|Where-Object{$_.kind-ne 'individual'}|Sort-Object minutes)[0]
    return @(@{prefix='Short';window=$individual;label='个人额度'},@{prefix='Week';window=$timed;label=(Get-QuotaWindowLabel $timed '其他额度')})
  }
  $short=@($windows|Where-Object{$_.minutes-eq 300})[0]
  $week=@($windows|Where-Object{$_.minutes-eq 10080})[0]
  $other=@($windows|Where-Object{$_.minutes-notin @(300,10080)})
  $next=0
  if(!$short -and $next-lt $other.Count){$short=$other[$next];$next++}
  if(!$week -and $next-lt $other.Count){$week=$other[$next]}
  @(@{prefix='Short';window=$short;label=(Get-QuotaWindowLabel $short '5小时')},@{prefix='Week';window=$week;label=(Get-QuotaWindowLabel $week '1周')})
}
function Set-ResetTimeMode([string]$mode,[long]$nowMilliseconds){
  $script:resetTimeMode=$mode
  $now=[long][Math]::Floor($nowMilliseconds/1000)
  foreach($row in (Get-QuotaRows)){
    $q=$row.window
    if($q -and $null-ne $q.resetsAt -and [double]$q.resetsAt-gt 0){Set-QuotaResetText $row.prefix $row.label (Format-ResetDisplay ([long]$q.resetsAt) $now)}
  }
}
function Update-Quota {
  $file=Join-Path $script:dataDir 'status.json'
  try{$stamp=[IO.File]::GetLastWriteTimeUtc($file).Ticks
    if(!(Test-Path -LiteralPath $file)){$script:status=$null;$script:statusStamp=0}
    elseif($stamp-ne $script:statusStamp){$script:status=Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json;$script:statusStamp=$stamp}
  }catch{$script:status=$null;$script:statusStamp=0}
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  foreach($row in (Get-QuotaRows)){
    $prefix=$row.prefix;$q=$row.window
    $script:ui[$prefix+'Label'].Text=$row.label
    $script:ui[$prefix+'Row'].Visibility=if(!$q -and $script:status.queryOk-eq $true){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}
    $script:ui[$prefix+'Reset'].Visibility=$script:ui[$prefix+'Row'].Visibility
    $script:ui[$prefix+'Reset'].ToolTip=$null
    if(!$q){
      $script:ui[$prefix+'Used'].Text='已用 —';$script:ui[$prefix+'Left'].Text='—'
      $message=if($script:status -and $script:status.queryOk-ne $true){'额度读取异常'}else{'暂无额度数据'}
      Set-QuotaResetText $prefix $row.label $message
      $script:ui[$prefix+'Bar'].Width=0;$script:ui[$prefix+'Left'].Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#95889F');continue
    }
    $hasReset=$null-ne $q.resetsAt -and [double]$q.resetsAt-gt 0
    $expired=$hasReset -and [double]$q.resetsAt-le $now
    $used=([double]$q.used).ToString('0.#');$left=([double]$q.remaining).ToString('0.#')
    $script:ui[$prefix+'Used'].Text=if($expired){"上次 $used%"}else{"已用 $used%"}
    $script:ui[$prefix+'Left'].Text=if($expired){'—'}else{"$left%"}
    foreach($fit in @(@('Label',15,52),@('Left',25,64))){
      $element=$script:ui[$prefix+$fit[0]];$size=[double]$fit[1];$width=[double]$fit[2]
      $face=[Windows.Media.Typeface]::new($element.FontFamily,$element.FontStyle,$element.FontWeight,$element.FontStretch)
      $measure=[Windows.Media.FormattedText]::new($element.Text,[Globalization.CultureInfo]::CurrentCulture,[Windows.FlowDirection]::LeftToRight,$face,$size,$element.Foreground)
      $element.FontSize=if($measure.Width-gt $width){$size*$width/$measure.Width}else{$size}
    }
    $resetText=if($hasReset){Format-ResetDisplay ([long]$q.resetsAt) $now}else{'未提供重置时间'}
    Set-QuotaResetText $prefix $row.label $resetText
    if($hasReset){$script:ui[$prefix+'Reset'].ToolTip='本机时间 '+[DateTimeOffset]::FromUnixTimeSeconds([long]$q.resetsAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm zzz')+' 重置 · '+(Reset-Label ([double]$q.resetsAt-$now))}
    $script:ui[$prefix+'Bar'].Width=if($expired){0}else{188*[Math]::Max(0,[Math]::Min(100,[double]$q.remaining))/100}
    $color=if($expired){'#B3A7C0'}elseif([double]$q.used-ge 90){'#D77659'}elseif([double]$q.used-ge 75){'#D0A051'}else{'#9B86C1'}
    $script:ui[$prefix+'Bar'].Background=[Windows.Media.BrushConverter]::new().ConvertFromString($color)
    $valueColor=if($expired){'#95889F'}elseif([double]$q.used-ge 90){'#B74839'}elseif([double]$q.used-ge 75){'#A06C1C'}else{'#745A98'}
    $script:ui[$prefix+'Left'].Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($valueColor)
  }
  if($script:bubbleMode-eq 'quota'){Set-WidgetSceneLayout}
  $age=if($script:status.observedAt){$now-[Math]::Floor([double]$script:status.observedAt/1000)}else{0}
  $dot='#9B86C1'
  if(!$script:status){$script:ui.Status.Text='正在读取订阅额度…';$dot='#C5A96F'}
  elseif(!$script:status.ok){$script:ui.Status.Text=$script:status.error;$dot='#C5A96F'}
  else{
    $at=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$script:status.observedAt).ToLocalTime().ToString('HH:mm:ss')
    if($script:status.error){$script:ui.Status.Text="刷新未成功 · 上次 $at";$dot='#C5A96F'}
    elseif($age-gt 180){$mins=[Math]::Floor($age/60);$script:ui.Status.Text="$mins 分钟前的额度 · 点击 ↻ 刷新";$dot='#C5A96F'}
    else{$script:ui.Status.Text="$at 更新 · 实时订阅额度"}
  }
  $script:ui.LiveDot.Fill=[Windows.Media.BrushConverter]::new().ConvertFromString($dot)
  $script:ui.Status.ToolTip=$script:ui.Status.Text
  $headerState=if(!$script:status){'正在读取'}elseif(!$script:status.ok){'暂无法读取'}elseif($script:status.error -or $age-gt 180){'上次剩余额度'}else{'剩余额度'}
  $planTitle=([string]$script:status.planLabel).Trim()
  $script:ui.Header.Text=$headerState
  $header=$script:ui.Header;$header.FontSize=17
  $headerFace=[Windows.Media.Typeface]::new($header.FontFamily,$header.FontStyle,$header.FontWeight,$header.FontStretch)
  $headerMeasure=[Windows.Media.FormattedText]::new($header.Text,[Globalization.CultureInfo]::CurrentCulture,[Windows.FlowDirection]::LeftToRight,$headerFace,17,$header.Foreground)
  if($headerMeasure.Width-gt 94){$header.FontSize=17*94/$headerMeasure.Width}
  $headerMeasure=[Windows.Media.FormattedText]::new($header.Text,[Globalization.CultureInfo]::CurrentCulture,[Windows.FlowDirection]::LeftToRight,$headerFace,$header.FontSize,$header.Foreground)
  $headerBounds=$headerMeasure.BuildGeometry([Windows.Point]::new(0,0)).Bounds
  $headerCenter=[Windows.Controls.Canvas]::GetTop($script:ui.Refresh)+$script:ui.Refresh.Height/2
  [Windows.Controls.Canvas]::SetTop($header,$headerCenter-$headerBounds.Top-$headerBounds.Height/2)
  $script:ui.Header.ToolTip=if($script:status.planLabel){'当前套餐：'+$script:status.planLabel+' · 重置时间按本机时间显示'}else{'重置时间按本机时间显示'}
  Update-BubbleTooltip
  if($script:widgetColors){Update-WidgetColorScene}
}
Set-Appearance;Set-BubbleState;Initialize-WidgetColors;Update-Quota
$script:window.Add_SizeChanged({Refresh-WidgetTextRaster})
if($CheckOnly){$hostWindow=[GptWidgetNative]::FindCodex();$foregroundWindow=[GptWidgetNative]::GetAncestor([GptWidgetNative]::GetForegroundWindow(),2);@{ok=$true;imageLoaded=$script:bitmap.PixelWidth-gt 0;characterId=$script:characterId;characterName=$script:activeCharacter.name;soundVolume=$script:soundVolume;sizing=@{character=$script:scale;bubble=$script:bubbleScale;display=$script:displayScale};autoQuotes=@{enabled=$script:autoQuoteEnabled;intervalSeconds=$script:autoQuoteIntervalSeconds};completion=(Get-CompletionNotificationStatus);placement=@{right=$script:offsetRight;left=$script:offsetLeft;bottom=$script:offsetBottom};host=$hostWindow.ToInt64();hostTitle=[GptWidgetNative]::Title($hostWindow);foreground=$foregroundWindow.ToInt64();foregroundTitle=[GptWidgetNative]::Title($foregroundWindow);dataDir=$script:dataDir}|ConvertTo-Json;return}
if($Preview){
  $script:collapsed=$false;Set-Appearance;Set-BubbleState;Apply-Scene
  $script:ui.Root.LayoutTransform=[Windows.Media.Transform]::Identity
  $root=$script:window.FindName('AnimationStage');$root.Measure([Windows.Size]::new($script:designWidth,$script:designHeight));$root.Arrange([Windows.Rect]::new(0,0,$script:designWidth,$script:designHeight));$root.UpdateLayout()
  $render=New-Object Windows.Media.Imaging.RenderTargetBitmap($script:designWidth,$script:designHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
  $render.Render($root);$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
  $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
  $stream=[IO.File]::Create((Join-Path $script:appDir 'preview.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()};return
}
$mutexKey='Local\GPTNiangUsage_'+([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:appDir))).Replace('/','_').Replace('+','-')
$script:mutex=[Threading.Mutex]::new($false,$mutexKey);$script:mutexOwned=$false
try{$script:mutexOwned=$script:mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$script:mutexOwned=$true}
if(!$script:mutexOwned){Request-Refresh;$script:mutex.Dispose();return}
Initialize-WidgetAudio -AppDir $script:appDir -DataDir $script:dataDir
# A stop request written while this GUI was still starting must win. Only a
# recent flag is honoured (stale leftovers are removed); the flag is removed
# after honoring so a later manual start is not blocked.
$stopFlag=Join-Path $script:dataDir 'stop.flag'
if([IO.File]::Exists($stopFlag)){
  $stopAge=([DateTime]::UtcNow-[IO.File]::GetLastWriteTimeUtc($stopFlag)).TotalSeconds
  if($stopAge-ge 0 -and $stopAge-lt 30){
    Remove-Item -LiteralPath $stopFlag -ErrorAction SilentlyContinue
    $script:mutex.Dispose();return
  }
}
Remove-Item -LiteralPath $stopFlag -ErrorAction SilentlyContinue
$script:worker=$null
$script:lastWorkerProbe=0;$script:lastWorkerStart=0;$script:runtimeClosed=$false
$script:hostHandle=[GptWidgetNative]::FindCodex();$script:lastPresence=0;$script:lastHostProbe=0;$script:drag=$null
$script:lastForeground=[IntPtr](-1);$script:foregroundHost=[IntPtr]::Zero;$script:foregroundOwn=$false
$script:lastPosition=$null;$script:attachedHost=[IntPtr]::Zero;$script:updating=$false
$interop=New-Object Windows.Interop.WindowInteropHelper($script:window)
$script:widgetHandle=$interop.EnsureHandle()
$script:occlusionRecovery=[GptWidgetOcclusionRecovery]::new($script:widgetHandle)
$script:hostFollower=[GptWidgetHostFollower]::new($script:widgetHandle)
$script:hostFollower.LayoutRequested=[Action]{if(!$script:hostEventTimer.IsEnabled){$script:hostEventTimer.Start()}}
$ex=[GptWidgetNative]::GetWindowLongPtr($script:widgetHandle,-20).ToInt64()
[GptWidgetNative]::SetWindowLongPtr($script:widgetHandle,-20,[IntPtr]($ex-bor 0x08000000-bor 0x80))|Out-Null
$source=[Windows.Interop.HwndSource]::FromHwnd($script:widgetHandle)
$script:messageHook=[Windows.Interop.HwndSourceHook]{param($hwnd,$msg,$w,$l,[ref]$handled)
  if($msg-eq 0x47){$script:occlusionRecovery.OnPositionChanged($l)}
  if($msg-eq 0x02E0 -or $msg-eq 0x007E -or $msg-eq 0x001A){
    $script:lastPosition=$null
    if($script:hostEventTimer -and !$script:hostEventTimer.IsEnabled){$script:hostEventTimer.Start()}
  }
  if($msg-eq 0x84 -and !$script:drag){
    $packed=$l.ToInt64();$x=[int]($packed-band 65535);$y=[int](($packed-shr 16)-band 65535)
    if($x-ge 32768){$x-=65536};if($y-ge 32768){$y-=65536}
    $point=$script:ui.Root.PointFromScreen([Windows.Point]::new($x,$y))
    if(!(Test-WidgetHit $point)){$handled.Value=$true;return [IntPtr](-1)}
  }
  if($msg-eq 0x21){$handled.Value=$true;return [IntPtr]3};return [IntPtr]::Zero
}
$source.AddHook($script:messageHook)
Initialize-WidgetUpdater
Initialize-WidgetSettingsMenu
$script:ui.Refresh.Add_Click({param($sender,$event)Request-Refresh;Restart-SceneTtl;$script:ui.Status.Text='正在刷新额度…';$event.Handled=$true})
$script:ui.MenuButton.Add_Click({Open-WidgetMenu})
$script:menuTimer=New-Object Windows.Threading.DispatcherTimer
$script:menuTimer.Interval=[TimeSpan]::FromMilliseconds(180)
$script:menuTimer.Add_Tick({
  $script:menuTimer.Stop()
  if(!$script:ui.Girl.IsMouseOver -and !$script:ui.MenuButton.IsMouseOver -and !$script:context.IsOpen){Set-MenuVisible $false}
})
foreach($control in @($script:ui.Girl,$script:ui.MenuButton)){
  $control.Add_MouseEnter({$script:menuTimer.Stop();Set-MenuVisible $true})
  $control.Add_MouseLeave({$script:menuTimer.Start()})
}
$script:context.Add_Closed({$script:menuTimer.Start()})
foreach($control in @($script:ui.Bubble,$script:ui.Tail,$script:ui.TailNear)){$control.Add_MouseLeftButtonUp({param($sender,$event)Next-Bubble;$event.Handled=$true})}
$pressDown={param($sender,$event)
  Pause-CompletionNotification
  Reset-WidgetAutoQuoteSchedule
  $cursor=New-Object GptWidgetNative+Point;[GptWidgetNative]::GetCursorPos([ref]$cursor)|Out-Null
  $rect=New-Object GptWidgetNative+Rect;[GptWidgetNative]::GetWindowRect($script:widgetHandle,[ref]$rect)|Out-Null
  if(Test-WidgetMusicActive){
    Hide-Quota
    $script:drag=@{music=$true;control=$sender;moved=$false}
    Set-WidgetMusicPickupColor
    $script:widgetMusic.BeginHold($cursor.X,$cursor.Y)
    $sender.CaptureMouse()|Out-Null;Play-WidgetPressSound;$event.Handled=$true;return
  }
  $script:hostFollower.Suspend()
  $script:drag=@{x=$cursor.X;y=$cursor.Y;left=$rect.Left;top=$rect.Top;moved=$false;control=$sender}
  $sender.CaptureMouse()|Out-Null;Animate-Press $true;Play-WidgetPressSound;$event.Handled=$true
}
$pressMove={param($sender,$event)
  if(!$script:drag){return}
  if($script:drag.music){$event.Handled=$true;return}
  $cursor=New-Object GptWidgetNative+Point;[GptWidgetNative]::GetCursorPos([ref]$cursor)|Out-Null
  $dx=$cursor.X-$script:drag.x;$dy=$cursor.Y-$script:drag.y
  if($dx*$dx+$dy*$dy-lt 9 -and !$script:drag.moved){return}
  if(Test-WidgetMusicActive){
    Stop-WidgetMusic -KeepPosition
    $musicRect=New-Object GptWidgetNative+Rect;[GptWidgetNative]::GetWindowRect($script:widgetHandle,[ref]$musicRect)|Out-Null
    $script:drag.left=$musicRect.Left;$script:drag.top=$musicRect.Top
  }
  $script:drag.moved=$true
  if($script:followHost -and $script:hostHandle-eq [IntPtr]::Zero){return}
  if(!$script:followHost){$script:desktopLeft=$script:drag.left+$dx;$script:desktopTop=$script:drag.top+$dy}
  $frame=Get-WidgetPlacementFrame;$dpi=Get-WidgetPlacementDpi
  if($dpi-le 0){$dpi=1}
  if(!(Test-WidgetPlacementFrame $frame $dpi)){return}
  $null=Set-WidgetPixelSize $dpi
  $w=[int]($script:designWidth*$script:displayScale*$dpi);$h=[int]($script:designHeight*$script:displayScale*$dpi)
  $x=[int]($script:drag.left+$dx)
  $y=Limit-WidgetVerticalPosition $frame $dpi ($script:drag.top+$dy)
  $nextSide=if($cursor.X-lt ($frame.Left+$frame.Right)/2){'left'}else{'right'}
  if($nextSide-ne $script:side){
    $before=$null
    if($script:ui.Girl){$center=[Windows.Point]::new($script:ui.Girl.ActualWidth/2,$script:ui.Girl.ActualHeight/2);$before=$script:ui.Girl.PointToScreen($center)}
    $script:side=$nextSide;Set-Facing
    if($before){
      # Mirroring the whole canvas must not teleport the character. Rebase
      # this drag as well, so the next mouse move keeps the same grab offset.
      $after=$script:ui.Girl.PointToScreen($center);$shift=[int][Math]::Round($before.X-$after.X)
      $x+=$shift;$script:drag.left+=$shift
    }
  }
  $x=Limit-WidgetHorizontalPosition $frame $dpi $x
  [GptWidgetNative]::SetWindowPos($script:widgetHandle,[IntPtr]::Zero,$x,$y,0,0,0x15)|Out-Null
  $script:lastPosition=$null
  if($script:followHost){
    $script:offsetRight=($frame.Right-$x-$w)/$dpi;$script:offsetBottom=($frame.Bottom-$y-$h)/$dpi
    $script:offsetLeft=($x-$frame.Left)/$dpi;$script:anchor='free'
  }else{$script:desktopLeft=$x;$script:desktopTop=$y}
}
$pressUp={param($sender,$event)
  if(!$script:drag){return}
  Reset-WidgetAutoQuoteSchedule
  if($script:drag.music){
    $script:drag=$null
    $sender.ReleaseMouseCapture()
    if(Test-WidgetMusicActive){$script:widgetMusic.EndHold()}
    Play-WidgetReleaseSound
    $script:hostEventTimer.Start();$event.Handled=$true;return
  }
  $moved=$script:drag.moved;$script:drag=$null;$sender.ReleaseMouseCapture()
  Animate-Press $false
  Play-WidgetReleaseSound
  if(!$moved){Click-Character}
  elseif($script:followHost -and $script:side-eq 'left' -and $script:offsetLeft-ge 0 -and $script:offsetLeft-le 18){$script:anchor='left';$script:offsetLeft=0;$script:side='left';Set-Facing}
  elseif($script:followHost -and $script:side-eq 'right' -and $script:offsetRight-ge 0 -and $script:offsetRight-le 18){$script:anchor='right';$script:offsetRight=0;$script:side='right';Set-Facing}
  Save-Settings;$script:hostEventTimer.Start();$event.Handled=$true
}
$script:ui.Girl.Add_MouseLeftButtonDown($pressDown);$script:ui.Girl.Add_MouseMove($pressMove);$script:ui.Girl.Add_MouseLeftButtonUp($pressUp)
$script:ui.Girl.Add_LostMouseCapture({
  if($script:drag -and $script:drag.music){
    Reset-WidgetAutoQuoteSchedule;$script:drag=$null
    if(Test-WidgetMusicActive){$script:widgetMusic.EndHold()}
    Stop-WidgetAudio;$script:hostEventTimer.Start();return
  }
  if($script:drag){Reset-WidgetAutoQuoteSchedule;$script:drag=$null;Animate-Press $false;Stop-WidgetAudio;Save-Settings;$script:hostEventTimer.Start()}
})
function Ensure-QuotaWorker([long]$now){
  $updateFlag=Join-Path $script:dataDir 'update-installing.json'
  if(Test-Path -LiteralPath $updateFlag){
    $update=Read-WidgetUpdateJson $updateFlag
    $installer=if($update.pid){Get-Process -Id ([int]$update.pid) -ErrorAction SilentlyContinue}else{$null}
    try{if($installer -and (!$update.startedAt -or $installer.StartTime.ToUniversalTime()-eq ([DateTime]$update.startedAt).ToUniversalTime())){return}}
    finally{if($installer){$installer.Dispose()}}
    Remove-Item -LiteralPath $updateFlag
  }
  if($now-$script:lastWorkerProbe-lt 5000){return}
  $script:lastWorkerProbe=$now
  $healthy=$false
  try{
    $health=Get-Content -LiteralPath (Join-Path $script:dataDir 'worker-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $owner=Get-Content -LiteralPath (Join-Path $script:dataDir 'worker.lock') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($health.token -and $health.token-eq $owner.token -and $health.pid-eq $owner.pid -and $now-[long]$health.at-ge 0 -and $now-[long]$health.at-lt 5000){
      $workerProcess=Get-Process -Id ([int]$health.pid) -ErrorAction Stop
      try{$healthy=$workerProcess.Path-eq $script:config.nodePath -and $workerProcess.StartTime.ToUniversalTime()-le [DateTimeOffset]::FromUnixTimeMilliseconds([long]$health.startedAt).UtcDateTime}
      finally{$workerProcess.Dispose()}
      if($healthy -and $health.parentPid){$parentProcess=Get-Process -Id ([int]$health.parentPid) -ErrorAction Stop;$parentProcess.Dispose()}
    }
  }catch{$healthy=$false}
  if($healthy){return}
  if($script:worker){
    try{
      if(!$script:worker.HasExited){
        if($now-$script:lastWorkerStart-lt 10000){return}
        $script:worker.Kill()
        if(!$script:worker.WaitForExit(1000)){return}
      }
    }catch{}
    $script:worker.Dispose();$script:worker=$null
  }
  if($now-$script:lastWorkerStart-lt 5000){return}
  $script:lastWorkerStart=$now
  $workerArgs=@(('"'+(Join-Path $script:appDir 'runtime\watch.mjs')+'"'),('"'+$script:configPath+'"'),[string]$PID)
  try{$script:worker=Start-Process -FilePath $script:config.nodePath -ArgumentList $workerArgs -WindowStyle Hidden -PassThru}
  catch{[IO.File]::WriteAllText((Join-Path $script:dataDir 'worker-error.txt'),$_.Exception.Message,[Text.UTF8Encoding]::new($false))}
}
function Stop-WidgetRuntime {
  if($script:runtimeClosed){return};$script:runtimeClosed=$true
  try{if($script:occlusionRecovery){$script:occlusionRecovery.Dispose()}}catch{}
  try{Stop-WidgetMusic}catch{}
  try{if($script:hostFollower){$script:hostFollower.Dispose()}}catch{}
  foreach($timer in @($script:settingsMenuDismissTimer,$script:timer,$script:hostEventTimer,$script:menuTimer,$script:sceneTimer,$script:resetPhaseTimer,$script:closeTimer)){try{if($timer){$timer.Stop()}}catch{}}
  try{Stop-CompletionMonitor;Clear-CompletionNotifications}catch{}
  try{Close-WidgetAudio}catch{}
  foreach($hook in $script:eventHooks){try{if($hook-ne [IntPtr]::Zero){[GptWidgetNative]::UnhookWinEvent($hook)|Out-Null}}catch{}}
  if($script:worker){try{if(!$script:worker.HasExited){$script:worker.Kill()}}catch{}; $script:worker.Dispose();$script:worker=$null}
  foreach($name in @('runtime.json','presence.json')){
    $file=Join-Path $script:dataDir $name
    try{$state=Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json;if($state.pid-eq $PID){Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue}}catch{}
  }
  # A consumed stop request must not linger: the next normal launch should not
  # be swallowed by an old flag.
  try{Remove-Item -LiteralPath (Join-Path $script:dataDir 'stop.flag') -ErrorAction SilentlyContinue}catch{}
  try{if($script:mutexOwned){$script:mutex.ReleaseMutex();$script:mutexOwned=$false}}catch{};try{$script:mutex.Dispose()}catch{}
}
function Write-WidgetPresence([bool]$visible,[long]$now){
Write-WidgetJson (Join-Path $script:dataDir 'presence.json') @{visible=[bool]$visible;at=$now;host=$script:hostHandle.ToInt64();widget=$script:widgetHandle.ToInt64();pid=$PID;textRaster=@{renderer='direct-vector-glyphs';draws=[GPTNiang.SmoothTextBlock]::VectorDraws;font=$script:ui.Header.FontFamily.Source;weight=[string]$script:ui.Header.FontWeight};character=@{id=$script:characterId;name=$script:activeCharacter.name;galleryOpen=[bool]($script:characterGallery -and $script:characterGallery.IsVisible)};sound=(Get-WidgetAudioStatus);followHost=$script:followHost;follow=@{ready=$script:hostFollower.Ready;events=$script:hostFollower.MovementEvents;mode='native-immediate';animationPaddingDip=14};sizing=@{character=$script:scale;bubble=$script:bubbleScale;display=$script:displayScale;preview=[bool]$script:settingsSizePreview};autoQuotes=@{enabled=$script:autoQuoteEnabled;intervalSeconds=$script:autoQuoteIntervalSeconds;nextAt=$script:autoQuoteNextAt;displayCount=$script:autoQuoteDisplayCount};completion=(Get-CompletionNotificationStatus);recovery=@{checks=$script:occlusionRecovery.Checks;toggles=$script:occlusionRecovery.Toggles;pending=$script:occlusionRecovery.Pending;cloaked=$script:occlusionRecovery.OwnedCloak;failed=$script:occlusionRecovery.Failed;hresult=$script:occlusionRecovery.LastHresult};music=(Get-WidgetMusicStatus);scene=@{open=!$script:collapsed;mode=$script:bubbleMode;resetTimeMode=$script:resetTimeMode;startedAt=$script:sceneStartedAt;closesAt=$script:sceneDeadline;shortReset=$script:ui.ShortReset.Text;weekReset=$script:ui.WeekReset.Text}}
}
function Tick-Widget {
  if($script:updating){return}
  $script:updating=$true
  try{
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Tick-Scene $now
  Tick-WidgetUpdater $now
  if($now-$script:lastPresence-ge 1000 -and (Test-Path -LiteralPath (Join-Path $script:dataDir 'stop.flag'))){$script:window.Close();return}
  Ensure-QuotaWorker $now
  if($script:completionTemporary){
    if($script:occlusionRecovery){$script:occlusionRecovery.Configure([IntPtr]::Zero,$false)}
    if($now-$script:lastPresence-ge 1000){Write-WidgetPresence $true $now;$script:lastPresence=$now;Update-Quota;Read-DisplayRequest;Tick-CompletionNotifications $true}
    return
  }
  $foreground=[GptWidgetNative]::GetAncestor([GptWidgetNative]::GetForegroundWindow(),2)
  if($foreground-ne $script:lastForeground -or ($script:hostHandle-ne [IntPtr]::Zero -and ![GptWidgetNative]::IsWindow($script:hostHandle))){
    $script:lastForeground=$foreground
    $script:foregroundHost=[GptWidgetNative]::ForegroundHost($foreground)
    $script:foregroundOwn=[GptWidgetNative]::ProcessId($foreground)-eq $PID
    if($script:foregroundHost-ne [IntPtr]::Zero){$script:hostHandle=$script:foregroundHost;$script:lastPosition=$null}
    elseif($script:hostHandle-eq [IntPtr]::Zero -or ![GptWidgetNative]::IsWindow($script:hostHandle)){$script:hostHandle=[IntPtr]::Zero;$script:lastHostProbe=0;$script:lastPosition=$null}
  }
  if($script:hostHandle-eq [IntPtr]::Zero -and $now-$script:lastHostProbe-gt 1000){$script:hostHandle=[GptWidgetNative]::FindCodex();$script:lastHostProbe=$now}
  $hostVisible=$script:hostHandle-ne [IntPtr]::Zero -and [GptWidgetZOrderNative]::VisibleSurface($script:hostHandle) -and ![GptWidgetNative]::IsIconic($script:hostHandle)
  $hostReady=Test-WidgetHostReady $script:hostReadiness $script:hostHandle $now
  if(!$script:followHost -and !$script:hostReadiness.desktopStarted -and ($script:hostHandle-eq [IntPtr]::Zero -or ($hostVisible -and $hostReady))){$script:hostReadiness.desktopStarted=$true}
  $visible=if($script:followHost){$hostVisible -and $hostReady}else{$script:hostReadiness.desktopStarted}
  $placementFrame=if($visible){Get-WidgetPlacementFrame}else{$null}
  $placementDpi=if($visible){Get-WidgetPlacementDpi}else{1}
  $visible=$visible -and (Test-WidgetPlacementFrame $placementFrame $placementDpi)
  if($visible){
    if($script:attachedHost-ne $script:hostHandle){
      $script:attachedHost=$script:hostHandle;$script:lastPosition=$null
    }
    $showWidget=!$script:window.IsVisible
    if(!$script:drag){
      $frame=$placementFrame;$dpi=$placementDpi
      if($dpi-le 0){$dpi=1}
      $fitted=Get-WidgetLayoutScale
      if(!$script:followHost){$fitted=[Math]::Min($fitted,[Math]::Min(($frame.Right-$frame.Left)/$dpi/$script:designWidth,($frame.Bottom-$frame.Top)/$dpi/$script:designHeight))}
      if([Math]::Abs($script:displayScale-$fitted)-gt 0.001){Set-Appearance}
      $null=Set-WidgetPixelSize $dpi
      $w=[int]($script:designWidth*$script:displayScale*$dpi);$h=[int]($script:designHeight*$script:displayScale*$dpi)
      if(!$script:followHost){
        if($null-eq $script:desktopLeft){$script:desktopLeft=$frame.Right-$w-24;$script:desktopTop=$frame.Bottom-$h-24}
        $x=[int]$script:desktopLeft
      }
      elseif($script:anchor-eq 'left'){$x=[int]($frame.Left+$script:offsetLeft*$dpi)}
      elseif($script:anchor-eq 'free'){
        if($null-eq $script:offsetLeft){$script:offsetLeft=[Math]::Max(0,($frame.Right-$frame.Left-$w)/$dpi-$script:offsetRight)}
        $x=[int]($frame.Left+$script:offsetLeft*$dpi)
      }else{$x=[int]($frame.Right-$w-$script:offsetRight*$dpi)}
      $desiredY=if($script:followHost){$frame.Bottom-$h-$script:offsetBottom*$dpi}else{$script:desktopTop}
      $y=[int]$desiredY
      if(!$script:followHost){
        $x=Limit-WidgetHorizontalPosition $frame $dpi $x
        $y=Limit-WidgetVerticalPosition $frame $dpi $desiredY
      }
      $position="$($script:hostHandle):$x,$y,$w,$h"
      if($position-ne $script:lastPosition -and !(Test-WidgetMusicActive)){
        [GptWidgetNative]::SetWindowPos($script:widgetHandle,[IntPtr]::Zero,$x,$y,0,0,0x15)|Out-Null
        $script:lastPosition=$position
        if($script:context.IsOpen){Set-WidgetMenuBounds;Position-WidgetMenuToHost}
      }
      if($script:followHost){$nativeFrame=[GptWidgetNative]::Frame($script:hostHandle);$script:hostFollower.Configure($script:hostHandle,$nativeFrame.Left,$nativeFrame.Top,$nativeFrame.Right,$nativeFrame.Bottom,$w,$h,[int]($script:offsetLeft*$dpi),[int]($script:offsetRight*$dpi),[int]($script:offsetBottom*$dpi),$script:anchor,$true)}
      Update-WidgetMusicPlacement $frame $dpi $x $y ([bool]$visible)
    }
    if($script:followHost){
      $musicLight=if(Test-WidgetMusicActive){$script:widgetMusic.LampHandle}else{[IntPtr]::Zero}
      if(!$script:occlusionRecovery.OwnedCloak){$layer=Set-WidgetAboveHost $script:widgetHandle $script:hostHandle $musicLight}
    }
    else{Set-WidgetDesktopLayer $script:widgetHandle $script:desktopTopmost}
    if($showWidget){Reset-WidgetAutoQuoteSchedule $now;$script:window.Show();$script:lastPosition=$null;Request-Refresh}
  }elseif($script:window.IsVisible){
    Reset-WidgetAutoQuoteSchedule $now
    $script:hostFollower.Suspend()
    $script:context.IsOpen=$false
    # Also return any owned quote editor to the normal band before hiding the overlay.
    [GptWidgetNative]::SetWindowPos($script:widgetHandle,[IntPtr](-2),0,0,0,0,0x13)|Out-Null
    $script:window.Hide()
  }
  $recoverAllowed=$script:followHost -and $visible -and !$script:drag -and !$script:context.IsOpen -and !$script:settingsSizePreview -and !($script:characterGallery -and $script:characterGallery.IsVisible) -and !($script:quoteEditor -and $script:quoteEditor.IsVisible)
  if($script:occlusionRecovery){$script:occlusionRecovery.Configure($script:hostHandle,[bool]$recoverAllowed)}
  if($now-$script:lastPresence-ge 1000){
    Update-WidgetMusicVisibility ([bool]$visible) ([bool]($script:completionTemporary -or $script:settingsSizePreview -or ($script:characterGallery -and $script:characterGallery.IsVisible) -or ($script:quoteEditor -and $script:quoteEditor.IsVisible)))
    Write-WidgetPresence ([bool]$visible) $now
    Update-Quota;$script:lastPresence=$now
    Read-DisplayRequest
    Tick-CompletionNotifications ([bool]$visible)
    Tick-WidgetAutoQuote $now ([bool]$visible)
  }
  }finally{$script:updating=$false}
}
$script:winEventCallback=[GptWidgetNative+WinEventProc]{param($hook,$ev,$hwnd,$objectId,$childId,$threadId,$time)
  if($objectId-eq 0 -and $childId-eq 0 -and $ev-in @(3,17,22,23,0x800A)){$script:occlusionRecovery.OnWindowEvent($hwnd)}
  if($hwnd-eq $script:hostHandle -and $objectId-eq 0 -and $childId-eq 0){
    if($ev-eq 16){$script:context.IsOpen=$false}
  }
  if($ev-eq 3 -or ($objectId-eq 0 -and $childId-eq 0 -and ($hwnd-eq $script:hostHandle -or ($script:hostHandle-eq [IntPtr]::Zero -and [GptWidgetNative]::IsCodex($hwnd))))){
    # Native movement is immediate. Only lifecycle, DPI/resize and popup layout
    # need the slower PowerShell update.
    if(!$script:hostEventTimer.IsEnabled){$script:hostEventTimer.Start()}
  }
}
$script:hostEventTimer=New-Object Windows.Threading.DispatcherTimer
$script:hostEventTimer.Interval=[TimeSpan]::FromMilliseconds(33)
$script:hostEventTimer.Add_Tick({$script:hostEventTimer.Stop();try{Tick-Widget}catch{[IO.File]::WriteAllText((Join-Path $script:dataDir 'display-error.txt'),$_.Exception.Message,[Text.UTF8Encoding]::new($false))}})
$script:eventHooks=@(
  [GptWidgetNative]::Hook(3,3,$script:winEventCallback),
  [GptWidgetNative]::Hook(16,23,$script:winEventCallback),
  [GptWidgetNative]::Hook(0x8000,0x8003,$script:winEventCallback),
  [GptWidgetNative]::Hook(0x800A,0x800A,$script:winEventCallback)
)
$script:timer=New-Object Windows.Threading.DispatcherTimer
$script:timer.Interval=[TimeSpan]::FromMilliseconds(1000)
$script:timer.Add_Tick({try{Tick-Widget}catch{[IO.File]::WriteAllText((Join-Path $script:dataDir 'display-error.txt'),$_.Exception.Message)}})
$script:window.Add_Closed({
  Stop-WidgetRuntime
  [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})
try{
  # Do not replace a settings file that failed to load with defaults; the
  # user's original file is the only remaining copy.
  if(!$script:settingsLoadFailed){Save-Settings}
  Start-CompletionMonitor
  Ensure-QuotaWorker ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  $widgetProcess=Get-Process -Id $PID
  try{$processStartedAt=$widgetProcess.StartTime.ToUniversalTime().ToString('o')}finally{$widgetProcess.Dispose()}
  Write-WidgetJson (Join-Path $script:dataDir 'runtime.json') @{pid=$PID;widget=$script:widgetHandle.ToInt64();startedAt=[DateTime]::UtcNow.ToString('o');processStartedAt=$processStartedAt;eventHooks=@($script:eventHooks|ForEach-Object{$_.ToInt64()});fallbackIntervalMs=1000;movementMode='native-immediate'}
  $script:timer.Start();Tick-Widget
  [Windows.Threading.Dispatcher]::Run()
}catch{
  [IO.File]::WriteAllText((Join-Path $script:dataDir 'display-error.txt'),$_.Exception.ToString())
  throw
}finally{Stop-WidgetRuntime}
