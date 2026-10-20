function Initialize-WidgetUpdater {
  $script:updateProcess=$null;$script:updateLastTick=0;$script:updateStartedAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$script:updateCleanupChecked=$false
  $preferences=Read-WidgetUpdateJson (Join-Path $script:dataDir 'update-preferences.json')
  $script:autoUpdate=!($preferences -and $preferences.automatic-eq $false)
}
function Test-WidgetUpdateEditor {
  return [bool]($script:audioDialogOpen -or ($script:quoteEditor -and $script:quoteEditor.IsVisible) -or ($script:colorTriggerEditor -and $script:colorTriggerEditor.IsVisible) -or ($script:characterGallery -and $script:characterGallery.IsVisible))
}
function Start-WidgetUpdate([string]$Mode='manual') {
  if($script:updateProcess){if(!$script:updateProcess.HasExited){return};$script:updateProcess.Dispose();$script:updateProcess=$null}
  if($Mode-eq 'manual' -and (Test-WidgetUpdateEditor)){
    [Windows.MessageBox]::Show($script:window,'请先保存并关闭编辑窗口，再检查更新。','GPT 娘更新')|Out-Null;return
  }
  if(!$script:config.nodePath){return}
  $info=New-Object Diagnostics.ProcessStartInfo
  $info.FileName=$script:config.nodePath
  $info.Arguments='"'+(Join-Path $script:appDir 'runtime\update.mjs')+'" "'+$script:configPath+'" '+$Mode
  $info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $process=New-Object Diagnostics.Process;$process.StartInfo=$info
  try{if(!$process.Start()){throw 'Updater process did not start.'};$script:updateProcess=$process}
  catch{$process.Dispose();Write-WidgetSupervisorJson (Join-Path $script:dataDir 'update-status.json') @{phase='failed';message=$_.Exception.Message;nextCheckAt=[DateTimeOffset]::UtcNow.AddDays(1).ToUnixTimeMilliseconds()}}
}
function Set-WidgetAutomaticUpdate([bool]$Enabled) {
  $script:autoUpdate=$Enabled
  Write-WidgetSupervisorJson (Join-Path $script:dataDir 'update-preferences.json') @{automatic=$Enabled}
  if($Enabled){Start-WidgetUpdate 'automatic-enabled'}
  Update-WidgetUpdateMenu
}
function Update-WidgetUpdateMenu {
  if(!$script:settingsMenuUi.UpdateVersion){return}
  $script:settingsMenuUi.UpdateVersion.Header='当前版本：'+$script:config.version
  $script:settingsMenuUi.AutoUpdate.IsChecked=$script:autoUpdate
  $state=Read-WidgetUpdateJson (Join-Path $script:dataDir 'update-status.json')
  $label=switch($state.phase){
    'checking' {'正在检查正式版…'}
    'downloading' {'正在下载：'+[Math]::Round([double]$state.bytes/1MB,1)+' MiB'}
    'waiting' {'已校验，等待挂件空闲'}
    'installing' {'正在安装更新…'}
    'updated' {'已更新至 '+$state.version}
    'rolled-back' {'更新失败，已恢复上一版'}
    'failed' {'更新失败：'+$state.message}
    'source' {'源码目录请使用 Git 更新'}
    'rate-limited' {'GitHub 限流，稍后再检查'}
    'current' {'已是最新正式版'}
    'cancelled' {'自动更新已关闭'}
    default {'自动检查正式版，每 24 小时一次'}
  }
  $script:settingsMenuUi.UpdateStatus.Header.Text=$label
  $script:settingsMenuUi.UpdateStatus.ToolTip=$state.message
}
function Tick-WidgetUpdater([long]$Now) {
  if($Now-$script:updateLastTick-lt 1000){return};$script:updateLastTick=$Now
  Write-WidgetSupervisorJson (Join-Path $script:dataDir 'update-idle.json') @{at=$Now;pid=$PID;editor=(Test-WidgetUpdateEditor);menu=[bool]$script:context.IsOpen;drag=[bool]$script:drag}
  if($script:updateProcess -and $script:updateProcess.HasExited){
    if($script:updateProcess.ExitCode-ne 0){Write-WidgetSupervisorJson (Join-Path $script:dataDir 'update-status.json') @{phase='failed';message='更新进程异常退出，请检查安装配置后再重试。';nextCheckAt=$Now+86400000}}
    $script:updateProcess.Dispose();$script:updateProcess=$null
  }
  $state=Read-WidgetUpdateJson (Join-Path $script:dataDir 'update-status.json')
  # Cleanup is independent of the preference to check for new releases.
  if(!$script:updateCleanupChecked -and $Now-ge $script:updateStartedAt+30000 -and !$script:updateProcess){
    $script:updateCleanupChecked=$true;Start-WidgetUpdate 'cleanup'
  }
  if($script:autoUpdate -and $Now-ge $script:updateStartedAt+30000 -and $Now-ge [long]$state.nextCheckAt -and $state.phase-ne 'source'){Start-WidgetUpdate 'automatic'}
  if($script:context.IsOpen){Update-WidgetUpdateMenu}
}
