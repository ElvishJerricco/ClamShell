
local multishell = multishell
local parentShell = shell
local parentTerm = term.current()
local clamPkg = grin.packageFromExecutable(parentShell.getRunningProgram())
local bish = grin.getPackageAPI(clamPkg, "bish")
local BishInterpreter = grin.getPackageAPI(clamPkg, "BishInterpreter")
local buffer = grin.getPackageAPI(clamPkg, "buffer")
local readLine = grin.getPackageAPI(clamPkg, "readLine")
local clamPath = grin.resolveInPackage(clamPkg, "clam.lua")

if multishell then
    multishell.setTitle( multishell.getCurrent(), "shell" )
end

local bExit = false
local sPath = ".:/" .. grin.getFromPackage(clamPkg, "tools") .. ":"
    .. ((parentShell and parentShell.path()) or "/rom/programs")
local tAliases = (parentShell and parentShell.aliases()) or {}
tAliases.sh = "clam"
tAliases.shell = "clam"

local environmentVariables
if parentShell and parentShell.getEnvironmentVariables then
    environmentVariables = parentShell.getEnvironmentVariables()
else
    environmentVariables = {}
end

local tProgramStack = {}

local shell = {}
local tEnv = {
    [ "shell" ] = shell,
    [ "multishell" ] = multishell,
}

-- Settings handling
local clamSettingsPath = ".clam.settings"
local clamSessionPath = ".clam.session"

local function writeSettings(path, table)
    if not table then return end

    local success, serialize = pcall(textutils.serialize, table)
    if not success then return end

    local file = fs.open(path, "w")
    if not file then return end
    file.write(serialize)
    file.close()
end

local function readSettings(path)
    local file = fs.open(path, "r")
    if not file then return end
    local contents = file.readAll()
    file.close()

    local result = textutils.unserialize(contents)
    if not result or type(result) ~= "table" then return end

    return result
end

-- Load settings
local termColors, settings, session
do
    local defaults = {
        colors = {
            prompt = colors.white,
            text = colors.white,
            bg = colors.black,
        },

        aliases = {},
        env = {},

        maxScrollback = 100,
        maxHistory = 100,
    }

    if term.isColor() then
        defaults.colors.prompt = colors.lightBlue
    end

    settings = setmetatable(readSettings(clamSettingsPath) or {}, {__index = defaults})
    session = readSettings(clamSessionPath) or {}

    -- Set session vars
    if type(session.dir) ~= "string" then
        session.dir = (parentShell and parentShell.dir and parentShell.dir()) or ""
    end

    if type(session.history) ~= "table" then
        session.history = {}
    end

    -- Colors
    termColors = setmetatable({}, {__index = defaults.colors})
    local validColors = {}
    for i=0,16,1 do validColors[2^i] = true end
    local validator = term.isColor() and
        function(c) return validColors[c] end or
        function(c) return color == colors.black or color == colors.white end

    local defaultCols = defaults.colors
    for name, color in pairs(settings.colors) do
        if type(color) == "string" then
            color = colors[color] or colours[color]
        end
        if not color or not validator(color) then
            color = defaultCols[name]
        end
        termColors[name] = color
    end

    -- Aliases
    local aliases = settings.aliases
    if type(aliases) == "table" then
        for name, value in pairs(aliases) do
            if type(name) == "string" and type(value) == "string" then
                tAliases[name] = value
            end
        end
    end

    -- Environment
    local variables = settings.env
    if type(variables) == "table" then
        for name, value in pairs(variables) do
            if type(name) == "string" and type(value) == "string" then
                environmentVariables[name] = value
            end
        end
    end

    -- Other settings
    session.maxHistory = tonumber(session.maxHistory)
    session.maxScrollback = tonumber(session.maxScrollback)
end

-- Install shell API
function shell.run( ... )
    local f, err = bish.compile(tEnv, shell, table.concat({...}, " "))
    if f then
        local ok, err = f()
        if not ok then
            printError(err)
            return false
        else
            return true
        end
    else
        printError(err)
        return false
    end
end

function shell.exit()
    bExit = true
end

function shell.dir()
    return session.dir
end

function shell.setDir( _sDir )
    session.dir = _sDir
    writeSettings(clamSessionPath, session)
end

function shell.path()
    return sPath
end

function shell.setPath( _sPath )
    sPath = _sPath
end

function shell.resolve( _sPath )
    local sStartChar = string.sub( _sPath, 1, 1 )
    if sStartChar == "/" or sStartChar == "\\" then
        return fs.combine( "", _sPath )
    else
        return fs.combine( session.dir, _sPath )
    end
end

function shell.resolveProgram( _sCommand )
    -- Substitute aliases firsts
    if tAliases[ _sCommand ] ~= nil then
        _sCommand = tAliases[ _sCommand ]
    end

    -- If the path is a global path, use it directly
    local sStartChar = string.sub( _sCommand, 1, 1 )
    if sStartChar == "/" or sStartChar == "\\" then
        local sPath = fs.combine( "", _sCommand )
        if fs.exists(sPath .. ".lua") and not fs.isDir(sPath .. ".lua") then
            return sPath .. ".lua"
        elseif fs.exists( sPath ) and not fs.isDir( sPath ) then
            return sPath
        end
        return nil
    end

    -- Otherwise, look on the path variable
    for sPath in string.gmatch(sPath, "[^:]+") do
        sPath = fs.combine( shell.resolve( sPath ), _sCommand )
        if fs.exists(sPath .. ".lua") and not fs.isDir(sPath .. ".lua") then
            return sPath .. ".lua"
        elseif fs.exists( sPath ) and not fs.isDir( sPath ) then
            return sPath
        end
    end

    -- Not found
    return nil
