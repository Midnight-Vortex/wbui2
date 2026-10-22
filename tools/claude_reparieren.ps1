<#
claude_reparieren.ps1
Repariert die Claude-Desktop-App, wenn sie nach dem SSD-Tausch nicht mehr startet
(z.B. "Claude ist offline ... Das Speichergeraet ist moeglicherweise nicht vorhanden").

Ursache: Die Programmdateien von Claude lagen auf der alten SSD (E:\WindowsApps).
Die Daten (Anmeldung, Chats, Einstellungen) liegen auf C: und bleiben erhalten.

Ablauf:
  1. Claude-Installation pruefen.
  2. Claude schliessen und die Daten nach E:\Claude-Datensicherung sichern.
     Die Sicherung wird geprueft, erst dann geht es weiter.
  3. Die kaputte Installation austragen.
  4. claude.ai/download oeffnen. Du installierst Claude neu.
  5. Die gesicherten Daten zurueckspielen.
  6. Claude starten.
  7. Pruefen, ob noch andere Store-Apps kaputt sind (z.B. Outlook).

Die Sicherung bleibt liegen. Adminrechte braucht es nur, falls Windows das
Austragen sonst verweigert; dann fragt es einmal nach.

Start: Rechtsklick auf die Datei > "Mit PowerShell ausfuehren".
#>
param(
    [string]$SicherungsLW = 'E'
)

# Die Appx-Befehle gibt es nur in Windows PowerShell 5.1.
if ($PSVersionTable.PSEdition -eq 'Core') {
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -SicherungsLW $SicherungsLW"
    exit
}

$Familie = 'Claude_pzs8sxrjxfjjc'
$SicherungsLW = $SicherungsLW.Trim().Substring(0, 1).ToUpper()
$DatenOrdner = Join-Path $env:LOCALAPPDATA "Packages\$Familie"
$SicherungsRoot = "$($SicherungsLW):\Claude-Datensicherung"
$Stempel = Get-Date -Format 'yyyyMMdd_HHmm'
$Sicherung = Join-Path $SicherungsRoot $Stempel
$Teile = @('LocalCache', 'LocalState', 'RoamingState')
$SquirrelOrdner = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
$SquirrelVorher = Test-Path -LiteralPath $SquirrelOrdner
$Hinweise = New-Object 'System.Collections.Generic.List[string]'

$LogOrdner = Join-Path $env:USERPROFILE 'Documents\Codex\SSD-Kopie'
if (-not (Test-Path -LiteralPath $LogOrdner)) { New-Item -ItemType Directory -Path $LogOrdner -Force | Out-Null }
$RoboLog = Join-Path $LogOrdner "robocopy_claude_$Stempel.log"
try { Start-Transcript -Path (Join-Path $LogOrdner "claude_reparieren_$Stempel.txt") -Force | Out-Null } catch { }
try { $Host.UI.RawUI.WindowTitle = 'Claude reparieren' } catch { }

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
    Write-Host "Protokolle: $LogOrdner"
    Ende 1
}
function Frage([string]$t) { return ((Read-Host "$t (J/N)") -match '^\s*[JjYy]') }

function ClaudePaket {
    Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Where-Object { $_.PackageFamilyName -eq $Familie } | Select-Object -First 1
}
function PaketHeil($pk) {
    return ($pk -and $pk.InstallLocation -and (Test-Path -LiteralPath (Join-Path $pk.InstallLocation 'AppxManifest.xml')))
}
function ClaudeProzesse {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ExecutablePath -and ($_.ExecutablePath -like '*\WindowsApps\Claude_*' -or $_.ExecutablePath -like '*\AnthropicClaude\*')
        })
}
function ClaudeSchliessen {
    if (-not (ClaudeProzesse).Count) { return }
    Info 'Schliesse Claude ...'
    foreach ($x in ClaudeProzesse) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    if ((ClaudeProzesse).Count) { Abbruch 'Claude laesst sich nicht schliessen. Bitte Claude unten rechts im Tray beenden und das Skript neu starten.' }
}
function ClaudeStarten {
    if ($script:Art -eq 'exe') {
        Start-Process -FilePath (Join-Path $SquirrelOrdner 'claude.exe')
        return
    }
    $appId = 'Claude'
    try {
        $m = Get-AppxPackageManifest -Package (ClaudePaket).PackageFullName -ErrorAction Stop
        $appId = @($m.Package.Applications.Application)[0].Id
    } catch { }
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$Familie!$appId"
}

# robocopy: kopiert Ordner samt Inhalt, ueberschreibt Abweichendes, loescht nie. Kann lange Pfade.
function Robo([string]$Von, [string]$Nach) {
    $a = @($Von, $Nach, '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/R:1', '/W:1', '/NP', '/NFL', '/NDL', "/UNILOG+:$RoboLog")
    & robocopy.exe @a | Out-Null
    return $LASTEXITCODE
}
# robocopy-Listenlauf: Gesamtgroesse und was noch fehlt.
function RoboPruef([string]$Von, [string]$Nach) {
    $out = @(& robocopy.exe $Von $Nach /L /E /XJ /BYTES /NFL /NDL /NJH /R:0 /W:0)
    $erg = [pscustomobject]@{ Code = $LASTEXITCODE; Bytes = [int64]0 }
    foreach ($z in $out) { if ($z -match '^\s*Bytes\s*:\s*(\d+)\s+(\d+)') { $erg.Bytes = [int64]$Matches[1] } }
    return $erg
}

