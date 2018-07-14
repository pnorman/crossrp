
local _, Me = ...
local L = Me.Locale
-- TODO: make sure you don't make duplicate requests. if you see someone else
--  make a request for something, share that cooldown!
-------------------------------------------------------------------------------
-- Entries in our vernum string.
--
--local VERNUM_RPCLIENT     = 1
--local VERNUM_VERSION_TEXT = 2
local VERNUM_PROFILE      = 1
local VERNUM_CHS_V        = 2
local VERNUM_ABOUT_V      = 3
local VERNUM_MISC_V       = 4
local VERNUM_CHAR_V       = 5
--local VERNUM_TRIAL        = 8

-- Exposure for other implementations.
--Me.VERNUM_CLIENT       = VERNUM_CLIENT
--Me.VERNUM_VERSION_TEXT = VERNUM_VERSION_TEXT
Me.VERNUM_PROFILE      = VERNUM_PROFILE
Me.VERNUM_CHS_V        = VERNUM_CHS_V
Me.VERNUM_ABOUT_V      = VERNUM_ABOUT_V
Me.VERNUM_MISC_V       = VERNUM_MISC_V
Me.VERNUM_CHAR_V       = VERNUM_CHAR_V
--Me.VERNUM_TRIAL        = VERNUM_TRIAL

-------------------------------------------------------------------------------
-- Indexes of parts that need updates. We use the word `update` a bunch where
--  it means a registry slice.
--
local UPDATE_CHS   = 1 -- Section B, update on mouseover.
local UPDATE_ABOUT = 2 -- Section D: update on inspect.
local UPDATE_MISC  = 3 -- Section C: update on target.
local UPDATE_CHAR  = 4 -- Section A, update on mouseover.
local UPDATE_SLOTS = 4

Me.TRP_UPDATE_CHS   = UPDATE_CHS
Me.TRP_UPDATE_ABOUT = UPDATE_ABOUT
Me.TRP_UPDATE_MISC  = UPDATE_MISC
Me.TRP_UPDATE_CHAR  = UPDATE_CHAR
Me.TRP_UPDATE_SLOTS = UPDATE_SLOTS

-- Things are a bit jumbled up right now, but we want to have this work with
--  little rewriting as possible. Eventually, we will switch fully to the
--  unified protocol.

-------------------------------------------------------------------------------
-- Functions for getting exchange data for a certain update slot.
--
local EXCHANGE_DATA_FUNCS

-------------------------------------------------------------------------------
-- Info types in the registry for each update slot.
--
local INFO_TYPES

-------------------------------------------------------------------------------
local SEND_COOLDOWN = 20.0  -- Cooldown for sending profile data.
local SEND_DELAY    = 5.0   -- Delay for sending profile data when not on
                            --  cooldown.
local REQUEST_COOLDOWN = 30.0  -- Cooldown for requesting profile data when 
                               --  mousing over.
local VERNUM_HENLO_DELAY = 27.0  -- Delay after getting HENLO to send vernum.
local VERNUM_HENLO_VARIATION = 10.0 -- We add 0 to this amount of seconds
                                    --  randomly, so when clients respond with
									--  VERNUM, they're not all sending it at
									--  the same time and punching the server.
local VERNUM_UPDATE_DELAY = 5.0  -- Delay after updating our profile data (like
                                 --  currently etc) before broadcasting our
								 --  vernum.
local REQUEST_IGNORE_PERIOD = 5.0  -- Seconds to wait before we accept new
                                   --  requests for an update slot we just
								   --  sent.
								   
--@debug@
VERNUM_HENLO_DELAY = 1.0  -- DEBUG BYPASS!!
VERNUM_HENLO_VARIATION = 1.0
REQUEST_COOLDOWN = 8.0
--@end-debug@
-------------------------------------------------------------------------------
-- What players we see out of date.
--   [username] is nil if we think we're up to date.
--   [username][UPDATE_SLOT] is true when we want updates.
Me.TRP_needs_update = {}
-------------------------------------------------------------------------------
-- Data that we're about to send.
--   [UPDATE_SLOT] is true when we're scheduled to send something.
Me.TRP_sending = {}
-------------------------------------------------------------------------------
-- Last time we sent our profile bits.
--   [UPDATE_SLOT] = time we last sent this update slot.
-- We use this to ignore TR message parts for `REQUEST_IGNORE_PERIOD` seconds.
Me.TRP_last_sent = {}
-------------------------------------------------------------------------------
-- The last time we requested data from someone, so we can have a cooldown.
Me.TRP_request_times = {}
-------------------------------------------------------------------------------
-- TRP3 can be replaced by other implementations if it isn't installed.
--
Me.TRP_imp = nil

