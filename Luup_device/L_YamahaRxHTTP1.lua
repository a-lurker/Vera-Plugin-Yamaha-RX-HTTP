--[[
    Written by a-lurker (c) copyright 7 Feb 2014,  XML parser by Futzle

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    version 3 (GPLv3) as published by the Free Software Foundation;

    In addition to the GPLv3 License, this software is only for private
    or home usage. Commercial utilisation is not authorized.

    The above copyright notice and this permission notice shall be included
    in all copies or substantial portions of the Software.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
]]

local PLUGIN_NAME     = 'YamahaRxHTTP'
local PLUGIN_SID      = 'urn:a-lurker-com:serviceId:'..PLUGIN_NAME..'1'
local PLUGIN_VERSION  = '0.55'
local THIS_LUL_DEVICE = nil

local ipAddress = nil
local m_Connected = false

-- this family uses different XML commands and is the exception to the rule
local m_RX_V3900_family = false

local m_ZoneCount = 1

-- the LuaExpat library
local lxp = require('lxp')


local DEBUG_MODE = false

local function debug(textParm, logLevel)
    if DEBUG_MODE then
        local text = ''
        local theType = type(textParm)
        if (theType == 'string') then
            text = textParm
        else
            text = 'type = '..theType..', value = '..tostring(textParm)
        end
        luup.log(PLUGIN_NAME..' debug: '..text,50)

    elseif (logLevel) then
        local text = ''
        if (type(textParm) == 'string') then text = textParm end
        luup.log(PLUGIN_NAME..' debug: '..text, logLevel)
    end
end

-- If non existent, create the variable
-- Update the variable only if needs to be
local function updateVariable(varK, varV, sid, id)
    if (sid == nil) then sid = PLUGIN_SID      end
    if (id  == nil) then  id = THIS_LUL_DEVICE end

    if ((varK == nil) or (varV == nil)) then
        luup.log(PLUGIN_NAME..' debug: '..'Error: updateVariable was supplied with a nil value', 1)
        return
    end

    local newValue = tostring(varV)
    debug(newValue..' --> '..varK)

    local currentValue = luup.variable_get(sid, varK, id)
    if ((currentValue ~= newValue) or (currentValue == nil)) then
        luup.variable_set(sid, varK, newValue, id)
    end
end

-- Validate the zone. The input can be:
--    1,2,3 or 4 as a string or a number
--    Main_Zone, Zone_2, Zone_3, Zone_4
--    If the equipment does not support the requested Zone: default to zone 1
--    If the zone is nil, which is an error, then default to zone 1
--    None of the above occurs, which is an error and will default to zone 1
--
-- The zone is returned as:
--    a string identifying the zone in the commands to the AVR
--    a string identifying the zone in the plugin variable(s)
--    a number 1 to 4
local function zChk(zone)
    -- if it's not zone 2, 3 or 4 it will default to the main zone, ie zone 1
    local zNum = 1

    zone = tostring(zone)   -- zone can be a number or a string at this point. Make it a string
    if ((zone == '2') or (zone == '3') or (zone == '4')) then
        zNum = tonumber(zone)
    elseif ((zone == 'Zone_2') or (zone == 'Zone_3') or (zone == 'Zone_4')) then
        local result = zone:sub(zone:len())
        zNum = tonumber(result)
    end

    -- We have a valid zone number but does the equipment support this zone?
    -- If not default to the main zone
    if (zNum > m_ZoneCount) then zNum = 1 end

    -- based on the determined zone number, assign some strings to suit
    local zVarStr = ''   -- a string to use in saved variables
    local zCmdStr = ''   -- a string to use in commands to the AVR
    if     (zNum == 4) then
        zVarStr = 'Zone4'
        zCmdStr = 'Zone_4'
    elseif (zNum == 3) then
        zVarStr = 'Zone3'
        zCmdStr = 'Zone_3'
    elseif (zNum == 2) then
        zVarStr = 'Zone2'
        zCmdStr = 'Zone_2'
    else -- zNum = 1
        zVarStr = 'MainZone'
        zCmdStr = 'Main_Zone'
    end

    debug('zCmdStr: '..zCmdStr)
    debug('zVarStr: '..zVarStr)
    debug('zNum: '..tostring(zNum))

    return zCmdStr, zVarStr, zNum
end

