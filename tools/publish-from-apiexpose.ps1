# publish-from-apiexpose.ps1 - Publie le Data Pack depuis le dossier resources d'APIExpose.
#
# Le depot est un MIROIR de ce qu'APIExpose LIT dans plugins\APIExpose\resources et
# n'ecrit jamais (inventaire du code, 2026-09-12) :
#   ram/            .MEM officiels (sans .user ni l'etat de synchro)          lu par le wrapper, MAME Lua
#   dynpanels/      panneaux dynamiques (generes HORS LIGNE par le curator)  lus par 5 services
#   gamelist/       la table des familles et les notices (PAS systems/ : jusqu'a 161 Mo, GitHub
#                   refuse au-dela de 100 Mo, ils partent en release, un actif par systeme, voir
#                   publish-gamelist-systems.ps1 ; PAS localized/ : un CACHE que chaque borne
#                   genere de ses propres gamelists, dans ses langues)
#   controls/       cfg MAME, rmp fbneo (sans retroarch/mame : doctrine cfg seulement)
#   config-ESmenus/ fragments de menu ES et leurs locales (sans les .bak)
#   locales/        interface-texts.json
#   scraping/       references (sans ScreenScraper.html)
#   startup-overlay/ images de l'overlay de demarrage
#   theme/hiscore/  descripteurs hi2txt (.parsingdb)  |  theme/images/  dessins des panneaux
#
# Ce qui N'Y EST PAS, et pourquoi :
#   theme/panels/, theme/gameinfos/, ra/, gamelist/localized/   GENERES par APIExpose sur la borne
#   outputs/, panels/                       sources du curator, jamais dans le pack public
#   iccards/                                un zip de 113 Mo (limite GitHub), a son propre depot
#   colors/, command/, history/             fichiers MAME externes, exclus de l'installeur
#
# Ce que ca fait : robocopy en miroir (les fichiers retires de resources sont retires du
# depot), puis un commit des differences et un push. Rien n'est pousse s'il n'y a rien.
#
#   .\tools\publish-from-apiexpose.ps1                # publie
#   .\tools\publish-from-apiexpose.ps1 -WhatIf       # montre ce qui changerait
param(
    [string]$ApiExposeRoot = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'APIExpose'),
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$resources = Join-Path $ApiExposeRoot 'resources'
if (-not (Test-Path (Join-Path $resources 'ram'))) { throw "resources\ram introuvable sous $ApiExposeRoot" }

# Les parties, et ce qui n'en fait pas partie. Les exclusions calquent release.ps1 : ce
# qui ne part pas dans full.7z ne part pas ici non plus.
$parties = @(
    @{ Source = 'ram';             Cible = 'ram';             ExclureDossiers = @('.user');          ExclureFichiers = @('.community-sync.json', '.datapack-sync.json', '*.bak', '*.tmp') },
    @{ Source = 'dynpanels';       Cible = 'dynpanels';       ExclureDossiers = @();                 ExclureFichiers = @('*.bak', '*.tmp') },
    @{ Source = 'gamelist';        Cible = 'gamelist';        ExclureDossiers = @('systems', 'localized'); ExclureFichiers = @('*.bak', '*.tmp') },
    @{ Source = 'controls';        Cible = 'controls';        ExclureDossiers = @('retroarch\mame'); ExclureFichiers = @('*.bak', '*.tmp') },
    @{ Source = 'config-ESmenus';  Cible = 'config-ESmenus';  ExclureDossiers = @();                 ExclureFichiers = @('*.bak', '*.tmp') },
    @{ Source = 'locales';         Cible = 'locales';         ExclureDossiers = @();                 ExclureFichiers = @('*.bak', '*.tmp') },
    @{ Source = 'scraping';        Cible = 'scraping';        ExclureDossiers = @();                 ExclureFichiers = @('ScreenScraper.html', '*.bak', '*.tmp') },
    @{ Source = 'startup-overlay'; Cible = 'startup-overlay'; ExclureDossiers = @();                 ExclureFichiers = @('*.bak', '*.tmp') },
    @{ Source = 'theme\hiscore';   Cible = 'theme\hiscore';   ExclureDossiers = @();                 ExclureFichiers = @('*.bak', '*.tmp') },
    @{ Source = 'theme\images';    Cible = 'theme\images';    ExclureDossiers = @();                 ExclureFichiers = @('*.bak', '*.tmp') }
)

foreach ($p in $parties) {
    $src = Join-Path $resources $p.Source
    $dst = Join-Path $repo $p.Cible
    $args = @($src, $dst, '/MIR', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NP', '/XJ')
    if ($p.ExclureDossiers.Count) { $args += '/XD'; $args += ($p.ExclureDossiers | ForEach-Object { Join-Path $src $_ }) }
    if ($p.ExclureFichiers.Count) { $args += '/XF'; $args += $p.ExclureFichiers }
    if ($WhatIf) { $args += '/L' }
    & robocopy @args | Out-Null
    # robocopy : 0-7 = succes (bits : 1 copie, 2 extra, 4 differences), 8+ = echec.
    if ($LASTEXITCODE -ge 8) { throw "robocopy a echoue sur $($p.Source) (code $LASTEXITCODE)" }
    Write-Host ("{0,-10} -> {1} (robocopy {2})" -f $p.Source, $p.Cible, $LASTEXITCODE)
}

Push-Location $repo
try {
    # git ecrit ses avertissements sur stderr, ce que PowerShell 5.1 transforme en erreur sous
    # 'Stop' : on passe par cmd pour les appels git et on lit le code de retour.
    cmd /c "git add -A 2>&1" | Out-Null
    $etat = @(cmd /c "git status --porcelain 2>&1")
    if ($etat.Count -eq 0) { Write-Host 'Rien a publier : le depot est deja le miroir de resources.'; exit 0 }
    $n = $etat.Count
    Write-Host "$n fichier(s) a publier :"
    $etat | Select-Object -First 20 | ForEach-Object { "  $_" }
    if ($n -gt 20) { "  ... et $($n - 20) autres" }
    if ($WhatIf) { cmd /c "git reset -q 2>&1" | Out-Null; Write-Host 'WhatIf : rien de commite.'; exit 0 }
    $message = "Data Pack : $n fichier(s) depuis APIExpose ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
    cmd /c "git commit -q -m `"$message`" 2>&1" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git commit a echoue' }
    cmd /c "git push -q origin HEAD 2>&1" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git push a echoue' }
    Write-Host "Publie : $(cmd /c 'git rev-parse --short HEAD 2>&1')"
} finally {
    Pop-Location
}
