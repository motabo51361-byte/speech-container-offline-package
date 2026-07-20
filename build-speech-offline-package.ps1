# Version: 20260720
# build-speech-offline-package.ps1
# One-click offline package builder for Azure AI Speech disconnected containers.
# - Supports speech-to-text, custom-speech-to-text, and neural-text-to-speech.
# - Pulls and saves the selected MCR image.
# - Downloads the disconnected container license.
# - For custom speech to text, optionally downloads the custom/base model first.
# - Generates run-disconnected-container-docker-compose.yaml.
# - Packages image tar, license, optional models, compose, and logs into tar.gz.
# - Prints SHA256 and writes a locale-specific checksum file for speech-to-text.

[CmdletBinding()]
param(
  [ValidateSet("speech-to-text", "custom-speech-to-text", "neural-text-to-speech")]
  [string]$Container,

  [string]$Tag = "latest",
  [string]$Image,

  [string]$LicenseEndpointUri,
  [string]$ModelEndpointUri,
  [string]$ModelId,

  [string]$Memory,
  [string]$Cpus,
  [int]$Port = 5000,

  [int]$LicenseDownloadTimeoutMinutes = 15,
  [int]$ModelDownloadTimeoutMinutes = 60,

  [switch]$SkipCustomModelDownload,
  [switch]$KeepDockerImage,
  [switch]$Help
)

$ErrorActionPreference = "Stop"
$scriptStartTime = Get-Date

if ($Help) {
@'
Usage:
  .\build-speech-offline-package.ps1
  .\build-speech-offline-package.ps1 -Container speech-to-text -Tag latest
  .\build-speech-offline-package.ps1 -Container neural-text-to-speech -Tag 3.11.0-amd64-en-us-arianeural
  .\build-speech-offline-package.ps1 -Container custom-speech-to-text -ModelId <model-id>

Optional environment variables:
  SPEECH_LICENSE_KEY
  SPEECH_LICENSE_ENDPOINT_URI
  SPEECH_MODEL_KEY                 # custom-speech-to-text model download only
  SPEECH_MODEL_ENDPOINT_URI        # custom-speech-to-text model download only

Notes:
  - The license resource must be approved for disconnected containers and use the
    disconnected commitment tier.
  - custom-speech-to-text needs a regular Speech resource for model download and
    a disconnected commitment resource for license/runtime.
  - Speech language identification is not included because Microsoft documents it
    as not available as a disconnected container.
  - Interactive speech-to-text mode queries MCR for the latest stable zh-TW and
    en-US tags. Pass -Tag to skip the lookup.
'@ | Write-Host
  exit 0
}

Write-Host "========================================"
Write-Host ("Script started at : {0}" -f $scriptStartTime.ToString("yyyy-MM-dd HH:mm:ss"))
Write-Host "========================================"

# ===========================
# Container specs
# ===========================
$ContainerSpecs = @{
  "speech-to-text" = [ordered]@{
    DisplayName = "Speech to text"
    ImageRepository = "mcr.microsoft.com/azure-cognitive-services/speechservices/speech-to-text"
    ServiceName = "azure-ai-speech-stt"
    ContainerName = "azure-ai-speech-stt"
    PackageSlug = "azure-ai-speech-to-text"
    ImageTarName = "oci-azure-ai-speech-to-text.tar"
    DefaultMemory = "8g"
    DefaultCpus = "4"
    HostProtocol = "ws"
    NeedsCustomModel = $false
  }
  "custom-speech-to-text" = [ordered]@{
    DisplayName = "Custom speech to text"
    ImageRepository = "mcr.microsoft.com/azure-cognitive-services/speechservices/custom-speech-to-text"
    ServiceName = "azure-ai-speech-custom-stt"
    ContainerName = "azure-ai-speech-custom-stt"
    PackageSlug = "azure-ai-custom-speech-to-text"
    ImageTarName = "oci-azure-ai-custom-speech-to-text.tar"
    DefaultMemory = "8g"
    DefaultCpus = "4"
    HostProtocol = "ws"
    NeedsCustomModel = $true
  }
  "neural-text-to-speech" = [ordered]@{
    DisplayName = "Neural text to speech"
    ImageRepository = "mcr.microsoft.com/azure-cognitive-services/speechservices/neural-text-to-speech"
    ServiceName = "azure-ai-speech-ntts"
    ContainerName = "azure-ai-speech-ntts"
    PackageSlug = "azure-ai-neural-text-to-speech"
    ImageTarName = "oci-azure-ai-neural-text-to-speech.tar"
    DefaultMemory = "16g"
    DefaultCpus = "8"
    HostProtocol = "http"
    NeedsCustomModel = $false
  }
}