-------------------------------------------------------------------------------
-- This tells us whether or not we should accept profile bits from people.
-- We don't want to intercept any profile transfers unless we start from the
--  vernum stage, otherwise we could be left in a wonky state, overwriting the
--  wrong profile with data, or saving data when we don't want to, like when
--  dealing with local MSP users.
-- Set to true when accepting their vernum, and revoke it when you discard
--  their vernum.
Me.TRP_accept_profile = {}

-------------------------------------------------------------------------------
-- PROTOCOL
-- Vernum Table:
--   TV a:b:c:d:e
--      | | | | |
--      '--------------- COLON SEPARATED LIST OF VERNUM_XYZ ENTRIES
--
-- Request info from user:
-- TR user:abcd
--     |    '---- UPDATE REQUESTS (1-4), "1" = update, "0" = skip
--     '--------- TARGET USER FULLNAME
--
-- Transfer data (DATA message):
-- TRPDx DATA
--     |  '---- PACKED EXCHANGE DATA
--     '------- UPDATE INDEX (1-4)
--
-------------------------------------------------------------------------------
-- When we see a VERNUM message, we flag users who we need updates from. We
--  don't actually do anything until we mouseover them. When we mouseover, we
--  see what we flagged and then request updates from them.
--
function Me.TRP_SetNeedsUpdate( user, slot )
	Me.TRP_needs_update[user] = Me.TRP_needs_update[user] or {}
	Me.TRP_needs_update[user][slot] = true
end

-------------------------------------------------------------------------------
-- After we receive the exchange data and update TRP's registry, we clear the
--  flags.
--
function Me.TRP_ClearNeedsUpdate( user, slot )
	if not Me.TRP_needs_update[user] then return end
	Me.TRP_needs_update[user][slot] = nil
	for k, v in pairs( Me.TRP_needs_update[user] ) do
		return
	end
	Me.TRP_needs_update[user] = nil
end

-------------------------------------------------------------------------------
-- Vernum (Version Numbers) is sent to people on the login message and after
--  we update the registry.
-- For login messages, we put a much longer delay, because that's low priority.
-- If you update your info, the delay is much shorter, just giving you enough
--  time to finish editing your currently or something before the vernum is
--  sent to everyone.
--
function Me.TRP_SendVernum()
	if not Me.relay_on then return end
	
	local query
	
	Me.TRP_last_sent_vernum = GetTime()
	
	if TRP3_API then
		-- Store empty profile as "-" in the protocol.
		local profile_id = TRP3_API.profile.getPlayerCurrentProfileID()
		if not profile_id then return end -- no profile loaded!
--		or profile_id == "" then profile_id = "-" end
		
		query = table.concat( {
		--	TRP3_API.globals.addon_name; -- a number
		--	TRP3_API.globals.version_display; -- a string
			profile_id; -- a string
			TRP3_API.profile.getData( "player/characteristics" ).v or 0;
			TRP3_API.profile.getData( "player/about" ).v or 0;
			TRP3_API.profile.getData( "player/misc" ).v or 0;
			TRP3_API.profile.getData( "player/character" ).v or 1;
		--	TRP3_API.globals.isTrialAccount and 1 or 0; -- true/nil
		}, ":" )
	elseif Me.TRP_imp then
		query = Me.TRP_imp.BuildVernum()
	else
		-- No TRP implemenation.
		return
	end
	
	Me.SendPacket( "TV", query )
end

-------------------------------------------------------------------------------
-- Currently only being called from the login command from others. We add a
--  long delay here because it isn't urgent at all and want to hit as many
--  people as possible.
--
function Me.TRP_SendVernumDelayed()
	--if not TRP3_API then return end
	Me.Timer_Start( "trp_vernums", "ignore", 
	               VERNUM_HENLO_DELAY + math.random(0, VERNUM_HENLO_VARIATION), 
				   Me.TRP_SendVernum )
end