# ---------------------------------------------------------------- 1. Pruefen
Schritt '1. Claude-Installation pruefen'
$pk = ClaudePaket
if ($pk) {
    Info "Installiert: Claude $($pk.Version)"
    Info "Programmordner: $($pk.InstallLocation)"
    if (PaketHeil $pk) {
        Info 'Die Programmdateien sind da.'
        if (-not (Frage 'Claude trotzdem neu installieren? Deine Daten werden vorher gesichert und danach zurueckgespielt.')) { Ende 0 }
    } else {
        Write-Host '       Die Programmdateien fehlen (sie lagen auf der alten SSD). Deshalb startet Claude nicht.' -ForegroundColor Yellow
    }
} else {
    Info 'Claude ist gerade nicht installiert.'
}

# ---------------------------------------------------------------- 2. Sichern
Schritt '2. Claude-Daten sichern'
$WiederAus = $null
if (Test-Path -LiteralPath (Join-Path $DatenOrdner 'LocalCache')) {
    ClaudeSchliessen
    if (-not (Test-Path -LiteralPath "$($SicherungsLW):\")) { Abbruch "Laufwerk $($SicherungsLW): fuer die Sicherung gibt es nicht." }
    $groesse = [int64]0
    foreach ($t in $Teile) {
        $v = Join-Path $DatenOrdner $t
        if (Test-Path -LiteralPath $v) { $groesse += (RoboPruef $v (Join-Path $Sicherung $t)).Bytes }
    }
    $frei = [int64](Get-Volume -DriveLetter $SicherungsLW -ErrorAction SilentlyContinue).SizeRemaining
    Info ('Claude-Daten: {0:N1} GB. Frei auf {1}: {2:N1} GB.' -f ($groesse / 1GB), $SicherungsLW, ($frei / 1GB))
    if ($frei -gt 0 -and $groesse -gt ($frei - 1GB)) { Abbruch 'Zu wenig Platz fuer die Sicherung. Es wurde nichts veraendert.' }
    Info "Sichere nach $Sicherung ..."
    foreach ($t in $Teile) {
        $v = Join-Path $DatenOrdner $t
        if (-not (Test-Path -LiteralPath $v)) { continue }
        $ziel = Join-Path $Sicherung $t
        $rc = Robo $v $ziel
        $nach = RoboPruef $v $ziel
        if ($rc -ge 8 -or $nach.Code -ge 8 -or ($nach.Code -band 1)) {
            Abbruch "Die Sicherung von $t ist unvollstaendig (robocopy $rc / $($nach.Code)). An Claude wurde nichts veraendert."
        }
        Ok "$t gesichert."
    }
    $WiederAus = $Sicherung
    Ok "Sicherung geprueft: $Sicherung"
} else {
    # Keine aktuellen Daten auf C: (z.B. weil ein frueherer Lauf schon ausgetragen hat): aeltere Sicherungen suchen.
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $kandidaten = @()
    $kandidaten += @(Get-ChildItem -LiteralPath $SicherungsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object { $_.FullName })
    $kandidaten += "$($SicherungsLW):\WpSystem\$sid\AppData\Local\Packages\$Familie"
    $kandidaten += "D:\Game 3 SSD 500GB\WpSystem\$sid\AppData\Local\Packages\$Familie"
    $WiederAus = $kandidaten | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'LocalCache') } | Select-Object -First 1
    if ($WiederAus) {
        Warnung "Auf C: sind keine Claude-Daten. Es wird die Sicherung $WiederAus genommen."
    } else {
        Warnung 'Keine Claude-Daten gefunden. Claude wird frisch installiert, du musst dich neu anmelden.'
    }
}

# ---------------------------------------------------------------- 3. Austragen
Schritt '3. Kaputte Installation austragen'
$pk = ClaudePaket
if ($pk) {
    ClaudeSchliessen
    $full = $pk.PackageFullName
    try {
        Remove-AppxPackage -Package $full -ErrorAction Stop
    } catch {
        Info "Ohne Adminrechte ging es nicht: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 2
    if (ClaudePaket) {
        Info 'Versuche es mit Adminrechten (bitte mit Ja bestaetigen) ...'
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ErrorAction Stop `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"Remove-AppxPackage -Package '$full' -AllUsers`""
        } catch { }
        Start-Sleep -Seconds 2
    }
    if (ClaudePaket) { Abbruch "Windows laesst die alte Claude-Installation nicht austragen. Deine Daten sind gesichert in $WiederAus." }
    Ok 'Alte Installation ausgetragen.'
} else {
    Info 'Nichts auszutragen.'
}

