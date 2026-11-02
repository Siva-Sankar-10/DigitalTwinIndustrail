$projectPath = "C:\Users\shiva\Desktop\twinguard_edge"
$pythonPath = Join-Path $projectPath "backend\venv\Scripts\python.exe"

if (-not (Test-Path $pythonPath)) {
    exit 1
}

$listener = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($listener) {
    exit 0
}

$logPath = Join-Path $projectPath "backend\logs"
New-Item -ItemType Directory -Path $logPath -Force | Out-Null

Start-Process -FilePath $pythonPath `
    -ArgumentList @(
        "-m", "uvicorn",
        "app.main:app",
        "--app-dir", "backend",
        "--host", "127.0.0.1",
        "--port", "8000"
    ) `
    -WorkingDirectory $projectPath `
    -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $logPath "uvicorn.log") `
    -RedirectStandardError (Join-Path $logPath "uvicorn-error.log")
