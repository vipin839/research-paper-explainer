# Research Paper Explainer - launcher
# Usage:  .\run.ps1          (local only)
#         .\run.ps1 -Share   (also create a public gradio.live link)

param([switch]$Share)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

if (-not $env:NVIDIA_API_KEY) {
    Write-Host ""
    Write-Host "NVIDIA_API_KEY is not set for this terminal." -ForegroundColor Yellow
    $key = Read-Host "Paste your NVIDIA API key (starts with nvapi-)"
    $env:NVIDIA_API_KEY = $key.Trim()
}

if (-not $env:NVIDIA_API_KEY.StartsWith("nvapi-")) {
    Write-Host "That key does not start with 'nvapi-'. Check it and try again." -ForegroundColor Red
    exit 1
}

if ($Share) { $env:GRADIO_SHARE = "1" } else { $env:GRADIO_SHARE = "" }

Write-Host ""
Write-Host "Starting Research Paper Explainer..." -ForegroundColor Green
Write-Host ""

& "$PSScriptRoot\.venv\Scripts\python.exe" app.py