# ===========================
# Helper functions
# ===========================
function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function Fail([string]$Message, [int]$Code = 1) {
  $now = Get-Date
  $elapsed = $now - $scriptStartTime
  Write-Host "ERROR: $Message"
  Write-Host ("Elapsed time before failure: {0}" -f $elapsed.ToString("hh\:mm\:ss"))
  exit $Code
}

function Read-ContainerChoice {
  Write-Host ""
  Write-Host "Please select Azure AI Speech container:"
  Write-Host "  1) speech-to-text"
  Write-Host "  2) custom-speech-to-text"
  Write-Host "  3) neural-text-to-speech"
  $choice = Read-Host "Container type [1]"
  if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

  switch ($choice.Trim()) {
    "1" { return "speech-to-text" }
    "2" { return "custom-speech-to-text" }
    "3" { return "neural-text-to-speech" }
    "speech-to-text" { return "speech-to-text" }
    "custom-speech-to-text" { return "custom-speech-to-text" }
    "neural-text-to-speech" { return "neural-text-to-speech" }
    default { Fail "Unsupported container type: $choice" }
  }
}

function Get-McrTags([string]$ImageRepository) {
  $repositoryPath = $ImageRepository -replace "^mcr\.microsoft\.com/", ""
  if ($repositoryPath -eq $ImageRepository) {
    throw "Unsupported MCR image repository: $ImageRepository"
  }

  $tagsUri = "https://mcr.microsoft.com/v2/$repositoryPath/tags/list"
  $response = Invoke-RestMethod -Uri $tagsUri -Method Get -TimeoutSec 30
  if ($null -eq $response.tags) {
    throw "MCR returned no tags for $ImageRepository"
  }

  return @($response.tags)
}

function Get-LatestStableSpeechToTextTag([string[]]$Tags, [string]$Locale) {
  $localePattern = [regex]::Escape($Locale.ToLowerInvariant())
  $candidates = @(
    foreach ($candidateTag in $Tags) {
      if ($candidateTag -match "^(\d+\.\d+\.\d+)-amd64-$localePattern$") {
        [pscustomobject]@{
          Tag = [string]$candidateTag
          Version = [version]$Matches[1]
        }
      }
    }
  )

  $latest = $candidates |
    Sort-Object -Property @{ Expression = { $_.Version }; Descending = $true } |
    Select-Object -First 1

  if ($null -eq $latest) {
    throw "No stable amd64 Speech to text tag was found for locale $Locale"
  }

  return [string]$latest.Tag
}

function Read-SpeechToTextTag([string]$ImageRepository) {
  Write-Host ""
  Write-Host "Querying Microsoft Container Registry for Speech to text tags..."

  try {
    $availableTags = @(Get-McrTags $ImageRepository)
    $zhTwTag = Get-LatestStableSpeechToTextTag $availableTags "zh-tw"
    $enUsTag = Get-LatestStableSpeechToTextTag $availableTags "en-us"
  } catch {
    Write-Host ("WARNING: Could not query MCR tags: {0}" -f $_.Exception.Message)
    $fallbackTag = Read-Host "IMAGE_TAG [latest]"
    if ([string]::IsNullOrWhiteSpace($fallbackTag)) { return "latest" }
    return $fallbackTag.Trim()
  }

  Write-Host "Latest stable amd64 tags:"
  Write-Host ("  1) zh-TW  {0}" -f $zhTwTag)
  Write-Host ("  2) en-US  {0}" -f $enUsTag)
  Write-Host "  3) Enter an image tag manually"
  Write-Host "INFO: One locale is packaged per run. Run the script again for the other locale."

  $choice = Read-Host "Speech-to-text locale [1]"
  if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

  switch ($choice.Trim().ToLowerInvariant()) {
    "1" { return $zhTwTag }
    "zh-tw" { return $zhTwTag }
    "2" { return $enUsTag }
    "en-us" { return $enUsTag }
    "3" {
      $manualTag = Read-Host "IMAGE_TAG"
      if ([string]::IsNullOrWhiteSpace($manualTag)) { Fail "IMAGE_TAG is empty" }
      return $manualTag.Trim()
    }
    default { Fail "Unsupported Speech-to-text locale choice: $choice" }
  }
}

