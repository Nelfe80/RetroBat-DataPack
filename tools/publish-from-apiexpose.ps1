# publish-from-apiexpose.ps1 - Publie le Data Pack depuis le dossier resources d'APIExpose.
#
# Le depot est un MIROIR de trois parties de plugins\APIExpose\resources :
#   ram/         les definitions .MEM officielles (sans .user, sans l'etat de synchro)
#   dynpanels/   les panneaux dynamiques
#   gamelist/    les gamelists localisees et la table des familles (PAS systems/ : ces
#                fichiers font jusqu'a 161 Mo, GitHub refuse au-dela de 100 Mo et chaque
#                regeneration gonflerait l'historique ; ils partent en release, un actif
#                par systeme, voir publish-gamelist-systems.ps1)
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
    @{ Source = 'ram';       Cible = 'ram';       ExclureDossiers = @('.user');   ExclureFichiers = @('.community-sync.json', '*.bak', '*.tmp') },
    @{ Source = 'dynpanels'; Cible = 'dynpanels'; ExclureDossiers = @();          ExclureFichiers = @('*.bak', '*.tmp') },
    @{ Source = 'gamelist';  Cible = 'gamelist';  ExclureDossiers = @('systems'); ExclureFichiers = @('*.bak', '*.tmp') }
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
    & git add -A
    $etat = & git status --porcelain
    if (-not $etat) { Write-Host 'Rien a publier : le depot est deja le miroir de resources.'; exit 0 }
    $n = ($etat | Measure-Object).Count
    Write-Host "$n fichier(s) a publier :"
    $etat | Select-Object -First 20 | ForEach-Object { "  $_" }
    if ($n -gt 20) { "  ... et $($n - 20) autres" }
    if ($WhatIf) { & git reset -q; Write-Host 'WhatIf : rien de commite.'; exit 0 }
    & git commit -q -m "Data Pack : $n fichier(s) depuis APIExpose ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
    & git push -q origin HEAD
    if ($LASTEXITCODE -ne 0) { throw 'git push a echoue' }
    Write-Host "Publie : $(& git rev-parse --short HEAD)"
} finally {
    Pop-Location
}
