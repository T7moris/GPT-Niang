if(!('GPTNiang.SmoothTextBlock' -as [type])){
Add-Type -AssemblyName System.Xaml
Add-Type -ReferencedAssemblies ([Windows.Controls.TextBlock].Assembly.Location),([Windows.Media.FormattedText].Assembly.Location),([Windows.Freezable].Assembly.Location),([Windows.Markup.IQueryAmbient].Assembly.Location) -TypeDefinition @'
using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
namespace GPTNiang {
 public sealed class SmoothTextBlock:Control {
  static readonly FrameworkPropertyMetadataOptions TextFlags=FrameworkPropertyMetadataOptions.AffectsMeasure|FrameworkPropertyMetadataOptions.AffectsRender;
  public static readonly DependencyProperty TextProperty=DependencyProperty.Register("Text",typeof(string),typeof(SmoothTextBlock),new FrameworkPropertyMetadata("",TextFlags));
  public string Text {get{return (string)GetValue(TextProperty);}set{SetValue(TextProperty,value);}}
  public static readonly DependencyProperty TextAlignmentProperty=DependencyProperty.Register("TextAlignment",typeof(TextAlignment),typeof(SmoothTextBlock),new FrameworkPropertyMetadata(TextAlignment.Left,TextFlags));
  public TextAlignment TextAlignment {get{return (TextAlignment)GetValue(TextAlignmentProperty);}set{SetValue(TextAlignmentProperty,value);}}
  public static readonly DependencyProperty TextWrappingProperty=DependencyProperty.Register("TextWrapping",typeof(TextWrapping),typeof(SmoothTextBlock),new FrameworkPropertyMetadata(TextWrapping.NoWrap,TextFlags));
  public TextWrapping TextWrapping {get{return (TextWrapping)GetValue(TextWrappingProperty);}set{SetValue(TextWrappingProperty,value);}}
  public static readonly DependencyProperty TextTrimmingProperty=DependencyProperty.Register("TextTrimming",typeof(TextTrimming),typeof(SmoothTextBlock),new FrameworkPropertyMetadata(TextTrimming.None,TextFlags));
  public TextTrimming TextTrimming {get{return (TextTrimming)GetValue(TextTrimmingProperty);}set{SetValue(TextTrimmingProperty,value);}}
  public static readonly DependencyProperty LineHeightProperty=DependencyProperty.Register("LineHeight",typeof(double),typeof(SmoothTextBlock),new FrameworkPropertyMetadata(double.NaN,TextFlags));
  public double LineHeight {get{return (double)GetValue(LineHeightProperty);}set{SetValue(LineHeightProperty,value);}}
  public LineStackingStrategy LineStackingStrategy {get;set;}
  public SmoothTextBlock(){Focusable=false;}
  FormattedText Format(double availableWidth){
#pragma warning disable 0618
   var formatted=new FormattedText(Text??"",CultureInfo.CurrentCulture,FlowDirection,new Typeface(FontFamily,FontStyle,FontWeight,FontStretch),FontSize,Foreground??Brushes.Black);
#pragma warning restore 0618
   formatted.TextAlignment=TextAlignment;formatted.Trimming=TextTrimming;
   if(TextWrapping!=TextWrapping.NoWrap||TextTrimming!=TextTrimming.None)formatted.MaxTextWidth=Math.Max(1,availableWidth-Padding.Left-Padding.Right);
   if(!double.IsNaN(LineHeight)&&LineHeight>0)formatted.LineHeight=LineHeight;
   return formatted;
  }
  protected override Size MeasureOverride(Size available){
   var text=Format(double.IsInfinity(available.Width)?100000:available.Width);
   return new Size(text.WidthIncludingTrailingWhitespace+Padding.Left+Padding.Right,text.Height+Padding.Top+Padding.Bottom);
  }
  public static long VectorDraws;
  public string RenderMode {get{return "vector-glyph-outlines";}}
  protected override void OnRender(DrawingContext context){
   if(string.IsNullOrEmpty(Text)||ActualWidth<=0||ActualHeight<=0)return;
   var formatted=Format(ActualWidth);
   formatted.MaxTextWidth=Math.Max(1,ActualWidth-Padding.Left-Padding.Right);
   var shape=formatted.BuildGeometry(new Point(Padding.Left,Padding.Top));
   context.DrawGeometry(Foreground,null,shape);
   VectorDraws++;
  }
  public void RefreshRaster(){InvalidateVisual();}
 }
}
'@
}
function ConvertTo-SmoothWidgetXaml([string]$Xaml,[string]$AppDir=(Split-Path $PSScriptRoot -Parent)){
  $fontDirectory=[IO.Path]::GetFullPath((Join-Path $AppDir 'assets\fonts'))+[IO.Path]::DirectorySeparatorChar
  $fontUri=([Uri]::new($fontDirectory)).AbsoluteUri+'#LXGW WenKai'
  $Xaml=$Xaml.Replace('__GPTNIANG_FONT__',[Security.SecurityElement]::Escape($fontUri))
  $assembly=[GPTNiang.SmoothTextBlock].Assembly.GetName().Name
  $Xaml=$Xaml.Replace('xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"',('xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:smooth="clr-namespace:GPTNiang;assembly='+$assembly+'"'))
  return $Xaml.Replace('<TextBlock ','<smooth:SmoothTextBlock ').Replace('</TextBlock>','</smooth:SmoothTextBlock>')
}
function Refresh-WidgetTextRaster {
  foreach($name in @('Header','ShortLabel','WeekLabel','ShortLeft','WeekLeft','ShortReset','WeekReset','QuoteText')){
    if($script:ui[$name]-is [GPTNiang.SmoothTextBlock]){$script:ui[$name].RefreshRaster()}
  }
}