function Get-SpeechToTextLocaleFromImage([string]$ImageRef) {
  $tagSeparatorIndex = $ImageRef.LastIndexOf(":")
  if ($tagSeparatorIndex -lt 0 -or $tagSeparatorIndex -eq ($ImageRef.Length - 1)) {
    return $null
  }

  $imageTag = $ImageRef.Substring($tagSeparatorIndex + 1).ToLowerInvariant()
  if ($imageTag -eq "latest") {
    return "en-us"
  }

  $imageTagWithoutPrerelease = $imageTag -replace "-preview$", ""
  if ($imageTagWithoutPrerelease -match "^\d+\.\d+\.\d+-[^-]+-(?<locale>[a-z]{2,3}-[a-z]{2}(?:-[a-z]+)?)$") {
    return $Matches["locale"].ToLowerInvariant()
  }

  return $null
}

function ConvertFrom-SecureStringToPlain([securestring]$Secure) {
  $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try {
    return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
  } finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
  }
}

function Read-Secret([string]$Prompt, [string]$EnvName) {
  $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
  if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
    Write-Host ("{0}: using value from environment variable {1}" -f $Prompt, $EnvName)
    return $fromEnv
  }

  $secure = Read-Host "$Prompt (will not be echoed)" -AsSecureString
  $plain = ConvertFrom-SecureStringToPlain $secure
  if ([string]::IsNullOrWhiteSpace($plain)) { Fail "$Prompt is empty" }
  return $plain
}

function Read-Value([string]$Prompt, [string]$CurrentValue, [string]$EnvName) {
  if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) { return $CurrentValue }

  $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
  if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
    Write-Host ("{0}: using value from environment variable {1}" -f $Prompt, $EnvName)
    return $fromEnv
  }

  $value = Read-Host $Prompt
  if ([string]::IsNullOrWhiteSpace($value)) { Fail "$Prompt is empty" }
  return $value
}

function Test-EndpointReachable([string]$Uri) {
  try {
    $u = [Uri]$Uri
    if ($u.Scheme -ne "https") {
      return @{ Ok = $false; Detail = "Endpoint must be https://" }
    }

    $req = [System.Net.HttpWebRequest]::Create($u)
    $req.Method = "HEAD"
    $req.Timeout = 10000

    try {
      $resp = $req.GetResponse()
      $code = [int]$resp.StatusCode
      $resp.Close()
      return @{ Ok = $true; Detail = "Reachable (HTTP $code)" }
    } catch [System.Net.WebException] {
      if ($_.Exception.Response) {
        $code = [int]$_.Exception.Response.StatusCode
        return @{ Ok = $true; Detail = "Reachable (HTTP $code)" }
      }
      return @{ Ok = $false; Detail = $_.Exception.Message }
    }
  } catch {
    return @{ Ok = $false; Detail = $_.Exception.Message }
  }
}

function Invoke-DockerCapture([string[]]$ArgumentList, [string]$LogPath, [string]$StepName) {
  Write-Host $StepName
  "===== $StepName =====" | Out-File -FilePath $LogPath -Encoding utf8 -Append
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = & docker @ArgumentList 2>&1
    $exit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  $output | Out-File -FilePath $LogPath -Encoding utf8 -Append
  if ($exit -ne 0) {
    Fail "$StepName failed. See log: $LogPath" $exit
  }
  return $output
}

function Remove-DockerContainerQuiet([string]$Name) {
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "SilentlyContinue"
    & docker rm -f $Name 2>&1 | Out-Null
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
}

function Append-DockerLogs([string]$Name, [string]$LogPath) {
  "===== docker logs $Name =====" | Out-File -FilePath $LogPath -Encoding utf8 -Append
  $logs = & docker logs $Name 2>&1
  $logs | Out-File -FilePath $LogPath -Encoding utf8 -Append
}