-------------------------------------------------------------------------------
-- Receiving Vernum from someone.
--
function Me.ProcessPacket.TV( user, command, msg )
	if user.self or not user.connected then return end
	
	-- Maybe we should cancel here for local players for compatibility reasons.
	-- It doesn't hurt to save this data for TRP though if you do it right.
	
	local args = {}
	for v in msg:gmatch( "[^:]+" ) do
		table.insert( args, v )
	end

	-- Conversion to numbers and basic sanitization.
	--args[VERNUM_VERSION] = tonumber(args[VERNUM_VERSION])
	args[VERNUM_CHS_V]   = tonumber(args[VERNUM_CHS_V]) 
	args[VERNUM_ABOUT_V] = tonumber(args[VERNUM_ABOUT_V])
	args[VERNUM_MISC_V]  = tonumber(args[VERNUM_MISC_V])
	args[VERNUM_CHAR_V]  = tonumber(args[VERNUM_CHAR_V])
	--args[VERNUM_TRIAL]   = args[VERNUM_TRIAL] == "1" and true or nil
	if args[VERNUM_PROFILE] == "-" or args[VERNUM_PROFILE] == "" then
		-- This is now required.
		return
	end
	
	if not args[VERNUM_CHS_V] or not args[VERNUM_ABOUT_V]
	        or not args[VERNUM_MISC_V] or not args[VERNUM_CHAR_V] then
		return 
	end
	
	Me.DebugLog( "Got vernum from %s : %s", user.name, msg )
	
	local cmsp = args[VERNUM_PROFILE]:match( "^[CMSP]" )
	
	if TRP3_API then
		if cmsp and Me.IsLocal( user.name, true ) then
			-- Local user, or piggybacking off of raid, don't deal with their
			--  profile.
			Me.TRP_accept_profile[user.name] = false
			return
		else
			Me.TRP_accept_profile[user.name] = true
		end
	
		-- Save info.
		if not TRP3_API.register.isUnitIDKnown( user.name ) then
			TRP3_API.register.addCharacter( user.name );
			local addon_name = "Cross RP"
			local addon_version = GetAddOnMetadata( "CrossRP", "Version" )
			TRP3_API.register.saveClientInformation( user.name, 
		                         addon_name, addon_version, false, nil, false )
		end
		
		TRP3_API.register.saveCurrentProfileID( user.name, args[VERNUM_PROFILE] )
		
		-- Check the update slot version numbers to see what we are out of date
		--  with.
		for i = 1, UPDATE_SLOTS do
			if TRP3_API.register.shouldUpdateInformation( user.name, 
					INFO_TYPES[i], args[VERNUM_CHS_V+i-1] ) then
				Me.TRP_SetNeedsUpdate( user.name, i )
			end
		end
	
	elseif Me.TRP_imp then
		Me.TRP_accept_profile[user.name] = Me.TRP_imp.OnVernum( user, args )
		
--		for i = 1, UPDATE_SLOTS do
--			if TRP_imp.NeedsUpdate( user, i, args[VERNUM_CHS_V+i-1] ) then
--				Me.TRP_SetNeedsUpdate( user.name, i )
--			end
--		end
		
		return
	end
end

