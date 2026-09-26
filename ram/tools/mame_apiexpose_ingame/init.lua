local exports = {
    name = "apiexpose_ingame",
    version = "0.3.2",
    description = "APIExpose MAME ingame RAM bridge",
    license = "",
    author = { name = "APIExpose" }
}

local bridge = exports
local plugindir = "apiexpose_ingame"
local socket = nil
local connected = false
local announced = false
local buffer = ""
local frame = 0
local last_connect_frame = -999999
local watches = {}
local watch_order = {}
local last_values = {}
local maincpu = nil
local memspace = nil
local reset_subscription = nil
local stop_subscription = nil
local frame_subscription = nil
local hello_logged = false
local memory_logged = false
local read_fail_logged = {}
local read_fallback_logged = {}

-- Anti-triche (parite avec le wrapper RetroArch) : l'AVANCE RAPIDE. Compteur emis au stop
-- (SENSITIVE|fast_forward=N), avec un seuil anti faux-positif.
--
-- On compare le TEMPS EMULE au TEMPS REEL : une avance rapide fait defiler plus de secondes de
-- jeu que de secondes d'horloge. La version 0.3.0 lisait l'etat de limitation de vitesse de
-- MAME (manager.machine.video.throttled). Juste sous MAME autonome, faux sous le coeur libretro :
-- la c'est RetroArch qui cadence les images, la limitation de MAME est TOUJOURS coupee, et la
-- partie entiere comptait comme avance rapide (3605 images pour une minute de Metal Slug 3,
-- 2026-09-25) : chaque score y aurait ete refuse. Le rapport temps emule / temps reel, lui,
-- vaut sous les deux hotes, et la touche d'avance rapide de MAME autonome reste detectee.
local ac_fast_forward_frames = 0
local AC_FF_THRESHOLD = 30   -- ~0.5 s d'avance rapide avant de compter
local AC_FF_WINDOW = 2.0     -- fenetre de mesure, en secondes REELLES
local AC_FF_RATIO = 1.5      -- au-dela de 1,5 s de jeu par seconde d'horloge : avance rapide
local ac_ff_emu0, ac_ff_real0, ac_ff_count = nil, nil, 0

-- Horloge reelle haute resolution de MAME. nil si l'hote ne la fournit pas : on ne mesure
-- alors rien plutot que de mesurer faux.
local function ac_real_seconds()
    local ok, s = pcall(function() return emu.osd_ticks() / emu.osd_ticks_per_second() end)
    if ok and type(s) == "number" then return s end
    return nil
end

local function ac_emu_seconds()
    local ok, s = pcall(function() return manager.machine.time:as_double() end)
    if ok and type(s) == "number" then return s end
    return nil
end

-- Une image de plus : on cumule, et a chaque fenetre on juge si le jeu a couru plus vite que
-- l'horloge. Une pause arrete le temps emule : jamais comptee.
local function ac_measure_fast_forward()
    local real = ac_real_seconds()
    local emu_t = ac_emu_seconds()
    if not real or not emu_t then return end
    if not ac_ff_real0 then
        ac_ff_emu0, ac_ff_real0, ac_ff_count = emu_t, real, 0
        return
    end
    ac_ff_count = ac_ff_count + 1
    local dr = real - ac_ff_real0
    if dr >= AC_FF_WINDOW then
        local de = emu_t - ac_ff_emu0
        if de > dr * AC_FF_RATIO then
            ac_fast_forward_frames = ac_fast_forward_frames + ac_ff_count
        end
        ac_ff_emu0, ac_ff_real0, ac_ff_count = emu_t, real, 0
    end
end

-- Phase E (epinglage des reglages) : on lit une fois les DIP switches et on les envoie
-- (SETTINGS|name=value;...). On garde les reglages qui affectent le jeu (difficulte,
-- vies, bonus...) et on ecarte ceux qui ne changent pas l'equite d'un score (monnayage,
-- service, test, flip, cabinet, demo sounds) : ainsi une borne en free play n'est PAS
-- recalee sur le monnayage. Digest cote APIExpose ; le verifieur ne controle QUE si le
-- profil epingle allowed_core_options_digest.
local core_options_sent = false
local SETTINGS_DENY = {
    "coin", "coinage", "free play", "service", "test mode",
    "flip screen", "cabinet", "demo sound", "unused",
}

