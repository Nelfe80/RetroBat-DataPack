# resources/ram

Definitions RAM/events ingame consommees par le runtime RetroBat.

## Contenu

- `<system>/<slug>.MEM` : definitions d'events memoire d'un jeu (table Lua,
  nomenclature V11). Generees par `tools/mem-curator/mem_curator_v5.py`.
- `<system>/alias.json` : correspondances nom de ROM / hash MD5 -> slug du
  fichier `.MEM` canonique (une entree par ligne, casse d'origine + minuscules).
- `tools/mame_apiexpose_ingame/` : source du plugin Lua MAME deploye au
  demarrage par APIExpose vers `bios/mame/plugins` et `emulators/mame/plugins`
  (copie git canonique : `tools/mem-curator/mame_apiexpose_ingame/`).

## Consommateurs

1. **Wrapper RetroArch** (`plugins/Wrapper/wrapper.cpp`) : chaque core de
   `emulators/retroarch/cores/` est un wrapper qui charge le vrai core depuis
   `cores_real/`, lit le `.MEM` du jeu et pousse les events via named pipe
   vers APIExpose (`/ws/ingame`).
2. **MAME standalone** : le plugin Lua `apiexpose_ingame` envoie les valeurs
   RAM par TCP a `MameLuaIngameProvider`, qui parse le meme `.MEM`.

Ce dossier n'est pas versionne (strategie Data Pack). Toujours faire un backup
avant regeneration massive ; l'outillage de validation et de diff est dans
`tools/mem-curator/`.
