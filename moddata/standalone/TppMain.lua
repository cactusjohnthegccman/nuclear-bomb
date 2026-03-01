-- =============================================================================
-- NuclearBomb.lua
-- NUCLEAR BOMB mod - Judge Authority System
-- Fork of MGSV Dynamite co-op mod
--
-- Manages dynamic authority (Judge) assignment between Host and Guest to
-- prevent split-brain desync on AI, vehicles, and world interactions.
-- =============================================================================

NuclearBomb = NuclearBomb or {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

NuclearBomb.PLAYER_HOST  = 0
NuclearBomb.PLAYER_GUEST = 1

-- Judge states
NuclearBomb.JUDGE_HOST    = "HOST"
NuclearBomb.JUDGE_GUEST   = "GUEST"
NuclearBomb.JUDGE_PENDING = "PENDING"  -- transitional: neither side is authoritative yet

-- Network message IDs (matched on both sides via OnMessage)
NuclearBomb.MSG_SYNC_JUDGE          = Tpp.StrCode32("NB_SYNC_JUDGE")
NuclearBomb.MSG_REQ_FULTON          = Tpp.StrCode32("NB_REQ_FULTON")
NuclearBomb.MSG_ACK_JUDGE           = Tpp.StrCode32("NB_ACK_JUDGE")

-- How many frames to stay in PENDING before forcing a fallback to HOST authority
NuclearBomb.PENDING_TIMEOUT_FRAMES  = 10

-- ---------------------------------------------------------------------------
-- Global Registry
-- _G.NuclearJudge  : current authority state ("HOST" | "GUEST" | "PENDING")
-- _G.NuclearPlayers: table tracking per-player position + vehicle state
-- ---------------------------------------------------------------------------

_G.NuclearJudge = _G.NuclearJudge or NuclearBomb.JUDGE_HOST

_G.NuclearPlayers = _G.NuclearPlayers or {
    [0] = { pos = { x = 0, y = 0, z = 0 }, inVehicle = false, isDriver = false },
    [1] = { pos = { x = 0, y = 0, z = 0 }, inVehicle = false, isDriver = false },
}

-- Internal frame counter for PENDING timeout
local _pendingFrames = 0

-- ---------------------------------------------------------------------------
-- Core Authority Query
-- ---------------------------------------------------------------------------

--- Returns true if the local machine is the current Judge (authoritative peer).
--- Wrap all physics/AI calls in: if NuclearBomb.IsJudge() then ... end
function NuclearBomb.IsJudge()
    local localRole = Dynamite.IsHost() and NuclearBomb.JUDGE_HOST or NuclearBomb.JUDGE_GUEST
    -- During PENDING, nobody is judge - prevents split-brain in handoff window
    if _G.NuclearJudge == NuclearBomb.JUDGE_PENDING then
        return false
    end
    return _G.NuclearJudge == localRole
end

--- Returns true if the local machine is the Host player (Player 0).
function NuclearBomb.IsHost()
    return Dynamite.IsHost()
end

--- Returns true if the local machine is the Guest player (Player 1).
function NuclearBomb.IsGuest()
    return Dynamite.IsClient()
end

--- Returns the current Judge state string (for UI/debug).
function NuclearBomb.GetJudgeState()
    return _G.NuclearJudge
end

-- ---------------------------------------------------------------------------
-- Authority Transfer
-- ---------------------------------------------------------------------------

--- Initiates an authority swap to the target role.
--- @param newJudge  string  NuclearBomb.JUDGE_HOST or NuclearBomb.JUDGE_GUEST
--- @param broadcast boolean  If true (Host only), broadcast SYNC_JUDGE to Guest
local function _SetJudge(newJudge, broadcast)
    if _G.NuclearJudge == newJudge then
        return  -- no-op
    end

    _G.NuclearJudge = NuclearBomb.JUDGE_PENDING
    _pendingFrames  = 0

    -- Defer actual assignment by one frame so both sides have a gap
    -- The Update() tick will resolve PENDING -> newJudge after the ack cycle
    _G._NuclearJudge_pendingTarget = newJudge

    if broadcast and NuclearBomb.IsHost() then
        NuclearBomb.BroadcastJudgeSync(newJudge)
    end
end

--- Called by Update() to resolve the PENDING state after the ack timeout.
local function _TickPending()
    if _G.NuclearJudge ~= NuclearBomb.JUDGE_PENDING then
        return
    end

    _pendingFrames = _pendingFrames + 1

    if _pendingFrames >= NuclearBomb.PENDING_TIMEOUT_FRAMES then
        local target = _G._NuclearJudge_pendingTarget or NuclearBomb.JUDGE_HOST
        _G.NuclearJudge = target
        _G._NuclearJudge_pendingTarget = nil
        _pendingFrames = 0

        -- Announce result
        local label = (target == NuclearBomb.JUDGE_GUEST) and "AUTHORITY: CLIENT ACTIVE" or "AUTHORITY: HOST ACTIVE"
        TppUiCommand.AnnounceLogView(label)
    end
end

-- ---------------------------------------------------------------------------
-- Vehicle-Based Authority Detection
-- ---------------------------------------------------------------------------

--- Checks whether Player 1 (Guest) is currently in the driver seat of any vehicle.
--- If so, authority should transfer to the Guest so they own vehicle physics.
function NuclearBomb.CheckVehicleAuthority()
    local guestVehicleId = vars.playerVehicleGameObjectId and vars.playerVehicleGameObjectId[NuclearBomb.PLAYER_GUEST]
    local hostVehicleId  = vars.playerVehicleGameObjectId and vars.playerVehicleGameObjectId[NuclearBomb.PLAYER_HOST]

    local guestDriving = guestVehicleId ~= nil and guestVehicleId ~= GameObject.NULL_ID
    local hostDriving  = hostVehicleId  ~= nil and hostVehicleId  ~= GameObject.NULL_ID

    -- Update player state table
    _G.NuclearPlayers[NuclearBomb.PLAYER_GUEST].isDriver = guestDriving
    _G.NuclearPlayers[NuclearBomb.PLAYER_HOST].isDriver  = hostDriving

    if guestDriving and _G.NuclearJudge ~= NuclearBomb.JUDGE_GUEST then
        -- Guest is now driving: transfer authority to them
        _SetJudge(NuclearBomb.JUDGE_GUEST, true)
    elseif not guestDriving and _G.NuclearJudge == NuclearBomb.JUDGE_GUEST then
        -- Guest stepped out: return authority to Host
        _SetJudge(NuclearBomb.JUDGE_HOST, true)
    end
end

-- ---------------------------------------------------------------------------
-- Player Position Sync
-- ---------------------------------------------------------------------------

--- Updates _G.NuclearPlayers position cache using Dynamite.GetPlayerPosition().
function NuclearBomb.SyncPlayerPositions()
    for i = 0, 1 do
        local pos = Dynamite.GetPlayerPosition(i)
        if pos then
            _G.NuclearPlayers[i].pos = pos
        end
    end
end

-- ---------------------------------------------------------------------------
-- Network: Outbound
-- ---------------------------------------------------------------------------

--- Host broadcasts the new judge state to the Guest.
--- The Guest's OnMessage handler updates _G.NuclearJudge accordingly.
function NuclearBomb.BroadcastJudgeSync(judgeState)
    if not NuclearBomb.IsHost() then return end
    -- Encode JUDGE_GUEST as 1, JUDGE_HOST as 0 in the message arg
    local val = (judgeState == NuclearBomb.JUDGE_GUEST) and 1 or 0
    GameObject.SendMessage(
        { type = "TppPlayer" },
        { id = NuclearBomb.MSG_SYNC_JUDGE, judgeIsGuest = val }
    )
end

--- Guest sends a Fulton extraction request to the Host for authoritative execution.
--- @param containerGameObjectId  number  The game object ID of the container to fulton
function NuclearBomb.RequestFultonContainer(containerGameObjectId)
    if not NuclearBomb.IsGuest() then return end
    GameObject.SendMessage(
        { type = "TppPlayer" },
        { id = NuclearBomb.MSG_REQ_FULTON, gameObjectId = containerGameObjectId }
    )
    TppUiCommand.AnnounceLogView("FULTON: REQUEST SENT TO HOST")
end

-- ---------------------------------------------------------------------------
-- Network: Inbound message handlers
-- ---------------------------------------------------------------------------

--- Call this from TppMain.OnMessage to handle NuclearBomb network packets.
--- @param msgId   number   Tpp.StrCode32 of the message
--- @param args    table    Message arguments table
function NuclearBomb.OnMessage(msgId, args)
    if msgId == NuclearBomb.MSG_SYNC_JUDGE then
        NuclearBomb._HandleSyncJudge(args)

    elseif msgId == NuclearBomb.MSG_REQ_FULTON then
        NuclearBomb._HandleReqFulton(args)
    end
end

--- Guest receives SYNC_JUDGE from Host and updates local authority.
function NuclearBomb._HandleSyncJudge(args)
    if NuclearBomb.IsHost() then return end  -- Host never needs to handle this

    local newJudge = (args.judgeIsGuest == 1) and NuclearBomb.JUDGE_GUEST or NuclearBomb.JUDGE_HOST
    _G.NuclearJudge = newJudge

    local label = (newJudge == NuclearBomb.JUDGE_GUEST) and "AUTHORITY: CLIENT ACTIVE" or "AUTHORITY: HOST ACTIVE"
    TppUiCommand.AnnounceLogView(label)
end

--- Host receives REQ_FULTON from Guest and executes the extraction authoritatively.
function NuclearBomb._HandleReqFulton(args)
    if not NuclearBomb.IsHost() then return end

    local gameObjectId = args.gameObjectId
    if not gameObjectId or gameObjectId == GameObject.NULL_ID then
        return
    end

    -- Execute the fulton extraction on the Host side
    -- This ensures physics + save-data update happen from one authoritative source
    GameObject.SendCommand(
        gameObjectId,
        { id = "RequestFulton" }
    )

    TppUiCommand.AnnounceLogView("FULTON: EXECUTING (HOST AUTHORITY)")
end

-- ---------------------------------------------------------------------------
-- Debug / Manual Override
-- ---------------------------------------------------------------------------

--- Manual authority override for testing the handshake during development.
--- Bind to a button combination (e.g. RELOAD) in TppMain.OnUpdate.
function NuclearBomb.DebugToggleAuthority()
    if _G.NuclearJudge == NuclearBomb.JUDGE_PENDING then
        TppUiCommand.AnnounceLogView("AUTHORITY: PENDING (wait...)")
        return
    end

    if _G.NuclearJudge == NuclearBomb.JUDGE_HOST then
        _SetJudge(NuclearBomb.JUDGE_GUEST, true)
        TppUiCommand.AnnounceLogView("AUTHORITY: MANUAL -> CLIENT")
    else
        _SetJudge(NuclearBomb.JUDGE_HOST, true)
        TppUiCommand.AnnounceLogView("AUTHORITY: MANUAL -> HOST")
    end
end

-- ---------------------------------------------------------------------------
-- Update Tick (call from TppMain.OnUpdate every frame)
-- ---------------------------------------------------------------------------

function NuclearBomb.OnUpdate()
    _TickPending()
    NuclearBomb.SyncPlayerPositions()

    -- Only the Host evaluates vehicle conditions and broadcasts changes
    if NuclearBomb.IsHost() then
        NuclearBomb.CheckVehicleAuthority()
    end
end

-- ---------------------------------------------------------------------------
-- Init (call from TppMain.OnAllocate or mission init)
-- ---------------------------------------------------------------------------

function NuclearBomb.Init()
    _G.NuclearJudge  = NuclearBomb.JUDGE_HOST
    _pendingFrames   = 0
    _G._NuclearJudge_pendingTarget = nil

    _G.NuclearPlayers = {
        [0] = { pos = { x = 0, y = 0, z = 0 }, inVehicle = false, isDriver = false },
        [1] = { pos = { x = 0, y = 0, z = 0 }, inVehicle = false, isDriver = false },
    }

    TppUiCommand.AnnounceLogView("NUCLEAR BOMB: JUDGE SYSTEM INITIALIZED")
end
	local e = {}
local s = Tpp.ApendArray
local n = Tpp.DEBUG_StrCode32ToString
local t = Tpp.IsTypeFunc
local i = Tpp.IsTypeTable
local M = TppScriptVars.IsSavingOrLoading
local f = ScriptBlock.UpdateScriptsInScriptBlocks
local m = Mission.GetCurrentMessageResendCount
local a = {}
local p = 0
local c = {}
local o = 0
local T = {}
local u = 0
local n = {}
local n = 0
local d = {}
local h = {}
local r = 0
local S = {}
local P = {}
local l = 0
local function n()
	if QuarkSystem.GetCompilerState() == QuarkSystem.COMPILER_STATE_WAITING_TO_LOAD then
		QuarkSystem.PostRequestToLoad()
		coroutine.yield()
		while QuarkSystem.GetCompilerState() == QuarkSystem.COMPILER_STATE_WAITING_TO_LOAD do
			coroutine.yield()
		end
	end
end
function e.DisableGameStatus()
	TppMission.DisableInGameFlag()
	Tpp.SetGameStatus({ target = "all", enable = false, except = { S_DISABLE_NPC = false }, scriptName = "TppMain.lua" })
end
function e.DisableGameStatusOnGameOverMenu()
	TppMission.DisableInGameFlag()
	Tpp.SetGameStatus({ target = "all", enable = false, scriptName = "TppMain.lua" })
end
function e.EnableGameStatus()
	TppMission.EnableInGameFlag()
	Tpp.SetGameStatus({
		target = {
			S_DISABLE_PLAYER_PAD = true,
			S_DISABLE_TARGET = true,
			S_DISABLE_NPC = true,
			S_DISABLE_NPC_NOTICE = true,
			S_DISABLE_PLAYER_DAMAGE = true,
			S_DISABLE_THROWING = true,
			S_DISABLE_PLACEMENT = true,
		},
		enable = true,
		scriptName = "TppMain.lua",
	})
end
function e.EnableGameStatusForDemo()
	TppDemo.ReserveEnableInGameFlag()
	Tpp.SetGameStatus({
		target = {
			S_DISABLE_PLAYER_PAD = true,
			S_DISABLE_TARGET = true,
			S_DISABLE_NPC = true,
			S_DISABLE_NPC_NOTICE = true,
			S_DISABLE_PLAYER_DAMAGE = true,
			S_DISABLE_THROWING = true,
			S_DISABLE_PLACEMENT = true,
		},
		enable = true,
		scriptName = "TppMain.lua",
	})
end
function e.EnableAllGameStatus()
	TppMission.EnableInGameFlag()
	Tpp.SetGameStatus({ target = "all", enable = true, scriptName = "TppMain.lua" })
end
function e.EnablePlayerPad()
	TppGameStatus.Reset("TppMain.lua", "S_DISABLE_PLAYER_PAD")
end
function e.DisablePlayerPad()
	TppGameStatus.Set("TppMain.lua", "S_DISABLE_PLAYER_PAD")
end
function e.EnablePause()
	TppPause.RegisterPause("TppMain.lua")
end
function e.DisablePause()
	TppPause.UnregisterPause("TppMain.lua")
end
function e.EnableBlackLoading(e)
	TppGameStatus.Set("TppMain.lua", "S_IS_BLACK_LOADING")
	if e then
		TppUI.StartLoadingTips()
	end
end
function e.DisableBlackLoading()
	TppGameStatus.Reset("TppMain.lua", "S_IS_BLACK_LOADING")
	TppUI.FinishLoadingTips()
end

function e.IsCoop(missionCode)
	local coops = {
		10020, -- 1
		10036, -- 3
		10043, -- 4
		10033, -- 5
		10040, -- 6
		10041, -- 7
		10044, -- 8
		10054, -- 9
		10052, -- 10
		10050, -- 11
		10070, -- 12
		10080, -- 13
		10086, -- 14
		10082, -- 15
		10090, -- 16
		10091, -- 17
		10100, -- 18
		10195, -- 19
		10110, -- 20
		10121, -- 21
		10120, -- 23
		10085, -- 24
		10200, -- 25
		10211, -- 26
		10081, -- 27
		10130, -- 28
		10140, -- 29
		10150, -- 30
		10151, -- 31
		10045, -- 32
		10093, -- 35
		10156, -- 38
		10171, -- 41
		10240, -- 43
		10260, -- 45
		10280, -- 46
	}

	for _, value in pairs(coops) do
		if value == missionCode then
			return true
		end
	end

	return false
end

-- =============================================================================
-- NUCLEAR BOMB: Judge Authority System hooks
-- NuclearBomb.lua must be loaded before TppMain (via script_loader or require)
-- =============================================================================

function e.OnAllocate(n)
	-- If you are loading a mission from a checkpoint with already placed marker, game will attempt to restore
	-- that marker through tpp::ui::menu::UiDepend::ActUserMarkerSaveLoad function (not lua).
	-- Combined with co-op hacks, marker restoration will result in a hang.
	-- Markers can be also be loaded during initial game loading, breaking the process.
	-- Therefore, markers are accepted again at the end of TppMain.OnMissionCanStart for coop missions only.
    if e.IsCoop(vars.missionCode) then
        Dynamite.IgnoreMarkerRequests()
    end

	-- NUCLEAR BOMB: Initialize Judge Authority system at mission start
	if NuclearBomb then
		NuclearBomb.Init()
	end

	TppWeather.OnEndMissionPrepareFunction()
	e.DisableGameStatus()
	e.EnablePause()
	TppClock.Stop()
	a = {}
	p = 0
	T = {}
	u = 0
	TppUI.FadeOut(TppUI.FADE_SPEED.FADE_MOMENT, nil, nil)
	TppSave.WaitingAllEnqueuedSaveOnStartMission()
	if TppMission.IsFOBMission(vars.missionCode) then
		TppMission.SetFOBMissionFlag() -- crashes 10033
		TppGameStatus.Set("Mission", "S_IS_ONLINE")
	elseif e.IsCoop(vars.missionCode) then
		TppNetworkUtil.SetTimeOut(10);
		if Dynamite.IsHost() then
			Dynamite.CreateHostSession()
		else
			--do nothing, client connects manually after host has finished loading the mission and called TppNetworkUtil.SessionEnableAccept(true)
		end

		TppGameStatus.Set("Mission", "S_IS_ONLINE")
	else
		Dynamite.StopNearestEnemyThread()
		TppGameStatus.Reset("Mission", "S_IS_ONLINE")
		Dynamite.ResetClientSessionState();

		--TppNetworkUtil.SessionDisconnectPreparingMembers() --breaks fob if uncommented
		--TppNetworkUtil.CloseSession() -- breaks fob if uncommented
	end
	Mission.Start()
	TppMission.WaitFinishMissionEndPresentation()
	TppMission.DisableInGameFlag()
	TppException.OnAllocate(n)
	TppClock.OnAllocate(n)
	TppTrap.OnAllocate(n)
	TppCheckPoint.OnAllocate(n)
	TppUI.OnAllocate(n)
	TppDemo.OnAllocate(n)
	TppScriptBlock.OnAllocate(n)
	TppSound.OnAllocate(n)
	TppPlayer.OnAllocate(n)
	TppMission.OnAllocate(n)
	TppTerminal.OnAllocate(n)
	TppEnemy.OnAllocate(n)
	TppRadio.OnAllocate(n)
	TppGimmick.OnAllocate(n)
	TppMarker.OnAllocate(n)
	TppRevenge.OnAllocate(n)
	e.ClearStageBlockMessage()
	TppQuest.OnAllocate(n)
	TppAnimal.OnAllocate(n)
	local function o()
		if TppLocation.IsAfghan() then
			if afgh then
				afgh.OnAllocate()
			end
		elseif TppLocation.IsMiddleAfrica() then
			if mafr then
				mafr.OnAllocate()
			end
		elseif TppLocation.IsCyprus() then
			if cypr then
				cypr.OnAllocate()
			end
		elseif TppLocation.IsMotherBase() then
			if mtbs then
				mtbs.OnAllocate()
			end
		end
	end
	o()
	if n.sequence then
		if f30050_sequence then
			function f30050_sequence.NeedPlayQuietWishGoMission()
				local i = TppQuest.IsCleard("mtbs_q99011")
				local n = not TppDemo.IsPlayedMBEventDemo("QuietWishGoMission")
				local e = TppDemo.GetMBDemoName() == nil
				return (i and n) and e
			end
		end
		if t(n.sequence.MissionPrepare) then
			n.sequence.MissionPrepare()
		end
		if t(n.sequence.OnEndMissionPrepareSequence) then
			TppSequence.SetOnEndMissionPrepareFunction(n.sequence.OnEndMissionPrepareSequence)
		end
	end
	for n, e in pairs(n) do
		if t(e.OnLoad) then
			e.OnLoad()
		end
	end
	do
		local a = {}
		for i, e in ipairs(Tpp._requireList) do
			if _G[e] then
				if _G[e].DeclareSVars then
					s(a, _G[e].DeclareSVars(n))
				end
			end
		end
		local o = {}
		for n, e in pairs(n) do
			if t(e.DeclareSVars) then
				s(o, e.DeclareSVars())
			end
			if i(e.saveVarsList) then
				s(o, TppSequence.MakeSVarsTable(e.saveVarsList))
			end
		end
		if OnlineChallengeTask then
			s(o, OnlineChallengeTask.DeclareSVars())
		end
		s(a, o)
		TppScriptVars.DeclareSVars(a)
		TppScriptVars.SetSVarsNotificationEnabled(false)
		while M() do
			coroutine.yield()
		end
		TppRadioCommand.SetScriptDeclVars()
		local t = vars.mbLayoutCode
		if gvars.ini_isTitleMode then
			TppPlayer.MissionStartPlayerTypeSetting()
		else
			if TppMission.IsMissionStart() then
				TppVarInit.InitializeForNewMission(n)
				TppPlayer.MissionStartPlayerTypeSetting()
				if not TppMission.IsFOBMission(vars.missionCode) then
					TppSave.VarSave(vars.missionCode, true)
				end
			else
				TppVarInit.InitializeForContinue(n)
			end
			TppVarInit.ClearIsContinueFromTitle()
		end
		TppUiCommand.ExcludeNonPermissionContents()
		TppStory.SetMissionClearedS10030()
		if not TppMission.IsDefiniteMissionClear() then
			TppTerminal.StartSyncMbManagementOnMissionStart()
		end
		if TppLocation.IsMotherBase() then
			if t ~= vars.mbLayoutCode then
				if vars.missionCode == 30050 then
					vars.mbLayoutCode = t
				else
					vars.mbLayoutCode = TppLocation.ModifyMbsLayoutCode(TppMotherBaseManagement.GetMbsTopologyType())
				end
			end
		end
		TppPlayer.FailSafeInitialPositionForFreePlay()
		e.StageBlockCurrentPosition(true)
		TppMission.SetSortieBuddy()
		if vars.missionCode ~= 10260 then
			TppMission.ResetQuietEquipIfUndevelop()
		end
		TppStory.UpdateStorySequence({ updateTiming = "BeforeBuddyBlockLoad" })
		if n.sequence then
			local e = n.sequence.DISABLE_BUDDY_TYPE
			if e then
				local n
				if i(e) then
					n = e
				else
					n = { e }
				end
				for n, e in ipairs(n) do
					TppBuddyService.SetDisableBuddyType(e)
				end
			end
		end
		if (vars.missionCode == 11043) or (vars.missionCode == 11044) then
			TppBuddyService.SetDisableAllBuddy()
		end
		if TppGameSequence.GetGameTitleName() == "TPP" then
			if n.sequence and n.sequence.OnBuddyBlockLoad then
				n.sequence.OnBuddyBlockLoad()
			end
			if TppLocation.IsAfghan() or TppLocation.IsMiddleAfrica() then
				TppBuddy2BlockController.Load()
			end
		end
		TppSequence.SaveMissionStartSequence()
		TppScriptVars.SetSVarsNotificationEnabled(true)
	end
	if n.enemy then
		if i(n.enemy.soldierPowerSettings) then
			TppEnemy.SetUpPowerSettings(n.enemy.soldierPowerSettings)
		end
	end
	TppRevenge.DecideRevenge(n)
	if TppEquip.CreateEquipMissionBlockGroup then
		if vars.missionCode > 6e4 then
			TppEquip.CreateEquipMissionBlockGroup({ size = (380 * 1024) * 24 })
		else
			TppPlayer.SetEquipMissionBlockGroupSize()
		end
	end
	if TppEquip.CreateEquipGhostBlockGroups then
		if TppSystemUtility.GetCurrentGameMode() == "MGO" then
			TppEquip.CreateEquipGhostBlockGroups({ ghostCount = 16 })
		elseif TppMission.IsFOBMission(vars.missionCode) then
			TppEquip.CreateEquipGhostBlockGroups({ ghostCount = 1 })
		end
	end

	if e.IsCoop(vars.missionCode) then
		TppPlayer.SetEquipMissionBlockGroupSize()
		TppEquip.CreateEquipGhostBlockGroups({ ghostCount = 1 })
	end

	TppEquip.StartLoadingToEquipMissionBlock()
	TppPlayer.SetMaxPickableLocatorCount()
	TppPlayer.SetMaxPlacedLocatorCount()
	TppEquip.AllocInstances({ instance = 60, realize = 60 })
	TppEquip.ActivateEquipSystem()
	if TppEnemy.IsRequiredToLoadDefaultSoldier2CommonPackage() then
		TppEnemy.LoadSoldier2CommonBlock()
	end
	if n.sequence then
		mvars.mis_baseList = n.sequence.baseList
		TppCheckPoint.RegisterCheckPointList(n.sequence.checkPointList)
	end
	if not TppMission.IsFOBMission(vars.missionCode) and not e.IsCoop(vars.missionCode) then
		TppPlayer.ForceChangePlayerFromOcelot()
	end
end
function e.OnInitialize(n)
	if TppMission.IsFOBMission(vars.missionCode) then
		TppMission.SetFobPlayerStartPoint()
	elseif TppMission.IsNeedSetMissionStartPositionToClusterPosition() then
		TppMission.SetMissionStartPositionMtbsClusterPosition()
		e.StageBlockCurrentPosition(true)
	else
		TppCheckPoint.SetCheckPointPosition()
	end
	if TppEnemy.IsRequiredToLoadSpecialSolider2CommonBlock() then
		TppEnemy.LoadSoldier2CommonBlock()
	end
	if TppMission.IsMissionStart() then
		TppTrap.InitializeVariableTraps()
	else
		TppTrap.RestoreVariableTrapState()
	end
	TppAnimalBlock.InitializeBlockStatus()
	if TppQuestList then
		TppQuest.RegisterQuestList(TppQuestList.questList)
		TppQuest.RegisterQuestPackList(TppQuestList.questPackList)
	end
	TppHelicopter.AdjustBuddyDropPoint()
	if n.sequence then
		local e = n.sequence.NPC_ENTRY_POINT_SETTING
		if i(e) then
			TppEnemy.NPCEntryPointSetting(e)
		end
	end
	TppLandingZone.OverwriteBuddyVehiclePosForALZ()
	if n.enemy then
		if i(n.enemy.vehicleSettings) then
			TppEnemy.SetUpVehicles()
		end
		if t(n.enemy.SpawnVehicleOnInitialize) then
			n.enemy.SpawnVehicleOnInitialize()
		end
		TppReinforceBlock.SetUpReinforceBlock()
	end
	for i, e in pairs(n) do
		if t(e.Messages) then
			n[i]._messageExecTable = Tpp.MakeMessageExecTable(e.Messages())
		end
	end
	if mvars.loc_locationCommonTable then
		mvars.loc_locationCommonTable.OnInitialize()
	end
	TppLandingZone.OnInitialize()
	for i, e in ipairs(Tpp._requireList) do
		if _G[e].Init then
			_G[e].Init(n)
		end
	end
	if OnlineChallengeTask then
		OnlineChallengeTask.Init()
	end
	if n.enemy then
		if GameObject.DoesGameObjectExistWithTypeName("TppSoldier2") then
			GameObject.SendCommand({ type = "TppSoldier2" }, { id = "CreateFaceIdList" })
		end
		if i(n.enemy.soldierDefine) then
			TppEnemy.DefineSoldiers(n.enemy.soldierDefine)
		end
		if n.enemy.InitEnemy and t(n.enemy.InitEnemy) then
			n.enemy.InitEnemy()
		end
		if i(n.enemy.soldierPersonalAbilitySettings) then
			TppEnemy.SetUpPersonalAbilitySettings(n.enemy.soldierPersonalAbilitySettings)
		end
		if i(n.enemy.travelPlans) then
			TppEnemy.SetTravelPlans(n.enemy.travelPlans)
		end
		TppEnemy.SetUpSoldiers()
		if i(n.enemy.soldierDefine) then
			TppEnemy.InitCpGroups()
			TppEnemy.RegistCpGroups(n.enemy.cpGroups)
			TppEnemy.SetCpGroups()
			if mvars.loc_locationGimmickCpConnectTable then
				TppGimmick.SetCommunicateGimmick(mvars.loc_locationGimmickCpConnectTable)
			end
		end
		if i(n.enemy.interrogation) then
			TppInterrogation.InitInterrogation(n.enemy.interrogation)
		end
		if i(n.enemy.useGeneInter) then
			TppInterrogation.AddGeneInter(n.enemy.useGeneInter)
		end
		if i(n.enemy.uniqueInterrogation) then
			TppInterrogation.InitUniqueInterrogation(n.enemy.uniqueInterrogation)
		end
		do
			local e
			if i(n.enemy.routeSets) then
				e = n.enemy.routeSets
				for e, n in pairs(e) do
					if not i(mvars.ene_soldierDefine[e]) then
					end
				end
			end
			if e then
				TppEnemy.RegisterRouteSet(e)
				TppEnemy.MakeShiftChangeTable()
				TppEnemy.SetUpCommandPost()
				TppEnemy.SetUpSwitchRouteFunc()
			end
		end
		if n.enemy.soldierSubTypes then
			TppEnemy.SetUpSoldierSubTypes(n.enemy.soldierSubTypes)
		end
		TppRevenge.SetUpEnemy()
		TppEnemy.ApplyPowerSettingsOnInitialize()
		TppEnemy.ApplyPersonalAbilitySettingsOnInitialize()
		TppEnemy.SetOccasionalChatList()
		TppEneFova.ApplyUniqueSetting()
		if n.enemy.SetUpEnemy and t(n.enemy.SetUpEnemy) then
			n.enemy.SetUpEnemy()
		end
		if TppMission.IsMissionStart() then
			TppEnemy.RestoreOnMissionStart2()
		else
			TppEnemy.RestoreOnContinueFromCheckPoint2()
		end
	end
	if not TppMission.IsMissionStart() then
		TppWeather.RestoreFromSVars()
		if not e.IsCoop(vars.missionCode) then
			TppMarker.RestoreMarkerLocator()
		end
	end
	TppPlayer.RestoreSupplyCbox()
	TppPlayer.RestoreSupportAttack()
	TppTerminal.MakeMessage()
	if n.sequence then
		local e = n.sequence.SetUpRoutes
		if e and t(e) then
			e()
		end
		TppEnemy.RegisterRouteAnimation()
		local e = n.sequence.SetUpLocation
		if e and t(e) then
			e()
		end
	end
	for n, e in pairs(n) do
		if e.OnRestoreSVars then
			e.OnRestoreSVars()
		end
	end
	--TppMission.RestoreShowMissionObjective()
	TppRevenge.SetUpRevengeMine()
	if TppPickable.StartToCreateFromLocators then
		TppPickable.StartToCreateFromLocators()
	end
	if TppPlaced and TppPlaced.StartToCreateFromLocators then
		TppPlaced.StartToCreateFromLocators()
	end
	if TppMission.IsMissionStart() then
		TppRadioCommand.RestoreRadioState()
	else
		TppRadioCommand.RestoreRadioStateContinueFromCheckpoint()
	end
	TppMission.SetPlayRecordClearInfo()
	TppChallengeTask.RequestUpdateAllChecker()
	TppMission.PostMissionOrderBoxPositionToBuddyDog()
	e.SetUpdateFunction(n)
	e.SetMessageFunction(n)
	TppQuest.UpdateActiveQuest()
	TppDevelopFile.OnMissionCanStart()
	if TppMission.GetMissionID() == 30010 or TppMission.GetMissionID() == 30020 then
		if TppQuest.IsActiveQuestHeli() then
			TppEnemy.ReserveQuestHeli()
		end
	end
	TppDemo.UpdateNuclearAbolitionFlag()
	TppQuest.AcquireKeyItemOnMissionStart()
end
function e.SetUpdateFunction(e)
	a = {}
	p = 0
	c = {}
	o = 0
	T = {}
	u = 0
	a = {
		TppMission.Update,
		TppSequence.Update,
		TppSave.Update,
		TppDemo.Update,
		TppPlayer.Update,
		TppMission.UpdateForMissionLoad,
		script_loader.Update,
	}
	p = #a
	for n, e in pairs(e) do
		if t(e.OnUpdate) then
			o = o + 1
			c[o] = e.OnUpdate
		end
	end
end
function e.OnEnterMissionPrepare()
	if TppMission.IsMissionStart() then
		TppScriptBlock.PreloadSettingOnMissionStart()
	end
	TppScriptBlock.ReloadScriptBlock()
end
function e.OnTextureLoadingWaitStart()
	if not TppMission.IsHelicopterSpace(vars.missionCode) then
		StageBlockCurrentPositionSetter.SetEnable(false)
	end
	gvars.canExceptionHandling = true
end
function e.OnMissionStartSaving() end
function e.OnMissionCanStart()
	if TppMission.IsMissionStart() then
		TppWeather.SetDefaultWeatherProbabilities()
		TppWeather.SetDefaultWeatherDurations()
		if (not gvars.ini_isTitleMode) and (not TppMission.IsFOBMission(vars.missionCode)) then
			TppSave.VarSave(nil, true)
		end
	end
	TppLocation.ActivateBlock()
	TppWeather.OnMissionCanStart()
	TppMarker.OnMissionCanStart()
	TppResult.OnMissionCanStart()
	TppQuest.InitializeQuestLoad()
	TppRatBird.OnMissionCanStart()
	TppMission.OnMissionStart()
	if mvars.loc_locationCommonTable then
		mvars.loc_locationCommonTable.OnMissionCanStart()
	end
	TppLandingZone.OnMissionCanStart()
	TppOutOfMissionRangeEffect.Disable(0)
	if TppLocation.IsMiddleAfrica() then
		TppGimmick.MafrRiverPrimSetting()
	end
	if MotherBaseConstructConnector.RefreshGimmicks then
		if vars.locationCode == TppDefine.LOCATION_ID.MTBS then
			MotherBaseConstructConnector.RefreshGimmicks()
		end
	end
	if vars.missionCode == 10240 and TppLocation.IsMBQF() then
		Player.AttachGasMask()
	end
	if vars.missionCode == 10150 then
		local e = TppSequence.GetMissionStartSequenceIndex()
		if (e ~= nil) and (e < TppSequence.GetSequenceIndex("Seq_Game_SkullFaceToPlant")) then
			if svars.mis_objectiveEnable[17] == false then
				Gimmick.ForceResetOfRadioCassetteWithCassette()
			end
		end
	end

	if e.IsCoop(vars.missionCode) then
		Dynamite.AcceptMarkerRequests()
	end
end
function e.OnMissionGameStart(n)
	TppClock.Start()
	if not gvars.ini_isTitleMode then
		PlayRecord.RegistPlayRecord("MISSION_START")
	end
	TppQuest.InitializeQuestActiveStatus()
	if mvars.seq_demoSequneceList[mvars.seq_missionStartSequence] then
		e.EnableGameStatusForDemo()
	else
		e.EnableGameStatus()
	end
	if Player.RequestChickenHeadSound ~= nil then
		Player.RequestChickenHeadSound()
	end
	TppTerminal.OnMissionGameStart()
	if TppSequence.IsLandContinue() then
		TppMission.EnableAlertOutOfMissionAreaIfAlertAreaStart()
	end
	TppSoundDaemon.ResetMute("Telop")
end
function e.ClearStageBlockMessage()
	StageBlock.ClearLargeBlockNameForMessage()
	StageBlock.ClearSmallBlockIndexForMessage()
end
function e.ReservePlayerLoadingPosition(n, s, o, t, i, p, a)
	e.DisableGameStatus()
	if n == TppDefine.MISSION_LOAD_TYPE.MISSION_FINALIZE then
		if t then
			TppHelicopter.ResetMissionStartHelicopterRoute()
			TppPlayer.ResetInitialPosition()
			TppPlayer.ResetMissionStartPosition()
			TppPlayer.ResetNoOrderBoxMissionStartPosition()
			TppMission.ResetIsStartFromHelispace()
			TppMission.ResetIsStartFromFreePlay()
		elseif s then
			if gvars.heli_missionStartRoute ~= 0 then
				TppPlayer.SetStartStatusRideOnHelicopter()
				if mvars.mis_helicopterMissionStartPosition then
					TppPlayer.SetInitialPosition(mvars.mis_helicopterMissionStartPosition, 0)
					TppPlayer.SetMissionStartPosition(mvars.mis_helicopterMissionStartPosition, 0)
				end
			else
				TppPlayer.SetStartStatus(TppDefine.INITIAL_PLAYER_STATE.ON_FOOT)
				local e = TppDefine.NO_HELICOPTER_MISSION_START_POSITION[vars.missionCode]
				if e then
					TppPlayer.SetInitialPosition(e, 0)
					TppPlayer.SetMissionStartPosition(e, 0)
				else
					TppPlayer.ResetInitialPosition()
					TppPlayer.ResetMissionStartPosition()
				end
			end
			TppPlayer.ResetNoOrderBoxMissionStartPosition()
			TppMission.SetIsStartFromHelispace()
			TppMission.ResetIsStartFromFreePlay()
		elseif i then
			if TppLocation.IsMotherBase() then
				TppPlayer.SetStartStatusRideOnHelicopter()
			else
				TppPlayer.ResetInitialPosition()
				TppHelicopter.ResetMissionStartHelicopterRoute()
				TppPlayer.SetStartStatus(TppDefine.INITIAL_PLAYER_STATE.ON_FOOT)
				TppPlayer.SetMissionStartPositionToCurrentPosition()
			end
			TppPlayer.ResetNoOrderBoxMissionStartPosition()
			TppMission.ResetIsStartFromHelispace()
			TppMission.ResetIsStartFromFreePlay()
			TppLocation.MbFreeSpecialMissionStartSetting(TppMission.GetMissionClearType())
		elseif o and TppLocation.IsMotherBase() then
			if gvars.heli_missionStartRoute ~= 0 then
				TppPlayer.SetStartStatusRideOnHelicopter()
			else
				TppPlayer.ResetInitialPosition()
				TppPlayer.ResetMissionStartPosition()
			end
			TppPlayer.ResetNoOrderBoxMissionStartPosition()
			TppMission.SetIsStartFromHelispace()
			TppMission.ResetIsStartFromFreePlay()
		else
			if o then
				if mvars.mis_orderBoxName then
					TppMission.SetMissionOrderBoxPosition()
					TppPlayer.ResetNoOrderBoxMissionStartPosition()
				else
					TppPlayer.ResetInitialPosition()
					TppPlayer.ResetMissionStartPosition()
					local e = {
						[10020] = { 1449.3460693359, 339.18698120117, 1467.4300537109, -104 },
						[10050] = { -1820.7060546875, 349.78659057617, -146.44400024414, 139 },
						[10070] = { -792.00512695313, 537.3740234375, -1381.4598388672, 136 },
						[10080] = { -439.28802490234, -20.472593307495, 1336.2784423828, -151 },
						[10140] = { 499.91635131836, 13.07358455658, 1135.1315917969, 79 },
						[10150] = { -1732.0286865234, 543.94067382813, -2225.7587890625, 162 },
						[10260] = { -1260.0454101563, 298.75305175781, 1325.6383056641, 51 },
					}
					e[11050] = e[10050]
					e[11080] = e[10080]
					e[11140] = e[10140]
					e[10151] = e[10150]
					e[11151] = e[10150]
					local e = e[vars.missionCode]
					if TppDefine.NO_ORDER_BOX_MISSION_ENUM[tostring(vars.missionCode)] and e then
						TppPlayer.SetNoOrderBoxMissionStartPosition(e, e[4])
					else
						TppPlayer.ResetNoOrderBoxMissionStartPosition()
					end
				end
				local e = TppDefine.NO_ORDER_FIX_HELICOPTER_ROUTE[vars.missionCode]
				if e then
					TppPlayer.SetStartStatusRideOnHelicopter()
					TppMission.SetIsStartFromHelispace()
					TppMission.ResetIsStartFromFreePlay()
				else
					TppPlayer.SetStartStatus(TppDefine.INITIAL_PLAYER_STATE.ON_FOOT)
					TppHelicopter.ResetMissionStartHelicopterRoute()
					TppMission.ResetIsStartFromHelispace()
					TppMission.SetIsStartFromFreePlay()
				end
				local e = TppMission.GetMissionClearType()
				TppQuest.SpecialMissionStartSetting(e)
			else
				TppPlayer.ResetInitialPosition()
				TppPlayer.ResetMissionStartPosition()
				TppPlayer.ResetNoOrderBoxMissionStartPosition()
				TppMission.ResetIsStartFromHelispace()
				TppMission.ResetIsStartFromFreePlay()
			end
		end
	elseif n == TppDefine.MISSION_LOAD_TYPE.MISSION_ABORT then
		TppPlayer.ResetInitialPosition()
		TppHelicopter.ResetMissionStartHelicopterRoute()
		TppMission.ResetIsStartFromHelispace()
		TppMission.ResetIsStartFromFreePlay()
		if p then
			if i then
				TppPlayer.SetStartStatus(TppDefine.INITIAL_PLAYER_STATE.ON_FOOT)
				TppHelicopter.ResetMissionStartHelicopterRoute()
				TppPlayer.SetMissionStartPositionToCurrentPosition()
				TppPlayer.ResetNoOrderBoxMissionStartPosition()
			elseif t then
				TppPlayer.ResetMissionStartPosition()
			elseif vars.missionCode ~= 5 then
			end
		else
			if t then
				TppHelicopter.ResetMissionStartHelicopterRoute()
				TppPlayer.ResetInitialPosition()
				TppPlayer.ResetMissionStartPosition()
			elseif i then
				TppMission.SetMissionOrderBoxPosition()
			elseif vars.missionCode ~= 5 then
			end
		end
	elseif n == TppDefine.MISSION_LOAD_TYPE.MISSION_RESTART then
	elseif n == TppDefine.MISSION_LOAD_TYPE.CONTINUE_FROM_CHECK_POINT then
	end
	if s and a then
		Mission.AddLocationFinalizer(function()
			e.StageBlockCurrentPosition()
		end)
	else
		e.StageBlockCurrentPosition()
	end
end
function e.StageBlockCurrentPosition(e)
	if vars.initialPlayerFlag == PlayerFlag.USE_VARS_FOR_INITIAL_POS then
		StageBlockCurrentPositionSetter.SetEnable(true)
		StageBlockCurrentPositionSetter.SetPosition(vars.initialPlayerPosX, vars.initialPlayerPosZ)
	else
		StageBlockCurrentPositionSetter.SetEnable(false)
	end
	if TppMission.IsHelicopterSpace(vars.missionCode) then
		StageBlockCurrentPositionSetter.SetEnable(true)
		StageBlockCurrentPositionSetter.DisablePosition()
		if e then
			while not StageBlock.LargeAndSmallBlocksAreEmpty() do
				coroutine.yield()
			end
		end
	end
end
function e.OnReload(n)
	for i, e in pairs(n) do
		if t(e.OnLoad) then
			e.OnLoad()
		end
		if t(e.Messages) then
			n[i]._messageExecTable = Tpp.MakeMessageExecTable(e.Messages())
		end
	end
	if OnlineChallengeTask then
		OnlineChallengeTask.OnReload()
	end
	if n.enemy then
		if i(n.enemy.routeSets) then
			TppClock.UnregisterClockMessage("ShiftChangeAtNight")
			TppClock.UnregisterClockMessage("ShiftChangeAtMorning")
			TppEnemy.RegisterRouteSet(n.enemy.routeSets)
			TppEnemy.MakeShiftChangeTable()
		end
	end
	for i, e in ipairs(Tpp._requireList) do
		if _G[e].OnReload then
			_G[e].OnReload(n)
		end
	end
	if mvars.loc_locationCommonTable then
		mvars.loc_locationCommonTable.OnReload()
	end
	if n.sequence then
		TppCheckPoint.RegisterCheckPointList(n.sequence.checkPointList)
	end
	e.SetUpdateFunction(n)
	e.SetMessageFunction(n)
end
function e.OnUpdate(e)
	local e
	local i = a
	local n = c
	local e = T
	for e = 1, p do
		i[e]()
	end
	for e = 1, o do
		n[e]()
	end
	f()

	-- NUCLEAR BOMB: Tick the Judge system every frame
	if NuclearBomb then
		NuclearBomb.OnUpdate()

		-- Debug override: manual authority toggle via RELOAD button
		if TppInput and TppInput.IsButtonPush and TppInput.IsButtonPush("RELOAD") then
			NuclearBomb.DebugToggleAuthority()
		end
	end
end
function e.OnChangeSVars(e, i, n)
	for t, e in ipairs(Tpp._requireList) do
		if _G[e].OnChangeSVars then
			_G[e].OnChangeSVars(i, n)
		end
	end
end
function e.SetMessageFunction(e)
	d = {}
	r = 0
	S = {}
	l = 0
	for n, e in ipairs(Tpp._requireList) do
		if _G[e].OnMessage then
			r = r + 1
			d[r] = _G[e].OnMessage
		end
	end
	for n, i in pairs(e) do
		if e[n]._messageExecTable then
			l = l + 1
			S[l] = e[n]._messageExecTable
		end
	end
end
function e.OnMessage(n, e, i, a, p, t, o)
	local n = mvars
	local s = ""
	local T
	local u = Tpp.DoMessage
	local c = TppMission.CheckMessageOption
	local T = TppDebug
	local T = h
	local T = P
	local T = TppDefine.MESSAGE_GENERATION[e] and TppDefine.MESSAGE_GENERATION[e][i]
	if not T then
		T = TppDefine.DEFAULT_MESSAGE_GENERATION
	end
	local m = m()
	if m < T then
		return Mission.ON_MESSAGE_RESULT_RESEND
	end

	-- NUCLEAR BOMB: Intercept Judge system messages before general dispatch
	if NuclearBomb then
		NuclearBomb.OnMessage(e, { id = e, gameObjectId = a, judgeIsGuest = p })
	end

	for n = 1, r do
		local s = s
		d[n](e, i, a, p, t, o, s)
	end
	for r = 1, l do
		local n = s
		u(S[r], c, e, i, a, p, t, o, n)
	end
	if OnlineChallengeTask then
		OnlineChallengeTask.OnMessage(e, i, a, p, t, o, s)
	end
	if n.loc_locationCommonTable then
		n.loc_locationCommonTable.OnMessage(e, i, a, p, t, o, s)
	end
	if n.order_box_script then
		n.order_box_script.OnMessage(e, i, a, p, t, o, s)
	end
	if n.animalBlockScript and n.animalBlockScript.OnMessage then
		n.animalBlockScript.OnMessage(e, i, a, p, t, o, s)
	end
end
function e.OnTerminate(e)
	if e.sequence then
		if t(e.sequence.OnTerminate) then
			e.sequence.OnTerminate()
		end
	end

	if TppGameStatus.IsSet("Mission", "S_IS_ONLINE") and e.IsCoop(vars.missionCode) then
		Dynamite.StopNearestEnemyThread()
		TppGameStatus.Reset("Mission", "S_IS_ONLINE")
		TppNetworkUtil.SessionDisconnectPreparingMembers()
		TppNetworkUtil.CloseSession()
		Dynamite.ResetClientSessionState()
	end
end
return e
