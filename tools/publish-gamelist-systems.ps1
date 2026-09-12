# publish-gamelist-systems.ps1 - Publie les bases par systeme (gamelist\systems\*_lt.json)
# en actifs de la release « gamelist » de ce depot, UN actif par systeme.
#
# Pourquoi pas dans l'historique git : ces fichiers font jusqu'a 161 Mo (GitHub refuse
# au-dela de 100 Mo) et se regenerent en bloc. Pourquoi un actif par systeme : une borne
# ne reprend que les systemes dont le contenu a change, pas 600 Mo pour un.
#
# Le manifeste `gamelist-manifest.json` porte, par fichier, l'empreinte SHA-256 du JSON
# brut (celle que la borne compare a son fichier local) et celle de l'actif (celle qui
# verifie le telechargement). Seuls les systemes dont le JSON a change sont recompresses
# et renvoyes ; les autres gardent leur actif tel quel.
#
# Gzip, pas 7z : .NET le decompresse nativement, la borne n'a ni 7-Zip ni bibliotheque a
# embarquer pour ca. Un peu moins compact (j2me : 25 Mo au lieu de 15), sans dependance.
#
#   .\tools\publish-gamelist-systems.ps1            # publie ce qui a change
#   .\tools\publish-gamelist-systems.ps1 -WhatIf   # montre seulement
param(
    [string]$ApiExposeRoot = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'APIExpose'),
    [string]$Repo = 'Nelfe80/RetroBat-DataPack',
    [string]$Tag = 'gamelist',
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
function Compress-Gzip([string]$source, [string]$cible) {
    $entree = [IO.File]::OpenRead($source)
    try {
        $sortie = [IO.File]::Create($cible)
        try {
            $gz = New-Object IO.Compression.GZipStream($sortie, [IO.Compression.CompressionLevel]::Optimal)
            try { $entree.CopyTo($gz) } finally { $gz.Dispose() }
        } finally { $sortie.Dispose() }
    } finally { $entree.Dispose() }
}
$source = Join-Path $ApiExposeRoot 'resources\gamelist\systems'
if (-not (Test-Path $source)) { throw "introuvable : $source" }
$work = Join-Path (Split-Path $PSScriptRoot -Parent) '.temp\gamelist-release'
New-Item -ItemType Directory -Force $work | Out-Null

# Le manifeste publie, s'il existe : c'est lui qui dit ce qui est deja en ligne.
$manifestePath = Join-Path $work 'gamelist-manifest.json'
$enLigne = @{}
$existe = (cmd /c "gh release view $Tag --repo $Repo --json tagName 2>&1") -match '"tagName"'
if ($existe) {
    cmd /c "gh release download $Tag --repo $Repo --pattern gamelist-manifest.json --dir `"$work`" --clobber 2>&1" | Out-Null
    if (Test-Path $manifestePath) {
        $lu = Get-Content $manifestePath -Raw | ConvertFrom-Json
        foreach ($prop in $lu.files.PSObject.Properties) { $enLigne[$prop.Name] = $prop.Value }
    }
} elseif (-not $WhatIf) {
    cmd /c "gh release create $Tag --repo $Repo --title `"Gamelist databases`" --notes `"Per-system ROM databases (gamelist/systems/*_lt.json), one archive each. Read gamelist-manifest.json for content hashes. Updated in place: this release moves, its tag does not mark a version.`" 2>&1" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'gh release create a echoue' }
}

$fichiers = Get-ChildItem $source -File -Filter '*.json' | Sort-Object Name
$aEnvoyer = @()
$manifeste = [ordered]@{ schema = 'apiexpose-gamelist-systems/1'; generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); files = [ordered]@{} }
foreach ($f in $fichiers) {
    $cle = 'systems/' + $f.Name
    $sha = (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower()
    $actif = 'gamelist-' + [IO.Path]::GetFileNameWithoutExtension($f.Name) + '.json.gz'
    $deja = $enLigne[$cle]
    if ($deja -and $deja.sha256 -eq $sha -and $deja.asset -eq $actif) {
        # Inchange : on garde l'actif en ligne et son empreinte.
        $manifeste.files[$cle] = [ordered]@{ sha256 = $sha; size = $f.Length; asset = $actif; asset_sha256 = $deja.asset_sha256 }
        continue
    }
    $archive = Join-Path $work $actif
    if (Test-Path $archive) { Remove-Item $archive -Force }
    if (-not $WhatIf) {
        Compress-Gzip $f.FullName $archive
        $ashaVal = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower()
    } else { $ashaVal = '(whatif)' }
    $manifeste.files[$cle] = [ordered]@{ sha256 = $sha; size = $f.Length; asset = $actif; asset_sha256 = $ashaVal }
    $aEnvoyer += $archive
    Write-Host ("  {0,-28} {1,7:N1} Mo  a publier" -f $f.Name, ($f.Length / 1MB))
}
Write-Host "$($aEnvoyer.Count) systeme(s) a publier sur $($fichiers.Count)."
if ($WhatIf) { exit 0 }
if ($aEnvoyer.Count -eq 0 -and $enLigne.Count -eq $fichiers.Count) { Write-Host 'Rien a publier.'; exit 0 }

($manifeste | ConvertTo-Json -Depth 4) | Set-Content $manifestePath -Encoding ascii
foreach ($archive in $aEnvoyer) {
    cmd /c "gh release upload $Tag `"$archive`" --repo $Repo --clobber 2>&1" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "envoi de $(Split-Path $archive -Leaf) echoue" }
    Write-Host "  envoye $(Split-Path $archive -Leaf)"
    Remove-Item $archive -Force
}
# Le manifeste en DERNIER : une borne qui le lit ne trouve que des actifs deja en place.
cmd /c "gh release upload $Tag `"$manifestePath`" --repo $Repo --clobber 2>&1" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'envoi du manifeste echoue' }
Write-Host 'Manifeste publie.'
