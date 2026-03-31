[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = ".\input data\Oregon (US-OR).csv",

    [Parameter(Mandatory = $false)]
    [string]$GpxPath = ".\input data\Oregon (US-OR).gpx",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output\Oregon (US-OR)-onx.gpx",

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-InputPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-ParkReferenceFromName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Name -match "^(US-\d{4,5})\b") {
        return $Matches[1]
    }

    return $null
}

function Get-ColorValue {
    param(
        [Parameter(Mandatory = $true)]
        [int]$MyActivations,

        [Parameter(Mandatory = $true)]
        [int]$Activations
    )

    if ($MyActivations -gt 0) {
        return "rgba(132, 212, 0, 1)"
    }

    if ($Activations -eq 0) {
        return "rgba(255, 255, 0, 1)"
    }

    return "rgba(255, 51, 0, 1)"
}

function ConvertTo-XmlContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

$resolvedCsv = Resolve-InputPath -Path $CsvPath -Label "CSV input"
$resolvedGpx = Resolve-InputPath -Path $GpxPath -Label "GPX input"

$outputDirectory = Split-Path -Parent $OutputPath
if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
    $outputDirectory = "."
}

if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw "Output already exists. Use -Force to overwrite: $OutputPath"
}

$csvRows = Import-Csv -LiteralPath $resolvedCsv
if (-not $csvRows -or $csvRows.Count -eq 0) {
    throw "CSV appears empty: $resolvedCsv"
}

[xml]$gpxXml = Get-Content -LiteralPath $resolvedGpx
$gpxNs = New-Object System.Xml.XmlNamespaceManager($gpxXml.NameTable)
$gpxNs.AddNamespace("g", "http://www.topografix.com/GPX/1/1")

$gpxLookup = @{}
foreach ($wpt in $gpxXml.SelectNodes("/g:gpx/g:wpt", $gpxNs)) {
    $nameNode = $wpt.SelectSingleNode("g:name", $gpxNs)
    if (-not $nameNode) { continue }

    $reference = Get-ParkReferenceFromName -Name $nameNode.InnerText
    if ([string]::IsNullOrWhiteSpace($reference)) { continue }

    $linkNode = $wpt.SelectSingleNode("g:link", $gpxNs)
    if ($linkNode -and $linkNode.Attributes["href"]) {
        $href = $linkNode.Attributes["href"].Value
        if (-not [string]::IsNullOrWhiteSpace($href)) {
            $gpxLookup[$reference] = $href
        }
    }
}

$total              = 0
$greenCount         = 0
$yellowCount        = 0
$redCount           = 0
$missingGpxLinkCount = 0

$gpxHeader = '<gpx xmlns:onx="https://wwww.onxmaps.com/" xmlns="http://www.topografix.com/GPX/1/1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd" version="1.1" creator="onXmaps hunt web"><metadata/>'

$sb = New-Object System.Text.StringBuilder
$sb.Append($gpxHeader) | Out-Null

foreach ($row in $csvRows) {
    $total++

    $reference   = [string]$row.reference
    $parkName    = [string]$row.name
    $fullName    = "$reference $parkName".Trim()
    $fullNameXml = ConvertTo-XmlContent -Value $fullName

    $attempts      = [int]$row.attempts
    $activations   = [int]$row.activations
    $qsos          = [int]$row.qsos
    $myActivations = [int]$row.my_activations

    $latStr = [string]$row.latitude
    $lonStr = [string]$row.longitude
    $grid   = [string]$row.grid

    $parkUrl = $gpxLookup[$reference]
    if ([string]::IsNullOrWhiteSpace($parkUrl)) {
        $missingGpxLinkCount++
        $parkUrl = "https://pota.app/#/park/$reference"
    }

    $colorValue = Get-ColorValue -MyActivations $myActivations -Activations $activations
    $iconValue  = "Parking"
    $guid       = [guid]::NewGuid().ToString()

    switch ($colorValue) {
        "rgba(132, 212, 0, 1)" { $greenCount++ }
        "rgba(255, 255, 0, 1)" { $yellowCount++ }
        default                { $redCount++ }
    }

    $descLines = @(
        $grid,
        $parkUrl,
        "Activations: $activations/$attempts",
        "qsos: $qsos"
    )
    $descContent = ConvertTo-XmlContent -Value ($descLines -join "`n")

    $sb.Append('<wpt lat="' + $latStr + '" lon="' + $lonStr + '">') | Out-Null
    $sb.Append('<name>'     + $fullNameXml  + '</name>') | Out-Null
    $sb.Append('<desc>'     + $descContent  + '</desc>') | Out-Null
    $sb.Append('<extensions><onx:color>' + $colorValue + '</onx:color><onx:icon>' + $iconValue + '</onx:icon></extensions>') | Out-Null
    $sb.Append('</wpt>') | Out-Null
}

$sb.Append('</gpx>') | Out-Null

[System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))

Write-Host "GPX generated: $OutputPath"
Write-Host "Total waypoints:              $total"
Write-Host "Green  (my_activations > 0):  $greenCount"
Write-Host "Yellow (activations = 0):     $yellowCount"
Write-Host "Red    (all others):          $redCount"
Write-Host "Missing GPX links (fallback): $missingGpxLinkCount"
