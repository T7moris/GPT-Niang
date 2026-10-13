# Original vector prop. Uses WPF animation clocks; no music files or polling timer.
$script:widgetSpeaker=$null
$script:speakerRequested=$false

function New-WidgetSpeaker {
    if($script:widgetSpeaker){return}
    $prop=[Windows.Markup.XamlReader]::Parse(@'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="132" Height="178" IsHitTestVisible="False" RenderTransformOrigin="0.5,1" Visibility="Collapsed">
 <Canvas.RenderTransform><TransformGroup><ScaleTransform x:Name="Pop"/><ScaleTransform x:Name="Beat"/><RotateTransform x:Name="Tilt"/><TranslateTransform x:Name="Slide"/></TransformGroup></Canvas.RenderTransform>
 <Border Width="132" Height="178" CornerRadius="16" BorderBrush="#D5B5FF" BorderThickness="3"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#544778" Offset="0"/><GradientStop Color="#171729" Offset="1"/></LinearGradientBrush></Border.Background></Border>
 <Rectangle Canvas.Left="15" Canvas.Top="13" Width="102" Height="7" RadiusX="3" RadiusY="3" Fill="#6CF4F0"/>
 <Ellipse Canvas.Left="45" Canvas.Top="30" Width="42" Height="42" Fill="#111324" Stroke="#C687FF" StrokeThickness="3"/>
 <Ellipse Canvas.Left="56" Canvas.Top="41" Width="20" Height="20" Fill="#BFA0E8"/>
 <Ellipse Canvas.Left="23" Canvas.Top="81" Width="86" Height="86" Fill="#111221" Stroke="#73EEF5" StrokeThickness="4"/>
 <Ellipse Canvas.Left="38" Canvas.Top="96" Width="56" Height="56" Fill="#34304D" Stroke="#786391" StrokeThickness="2"/>
 <Ellipse Canvas.Left="52" Canvas.Top="110" Width="28" Height="28" Fill="#C29DDB"/>
 <Rectangle Canvas.Left="12" Canvas.Top="170" Width="23" Height="8" RadiusX="3" RadiusY="3" Fill="#171729"/>
 <Rectangle Canvas.Left="97" Canvas.Top="170" Width="23" Height="8" RadiusX="3" RadiusY="3" Fill="#171729"/>
</Canvas>
'@)
    [Windows.Controls.Canvas]::SetLeft($prop,57);[Windows.Controls.Canvas]::SetTop($prop,166)
    $script:ui.Root.Children.Insert($script:ui.Root.Children.IndexOf($script:ui.Girl),$prop)
    $script:widgetSpeaker=@{Prop=$prop;Pop=$prop.FindName('Pop');Beat=$prop.FindName('Beat');Tilt=$prop.FindName('Tilt');Slide=$prop.FindName('Slide');
        GirlScale=[Windows.Media.ScaleTransform]::new();GirlTransform=$script:ui.Girl.RenderTransform;GirlOrigin=$script:ui.Girl.RenderTransformOrigin;Running=$false}
    $script:window.Add_IsVisibleChanged({
        if($script:speakerRequested -and $script:window.IsVisible){Start-WidgetSpeakerAnimation}
        else{Stop-WidgetSpeakerAnimation}
    })
}

function Set-WidgetSpeakerPulse($Target,$Property,[double]$From,[double]$To) {
    $animation=[Windows.Media.Animation.DoubleAnimation]::new($From,$To,[Windows.Duration]::new([TimeSpan]::FromSeconds(0.23)))
    $animation.AutoReverse=$true;$animation.RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever
    $animation.EasingFunction=[Windows.Media.Animation.SineEase]::new()
    $animation.EasingFunction.EasingMode=[Windows.Media.Animation.EasingMode]::EaseInOut
    $Target.BeginAnimation($Property,$animation)
}

function Stop-WidgetSpeakerAnimation {
    $s=$script:widgetSpeaker;if(!$s){return}
    foreach($scale in @($s.Pop,$s.Beat,$s.GirlScale)){
        $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty,$null)
        $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty,$null)
    }
    $s.Tilt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty,$null)
    $s.Slide.BeginAnimation([Windows.Media.TranslateTransform]::XProperty,$null)
    $s.Slide.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$null)
    $s.Prop.BeginAnimation([Windows.UIElement]::OpacityProperty,$null)
    $script:ui.Girl.RenderTransform=$s.GirlTransform;$script:ui.Girl.RenderTransformOrigin=$s.GirlOrigin
    $s.Prop.Visibility=[Windows.Visibility]::Collapsed;$s.Running=$false
}

function Start-WidgetSpeakerAnimation {
    $s=$script:widgetSpeaker
    if(!$s -or $s.Running -or !$script:speakerRequested -or !$script:window.IsVisible){return}
    $s.Running=$true;$s.Prop.Visibility=[Windows.Visibility]::Visible
    $script:ui.Girl.RenderTransform=$s.GirlScale;$script:ui.Girl.RenderTransformOrigin=[Windows.Point]::new(0.5,1)
    Set-WidgetSpeakerPulse $s.Beat ([Windows.Media.ScaleTransform]::ScaleXProperty) 1 1.04
    Set-WidgetSpeakerPulse $s.Beat ([Windows.Media.ScaleTransform]::ScaleYProperty) 1 0.91
    Set-WidgetSpeakerPulse $s.GirlScale ([Windows.Media.ScaleTransform]::ScaleXProperty) 1 1.035
    Set-WidgetSpeakerPulse $s.GirlScale ([Windows.Media.ScaleTransform]::ScaleYProperty) 1 0.94
    Set-WidgetSpeakerPulse $s.Tilt ([Windows.Media.RotateTransform]::AngleProperty) -4 4
    foreach($axis in @('X','Y')){
        $property=if($axis-eq 'X'){[Windows.Media.ScaleTransform]::ScaleXProperty}else{[Windows.Media.ScaleTransform]::ScaleYProperty}
        $animation=[Windows.Media.Animation.DoubleAnimation]::new(0.05,1,[Windows.Duration]::new([TimeSpan]::FromSeconds(0.65)))
        $animation.EasingFunction=[Windows.Media.Animation.BackEase]::new();$animation.EasingFunction.Amplitude=0.5
        $animation.EasingFunction.EasingMode=[Windows.Media.Animation.EasingMode]::EaseOut
        $s.Pop.BeginAnimation($property,$animation)
    }
    foreach($axis in @('X','Y')){
        $property=if($axis-eq 'X'){[Windows.Media.TranslateTransform]::XProperty}else{[Windows.Media.TranslateTransform]::YProperty}
        $from=if($axis-eq 'X'){100}else{28}
        $animation=[Windows.Media.Animation.DoubleAnimation]::new($from,0,[Windows.Duration]::new([TimeSpan]::FromSeconds(0.65)))
        $animation.EasingFunction=[Windows.Media.Animation.CubicEase]::new();$animation.EasingFunction.EasingMode=[Windows.Media.Animation.EasingMode]::EaseOut
        $s.Slide.BeginAnimation($property,$animation)
    }
    $s.Prop.BeginAnimation([Windows.UIElement]::OpacityProperty,[Windows.Media.Animation.DoubleAnimation]::new(0,1,[Windows.Duration]::new([TimeSpan]::FromSeconds(0.25))))
}

function Set-WidgetSpeakerVisible([bool]$Visible) {
    $script:speakerRequested=$Visible
    if($Visible){New-WidgetSpeaker;Start-WidgetSpeakerAnimation}
    else{Stop-WidgetSpeakerAnimation}
}
