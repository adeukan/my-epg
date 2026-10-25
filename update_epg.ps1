$epgUrl = "http://epg.online/epg.xml.gz"
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = $PWD.Path }

$localPath = Join-Path $scriptDir "my_14day_epg.xml"
$gzPath = Join-Path $scriptDir "temp.xml.gz"
$tempPath = Join-Path $scriptDir "temp.xml"
$mergedPath = Join-Path $scriptDir "merged_temp.xml"

Write-Host "Downloading EPG..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $epgUrl -OutFile $gzPath

Write-Host "Unpacking archive..." -ForegroundColor Cyan
$gzStream = New-Object System.IO.Compression.GZipStream(
    (New-Object System.IO.FileStream($gzPath, [System.IO.FileMode]::Open)), 
    [System.IO.Compression.CompressionMode]::Decompress
)
$targetStream = New-Object System.IO.FileStream($tempPath, [System.IO.FileMode]::Create)
$gzStream.CopyTo($targetStream)
$targetStream.Close()
$gzStream.Close()
Remove-Item $gzPath

function Remove-DtdReference($filePath) {
    if (Test-Path $filePath) {
        $content = Get-Content $filePath -Raw -Encoding UTF8
        $cleanContent = [System.Text.RegularExpressions.Regex]::Replace($content, "<!DOCTYPE[^>]+>", "")
        [System.IO.File]::WriteAllText($filePath, $cleanContent, [System.Text.Encoding]::UTF8)
    }
}

Remove-DtdReference $tempPath

# Проверяем: если локальный файл существует, но внутри него LFS-указатель (не XML) — удаляем его
if (Test-Path $localPath) {
    $firstLine = Get-Content $localPath -TotalCount 1
    if (-not $firstLine -or -not $firstLine.Trim().StartsWith("<?xml")) {
        Write-Host "Local file is an LFS pointer or invalid. Removing it." -ForegroundColor Yellow
        Remove-Item $localPath -Force
    }
}

if (-not (Test-Path $localPath)) {
    Write-Host "Local file not found. Moving temp to local." -ForegroundColor Green
    Move-Item $tempPath $localPath -Force
    exit
}

Write-Host "Fast streaming merge with 14-day rolling window..." -ForegroundColor Cyan
$cutoffDate = (Get-Date).AddDays(-14).ToString("yyyyMMddHHmmss")
$existingKeys = New-Object 'System.Collections.Generic.HashSet[string]'

$settings = New-Object System.Xml.XmlReaderSettings
$settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
$settings.XmlResolver = $null

$writerSettings = New-Object System.Xml.XmlWriterSettings
$writerSettings.Indent = $true
$writerSettings.IndentChars = "  "
$writerSettings.Encoding = [System.Text.Encoding]::UTF8

$writer = [System.Xml.XmlWriter]::Create($mergedPath, $writerSettings)
$writer.WriteStartDocument()
$writer.WriteStartElement("tv")

# 1. Сначала переносим ВСЕ каналы из старого файла
$readerOld = [System.Xml.XmlReader]::Create($localPath, $settings)
while ($readerOld.Read()) {
    if ($readerOld.NodeType -eq [System.Xml.XmlNodeType]::Element -and $readerOld.Name -eq "channel") {
        $writer.WriteNode($readerOld, $false)
    }
}
$readerOld.Close()

# 2. Переносим все старые программы в пределах 14 дней
$readerOld = [System.Xml.XmlReader]::Create($localPath, $settings)
while ($readerOld.Read()) {
    if ($readerOld.NodeType -eq [System.Xml.XmlNodeType]::Element -and $readerOld.Name -eq "programme") {
        $start = $readerOld.GetAttribute("start")
        $channel = $readerOld.GetAttribute("channel")
        if ($start -gt $cutoffDate) {
            $key = $channel + "_" + $start
            if ($existingKeys.Add($key)) {
                $writer.WriteNode($readerOld, $false)
            }
        }
    }
}
$readerOld.Close()

# 3. Дописываем новые уникальные программы из свежего файла
$readerNew = [System.Xml.XmlReader]::Create($tempPath, $settings)
$addedCount = 0
while ($readerNew.Read()) {
    if ($readerNew.NodeType -eq [System.Xml.XmlNodeType]::Element -and $readerNew.Name -eq "programme") {
        $start = $readerNew.GetAttribute("start")
        $channel = $readerNew.GetAttribute("channel")
        if ($start -gt $cutoffDate) {
            $key = $channel + "_" + $start
            if ($existingKeys.Add($key)) {
                $writer.WriteNode($readerNew, $false)
                $addedCount++
            }
        }
    }
}
$readerNew.Close()

$writer.WriteEndElement()
$writer.WriteEndDocument()
$writer.Flush()
$writer.Close()

Remove-Item $localPath
Move-Item $mergedPath $localPath
Remove-Item $tempPath

Write-Host "Done! Added new programs: $addedCount" -ForegroundColor Green
