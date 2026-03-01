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

