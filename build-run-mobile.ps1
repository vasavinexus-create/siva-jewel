[CmdletBinding()]
param(
    [string]$JavaHome,
    [string]$AndroidSdk,
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
$originalJavaHome = $env:JAVA_HOME
$originalAndroidHome = $env:ANDROID_HOME
$androidDirectory = Join-Path $PSScriptRoot 'android'
$apk = Join-Path $androidDirectory 'app\build\outputs\apk\debug\app-debug.apk'

if (-not $JavaHome) {
    $studioJdk = Join-Path $env:ProgramFiles 'Android\Android Studio\jbr'
    $JavaHome = if (Test-Path -LiteralPath (Join-Path $studioJdk 'bin\java.exe')) {
        $studioJdk
    } else {
        $env:JAVA_HOME
    }
}
if (-not $JavaHome -or -not (Test-Path -LiteralPath (Join-Path $JavaHome 'bin\java.exe'))) {
    throw 'Set JAVA_HOME or pass -JavaHome with the path to JDK 21.'
}

if (-not $AndroidSdk) {
    $AndroidSdk = $env:ANDROID_HOME
    if (-not $AndroidSdk) { $AndroidSdk = $env:ANDROID_SDK_ROOT }
    if (-not $AndroidSdk) { $AndroidSdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
}
if (-not (Test-Path -LiteralPath $AndroidSdk -PathType Container)) {
    throw 'Set ANDROID_HOME or pass -AndroidSdk with the path to the Android SDK.'
}

Push-Location -LiteralPath $PSScriptRoot
try {
    $env:JAVA_HOME = (Resolve-Path -LiteralPath $JavaHome).Path
    $env:ANDROID_HOME = (Resolve-Path -LiteralPath $AndroidSdk).Path

    if (-not (Test-Path -LiteralPath 'node_modules\.bin\cap.cmd') -or
        -not (Test-Path -LiteralPath 'node_modules\.bin\vite.cmd')) {
        $installArgs = @('ci')
        if ($Offline) { $installArgs += '--offline' }
        & npm.cmd @installArgs
        if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit code $LASTEXITCODE." }
    }

    & npm.cmd run android
    if ($LASTEXITCODE -ne 0) { throw "Web build or Capacitor sync failed with exit code $LASTEXITCODE." }

    # Annotation extraction is unnecessary for this debug APK and requires
    # separate lint downloads for the Capacitor libraries.
    $gradleArgs = @(
        ':app:assembleDebug', '--console=plain',
        '-x', ':capacitor-android:extractDebugAnnotations',
        '-x', ':capacitor-camera:extractDebugAnnotations',
        '-x', ':capacitor-cordova-android-plugins:extractDebugAnnotations'
    )
    if ($Offline) { $gradleArgs += '--offline' }

    Push-Location -LiteralPath $androidDirectory
    try {
        & .\gradlew.bat @gradleArgs
        if ($LASTEXITCODE -ne 0) { throw "Android build failed with exit code $LASTEXITCODE." }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) { throw 'The debug APK was not found.' }
    Write-Host "Android debug APK: $apk"
} finally {
    $env:JAVA_HOME = $originalJavaHome
    $env:ANDROID_HOME = $originalAndroidHome
    Pop-Location
}
