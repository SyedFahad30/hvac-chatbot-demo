<#
.SYNOPSIS
  Points hvac-chat-widget.js at your live API Gateway endpoint after
  deploy-hvac.ps1 prints it out.

.USAGE
  .\update-hvac-widget-endpoint.ps1 -Endpoint "https://xxxxx.execute-api.us-east-1.amazonaws.com/"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Endpoint
)

$WidgetFile = ".\hvac-chat-widget.js"
$DashboardFile = ".\hvac-dashboard.html"

if (Test-Path $WidgetFile) {
    Copy-Item $WidgetFile "$WidgetFile.bak"
    $content = Get-Content $WidgetFile -Raw
    $updated = $content -replace 'apiEndpoint:\s*"[^"]*",', "apiEndpoint: `"$Endpoint`","
    Set-Content -Path $WidgetFile -Value $updated -NoNewline
    Write-Host "Updated $WidgetFile to call: $Endpoint"
} else {
    Write-Host "$WidgetFile not found, skipping." -ForegroundColor Yellow
}

if (Test-Path $DashboardFile) {
    Copy-Item $DashboardFile "$DashboardFile.bak"
    $content = Get-Content $DashboardFile -Raw
    $updated = $content -replace 'const API_ENDPOINT = "[^"]*";', "const API_ENDPOINT = `"$Endpoint`";"
    Set-Content -Path $DashboardFile -Value $updated -NoNewline
    Write-Host "Updated $DashboardFile to call: $Endpoint"
} else {
    Write-Host "$DashboardFile not found, skipping." -ForegroundColor Yellow
}

Write-Host "(backups saved as *.bak)"
