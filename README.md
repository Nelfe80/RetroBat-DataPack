# RetroBat APIExpose Data Pack

The data files of [APIExpose](https://github.com/Nelfe80/RetroBat-APIExpose), published file by file so that a cabinet only downloads what changed.

| Folder | Content | Installed into |
|---|---|---|
| `ram/` | Official `.MEM` memory definitions (scores, lives, in-game events) | `plugins\APIExpose\resources\ram\` |
| `dynpanels/` | Dynamic control panels (systems, cores, games) | `plugins\APIExpose\resources\dynpanels\` |
| `gamelist/` | The game family table and notes (the localized gamelists are a per-cabinet cache, generated locally) | `plugins\APIExpose\resources\gamelist\` |
| `controls/` | MAME `cfg` and FBNeo `rmp` packs | `plugins\APIExpose\resources\controls\` |
| `config-ESmenus/`, `locales/`, `scraping/`, `startup-overlay/`, `theme/hiscore/`, `theme/images/` | Menu fragments and their locales, interface texts, scraping references, startup overlay, hi2txt descriptors, panel artwork | same folders under `resources\` |

The per-system ROM databases (`gamelist/systems/*_lt.json`, up to 161 MB each) are published as assets of the [`gamelist` release](../../releases/tag/gamelist), one archive per system, with a manifest of content hashes.

The arcade instruction cards pack (`iccards-arcade.zip`, 887 cards) is published as the [`iccards` release](../../releases/tag/iccards) with a manifest; APIExpose installs it into `media\systems\arcade\games\<rom>\artwork\ic\`, never overwriting a card you made or modified yourself.

## How cabinets use it

APIExpose pulls this repository in the background (once a day, and on demand from `RetroBat.Api.Update.exe`): it compares the commit HEAD with the last one applied, then the blob hash of every file with its local copy, and downloads only the files that differ, over HTTPS from GitHub's raw content CDN. Nothing is pushed from a cabinet. Files present locally but absent here (personal `.MEM` under `ram\.user\`, community additions, everything APIExpose generates itself: `theme\panels`, `theme\gameinfos`, `gamelist\localized`, `ra`) are never touched.

## License

See [DATA-LICENSE.md](DATA-LICENSE.md). Personal, non-commercial use is free; any commercial use requires a written license.
