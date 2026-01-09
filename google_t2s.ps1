# ============================================
# NASTAVENÍ - Uprav tyto hodnoty
# ============================================
$apiKey = "??????????????" # Je potreba vytvorit Google projekt, povolit Cloud Text2Speach Service a zisakt API klic 
                                                    # https://console.cloud.google.com/apis/api/texttospeech.googleapis.com/cost?project=poetic-analog-454018-h6
                                                    # 1 milion znaku mesicne by melo byt zdarma, pak 30 USD za milion znaku
$inputFolder = "c:\_Data\Projects\tts\kapitoly"   # slozka s txt soubory
$outputFolder = "c:\_Data\Projects\tts\mp3"       # vystupni slozka s mp3 soubory
$language = "cs-CZ"
$voiceName = "cs-CZ-Chirp3-HD-Zubenelgenubi"  # https://docs.cloud.google.com/text-to-speech/docs/list-voices-and-types
$speakingRate = 1.0
$maxCharsPerChunk = 4500  # Maximum znaků na jeden API požadavek
$maxBytesPerChunk = 4800  # Maximum bajtů (Google limit je 5000)

# ============================================
# SKRIPT - Neměň nic pod touto čarou
# ============================================

# Kontrola API klíče
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Host "CHYBA: API klíč není vyplněný!" -ForegroundColor Red
    Write-Host "Vlož svůj Google Cloud API klíč do proměnné `$apiKey na řádku 4" -ForegroundColor Yellow
    exit
}

# Vytvoření výstupní složky
if (-not (Test-Path $outputFolder)) {
    New-Item -ItemType Directory -Path $outputFolder | Out-Null
}

# Vytvoření dočasné složky pro části
$tempFolder = Join-Path $outputFolder "temp"
if (-not (Test-Path $tempFolder)) {
    New-Item -ItemType Directory -Path $tempFolder | Out-Null
}

# Funkce pro rozdělení textu na části podle vět (měří bajty!)
function Split-TextByChunks {
    param(
        [string]$text,
        [int]$maxChars,
        [int]$maxBytes
    )
    
    $chunks = @()
    $sentences = $text -split '(?<=[.!?])\s+'
    $currentChunk = ""
    
    foreach ($sentence in $sentences) {
        $sentence = $sentence.Trim()
        if ([string]::IsNullOrWhiteSpace($sentence)) { continue }
        
        $testChunk = if ($currentChunk.Length -gt 0) { "$currentChunk $sentence" } else { $sentence }
        $testBytes = [System.Text.Encoding]::UTF8.GetByteCount($testChunk)
        
        if (($testChunk.Length -le $maxChars) -and ($testBytes -le $maxBytes)) {
            $currentChunk = $testChunk
        }
        else {
            if ($currentChunk.Length -gt 0) {
                $chunks += $currentChunk
            }
            $currentChunk = $sentence
        }
    }
    
    if ($currentChunk.Length -gt 0) {
        $chunks += $currentChunk
    }
    
    return $chunks
}

# Funkce pro konverzi textu na MP3 s opakováním
function Convert-TextToMP3 {
    param(
        [string]$text,
        [string]$outputFile,
        [int]$maxRetries = 3
    )
    
    $requestBody = @{
        input = @{
            text = $text
        }
        voice = @{
            languageCode = $language
            name = $voiceName
        }
        audioConfig = @{
            audioEncoding = "MP3"
            speakingRate = $speakingRate
        }
    } | ConvertTo-Json -Depth 10
    
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            if ($attempt -gt 1) {
                Write-Host "    → Pokus $attempt/$maxRetries..." -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            }
            
            $response = Invoke-RestMethod -Uri "https://texttospeech.googleapis.com/v1/text:synthesize?key=$apiKey" `
                -Method Post `
                -Body $requestBody `
                -ContentType "application/json" `
                -TimeoutSec 60
            
            $audioBytes = [Convert]::FromBase64String($response.audioContent)
            [System.IO.File]::WriteAllBytes($outputFile, $audioBytes)
            
            return $true
        }
        catch {
            $errorMsg = $_.Exception.Message
            
            if ($_.ErrorDetails.Message) {
                try {
                    $errorJson = $_.ErrorDetails.Message | ConvertFrom-Json
                    $errorMsg = $errorJson.error.message
                }
                catch {}
            }
            
            if ($attempt -eq $maxRetries) {
                Write-Host "    ✗ Selhalo po $maxRetries pokusech: $errorMsg" -ForegroundColor Red
                return $false
            }
        }
    }
    
    return $false
}