-------------------------------------------------------------------------------
-- This is a data request from someone.
--
function Me.ProcessPacket.TR( user, command, msg )
	if user.self or not user.connected then return end
	-- (This check isn't necessary. Why is anyone even doing this?)
	--if not user.horde and not user.xrealm then 
	--	-- local player, don't use this protocol.
	--	return
	--end
	if not Me.relay_on then
		-- Relay is off. Ignore this.
		return
	end
	
	local target, a, b, c, d = msg:match( "^([^:]+):(%d)(%d)(%d)(%d)" )
	if not target then return end
	local targeting_us = target == Me.fullname
	if not targeting_us then
		
	else
		
		Me.DebugLog2( "Received TRP request.", a, b, c, d )
	end

	-- If request isn't targeting us, we still want to update our cooldowns 
	--  with it.
	Me.TRP_request_times[user.name] = Me.TRP_request_times[user.name] or {}
	local rqt = Me.TRP_request_times[user.name]
	
	local parts = { a, b, c, d }
	for i = 1, UPDATE_SLOTS do
		if parts[i] == "1" then
			if targeting_us then
				local time_elapsed = GetTime() - (Me.TRP_last_sent[i] or 0)
				if time_elapsed < REQUEST_IGNORE_PERIOD then
					-- We're in the ignore period. This is set after we
					--  broadcast data, for each part, so that any additional
					--  requests that come /right after/ are ignored, as they
					--  likely have just been fulfilled. In the corner case 
					--  where someone actually just logged in and missed that
					--  message, they'll have to wait out the cooldown before
					--                               making another request.
				else
					Me.TRP_sending[i] = true
					
					-- Use one timer per sending slot. Cooldown mode so this can
					--  trigger instantly!
					Me.Timer_Start( "trp_sending" .. i, "cooldown", 
					                            SEND_COOLDOWN, function()
						Me.TRP_SendProfile( i )
					end)
				end
			else
				-- Reset our cooldown. Only one person has to make a request.
				rqt[i] = GetTime()
			end
		end
	end
	
--	if not targeting_us then
--		return
--	end
	
	-- This timer is a mix of cooldown and normal. If it's on CD, then we run
	--  it normally - at the next CD end. If it's not on CD, we still use a 
	--  delay, to catch any additional requests before we send out
	--  data.
	-- Scenario: Player is running around like an idiot, and comes across
	--  a group of a few people. They're gonna mouse-over and then send
	--  their TRP requests all at once. We want to catch them all before we
	--  actually do the send.
--	if Me.Timer_NotOnCD( "trp_sending", SEND_COOLDOWN ) then	
	--	Me.Timer_Start( "trp_sending", "ignore", SEND_DELAY, function()
--			Me.TRP_SendProfile()
--		end)
--	else
--		Me.Timer_Start( "trp_sending", "cooldown", SEND_COOLDOWN, function()
--			Me.TRP_SendProfile()
--		end)
--	end
end

-------------------------------------------------------------------------------
-- Send out our exchange data. Use as sparingly as possible, as this is 
--  broadcasted to everyone.
--
function Me.TRP_SendProfile( slot )
	if not Me.relay_on then 
		-- Don't send anything if the relay is turned off at some point.
		Me.TRP_sending[slot] = nil
		return
	end
	
	--for i = 1, UPDATE_SLOTS do
		if Me.TRP_sending[slot] then
			Me.TRP_sending[slot] = nil
			Me.TRP_last_sent[slot] = GetTime()
			local data = nil
			if TRP3_API then
				data = EXCHANGE_DATA_FUNCS[slot]()
				if type(data) == "string" then
					-- Revert TRP's compression. :(
					data = TRP3_API.utils.serial.safeDecompressCodedStructure(data, {});
				end
			else
				if Me.TRP_imp then
					data = Me.TRP_imp.GetExchangeData(slot)
				end
			end
			
			if data then
				Me.DebugLog( "Sending profile piece %d", slot )
				Me.SendData( "TRPD" .. slot, data )
			end
		end
	--end
end

-------------------------------------------------------------------------------
-- Callback for receiving TRP DATA messages.
--
local function HandleTRPData( user, tag, istext, data )
	if user.self then return end
	if not user.horde and not user.xrealm then
		-- /Maybe/ we should cut out here, because otherwise we have two
		--  protocols going - one in addon whisper, and the other in the
		--  relay channel. Is this bad though? Double updates sometimes.
	end
	
	if not TRP_accept_profile[user.name] then
		-- This player isn't flagged to receive data from. Cancel before we
		--  botch something. This is a very delicate operation!
		return
	end
	
	-- Parse out the index from the tag TRPDx, and then save the data.
	local index = tonumber(tag:match( "TRPD(%d+)" ))
	if not index then return end
	
	if TRP3_API then
		-- Catch unregistered unit. Maybe we should register them here? I'm not
		--  sure if you can do that without the Vernum.
		if not TRP3_API.register.isUnitIDKnown( user.name ) then
			return
		end
		
		if not TRP3_API.register.getUnitIDCurrentProfile( user.name ) then 
			return
		end
		
		if type(data) == "string" then
			-- This might be a compressed string.
			data = TRP3_API.utils.serial.safeDecompressCodedStructure(data, {});
		end
		
		if index == 1 then
			local client = data.VA
			if client then
				-- don't store anything foreign in the trp registry or ellypse will have a cow
				data.VA = nil
				local client_name, client_version, trial = client:match( "([^;]+);([^;]+);([0-9])" )
				if client_name then
					local character = TRP3_API.register.getUnitIDCharacter( user.name );
					character.client        = client_name;
					character.clientVersion = client_version
					character.msp           = false
					character.extended      = false;
					character.isTrial       = trial == "1"
				end
			end
		end
		if index == 3 then
			local _, profile_id = TRP3_API.register.getUnitIDCurrentProfile( user.name )
			if profile_id:match( "^%[CMSP%]" ) then
				data.PE = {
					["5"] = {
						AC = true;
						TI = "(Cross RP)";
						TX = L.CROSS_RP_GLANCE;
						IC = "INV_Jewelcrafting_ArgusGemCut_Green_MiscIcons";
					};
				}
			end
		end
		
		TRP3_API.register.saveInformation( user.name, INFO_TYPES[index], data );
	elseif Me.TRP_imp then
		
		Me.TRP_imp.SaveProfileData( user, index, data )
		
	end
	Me.TRP_ClearNeedsUpdate( user.name, index )
end

Me.DataHandlers.TRPD1 = HandleTRPData
Me.DataHandlers.TRPD2 = HandleTRPData
Me.DataHandlers.TRPD3 = HandleTRPData
Me.DataHandlers.TRPD4 = HandleTRPData

-------------------------------------------------------------------------------
-- If the user has an obnoxiously long TRP, the timeouts might expire before
--  it's actually sent.
--
local function HandleDataProgress( user, tag, istext, data )
	local index = tonumber(tag:match( "TRPD(%d+)" ))
	if user.self then
		-- If we see ourself sending, update our last_sent blocker
		Me.TRP_last_sent[index] = GetTime()
	else
		-- If we see someone else sending, set our REQUEST_COOLDOWN cd, so
		--  we don't update them anytime soon.
		Me.TRP_request_times[user.name] = Me.TRP_request_times[user.name] or {}
		Me.TRP_request_times[user.name][index] = GetTime()
	end
end

Me.DataProgressHandlers.TRPD1 = HandleDataProgress
Me.DataProgressHandlers.TRPD2 = HandleDataProgress
Me.DataProgressHandlers.TRPD3 = HandleDataProgress
Me.DataProgressHandlers.TRPD4 = HandleDataProgress

-------------------------------------------------------------------------------
-- Request profile data from someone. This reads from Me.TRP_needs_update[user]
--  to see what we want to get from them. It's also safe to spam (from
--  mouseover and such) as it has a cooldown.
--
function Me.TRP_RequestProfile( name, parts )

	if TRP3_API then
		if not TRP3_API.register.isUnitIDKnown( name ) then return end
		if not TRP3_API.register.getUnitIDCurrentProfile( name ) then return end
	elseif Me.TRP_imp then
		if not Me.TRP_imp.IsPlayerKnown( name ) then return end
	else
		return
	end
	
