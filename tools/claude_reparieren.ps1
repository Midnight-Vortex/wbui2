<#
claude_reparieren.ps1
Repariert die Claude-Desktop-App, wenn sie nach dem SSD-Tausch nicht mehr startet
(z.B. "Claude ist offline ... Das Speichergeraet ist moeglicherweise nicht vorhanden")
oder das Claude-Setup mit "AddPackage failed with HRESULT 0x80073D0D" abbricht.

Ursache: Windows hat Claude noch auf der alten SSD (altes E:\WindowsApps)
eingetragen. Diese Platte ist weg ("offline"), also startet Claude nicht, und
das Setup bleibt am alten Eintrag haengen. Die Daten (Anmeldung, Chats,
Einstellungen) liegen auf C: und bleiben erhalten.

Ablauf:
  1. Claude-Eintraege und die alte, fehlende Platte anzeigen.
  2. Claude schliessen und die Daten nach E:\Claude-Datensicherung sichern.
     Die Sicherung wird geprueft, erst dann geht es weiter.
  3. Alle alten Claude-Eintraege austragen (fuer alle Benutzer, auch halb
     installierte) und den Eintrag der alten Platte aufraeumen.
  4. claude.ai/download oeffnen. Du installierst Claude neu.
  5. Die gesicherten Daten zurueckspielen.
  6. Claude starten.
  7. Pruefen, ob noch andere Store-Apps kaputt sind (z.B. Outlook).

Laeuft mit Adminrechten (fragt beim Start). Die Sicherung bleibt liegen.
Ein zweiter Lauf ist kein Problem: er nimmt dann die letzte Sicherung.

Start: Rechtsklick auf die Datei > "Mit PowerShell ausfuehren".
#>
param(
    [string]$SicherungsLW = 'E',
    [string]$NutzerAppData = $env:LOCALAPPDATA,
    [string]$NutzerRoaming = $env:APPDATA,
    [string]$NutzerProfil = $env:USERPROFILE,
    [string]$NutzerSid = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
)

# ---------------------------------------------------------------- Windows PowerShell + Adminrechte
$ich = [Security.Principal.WindowsIdentity]::GetCurrent()
$istAdmin = ([Security.Principal.WindowsPrincipal]$ich).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($PSVersionTable.PSEdition -eq 'Core' -or -not $istAdmin) {
    if (-not $PSCommandPath) {
        Write-Host 'Bitte das Skript als Datei speichern und per Rechtsklick > "Mit PowerShell ausfuehren" starten.' -ForegroundColor Red
        return
    }
    $argListe = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -SicherungsLW {1} -NutzerAppData "{2}" -NutzerRoaming "{3}" -NutzerProfil "{4}" -NutzerSid {5}' -f `
        $PSCommandPath, $SicherungsLW, $NutzerAppData, $NutzerRoaming, $NutzerProfil, $NutzerSid
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argListe -ErrorAction Stop
    } catch {
        Write-Host 'Ohne Administratorrechte geht es nicht. Abgebrochen.' -ForegroundColor Red
        Read-Host 'Enter zum Schliessen' | Out-Null
    }
    exit
}

# ---------------------------------------------------------------- Grundlagen
$Familie = 'Claude_pzs8sxrjxfjjc'
$SicherungsLW = $SicherungsLW.Trim().Substring(0, 1).ToUpper()
$DatenOrdner = Join-Path $NutzerAppData "Packages\$Familie"
$SicherungsRoot = "$($SicherungsLW):\Claude-Datensicherung"
$Stempel = Get-Date -Format 'yyyyMMdd_HHmm'
$Sicherung = Join-Path $SicherungsRoot $Stempel
$Teile = @('LocalCache', 'LocalState', 'RoamingState')
$SquirrelOrdner = Join-Path $NutzerAppData 'AnthropicClaude'
$SquirrelVorher = Test-Path -LiteralPath $SquirrelOrdner
$Hinweise = New-Object 'System.Collections.Generic.List[string]'
$Art = $null

$LogOrdner = Join-Path $NutzerProfil 'Documents\Codex\SSD-Kopie'
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