function Wait-ForLicense([string]$ContainerName, [string]$LicenseDir, [string]$LogPath, [int]$TimeoutMinutes) {
  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  while ((Get-Date) -lt $deadline) {
    $licenseFiles = Get-ChildItem -LiteralPath $LicenseDir -Recurse -File -ErrorAction SilentlyContinue
    if ($licenseFiles) {
      Append-DockerLogs $ContainerName $LogPath
      Remove-DockerContainerQuiet $ContainerName
      return
    }

    $running = (& docker inspect -f "{{.State.Running}}" $ContainerName 2>$null)
    if ($LASTEXITCODE -ne 0) {
      Start-Sleep -Seconds 3
      continue
    }

    if ($running -eq "false") {
      Append-DockerLogs $ContainerName $LogPath
      Remove-DockerContainerQuiet $ContainerName
      $licenseFiles = Get-ChildItem -LiteralPath $LicenseDir -Recurse -File -ErrorAction SilentlyContinue
      if ($licenseFiles) { return }
      Fail "License download container exited, but no license file was found. See log: $LogPath"
    }

    Start-Sleep -Seconds 5
  }

  Append-DockerLogs $ContainerName $LogPath
  Remove-DockerContainerQuiet $ContainerName
  Fail "License download timed out after $TimeoutMinutes minutes. See log: $LogPath"
}

function Wait-ForReadyEndpoint([int]$Port, [string]$ContainerName, [string]$LogPath, [int]$TimeoutMinutes) {
  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  $readyUri = "http://localhost:$Port/ready"

  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -Uri $readyUri -UseBasicParsing -TimeoutSec 5
      if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300) {
        Append-DockerLogs $ContainerName $LogPath
        return
      }
    } catch {
      $running = (& docker inspect -f "{{.State.Running}}" $ContainerName 2>$null)
      if ($LASTEXITCODE -eq 0 -and $running -eq "false") {
        Append-DockerLogs $ContainerName $LogPath
        Fail "Model download container exited before /ready succeeded. See log: $LogPath"
      }
    }

    Start-Sleep -Seconds 10
  }

  Append-DockerLogs $ContainerName $LogPath
  Fail "Model download did not become ready after $TimeoutMinutes minutes. See log: $LogPath"
}

function Write-RuntimeCompose(
  [string]$Path,
  [object]$Spec,
  [string]$ImageRef,
  [string]$MemoryValue,
  [string]$CpuValue,
  [int]$HostPort
) {
  $modelVolume = ""
  $modelComment = ""

  if ($Spec.NeedsCustomModel) {
    $modelVolume = "      - ./azure-ai-speech/models:/usr/local/models`n"
    $modelComment = "      # Custom speech models are loaded from /usr/local/models.`n"
  }

  @"
---
networks:
  speech-network:
    driver: bridge

services:
  $($Spec.ServiceName):
    container_name: $($Spec.ContainerName)
    image: $ImageRef
    restart: always
    environment:
      eula: accept
      "Mounts:License": "/license"
      "Mounts:Output": "/output"
      "Logging:Console:LogLevel:Default": "Information"
$modelComment    volumes:
      - ./azure-ai-speech/license:/license
      - ./azure-ai-speech/output:/output
$modelVolume    ports:
      - "$HostPort`:5000"
    mem_limit: $MemoryValue
    cpus: "$CpuValue"
    networks:
      - speech-network
"@ | Out-File -FilePath $Path -Encoding utf8 -Force
}

# ===========================
# Prompt for required inputs
# ===========================
if ([string]::IsNullOrWhiteSpace($Container)) {
  $Container = Read-ContainerChoice
}
$spec = $ContainerSpecs[$Container]

Write-Host ""
Write-Host ("Selected container : {0}" -f $Container)
Write-Host ("Image repository   : {0}" -f $spec.ImageRepository)

if ([string]::IsNullOrWhiteSpace($Image)) {
  if (-not $PSBoundParameters.ContainsKey("Tag")) {
    if ($Container -eq "speech-to-text") {
      $Tag = Read-SpeechToTextTag $spec.ImageRepository
    } else {
      $tagInput = Read-Host "IMAGE_TAG [latest]"
      if (-not [string]::IsNullOrWhiteSpace($tagInput)) { $Tag = $tagInput.Trim() }
    }
  }
  $Image = "$($spec.ImageRepository):$Tag"
}

if ([string]::IsNullOrWhiteSpace($Memory)) { $Memory = $spec.DefaultMemory }
if ([string]::IsNullOrWhiteSpace($Cpus)) { $Cpus = $spec.DefaultCpus }

