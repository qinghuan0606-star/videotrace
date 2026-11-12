#Requires -Version 5.1
<#
.SYNOPSIS
在 Windows 上启动 VideoTrace 后端（Spring Boot，默认 http://localhost:9090）。

.DESCRIPTION
先把项目根目录的 .env 载入当前进程环境变量，再在 server 目录执行 mvnw.cmd。

.EXAMPLE
.\scripts\start-server.ps1
#>

$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $RootDir '.env'

if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
    throw "找不到 $EnvFile，请先运行 scripts/dev-up.ps1 生成配置模板"
}

. (Join-Path $PSScriptRoot 'load-env.ps1')
Import-DotEnv -Path $EnvFile

Push-Location -LiteralPath (Join-Path $RootDir 'server')
try {
    Write-Host '启动后端：http://localhost:9090（健康检查 /health）' -ForegroundColor Cyan
    & cmd /c mvnw.cmd spring-boot:run
}
finally {
    Pop-Location
}
