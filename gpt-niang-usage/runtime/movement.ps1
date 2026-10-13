# Transient horizontal movement. Saved placement remains the resting position.
$script:widgetMovement=$null
function Initialize-WidgetMovement {
    if($script:widgetMovement){return}
    $timer=[Windows.Threading.DispatcherTimer]::new()
    $timer.Interval=[TimeSpan]::FromMilliseconds(33)
    $script:widgetMovement=@{Enabled=$false;Timer=$timer;Clock=[Diagnostics.Stopwatch]::new();Phase=$null}
    $timer.Add_Tick({
        try{Sync-WidgetMovement;Tick-Widget}catch{Set-WidgetMovement $false -NoLayout}
    })
    $script:window.Add_IsVisibleChanged({Sync-WidgetMovement})
    $script:window.Add_MouseEnter({Sync-WidgetMovement})
    $script:window.Add_MouseLeave({Sync-WidgetMovement})
    $script:context.Add_Opened({Sync-WidgetMovement})
    $script:context.Add_Closed({Sync-WidgetMovement})
}
function Sync-WidgetMovement {
    $m=$script:widgetMovement;if(!$m){return}
    if($m.Enabled -and $script:window.IsVisible -and !$script:window.IsMouseOver -and !$script:context.IsOpen -and !$script:drag){
        $m.Clock.Start();$m.Timer.Start()
    }else{$m.Clock.Stop();$m.Timer.Stop()}
}
function Set-WidgetMovement([bool]$Enabled,[switch]$NoLayout) {
    if(!$script:widgetMovement){if(!$Enabled){return};Initialize-WidgetMovement}
    $m=$script:widgetMovement
    if($m.Enabled-eq $Enabled){return}
    $m.Enabled=$Enabled;$m.Phase=$null;$m.Clock.Reset()
    Sync-WidgetMovement
    if($script:settingsMenuUi.Movement){$script:settingsMenuUi.Movement.IsChecked=$Enabled}
    if(!$NoLayout){$script:lastPosition=$null;Tick-Widget}
}
function Get-WidgetMovementX([double]$Left,[double]$Right,[double]$RestX) {
    $m=$script:widgetMovement
    if(!$m -or !$m.Enabled){return $RestX}
    $span=[Math]::Max(0,$Right-$Left)
    if($span-lt 1){return $Left}
    if($null-eq $m.Phase){
        $fraction=[Math]::Max(0.0,[Math]::Min(1.0,($RestX-$Left)/$span))
        $m.Phase=[Math]::Acos(2*$fraction-1);$m.Clock.Reset();Sync-WidgetMovement
    }
    # Eight seconds per crossing, with gradual braking and reversal at each edge.
    $angle=$m.Phase+$m.Clock.Elapsed.TotalSeconds*[Math]::PI/8
    return $Left+$span*(0.5+0.5*[Math]::Cos($angle))
}
