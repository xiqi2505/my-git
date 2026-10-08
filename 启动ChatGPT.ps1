#Requires -Version 5.1
<#
    ChatGPT 桌面版一键修复 / 启动脚本
    ------------------------------------------------------------
    背景：ChatGPT 桌面版（Store 包 OpenAI.Codex）启动时会先连接服务端，
          连不上就一直卡在初始化阶段 —— 后台有进程，但不弹出窗口。

    本脚本流程：
      1. 检测代理客户端（Clash Verge）是否在运行，没运行则自动拉起
      2. 检测「代理隧道 → OpenAI」是否真的通，以及系统代理开关是否打开
      3. 清理卡死的 ChatGPT 残留进程（含 lockfile 残留）
      4. 启动 ChatGPT 并验证窗口是否真的显示出来

    用法：
      右键「使用 PowerShell 运行」，
      或在本目录执行：  powershell -ExecutionPolicy Bypass -File ".\启动ChatGPT.ps1"

    参数：
      -EnableSystemProxy  自动打开系统代理，等价于 Clash Verge 首页的「系统代理」开关
      -KeepSystemProxy    脚本结束后保留系统代理设置（默认会还原成运行前的状态）
      -SkipLaunch         只检测和清理，不启动 ChatGPT
      -NoClashStart       不自动拉起 Clash Verge，仅检测

    注意：需在你自己登录的桌面会话中运行（不要用管理员另开一个会话去跑 App）。
#>
[CmdletBinding()]
param(
    [switch]$EnableSystemProxy,
    [switch]$KeepSystemProxy,
    [switch]$SkipLaunch,
    [switch]$NoClashStart
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

$PackageName   = 'OpenAI.Codex'
$ProxyPort     = 7897
$ClashExe      = 'D:\下载\Clash Verge\clash-verge.exe'
$ClashWaitSec  = 60     # 等待 Clash 核心起来的最长时间
$WinWaitSec    = 45     # 等待 ChatGPT 窗口出现的最长时间
$RegKey        = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

$Failed        = @()
$ProxyStateBefore = $null
$ProxyChanged  = $false

# ---------------------------------------------------------------- 输出 helper
function Write-Head($text) {
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
}
function Write-OK  ($t) { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Write-Bad ($t) { Write-Host "  [失败] $t" -ForegroundColor Red }
function Write-Warn($t) { Write-Host "  [注意] $t" -ForegroundColor Yellow }
function Write-Info($t) { Write-Host "  [信息] $t" -ForegroundColor Gray }

# ---------------------------------------------------------------- 工具函数
function Test-Tcp {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 4000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($ComputerName, $Port)
        if ($task.Wait($TimeoutMs) -and $client.Connected) { return $true }
        return $false
    } catch { return $false }
    finally { try { $client.Close() } catch {} }
}

function Get-ProxyState {
    $p = Get-ItemProperty -Path $RegKey -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Enable = if ($null -eq $p.ProxyEnable) { 0 } else { [int]$p.ProxyEnable }
        Server = [string]$p.ProxyServer
    }
}

function Set-ProxyState {
    param([int]$Enable)
    try {
        Set-ItemProperty -Path $RegKey -Name ProxyEnable -Value $Enable -Type DWord -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Get-ClashProcesses {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match 'clash-verge|verge-mihomo|clash-meta|mihomo' }
}

# 通过 HTTP CONNECT 隧道实测代理能否到达目标站点
# 返回 'OK' / 'PROXY_DOWN' / 'NO_RESPONSE' / 'ERROR: ...'
function Test-ProxyTunnel {
    param(
        [string]$ProxyHost = '127.0.0.1',
        [int]$ProxyPort    = 7897,
        [string]$TargetHost = 'chatgpt.com',
        [int]$TargetPort   = 443,
        [int]$TimeoutMs    = 10000
    )
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        if (-not $c.ConnectAsync($ProxyHost, $ProxyPort).Wait(3000)) { return 'PROXY_DOWN' }
        $s = $c.GetStream()
        $s.ReadTimeout = $TimeoutMs
        $s.WriteTimeout = $TimeoutMs
        $req = "CONNECT ${TargetHost}:${TargetPort} HTTP/1.1`r`nHost: ${TargetHost}:${TargetPort}`r`nProxy-Connection: keep-alive`r`n`r`n"
        $b = [System.Text.Encoding]::ASCII.GetBytes($req)
        $s.Write($b, 0, $b.Length)
        $s.Flush()
        $buf = New-Object byte[] 512
        $n = $s.Read($buf, 0, 512)
        if ($n -le 0) { return 'NO_RESPONSE' }
        $resp = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
        $line = ($resp -split "`r`n")[0]
        if ($line -match '^HTTP/\d\.\d\s+200') { return 'OK' }
        return $line
    } catch { return "ERROR: $($_.Exception.Message)" }
    finally { try { $c.Close() } catch {} }
}