-- Decouverte (MEM Explorer) : quand APIExpose repond DISCOVER|host|port|hz, on ouvre un
-- 2e socket vers le listener TCP de l'Explorer et on streame la RAM principale (SNAP/DELTA,
-- offset-based comme le wrapper). Anti-fuite : si l'Explorer n'ecoute pas, la connexion
-- echoue et on reste en comportement normal.
local disco_socket = nil
local disco_active = false
local disco_hz = 8
local disco_abs = 0      -- adresse ABSOLUE de depart de la RAM principale
local disco_size = 0     -- taille streamee (offsets 0..size-1)
local disco_seq = 0
local disco_prev = nil
local disco_last_frame = -999999
local DISCO_MAX = 0x10000  -- cap de securite (perf Lua) : 64 Ko streames au plus

local config = {
    host = "127.0.0.1",
    port = 12347,
    poll_frames = 1,
    reconnect_frames = 60,
}

local function log(msg)
    print("[APIExpose Ingame] " .. tostring(msg))
end

function bridge.set_folder(path)
    plugindir = path or plugindir
end

local function try_load_config()
    local ok, cfg = pcall(function()
        package.path = plugindir .. "/?.lua;" .. package.path
        return require("config")
    end)
    if ok and type(cfg) == "table" then
        for k, v in pairs(cfg) do
            config[k] = v
        end
    end
end

local function get_rom_name()
    local ok, v
    ok, v = pcall(function() return emu.romname() end)
    if ok and v and v ~= "" then return v end
    ok, v = pcall(function() return manager.machine.system.name end)
    if ok and v and v ~= "" then return v end
    return "unknown"
end

local function get_game_name()
    local ok, v = pcall(function() return emu.gamename() end)
    if ok and v and v ~= "" then return v end
    return get_rom_name()
end

local function current_machine()
    if manager and manager.machine then
        return manager.machine
    end
    return nil
end

local function resolve_memory()
    local machine = current_machine()
    if not machine or not machine.devices then
        maincpu = nil
        memspace = nil
        return false
    end

    maincpu = machine.devices[":maincpu"]
    if not maincpu then
        for _, device in pairs(machine.devices) do
            if device.spaces and device.spaces["program"] then
                maincpu = device
                break
            end
        end
    end

    if maincpu and maincpu.spaces then
        memspace = maincpu.spaces["program"]
    end

    if memspace and not memory_logged then
        local tag = "unknown"
        pcall(function()
            if maincpu and maincpu.tag then
                tag = maincpu.tag
            end
        end)
        log("memory resolved: device=" .. tostring(tag) .. " space=program")
        memory_logged = true
    end

    return memspace ~= nil
end

local function disconnect()
    if socket then
        pcall(function() socket:close() end)
    end
    ram_regions = nil
    rebase_logged = {}
    socket = nil
    connected = false
    announced = false
    core_options_sent = false
    hello_logged = false
    buffer = ""
    watches = {}
    watch_order = {}
    last_values = {}
end

local function write_line(line)
    if not socket then return false end
    local ok, result = pcall(function()
        return socket:write(line .. "\n")
    end)
    if not ok then
        log("write failed: " .. tostring(result))
        disconnect()
        return false
    end

    pcall(function()
        socket:flush()
    end)
    return true
end

local function connect_if_needed()
    if connected then return end
    if frame - last_connect_frame < (tonumber(config.reconnect_frames) or 60) then return end
    last_connect_frame = frame

    local ok, s, err = pcall(function()
        -- flags READ|WRITE sans CREATE : pour un socket MAME, CREATE
        -- voudrait dire LISTEN (serveur) ; ici on se connecte a APIExpose
        local f = emu.file("", 3)
        local e = f:open("socket." .. tostring(config.host) .. ":" .. tostring(config.port))
        return f, e
    end)

    if not ok or not s or (err ~= nil and err ~= 0) then
        return
    end

    socket = s
    connected = true
    announced = false
    log("connected to " .. tostring(config.host) .. ":" .. tostring(config.port))
end

local ram_regions = nil
local rebase_logged = {}
local main_ram_base = nil