--	if Me.TRP_request_times[name]
 --          and GetTime() - Me.TRP_request_times[name] < REQUEST_COOLDOWN then
--	--	return
	--end

	Me.TRP_request_times[name] = Me.TRP_request_times[name] or {}
	local rqt = Me.TRP_request_times[name]
	
	local data = ""
	local send = false
	
	for i = 1, 4 do
		if not parts[i] then
			data = data .. "0"
		elseif rqt[i] and GetTime() - rqt[i] < REQUEST_COOLDOWN then
			data = data .. "0"
		elseif Me.TRP_needs_update[name] and Me.TRP_needs_update[name][i] then
			rqt[i] = GetTime()
			data = data .. "1"
			send = true
		else
			data = data .. "0"
		end
		--data = data .. (Me.TRP_needs_update[name][i] and "1" or "0")
	end
	
	if send then
		Me.DebugLog( "Sending TR request to %s: %s", name, data )
		Me.SendPacket( "TR", name .. ":" .. data )
	end
end

-------------------------------------------------------------------------------
function Me.TRP_TryRequest( username, ... )
	if not Me.connected or not Me.relay_on then return end
	if not username then return end
	
	if not TRP_accept_profile[username] then return end
	local islocal = Me.IsLocal( username )
	if islocal == nil or islocal == true then return end
	
	local parts = {}
	for k, v in pairs( {...} ) do
		parts[v] = true
	end
	
	Me.TRP_RequestProfile( username, parts )
end

-------------------------------------------------------------------------------
-- When we interact with people through mouseover, targeting, or opening their
--  profile, we request different parts of their profile. TRP_needs_update
--                               erases its entries after we receive the data.
function Me.OnMouseoverUnit()
	local username = Me.GetFullName( "mouseover" )
	Me.TRP_TryRequest( username, UPDATE_CHAR, UPDATE_CHS )
end

function Me.OnTargetChanged()
	local username = Me.GetFullName( "target" )
	Me.TRP_TryRequest( username, UPDATE_CHAR, UPDATE_CHS, UPDATE_MISC )
end

-------------------------------------------------------------------------------
-- This is part of the implementation's end, and needs to be called whenever
--  the user opens up someone's profile, so we can start transferring
--                                             description data.
function Me.TRP_OnProfileOpened( username )
	if username == Me.fullname then return end
	Me.TRP_TryRequest( username, UPDATE_CHAR, UPDATE_CHS, 
	                                                UPDATE_MISC, UPDATE_ABOUT )