function Test-InternetBaseline {
    # 用国内可直连站点确认「本机本身能上网」，用于区分「断网」和「被墙」
    foreach ($h in @('www.baidu.com', 'www.qq.com')) {
        if (Test-Tcp -ComputerName $h -Port 443 -TimeoutMs 3000) { return $true }
    }
    return $false
}

function Wait-WithSpinner {
    param([string]$Label, [int]$TimeoutSec, [scriptblock]$Condition)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $spin = @('|', '/', '-', '\')
    $i = 0
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { Write-Host "`r" -NoNewline; return $true }
        Write-Host "`r  $Label $($spin[$i % 4])  " -NoNewline -ForegroundColor DarkGray
        $i++
        Start-Sleep -Milliseconds 800
    }
    Write-Host "`r" -NoNewline
    return $false
}

# ================================================================ 步骤 1
Write-Head '步骤 1 / 4  检测代理客户端'

$clashProcs = @(Get-ClashProcesses)
if ($clashProcs.Count -gt 0) {
    Write-OK "代理客户端已运行：$(($clashProcs | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')"
} else {
    Write-Warn 'Clash Verge 未运行'
}

if (Test-Tcp -ComputerName '127.0.0.1' -Port $ProxyPort -TimeoutMs 2000) {
    Write-OK "代理端口 127.0.0.1:$ProxyPort 已在监听"
} else {
    Write-Warn "代理端口 127.0.0.1:$ProxyPort 无响应"

    if ($NoClashStart) {
        Write-Info '按 -NoClashStart 要求不自动启动，请手动打开 Clash Verge。'
        $Failed += '代理端口未监听'
    }
    elseif (-not (Test-Path -LiteralPath $ClashExe)) {
        Write-Bad "找不到 Clash Verge：$ClashExe"
        Write-Info '请手动打开你的代理客户端，然后重新运行本脚本。'
        $Failed += '找不到代理客户端'
    }
    else {
        Write-Info "正在启动 Clash Verge：$ClashExe"
        try { Start-Process -FilePath $ClashExe -ErrorAction Stop }
        catch {
            Write-Bad "启动失败：$($_.Exception.Message)"
            $Failed += '代理客户端启动失败'
        }
        if (-not (Wait-WithSpinner -Label '等待 Clash 核心就绪' -TimeoutSec $ClashWaitSec -Condition {
                    Test-Tcp -ComputerName '127.0.0.1' -Port $ProxyPort -TimeoutMs 1500 })) {
            Write-Bad "等待 ${ClashWaitSec}s 后端口仍未监听"
            Write-Info '请手动打开 Clash Verge 并确认已选择一个可用订阅。'
            $Failed += '代理端口未监听'
        } else {
            Write-OK "代理端口 127.0.0.1:$ProxyPort 已就绪"
        }
    }
}

# ================================================================ 步骤 2
Write-Head '步骤 2 / 4  检测系统代理与到 OpenAI 的实际连通性'

