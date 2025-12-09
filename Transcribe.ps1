Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

param(
  [ValidateSet('tiny','base','small','medium','large')]
  [string]$ModelSize = 'small',

  [ValidateSet('int8','int8_float16','int16','float32')]
  [string]$ComputeType = 'int8',

  [string]$Language = 'en'
)

function Fail($msg) { Write-Error $msg; exit 1 }

function Require-Cmd([string]$name, [string]$hint) {
  try { return (Get-Command $name -ErrorAction Stop).Source }
  catch { Fail "$name not found. $hint" }
}

function Wait-ForStableFile {
  param([string]$Path, [int]$StableSeconds = 6, [int]$PollMs = 1000)
  Write-Host "Waiting for file to become stable (no size changes for $StableSeconds seconds)..."
  $stableFor = 0; $prevSize = -1
  while ($true) {
    if (-not (Test-Path $Path)) { Start-Sleep -Milliseconds $PollMs; continue }
    $len = (Get-Item $Path).Length
    if ($len -eq $prevSize) {
      $stableFor += ($PollMs / 1000)
      if ($stableFor -ge $StableSeconds) { break }
    } else {
      $stableFor = 0; $prevSize = $len
    }
    Start-Sleep -Milliseconds $PollMs
  }
  Write-Host "File size stable."
}

# --- GUI File Picker ---
function Select-VideoFile {
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Filter = "MP4 files (*.mp4)|*.mp4"
  $dialog.Title = "Select Outplayed Video to Transcribe"
  if ($dialog.ShowDialog() -eq 'OK') {
    return $dialog.FileName
  } else {
    Fail "No video selected."
  }
}

function Select-OutputFolder {
  $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $folderDialog.Description = "Select Output Folder for Transcription"
  if ($folderDialog.ShowDialog() -eq 'OK') {
    return $folderDialog.SelectedPath
  } else {
    Fail "No output folder selected."
  }
}

# --- Select video and output folder ---
$videoPath = Select-VideoFile
$workDir   = Select-OutputFolder

# --- Prereqs ---
$ffmpeg = Require-Cmd -name 'ffmpeg' -hint 'Install via Chocolatey: choco install ffmpeg'
$python = Require-Cmd -name 'python' -hint 'Install Python 3 and ensure "python" is on PATH.'

# Create output folder if needed
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

# Ensure faster-whisper is installed
& $python -c "import faster_whisper" 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Installing faster-whisper (first run only)..."
  & $python -m pip install --upgrade pip | Out-Null
  & $python -m pip install faster-whisper | Out-Null
  & $python -c "import faster_whisper" 2>$null
  if ($LASTEXITCODE -ne 0) {
    Fail "Failed to install faster-whisper. Try: pip install faster-whisper"
  }
}

Write-Host "Selected video: $videoPath"
Wait-ForStableFile -Path $videoPath

# --- Prepare working names ---
$stamp     = (Get-Date).ToString('yyyyMMdd_HHmmss')
$videoDst  = Join-Path $workDir "session_$stamp.mp4"
$audioWav  = Join-Path $workDir "session_$stamp.wav"
$outTxt    = Join-Path $workDir "session_$stamp.txt"
$outVtt    = Join-Path $workDir "session_$stamp.vtt"
$pyPath    = Join-Path $workDir "run_faster_whisper_$stamp.py"

# --- Copy video ---
Copy-Item -LiteralPath $videoPath -Destination $videoDst -Force
Write-Host "Copied -> $videoDst"

# --- Extract audio ---
$ffArgs = @('-y','-i',"$videoDst", '-map','0:a:0','-vn','-ac','1','-ar','16000',"$audioWav")
Write-Host "Extracting audio with ffmpeg..."
$ff = Start-Process -FilePath $ffmpeg -ArgumentList $ffArgs -NoNewWindow -PassThru -Wait
if ($ff.ExitCode -ne 0 -or -not (Test-Path $audioWav)) {
  Fail "ffmpeg failed to extract audio (code $($ff.ExitCode))."
}

# --- Python transcription script ---
$pyCode = @"
from faster_whisper import WhisperModel

audio = r"$audioWav"
out_txt = r"$outTxt"
out_vtt = r"$outVtt"
language = "$Language"
model_size = "$ModelSize"
compute_type = "$ComputeType"

model = WhisperModel(model_size, device="cpu", compute_type=compute_type)

segments, info = model.transcribe(
    audio,
    language=language,
    vad_filter=True
)

# Write TXT
with open(out_txt, "w", encoding="utf-8") as ftxt:
    for seg in segments:
        ftxt.write(seg.text.strip() + "\n")

# Second pass for VTT
segments, _ = model.transcribe(
    audio,
    language=language,
    vad_filter=True
)

def fmt_ts(seconds: float) -> str:
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = seconds % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"

with open(out_vtt, "w", encoding="utf-8") as fvtt:
    fvtt.write("WEBVTT\\n\\n")
    i = 1
    for seg in segments:
        start = fmt_ts(seg.start)
        end = fmt_ts(seg.end)
        text = seg.text.strip()
        fvtt.write(f"{i}\\n{start} --> {end}\\n{text}\\n\\n")
        i += 1

print("WROTE:", out_txt)
print("WROTE:", out_vtt)
"@

Set-Content -LiteralPath $pyPath -Value $pyCode -Encoding UTF8

Write-Host "Transcribing with faster-whisper ($ModelSize, $ComputeType, language=$Language)..."
$proc = Start-Process -FilePath $python -ArgumentList @($pyPath) -NoNewWindow -PassThru -Wait
if ($proc.ExitCode -ne 0 -or -not (Test-Path $outTxt)) {
  Fail "Transcription failed (code $($proc.ExitCode))."
}

Write-Host ""
Write-Host "✅ Transcription complete."
Write-Host "Transcript (TXT): $outTxt"
Write-Host "Subtitles (VTT):  $outVtt"
Write-Host ""
Write-Host "Tip: Open the VTT in VLC (Subtitle > Add Subtitle File...) to scrub by timestamps."
