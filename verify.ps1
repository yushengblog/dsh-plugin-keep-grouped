# verify-keep-grouped.ps1
# 验证 dsh-plugin-keep-grouped 是否已生效
#
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File verify-keep-grouped.ps1
#
# 注意: 本文件必须存为 UTF-8 with BOM，否则 PowerShell 5.1 会把中文读成乱码。

$ErrorActionPreference = 'SilentlyContinue'

function Ok($b) { if ($b) { return '[OK]' } else { return '[缺失]' } }

Write-Host '=== 1) profile 配置检查 ===' -ForegroundColor Cyan
$pkg = 'C:\Users\misaka\.dsh\profiles\desktop\package.json'
if (Test-Path $pkg) {
    $j = Get-Content $pkg -Raw -Encoding UTF8 | ConvertFrom-Json
    $inDeps = $j.dependencies.PSObject.Properties.Name -contains 'dsh-plugin-keep-grouped'
    $inBundles = $j.dsh.profile.bundles -contains 'dsh-plugin-keep-grouped'
    Write-Host ('  dependencies: ' + (Ok $inDeps))
    Write-Host ('  bundles:      ' + (Ok $inBundles))
} else {
    Write-Host '  package.json 不存在'
}

Write-Host ''
Write-Host '=== 2) 插件文件检查 ===' -ForegroundColor Cyan
$link = 'C:\Users\misaka\.dsh\profiles\desktop\node_modules\dsh-plugin-keep-grouped'
Write-Host ('  node_modules 链接: ' + (Ok (Test-Path $link)))
foreach ($f in 'package.json','cordis.patch.yml','lib\index.js') {
    $p = Join-Path $link $f
    Write-Host ('  ' + $f.PadRight(20) + ': ' + (Ok (Test-Path $p)))
}

Write-Host ''
Write-Host '=== 3) DSH 进程启动时间 ===' -ForegroundColor Cyan
$procs = Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" |
         Sort-Object CreationDate | Select-Object -First 1
if ($procs) {
    Write-Host ('  最早进程启动: ' + $procs.CreationDate)
    Write-Host ('  当前时间:     ' + (Get-Date))
}

Write-Host ''
Write-Host '=== 4) 工作区路径可达性 ===' -ForegroundColor Cyan
$ws = 'C:\Users\misaka\.dsh\storages\workspace.json'
if (Test-Path $ws) {
    $w = Get-Content $ws -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($id in $w.tables.workspaces.PSObject.Properties.Name) {
        $item = $w.tables.workspaces.$id
        $reach = Test-Path $item.path
        Write-Host ('  ' + $item.title + ' : ' + $item.sessionIds.Count + ' 个会话, 路径可达=' + (Ok $reach))
        Write-Host ('     ' + $item.path)
    }
}

Write-Host ''
Write-Host '=== 5) 检查 workspace.json 是否被改写 ===' -ForegroundColor Cyan
$wsFile = Get-Item $ws
$dshProc = Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" |
           Sort-Object CreationDate | Select-Object -First 1
if ($wsFile -and $dshProc) {
    Write-Host ('  workspace.json 修改时间: ' + $wsFile.LastWriteTime)
    Write-Host ('  DSH 启动时间:            ' + $dshProc.CreationDate)
    if ($wsFile.LastWriteTime -lt $dshProc.CreationDate) {
        Write-Host '  -> 文件未被改写（分组未被破坏）' -ForegroundColor Green
    } else {
        Write-Host '  -> 文件被改写过，请检查分组是否正常' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '=== 完成 ===' -ForegroundColor Green
Write-Host '判定标准：'
Write-Host '  1. 上面 1、2 项全部 [OK]'
Write-Host '  2. 工作区路径不可达时，会话数仍然 > 0'
Write-Host '  3. workspace.json 未被改写'