# 2a. 代理隧道本身能不能到 OpenAI（决定"开系统代理"是否有意义）
$tunnelOK = $false
if (Test-Tcp -ComputerName '127.0.0.1' -Port $ProxyPort -TimeoutMs 2000) {
    $r1 = Test-ProxyTunnel -TargetHost 'chatgpt.com'
    $r2 = Test-ProxyTunnel -TargetHost 'api.openai.com'
    if ($r1 -eq 'OK' -and $r2 -eq 'OK') {
        $tunnelOK = $true
        Write-OK "代理隧道可达 OpenAI（chatgpt.com / api.openai.com 均 200）"
    } else {
        Write-Bad "代理隧道不通：chatgpt.com=$r1 ; api.openai.com=$r2"
        Write-Info '说明当前节点连不上 OpenAI，换一个节点再试。'
        $Failed += '代理节点到 OpenAI 不通'
    }
} else {
    Write-Warn '代理端口未监听，跳过隧道测试'
}

# 2b. 系统代理开关状态
$ProxyStateBefore = Get-ProxyState
$proxyNowOn = ($ProxyStateBefore.Enable -eq 1)
Write-Host ''
if ($proxyNowOn) {
    $srv = if ($ProxyStateBefore.Server) { $ProxyStateBefore.Server } else { "(未设置 ProxyServer)" }
    Write-OK "系统代理已开启：$srv"
} else {
    Write-Warn '系统代理未开启（ProxyEnable = 0）'

    if ($EnableSystemProxy) {
        if (-not $ProxyStateBefore.Server) {
            # 补上地址，否则开了开关也没有指向
            try { Set-ItemProperty -Path $RegKey -Name ProxyServer -Value "127.0.0.1:$ProxyPort" -ErrorAction Stop } catch {}
        }
        if (Set-ProxyState -Enable 1) {
            $ProxyChanged = $true
            Start-Sleep -Seconds 2
            if ((Get-ProxyState).Enable -eq 1) {
                $proxyNowOn = $true
                Write-OK "已自动开启系统代理：$((Get-ProxyState).Server)"
                if (-not $KeepSystemProxy) {
                    Write-Info '（脚本结束后会还原成原来的关闭状态；如需保留请加 -KeepSystemProxy）'
                }
            } else {
                Write-Bad '写入注册表后 ProxyEnable 仍为 0，可能被安全软件拦截'
            }
        } else {
            Write-Bad '无法写入系统代理设置（注册表被拒绝访问）'
        }
    } else {
        Write-Info 'ChatGPT 是 Store 打包应用，走系统代理设置。两种打开方式：'
        Write-Info '  A. 在 Clash Verge 首页把「系统代理」开关打开'
        Write-Info "  B. 重跑本脚本并加上 -EnableSystemProxy 参数，让脚本自动打开"
        Write-Info '若打开后仍连不上，再开「TUN 模式」（需管理员权限装服务）'
    }
}

# 2c. 直连可达性（区分「DNS 污染/被墙」和「彻底断网」）
Write-Host ''
$directOK = $false
$resolvedIP = ''
try {
    $resolvedIP = (Resolve-DnsName -Name 'chatgpt.com' -Type A -ErrorAction SilentlyContinue |
                   Where-Object { $_.IPAddress } |
                   Select-Object -First 1 -ExpandProperty IPAddress)
} catch {}

if (Test-Tcp -ComputerName 'chatgpt.com' -Port 443 -TimeoutMs 5000) {
    $directOK = $true
    Write-OK 'chatgpt.com:443 直连可通'
} else {
    Write-Warn 'chatgpt.com:443 直连超时（在需要代理的网络环境下属正常现象）'
    if ($resolvedIP -match '^(157\.240\.|168\.143\.|31\.13\.|59\.24\.|243\.185\.|8\.7\.)') {
        Write-Info "解析结果 $resolvedIP 不是 OpenAI 的真实 IP —— 属于 DNS 污染"
    }
}

# 2d. 综合判断：ChatGPT 实际能不能连上
Write-Host ''
if ($directOK) {
    Write-OK '网络可达 OpenAI，应可正常启动'
}
elseif ($tunnelOK -and $proxyNowOn) {
    Write-OK '代理隧道正常，且系统代理已开启 —— ChatGPT 可经代理连接'
    Write-Info '提示：若想让所有应用都不必单独配代理，可在 Clash Verge 开启「TUN 模式」。'
}
elseif ($tunnelOK) {
    Write-Bad '代理节点没问题，但 ChatGPT 拿不到可用通道。'
    Write-Info '请开启「系统代理」或「TUN 模式」后重跑本脚本。'
    $Failed += '系统代理未开启，ChatGPT 无法联网'
}
elseif (-not (Test-InternetBaseline)) {
    Write-Bad '本机连国内站点也不通 —— 这是网络本身断了，不是被墙。'
    Write-Info '请先恢复网络，再重新运行本脚本。'
    $Failed += '本机无网络'
}
else {
    Write-Bad '既连不上 OpenAI，代理隧道也不通。'
    Write-Info '请在 Clash Verge 的「代理」页换一个节点，确认延迟正常后再试。'
    $Failed += '代理节点到 OpenAI 不通'
}

