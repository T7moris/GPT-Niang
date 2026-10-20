param([string]$AppRoot,[string]$ResultFile)
$ErrorActionPreference='Stop'
if(!$AppRoot){$AppRoot=Split-Path $PSScriptRoot -Parent}
$source=[IO.File]::ReadAllText((Join-Path $AppRoot 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Widget source does not parse'}
foreach($name in @('Get-QuotaWindowLabel','Get-QuotaRows')){
 $definition=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst]-and $node.Name-eq $name},$true)
 if(!$definition){throw ('Missing quota function: '+$name)}
 . ([scriptblock]::Create($definition.Extent.Text))
}
$cases=@(
 @{name='empty';windows=@();short=$null;week=$null},
 @{name='personal';windows=@(@{id='week';minutes=10080},@{id='short';minutes=300});short='short';week='week'},
 @{name='short-only';windows=@(@{id='short';minutes=300});short='short';week=$null},
 @{name='week-only';windows=@(@{id='week';minutes=10080});short=$null;week='week'},
 @{name='other-windows';windows=@(@{id='day';minutes=1440},@{id='hour';minutes=60});short='hour';week='day'},
 @{name='other-and-week';windows=@(@{id='hour';minutes=60},@{id='week';minutes=10080});short='hour';week='week'},
 @{name='individual-and-timed';windows=@(@{id='week';minutes=10080},@{id='individual';kind='individual';minutes=0},@{id='hour';minutes=60});short='individual';week='hour'},
 @{name='individual-only';windows=@(@{id='individual';kind='individual';minutes=0});short='individual';week=$null}
)
$failures=@();$rows=@()
foreach($case in $cases){
 $script:status=(@{windows=$case.windows}|ConvertTo-Json -Depth 6)|ConvertFrom-Json
 $before=$script:status|ConvertTo-Json -Depth 8 -Compress
 $types=@(foreach($window in $script:status.windows){$window.PSObject.TypeNames-join '|'});
 $got=@(Get-QuotaRows)
 if($got.Count-ne 2-or $got[0].prefix-ne 'Short'-or $got[1].prefix-ne 'Week'-or $got[0].window.id-ne $case.short-or $got[1].window.id-ne $case.week){$failures+=('Selection differs for '+$case.name)}
 if(($script:status|ConvertTo-Json -Depth 8 -Compress)-ne $before){$failures+=('Quota values changed for '+$case.name)}
 $afterTypes=@(foreach($window in $script:status.windows){$window.PSObject.TypeNames-join '|'})
 if(($types-join ';')-cne ($afterTypes-join ';')){$failures+=('Cached object type metadata changed for '+$case.name)}
 $rows+=@{name=$case.name;short=$got[0].window.id;week=$got[1].window.id;shortLabel=$got[0].label;weekLabel=$got[1].label}
}
$script:status='{"windows":[{"minutes":300,"used":25,"remaining":75},{"minutes":10080,"used":10,"remaining":90}]}'|ConvertFrom-Json
$before=@($script:status.windows|ForEach-Object{$_.PSObject.TypeNames.Count})
for($i=0;$i-lt 1000;$i++){$null=Get-QuotaRows}
$after=@($script:status.windows|ForEach-Object{$_.PSObject.TypeNames.Count})
if(($before-join ',')-ne ($after-join ',')){$failures+=('Repeated selection grows type metadata: '+($before-join ',')+' -> '+($after-join ','))}
$result=@{passed=($failures.Count-eq 0);powerShellVersion=$PSVersionTable.PSVersion.ToString();functionalCases=$rows;iterations=1000;typeCountsBefore=$before;typeCountsAfter=$after;failures=$failures}
if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))}
if($failures.Count){throw ($failures-join [Environment]::NewLine)}
Write-Output 'PASS: eight quota selection cases; original values and cached type metadata unchanged after 1000 selections'