function DateienDa($pk) {
    if (-not $pk -or -not $pk.InstallLocation) { return $false }
    try { return [bool](Test-Path -LiteralPath ([IO.Path]::Combine($pk.InstallLocation, 'AppxManifest.xml')) -ErrorAction Stop) } catch { return $false }
}
# Programmdateien fehlen und der Programmordner liegt nicht auf C:, also auf der alten SSD.
# (Windows fuehrt auch Reste eigener Bausteine ohne Dateien auf C:; die sind normal und harmlos.)
function AufAlterSsd($pk) {
    return ($pk -and $pk.InstallLocation -and
        -not $pk.InstallLocation.StartsWith($env:SystemDrive, [StringComparison]::OrdinalIgnoreCase) -and
        -not (DateienDa $pk))
}
# Claude fuer diesen Benutzer
function ClaudePaket {
    Get-AppxPackage -User $NutzerSid -Name 'Claude' -ErrorAction SilentlyContinue | Where-Object { $_.PackageFamilyName -eq $Familie } | Select-Object -First 1
}
# Alle Claude-Eintraege auf dem PC (alle Benutzer, alle Versionen, auch nur bereitgestellte)
function AlleClaude {
    @(Get-AppxPackage -AllUsers -Name 'Claude' -ErrorAction SilentlyContinue | Where-Object { $_.PackageFamilyName -eq $Familie })
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
# Startet Claude ohne Adminrechte (ueber den Explorer).
function ClaudeStarten {
    if ($script:Art -eq 'exe') {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + (Join-Path $SquirrelOrdner 'claude.exe') + '"')
        return
    }
    $appId = 'Claude'
    try {
        $m = Get-AppxPackageManifest -Package (ClaudePaket).PackageFullName -User $NutzerSid -ErrorAction Stop
        $appId = @($m.Package.Applications.Application)[0].Id
    } catch { }
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$Familie!$appId"
}

# robocopy: kopiert Ordner samt Inhalt, ueberschreibt Abweichendes, loescht nie. Kann lange Pfade.
function Robo([string]$Von, [string]$Nach) {
    $a = @($Von, $Nach, '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/B', '/R:1', '/W:1', '/NP', '/NFL', '/NDL', "/UNILOG+:$RoboLog")
    & robocopy.exe @a | Out-Null
    return $LASTEXITCODE
}
# robocopy-Listenlauf: Gesamtgroesse und ob noch etwas fehlt.
function RoboPruef([string]$Von, [string]$Nach) {
    $out = @(& robocopy.exe $Von $Nach /L /E /XJ /BYTES /NFL /NDL /NJH /R:0 /W:0)
    $erg = [pscustomobject]@{ Code = $LASTEXITCODE; Bytes = [int64]0 }
    foreach ($z in $out) { if ($z -match '^\s*Bytes\s*:\s*(\d+)\s+(\d+)') { $erg.Bytes = [int64]$Matches[1] } }
    return $erg
}

# ---------------------------------------------------------------- 1. Pruefen
Schritt '1. Claude-Eintraege und alte Platte pruefen'
$alleClaude = AlleClaude
if ($alleClaude.Count) {
    foreach ($p in $alleClaude) {
        $zustand = 'Dateien da'
        if (AufAlterSsd $p) { $zustand = 'liegt auf der ALTEN SSD' }
        elseif (-not (DateienDa $p)) { $zustand = 'alter Rest auf C:, stoert nicht' }
        Info ("Claude {0}: {1}  [{2}]" -f $p.Version, $p.InstallLocation, $zustand)
    }
} else {
    Info 'Claude ist auf diesem PC nicht eingetragen.'
}
$offline = @()
try { $offline = @(Get-AppxVolume -ErrorAction Stop | Where-Object { $_.IsOffline }) } catch { }
foreach ($v in $offline) { Info "Fehlende Platte fuer Store-Apps: $($v.PackageStorePath) ($($v.Name))" }

