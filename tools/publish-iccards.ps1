# publish-iccards.ps1 - Publie le pack de cartes d'instructions (resources\iccards) en actif
# de la release « iccards » de ce depot.
#
# Le pack est un zip de 113 Mo (887 cartes et leurs compagnons de placement) : trop gros pour
# l'historique git, et c'est une unite : on le prend entier ou pas. Le manifeste
# `iccards-manifest.json` porte la version du pack (celle de resources\iccards\manifest.json)
# et l'empreinte SHA-256 du zip : la borne ne le reprend que si l'empreinte a change.
#
#   .\tools\publish-iccards.ps1            # publie si le zip a change
#   .\tools\publish-iccards.ps1 -WhatIf   # montre seulement
param(
    [string]$ApiExposeRoot = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'APIExpose'),
    [string]$Repo = 'Nelfe80/RetroBat-DataPack',
    [string]$Tag = 'iccards',
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $ApiExposeRoot 'resources\iccards'
$zip = Join-Path $source 'iccards-arcade.zip'
$manifesteLocal = Join-Path $source 'manifest.json'
if (-not (Test-Path $zip)) { throw "introuvable : $zip" }
if (-not (Test-Path $manifesteLocal)) { throw "introuvable : $manifesteLocal" }
$work = Join-Path (Split-Path $PSScriptRoot -Parent) '.temp\iccards-release'
New-Item -ItemType Directory -Force $work | Out-Null

$local = Get-Content $manifesteLocal -Raw | ConvertFrom-Json
$sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
$taille = (Get-Item $zip).Length
Write-Host ("pack {0} : {1:N1} Mo, sha {2}..." -f $local.version, ($taille / 1MB), $sha.Substring(0, 12))

$manifestePath = Join-Path $work 'iccards-manifest.json'
$existe = (cmd /c "gh release view $Tag --repo $Repo --json tagName 2>&1") -match '"tagName"'
if ($existe) {
    cmd /c "gh release download $Tag --repo $Repo --pattern iccards-manifest.json --dir `"$work`" --clobber 2>&1" | Out-Null
    if (Test-Path $manifestePath) {
        $enLigne = Get-Content $manifestePath -Raw | ConvertFrom-Json
        if ($enLigne.sha256 -eq $sha) { Write-Host "Deja en ligne (version $($enLigne.version)). Rien a publier."; exit 0 }
        Write-Host "En ligne : version $($enLigne.version), sha $($enLigne.sha256.Substring(0,12))... -> a remplacer."
    }
} elseif (-not $WhatIf) {
    cmd /c "gh release create $Tag --repo $Repo --title `"Instruction cards`" --notes `"The arcade instruction cards pack (iccards-arcade.zip) and its manifest. Updated in place: this release moves, its tag does not mark a version. APIExpose installs it into media/systems/arcade/games/<rom>/artwork/ic/.`" 2>&1" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'gh release create a echoue' }
}
if ($WhatIf) { Write-Host 'WhatIf : rien de publie.'; exit 0 }

$manifeste = [ordered]@{
    schema = 'apiexpose-iccards/1'
    version = [string]$local.version
    source = [string]$local.source
    asset = 'iccards-arcade.zip'
    sha256 = $sha
    size = $taille
    jeux = $local.jeux
    cartes = $local.cartes
    generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
($manifeste | ConvertTo-Json -Depth 3) | Set-Content $manifestePath -Encoding ascii
cmd /c "gh release upload $Tag `"$zip`" --repo $Repo --clobber 2>&1" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'envoi du zip echoue' }
Write-Host '  zip envoye'
# Le manifeste en DERNIER : une borne qui le lit trouve le zip deja en place.
cmd /c "gh release upload $Tag `"$manifestePath`" --repo $Repo --clobber 2>&1" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'envoi du manifeste echoue' }
Write-Host 'Manifeste publie.'
