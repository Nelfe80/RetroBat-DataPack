-- APIExpose : copie du tampon d'image de MAME, pour la decouverte silencieuse du scoring.
--
-- Plugin SEPARE de apiexpose_ingame, et il doit le rester : le SHA-256 de l'init.lua du pont
-- RAM est l'empreinte homologuee du listener, elle ne bouge pas parce qu'on ajoute une capture.
--
-- Ce que fait ce plugin, et rien d'autre :
--   1. il ouvre un socket de COMMANDE vers APIExpose et attend ;
--   2. quand APIExpose arme la capture (ARM|host|port|token|count), il copie screen:pixels()
--      et envoie les octets au VERIFICATEUR, directement, sur le socket indique ;
--   3. il se desarme des que le compte est atteint, que l'ecriture echoue ou qu'on lui dit.
--
-- Trois regles qui ne se negocient pas :
--   * hors armement, screen:pixels() n'est JAMAIS appele : aucune copie, aucun cout ;
--   * les pixels ne passent pas par APIExpose (contrat A1.3 : aucune image dans son espace
--     memoire) ; le socket de commande ne transporte que du texte ;
--   * on ne reessaie jamais : une ecriture qui echoue desarme. Une partie ne ralentit pas
--     parce qu'un verificateur est occupe.
--
-- L'image part telle que MAME la rend : non orientee, definition d'origine, sans bezel ni
-- filtre. Un jeu vertical sort couche ; c'est le verificateur qui applique la rotation, a
-- partir du referentiel arcade, pas ce plugin.

local exports = {
    name = "apiexpose_frames",
    version = "0.1.0",
    description = "APIExpose MAME frame buffer capture",
    license = "",
    author = { name = "APIExpose" }
}

local frames = exports
local plugindir = "apiexpose_frames"

-- Port DISTINCT de celui du pont RAM (12347) : deux plugins, deux sockets, aucun melange.
local config = { host = "127.0.0.1", port = 12348, debug = false }

local control = nil          -- socket de commande vers APIExpose (texte)
local connected = false
local announced = false
local inbox = ""
local frame = 0
local last_connect_frame = -999999
local CONNECT_RETRY_FRAMES = 300   -- ~5 s : on n'insiste pas si APIExpose n'ecoute pas

local sink = nil             -- socket vers le verificateur (binaire), ouvert le temps d'une rafale
local armed = false
local arm_token = ""
local arm_left = 0
local arm_seq = 0
local last_capture_frame = -999999
local min_interval_frames = 30     -- 500 ms a 60 Hz, aligne sur OCR_MIN_INTERVAL_MS
local minute_window_frame = 0
local minute_count = 0
local MAX_CAPTURES_PER_MINUTE = 60
local MAX_FRAMES_PER_ARM = 8

local screen_device = nil
local geometry_logged = false

-- Les abonnements se GARDENT. MAME lie la vie d'un notifier a l'objet rendu par
-- add_machine_*_notifier : jete, il est ramasse et le notifier cesse de tomber, sans une
-- ligne d'erreur. Mesure du 2026-09-12 : sans ces trois locales, le plugin envoyait son
-- HELLO puis devenait sourd au bout de quelques images.
local reset_subscription = nil
local stop_subscription = nil
local frame_subscription = nil

local function log(message)
    if config.debug then
        print("[apiexpose_frames] " .. tostring(message))
    end
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

local function rom_name()
    local ok, value = pcall(function() return emu.romname() end)
    if ok and value and value ~= "" then return value end
    ok, value = pcall(function() return manager.machine.system.name end)
    if ok and value and value ~= "" then return value end
    return "unknown"
end

-- Le premier ecran de la machine. MAME en expose plusieurs sur les bornes a deux moniteurs ;
-- le score vit sur le principal, et une capture de plus serait du cout pour rien.
local function resolve_screen()
    if screen_device then return true end
    local ok, found = pcall(function()
        for _, screen in pairs(manager.machine.screens) do
            return screen
        end
        return nil
    end)
    if ok and found then
        screen_device = found
        return true
    end
    return false
end

local function screen_size()
    if not resolve_screen() then return nil, nil end
    local ok, width, height = pcall(function()
        return screen_device.width, screen_device.height
    end)
    if ok and width and height then return width, height end
    return nil, nil
end

local function close_sink()
    if sink then
        pcall(function() sink:close() end)
    end
    sink = nil
end

local function disarm(reason)
    if armed or sink then
        log("desarme : " .. tostring(reason))
    end
    armed = false
    arm_token = ""
    arm_left = 0
    close_sink()
end

local function disconnect()
    disarm("socket de commande ferme")
    if control then
        pcall(function() control:close() end)
    end
    control = nil
    connected = false
    announced = false
    inbox = ""
end

-- Le flush a SON pcall, et son echec ne compte pas : sur MAME 0.286 il rend une erreur
-- alors que les octets sont deja partis. Mesure du 2026-09-12 : groupe avec le write, il
-- faisait fermer un socket parfaitement sain juste apres le HELLO, et le plugin devenait
-- sourd. Le pont RAM isole son flush pour la meme raison.
local function write_control(line)
    if not control then return false end
    local ok = pcall(function()
        control:write(line .. "\n")
    end)
    if not ok then
        disconnect()
        return false
    end
    pcall(function() control:flush() end)
    return true
