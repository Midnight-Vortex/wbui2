<#
ssd_zurueck_nach_E.ps1
Kopiert die Sicherung "D:\Game 3 SSD 500GB" auf die neue SSD (E:) zurueck
und repariert danach die Apps, die auf E: verweisen.

Ablauf:
  1. Sicherung pruefen.
  2. Dafuer sorgen, dass die neue SSD den Buchstaben E: hat (fragt vorher).
     Liegt eine angefangene Explorer-Kopie in E:\Game 3 SSD 500GB, wird ihr
     Inhalt nach E:\ verschoben (geht sofort).
  3. Platz pruefen.
  4. Alles mit robocopy nach E:\ kopieren. Robocopy kann lange Pfade, der
     Explorer nicht ("Der Dateiname ist fuer den Zielordner zu lang").
  5. Kopie pruefen.
  6. Store-App-Daten (Claude, Codex ...) reparieren.
  7. Neue Store-Apps auf C: speichern lassen.
  8. Steam, Dienste, Verknuepfungen und Autostart pruefen.
  9. Lange Pfade in Windows erlauben.

Geloescht wird nichts, weder auf D: noch auf E:.
Wird das Skript abgebrochen, einfach noch mal starten: es macht dort weiter.

Start: Rechtsklick auf die Datei > "Mit PowerShell ausfuehren".
       Es fragt nach Administratorrechten.
Nur pruefen, nichts aendern:
       powershell -ExecutionPolicy Bypass -File .\ssd_zurueck_nach_E.ps1 -Test
#>
param(
    [string]$Quelle = 'D:\Game 3 SSD 500GB',
    [string]$ZielLW = 'E',
    [switch]$Test,
    [string]$NutzerAppData = $env:LOCALAPPDATA,
    [string]$NutzerProfil = $env:USERPROFILE,
    [string]$NutzerSid = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
)

# ---------------------------------------------------------------- Adminrechte
$ich = [Security.Principal.WindowsIdentity]::GetCurrent()
$istAdmin = ([Security.Principal.WindowsPrincipal]$ich).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $istAdmin) {
    if (-not $PSCommandPath) {
        Write-Host 'Bitte das Skript als Datei speichern und per Rechtsklick > "Mit PowerShell ausfuehren" starten.' -ForegroundColor Red
        return
    }
    Write-Host 'Starte mit Administratorrechten neu ...'
    $argListe = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Quelle "{1}" -ZielLW {2} -NutzerAppData "{3}" -NutzerProfil "{4}" -NutzerSid {5}' -f `
        $PSCommandPath, $Quelle, $ZielLW, $NutzerAppData, $NutzerProfil, $NutzerSid
    if ($Test) { $argListe += ' -Test' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argListe -ErrorAction Stop
    } catch {
        Write-Host 'Ohne Administratorrechte geht es nicht. Abgebrochen.' -ForegroundColor Red
        Read-Host 'Enter zum Schliessen' | Out-Null
    }
    exit
}

