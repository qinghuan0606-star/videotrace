#Requires -Version 5.1
<#
.SYNOPSIS
启动 VideoTrace 本地开发所需的中间件（MySQL、Redis、MinIO、Qdrant、RocketMQ）。
与 scripts/dev-up.sh 行为一致，供 Windows 本机使用。

.DESCRIPTION
依次完成：必需命令检查、.env 校验、JDK/Node 版本检查、Compose 配置校验、
RocketMQ 卷属主修正、中间件启动与健康检查、分析主题创建。

.EXAMPLE
.\scripts\dev-up.ps1
#>

$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $RootDir '.env'

function Wait-Service {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers = @{},
        [int]$Attempts = 20
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $null = Invoke-WebRequest -Uri $Uri -Headers $Headers -TimeoutSec 5 -UseBasicParsing
            return
        }
        catch {
            if ($i -eq $Attempts) { throw "服务未就绪：$Uri（最后一次错误：$($_.Exception.Message)）" }
            Start-Sleep -Seconds 1
        }
    }
}

Push-Location -LiteralPath $RootDir
try {
    . (Join-Path $PSScriptRoot 'load-env.ps1')

    Write-Host '[1/6] 检查必需命令' -ForegroundColor Cyan
    foreach ($command in @('docker', 'java', 'node', 'ffmpeg', 'tesseract')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "缺少必需命令：$command"
        }
    }

    Write-Host '[2/6] 校验 .env' -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
        Copy-Item -LiteralPath (Join-Path $RootDir '.env.example') -Destination $EnvFile
        Write-Host "已生成 .env。请填写 SILICONFLOW_API_KEY、替换示例密码，然后重新运行本脚本。" -ForegroundColor Yellow
        return
    }

    Import-DotEnv -Path $EnvFile

    foreach ($name in @('DB_PASSWORD', 'MYSQL_ROOT_PASSWORD', 'REDIS_PASSWORD', 'MINIO_SECRET_KEY', 'QDRANT_API_KEY', 'SILICONFLOW_API_KEY')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith('change-')) {
            throw "请在 .env 中为 $name 设置非示例值"
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $RootDir 'mysql/data/mysql'))) {
        $dbUser = [Environment]::GetEnvironmentVariable('DB_USERNAME', 'Process')
        $appUser = [Environment]::GetEnvironmentVariable('MYSQL_APP_USER', 'Process')
        if ([string]::IsNullOrWhiteSpace($appUser)) { $appUser = 'videotrace' }
        if ($dbUser -ne $appUser) {
            throw "全新数据库要求 DB_USERNAME 与 MYSQL_APP_USER 一致（当前：$dbUser / $appUser）"
        }
    }

    Write-Host '[3/6] 检查 JDK 与 Node 版本' -ForegroundColor Cyan
    $javaRaw = (& java -version 2>&1 | Out-String)
    $javaMatch = [regex]::Match($javaRaw, 'version "([^"]+)"')
    if (-not $javaMatch.Success) { throw "无法解析 java -version 输出：$javaRaw" }
    $javaVersion = $javaMatch.Groups[1].Value
    $javaMajor = ($javaVersion -split '.')[0]
    if ($javaMajor -eq '1') { $javaMajor = ($javaVersion -split '.')[1] }
    if ([int]$javaMajor -lt 21) { throw "需要 JDK 21 及以上，当前为 $javaVersion" }

    $nodeVersion = (& node --version) -replace '^v', ''
    $nodeMajor = [int](($nodeVersion -split '.')[0])
    if ($nodeMajor -lt 22) { throw "需要 Node.js 22 及以上，当前为 $nodeVersion" }

    Write-Host '[4/6] 校验 Docker 与 Compose 配置' -ForegroundColor Cyan
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw "无法连接 Docker 守护进程，请先启动 Docker Desktop" }

    & docker compose --env-file $EnvFile config --quiet
    if ($LASTEXITCODE -ne 0) { throw "docker compose 配置校验未通过（上方为具体报错）" }
    $compose = @('docker', 'compose', '--env-file', $EnvFile)

    Write-Host '[5/6] 启动中间件' -ForegroundColor Cyan
    # RocketMQ 以 uid 3000 运行，首次创建的命名卷属主是 root，会导致 broker 无法写
    # commitlog 与日志而退出（exit 253）。启动前先修正属主，对已修正过的卷是幂等的。
    & docker @compose run --rm --no-deps --user root --entrypoint sh rmqbroker -c 'mkdir -p /home/rocketmq/store /home/rocketmq/logs && chown -R 3000:3000 /home/rocketmq/store /home/rocketmq/logs'
    if ($LASTEXITCODE -ne 0) { throw "修正 RocketMQ 卷属主失败" }

    & docker @compose up --wait --wait-timeout 120
    if ($LASTEXITCODE -ne 0) { throw "中间件启动失败或超时" }

    Wait-Service -Uri 'http://127.0.0.1:6333/healthz' -Headers @{ 'api-key' = [Environment]::GetEnvironmentVariable('QDRANT_API_KEY', 'Process') }
    Wait-Service -Uri 'http://127.0.0.1:9000/minio/health/live'

    Write-Host '等待 RocketMQ broker 注册' -ForegroundColor Cyan
    $brokerReady = $false
    for ($i = 1; $i -le 30; $i++) {
        $clusterList = (& docker @compose exec -T rmqbroker sh -c '$ROCKETMQ_HOME/bin/mqadmin clusterList -n rmqnamesrv:9876' 2>$null | Out-String)
        if ($clusterList -match 'broker-a') { $brokerReady = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $brokerReady) { throw "RocketMQ broker 未在预期时间内注册" }

    Write-Host '[6/6] 创建分析主题' -ForegroundColor Cyan
    $topics = @()
    $analysisTopic = [Environment]::GetEnvironmentVariable('ROCKETMQ_ANALYSIS_TOPIC', 'Process')
    if ([string]::IsNullOrWhiteSpace($analysisTopic)) { $analysisTopic = 'video-analysis-topic' }
    $topics += $analysisTopic
    $deadTopic = [Environment]::GetEnvironmentVariable('ROCKETMQ_ANALYSIS_DEAD_TOPIC', 'Process')
    if ([string]::IsNullOrWhiteSpace($deadTopic)) { $deadTopic = 'video-analysis-dead-topic' }
    $topics += $deadTopic

    foreach ($topic in $topics) {
        $updateCommand = '$ROCKETMQ_HOME/bin/mqadmin updateTopic -n rmqnamesrv:9876 -c DefaultCluster -t {0}' -f $topic
        & docker @compose exec -T rmqbroker sh -c $updateCommand *> $null
        if ($LASTEXITCODE -ne 0) { throw "创建 RocketMQ 主题失败：$topic" }
        Write-Host "  RocketMQ 主题就绪：$topic" -ForegroundColor Green
    }

    & docker @compose ps

    Write-Host ''
    Write-Host '中间件已就绪。启动后端：' -ForegroundColor Green
    Write-Host '  .\scripts\start-server.ps1'
    Write-Host '启动前端：'
    Write-Host '  .\scripts\start-client.ps1'
}
finally {
    Pop-Location
}
