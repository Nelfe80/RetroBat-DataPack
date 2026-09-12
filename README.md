# RetroBat APIExpose Data Pack

The data files of [APIExpose](https://github.com/Nelfe80/RetroBat-APIExpose), published file by file so that a cabinet only downloads what changed.

| Folder | Content | Installed into |
|---|---|---|
| `ram/` | Official `.MEM` memory definitions (scores, lives, in-game events) | `plugins\APIExpose\resources\ram\` |
| `dynpanels/` | Dynamic control panels (systems, cores, games) | `plugins\APIExpose\resources\dynpanels\` |
| `gamelist/` | Localized gamelists and the game family table | `plugins\APIExpose\resources\gamelist\` |

The per-system ROM databases (`gamelist/systems/*_lt.json`, up to 161 MB each) are published as assets of the [`gamelist` release](../../releases/tag/gamelist), one archive per system, with a manifest of content hashes.

## How cabinets use it

APIExpose pulls this repository in the background (once a day, and on demand from `RetroBat.Api.Update.exe`): it compares the commit HEAD with the last one applied, then the blob hash of every file with its local copy, and downloads only the files that differ, over HTTPS from GitHub's raw content CDN. Nothing is pushed from a cabinet. Files present locally but absent here (personal `.MEM` under `ram\.user\`, community additions) are never touched.

## License

See [DATA-LICENSE.md](DATA-LICENSE.md). Personal, non-commercial use is free; any commercial use requires a written license.