# ---------------------------------------------------------------- Grundlagen
$ZielLW = $ZielLW.Trim().Substring(0, 1).ToUpper()
$Ziel = "$($ZielLW):\"
$Quelle = $Quelle.TrimEnd('\')
$Label = Split-Path $Quelle -Leaf
if ($Label.Length -gt 32) { $Label = $Label.Substring(0, 32) }
$Hinweise = New-Object 'System.Collections.Generic.List[string]'
$ClaudeAufE = $false

$LogOrdner = Join-Path $NutzerProfil 'Documents\Codex\SSD-Kopie'
if (-not (Test-Path -LiteralPath $LogOrdner)) { New-Item -ItemType Directory -Path $LogOrdner -Force | Out-Null }
$Stempel = Get-Date -Format 'yyyyMMdd_HHmm'
$RoboLog = Join-Path $LogOrdner "robocopy_zurueck_$Stempel.log"
try { Start-Transcript -Path (Join-Path $LogOrdner "ssd_zurueck_$Stempel.txt") -Force | Out-Null } catch { }
try { $Host.UI.RawUI.WindowTitle = "SSD zurueck nach $($ZielLW):" } catch { }

function Schritt([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Ok([string]$t) { Write-Host "   OK  $t" -ForegroundColor Green }
function Info([string]$t) { Write-Host "       $t" }
function Warnung([string]$t) { Write-Host "   !!  $t" -ForegroundColor Yellow; $script:Hinweise.Add($t) }
function Ende([int]$code) {
    try { Stop-Transcript | Out-Null } catch { }
    Read-Host 'Enter zum Schliessen' | Out-Null
    exit $code
}
function Abbruch([string]$t) {
    Write-Host ''
    Write-Host "ABBRUCH: $t" -ForegroundColor Red
    Write-Host 'Geloescht wurde nichts.'
    Ende 1
}
function Frage([string]$t) { return ((Read-Host "$t (J/N)") -match '^\s*[JjYy]') }
function HatBuchstabe($c) { return ($null -ne $c -and [int][char]$c -ge 65) }

# robocopy mit festen Optionen. Kopiert nur, ueberschreibt Abweichendes, loescht nie.
function Robo([string]$Von, [string]$Nach, [string[]]$Opt) {
    $a = @($Von, $Nach) + $Opt + @('/COPY:DAT', '/DCOPY:DAT', '/XJ', '/B', '/R:1', '/W:1', '/NP', '/NFL', '/NDL', "/UNILOG+:$RoboLog")
    & robocopy.exe @a | Out-Null
    return $LASTEXITCODE
}

# robocopy-Listenlauf (/L): zaehlt, was noch kopiert werden muesste.
function RoboListe {
    $a = @($Quelle, $Ziel, '/L', '/E', '/XJ', '/BYTES', '/NFL', '/NDL', '/NJH', '/R:0', '/W:0', '/XD', 'System Volume Information', '$RECYCLE.BIN')
    $out = @(& robocopy.exe @a)
    $erg = [pscustomobject]@{ Code = $LASTEXITCODE; Dateien = $null; Bytes = $null }
    foreach ($z in $out) {
        if ($z -match '^\s*(?:Dateien|Files)\s*:\s*(\d+)\s+(\d+)') { $erg.Dateien = [int64]$Matches[2] }
        elseif ($z -match '^\s*Bytes\s*:\s*(\d+)\s+(\d+)') { $erg.Bytes = [int64]$Matches[2] }
    }
    return $erg
}

function Volumes {
    foreach ($v in @(Get-Volume | Where-Object { HatBuchstabe $_.DriveLetter })) {
        $lw = ([string]$v.DriveLetter).ToUpper()
        $d = $null
        try { $d = Get-Partition -DriveLetter $lw -ErrorAction Stop | Get-Disk -ErrorAction Stop } catch { }
        [pscustomobject]@{
            LW     = $lw
            Name   = $v.FileSystemLabel
            FS     = $v.FileSystem
            Typ    = [string]$v.DriveType
            GB     = [math]::Round($v.Size / 1GB)
            FreiGB = [math]::Round($v.SizeRemaining / 1GB)
            Platte = $(if ($d) { $d.FriendlyName } else { '' })
            DiskNr = $(if ($d) { [int]$d.Number } else { -1 })
        }
    }
}

# Leerer Text = Laufwerk passt als Ziel, sonst der Grund.
function Passt($v) {
    if (-not $v) { return 'gibt es nicht' }
    if ($v.Typ -ne 'Fixed' -and $v.Typ -ne 'Removable') { return "ist keine Festplatte ($($v.Typ))" }
    if ($v.DiskNr -ge 0 -and $null -ne $QuelleDisk -and $v.DiskNr -eq $QuelleDisk) { return 'liegt auf derselben Platte wie die Sicherung' }
    if ($v.DiskNr -ge 0 -and $null -ne $SysDisk -and $v.DiskNr -eq $SysDisk) { return 'liegt auf der Windows-Platte' }
    return ''
}

function PlattenOhneBuchstabe {
    foreach ($d in @(Get-Disk)) {
        if ($d.IsBoot -or $d.IsSystem) { continue }
        if ($null -ne $QuelleDisk -and $d.Number -eq $QuelleDisk) { continue }
        $gb = [math]::Round($d.Size / 1GB)
        if ($d.PartitionStyle -eq 'RAW') {
            [pscustomobject]@{ Nr = $d.Number; Platte = $d.FriendlyName; GB = $gb; Zustand = 'neu, nicht eingerichtet'; Partition = $null }
            continue
        }
        $teile = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { $_.Type -ne 'Reserved' })
        if ($teile.Count -eq 0) {
            [pscustomobject]@{ Nr = $d.Number; Platte = $d.FriendlyName; GB = $gb; Zustand = 'leer'; Partition = $null }
            continue
        }
        if (@($teile | Where-Object { HatBuchstabe $_.DriveLetter }).Count) { continue }
        $gross = $teile | Where-Object { $_.Type -eq 'Basic' -or $_.Type -eq 'IFS' } | Sort-Object Size -Descending | Select-Object -First 1
        if ($gross) {
            [pscustomobject]@{ Nr = $d.Number; Platte = $d.FriendlyName; GB = $gb; Zustand = 'hat Daten, aber keinen Buchstaben'; Partition = $gross.PartitionNumber }
        }
    }
}

function FreierBuchstabe {
    $belegt = @()
    $belegt += @(Get-CimInstance Win32_LogicalDisk | ForEach-Object { $_.DeviceID.Substring(0, 1).ToUpper() })
    $belegt += @(Get-CimInstance Win32_Volume | Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter.Substring(0, 1).ToUpper() })
    $belegt += @(Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName.ToUpper() })
    foreach ($c in [char[]]'ZYXWVUTSRQPONMLKJIHGF') { if ($belegt -notcontains [string]$c) { return [string]$c } }
    return $null
}

