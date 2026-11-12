#Requires -Version 5.1
<#
.SYNOPSIS
在 Windows 上启动 VideoTrace 前端（Vue 3 + Vite，默认 http://localhost:5173）。

.PARAMETER SkipInstall
跳过 npm ci，适用于依赖已安装、只想重启开发服务的场景。

.EXAMPLE
.\scripts\start-client.ps1

.EXAMPLE
.\scripts\start-client.ps1 -SkipInstall
#>

param(
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $RootDir '.env'

if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
    throw "找不到 $EnvFile，请先运行 scripts/dev-up.ps1 生成配置模板"
}

. (Join-Path $PSScriptRoot 'load-env.ps1')
Import-DotEnv -Path $EnvFile

Push-Location -LiteralPath (Join-Path $RootDir 'client')
try {
    if (-not $SkipInstall) {
        Write-Host '安装前端依赖（npm ci）' -ForegroundColor Cyan
        & npm ci --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw "npm ci 失败" }
    }

    Write-Host '启动前端：http://localhost:5173' -ForegroundColor Cyan
    & npm run dev
}
finally {
    Pop-Location
}