end

function shell.programs( _bIncludeHidden )
    local tItems = {}

    -- Add programs from the path
    for sPath in string.gmatch(sPath, "[^:]+") do
        sPath = shell.resolve( sPath )
        if fs.isDir( sPath ) then
            local tList = fs.list( sPath )
            for n,sFile in pairs( tList ) do
                if not fs.isDir( fs.combine( sPath, sFile ) ) and
                   (_bIncludeHidden or string.sub( sFile, 1, 1 ) ~= ".") then
                    tItems[ sFile ] = true
                end
            end
        end
    end

    -- Sort and return
    local tItemList = {}
    for sItem, b in pairs( tItems ) do
        table.insert( tItemList, sItem )
    end
    table.sort( tItemList )
    return tItemList
end

function shell.pushRunningProgram(prg)
    table.insert(tProgramStack, prg)
end

function shell.popRunningProgram()
    return table.remove(tProgramStack)
end

function shell.getRunningProgram()
    if #tProgramStack > 0 then
        return tProgramStack[#tProgramStack]
    end
end

function shell.setAlias( _sCommand, _sProgram )
    tAliases[ _sCommand ] = _sProgram
end

function shell.clearAlias( _sCommand )
    tAliases[ _sCommand ] = nil
end

function shell.aliases()
    -- Add aliases
    local tCopy = {}
    for sAlias, sCommand in pairs( tAliases ) do
        tCopy[sAlias] = sCommand
    end
    return tCopy
end

function shell.version()
    return "ClamShell 1.0"
end

function shell.getEnvironmentVariables()
    local copy = {}
    for k,v in pairs(environmentVariables) do
        copy[k] = v
    end
    return copy
end

function shell.getenv(name)
    grin.expect("string", name)
    return environmentVariables[name]
end

function shell.setenv(name, value)
    grin.expect("string", name)
    grin.expect("string", value)
    environmentVariables[name] = value
end

if multishell then
    function shell.openTab( ... )
        return multishell.launch(tEnv, "rom/programs/shell", clamPath, table.concat({...}," "))
    end

    function shell.switchTab( nID )
        multishell.setFocus( nID )
    end
end

local tArgs = { ... }
if #tArgs > 0 then
    -- "shell x y z"
    -- Run the program specified on the commandline
    shell.run( ... )

else
    -- "shell"
    -- Buffer
    term.clear()
    term.setCursorPos(1, 1)

    local thisBuffer = buffer.new(parentTerm)
    thisBuffer.bubble(true)
    thisBuffer.maxScrollback(settings.maxScrollback)
    term.redirect(thisBuffer)

    -- Print the header
    term.setBackgroundColor(termColors.bg)
    term.setTextColor(termColors.prompt)
    print(os.version(), " - ", shell.version())
    term.setTextColor(termColors.text)

    -- Run the startup program
    if parentShell == nil then
        shell.run( "/rom/startup" )
    end

    local tCommandHistory = session.history
    local maxHistory = settings.maxHistory

    -- Read commands and execute them
    while not bExit do
        term.redirect(thisBuffer)
        thisBuffer.friendlyClear(true)

        term.setBackgroundColor(termColors.bg)
        term.setTextColor(termColors.prompt)

        write( shell.dir() .. "> " )
        term.setTextColor(termColors.text)

        local offset = 0
        local sLine = nil
        parallel.waitForAny(
            function() sLine = readLine.read(nil, tCommandHistory) end,
            function()
                while true do
                    local changed = false
                    local e, change = os.pullEvent()
                    if e == "mouse_scroll" then
                        local newOffset = offset + change
                        if newOffset > 0 then newOffset = 0 end
                        if newOffset < -thisBuffer.totalHeight() then newOffset = -thisBuffer.totalHeight() end

                        offset = newOffset
                        changed = true
                    elseif e == "key" or e == "paste" and offset ~= 0 then
                        offset = 0
                        changed = true
                    end

                    if changed then
                        term.setCursorBlink(offset == 0)
                        thisBuffer.draw(offset)
                    end
                end
            end
        )
        if offset ~= 0 then buffer.draw() end

        if not sLine then
            return
        end

        if sLine:match("[^%s]") then -- If not blank
            for i = #tCommandHistory, 1, -1 do
                if tCommandHistory[i] == sLine then
                    table.remove(tCommandHistory, i)
                end
            end

            if maxHistory > -1 then
                while #tCommandHistory > maxHistory do -- Limit to n number of history items
                    table.remove(tCommandHistory, 1)
                end
            end
            table.insert( tCommandHistory, sLine )
            writeSettings(clamSessionPath, session)
        end

        shell.run( sLine )
    end
end