function SetzeBuchstabe([string]$von, [string]$nach) {
    $v = Get-CimInstance Win32_Volume -Filter "DriveLetter='$($von):'"
    if (-not $v) { throw "Laufwerk $($von): nicht gefunden" }
    Set-CimInstance -InputObject $v -Property @{ DriveLetter = "$($nach):" } -ErrorAction Stop
}

# Gibt den Buchstaben E: frei, falls ihn gerade ein anderes Laufwerk hat (z.B. DVD oder USB-Stick).
function ZielFreimachen {
    $belegt = Get-CimInstance Win32_Volume -Filter "DriveLetter='$($ZielLW):'"
    if (-not $belegt) {
        if (Test-Path -LiteralPath $Ziel) { Abbruch "$($ZielLW): ist ein Netz- oder SUBST-Laufwerk. Bitte trennen und das Skript neu starten." }
        return
    }
    $frei = FreierBuchstabe
    if (-not $frei) { Abbruch 'Kein freier Laufwerksbuchstabe da.' }
    SetzeBuchstabe $ZielLW $frei
    Warnung "Das Laufwerk, das vorher $($ZielLW): war ('$($belegt.Label)'), heisst jetzt $($frei):."
}

# Wartet, bis eine Store-App ganz geschlossen ist. $false = uebersprungen.
function WarteBisZu([string]$familie) {
    $pk = $null
    try { $pk = Get-AppxPackage -User $NutzerSid -ErrorAction Stop | Where-Object { $_.PackageFamilyName -eq $familie } | Select-Object -First 1 } catch { }
    if (-not $pk -or -not $pk.InstallLocation) { return $true }
    $ort = $pk.InstallLocation
    while ($true) {
        $laeuft = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($ort, [StringComparison]::OrdinalIgnoreCase) })
        if (-not $laeuft.Count) { return $true }
        Write-Host "   $($pk.Name) laeuft noch. Bitte ganz schliessen (auch unten rechts im Tray)." -ForegroundColor Yellow
        if ((Read-Host '   Danach Enter druecken (U = ueberspringen)') -match '^\s*[Uu]') { return $false }
    }
}

function ExeAusBefehl([string]$befehl) {
    $b = $befehl.Trim()
    if ($b.StartsWith('"')) {
        $ende = $b.IndexOf('"', 1)
        if ($ende -gt 1) { return $b.Substring(1, $ende - 1) }
        return $b.Trim('"')
    }
    return ($b -replace '(?i)^(.*?\.exe).*$', '$1')
}

if ($Test) { Write-Host 'TESTLAUF: Es wird nur geprueft, nichts geaendert.' -ForegroundColor Magenta }