end

local function connect_if_needed()
    if connected then return end
    if frame - last_connect_frame < CONNECT_RETRY_FRAMES then return end
    last_connect_frame = frame

    local ok, file, err = pcall(function()
        local f = emu.file("", 3)   -- READ|WRITE sans CREATE : client sortant
        local e = f:open("socket." .. tostring(config.host) .. ":" .. tostring(config.port))
        return f, e
    end)
    if not ok or not file or (err ~= nil and err ~= 0) then
        return
    end

    control = file
    connected = true
    announced = false
end

local function announce()
    if announced then return end
    local width, height = screen_size()
    if not width then return end
    announced = write_control(string.format("HELLO|frames|%s|%d|%d|%s", rom_name(), width, height, exports.version))
    if announced and not geometry_logged then
        geometry_logged = true
        log(string.format("ecran %dx%d, %d octets par image", width, height, width * height * 4))
    end
end

local function read_control()
    if not control then return nil end
    local ok, chunk = pcall(function() return control:read(4096) end)
    if not ok then
        disconnect()
        return nil
    end
    if not chunk or #chunk == 0 then return nil end
    inbox = inbox .. chunk

    local line
    local cut = inbox:find("\n", 1, true)
    if not cut then return nil end
    line = inbox:sub(1, cut - 1):gsub("\r$", "")
    inbox = inbox:sub(cut + 1)
    return line
end

-- ARM|host|port|token|count : on ouvre le socket vers le verificateur tout de suite. S'il
-- n'ecoute pas, on ne s'arme pas : mieux vaut ne rien capturer que copier pour jeter.
local function handle_arm(host, port, token, count)
    disarm("nouvel armement")
    if not resolve_screen() then
        write_control("ARMED|0|no-screen")
        return
    end

    local ok, file, err = pcall(function()
        local f = emu.file("", 3)
        local e = f:open("socket." .. tostring(host) .. ":" .. tostring(port))
        return f, e
    end)
    if not ok or not file or (err ~= nil and err ~= 0) then
        write_control("ARMED|0|no-verifier")
        return
    end

    sink = file
    armed = true
    arm_token = token or ""
    arm_left = math.min(tonumber(count) or 1, MAX_FRAMES_PER_ARM)
    arm_seq = 0
    last_capture_frame = -999999
    write_control("ARMED|1|" .. tostring(arm_left))
end

local function handle_line(line)
    if not line or line == "" then return end
    local parts = {}
    for piece in string.gmatch(line, "([^|]*)") do
        parts[#parts + 1] = piece
    end
    local verb = parts[1]

    if verb == "ARM" then
        handle_arm(parts[2], parts[3], parts[4], parts[5])
    elseif verb == "DISARM" then
        disarm("demande d'APIExpose")
        write_control("DISARMED")
    elseif verb == "PING" then
        write_control("PONG|" .. rom_name())
    end
end

-- Le budget par minute protege des rafales d'un declencheur trop bavard : passe le plafond,
-- on se desarme et APIExpose devra redemander.
local function minute_budget_left()
    if frame - minute_window_frame >= 3600 then
        minute_window_frame = frame
        minute_count = 0
    end
    return minute_count < MAX_CAPTURES_PER_MINUTE
end

local function capture_once()
    if not armed or not sink then return end
    if frame - last_capture_frame < min_interval_frames then return end
    if not minute_budget_left() then
        disarm("plafond par minute atteint")
        return
    end

    local width, height = screen_size()
    if not width then
        disarm("ecran introuvable")
        return
    end

    local ok, pixels = pcall(function() return screen_device:pixels() end)
    if not ok or type(pixels) ~= "string" or #pixels == 0 then
        disarm("pixels indisponibles")
        return
    end

    last_capture_frame = frame
    minute_count = minute_count + 1
    arm_seq = arm_seq + 1

    local header = string.format("FRAME|%s|%d|%d|%d|4|%d\n", arm_token, arm_seq, width, height, #pixels)
    local sent = pcall(function()
        sink:write(header)
        sink:write(pixels)
    end)
    pcall(function() sink:flush() end)
    if not sent then
        disarm("ecriture vers le verificateur echouee")
        return
    end

    arm_left = arm_left - 1
    if arm_left <= 0 then
        disarm("rafale terminee")
    end
end

function frames.startplugin()
    try_load_config()
    if config.min_interval_frames then
        min_interval_frames = math.max(1, tonumber(config.min_interval_frames) or 30)
    end

    reset_subscription = emu.add_machine_reset_notifier(function()
        disarm("reset machine")
        screen_device = nil
    end)

    stop_subscription = emu.add_machine_stop_notifier(function()
        disarm("arret machine")
        disconnect()
    end)

    frame_subscription = emu.add_machine_frame_notifier(function()
        frame = frame + 1
        connect_if_needed()
        if not connected then return end
        announce()

        local line = read_control()
        if line then
            handle_line(line)
        end

        if armed then
            capture_once()
        end
    end)
end

return exports