# ---------------------------------------------------------------- 4. Neu installieren
Schritt '4. Claude neu installieren'
Info 'Im Browser oeffnet sich claude.ai/download.'
Info 'Lade dort Claude fuer Windows herunter und installiere es.'
Info 'Startet Claude danach von selbst, musst du dich noch nicht anmelden.'
Start-Process 'https://claude.ai/download'
$Art = $null
while (-not $Art) {
    $a = Read-Host '       Wenn die Installation fertig ist: Enter druecken (A = Abbruch)'
    if ($a -match '^\s*[Aa]') { Abbruch "Abgebrochen. Deine Daten liegen in $WiederAus. Skript spaeter einfach noch mal starten." }
    $pk = ClaudePaket
    if (PaketHeil $pk) { $Art = 'msix'; Ok "Claude $($pk.Version) ist installiert."; break }
    if (-not $SquirrelVorher -and (Test-Path -LiteralPath (Join-Path $SquirrelOrdner 'claude.exe'))) { $Art = 'exe'; Ok "Claude ist installiert ($SquirrelOrdner)."; break }
    Write-Host '       Claude ist noch nicht (fertig) installiert.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 5. Zurueckspielen
Schritt '5. Daten zurueckspielen'
if (-not $WiederAus) {
    Info 'Keine Daten zum Zurueckspielen.'
} elseif ($Art -eq 'msix') {
    # Den Datenordner legt Windows beim ersten Start an.
    if (-not (Test-Path -LiteralPath (Join-Path $DatenOrdner 'LocalCache'))) {
        Info 'Starte Claude einmal kurz, damit Windows den Datenordner anlegt ...'
        ClaudeStarten
        $bis = (Get-Date).AddSeconds(60)
        while (-not (Test-Path -LiteralPath (Join-Path $DatenOrdner 'LocalCache')) -and (Get-Date) -lt $bis) { Start-Sleep -Seconds 2 }
        Start-Sleep -Seconds 5
    }
    ClaudeSchliessen
    foreach ($t in $Teile) {
        $v = Join-Path $WiederAus $t
        if (-not (Test-Path -LiteralPath $v)) { continue }
        $rc = Robo $v (Join-Path $DatenOrdner $t)
        if ($rc -ge 8) { Warnung "$t ist nicht ganz zurueckgespielt (robocopy $rc). Protokoll: $RoboLog" } else { Ok "$t zurueckgespielt." }
    }
} else {
    # Claude als normale Windows-Installation: Daten liegen dann in %APPDATA%\Claude.
    ClaudeSchliessen
    $v = Join-Path $WiederAus 'LocalCache\Roaming\Claude'
    if (Test-Path -LiteralPath $v) {
        $rc = Robo $v (Join-Path $env:APPDATA 'Claude')
        if ($rc -ge 8) { Warnung "Daten nicht ganz zurueckgespielt (robocopy $rc). Protokoll: $RoboLog" } else { Ok 'Daten nach %APPDATA%\Claude zurueckgespielt.' }
    } else {
        Info 'In der Sicherung sind keine Claude-Daten.'
    }
}

# ---------------------------------------------------------------- 6. Starten
Schritt '6. Claude starten'
ClaudeStarten
Ok 'Claude startet. Fragt es nach der Anmeldung, melde dich einfach an.'

# ---------------------------------------------------------------- 7. Andere Store-Apps
Schritt '7. Andere Store-Apps pruefen'
$kaputt = @(Get-AppxPackage -PackageTypeFilter Main, Framework -ErrorAction SilentlyContinue | Where-Object {
        -not $_.InstallLocation -or -not (Test-Path -LiteralPath (Join-Path $_.InstallLocation 'AppxManifest.xml'))
    })
if (-not $kaputt.Count) {
    Ok 'Keine weiteren Store-Apps mit fehlenden Dateien.'
} else {
    foreach ($k in $kaputt) { Warnung "Store-App '$($k.Name)' hat keine Programmdateien mehr ($($k.InstallLocation))." }
    if ($kaputt | Where-Object { $_.Name -eq 'Microsoft.OutlookForWindows' }) {
        Info 'Outlook reparieren (Mails kommen vom Server zurueck):'
        Info '  Get-AppxPackage Microsoft.OutlookForWindows | Remove-AppxPackage'
        Info '  winget install --id 9NRX63209R7B --source msstore --accept-package-agreements --accept-source-agreements'
    }
    Info 'Andere Apps hier bitte nicht einfach deinstallieren, sondern die Liste an Claude schicken.'
}

# ---------------------------------------------------------------- Fertig
Schritt 'Fertig'
if ($Hinweise.Count) {
    Write-Host '   Bitte ansehen:' -ForegroundColor Yellow
    foreach ($h in $Hinweise) { Write-Host "    - $h" -ForegroundColor Yellow }
}
if ($WiederAus -and $WiederAus -like "$SicherungsRoot*") { Info "Die Sicherung bleibt in $WiederAus. Loesch sie, wenn Claude ein paar Tage laeuft." }
Info "Protokolle: $LogOrdner"
Ende 0