$pk = ClaudePaket
if ($pk -and (DateienDa $pk) -and -not @($alleClaude | Where-Object { AufAlterSsd $_ }).Count) {
    Info 'Claude sieht vollstaendig aus.'
    if (-not (Frage 'Claude trotzdem neu installieren? Deine Daten werden vorher gesichert und danach zurueckgespielt.')) { Ende 0 }
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
    # Keine aktuellen Daten auf C: (z.B. weil ein frueherer Lauf schon ausgetragen hat): Sicherungen suchen.
    $kandidaten = @()
    $kandidaten += @(Get-ChildItem -LiteralPath $SicherungsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object { $_.FullName })
    $kandidaten += "$($SicherungsLW):\WpSystem\$NutzerSid\AppData\Local\Packages\$Familie"
    $kandidaten += "D:\Game 3 SSD 500GB\WpSystem\$NutzerSid\AppData\Local\Packages\$Familie"
    $WiederAus = $kandidaten | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'LocalCache') } | Select-Object -First 1
    if ($WiederAus) {
        Ok "Auf C: sind keine Claude-Daten mehr, es wird die Sicherung genommen: $WiederAus"
    } else {
        Warnung 'Keine Claude-Daten gefunden. Claude wird frisch installiert, du musst dich neu anmelden.'
    }
}

# ---------------------------------------------------------------- 3. Austragen und aufraeumen
Schritt '3. Alte Claude-Eintraege austragen'
ClaudeSchliessen
foreach ($p in AlleClaude) {
    $full = $p.PackageFullName
    try {
        Remove-AppxPackage -Package $full -AllUsers -ErrorAction Stop
        Ok "ausgetragen: $full"
    } catch {
        try {
            Remove-AppxPackage -Package $full -User $NutzerSid -ErrorAction Stop
            Ok "ausgetragen (nur dein Benutzer): $full"
        } catch {
            Info "$full liess sich so nicht austragen: $($_.Exception.Message)"
        }
    }
}
Start-Sleep -Seconds 2

# Store-Apps (ohne Claude), die auf der alten SSD liegen
function AppsOhneDateien {
    @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
            $_.PackageFamilyName -ne $Familie -and (AufAlterSsd $_)
        })
}

# Outlook liegt evtl. auch dort; seine Mails liegen auf dem Server.
$outlook = @(AppsOhneDateien | Where-Object { $_.Name -eq 'Microsoft.OutlookForWindows' })
if ($outlook.Count -and (Frage 'Outlook liegt auch noch auf der alten SSD und startet deshalb nicht. Austragen, damit es sich neu installieren laesst? Deine Mails liegen auf dem Server.')) {
    foreach ($o in $outlook) {
        try { Remove-AppxPackage -Package $o.PackageFullName -AllUsers -ErrorAction Stop; Ok "ausgetragen: $($o.PackageFullName)" }
        catch { Info "Outlook liess sich so nicht austragen: $($_.Exception.Message)" }
    }
    $Hinweise.Add('Outlook neu installieren: im Microsoft Store "Outlook fuer Windows" suchen und installieren.')
}

# Haengt Claude noch an der fehlenden Platte, den Eintrag der Platte selbst entfernen.
# Windows traegt dabei alle Apps aus, die nur noch dort liegen (die starten ohnehin nicht mehr).
if (@(AlleClaude | Where-Object { AufAlterSsd $_ }).Count) {
    Info 'Claude haengt noch an der alten SSD. Entferne deren Eintrag fuer Store-Apps ...'
    if (-not $offline.Count) { Info 'Windows meldet keine fehlende Platte fuer Store-Apps.' }
    foreach ($v in $offline) {
        $andere = @(AppsOhneDateien)
        if ($andere.Count) {
            Write-Host '       Diese Apps liegen auch auf der alten SSD und wuerden mit ausgetragen:' -ForegroundColor Yellow
            foreach ($a in $andere) { Write-Host "         - $($a.Name)" -ForegroundColor Yellow }
            Info 'Dabei gingen ihre Daten verloren. Deshalb hier abbrechen und Claude ein Bild von dieser Liste schicken.'
            Abbruch "Nichts weiter geaendert. Deine Claude-Daten sind gesichert in $WiederAus."
        }
        try { Remove-AppxVolume -Volume $v -ErrorAction Stop; Ok "Eintrag der alten SSD ($($v.PackageStorePath)) entfernt." }
        catch { Warnung "Eintrag der alten SSD liess sich nicht entfernen: $($_.Exception.Message)" }
    }
    Start-Sleep -Seconds 2
    foreach ($p in AlleClaude) {
        if (-not (AufAlterSsd $p)) { continue }
        try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; Ok "ausgetragen: $($p.PackageFullName)" } catch { }
    }
}
$rest = @(AlleClaude | Where-Object { AufAlterSsd $_ })
if ($rest.Count) {
    Abbruch ("Windows laesst den alten Claude-Eintrag ({0}) nicht austragen, solange die alte SSD fehlt. Deine Daten sind gesichert in {1}. Ausweg: die alte SSD kurz wieder anschliessen (z.B. per USB-Adapter) und das Skript noch mal starten. Oder schick Claude dieses Fenster." -f (($rest | ForEach-Object { $_.PackageFullName }) -join ', '), $WiederAus)
}
Ok 'Claude haengt nicht mehr an der alten SSD.'

