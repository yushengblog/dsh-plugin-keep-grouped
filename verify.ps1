# verify-keep-grouped.ps1
# 验证 dsh-plugin-keep-grouped 是否已生效
#
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify-keep-grouped.ps1
#   powershell ... -File verify-keep-grouped.ps1 -Profile desktop    # 指定 profile
#
# 注意: 本文件必须存为 UTF-8 with BOM，否则 PowerShell 5.1 会把中文读成乱码。
#
# 路径全部自动探测，不写死用户名 —— 换机器直接能用。

param(
    # DSH 的 profile 名；不传则自动探测（优先 desktop，其次第一个有 package.json 的）
    [string]$Profile = ''
)

$ErrorActionPreference = 'SilentlyContinue'

function Ok($b) { if ($b) { return '[OK]' } else { return '[缺失]' } }

# ── 自动探测 DSH_HOME ──────────────────────────────────────────────
# 优先级: 环境变量 $env:DSH_HOME → ~/.dsh
function Get-DshHome {
    if ($env:DSH_HOME -and (Test-Path $env:DSH_HOME)) { return $env:DSH_HOME }
    $candidate = Join-Path $env:USERPROFILE '.dsh'
    if (Test-Path $candidate) { return $candidate }
    return $null
}

# ── 自动探测 profile 目录 ─────────────────────────────────────────
function Get-ProfileDir {
    param([string]$DshHome, [string]$ProfileName)

    $profilesRoot = Join-Path $DshHome 'profiles'
    if (-not (Test-Path $profilesRoot)) { return $null }

    # 1) 显式指定
    if ($ProfileName) {
        $p = Join-Path $profilesRoot $ProfileName
        if (Test-Path $p) { return $p }
        Write-Host ("  警告: 指定的 profile '$ProfileName' 不存在，改为自动探测") -ForegroundColor Yellow
    }

    # 2) 优先 desktop
    $desktop = Join-Path $profilesRoot 'desktop'
    if (Test-Path (Join-Path $desktop 'package.json')) { return $desktop }

    # 3) 第一个含 package.json 的 profile
    $found = Get-ChildItem $profilesRoot -Directory -ErrorAction SilentlyContinue |
             Where-Object { Test-Path (Join-Path $_.FullName 'package.json') } |
             Select-Object -First 1
    if ($found) { return $found.FullName }

    return $null
}

# ── 主流程 ────────────────────────────────────────────────────────
$dshHome = Get-DshHome
if (-not $dshHome) {
    Write-Host '找不到 DSH 数据目录（$env:DSH_HOME 或 ~/.dsh）' -ForegroundColor Red
    exit 1
}
Write-Host ('DSH 数据目录: ' + $dshHome) -ForegroundColor DarkGray

$profileDir = Get-ProfileDir -DshHome $dshHome -ProfileName $Profile
if (-not $profileDir) {
    Write-Host '找不到 profile 目录' -ForegroundColor Red
    exit 1
}
Write-Host ('profile 目录: ' + $profileDir) -ForegroundColor DarkGray
Write-Host ''

Write-Host '=== 1) profile 配置检查 ===' -ForegroundColor Cyan
$pkg = Join-Path $profileDir 'package.json'
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
$link = Join-Path $profileDir 'node_modules\dsh-plugin-keep-grouped'
Write-Host ('  node_modules 链接: ' + (Ok (Test-Path $link)))
foreach ($f in 'package.json','cordis.patch.yml','lib\index.js') {
    $p = Join-Path $link $f
    Write-Host ('  ' + $f.PadRight(20) + ': ' + (Ok (Test-Path $p)))
}

Write-Host ''
Write-Host '=== 3) DSH 进程启动时间 ===' -ForegroundColor Cyan
$procs = Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
         Sort-Object CreationDate | Select-Object -First 1
if ($procs) {
    Write-Host ('  最早进程启动: ' + $procs.CreationDate)
    Write-Host ('  当前时间:     ' + (Get-Date))
} else {
    Write-Host '  DSH 未在运行（进程名可能是别的，跳过）' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== 4) 工作区路径可达性 ===' -ForegroundColor Cyan
$ws = Join-Path $dshHome 'storages\workspace.json'
if (Test-Path $ws) {
    $w = Get-Content $ws -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($id in $w.tables.workspaces.PSObject.Properties.Name) {
        $item = $w.tables.workspaces.$id
        $reach = Test-Path $item.path
        $color = if ($reach) { 'Gray' } else { 'Yellow' }
        Write-Host ('  ' + $item.title + ' : ' + $item.sessionIds.Count + ' 个会话, 路径可达=' + (Ok $reach)) -ForegroundColor $color
        Write-Host ('     ' + $item.path) -ForegroundColor DarkGray
    }
} else {
    Write-Host '  workspace.json 不存在' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== 5) 检查 workspace.json 是否被改写 ===' -ForegroundColor Cyan
$wsFile = Get-Item $ws -ErrorAction SilentlyContinue
if ($wsFile -and $procs) {
    Write-Host ('  workspace.json 修改时间: ' + $wsFile.LastWriteTime)
    Write-Host ('  DSH 启动时间:            ' + $procs.CreationDate)
    if ($wsFile.LastWriteTime -lt $procs.CreationDate) {
        Write-Host '  -> 文件未被改写（分组未被破坏）' -ForegroundColor Green
    } else {
        Write-Host '  -> 文件被改写过，请检查分组是否正常' -ForegroundColor Yellow
    }
} elseif ($wsFile) {
    Write-Host ('  workspace.json 修改时间: ' + $wsFile.LastWriteTime)
    Write-Host '  （DSH 未运行，无法比较）' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== 完成 ===' -ForegroundColor Green
Write-Host '判定标准：'
Write-Host '  1. 上面 1、2 项全部 [OK]'
Write-Host '  2. 工作区路径不可达时，会话数仍然 > 0（说明插件兜底生效）'
Write-Host '  3. workspace.json 未被改写'
Write-Host ''
Write-Host '复现「路径不可达」的常见做法：'
Write-Host '  · 断开网络映射：net use \\\\server\\share /delete'
Write-Host '  · 停掉做端口转发的服务（如 MPF / VPN）'
Write-Host '  · 拔网线 / 断 Wi-Fi（但这样连 DSH 的本地服务也可能受影响）'
