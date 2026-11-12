#Requires -Version 5.1
<#
.SYNOPSIS
停止 VideoTrace 本地中间件，但保留数据目录与命名卷。

.PARAMETER RemoveVolumes
同时删除 RocketMQ 的命名卷（rocketmq-store / rocketmq-logs）。
mysql/data、redis/data、minio/data、qdrant/data 属于绑定挂载，本参数不会删除它们。

.EXAMPLE
.\scripts\dev-down.ps1

.EXAMPLE
.\scripts\dev-down.ps1 -RemoveVolumes
#>

param(
    [switch]$RemoveVolumes
)

$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $RootDir '.env'

if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
    throw "找不到 $EnvFile"
}

Push-Location -LiteralPath $RootDir
try {
    $arguments = @('compose', '--env-file', $EnvFile, 'down')
    if ($RemoveVolumes) { $arguments += '--volumes' }

    & docker @arguments
    if ($LASTEXITCODE -ne 0) { throw "docker compose down 失败" }

    Write-Host '中间件已停止。' -ForegroundColor Green
    if ($RemoveVolumes) {
        Write-Host 'RocketMQ 命名卷已删除；数据目录（mysql/redis/minio/qdrant）仍保留在项目内。' -ForegroundColor Yellow
    }
}
finally {
    Pop-Location
}