Write-Host ("Image              : {0}" -f $Image)
Write-Host ("Runtime resources  : memory={0}, cpus={1}, port={2}:5000" -f $Memory, $Cpus, $Port)

Write-Host ""
Write-Host "Please input disconnected Speech resource settings for license/runtime:"
$LicenseKey = Read-Secret "SPEECH_LICENSE_KEY" "SPEECH_LICENSE_KEY"
$LicenseEndpointUri = Read-Value "SPEECH_LICENSE_ENDPOINT_URI (https://xxx.cognitiveservices.azure.com)" $LicenseEndpointUri "SPEECH_LICENSE_ENDPOINT_URI"

$ModelKey = $null
if ($spec.NeedsCustomModel -and -not $SkipCustomModelDownload) {
  Write-Host ""
  Write-Host "Please input regular Speech resource settings for custom model download:"
  $ModelKey = Read-Secret "SPEECH_MODEL_KEY" "SPEECH_MODEL_KEY"
  $ModelEndpointUri = Read-Value "SPEECH_MODEL_ENDPOINT_URI (https://xxx.cognitiveservices.azure.com)" $ModelEndpointUri "SPEECH_MODEL_ENDPOINT_URI"
  $ModelId = Read-Value "MODEL_ID (custom or base speech model ID)" $ModelId "SPEECH_MODEL_ID"
}

if ($spec.NeedsCustomModel -and $SkipCustomModelDownload) {
  Write-Host "INFO: SkipCustomModelDownload is set. Existing files under azure-ai-speech\models will be packaged."
}

# ===========================
# Preflight check
# ===========================
Write-Host ""
Write-Host "====================="
Write-Host "PREFLIGHT CHECK"
Write-Host "====================="

& docker version | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "docker version failed. Is Docker running?" $LASTEXITCODE }
Write-Host "Docker version: OK"

& tar --version | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "tar command is unavailable" $LASTEXITCODE }
Write-Host "tar command: OK"

$pre = Test-EndpointReachable $LicenseEndpointUri
if (-not $pre.Ok) { Fail "License endpoint check failed: $($pre.Detail)" }
Write-Host ("License endpoint check: {0}" -f $pre.Detail)

if ($spec.NeedsCustomModel -and -not $SkipCustomModelDownload) {
  $preModel = Test-EndpointReachable $ModelEndpointUri
  if (-not $preModel.Ok) { Fail "Model endpoint check failed: $($preModel.Detail)" }
  Write-Host ("Model endpoint check: {0}" -f $preModel.Detail)
}

Write-Host "Keys provided: OK"

# ===========================
# Config
# ===========================
$WorkRoot = Join-Path $PWD "azure-ai-speech"
$LicenseDir = Join-Path $WorkRoot "license"
$OutputDir = Join-Path $WorkRoot "output"
$ModelsDir = Join-Path $WorkRoot "models"
$ArchiveDir = Join-Path $PWD "archive"

$artifactLocale = $null
$imageTarName = $spec.ImageTarName
$packageSlug = $spec.PackageSlug
$logLocaleSuffix = ""
$shaFileName = "SHA256SUMS.txt"