# ================================================================ 步骤 3
Write-Head '步骤 3 / 4  清理卡死的 ChatGPT 进程'

$stuck = @(Get-Process ChatGPT -ErrorAction SilentlyContinue)
if ($stuck.Count -eq 0) {
    Write-OK '没有残留的 ChatGPT 进程'
} else {
    Write-Warn "发现 $($stuck.Count) 个 ChatGPT 进程，正在结束…"
    $stuck | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $left = @(Get-Process ChatGPT -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) { Write-OK '已全部清理' }
    else { Write-Warn "仍有 $($left.Count) 个进程未退出（可能被其它会话占用）" }
}

# ================================================================ 步骤 4
if ($SkipLaunch) {
    Write-Head '步骤 4 / 4  已按 -SkipLaunch 跳过启动'
} else {
    Write-Head '步骤 4 / 4  启动 ChatGPT 并验证窗口'

    $pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
    if (-not $pkg) {
        Write-Bad "未找到 Store 包 $PackageName —— ChatGPT 可能没装好"
        Write-Info '请在 Microsoft Store 搜索 ChatGPT 安装，或从 chatgpt.com 重新下载官方安装器。'
        $Failed += '未找到 ChatGPT 包'
    } else {
        $aumid = "$($pkg.PackageFamilyName)!App"
        Write-Info "包　：$($pkg.PackageFullName)"
        Write-Info "入口：$aumid"

        Start-Process "shell:AppsFolder\$aumid" -ErrorAction SilentlyContinue

        $shown = Wait-WithSpinner -Label '等待窗口出现' -TimeoutSec $WinWaitSec -Condition {
            $null -ne (Get-Process ChatGPT -ErrorAction SilentlyContinue |
                       Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1)
        }

        if ($shown) {
            Write-OK 'ChatGPT 窗口已显示，启动成功'
            Write-Info '若没看到窗口，检查一下任务栏是否被最小化。'
        } else {
            $procs = @(Get-Process ChatGPT -ErrorAction SilentlyContinue)
            Write-Bad "等待 ${WinWaitSec}s 后窗口仍未出现（进程数：$($procs.Count)）"
            if ($procs.Count -gt 0) {
                Write-Info '进程在跑却不弹窗 —— 基本可以确定还是网络没通。'
                Write-Info '请先解决步骤 2 的连通性问题，再重新运行本脚本。'
            }
            $Failed += '窗口未显示'
        }
    }
}

# ================================================================ 还原系统代理
if ($ProxyChanged -and -not $KeepSystemProxy) {
    Write-Host ''
    if (Set-ProxyState -Enable $ProxyStateBefore.Enable) {
        Write-Info '已把系统代理还原成运行前的状态'
    } else {
        Write-Warn '还原系统代理失败，请手动在 Clash Verge 里调整'
    }
}

# ================================================================ 汇总
Write-Head '结果汇总'
if ($Failed.Count -eq 0) {
    Write-Host '  全部通过' -ForegroundColor Green
    Write-Host ''
} else {
    $uniq = @($Failed | Select-Object -Unique)
    Write-Host "  存在 $($uniq.Count) 个问题：" -ForegroundColor Yellow
    $uniq | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  最常见原因：代理没开 → 开启「系统代理」或「TUN 模式」后重跑本脚本。' -ForegroundColor Gray
    Write-Host "  小技巧：加 -EnableSystemProxy 让脚本自动打开系统代理。" -ForegroundColor Gray
    Write-Host ''
}

if (-not $env:DSH_NO_PAUSE) {
    Read-Host '按回车键退出'
}