--[[
The Yamaha receiver returns error codes depending on the error:

HTTP 400 Bad Request:  XML parse error

The response code is the "RC" attribute in the returned XML: <YAMAHA_AV rsp="GET" RC="0">......
0   Successful completion
1   Reserved
2   Error in node designation - not supported by the specific model
3   Error in parameter (value/range) - not supported by the specific model
4   Not successfully set due to a system error - protected by a Guard Condition
5   Internal error
]]

-- refer also to: http://w3.impa.br/~diego/software/luasocket/http.html
local function urlRequest(request_body)
    local ltn12 = require('ltn12')
    local http  = require('socket.http')

    http.TIMEOUT = 1

    local response_body = {}

    -- site not found: r is nil, c is the error status eg (as a string) 'No route to host' and h is nil
    -- site is found:  r is 1, c is the return status (as a number) and h are the returned headers in a table variable
    local r, c, h = http.request {
          url = 'http://'..ipAddress..'/YamahaRemoteControl/ctrl',
          method = 'POST',
          headers = {
            ['Content-Type']   = 'text/xml; charset=UTF-8',
            ['Content-Length'] = string.len(request_body)
          },
          source = ltn12.source.string(request_body),
          sink   = ltn12.sink.table(response_body)
    }

    debug('URL request result: r = '..tostring(r))
    debug('URL request result: c = '..tostring(c))
    debug('URL request result: h = '..tostring(h))

    local page = ''
    if (r == nil) then return false, page end

    if ((c == 200) and (type(response_body) == 'table')) then
        page = table.concat(response_body)
        debug('Returned web page data is : '..page)

        local i, j = page:find('RC="0"')
        if (i == nil) then
            luup.log(PLUGIN_NAME..' debug: Error - this command is invalid: '..request_body, 1)
            return false, page
        end

        return true, page
    end

    if (c == 400) then
        luup.log(PLUGIN_NAME..' debug: HTTP 400 Bad Request: XML parse error', 1)
        return false, page
    end

    return false, page
end

