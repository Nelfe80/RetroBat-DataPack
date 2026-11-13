# Règlements des challenges

Sources des règlements au format `nelfe.challenge.v2`, un fichier par challenge, nommé `<jeu>.<challenge>.json` (le `challenge_id` du règlement).

## Format

Chaque fichier porte `schema`, `challenge_id`, `version`, `ruleset`, `game`, `mem_sha256` (le .MEM de `ram/.defis/`), la politique de départ (`start_policy`, et l'état de `../states/<système>/<jeu>/` quand le départ se fait sur un état), le chronométrage et les règles d'arrivée.

## Immuabilité

La version qui fait foi est celle déposée au site (table `challenge_rulesets`, immuable) : les bornes la reçoivent par `/api/v1/challenges/open`. Ce dossier en est la source.

- Un fichier déjà déposé ne se modifie jamais.
- Toute modification crée une nouvelle version : `version` et `ruleset` changent (`...-v2`, `...-v3`), puis un nouveau dépôt au site.
- Les dépôts comparent des empreintes : les fichiers sont conservés à l'octet près (`.gitattributes` : aucune conversion de fin de ligne).

## Lien avec `states/`

Un règlement qui part d'un état cite les points de départ rangés dans `../states/<système>/<jeu>/` (états et images). Ajouter un challenge se fait donc entièrement dans le Data Pack : état, .MEM de `ram/.defis/`, règlement ici, puis dépôt au site. L'API n'est pas concernée.