local function scan_ram_regions()
    ram_regions = {}
    main_ram_base = nil
    if not memspace then return end
    pcall(function()
        for _, entry in pairs(memspace.map.entries) do
            local a0 = entry.address_start or entry.addrstart
            local a1 = entry.address_end or entry.addrend
            local kind = nil
            pcall(function() kind = entry.read.handlertype end)
            if kind == "ram" and a0 and a1 then
                table.insert(ram_regions, { first = a0, last = a1 })
            end
        end
    end)
    -- region principale = la plus grande, a defaut la plus basse
    table.sort(ram_regions, function(a, b)
        local sa, sb = a.last - a.first, b.last - b.first
        if sa ~= sb then return sa > sb end
        return a.first < b.first
    end)
    -- chaque zone dans le journal : quand une adresse ne repond pas, c'est la
    -- premiere chose a regarder
    for _, r in ipairs(ram_regions) do
        log(string.format("  ram region 0x%X-0x%X (%d bytes)", r.first, r.last, r.last - r.first + 1))
    end
    log("ram regions: " .. tostring(#ram_regions))
end

-- La work RAM n'est PAS la plus grande zone RAM de la machine. Sur CPS-1 la
-- memoire video fait 192 Ko et la work RAM 64 Ko : prendre la plus grande faisait
-- lire les tuiles de l'ecran a la place du jeu, et une adresse de personnage y
-- rendait un code de caractere fige (0x20 = espace) qui ne bougeait jamais.
--
-- Le pilote, lui, sait laquelle c'est : il la nomme "mainram". Sa taille suffit a
-- la retrouver dans la carte memoire, et c'est aussi l'espace dans lequel les
-- offsets des .MEM sont exprimes (celui que libretro expose comme system RAM).
local function resolve_main_ram_base()
    if main_ram_base ~= nil then return main_ram_base end
    main_ram_base = false

    local size = nil
    pcall(function()
        local shares = manager.machine.memory.shares
        if not shares then return end
        local share = shares[":mainram"] or shares["mainram"]
        if share then size = share.size end
    end)

    if size then
        -- la plus haute des zones RAM de cette taille : sur 68000 la work RAM est
        -- en haut de la carte, et une egalite de taille se departage ainsi
        local best = nil
        for _, r in ipairs(ram_regions) do
            if (r.last - r.first + 1) == size and (best == nil or r.first > best) then
                best = r.first
            end
        end
        if best then
            main_ram_base = best
            log(string.format("main ram base 0x%X (share \"mainram\", %d bytes)", best, size))
            return main_ram_base
        end
    end

    local main = ram_regions[1]
    if main then
        main_ram_base = main.first
        log(string.format("main ram base 0x%X (plus grande zone RAM, %d bytes)",
            main.first, main.last - main.first + 1))
    end
    return main_ram_base
end

-- Les .MEM arcade portent des OFFSETS de work RAM (releves via le wrapper
-- libretro) : on les rebase sur la carte memoire reelle de la machine
-- (Neo-Geo 0x100000, CPS/Megadrive 0xFF0000...). Une adresse deja situee
-- dans une region RAM est gardee telle quelle.
local function translate_address(addr)
    if ram_regions == nil then scan_ram_regions() end
    for _, r in ipairs(ram_regions) do
        if addr >= r.first and addr <= r.last then
            return addr
        end
    end
    local base = resolve_main_ram_base()
    local main = nil
    if base then
        for _, r in ipairs(ram_regions) do
            if r.first == base then main = r break end
        end
    end
    if main and addr <= (main.last - main.first) then
        local rebased = main.first + addr
        if not rebase_logged[addr] then
            log(string.format("rebase 0x%X -> 0x%X (main ram)", addr, rebased))
            rebase_logged[addr] = true
        end
        return rebased
    end
    return addr
end

local function parse_command(line)
    local parts = {}
    for part in string.gmatch(line, "([^|]+)") do
        table.insert(parts, part)
    end
    return parts
end

local function disconnect_discovery()
    if disco_socket then
        pcall(function() disco_socket:close() end)
    end
    disco_socket = nil
    disco_active = false
    disco_prev = nil
    disco_seq = 0
end

local function read_region_bytes()
    local bytes = {}
    for i = 0, disco_size - 1 do
        bytes[i + 1] = memspace:read_u8(disco_abs + i)
    end
    return bytes
end

-- Ouvre le canal de decouverte vers l'Explorer et annonce HELLO (base=0 offset-based).
local function start_discovery(host, port, hz)
    if disco_active then return end
    if not memspace and not resolve_memory() then return end
    if ram_regions == nil then scan_ram_regions() end
    local main = ram_regions and ram_regions[1]
    if not main then
        log("discovery: aucune region RAM trouvee")
        return
    end

    disco_abs = main.first
    disco_size = math.min(main.last - main.first + 1, DISCO_MAX)
    disco_hz = tonumber(hz) or 8
    if disco_hz < 1 then disco_hz = 1 end
    if disco_hz > 60 then disco_hz = 60 end

    local ok, f, e = pcall(function()
        local file = emu.file("", 3)   -- READ|WRITE, pas de CREATE (client sortant)
        local err = file:open("socket." .. tostring(host) .. ":" .. tostring(port))
        return file, err
    end)
    if not ok or not f or (e ~= nil and e ~= 0) then
        log("discovery: connexion " .. tostring(host) .. ":" .. tostring(port) .. " impossible (Explorer absent ?)")
        return
    end

    disco_socket = f
    disco_prev = nil
    disco_seq = 0
    disco_last_frame = -999999
    disco_active = true

    pcall(function()
        disco_socket:write("HELLO|" .. get_rom_name() .. "|0|" .. tostring(disco_size) .. "\n")
        disco_socket:flush()
    end)
    log(string.format("discovery: stream %d o depuis 0x%X -> %s:%s @ %dHz",
        disco_size, disco_abs, tostring(host), tostring(port), disco_hz))
end

-- Streame la RAM principale : 1er tick = SNAP complet, ensuite DELTA (octets changes).
local function poll_discovery()
    if not disco_active or not disco_socket then return end
    if not memspace then return end
    local interval = math.floor(60 / disco_hz)
    if interval < 1 then interval = 1 end
    if frame - disco_last_frame < interval then return end
    disco_last_frame = frame

    local ok, bytes = pcall(read_region_bytes)
    if not ok or not bytes then return end

    disco_seq = disco_seq + 1
    local line
    if disco_prev == nil then
        local parts = {}
        for i = 1, disco_size do parts[i] = string.format("%02X", bytes[i]) end
        line = "SNAP|" .. tostring(disco_seq) .. "|" .. table.concat(parts)
    else
        local changed = {}
        for i = 1, disco_size do
            if bytes[i] ~= disco_prev[i] then
                changed[#changed + 1] = string.format("%d:%02X", i - 1, bytes[i])
            end
        end
        line = "DELTA|" .. tostring(disco_seq) .. "|" .. table.concat(changed, ",")
    end
    disco_prev = bytes

    local wok = pcall(function()
        disco_socket:write(line .. "\n")
        disco_socket:flush()
    end)
    if not wok then
        log("discovery: write echoue, arret")
        disconnect_discovery()
    end
end

local function clear_watches()
    watches = {}
    watch_order = {}
    last_values = {}
end

-- ── Entrees injectees (le labo pilote MAME comme il pilote RetroArch) ──────────────────
--
-- RetroArch a une manette reseau ; MAME n'en a pas. Mais son API Lua sait forcer un champ
-- d'entree (ioport_field:set_value), et c'est plus sur qu'un clavier synthetique : pas de
-- fenetre a mettre au premier plan, pas de reglage de touches a connaitre. Le champ se
-- designe par son NOM MAME (« 1 Player Start », « Coin 1 », « P1 Up », « P1 Button 1 ») ;
-- INPUTS? liste ceux de la machine pour que l'appelant sache quoi demander.
--
-- Une valeur forcee tient jusqu'a INPUT|<nom>|0 ; on retire alors le forcage (clear_value)
-- pour rendre le champ au vrai joueur, et non set_value(0), qui le tiendrait relache.
local forced_fields = {}

local function find_field(name)
    local machine = current_machine()
    if not machine then return nil end
    local found = nil
    pcall(function()
        for _, port in pairs(machine.ioport.ports) do
            if port.fields then
                for fname, field in pairs(port.fields) do
                    if fname == name then found = field return end
                end
            end
        end
    end)
    return found
end

local function set_input(name, pressed)
    local field = find_field(name)
    if not field then
        write_line("INPUT|" .. name .. "|absent")
        return
    end
    local ok, err
    if pressed then
        ok, err = pcall(function() field:set_value(1) end)
        if ok then forced_fields[name] = field end
    else
        ok, err = pcall(function() field:clear_value() end)
        if not ok then ok, err = pcall(function() field:set_value(0) end) end
        forced_fields[name] = nil
    end
    write_line("INPUT|" .. name .. "|" .. (ok and (pressed and "1" or "0") or "err"))
    if not ok then log("input " .. name .. " failed: " .. tostring(err)) end
end

local function release_inputs()
    for name, field in pairs(forced_fields) do
        pcall(function() field:clear_value() end)
    end
    forced_fields = {}
end

local function list_inputs()
    local machine = current_machine()
    if not machine then
        write_line("INPUTS|")
        return
    end
    local names = {}
    pcall(function()
        for _, port in pairs(machine.ioport.ports) do
            if port.fields then
                for fname, field in pairs(port.fields) do
                    local cls = nil
                    pcall(function() cls = field.type_class end)
                    -- Les DIP et la configuration ne sont pas des entrees de jeu.
                    if cls ~= "dipswitch" and cls ~= "config" then
                        names[#names + 1] = fname
                    end
                end
            end
        end
    end)
    table.sort(names)
    write_line("INPUTS|" .. table.concat(names, ","))
end

local function handle_line(line)
    local parts = parse_command(line)
    local cmd = parts[1]

    if cmd == "CLEAR" then
        clear_watches()
    elseif cmd == "WATCH" then
        local id = parts[2]
        local addr = tonumber((parts[3] or ""):gsub("^0[xX]", ""), 16)
        local typ = parts[4] or "u8"
        if id and addr then
            watches[id] = { address = translate_address(addr), type = typ }
            table.insert(watch_order, id)
        end
    elseif cmd == "READY" then
        log("watchlist ready: " .. tostring(#watch_order) .. " addresses")
    elseif cmd == "DISCOVER" then
        -- APIExpose nous redirige vers le listener de decouverte de l'Explorer.
        local host = parts[2] or "127.0.0.1"
        local port = tonumber(parts[3]) or 12348
        local hz = tonumber(parts[4]) or 8
        start_discovery(host, port, hz)
    elseif cmd == "SNAPSHOT" then
        -- Capture d'ecran du RECORD (parite avec RetroArch).
        --
        -- On passe par MAME lui-meme plutot que par une capture de fenetre : son snapshot
        -- est pris dans le tampon du jeu, donc a la definition d'origine et deja oriente
        -- pour un jeu vertical. Une capture de fenetre rendrait ce que cet ecran-la
        -- affiche, mise a l'echelle et filtree.
        --
        -- MAME ecrit dans son snapshot_directory ; c'est APIExpose qui retrouve le
        -- fichier apparu, comme il le fait pour RetroArch.
        local ok, err = pcall(function() manager.machine.video:snapshot() end)
        write_line("SNAPSHOT|" .. (ok and "ok" or "err") .. "|" .. tostring(frame))
        if not ok then
            log("snapshot failed: " .. tostring(err))
        end
    elseif cmd == "INPUT" then
        local name = parts[2] or ""
        local pressed = (parts[3] or "0") == "1"
        if name ~= "" then set_input(name, pressed) end
    elseif cmd == "INPUTS?" then
        list_inputs()
    elseif cmd == "RELEASE" then
        release_inputs()
        write_line("INPUT|*|0")
    elseif cmd == "PING" then
        write_line("PONG|" .. tostring(frame))
    elseif cmd == "HELLO?" then
        local hello = "HELLO|" .. get_rom_name() .. "|" .. get_game_name()
        if not hello_logged then
            log("replying " .. hello)
            hello_logged = true
        end
        announced = write_line(hello)
    end
end

local function read_socket()
    if not socket then return end
    local ok, chunk = pcall(function()
        return socket:read(4096)
    end)
    if not ok then
        log("read failed: " .. tostring(chunk))
        disconnect()
        return
    end
    if not chunk or #chunk == 0 then return end

    buffer = buffer .. chunk
    while true do
        local pos = buffer:find("\n", 1, true)
        if not pos then break end
        local line = buffer:sub(1, pos - 1):gsub("\r", "")
        buffer = buffer:sub(pos + 1)
        if line ~= "" then
            handle_line(line)
        end
    end
end

local function candidate_addresses(addr)
    local candidates = { addr }

    -- Some MAME cheat/MEM sources expose CPS-style CPU addresses (0x92xxxx)
    -- while Lua program-space reads expect the RAM offset within that bank.
    if addr >= 0x920000 and addr <= 0x92FFFF then
        table.insert(candidates, addr - 0x920000)
    end

    if addr > 0xFFFF then
        local low = addr % 0x10000
        if low ~= addr and low ~= (addr - 0x920000) then
            table.insert(candidates, low)
        end
    end

    return candidates
end

local function read_be(addr, size)
    local value = 0
    for i = 0, size - 1 do
        value = value * 256 + memspace:read_u8(addr + i)
    end
    return value
end

local function read_le(addr, size)
    local value = 0
    local multiplier = 1
    for i = 0, size - 1 do
        value = value + memspace:read_u8(addr + i) * multiplier
        multiplier = multiplier * 256
    end
    return value
end

local function raw_read_mem(addr, typ)
    if not memspace then return nil end
    local ok, v
    if typ == "u8" then
        ok, v = pcall(function() return memspace:read_u8(addr) end)
    elseif typ == "u24be" then
        ok, v = pcall(function() return read_be(addr, 3) end)
    elseif typ == "u24le" then
        ok, v = pcall(function() return read_le(addr, 3) end)
    elseif typ == "u16be" then
        ok, v = pcall(function()
            return memspace:read_u8(addr) * 256 + memspace:read_u8(addr + 1)
        end)
    elseif typ == "u16le" then
        ok, v = pcall(function()
            return memspace:read_u8(addr) + memspace:read_u8(addr + 1) * 256
        end)
    elseif typ == "u32be" then
        ok, v = pcall(function()
            return memspace:read_u8(addr) * 16777216
                + memspace:read_u8(addr + 1) * 65536
                + memspace:read_u8(addr + 2) * 256
                + memspace:read_u8(addr + 3)
        end)
    elseif typ == "u32le" then
        ok, v = pcall(function()
            return memspace:read_u8(addr)
                + memspace:read_u8(addr + 1) * 256
                + memspace:read_u8(addr + 2) * 65536
                + memspace:read_u8(addr + 3) * 16777216
        end)
    elseif typ == "u40be" then
        ok, v = pcall(function() return read_be(addr, 5) end)
    elseif typ == "u40le" then
        ok, v = pcall(function() return read_le(addr, 5) end)
    elseif typ == "u48be" then
        ok, v = pcall(function() return read_be(addr, 6) end)
    elseif typ == "u48le" then
        ok, v = pcall(function() return read_le(addr, 6) end)
    elseif typ == "u64be" then
        ok, v = pcall(function()
            return memspace:read_u8(addr) * 72057594037927936
                + memspace:read_u8(addr + 1) * 281474976710656
                + memspace:read_u8(addr + 2) * 1099511627776
                + memspace:read_u8(addr + 3) * 4294967296
                + memspace:read_u8(addr + 4) * 16777216
                + memspace:read_u8(addr + 5) * 65536
                + memspace:read_u8(addr + 6) * 256
                + memspace:read_u8(addr + 7)
        end)
    elseif typ == "u64le" then
        ok, v = pcall(function()
            return memspace:read_u8(addr)
                + memspace:read_u8(addr + 1) * 256
                + memspace:read_u8(addr + 2) * 65536
                + memspace:read_u8(addr + 3) * 16777216
                + memspace:read_u8(addr + 4) * 4294967296
                + memspace:read_u8(addr + 5) * 1099511627776
                + memspace:read_u8(addr + 6) * 281474976710656
                + memspace:read_u8(addr + 7) * 72057594037927936
        end)
    else
        ok, v = pcall(function() return memspace:read_u8(addr) end)
    end
    if ok then return v end
    return nil
end

local function read_mem(addr, typ)
    local candidates = candidate_addresses(addr)
    for _, candidate in ipairs(candidates) do
        local value = raw_read_mem(candidate, typ)
        if value ~= nil then
            if candidate ~= addr then
                local key = string.format("%X>%X", addr, candidate)
                if not read_fallback_logged[key] then
                    log("read fallback: 0x" .. string.format("%X", addr) .. " -> 0x" .. string.format("%X", candidate))
                    read_fallback_logged[key] = true
                end
            end
            return value
        end
    end

    local fail_key = string.format("%X/%s", addr, tostring(typ))
    if not read_fail_logged[fail_key] then
        log("read failed: 0x" .. string.format("%X", addr) .. " type=" .. tostring(typ))
        read_fail_logged[fail_key] = true
    end

    return nil
end

local function format_mem_value(value)
    local ok, text = pcall(function()
        return string.format("%d", value)
    end)
    if ok then return text end
    ok, text = pcall(function()
        return string.format("%.0f", value)
    end)
    if ok then return text end
    return tostring(value)
end

local function poll_watches()
    if not connected then return end
    if not memspace and not resolve_memory() then return end
    local poll_frames = tonumber(config.poll_frames) or 1
    if poll_frames > 1 and frame % poll_frames ~= 0 then return end

    for _, id in ipairs(watch_order) do
        local watch = watches[id]
        if watch then
            local ok, value = pcall(function()
                return read_mem(watch.address, watch.type)
            end)
            if not ok then
                log("poll error: id=" .. tostring(id) .. " address=0x" .. string.format("%X", watch.address) .. " type=" .. tostring(watch.type) .. " error=" .. tostring(value))
                value = nil
            end
            if value ~= nil and last_values[id] ~= value then
                last_values[id] = value
                -- 0.3.2 : la trame emulee voyage avec la valeur (4e champ). Sans elle, APIExpose ne
                -- savait pas QUAND les vies remontaient au continue : la coupure 1CC n'agissait pas
                -- sous MAME, et un score avec continue passait entier. Les API d'avant la lisent
                -- sans la voir : elles ne prennent que les trois premiers champs.
                if not write_line("VALUE|" .. id .. "|" .. format_mem_value(value) .. "|" .. tostring(frame)) then
                    return
                end
            end
        end
    end
end

local function is_denied_setting(name)
    local low = string.lower(name or "")
    for _, token in ipairs(SETTINGS_DENY) do
        if string.find(low, token, 1, true) then return true end
    end
    return false
end

-- Lit les DIP switches de la machine et renvoie une chaine canonique triee
-- "name=value;name=value" (valeur = octet masque du champ). Vide si indisponible.
local function read_core_options()
    local machine = current_machine()
    if not machine then return "" end
    local entries = {}
    pcall(function()
        local ioport = machine.ioport
        if not ioport or not ioport.ports then return end
        for _, port in pairs(ioport.ports) do
            local value = nil
            pcall(function() value = port:read() end)
            if port.fields then
                for fname, field in pairs(port.fields) do
                    local cls = nil
                    pcall(function() cls = field.type_class end)
                    if cls == "dipswitch" and not is_denied_setting(fname) then
                        local masked = 0
                        if value ~= nil then
                            pcall(function() masked = value & field.mask end)
                        end
                        entries[#entries + 1] = string.format("%s=%d", fname, masked)
                    end
                end
            end
        end
    end)
    table.sort(entries)
    return table.concat(entries, ";")
end

-- Envoie les reglages une seule fois par session (des que le HELLO est acquitte et que
-- l'ioport repond). Retente chaque frame tant que la lecture est vide (machine pas prete).
local function maybe_send_settings()
    if core_options_sent or not announced then return end
    local opts = read_core_options()
    if opts ~= "" then
        core_options_sent = write_line("SETTINGS|" .. opts)
        if core_options_sent then
            log("core options: " .. opts)
        end
    end
end

function bridge.startplugin()
    try_load_config()

    reset_subscription = emu.add_machine_reset_notifier(function()
        release_inputs()
        disconnect_discovery()
        disconnect()
        resolve_memory()
    end)

    stop_subscription = emu.add_machine_stop_notifier(function()
        if disco_socket then
            pcall(function()
                disco_socket:write("BYE\n")
                disco_socket:flush()
            end)
        end
        disconnect_discovery()
        -- Anti-triche : bilan des vecteurs detectes cette session (seuil applique).
        local ff = (ac_fast_forward_frames > AC_FF_THRESHOLD) and ac_fast_forward_frames or 0
        write_line("SENSITIVE|fast_forward=" .. ff)
        write_line("BYE|" .. get_rom_name())
        disconnect()
    end)

    frame_subscription = emu.add_machine_frame_notifier(function()
        frame = frame + 1
        -- Anti-triche : l'avance rapide, par le rapport temps emule / temps reel.
        ac_measure_fast_forward()
        if not memspace then
            resolve_memory()
        end
        connect_if_needed()

        if connected then
            read_socket()
            maybe_send_settings()
            if disco_active then
                poll_discovery()
            else
                poll_watches()
            end
        end
    end)
end

return exports