if ($Container -eq "speech-to-text") {
  $artifactLocale = Get-SpeechToTextLocaleFromImage $Image
  if (-not [string]::IsNullOrWhiteSpace($artifactLocale)) {
    $imageTarName = "oci-azure-ai-speech-to-text-$artifactLocale.tar"
    $packageSlug = "$packageSlug-$artifactLocale"
    $logLocaleSuffix = "_$artifactLocale"
    $shaFileName = "SHA256SUMS-$artifactLocale.txt"
  }
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$buildLog = "log-build-speech-offline-package${logLocaleSuffix}_$timestamp.log"
$buildLogPath = Join-Path $ArchiveDir $buildLog

$imageTarPath = Join-Path $ArchiveDir $imageTarName
$runComposeName = "run-disconnected-container-docker-compose.yaml"
$runComposePath = Join-Path $ArchiveDir $runComposeName

$pkgName = "package-$packageSlug-container-$timestamp.tar.gz"
$pkgPath = Join-Path $ArchiveDir $pkgName

$success = $false
$licenseContainerName = "speech-license-download-$timestamp"
$modelContainerName = "speech-model-download-$timestamp"

try {
  Ensure-Dir $LicenseDir
  Ensure-Dir $OutputDir
  Ensure-Dir $ArchiveDir
  if ($spec.NeedsCustomModel) { Ensure-Dir $ModelsDir }
  Write-Host "INFO: Folder structure prepared"

  "Script started at: $($scriptStartTime.ToString("yyyy-MM-dd HH:mm:ss"))" | Out-File -FilePath $buildLogPath -Encoding utf8 -Force
  "Container: $Container" | Out-File -FilePath $buildLogPath -Encoding utf8 -Append
  "Image: $Image" | Out-File -FilePath $buildLogPath -Encoding utf8 -Append

  # ===========================
  # Pull image & save tar
  # ===========================
  Write-Host "====================="
  Write-Host "STEP 1: Pull container image"
  Write-Host "====================="
  & docker pull $Image
  if ($LASTEXITCODE -ne 0) { Fail "docker pull failed" $LASTEXITCODE }

  Write-Host "====================="
  Write-Host "STEP 2: Save container image"
  Write-Host "====================="
  & docker save -o $imageTarPath $Image
  if ($LASTEXITCODE -ne 0) { Fail "docker save failed" $LASTEXITCODE }

  # ===========================
  # Custom speech model download
  # ===========================
  if ($spec.NeedsCustomModel -and -not $SkipCustomModelDownload) {
    Write-Host "====================="
    Write-Host "STEP 3: Download custom speech model"
    Write-Host "====================="

    Remove-DockerContainerQuiet $modelContainerName

    $modelArgs = @(
      "run", "-d",
      "--name", $modelContainerName,
      "-p", "${Port}:5000",
      "--memory", $Memory,
      "--cpus", $Cpus,
      "-v", "${ModelsDir}:/usr/local/models",
      $Image,
      "ModelId=$ModelId",
      "Eula=accept",
      "Billing=$ModelEndpointUri",
      "ApiKey=$ModelKey"
    )

    Invoke-DockerCapture $modelArgs $buildLogPath "docker run model download"
    Wait-ForReadyEndpoint $Port $modelContainerName $buildLogPath $ModelDownloadTimeoutMinutes
    Remove-DockerContainerQuiet $modelContainerName

    $modelFiles = Get-ChildItem -LiteralPath $ModelsDir -Recurse -File -ErrorAction SilentlyContinue
    if (-not $modelFiles) { Fail "Custom model directory is empty after model download" }
    Write-Host ("Model files downloaded: {0}" -f ($modelFiles | Measure-Object).Count)
  } elseif ($spec.NeedsCustomModel -and $SkipCustomModelDownload) {
    $modelFiles = Get-ChildItem -LiteralPath $ModelsDir -Recurse -File -ErrorAction SilentlyContinue
    if (-not $modelFiles) {
      Fail "SkipCustomModelDownload was used, but azure-ai-speech\models is empty"
    }
    Write-Host ("Existing model files found: {0}" -f ($modelFiles | Measure-Object).Count)
  }

  # ===========================
  # Download disconnected license
  # ===========================
  Write-Host "====================="
  if ($spec.NeedsCustomModel) {
    Write-Host "STEP 4: Download disconnected license"
  } else {
    Write-Host "STEP 3: Download disconnected license"
  }
  Write-Host "====================="

  Remove-DockerContainerQuiet $licenseContainerName

  $licenseArgs = @(
    "run", "-d",
    "--name", $licenseContainerName,
    "-p", "${Port}:5000",
    "-v", "${LicenseDir}:/license"
  )

  if ($spec.NeedsCustomModel) {
    $licenseArgs += @("-v", "${ModelsDir}:/usr/local/models")
  }

  $licenseArgs += @(
    $Image,
    "eula=accept",
    "billing=$LicenseEndpointUri",
    "apikey=$LicenseKey",
    "DownloadLicense=True",
    "Mounts:License=/license"
  )

  Invoke-DockerCapture $licenseArgs $buildLogPath "docker run license download"
  Wait-ForLicense $licenseContainerName $LicenseDir $buildLogPath $LicenseDownloadTimeoutMinutes

  $licenseFiles = Get-ChildItem -LiteralPath $LicenseDir -Recurse -File -ErrorAction SilentlyContinue
  if (-not $licenseFiles) { Fail "License directory is empty after license download" }
  Write-Host ("License files downloaded: {0}" -f ($licenseFiles | Measure-Object).Count)

  # ===========================
  # Generate offline docker-compose
  # ===========================
  Write-Host "====================="
  if ($spec.NeedsCustomModel) {
    Write-Host "STEP 5: Generate offline docker compose"
  } else {
    Write-Host "STEP 4: Generate offline docker compose"
  }
  Write-Host "====================="

  Write-RuntimeCompose $runComposePath $spec $Image $Memory $Cpus $Port
  Write-Host "Offline compose generated:"
  Write-Host "  $runComposePath"

  # ===========================
  # Package tar.gz
  # ===========================
  Write-Host "====================="
  if ($spec.NeedsCustomModel) {
    Write-Host "STEP 6: Package tar.gz"
  } else {
    Write-Host "STEP 5: Package tar.gz"
  }
  Write-Host "====================="

  $staging = Join-Path $PWD "staging_$timestamp"
  Ensure-Dir $staging
  Ensure-Dir (Join-Path $staging "azure-ai-speech")
  Ensure-Dir (Join-Path $staging "archive")

  Copy-Item -Recurse $LicenseDir (Join-Path $staging "azure-ai-speech\license")
  Ensure-Dir (Join-Path $staging "azure-ai-speech\output")

  if ($spec.NeedsCustomModel) {
    Copy-Item -Recurse $ModelsDir (Join-Path $staging "azure-ai-speech\models")
  }

  $manifestPath = Join-Path $staging "package-manifest.txt"
@"
Package timestamp: $timestamp
Container: $Container
Image: $Image
Locale: $artifactLocale
Runtime host URL: $($spec.HostProtocol)://localhost:$Port
Memory: $Memory
CPUs: $Cpus
Generated by: build-speech-offline-package.ps1
"@ | Out-File -FilePath $manifestPath -Encoding utf8 -Force

  Copy-Item $runComposePath (Join-Path $staging "archive\$runComposeName")
  Copy-Item $imageTarPath (Join-Path $staging "archive\$imageTarName")
  Copy-Item $buildLogPath (Join-Path $staging "archive\$buildLog")

  Push-Location $staging
  tar -czf $pkgPath .
  Pop-Location

  Remove-Item $staging -Recurse -Force

  Write-Host "Delivery package created:"
  Write-Host "  $pkgPath"

  # ===========================
  # SHA256 hash
  # ===========================
  $h = Get-FileHash -Path $pkgPath -Algorithm SHA256

  Write-Host ""
  Write-Host "========================================"
  Write-Host "DELIVERY FILE HASH (SHA256)"
  Write-Host "========================================"
  Write-Host ("File   : {0}" -f $pkgPath)
  Write-Host ("SHA256 : {0}" -f $h.Hash)
  Write-Host "========================================"

  $shaFile = Join-Path $ArchiveDir $shaFileName
  $pkgFileName = [System.IO.Path]::GetFileName($pkgPath)

  "{0}  {1}" -f $h.Hash.ToLower(), $pkgFileName |
    Out-File -FilePath $shaFile -Encoding ascii -Force

  Write-Host "$shaFileName generated:"
  Write-Host "  $shaFile"

  $success = $true
}
finally {
  Remove-DockerContainerQuiet $licenseContainerName
  Remove-DockerContainerQuiet $modelContainerName

  if ($success) {
    Write-Host ""
    Write-Host "====================="
    Write-Host "SUCCESS CLEANUP"
    Write-Host "====================="

    if (-not $KeepDockerImage) {
      & docker rmi $Image | Out-Null
    }

    Remove-Item $imageTarPath -ErrorAction SilentlyContinue
    Remove-Item $runComposePath -ErrorAction SilentlyContinue
    Remove-Item $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "Cleanup done. Remaining artifacts:"
    Write-Host "  - $buildLogPath"
    Write-Host "  - $pkgPath"
    Write-Host "  - $shaFile"
  }
}

# ===========================
# Timing
# ===========================
$scriptEndTime = Get-Date
$elapsed = $scriptEndTime - $scriptStartTime
Write-Host "========================================"
Write-Host ("Script finished at : {0}" -f $scriptEndTime.ToString("yyyy-MM-dd HH:mm:ss"))
Write-Host ("Elapsed time      : {0}" -f $elapsed.ToString("hh\:mm\:ss"))
Write-Host "========================================"