# Získání všech .txt souborů
$files = Get-ChildItem -Path $inputFolder -Filter *.txt | Sort-Object Name

Write-Host "Nalezeno $($files.Count) souborů k zpracování`n" -ForegroundColor Cyan

$fileCounter = 1
foreach ($file in $files) {
    Write-Host "[$fileCounter/$($files.Count)] Zpracovávám: $($file.Name)" -ForegroundColor Cyan
    
    # Načtení obsahu souboru
    $text = Get-Content -Path $file.FullName -Encoding UTF8 -Raw
    Write-Host "  → Načteno $($text.Length) znaků"
    
    # Rozdělení na části
    $chunks = Split-TextByChunks -text $text -maxChars $maxCharsPerChunk -maxBytes $maxBytesPerChunk
    Write-Host "  → Rozděleno na $($chunks.Count) částí"
    
    # Vytvoření MP3 pro každou část
    $chunkFiles = @()
    $chunkCounter = 1
    $hasError = $false
    
    foreach ($chunk in $chunks) {
        $chunkBytes = [System.Text.Encoding]::UTF8.GetByteCount($chunk)
        Write-Host "  → Zpracovávám část $chunkCounter/$($chunks.Count) ($($chunk.Length) znaků, $chunkBytes bajtů)..."
        
        $chunkFile = Join-Path $tempFolder "$($file.BaseName)_part$chunkCounter.mp3"
        
        if (Convert-TextToMP3 -text $chunk -outputFile $chunkFile) {
            $chunkFiles += $chunkFile
            Write-Host "    ✓ Část $chunkCounter vytvořena" -ForegroundColor Green
        }
        else {
            Write-Host "`n✗✗✗ KRITICKÁ CHYBA ✗✗✗" -ForegroundColor Red
            Write-Host "Selhalo vytvoření části $chunkCounter souboru $($file.Name)" -ForegroundColor Red
            Write-Host "Ukončuji zpracování - část by chyběla!" -ForegroundColor Red
            
            # Smazání neúplných částí
            foreach ($chunkFile in $chunkFiles) {
                if (Test-Path $chunkFile) {
                    Remove-Item $chunkFile -Force
                }
            }
            
            # Ukončení celého skriptu
            exit 1
        }
        
        $chunkCounter++
        Start-Sleep -Milliseconds 500
    }
    
    # Pokud byla chyba, smaž neúplné části a pokračuj dalším souborem
    if ($hasError) {
        foreach ($chunkFile in $chunkFiles) {
            if (Test-Path $chunkFile) {
                Remove-Item $chunkFile -Force
            }
        }
        Write-Host ""
        $fileCounter++
        continue
    }
    
    # Spojení všech částí do jednoho MP3
    if ($chunkFiles.Count -gt 0) {
        Write-Host "  → Spojuji $($chunkFiles.Count) částí do jednoho souboru..."
        
        $outputFile = Join-Path $outputFolder "$($file.BaseName).mp3"
        
        # Spojení pomocí binárního zápisu
        $outputStream = [System.IO.File]::Create($outputFile)
        foreach ($chunkFile in $chunkFiles) {
            $chunkBytes = [System.IO.File]::ReadAllBytes($chunkFile)
            $outputStream.Write($chunkBytes, 0, $chunkBytes.Length)
        }
        $outputStream.Close()
        
        $fileSizeMB = [math]::Round((Get-Item $outputFile).Length / 1MB, 2)
        Write-Host "  ✓ Vytvořeno: $($file.BaseName).mp3 ($fileSizeMB MB)" -ForegroundColor Green
        
        # Smazání dočasných souborů
        foreach ($chunkFile in $chunkFiles) {
            Remove-Item $chunkFile -Force
        }
    }
    
    Write-Host ""
    $fileCounter++
}

# Smazání dočasné složky
Remove-Item $tempFolder -Force -ErrorAction SilentlyContinue

Write-Host "Hotovo! Zpracováno $($files.Count) souborů." -ForegroundColor Cyan