-- runParser(xmlSource, targets)
-- Returns a parser object that collects strings in an XML document based on their root-to-element "xpath".
-- Parameters:
--   xmlSource: the XML to parse
--   targets: array of strings, the paths to look for.  In form "/root/element1/element2".
-- Returns:
--   table, keys:
--     result: function which takes an XPath that was sought (string).
--       returns an array, each element one occurrence of the xpath, contains the strings in that element.
local function runParser(xmlSource, targets)
    local currentXpathTable = {}

    local currentXpath = function()
        return "/" .. table.concat(currentXpathTable, "/")
    end

    local result = {}

    local targetTable = {}
    for _, xpath in pairs(targets) do
        targetTable[xpath] = true
        result[xpath] = {}
    end

    local callbacks = {
        StartElement = function(parser, elementName, attributes)
            --debug("XML: start element: " .. elementName)
            table.insert(currentXpathTable, elementName)
            if (targetTable[currentXpath()]) then
                table.insert(result[currentXpath()], "")
            end
        end,
        CharacterData = function(parser, string)
            --debug("XML: string: " .. string)
            if (targetTable[currentXpath()]) then
                debug("XPath match, new result: "..string)
                result[currentXpath()][#(result[currentXpath()])] = result[currentXpath()][#(result[currentXpath()])] .. string
            end
        end,
        EndElement = function(parser, elementName)
            --debug("XML: end element: " .. elementName)
            table.remove(currentXpathTable)
        end
    }

    local p = lxp.new(callbacks)

    p:parse(xmlSource)
    p:parse()  -- finishes the document
    p:close()  -- closes the parser

    return {result = function(s) return result[s] end }
end

local function parseXMLconfig(returnedXML)
    -- avoid too much string duplication by defining the common path sections here first
    local XPathBranch1 = '/YAMAHA_AV/System/Config/'
    local XPathBranch2 = '/YAMAHA_AV/System/Config/Feature_Existence/'

    local modelNameXP = XPathBranch1..'Model_Name'
    local systemIdXP  = XPathBranch1..'System_ID'
    local versionXP   = XPathBranch1..'Version'

    local z2XP = XPathBranch2..'Zone_2'
    local z3XP = XPathBranch2..'Zone_3'
    local z4XP = XPathBranch2..'Zone_4'

    -- look for these paths in the XML
    local xpathParser = runParser(returnedXML, {
        modelNameXP,
        systemIdXP,   -- not used
        versionXP,    -- not used
        z2XP,
        z3XP,
        z4XP
    })

    -- get the results
    local modelName = xpathParser.result(modelNameXP)[1]
    local systemId  = xpathParser.result(systemIdXP) [1]
    local version   = xpathParser.result(versionXP)  [1]
    local z2 = xpathParser.result(z2XP)[1]
    local z3 = xpathParser.result(z3XP)[1]
    local z4 = xpathParser.result(z4XP)[1]

    -- Count up the number of available zones for this AVR
    -- Don't rely on the XML numbering order of the zone info
    -- It could be backwards like this
    m_ZoneCount = 1
    if ((z4 ~= nil) and (z4 == '1')) then m_ZoneCount = m_ZoneCount+1 end
    if ((z3 ~= nil) and (z3 == '1')) then m_ZoneCount = m_ZoneCount+1 end
    if ((z2 ~= nil) and (z2 == '1')) then m_ZoneCount = m_ZoneCount+1 end

    updateVariable('ModelName', modelName)
    updateVariable('ZoneCount', m_ZoneCount)
end

local function parseXMLstatus(zone, returnedXML)

    local zCmdStr, zVarStr = zChk(zone)

    -- avoid too much string duplication by defining the common path sections here first
    local XPathBranch1 = '/YAMAHA_AV/'..zCmdStr..'/Basic_Status/'

    local powerXP  = XPathBranch1..'Power_Control/Power'
    local inputXP  = XPathBranch1..'Input/Input_Sel'
    local volumeXP = ''
    local muteXP   = ''

    -- The RX-V3900 (and other AVRs possibly?) use the tag "Vol" instead of "Volume", so flag the family:
    local tag = returnedXML:find('Volume')
    if (tag == nil) then m_RX_V3900_family = true end

    local volumeTag = 'Volume'
    if (m_RX_V3900_family) then volumeTag = 'Vol' end

    local volumeXP = XPathBranch1..volumeTag..'/Lvl/Val'
    local muteXP   = XPathBranch1..volumeTag..'/Mute'

    -- look for these paths in the XML
    local xpathParser = runParser(returnedXML, {
        powerXP,
        inputXP,
        volumeXP,
        muteXP
    })

    -- get the results
    local power  = xpathParser.result(powerXP) [1]
    local input  = xpathParser.result(inputXP) [1]
    local volume = xpathParser.result(volumeXP)[1]
    local mute   = xpathParser.result(muteXP)  [1]

    local volVal = tonumber(volume)
    if (volVal) then
        -- example:  -45.5 dB is expressed as -455
        volume = tostring(volVal / 10.0)
        updateVariable(zVarStr..'Volume', volume)
    end

    updateVariable(zVarStr..'Power', power)
    updateVariable(zVarStr..'Input', input)
    updateVariable(zVarStr..'Mute',  mute)
end

-- as soon as the link goes from not m_Connected to m_Connected, the
-- config is retrieved and the connection status is set to true
local function getConfig()
    if m_Connected then return end

    local command = '<YAMAHA_AV cmd="GET"><System><Config>GetParam</Config></System></YAMAHA_AV>'
    local success, returnedXML = urlRequest(command)

    m_Connected = success
    if m_Connected then
        updateVariable('Connected', '1')
    else
        updateVariable('Connected', '0')
        return
    end

    debug('Successful execution of getConfig: XML is '..returnedXML)
    parseXMLconfig(returnedXML)
end

local function getZoneStatus(zone)
    local zCmdStr, _, zNum = zChk(zone)

    -- only get the status if the link is up
    if not m_Connected then return end

    local command = '<YAMAHA_AV cmd="GET"><'..zCmdStr..'><Basic_Status>GetParam</Basic_Status></'..zCmdStr..'></YAMAHA_AV>'
    local success, returnedXML = urlRequest(command)

    m_Connected = success
    if m_Connected then
        updateVariable('Connected', '1')
    else
        updateVariable('Connected', '0')
        return
    end

    debug('Successful execution of getZoneStatus for zone '..tostring(zNum)..': XML is '..returnedXML)
    parseXMLstatus(zone, returnedXML)
end

-- get the status every 30 seconds, while simultaneously
-- checking if the network connection is still OK
-- this function needs to be global, so the timer's TimeOut can find it
function monitor()
    -- As soon as the link is up, the AV receiver config is
    -- retrieved and the connection status is set to true.
    -- If it goes down, the connection status is set to false
    -- after a one second timeout.

    -- get the AVR version and number of zones
    getConfig()

    -- update the status of all the zones if the link is up
    for i = 1, m_ZoneCount do getZoneStatus(i) end

    -- get the status every 30 seconds
    luup.call_delay('monitor', 30, '')
end

local function send(zone, command)
    -- only send the command if the link is up
    if not m_Connected then return end

    local XML_LEAD_IN  = '<?xml version="1.0" encoding="utf-8"?><YAMAHA_AV cmd="PUT"><'
    local XML_LEAD_OUT = '></YAMAHA_AV>'

    command = XML_LEAD_IN..command..XML_LEAD_OUT

    debug('Sending command: '..command)
    urlRequest(command)

    -- update the status right now
    -- also update the connection status
    getZoneStatus(zone)
end

-- allowed values: 'On', 'Standby'
local function setPower(zone, power)
    local zCmdStr = zChk(zone)
    power = power or ''

    local command = zCmdStr..'><Power_Control><Power>'..power..'</Power></Power_Control></'..zCmdStr
    send(zone, command)
end

-- allowed values: a scene number: 1 to 4;  5 to 12 may also be available
local function setScene(zone, sceneNumber)
    local zCmdStr = zChk(zone)

    sceneNumber = tostring(sceneNumber)
    sceneNumber = sceneNumber or ''
    local command = zCmdStr..'><Scene><Scene_Load>Scene '..sceneNumber..'</Scene_Load></Scene></'..zCmdStr
    send(zone, command)
end

-- allowed string values: 'HDMIx', 'AVx', 'AUDIOx', 'V-AUX', 'TUNER', 'USB', 'Pandora', 'AirPlay', 'SERVER'
-- where x in the above is a single digit integer. There may be other inputs available.
local function setInput(zone, input)
    local zCmdStr = zChk(zone)
    input = input or ''

    local command = zCmdStr..'><Input><Input_Sel>'..input..'</Input_Sel></Input></'..zCmdStr
    send(zone, command)
end

-- note that VOLFIXVAR may effect if the volume can be altered at all
-- the range is -80.5 to 16.5, step size is 0.5
local function setVolume(zone, volume)
    local zCmdStr = zChk(zone)
    volume = tonumber(volume) or -80.5

    -- example:  -45.5 dB is expressed as -455
    volume = tostring(volume * 10.0)

    local command = zCmdStr..'><Volume><Lvl><Val>'..volume..'</Val><Exp>1</Exp><Unit>dB</Unit></Lvl></Volume></'..zCmdStr
    if (m_RX_V3900_family) then
        command = zCmdStr..'><Vol><Lvl><Val>'..volume..'</Val><Exp>1</Exp><Unit>dB</Unit></Lvl></Vol></'..zCmdStr
    end

    send(zone, command)
end

-- note that VOLFIXVAR may effect if the volume can be altered at all
-- only increments of 0.5, 1, 2 and 5 dB are allowed
-- generally no data is needed in the "Exp" and "Unit" tags but the tags must be present
local function setVolumeUpDown(zone, step)
    local zCmdStr, zVarStr = zChk(zone)

    -- default a missing step or an invalid string to a down step of -0.5
    step = tonumber(step)
    if (step == nil) then step = -0.5 end

    local valueAbs = math.abs(step)
    if ((valueAbs ~= 5.0) and (valueAbs ~= 2.0) and (valueAbs ~= 1.0)) then step = -0.5 end

    if (m_RX_V3900_family) then
        local volStr = luup.variable_get(PLUGIN_SID, zVarStr..'Volume',  THIS_LUL_DEVICE)
        local volume = tonumber(volStr)
        if (volume) then
            volume = volume + step
            -- example:  -45.5 dB is expressed as -455
            volStr = tostring(volume * 10.0)

            local command = zCmdStr..'><Vol><Lvl><Val>'..volStr..'</Val><Exp>1</Exp><Unit>dB</Unit></Lvl></Vol></'..zCmdStr
            send(zone, command)
        end

    else
        local stepStr = ''
        if     (valueAbs == 5.0) then stepStr = ' 5 dB'
        elseif (valueAbs == 2.0) then stepStr = ' 2 dB'
        elseif (valueAbs == 1.0) then stepStr = ' 1 dB' end

        -- any step value that is not 1, 2 or 5 will default to a discrete up or down 0.5 dB step
        -- that is:  just the string 'Up' or 'Down' is sent
        local upDwnStr = ''
        if (step >= 0.0) then
            upDwnStr = 'Up'..stepStr
        else
            upDwnStr = 'Down'..stepStr
        end

        local command = zCmdStr..'><Volume><Lvl><Val>'..upDwnStr..'</Val><Exp></Exp><Unit></Unit></Lvl></Volume></'..zCmdStr
        send(zone, command)
    end
end

-- allowed values: 'On', 'Off', 'Att -40 dB', 'Att -20 dB', 'On/Off' (the latter being
-- a toggle)
local function setMute(zone, mute)
    local zCmdStr = zChk(zone)
    mute = mute or ''

    local command = zCmdStr..'><Volume><Mute>'..mute..'</Mute></Volume></'..zCmdStr
    if (m_RX_V3900_family) then
        command = zCmdStr..'><Vol><Mute>'..mute..'</Mute></Vol></'..zCmdStr
    end

    send(zone, command)
end

-- source is 'SERVER', 'USB', 'NET RADIO', 'iPod_USB', 'Pandora' and probably others - just try them
-- mode is Stop, Pause, Play, Skip Rev, Skip Fwd
local function playControl(source, mode)
    source = source or ''
    mode = mode or ''

    local command = source..'><Play_Control><Playback>'..mode..'</Playback></Play_Control></'..source

    -- the zone 1 status will be updated by getZoneStatus
    send(1, command)
end

-- source is 'SERVER', 'USB', 'NET RADIO', 'iPod_USB', 'Pandora' and probably others - just try them
-- the preset number of a previously saved station/whatever. Numbered from 1 to 40
local function selectPreset(source, preset)
    source = source or ''
    preset = preset or ''

    preset = tostring(preset)
    local command = source..'><Play_Control><Preset><Preset_Sel>'..preset..'</Preset_Sel></Preset></Play_Control></'..source

    -- the zone 1 status will be updated by getZoneStatus
    send(1, command)
end

-- allowed values: 'On', 'Off'
-- Alternative Party mode for 3 zones or more;  where *** = On/Off or perhaps Enable/Disable - not checked
-- <?xml version="1.0" encoding="utf-8"?><YAMAHA_AV cmd="PUT"><System><Party_Mode><Target_Zone><Zone_2>***</Zone_2><Zone_3>***</Zone_3><Zone_4>***</Zone_4></Target_Zone></Party_Mode></System></YAMAHA_AV>
local function setPartyMode(letsParty)
    letsParty = letsParty or ''

    local command = 'System><Party_Mode><Mode>'..letsParty..'</Mode></Party_Mode></System'

    -- the zone 1 status will be updated by getZoneStatus
    send(1, command)
end

-- Code is 8 characters in hex. Example, omit the hyphens:
-- Zone 2 On/Off toggle = 7A85-453A <-- works,  7A85-453B <-- doesn't work
local function sendRemoteCode(remoteCode)
    remoteCode = tostring(remoteCode)
    remoteCode = remoteCode or ''

    local command = 'System><Misc><Remote_Signal><Receive><Code>'..remoteCode..'</Code></Receive></Remote_Signal></Misc></System'

    -- the zone 1 status will be updated by getZoneStatus
    send(1, command)
end

-- Start up the plugin
-- Refer to: I_YamahaRxHTTP1.xml
-- <startup>luaStartUp</startup>
-- function needs to be global
function luaStartUp(lul_device)
    THIS_LUL_DEVICE = lul_device
    debug('luaStartUp running')

    m_Connected = false
    updateVariable('Connected', '0')

    updateVariable('PluginVersion', PLUGIN_VERSION)

    local ipa = luup.devices[THIS_LUL_DEVICE].ip
    ipAddress = string.match(ipa, '^(%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?)')

    if ((ipAddress == nil) or (ipAddress == '')) then return false, 'Enter a valid IP address', PLUGIN_NAME end

    local linkToDeviceWebPage = "<a href='http://"..ipAddress.."/' target='_blank'>Yamaha Receiver web page</a>"
    updateVariable('LinkToDeviceWebPage', linkToDeviceWebPage)

    monitor()

    -- required for UI7
    luup.set_failure(false)

    return true, 'All OK', PLUGIN_NAME
end