end

-------------------------------------------------------------------------------
-- Called by the implementation whenever the user's profile changes, so we can
--  send vernums out. This can safely be spammed, as it uses a push timer
--  internally. It'll only trigger when the user stops editing for a number of
--                                                                     seconds.
function Me.TRP_OnProfileChanged()
	if Me.connected and Me.relay_on then
		Me.Timer_Start( "trp_vernums", "push", 
					   VERNUM_UPDATE_DELAY, Me.TRP_SendVernum )
	end
end

-------------------------------------------------------------------------------
-- Called after we connect to the relay stream.
--
function Me.TRP_OnConnected()
--	if not TRP3_API then return end
	if not Me.relay_on then return end
	
	-- We don't do delay here so we can fit this message in with HENLO.
	Me.TRP_SendVernum()
end

-------------------------------------------------------------------------------
function Me.TRP_Init()
	
	Me:RegisterEvent( "UPDATE_MOUSEOVER_UNIT", Me.OnMouseoverUnit )
	Me:RegisterEvent( "PLAYER_TARGET_CHANGED", Me.OnTargetChanged )
	
	if TRP3_API then
		EXCHANGE_DATA_FUNCS = {
			function()
				local data = TRP3_API.profile.getData( "player/characteristics" )
				
				-- We moved the addon version into the B table. This is
				--  unversioned, but this is also static information.
				data.VA = TRP3_API.globals.addon_name .. ";" 
				          .. TRP3_API.globals.version_display .. ";" 
						  .. (TRP3_API.globals.isTrialAccount and "1" or "0")
			
				return data
			end;
			
			function()
				local data = TRP3_API.register.player.getAboutExchangeData()
				if type(data) == "string" then
					-- I'm not proud of this.
					data = TRP3_API.utils.serial.safeDecompressCodedStructure(data, {});
				end
				return data;
			end;
			
			function()
				local data = TRP3_API.register.player.getMiscExchangeData()
				if type(data) == "string" then
					data = TRP3_API.utils.serial.safeDecompressCodedStructure(data, {});
				end
				return data
			end;
			
			function()
				return TRP3_API.profile.getData( "player/character" )
			end;
			
		-- We don't use the getExchangeData functions directly, because we
		--  don't want compression, for portability.
		--	TRP3_API.register.player.getCharacteristicsExchangeData;
		--	TRP3_API.register.player.getAboutExchangeData;
		--	TRP3_API.register.player.getMiscExchangeData;
		--	TRP3_API.dashboard.getCharacterExchangeData;
		}
		
		INFO_TYPES = {
			TRP3_API.register.registerInfoTypes.CHARACTERISTICS;
			TRP3_API.register.registerInfoTypes.ABOUT;
			TRP3_API.register.registerInfoTypes.MISC;
			TRP3_API.register.registerInfoTypes.CHARACTER;
		}
		
		TRP3_API.Events.registerCallback( TRP3_API.Events.REGISTER_DATA_UPDATED, 
			function( player_id, profileID )
				if player_id == TRP3_API.globals.player_id then
				
					Me.TRP_OnProfileChanged()
				end
			end)
			
		TRP3_API.Events.registerCallback( TRP3_API.Events.REGISTER_PROFILE_OPENED,
			function( context )
				if context.source == "directory" then
				
					local profile_id  = context.profileID
					local unit_id     = context.unitID
					local has_unit_id = context.openedWithUnitID
					
					if has_unit_id then
						-- Definitely have a unit ID
						Me.TRP_OnProfileOpened( unit_id )
						return
					elseif unit_id then
						-- Maybe have a unit ID, double check with our registry.
						if Me.crossrp_users[unit_id] then
							Me.TRP_OnProfileOpened( unit_id )
							return
						end
					end
					
					local profile = TRP3_API.register.getProfile(profile_id)
					local best_match, best_time = nil, 900
					for k,v in pairs( profile.link or {} ) do
						if Me.crossrp_users[k] 
						          and Me.crossrp_users[k].time < best_time then
							-- We saw this character using cross RP, but they 
							--  might have switched characters while using the
							--  same profile, so we'll still search to see if
							--  there's a shorter idle time in here.
							best_match = k
							best_time  = Me.crossrp_users[k].time
						end
					end
					
					if best_match then
						Me.TRP_OnProfileOpened( best_match )
					end
				end
				Me.DebugLog2( "REGISTER_PROFILE_OPENED", context.unitID )
			end)
	else
		Me.TRP_imp.Init()
	end
end