foreach ($d in AppsOhneDateien) { Warnung "Store-App '$($d.Name)' liegt noch auf der alten SSD und startet nicht. Liste an Claude schicken, nicht selbst deinstallieren." }

# Neue Store-Apps (und damit auch Claude) auf C: installieren
try {
    $sysVol = Get-AppxVolume -ErrorAction Stop | Where-Object { $_.IsSystemVolume } | Select-Object -First 1
    $defVol = Get-AppxDefaultVolume -ErrorAction Stop
    if ($sysVol -and $defVol -and $defVol.Name -ne $sysVol.Name) {
        Set-AppxDefaultVolume -Volume $sysVol -ErrorAction Stop
        Ok "Neue Store-Apps werden jetzt auf $($sysVol.PackageStorePath) installiert."
    } else {
        Ok 'Neue Store-Apps werden auf C: installiert.'
    }
} catch {
    Warnung "Speicherort fuer neue Apps nicht geprueft: $($_.Exception.Message)"
}

# ---------------------------------------------------------------- 4. Neu installieren
Schritt '4. Claude neu installieren'
$setup = Join-Path $NutzerProfil 'Downloads\Claude Setup.exe'
if (Test-Path -LiteralPath $setup) {
    Info "Starte das Claude-Setup ($setup)."
    Info 'Fragt Windows nach Adminrechten, mit Ja bestaetigen. Anmelden musst du dich noch nicht.'
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $setup + '"')
} else {
    Info 'Im Browser oeffnet sich claude.ai/download. Lade dort Claude fuer Windows herunter und starte das Setup.'
    Info 'Fragt Windows nach Adminrechten, mit Ja bestaetigen. Anmelden musst du dich noch nicht.'
    Start-Process 'https://claude.ai/download'
}
while (-not $Art) {
    $a = Read-Host '       Wenn die Installation fertig ist: Enter druecken (A = Abbruch)'
    if ($a -match '^\s*[Aa]') { Abbruch "Abgebrochen. Deine Daten liegen in $WiederAus. Skript spaeter einfach noch mal starten." }
    $pk = ClaudePaket
    if (DateienDa $pk) { $Art = 'msix'; Ok "Claude $($pk.Version) ist installiert ($($pk.InstallLocation))."; break }
    if (-not $SquirrelVorher -and (Test-Path -LiteralPath (Join-Path $SquirrelOrdner 'claude.exe'))) { $Art = 'exe'; Ok "Claude ist installiert ($SquirrelOrdner)."; break }
    Write-Host '       Claude ist noch nicht (fertig) installiert. Kam beim Setup ein Fehler? Dann schick Claude ein Bild davon.' -ForegroundColor Yellow
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
        $rc = Robo $v (Join-Path $NutzerRoaming 'Claude')
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
$kaputt = @(Get-AppxPackage -User $NutzerSid -PackageTypeFilter Main, Framework -ErrorAction SilentlyContinue | Where-Object { -not (DateienDa $_) })
if (-not $kaputt.Count) {
    Ok 'Keine weiteren Store-Apps mit fehlenden Dateien.'
} else {
    foreach ($k in $kaputt) { Warnung "Store-App '$($k.Name)' hat keine Programmdateien mehr ($($k.InstallLocation))." }
    Info 'Diese Apps bitte nicht einfach deinstallieren, sondern die Liste an Claude schicken.'
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
