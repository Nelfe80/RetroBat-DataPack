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

This channel **overwrites**: it is the official one. Pushing a file here sends it to every cabinet on its own, within a day.

## Editing a `.MEM` of a game that is open to scoring

A game open to World Scoring pins the SHA-256 of its official definition inside its scoring profile. That hash is what *defines* the measurement, so records set before and after a change would not be comparable, and the platform never silently replaces it. It publishes the pinned value in its public index, `https://nelfeplay.com/api/v1/scores/open-games`, as `mem_sha256` next to each open game.

A cabinet compares the hash of its local file with that value. When the two differ it takes the game **out of the World Scoring collection**, with the reason shown on screen, rather than letting a player set a score the platform would refuse. The game comes back as soon as they agree again.

Correcting such a definition is therefore **two publications that belong together**: a new profile version carrying the new hash, and the file here. Publishing only the file takes the game out of the collection until the profile follows; publishing only the profile does the same until cabinets have synchronised. Either way the gap can last up to a day, which is the sync period.

Before pushing a `.MEM`, check whether its game is open, and compare:

```sh
sha256sum ram/arcade/altered-beast.MEM
curl -s https://nelfeplay.com/api/v1/scores/open-games
```

If the game appears in that index and its `mem_sha256` is not what `sha256sum` printed, the two publications are out of step: line them up before pushing.

`.MEM` files of games that are **not** in that index carry no such constraint. Correct and push them freely; cabinets pick them up on their next sync.

`ram/` mirrors `plugins\APIExpose\resources\ram\`, and the mirror is refreshed from it. A correction made only here is overwritten the next time the mirror is refreshed, so apply it to both.

## License

See [DATA-LICENSE.md](DATA-LICENSE.md). Personal, non-commercial use is free; any commercial use requires a written license.