# ---------------------------------------------------------------- 1. Sicherung
Schritt '1. Sicherung pruefen'
if (-not (Test-Path -LiteralPath $Quelle)) { Abbruch "Den Ordner $Quelle gibt es nicht." }
$QuelleLW = $Quelle.Substring(0, 1).ToUpper()
if ($QuelleLW -eq $ZielLW) { Abbruch 'Sicherung und Ziel liegen auf demselben Laufwerk.' }
$QuelleDisk = $null
try { $QuelleDisk = [int](Get-Partition -DriveLetter $QuelleLW -ErrorAction Stop | Get-Disk -ErrorAction Stop).Number } catch { }
$SysDisk = $null
try { $SysDisk = [int](Get-Partition -DriveLetter $env:SystemDrive.Substring(0, 1) -ErrorAction Stop | Get-Disk -ErrorAction Stop).Number } catch { }
$inhalt = @(Get-ChildItem -LiteralPath $Quelle -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
Ok "Sicherung gefunden: $Quelle"
Info ('Inhalt: ' + ($inhalt -join ', '))

# ---------------------------------------------------------------- 2. Ziel
Schritt "2. Neue SSD als $($ZielLW): pruefen"
$alle = @(Volumes)
$e = $alle | Where-Object { $_.LW -eq $ZielLW } | Select-Object -First 1
$grund = Passt $e
$bereit = $false
if ($e -and -not $grund) {
    Info ("{0}:  Name '{1}', {2}, {3} GB, frei {4} GB, Platte: {5}" -f $e.LW, $e.Name, $e.FS, $e.GB, $e.FreiGB, $e.Platte)
    if ($e.Platte -like '*WDS480G2G0A*') { Write-Host '       Das sieht nach der ALTEN SSD aus (WD 480 GB).' -ForegroundColor Yellow }
    $bereit = Frage "Ist $($ZielLW): die neue SSD, auf die zurueckkopiert werden soll?"
}
if (-not $bereit) {
    if ($grund) { Info "$($ZielLW): $grund." }
    Info 'Laufwerke im PC:'
    $alle | Format-Table @{ n = 'LW'; e = { $_.LW + ':' } }, Name, FS, Typ, GB, FreiGB, Platte -AutoSize | Out-String -Width 200 | Write-Host
    $ohne = @(PlattenOhneBuchstabe)
    if ($ohne.Count) {
        Info 'Platten ohne Laufwerksbuchstaben (z.B. eine neue SSD):'
        $ohne | Format-Table Nr, Platte, GB, Zustand -AutoSize | Out-String -Width 200 | Write-Host
    }
    if ($Test) { Abbruch "Testlauf: $($ZielLW): ist noch nicht die neue SSD. Ohne -Test richtet das Skript das ein." }
    $wahl = (Read-Host 'Buchstabe der neuen SSD eingeben, oder P fuer eine Platte ohne Buchstaben (nur Enter = Abbruch)').Trim().TrimEnd(':').ToUpper()
    if (-not $wahl) { Abbruch 'Nichts gewaehlt.' }
    try {
        if ($wahl -eq 'P') {
            if (-not $ohne.Count) { Abbruch 'Es gibt keine Platte ohne Buchstaben.' }
            $nr = (Read-Host 'Nummer (Nr) der Platte').Trim()
            $pl = $ohne | Where-Object { [string]$_.Nr -eq $nr } | Select-Object -First 1
            if (-not $pl) { Abbruch "Platte $nr steht nicht in der Liste." }
            $d = Get-Disk -Number $pl.Nr
            if ($d.IsOffline) { Set-Disk -Number $d.Number -IsOffline $false -ErrorAction Stop }
            if ($d.IsReadOnly) { Set-Disk -Number $d.Number -IsReadOnly $false -ErrorAction Stop }
            if ($pl.Partition) {
                ZielFreimachen
                Set-Partition -DiskNumber $pl.Nr -PartitionNumber $pl.Partition -NewDriveLetter $ZielLW -ErrorAction Stop
            } else {
                Write-Host ("Platte {0} ({1}, {2} GB) ist leer. Sie wird eingerichtet: GPT, NTFS, Name '{3}', Laufwerk {4}:" -f $pl.Nr, $pl.Platte, $pl.GB, $Label, $ZielLW) -ForegroundColor Yellow
                if ((Read-Host 'Zum Bestaetigen JA eintippen') -ne 'JA') { Abbruch 'Nicht bestaetigt.' }
                ZielFreimachen
                $d = Get-Disk -Number $pl.Nr
                if ($d.PartitionStyle -eq 'RAW') { Initialize-Disk -Number $d.Number -PartitionStyle GPT -ErrorAction Stop }
                $neu = New-Partition -DiskNumber $d.Number -UseMaximumSize -DriveLetter $ZielLW -ErrorAction Stop
                $neu | Format-Volume -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false -ErrorAction Stop | Out-Null
            }
        } else {
            $v = $alle | Where-Object { $_.LW -eq $wahl } | Select-Object -First 1
            $g = Passt $v
            if ($g) { Abbruch "$($wahl): $g." }
            if ($wahl -ne $ZielLW) {
                ZielFreimachen
                SetzeBuchstabe $wahl $ZielLW
            }
        }
    } catch {
        Abbruch "Das Laufwerk liess sich nicht einrichten: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 3
    $e = @(Volumes) | Where-Object { $_.LW -eq $ZielLW } | Select-Object -First 1
    $g = Passt $e
    if ($g) { Abbruch "$($ZielLW): $g." }
    Ok "Die neue SSD ist jetzt $($ZielLW): ('$($e.Name)', $($e.GB) GB)."
}
if ($e.FS -ne 'NTFS') {
    Write-Host "   $($ZielLW): ist $($e.FS), nicht NTFS. Store-App-Daten und manche Spiele brauchen NTFS." -ForegroundColor Yellow
    if (-not $Test -and -not (Frage 'Trotzdem weitermachen?')) { Abbruch 'Abgebrochen.' }
}

# Angefangene Explorer-Kopie im falschen Ordner (E:\Game 3 SSD 500GB\...)? Inhalt gehoert direkt nach E:\.
$falsch = Join-Path $Ziel $Label
if (Test-Path -LiteralPath $falsch) {
    Write-Host "   Auf $($ZielLW): liegt der Ordner '$Label', wohl eine angefangene Explorer-Kopie." -ForegroundColor Yellow
    Info "Sein Inhalt gehoert direkt nach $Ziel, sonst finden Steam und die Apps ihn nicht."
    if (-not $Test -and (Frage "Inhalt nach $Ziel verschieben? (geht sofort, es wird nichts geloescht)")) {
        foreach ($x in @(Get-ChildItem -LiteralPath $falsch -Force)) {
            $dest = Join-Path $Ziel $x.Name
            if (Test-Path -LiteralPath $dest) { Info "bleibt liegen, weil es $dest schon gibt: $($x.Name)"; continue }
            try { Move-Item -LiteralPath $x.FullName -Destination $dest -ErrorAction Stop; Ok "verschoben: $($x.Name)" }
            catch { Warnung "Konnte $($x.Name) nicht verschieben: $($_.Exception.Message)" }
        }
        if (-not @(Get-ChildItem -LiteralPath $falsch -Force).Count) {
            Remove-Item -LiteralPath $falsch -Force
            Ok "Leeren Ordner $falsch entfernt."
        } else {
            Warnung "In $falsch liegt noch etwas, das es in $Ziel schon gab. Wenn alles laeuft, kannst du diesen Ordner loeschen."
        }
    }
}

# ---------------------------------------------------------------- 3. Platz
Schritt '3. Platz pruefen'
Info 'Vergleiche Sicherung und Ziel (dauert etwa 1 Minute) ...'
$liste = RoboListe
if ($liste.Code -ge 16) { Abbruch "robocopy kann die Sicherung nicht lesen (Code $($liste.Code))." }
$freiB = [int64](Get-Volume -DriveLetter $ZielLW).SizeRemaining
$minuten = $null
if ($null -ne $liste.Bytes) {
    Info ('Zu kopieren: {0:N0} Dateien, {1:N1} GB. Frei auf {2}: {3:N1} GB.' -f $liste.Dateien, ($liste.Bytes / 1GB), $Ziel, ($freiB / 1GB))
    if ($liste.Bytes -gt ($freiB - 1GB)) { Abbruch 'Auf der neuen SSD ist zu wenig Platz.' }
    $minuten = [math]::Max(1, [math]::Ceiling($liste.Bytes / 75MB / 60))
} else {
    Warnung 'Die Groesse liess sich nicht ermitteln. Bitte selbst pruefen, ob genug Platz frei ist.'
}

# ---------------------------------------------------------------- 4. Kopieren
if (-not $Test) {
    while (Get-Process -Name steam -ErrorAction SilentlyContinue) {
        Write-Host '   Steam laeuft noch. Bitte Steam beenden (Steam > Beenden).' -ForegroundColor Yellow
        if ((Read-Host '   Danach Enter druecken (W = trotzdem weiter)') -match '^\s*[Ww]') { break }
    }
    # Store-Apps, deren Daten auf E: liegen (z.B. Claude), muessen beim Kopieren zu sein.
    $paketeAufE = @(Get-ChildItem -LiteralPath (Join-Path $NutzerAppData 'Packages') -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
            @(Get-ChildItem -LiteralPath $_.FullName -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
                    $_.LinkType -and ([string](@($_.Target) | Select-Object -First 1)).StartsWith($Ziel, [StringComparison]::OrdinalIgnoreCase)
                }).Count
        } | ForEach-Object { $_.Name })
    foreach ($pkg in $paketeAufE) {
        if (-not (WarteBisZu $pkg)) { Warnung "$pkg war beim Kopieren offen. Falls es danach nicht startet: Skript noch mal laufen lassen." }
    }
    Write-Host ''
    $dauer = ''
    if ($minuten) { $dauer = " Das dauert etwa $minuten Minuten." }
    Write-Host "Jetzt wird $Quelle nach $Ziel kopiert.$dauer Geloescht wird nichts." -ForegroundColor Cyan
    Write-Host 'Schon Kopiertes wird uebersprungen, halb Kopiertes wird neu kopiert.'
    Write-Host 'Laeuft noch ein Kopierfenster vom Explorer? Dann das vorher abbrechen.' -ForegroundColor Yellow
    if (-not (Frage 'Starten?')) { Abbruch 'Nicht gestartet.' }

    # Standby verhindern, solange das Skript laeuft.
    try {
        Add-Type -Namespace SsdZurueck -Name Strom -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' -ErrorAction Stop
        [SsdZurueck.Strom]::SetThreadExecutionState([uint32]2147483649) | Out-Null
    } catch { }

    Schritt '4. Zurueckkopieren (robocopy)'
    Info "Protokoll: $RoboLog"
    $teile = @(Get-ChildItem -LiteralPath $Quelle -Directory -Force | Where-Object { @('System Volume Information', '$RECYCLE.BIN') -notcontains $_.Name })
    $t0 = Get-Date
    $i = 0
    foreach ($t in $teile) {
        $i++
        Write-Host ('   [{0}/{1}] {2:HH:mm}  {3}' -f $i, $teile.Count, (Get-Date), $t.Name)
        $rc = Robo $t.FullName (Join-Path $Ziel $t.Name) @('/E', '/MT:16')
        if ($rc -ge 8) { Warnung "Beim Kopieren von '$($t.Name)' gab es Fehler (robocopy $rc)." }
    }
    $rc = Robo $Quelle $Ziel @()   # Dateien direkt im Hauptordner
    if ($rc -ge 8) { Warnung "Beim Kopieren der Dateien im Hauptordner gab es Fehler (robocopy $rc)." }
    Ok ('Kopieren fertig nach {0:N0} Minuten.' -f ((Get-Date) - $t0).TotalMinutes)

    # ------------------------------------------------------------ 5. Pruefen
    Schritt '5. Kopie pruefen'
    $nach = RoboListe
    if ($nach.Code -lt 8 -and ($nach.Code -band 1) -eq 0) {
        Ok "Alles aus der Sicherung ist auf $($ZielLW):."
    } else {
        Warnung ("Noch nicht alles auf {0}: ({1} Dateien offen, Code {2}). Skript einfach noch mal starten, es macht dort weiter." -f $ZielLW, $nach.Dateien, $nach.Code)
    }
    $fz = @(Select-String -LiteralPath $RoboLog -Pattern '\(0x[0-9A-Fa-f]{8}\)' -ErrorAction SilentlyContinue)
    if ($fz.Count) {
        Info 'Fehler laut Protokoll (Auszug):'
        $fz | Select-Object -First 10 | ForEach-Object { Info $_.Line.Trim() }
    }
}

