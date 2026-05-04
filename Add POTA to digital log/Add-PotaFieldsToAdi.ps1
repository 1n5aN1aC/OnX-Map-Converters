[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputAdiPath = "Example Input.adi",

    [Parameter(Mandatory = $false)]
    [string[]]$Parks,

    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ScriptDirectory = $PSScriptRoot

function Resolve-FromScriptDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path -Path $ScriptDirectory -ChildPath $Path)
}

function Resolve-RequiredPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $resolvedCandidate = Resolve-FromScriptDirectory -Path $Path

    if (-not (Test-Path -LiteralPath $resolvedCandidate)) {
        throw "$Label not found: $resolvedCandidate"
    }

    return (Resolve-Path -LiteralPath $resolvedCandidate).Path
}

function Get-ParkList {
    param(
        [string[]]$FromArgs
    )

    $items = @()

    if ($FromArgs -and $FromArgs.Count -gt 0) {
        foreach ($entry in $FromArgs) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $items += ($entry -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }

    while (-not $items -or @($items).Count -eq 0) {
        $prompt = Read-Host "Enter one or more POTA park refs (comma/space separated, e.g. US-3424, US-9999)"
        if ([string]::IsNullOrWhiteSpace($prompt)) { continue }

        $items = @($prompt -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $normalized = @()
    foreach ($park in $items) {
        $upper = $park.Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($upper)) { continue }
        $normalized += $upper
    }

    return @($normalized | Select-Object -Unique)
}

function Remove-ExistingMyPotaFields {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Record
    )

    $result = $Record
    $result = [regex]::Replace($result, '(?is)\s*<MY_SIG:\d+>[^<]*', '')
    $result = [regex]::Replace($result, '(?is)\s*<MY_SIG_INFO:\d+>[^<]*', '')
    $result = [regex]::Replace($result, '(?is)\s*<MY_POTA_REF:\d+>[^<]*', '')
    return $result
}

function Add-MyPotaFieldsToRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Record,

        [Parameter(Mandatory = $true)]
        [string]$Park
    )

    $cleanRecord = Remove-ExistingMyPotaFields -Record $Record
    $parkLength = $Park.Length
    $insertFields = "<MY_SIG:4>POTA<MY_SIG_INFO:$parkLength>$Park<MY_POTA_REF:$parkLength>$Park"

    return [regex]::Replace($cleanRecord, '(?is)<EOR>', "$insertFields<EOR>", 1)
}

$resolvedInput = Resolve-RequiredPath -Path $InputAdiPath -Label "ADI input"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Split-Path -Parent $resolvedInput
}

$OutputDirectory = Resolve-FromScriptDirectory -Path $OutputDirectory

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
}

$parkList = @(Get-ParkList -FromArgs $Parks)
if (-not $parkList -or $parkList.Count -eq 0) {
    throw "No POTA parks were provided."
}

$adiRaw = [System.IO.File]::ReadAllText($resolvedInput)

$headerMatch = [regex]::Match($adiRaw, '(?is)\A(.*?<EOH>\s*)')
if (-not $headerMatch.Success) {
    throw "Input ADI file is missing an <EOH> header terminator: $resolvedInput"
}

$header = $headerMatch.Groups[1].Value
$recordsPart = $adiRaw.Substring($header.Length)

$recordMatches = [regex]::Matches($recordsPart, '(?is).*?<EOR>')
if ($recordMatches.Count -eq 0) {
    throw "No ADI records ending in <EOR> were found in: $resolvedInput"
}

$baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedInput)
$ext = [System.IO.Path]::GetExtension($resolvedInput)

foreach ($park in $parkList) {
    $safePark = ($park -replace '[^A-Za-z0-9_-]', '_')
    $outputName = "$baseName-$safePark$ext"
    $outputPath = Join-Path -Path $OutputDirectory -ChildPath $outputName

    if ((Test-Path -LiteralPath $outputPath) -and -not $Force) {
        throw "Output already exists. Use -Force to overwrite: $outputPath"
    }

    $transformedRecords = New-Object System.Text.StringBuilder
    foreach ($match in $recordMatches) {
        $updatedRecord = Add-MyPotaFieldsToRecord -Record $match.Value -Park $park
        $transformedRecords.Append($updatedRecord) | Out-Null
        $transformedRecords.Append([Environment]::NewLine) | Out-Null
    }

    $finalContent = $header + $transformedRecords.ToString()
    [System.IO.File]::WriteAllText($outputPath, $finalContent, [System.Text.UTF8Encoding]::new($false))

    Write-Host "Created: $outputPath"
}

Write-Host "Input contacts processed: $($recordMatches.Count)"
Write-Host "Parks exported: $($parkList.Count)"