# ---------------------------------------------------------------- 6. Store-App-Daten
Schritt '6. Store-App-Daten (Claude, Codex ...)'
$Pakete = Join-Path $NutzerAppData 'Packages'
$wpOrdner = @()
$wpRoot = Join-Path $Quelle 'WpSystem'
if (Test-Path -LiteralPath $wpRoot) {
    $wpOrdner = @(Get-ChildItem -LiteralPath $wpRoot -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object @{ e = { $_.Name -ne $NutzerSid } } |
        ForEach-Object { Join-Path $_.FullName 'AppData\Local\Packages' } |
        Where-Object { Test-Path -LiteralPath $_ })
}

# a) Verknuepfungen (Junctions) von Store-Apps nach E: pruefen
$verbOk = 0
$verbRep = 0
foreach ($p in @(Get-ChildItem -LiteralPath $Pakete -Directory -Force -ErrorAction SilentlyContinue)) {
    foreach ($s in @(Get-ChildItem -LiteralPath $p.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($s.LinkType -ne 'Junction' -and $s.LinkType -ne 'SymbolicLink') { continue }
        $tgt = [string](@($s.Target) | Select-Object -First 1)
        if (-not $tgt -or $tgt.Length -lt 4) { continue }
        $name = "$($p.Name)\$($s.Name)"
        $aufZiel = $tgt.Substring(0, 1).ToUpper() -eq $ZielLW
        if ($aufZiel -and $p.Name -like 'Claude_*') { $ClaudeAufE = $true }
        if (Test-Path -LiteralPath $tgt) { $verbOk++; continue }
        if (-not $aufZiel) { Warnung "$name zeigt auf $tgt, das gibt es nicht."; continue }
        $ausKopie = Join-Path $Quelle $tgt.Substring(3)
        if ($Test) {
            if (Test-Path -LiteralPath $ausKopie) { Info "kommt mit der Kopie zurueck: $name" } else { Info "wuerde leer angelegt: $tgt" }
            continue
        }
        if (Test-Path -LiteralPath $ausKopie) { $null = Robo $ausKopie $tgt @('/E') } else { New-Item -ItemType Directory -Path $tgt -Force | Out-Null }
        if (Test-Path -LiteralPath $tgt) { $verbRep++; Ok "repariert: $name" } else { Warnung "$tgt liess sich nicht anlegen." }
    }
}
if ($verbRep) { Ok "$verbOk Store-App-Ordner auf $($ZielLW): sind da, $verbRep repariert." } else { Ok "$verbOk Store-App-Ordner auf $($ZielLW): sind da." }

# b) Umzug nach C: von vorhin (appdaten_nach_C.ps1) vervollstaendigen, falls er mittendrin abgebrochen ist
$umzugLog = Join-Path $LogOrdner 'appdaten_nach_C.log'
if ((Test-Path -LiteralPath $umzugLog) -and $wpOrdner.Count) {
    $fertig = @{}
    $angefasst = @{}
    foreach ($z in @(Get-Content -LiteralPath $umzugLog -Encoding UTF8)) {
        if ($z -match '^\d\d:\d\d:\d\d (\S+?)\\([^\\:]+): (OK|FEHLER)') {
            $angefasst[$Matches[1]] = $true
            if ($Matches[3] -eq 'OK') { $fertig["$($Matches[1])\$($Matches[2])"] = $true }
        } elseif ($z -match 'Claude-Umzug: Claude ist zu, starte Umzug') {
            $angefasst['Claude_pzs8sxrjxfjjc'] = $true
        }
    }
    $umzugOk = $true
    foreach ($pkg in @($angefasst.Keys)) {
        $c = Join-Path $Pakete $pkg
        if (-not (Test-Path -LiteralPath $c)) { continue }
        $k = $wpOrdner | ForEach-Object { Join-Path $_ $pkg } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $k) { continue }
        $offen = @()
        foreach ($s in @(Get-ChildItem -LiteralPath $k -Directory -Force -ErrorAction SilentlyContinue)) {
            $item = Get-Item -LiteralPath (Join-Path $c $s.Name) -Force -ErrorAction SilentlyContinue
            if ($item -and $item.LinkType) { continue }                  # noch Verknuepfung, siehe a)
            if ($item -and $fertig.ContainsKey("$pkg\$($s.Name)")) { continue }
            $offen += $s
        }
        if (-not $offen.Count) { continue }
        $umzugOk = $false
        $namen = ($offen | ForEach-Object { $_.Name }) -join ', '
        if ($Test) { Info "$pkg : Umzug nach C: ist unvollstaendig ($namen), wuerde aus der Sicherung ergaenzt."; continue }
        Info "$pkg : Umzug nach C: ist unvollstaendig ($namen). Wird aus der Sicherung ergaenzt."
        if (-not (WarteBisZu $pkg)) { Warnung "$pkg wurde nicht ergaenzt (uebersprungen)."; continue }
        foreach ($s in $offen) {
            $cs = Join-Path $c $s.Name
            if (-not (Test-Path -LiteralPath $cs)) { New-Item -ItemType Directory -Path $cs -Force | Out-Null }
            $rc = Robo $s.FullName $cs @('/E')
            if ($rc -lt 8) { Ok "$pkg\$($s.Name) ergaenzt." } else { Warnung "$pkg\$($s.Name): robocopy-Fehler $rc." }
        }
    }
    if ($umzugOk) { Ok 'Die Store-App-Daten, die vorhin nach C: umgezogen sind, sind vollstaendig.' }
}

# ---------------------------------------------------------------- 7. Neue Store-Apps
Schritt '7. Speicherort fuer neue Store-Apps'
try {
    $sysVol = Get-AppxVolume -ErrorAction Stop | Where-Object { $_.IsSystemVolume } | Select-Object -First 1
    $defVol = Get-AppxDefaultVolume -ErrorAction Stop
    if ($sysVol -and $defVol -and $defVol.Name -ne $sysVol.Name) {
        Info "Neue Store-Apps landen noch auf $($defVol.PackageStorePath) (alte SSD, gibt es nicht mehr)."
        if (-not $Test) {
            Set-AppxDefaultVolume -Volume $sysVol -ErrorAction Stop
            Ok "Neue Store-Apps werden jetzt auf $($sysVol.PackageStorePath) gespeichert."
        }
    } else {
        Ok 'Neue Store-Apps werden auf C: gespeichert.'
    }
} catch {
    Warnung ("Speicherort fuer neue Apps nicht geaendert ({0}). Von Hand: Einstellungen > System > Speicher > Erweiterte Speichereinstellungen > Speicherort fuer neue Inhalte > Neue Apps: C:" -f $_.Exception.Message)
}

# ---------------------------------------------------------------- 8. Steam, Dienste, Verknuepfungen
Schritt '8. Steam'
$steamPfad = $null
foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam') {
    $x = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
    if ($x -and $x.SteamPath) { $steamPfad = $x.SteamPath; break }
    if ($x -and $x.InstallPath) { $steamPfad = $x.InstallPath; break }
}
$vdf = $null
if ($steamPfad) { $vdf = Join-Path ($steamPfad -replace '/', '\') 'steamapps\libraryfolders.vdf' }
if ($vdf -and (Test-Path -LiteralPath $vdf)) {
    $bib = @([regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' })
    foreach ($b in $bib) {
        if ($b.Substring(0, 1).ToUpper() -ne $ZielLW) { continue }
        if (Test-Path -LiteralPath $b) { Ok "Steam-Bibliothek $b ist wieder da." } else { Warnung "Steam-Bibliothek $b fehlt." }
    }
    foreach ($kand in @(Get-ChildItem -LiteralPath $Ziel -Directory -Force -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'steamapps') })) {
        $bekannt = $bib | Where-Object { $_.TrimEnd('\') -ieq $kand.FullName.TrimEnd('\') }
        if (-not $bekannt) { Warnung "Steam kennt $($kand.FullName) nicht mehr. In Steam: Einstellungen > Speicher > Laufwerk hinzufuegen > $($kand.FullName)" }
    }
} else {
    Info 'Steam-Bibliotheksliste nicht gefunden, uebersprungen.'
}

Schritt "9. Dienste, Verknuepfungen und Autostart nach $($ZielLW):"
$muster = '^\s*"?' + $ZielLW + ':\\'
foreach ($svc in @(Get-CimInstance Win32_Service | Where-Object { $_.PathName -and $_.PathName -match $muster })) {
    $exe = ExeAusBefehl $svc.PathName
    if (-not (Test-Path -LiteralPath $exe)) { Warnung "Dienst '$($svc.DisplayName)': $exe fehlt."; continue }
    if ($svc.StartMode -eq 'Auto' -and $svc.State -ne 'Running') {
        if ($Test) { Info "Dienst '$($svc.DisplayName)' wuerde gestartet."; continue }
        try { Start-Service -Name $svc.Name -ErrorAction Stop; Ok "Dienst '$($svc.DisplayName)' gestartet." }
        catch { Warnung "Dienst '$($svc.DisplayName)' startet nicht: $($_.Exception.Message)" }
    } else {
        Ok "Dienst '$($svc.DisplayName)' ist in Ordnung."
    }
}

$sh = New-Object -ComObject WScript.Shell
$orte = @(
    (Join-Path $NutzerProfil 'AppData\Roaming\Microsoft\Windows\Start Menu'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu'),
    (Join-Path $NutzerProfil 'Desktop'),
    (Join-Path $NutzerProfil 'OneDrive\Desktop'),
    (Join-Path $env:PUBLIC 'Desktop')
) | Where-Object { Test-Path -LiteralPath $_ }
$lnkOk = 0
foreach ($l in @(Get-ChildItem -LiteralPath $orte -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
    $t = $null
    try { $t = $sh.CreateShortcut($l.FullName).TargetPath } catch { }
    if (-not $t -or $t.Length -lt 3 -or $t.Substring(0, 1).ToUpper() -ne $ZielLW) { continue }
    if (Test-Path -LiteralPath $t) { $lnkOk++ } else { Warnung "Verknuepfung '$($l.BaseName)' zeigt auf $t, das fehlt." }
}
Ok "$lnkOk Verknuepfungen nach $($ZielLW): funktionieren."

foreach ($rk in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
    $werte = Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue
    if (-not $werte) { continue }
    foreach ($w in @($werte.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
        $exe = ExeAusBefehl ([string]$w.Value)
        if ($exe.Length -lt 3 -or $exe.Substring(0, 1).ToUpper() -ne $ZielLW) { continue }
        if (Test-Path -LiteralPath $exe) { Ok "Autostart '$($w.Name)' ist in Ordnung." } else { Warnung "Autostart '$($w.Name)' zeigt auf $exe, das fehlt." }
    }
}

$xbox = Join-Path $Ziel 'XboxGames'
if (Test-Path -LiteralPath $xbox) {
    $spiele = @(Get-ChildItem -LiteralPath $xbox -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'GameSave' } | ForEach-Object { $_.Name })
    if ($spiele.Count) { Warnung ("Xbox-Spiele ({0}) bitte in der Xbox-App neu installieren. Deren Store-Teil (E:\WindowsApps) liess sich nicht sichern." -f ($spiele -join ', ')) }
}

# ---------------------------------------------------------------- 10. Lange Pfade
Schritt '10. Lange Dateipfade'
$fsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
$lp = (Get-ItemProperty -Path $fsKey -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
if ($lp -eq 1) {
    Ok 'Lange Pfade sind schon erlaubt.'
} elseif ($Test) {
    Info 'Lange Pfade wuerden erlaubt.'
} else {
    try {
        Set-ItemProperty -Path $fsKey -Name LongPathsEnabled -Value 1 -Type DWord -ErrorAction Stop
        Ok 'Lange Pfade sind jetzt erlaubt (hilft Programmen, der Explorer bleibt bei 260 Zeichen).'
    } catch { Warnung "Lange Pfade nicht eingeschaltet: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- Fertig
Schritt 'Fertig'
if ($Test) { Info 'Das war nur ein Testlauf, es wurde nichts geaendert.' }
if ($Hinweise.Count) {
    Write-Host '   Bitte ansehen:' -ForegroundColor Yellow
    foreach ($h in $Hinweise) { Write-Host "    - $h" -ForegroundColor Yellow }
} else {
    Ok 'Keine Probleme gefunden.'
}
if (-not $Test) {
    Info 'Jetzt Claude, Steam usw. ganz normal starten.'
    if ($ClaudeAufE) { Info 'Falls Claude nach der Anmeldung fragt: einfach neu anmelden (2 Cookie-Dateien fehlten in der Sicherung).' }
    Info "Die Sicherung $Quelle bleibt liegen. Loesch sie erst, wenn alles laeuft."
}
Info "Protokolle: $LogOrdner"
Ende 0
