-- AntiCheat: all-in-one test tool for YOUR OWN game's anti-cheat (single script).
-- Put in StarterPlayer > StarterPlayerScripts as a LocalScript, or run it through your
-- test executor in your own place. RightShift hides/shows the menu.
--   Menu  : automation simulator (farm, quests, combat, loot, movement, ESP...)
--   Scan  : 'Scan game' button, collects remotes/quests/NPCs into ACScanData.json
--   Tests : 'Run tests' button (or type /ac all in chat), basic exploit simulations

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local player = Players.LocalPlayer
local env = (getgenv and getgenv()) or _G

-- Teardown registry. Declared unconditionally and BEFORE the gate below, because the rest of the
-- file uses it: if the gate block gets removed, the file must still load rather than dying with
-- "invalid argument #1 to 'insert' (table expected, got nil)".
local teardown: { () -> () } = {}
local revoked = false
local function revokeAll(reason: string)
	if revoked then
		return
	end
	revoked = true
	warn("[AC] " .. reason .. " - shutting down.")
	for _, fn in teardown do
		pcall(fn)
	end
end

-- ===== SELF-IDENTIFICATION (so the scanner doesn't report this tool as game data) =====
-- The getgc scan walks every live object, which includes this script's own tables and closures.
-- Without this, the report lists our settings table as "quest data" and our own field names
-- ("AcceptQuestRemote", "AutoQuest", "ESPNpcs") as strings found in the game.
local OURS: { [any]: boolean } = {}
local function claim<T>(t: T): T
	OURS[t] = true
	return t
end
-- Chunk name of this script; any closure reporting the same source is ours, not the game's.
local MY_SOURCE: string? = nil
pcall(function()
	MY_SOURCE = debug.info(function() end, "s")
end)

-- ===== GAME STATE RECONSTRUCTION =====
-- The server is authoritative, but it replicates a lot to the client: objects,
-- attributes, ValueBases, and UI text. This layer rebuilds useful game info
-- (stat points, quest objective, quest progress) from those sources, so the
-- automation needs no hardcoded per-game hooks. Whatever it can reconstruct here
-- is also information an exploiter can read, which is the point of testing it.
local GameState = claim({})

local function shown(g: Instance): boolean
	local cur: Instance? = g
	while cur and cur ~= game do
		if cur:IsA("GuiObject") and not cur.Visible then
			return false
		end
		if cur:IsA("ScreenGui") and not cur.Enabled then
			return false
		end
		cur = cur.Parent
	end
	return true
end

function GameState.uiTexts(): { string }
	local out = {}
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return out
	end
	for _, d in pg:GetDescendants() do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and not d:FindFirstAncestor("ACMenu") and shown(d) then
			table.insert(out, (d.Text:gsub("<[^>]+>", "")))
		end
	end
	return out
end

function GameState.statPoints(): number
	for k, v in player:GetAttributes() do
		if k:lower():find("point") and type(v) == "number" then
			return v
		end
	end
	for _, d in player:GetDescendants() do
		if d:IsA("ValueBase") and d.Name:lower():find("point") and type((d :: any).Value) == "number" then
			return (d :: any).Value
		end
	end
	for _, t in GameState.uiTexts() do
		local low = t:lower()
		local n = low:match("points?%D-(%d+)") or low:match("(%d+)%s*points?")
		if n then
			return tonumber(n) :: number
		end
	end
	return 0
end

-- Sorts a Humanoid NPC into: "enemy" | "quest" | "merchant" | "blacksmith" | "guard" | "ignore".
-- Only replicated hints are used: name, ProximityPrompt text, attributes, tags, parent folders.
local NPC_WORDS = {
	quest = { "quest", "mission", "bounty" },
	merchant = { "merchant", "shop", "vendor", "trader", "seller", "store", "trade" },
	blacksmith = { "blacksmith", "smith", "forge", "anvil", "upgrade", "craft" },
}
local ENEMY_WORDS = { "enemy", "enemies", "mob", "monster", "hostile", "creature", "boss" }
local GUARD_WORDS = { "guard", "sentry", "watchman" }
local npcClassCache: { [Model]: string } = setmetatable({}, { __mode = "k" }) :: any

local function hasAny(hay: string, words: { string }): boolean
	for _, w in words do
		if hay:find(w, 1, true) then
			return true
		end
	end
	return false
end

function GameState.classifyNPC(m: Model): string
	if npcClassCache[m] then
		return npcClassCache[m]
	end
	local CollectionService = game:GetService("CollectionService")

	-- explicit flags first: attributes / tags the game itself sets
	local hostile = m:GetAttribute("Hostile") or m:GetAttribute("IsEnemy") or m:GetAttribute("Enemy")
	local hay = { m.Name:lower() }
	for k, v in m:GetAttributes() do
		table.insert(hay, k:lower())
		if type(v) == "string" then
			table.insert(hay, v:lower())
		end
	end
	for _, tag in CollectionService:GetTags(m) do
		table.insert(hay, tag:lower())
	end
	local hasPrompt = false
	local promptText = {}
	for _, d in m:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			hasPrompt = true
			table.insert(promptText, (d.ActionText .. " " .. d.ObjectText):lower())
		elseif d:IsA("ClickDetector") then
			hasPrompt = true
		end
	end
	local folders, cur = {}, m.Parent
	for _ = 1, 4 do
		if not cur or cur == workspace then
			break
		end
		table.insert(folders, cur.Name:lower())
		cur = cur.Parent
	end
	local own = table.concat(hay, " ") .. " " .. table.concat(promptText, " ")
	local withFolders = own .. " " .. table.concat(folders, " ")

	local result
	if hostile == true then
		result = "enemy"
	elseif hasAny(own, NPC_WORDS.quest) then
		result = "quest"
	elseif hasAny(own, NPC_WORDS.merchant) then
		result = "merchant"
	elseif hasAny(own, NPC_WORDS.blacksmith) then
		result = "blacksmith"
	elseif hasAny(withFolders, ENEMY_WORDS) then
		result = "enemy"
	elseif hasAny(withFolders, GUARD_WORDS) then
		result = "guard"
	elseif hasPrompt then
		result = "ignore" -- interactive NPC we couldn't identify: don't attack it
	else
		result = "enemy" -- Humanoid with no interaction and no friendly hints
	end
	npcClassCache[m] = result
	return result
end

local KILL_VERBS = { "defeat", "kill", "slay", "hunt", "eliminate" }
local COLLECT_VERBS = { "collect", "gather", "find", "obtain", "pick up" }

-- Parses on-screen quest text like "Defeat 5 Goblins (2/5)" into an objective.
-- Quest markers. This game keeps the live objective and the tracked NPCs as children of
-- PlayerGui.markergui: one child named after the objective ("Defeat 3 bandits") and one per
-- located NPC, suffixed "-AddedByAreaLocator". That is far more reliable than scraping every
-- label on screen, which found nothing at all on this game.
local MARKER_SUFFIX = "-AddedByAreaLocator"

function GameState.questMarkers(): { objective: string?, npcs: { string } }
	local out: { objective: string?, npcs: { string } } = { objective = nil, npcs = {} }
	local pg = player:FindFirstChildOfClass("PlayerGui")
	local gui = pg and pg:FindFirstChild("markergui")
	if not gui then
		return out
	end
	for _, child in gui:GetChildren() do
		local n = child.Name
		local at = n:find(MARKER_SUFFIX, 1, true) -- plain find: the name contains pattern magic
		if at then
			table.insert(out.npcs, n:sub(1, at - 1))
		elseif not out.objective then
			out.objective = n
		end
	end
	return out
end

function GameState.questProgress(): { kind: string, target: string, current: number?, needed: number?, text: string }?
	local texts = GameState.uiTexts()
	-- the objective marker is the most trustworthy source, so it is parsed first
	local marker = GameState.questMarkers().objective
	if marker then
		table.insert(texts, 1, marker)
	end
	for _, raw in texts do
		local low = raw:lower()
		for _, group in { { KILL_VERBS, "kill" }, { COLLECT_VERBS, "collect" } } do
			for _, verb in group[1] :: { string } do
				local count, rest = low:match(verb .. "%s+(%d+)%s+(.+)")
				if not rest then
					rest = low:match(verb .. "%s+(.+)")
				end
				if rest then
					local target = (rest:gsub("%s*[%(%[].*$", ""):gsub("[%.!:]+.*$", ""):gsub("%s+$", ""))
					target = target:gsub("^the%s+", ""):gsub("^an?%s+", "")
					-- singularise so "Wolves"/"Zombies"/"Goblins" still substring-match "Wolf"/"Zombie"/"Goblin"
					if #target > 4 and target:sub(-3) == "ves" then
						target = target:sub(1, -4)
					elseif #target > 4 and target:sub(-3) == "ies" then
						target = target:sub(1, -4)
					elseif #target > 3 and target:sub(-1) == "s" then
						target = target:sub(1, -2)
					end
					local cur, need = low:match("(%d+)%s*/%s*(%d+)")
					if not cur then
						for _, other in texts do
							cur, need = other:match("(%d+)%s*/%s*(%d+)")
							if cur then
								break
							end
						end
					end
					return {
						kind = group[2] :: string,
						target = target,
						current = tonumber(cur),
						needed = tonumber(need) or tonumber(count),
						text = raw,
					}
				end
			end
		end
	end
	return nil
end

function GameState.questComplete(): boolean?
	local p = GameState.questProgress()
	if p and p.current and p.needed and p.current >= p.needed then
		return true
	end
	for _, t in GameState.uiTexts() do
		local low = t:lower()
		if low:find("quest complete") or low:find("claim reward") or low:find("turn in") or low:find("return to") then
			return true
		end
	end
	if p then
		return false
	end
	return nil
end

local comboIdx = 0
local lastSwing = 0

-- ===== ADAPTER: wire these to YOUR game =====
-- Remotes are looked up by name anywhere under ReplicatedStorage. Leave "" to skip.
local ADAPT = {
	-- From the scan's recorded call: SignalEvent.Event("Combat_Service", "Combat", combo, false, 0.13, false, nil)
	AttackRemote = "Communication.ServerAndClient.Signals.SignalEvent.Event", -- fired as AttackRemote:FireServer(unpack(BuildAttackArgs(enemy)))
	ParryRemote = "",
	SkillRemote = "",       -- if "", skills are sent as key presses instead
	StatRemote = "",        -- fired as StatRemote:FireServer(statName, amount)
	SellRemote = "",        -- fired as SellRemote:FireServer(itemName)
	AcceptQuestRemote = "",
	CompleteQuestRemote = "",
	-- Quest loop hooks. All optional; defaults are guesses until you fill them in.
	-- Name of the NPC model that gives/claims a quest.
	-- Return the NPC model name for a quest, or "" to let the loop work it out from the game's
	-- own quest markers. Returning the quest name was a bad default: objectives read like
	-- "Defeat 3 bandits", which matches no NPC and made findNPC fall through every time.
	QuestNPCName = function(_questName: string): string
		return ""
	end,
	-- Return { kind = "kill" | "collect", target = "<enemy or item name>" } for the active quest.
	-- Read it from your quest UI/attributes; default = kill anything.
	GetObjective = function(questName: string): { kind: string, target: string, needed: number? }
		local p = GameState.questProgress() -- reconstructed from on-screen quest text
		if p then
			return { kind = p.kind, target = p.target, needed = p.needed }
		end
		return { kind = "kill", target = "" }
	end,
	-- Return true when the quest is done, false if not, nil if you can't tell
	-- (then the loop falls back to the QuestActionSeconds timer).
	IsQuestComplete = function(questName: string): boolean?
		return GameState.questComplete()
	end,
	-- The recorded call carries no target, so the server resolves the hit itself (facing / range).
	-- Set `n` because the last argument is an explicit nil. The combo index cycles 1-4 (character
	-- attribute last_combo topped out at 4 in the scan); the 0.13 is copied as recorded.
	BuildAttackArgs = function(_enemy: Model): { any }
		-- A real combo resets when you stop swinging; replaying 1-2-3-4 forever across a pause is
		-- an obvious desync from what the client's own combat script would send.
		local now = os.clock()
		if now - lastSwing > 1.5 then
			comboIdx = 0
		end
		lastSwing = now
		comboIdx = comboIdx % 4 + 1
		return { "Combat_Service", "Combat", comboIdx, false, 0.13, false, nil, n = 7 }
	end,
	-- Return the number of unspent stat points (read your leaderstats / attribute).
	GetStatPoints = function(): number
		return GameState.statPoints() -- attributes, then ValueBases, then UI text
	end,
}

-- ===== LOAD SCAN DATA =====
-- AntiCheatScan saves ACScanData.json. If it exists, fill any ADAPT remote that is
-- still "" by matching remote names. Remotes you actually fired during the scan's
-- record phase are tried first, then ReplicatedStorage remotes, then getgc finds.
local function applyScanData()
	if not (env.isfile and env.readfile and env.isfile("ACScanData.json")) then
		return
	end
	local ok, scan = pcall(function()
		return HttpService:JSONDecode(env.readfile("ACScanData.json"))
	end)
	if not (ok and type(scan) == "table") then
		warn("[ACMenu] ACScanData.json unreadable, ignoring")
		return
	end

	local names: { string } = {}
	for path in scan.recorded or {} do
		table.insert(names, (path:match("[^%.]+$")))
	end
	for _, r in scan.remotes or {} do
		table.insert(names, r.name)
	end
	for _, path in scan.gcRemotes or {} do
		table.insert(names, (path:match("[^%.]+$")))
	end

	-- all = every word must appear, any = at least one (either may be empty)
	local rules = {
		AttackRemote = { all = {}, any = { "attack", "damage", "swing", "combat", "hit" } },
		ParryRemote = { all = {}, any = { "parry", "block", "deflect" } },
		SkillRemote = { all = {}, any = { "skill", "ability", "spell" } },
		StatRemote = { all = {}, any = { "stat", "allocate", "attribute" } },
		SellRemote = { all = {}, any = { "sell" } },
		AcceptQuestRemote = { all = { "quest" }, any = { "accept", "start", "take" } },
		CompleteQuestRemote = { all = { "quest" }, any = { "complete", "claim", "turnin", "finish" } },
	}

	local applied, missing = {}, {}
	for key, rule in rules do
		if ADAPT[key] == "" then
			for _, n in names do
				local low = (n :: string):lower()
				local okAll = true
				for _, w in rule.all do
					okAll = okAll and low:find(w, 1, true) ~= nil
				end
				local okAny = #rule.any == 0
				for _, w in rule.any do
					okAny = okAny or low:find(w, 1, true) ~= nil
				end
				if okAll and okAny then
					ADAPT[key] = n
					table.insert(applied, key .. "=" .. n)
					break
				end
			end
			if ADAPT[key] == "" then
				table.insert(missing, key)
			end
		end
	end
	print("[ACMenu] scan data applied: " .. (#applied > 0 and table.concat(applied, ", ") or "nothing"))
	if #missing > 0 then
		print("[ACMenu] no match found for (set in ADAPT by hand): " .. table.concat(missing, ", "))
	end
end
applyScanData()

-- ===== TESTER (basic exploit simulations) =====
local function setupTester()
-- ===== CONFIG: edit to match your game =====
local CONFIG = {
	-- true = run every test as soon as the script executes (handy from an executor)
	AutoRun = false,
	-- Remotes to fuzz. Add names of RemoteEvents in ReplicatedStorage.
	-- Full paths under ReplicatedStorage, from your scan (purchasedGamepass left out on purpose).
	RemoteNames = {
		"Communication.ServerAndClient.Signals.SignalFunction.Function",
		"Communication.ServerAndClient.Signals.SignalEvent.Event",
		"Communication.ServerAndClient.Signals.PartyHud.Event",
		"Communication.ServerAndClient.Effects.EffectsEvent.Event",
		"CAM.Global.ServerClientPortal.Event",
		"CAM.Global.ServerClientPortal.Function",
		"OCIServerHolder.Remote",
		"OCIServerHolder.RemoteFunction",
	} :: { string },
	-- How long to wait after each test for the server to react (seconds).
	ReactWindow = 4,
	SpeedValue = 100,
	JumpPowerValue = 200,
	TeleportDistance = 500,
	FlyHeight = 80,
	-- Humanized movement (tune these around your server thresholds)
	HumanDuration = 8,   -- seconds per humanized test
	HumanSpeed = 30,     -- studs/sec; server MaxSpeedStuds is 40
	HopStuds = 4,        -- studs per hop, one hop per 0.15s (~27 studs/sec)
	HumanRiseMax = 9,    -- studs; server MaxAirRise is 12
	HumanRiseRate = 4,   -- studs/sec while a burst is active
	-- Automation-signature tests: identical, perfectly regular behaviour repeated until flagged
	AutoAttempts = 200,  -- give up after this many attempts with no flag
	AutoInterval = 0.5,  -- seconds between remote calls (exact, no jitter)
	PatrolStuds = 30,    -- one lap = out and back this far
	PatrolSpeed = 16,    -- studs/sec, kept at a legal walk speed so only the pattern is unusual
	AutoRemote = "",     -- full path under ReplicatedStorage of the remote to call at a fixed interval
	AutoRemoteArgs = {} :: { any },
}

local results: { { key: string, name: string, detected: boolean, note: string } } = {}
local currentKey = ""
local listeners = {
	onStart = {} :: { (string) -> () },
	onResult = {} :: { (any) -> () },
	onProgress = {} :: { (string, string) -> () },
}
local busy = false
-- Toggle mode: the movement/automation tests loop until stopRequested instead of stopping on their own.
local continuous, stopRequested = false, false
local TOGGLABLE = { human_speed = true, human_hops = true, human_fly = true, auto_path = true, auto_remote = true }

local function progress(text: string)
	for _, fn in listeners.onProgress do
		task.spawn(fn, currentKey, text)
	end
end

local function record(name: string, detected: boolean, note: string)
	local entry = { key = currentKey, name = name, detected = detected, note = note }
	table.insert(results, entry)
	for _, fn in listeners.onResult do
		task.spawn(fn, entry)
	end
end

local function log(msg: string)
	print(("[ACTest] %s"):format(msg))
end

local function getChar(): (Model, Humanoid, BasePart)
	local char = player.Character or player.CharacterAdded:Wait()
	local hum = char:WaitForChild("Humanoid") :: Humanoid
	local root = char:WaitForChild("HumanoidRootPart") :: BasePart
	return char, hum, root
end

-- Runs `action`, waits, then asks `wasReverted` whether the server undid it.
-- A respawn/death also counts as detection.
local function runTest(name: string, action: (Humanoid, BasePart) -> (), wasReverted: (Humanoid, BasePart) -> boolean)
	local char, hum, root = getChar()
	log("Running: " .. name)
	local startChar = char
	local died = false
	local conn = hum.Died:Connect(function()
		died = true
	end)

	action(hum, root)
	task.wait(CONFIG.ReactWindow)
	conn:Disconnect()

	local replaced = player.Character ~= startChar
	local detected = died or replaced
	local note = detected and "character reset/killed" or ""
	if not detected and startChar.Parent and hum.Parent then
		detected = wasReverted(hum, root)
		note = detected and "value reverted / corrected" or "NOT DETECTED"
	end

	record(name, detected, note)
	log(("%s -> %s (%s)"):format(name, detected and "CAUGHT" or "MISSED", note))
	if not detected then
		-- put things back so the next test starts clean
		pcall(function()
			hum.WalkSpeed = 16
			hum.JumpPower = 50
		end)
	end
	if player.Character == startChar and (died or not startChar.Parent) then
		player.CharacterAdded:Wait() -- fresh character between tests
	end
end

local tests: { [string]: () -> () } = {}

tests.speed = function()
	runTest("WalkSpeed hack", function(hum)
		hum.WalkSpeed = CONFIG.SpeedValue
	end, function(hum)
		return hum.WalkSpeed ~= CONFIG.SpeedValue
	end)
end

tests.jump = function()
	runTest("JumpPower hack", function(hum)
		hum.UseJumpPower = true
		hum.JumpPower = CONFIG.JumpPowerValue
		hum.Jump = true
	end, function(hum)
		return hum.JumpPower ~= CONFIG.JumpPowerValue
	end)
end

tests.teleport = function()
	local origin: Vector3
	runTest("Teleport hack", function(_, root)
		origin = root.Position
		root.CFrame = root.CFrame + Vector3.new(CONFIG.TeleportDistance, 0, 0)
	end, function(_, root)
		return (root.Position - origin).Magnitude < CONFIG.TeleportDistance * 0.5
	end)
end

tests.fly = function()
	local startY = 0
	local bv: BodyVelocity? = nil
	runTest("Fly hack (BodyVelocity)", function(_, root)
		startY = root.Position.Y
		local v = Instance.new("BodyVelocity")
		v.MaxForce = Vector3.new(1e6, 1e6, 1e6)
		v.Velocity = Vector3.new(0, CONFIG.FlyHeight / 2, 0)
		v.Parent = root
		bv = v
	end, function(_, root)
		return root.Position.Y - startY < CONFIG.FlyHeight * 0.5
	end)
	if bv then
		bv:Destroy()
	end
end

tests.noclip = function()
	runTest("Noclip (CanCollide off)", function(_, root)
		local char = root.Parent :: Model
		for _, p in char:GetDescendants() do
			if p:IsA("BasePart") then
				p.CanCollide = false
			end
		end
		root.CFrame = root.CFrame + root.CFrame.LookVector * 20
	end, function()
		return false -- server must kick/reset; no state to inspect
	end)
end

tests.health = function()
	runTest("Health/MaxHealth edit", function(hum)
		hum.MaxHealth = math.huge
		hum.Health = math.huge
	end, function(hum)
		return hum.MaxHealth ~= math.huge
	end)
end

-- ===== HUMANIZED MOVEMENT TESTS =====
-- Subtle movement meant to sit near or under your thresholds. Detection = the server pushed at
-- least one flag (ACFlags) during the run, or reset the character. Each result records how many
-- flags fired, so you can see how close a MISSED test came to being caught.
local flagCount = 0
task.spawn(function()
	local flags = ReplicatedStorage:WaitForChild("ACFlags", 15)
	if flags and flags:IsA("RemoteEvent") then
		flags.OnClientEvent:Connect(function()
			flagCount += 1
		end)
	end
end)

local moveRng = Random.new()

local function runMoveTest(name: string, duration: number, step: (root: BasePart, dt: number, t: number) -> ())
	local char, hum, root = getChar()
	log("Running: " .. name)
	local startChar = char
	flagCount = 0
	local resets = 0
	local t0 = os.clock()
	local isCont = continuous
	local lastProgress = 0
	while true do
		local elapsed = os.clock() - t0
		if isCont then
			if stopRequested then
				break
			end
		elseif elapsed >= duration then
			break
		end
		-- A reset is a detection, not the end of the run. In toggle mode the point is to keep
		-- applying pressure, so re-acquire the new character and carry on; a one-shot Run still
		-- stops, because the reset is the result it was measuring.
		if player.Character ~= startChar or hum.Health <= 0 or not root.Parent then
			if not isCont then
				break
			end
			resets += 1
			char, hum, root = getChar()
			startChar = char
			task.wait(0.5)
		end
		local dt = RunService.Heartbeat:Wait()
		step(root, dt, elapsed)
		if isCont and os.clock() - lastProgress > 0.5 then
			lastProgress = os.clock()
			progress(("ON %ds • %d flag(s)"):format(elapsed, flagCount))
		end
	end
	task.wait(CONFIG.ReactWindow)

	local ended = player.Character ~= startChar or hum.Health <= 0
	local resetCount = resets + (ended and 1 or 0)
	local detected = flagCount > 0 or resetCount > 0
	local note = ("%d flag(s) over %ds%s"):format(
		flagCount, os.clock() - t0, resetCount > 0 and (", %d character reset(s)"):format(resetCount) or "")
	record(name, detected, note)
	log(("%s -> %s (%s)"):format(name, detected and "CAUGHT" or "MISSED", note))
	if ended then
		player.CharacterAdded:Wait()
	end
end

-- Horizontal CFrame movement above WalkSpeed but under the server's studs/sec cap, with jitter
-- and short stops like a person changing direction.
tests.human_speed = function()
	local dir = Vector3.new(1, 0, 0)
	local pauseUntil = 0
	local speed = CONFIG.HumanSpeed
	local _, _, root0 = getChar()
	local home = root0.Position
	runMoveTest("Humanized speed (CFrame, under cap)", CONFIG.HumanDuration, function(root, dt, t)
		if t < pauseUntil then
			return
		end
		if (root.Position - home).Magnitude > 120 then -- long toggled runs: turn back toward the start
			local back = home - root.Position
			dir = Vector3.new(back.X, 0, back.Z).Unit
		end
		if moveRng:NextNumber() < 0.01 then
			pauseUntil = t + 0.2 + moveRng:NextNumber() * 0.6
			dir = CFrame.Angles(0, math.rad(moveRng:NextNumber(-70, 70)), 0):VectorToWorldSpace(dir)
			return
		end
		local s = speed * (1 + moveRng:NextNumber(-0.1, 0.1))
		root.CFrame += dir * s * dt
	end)
end

-- Short hops that each stay under MaxTeleport and whose average stays near the speed cap.
tests.human_hops = function()
	local acc = 0
	local sign = 1
	local _, _, root0 = getChar()
	local homeX = root0.Position.X
	runMoveTest("Humanized short-hop teleport", CONFIG.HumanDuration, function(root, dt)
		acc += dt
		if acc >= 0.15 then
			acc = 0
			if math.abs(root.Position.X - homeX) > 100 then -- long toggled runs: reverse direction
				sign = -math.sign(root.Position.X - homeX)
			end
			root.CFrame += Vector3.new(sign * CONFIG.HopStuds * (0.8 + moveRng:NextNumber() * 0.4), 0, 0)
		end
	end)
end

-- Slow rise in bursts, reaching only part of the allowed air-rise before settling.
tests.human_fly = function()
	local startY = 0
	local first = true
	runMoveTest("Humanized fly (slow burst rise)", CONFIG.HumanDuration, function(root, dt, t)
		if first then
			startY = root.Position.Y
			first = false
		end
		local burst = math.sin(t * 1.3) > 0
		if burst and root.Position.Y - startY < CONFIG.HumanRiseMax then
			root.CFrame += Vector3.new(0, CONFIG.HumanRiseRate * dt, 0)
			root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
		end
	end)
end

-- ===== AUTOMATION-SIGNATURE TESTS =====
-- Real automation is recognisable by repetition and zero variance, not by any single value being
-- illegal. Each attempt is identical to the last; the run stops at the first server flag and
-- reports how many attempts it took, so you can see how far your flag threshold sits.
-- These are not in "all" (200 attempts can take minutes); run them by name or from the menu.
local function resolveRemote(path: string): Instance?
	local cur: Instance? = ReplicatedStorage
	for part in path:gmatch("[^%.]+") do
		cur = cur and cur:FindFirstChild(part)
	end
	return cur or ReplicatedStorage:FindFirstChild(path, true)
end

local function sendRemote(remote: Instance, ...: any)
	if remote:IsA("RemoteEvent") then
		(remote :: RemoteEvent):FireServer(...)
	else
		task.spawn(pcall, function(...)
			(remote :: RemoteFunction):InvokeServer(...) -- may yield/never return; runs detached
		end, ...)
	end
end

local function runRepeatTest(name: string, attempt: (n: number) -> ())
	local char, hum = getChar()
	log("Running: " .. name)
	flagCount = 0
	local firstAt: number? = nil
	local n = 0
	local resets = 0
	local isCont = continuous
	while true do
		if isCont then
			if stopRequested then
				break
			end
		elseif n >= CONFIG.AutoAttempts or firstAt then
			break
		end
		-- keep applying pressure across resets while toggled on (see runMoveTest)
		if player.Character ~= char or hum.Health <= 0 then
			if not isCont then
				break
			end
			resets += 1
			char, hum = getChar()
			task.wait(0.5)
		end
		n += 1
		attempt(n)
		if flagCount > 0 and not firstAt then
			firstAt = n
		end
		if isCont then
			progress(("ON • %d attempt(s) • %d flag(s)%s"):format(n, flagCount, firstAt and (" • first at " .. firstAt) or ""))
		end
	end
	task.wait(CONFIG.ReactWindow) -- the server checks on an interval, so allow late flags
	local ended = player.Character ~= char or hum.Health <= 0
	local resetCount = resets + (ended and 1 or 0)
	if not firstAt and flagCount > 0 then
		firstAt = n
	end
	local detected = firstAt ~= nil or resetCount > 0
	local note = firstAt and ("first flag after %d attempt(s), %d flag(s) total"):format(firstAt, flagCount)
		or ("no flag after %d attempts"):format(n)
	record(name, detected, note .. (resetCount > 0 and (", %d reset(s)"):format(resetCount) or ""))
	log(("%s -> %s (%s)"):format(name, detected and "CAUGHT" or "MISSED", note))
	if ended then
		player.CharacterAdded:Wait()
	end
end

-- Constant-speed A->B->A patrol on the exact same line every lap.
tests.auto_path = function()
	local _, _, root0 = getChar()
	local a = root0.Position
	local b = a + Vector3.new(CONFIG.PatrolStuds, 0, 0)
	-- The root is re-read every frame: holding the one captured at the start would keep writing
	-- to a destroyed part after a respawn, which is exactly what a long toggled run provokes.
	local function glide(from: Vector3, to: Vector3)
		local dur = (to - from).Magnitude / math.max(CONFIG.PatrolSpeed, 0.1)
		local t = 0
		while t < dur do
			t += RunService.Heartbeat:Wait()
			local c = player.Character
			local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not root then
				return
			end
			local rot = root.CFrame - root.CFrame.Position
			root.CFrame = CFrame.new(from:Lerp(to, math.min(t / dur, 1))) * rot
		end
	end
	runRepeatTest("Automation: identical patrol lap", function()
		glide(a, b)
		glide(b, a)
	end)
end

-- One remote fired at an exact fixed interval with identical arguments.
tests.auto_remote = function()
	local remote = CONFIG.AutoRemote ~= "" and resolveRemote(CONFIG.AutoRemote) or nil
	if not (remote and (remote:IsA("RemoteEvent") or remote:IsA("RemoteFunction"))) then
		log("auto_remote skipped: set CONFIG.AutoRemote to a full remote path (Automation tab)")
		return
	end
	local nextAt = os.clock()
	runRepeatTest("Automation: fixed-interval remote", function()
		sendRemote(remote, table.unpack(CONFIG.AutoRemoteArgs))
		nextAt += CONFIG.AutoInterval
		task.wait(math.max(0, nextAt - os.clock()))
	end)
end

tests.remotes = function()
	if #CONFIG.RemoteNames == 0 then
		log("Remote fuzz skipped: add names to CONFIG.RemoteNames")
		return
	end
	local payloads: { any } = {
		nil, 0, -1, math.huge, -math.huge, 0 / 0, 1e308, "", string.rep("A", 100000),
		{}, { {} }, true, Vector3.new(math.huge, 0, 0), workspace, player,
	}
	-- Names are full paths under ReplicatedStorage ("A.B.C", as the scan prints them) or bare names.
	for _, remoteName in CONFIG.RemoteNames do
		local remote = resolveRemote(remoteName)
		if remote and (remote:IsA("RemoteEvent") or remote:IsA("RemoteFunction")) then
			flagCount = 0
			log("Fuzzing remote: " .. remoteName)
			for i = 1, 15 do
				pcall(sendRemote, remote, payloads[i])
			end
			if remote:IsA("RemoteEvent") then
				log("Spamming remote: " .. remoteName)
				for _ = 1, 500 do
					pcall(sendRemote, remote)
				end
			end
			task.wait(CONFIG.ReactWindow)
			-- Only remotes wrapped in AC.guard can flag; MISSED means no rate limit fired, not necessarily exploitable.
			record("Remote " .. remoteName:match("[^%.]+$"), flagCount > 0, ("%d flag(s)"):format(flagCount))
		else
			log("Remote not found or not a Remote: " .. remoteName)
		end
	end
end

local function printReport()
	log("===== REPORT =====")
	for _, r in results do
		log(("%-28s %s  %s"):format(r.name, r.detected and "CAUGHT" or "MISSED", r.note))
	end
end

local function invoke(key: string)
	currentKey = key
	for _, fn in listeners.onStart do
		task.spawn(fn, key)
	end
	tests[key]()
	currentKey = ""
end

local function run(cmd: string, toggleMode: boolean?)
	if busy then
		log("A run is already in progress")
		return
	end
	busy = true
	continuous = toggleMode == true and TOGGLABLE[cmd] == true
	stopRequested = false
	if cmd == "all" then
		for _, name in { "speed", "jump", "teleport", "fly", "noclip", "health", "human_speed", "human_hops", "human_fly", "remotes" } do
			invoke(name)
		end
		printReport()
	elseif tests[cmd] then
		invoke(cmd)
		printReport()
	else
		log("Unknown test. Options: all, speed, jump, teleport, fly, noclip, health, human_speed, human_hops, human_fly, auto_path, auto_remote, remotes")
	end
	busy = false
	continuous, stopRequested = false, false
	for _, fn in listeners.onStart do
		task.spawn(fn, "")
	end
end

-- Start the test as an on/off switch, or turn it off if it is the one currently on.
local function toggle(key: string)
	if not TOGGLABLE[key] then
		log("Not a toggle test: " .. key)
	elseif busy and continuous and currentKey == key then
		stopRequested = true
		log("Stopping: " .. key)
	elseif busy then
		log("Another run is active; turn it off first")
	else
		task.spawn(run, key, true)
	end
end

local function handle(text: string)
	local verb, arg = text:match("^/ac%s+(%w+)%s*(%w*)")
	if not verb then
		return
	end
	verb = verb:lower()
	if verb == "on" or verb == "toggle" then
		toggle(arg:lower())
	elseif verb == "off" then
		stopRequested = true
	else
		task.spawn(run, verb)
	end
end

-- Works with both chat systems
if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
	TextChatService.SendingMessage:Connect(function(msg)
		handle(msg.Text)
	end)
else
	player.Chatted:Connect(handle)
end

log("Ready. Type /ac all  (or on <test> / off for toggles; speed, jump, teleport, fly, noclip, health, human_speed, human_hops, human_fly, auto_path, auto_remote, remotes)")

if CONFIG.AutoRun then
	task.spawn(run, "all")
end

	local api = {
		CONFIG = CONFIG, results = results, listeners = listeners,
		isBusy = function() return busy end, toggle = toggle,
	}
	return run, api
end

-- ===== SCANNER (collects info about your game) =====
-- Value serialiser, shared by the scanner report and the remote recorder.
local function ser(v: any, depth: number?): string
	depth = depth or 0
	local t = typeof(v)
	if t == "string" then
		return #v > 60 and ('"' .. v:sub(1, 60) .. '..."') or ('"' .. v .. '"')
	elseif t == "table" then
		if depth :: number >= 2 then
			return "{...}"
		end
		local parts, n = {}, 0
		for k, val in v do
			n += 1
			if n > 8 then
				table.insert(parts, "...")
				break
			end
			table.insert(parts, ("[%s]=%s"):format(tostring(k), ser(val, (depth :: number) + 1)))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	elseif t == "Instance" then
		return "<" .. v.ClassName .. " " .. v:GetFullName() .. ">"
	end
	if t == "number" or t == "boolean" or t == "nil" then
		return tostring(v)
	end
	return tostring(v) .. "(" .. t .. ")"
end

-- ===== REMOTE RECORDER =====
-- Captures the remote calls YOUR OWN actions produce, so their argument format can be replayed.
--
-- This is a toggle with no time limit, not a fixed window. A quest cycle (walk out, accept, do
-- the objective, walk back, hand in) does not fit in 60 seconds, and you may only be able to do
-- one quest now and another later. Captures accumulate across start/stop and across sessions, so
-- you can record the accept today and the turn-in whenever you get to it.
--
-- Calls are grouped per remote AND per "selector" (the first string argument), because games
-- commonly multiplex everything through one remote - here SignalEvent.Event("Combat_Service",...).
type Variant = { count: number, sample: string, alt: string? }
type Logged = { count: number, variants: { [string]: Variant } }

local RECORD_FILE = "ACRecorded.json"
local MAX_VARIANTS = 24

local Recorder = claim({
	on = false,
	installed = false,
	total = 0,
	captures = {} :: { [string]: Logged },
	onChange = nil :: (() -> ())?,
})

local function variantCount(entry: Logged): number
	local n = 0
	for _ in entry.variants do
		n += 1
	end
	return n
end

local function recordCall(self: any, ...)
	local args = table.pack(...)
	local parts = {}
	for i = 1, args.n do
		table.insert(parts, ser(args[i]))
	end
	local key = self:GetFullName()
	local sig = key .. "(" .. table.concat(parts, ", ") .. ")"
	local selector = "(no selector)"
	if args.n > 0 then
		selector = type(args[1]) == "string" and args[1] or ("<" .. typeof(args[1]) .. ">")
	end
	Recorder.total += 1
	local entry = Recorder.captures[key]
	if not entry then
		entry = { count = 0, variants = {} }
		Recorder.captures[key] = entry
	end
	entry.count += 1
	local v = entry.variants[selector]
	if v then
		v.count += 1
		if v.sample ~= sig and not v.alt then
			v.alt = sig -- one differing sample shows which arguments vary
		end
	elseif variantCount(entry) < MAX_VARIANTS then
		entry.variants[selector] = { count = 1, sample = sig }
	end
	if Recorder.onChange then
		Recorder.onChange()
	end
end

-- Hooks are installed once and left in place; they only log while Recorder.on is true.
function Recorder.install(): string
	if Recorder.installed then
		return "already installed"
	end
	if not (env.hookmetamethod and env.getnamecallmethod) then
		return "unavailable (this executor has no hookmetamethod)"
	end
	Recorder.installed = true
	local wrap = env.newcclosure or function(f)
		return f
	end
	-- method-style calls: remote:FireServer(...)
	local oldNamecall
	oldNamecall = env.hookmetamethod(game, "__namecall", wrap(function(self, ...)
		local method = env.getnamecallmethod()
		if Recorder.on and (method == "FireServer" or method == "InvokeServer") and typeof(self) == "Instance" then
			pcall(recordCall, self, ...)
		end
		return oldNamecall(self, ...)
	end))
	-- cached/dot-style calls never touch __namecall, so hook the functions too where possible
	local extra: { string } = {}
	if env.hookfunction then
		for _, spec in { { "RemoteEvent", "FireServer" }, { "RemoteFunction", "InvokeServer" },
			{ "UnreliableRemoteEvent", "FireServer" } } do
			local ok = pcall(function()
				local probe = Instance.new(spec[1])
				local orig
				orig = env.hookfunction(probe[spec[2]], wrap(function(self, ...)
					if Recorder.on and typeof(self) == "Instance" then
						pcall(recordCall, self, ...)
					end
					return orig(self, ...)
				end))
				probe:Destroy()
			end)
			if ok then
				table.insert(extra, spec[1])
			end
		end
	end
	return #extra > 0 and ("__namecall + " .. table.concat(extra, ", ")) or "__namecall only"
end

function Recorder.save()
	if not env.writefile then
		return
	end
	pcall(function()
		env.writefile(RECORD_FILE, HttpService:JSONEncode(Recorder.captures))
	end)
end

function Recorder.load()
	if not (env.isfile and env.readfile and env.isfile(RECORD_FILE)) then
		return
	end
	local ok, data = pcall(function()
		return HttpService:JSONDecode(env.readfile(RECORD_FILE))
	end)
	if not (ok and type(data) == "table") then
		return
	end
	-- merge, so a capture from an earlier session is not lost by this one
	for key, entry in data do
		if type(entry) == "table" and type(entry.variants) == "table" then
			local cur = Recorder.captures[key]
			if not cur then
				Recorder.captures[key] = entry
			else
				for sel, v in entry.variants do
					if not cur.variants[sel] and variantCount(cur) < MAX_VARIANTS then
						cur.variants[sel] = v
					end
				end
			end
		end
	end
end

function Recorder.setOn(state: boolean): string
	if state and not Recorder.installed then
		local how = Recorder.install()
		if not Recorder.installed then
			return how
		end
		print("[ACRec] hooks: " .. how)
	end
	Recorder.on = state
	if not state then
		Recorder.save()
	end
	if Recorder.onChange then
		Recorder.onChange()
	end
	return state and "recording" or "stopped"
end

-- Human-readable dump, busiest selector first.
function Recorder.report(): string
	local out = { "=== Recorded remote calls ===",
		"Grouped by first argument (the action selector for multiplexed remotes)." }
	local any = false
	for name, entry in Recorder.captures do
		any = true
		table.insert(out, ("%s  x%d"):format(name, entry.count))
		local sels = {}
		for sel in entry.variants do
			table.insert(sels, sel)
		end
		table.sort(sels, function(a, b)
			return entry.variants[a].count > entry.variants[b].count
		end)
		for _, sel in sels do
			local v = entry.variants[sel]
			table.insert(out, ("    [%s] x%d"):format(sel, v.count))
			table.insert(out, ("        %s"):format(v.sample))
			if v.alt then
				table.insert(out, ("        alt: %s"):format(v.alt))
			end
		end
	end
	if not any then
		table.insert(out, "(nothing captured yet)")
	end
	return table.concat(out, "\n")
end

Recorder.load()

local scannerRan = false
local function runScanner()
	if scannerRan then
		warn("[ACScan] already ran this session; re-execute the script to scan again")
		return
	end
	scannerRan = true
-- ===== helpers =====
local lines: { string } = {}
-- Structured copy of the findings, saved as ACScanData.json for AntiCheatMenu to load.
local data = { remotes = {}, enemies = {}, gcRemotes = {}, candidates = {}, questStrings = {}, recorded = {} }
local function add(s: string)
	table.insert(lines, s)
end

local function flush(label: string)
	local text = table.concat(lines, "\n")
	print(text)
	if env.writefile then
		pcall(function()
			env.writefile("ACScanData.json", game:GetService("HttpService"):JSONEncode(data))
		end)
		pcall(env.writefile, "ACScan.txt", text)
		print(("[ACScan] %s saved to ACScan.txt in your executor workspace folder"):format(label))
	end
	if env.setclipboard then
		pcall(env.setclipboard, text)
		print("[ACScan] Report copied to clipboard, paste it straight into chat")
	end
end

-- ===== getgc scan (read-only) =====
-- Walks live Luau memory for what the game's own scripts hold: RemoteEvent/Function
-- references (in tables and function upvalues), string constants of functions that
-- call FireServer/InvokeServer (candidate remote names), and quest-looking strings/tables.
-- It never writes to anything, hooks nothing, and only reads via next/upvalue/constant getters.
local QUEST_WORDS = { "quest", "objective", "reward", "defeat", "slay", "collect", "npc", "bounty", "mission" }

local function looksQuesty(s: string): boolean
	if #s < 4 or #s > 80 then
		return false
	end
	local low = s:lower()
	for _, w in QUEST_WORDS do
		if low:find(w, 1, true) then
			return true
		end
	end
	return false
end

local function isRemote(v: any): boolean
	return typeof(v) == "Instance"
		and (v:IsA("RemoteEvent") or v:IsA("RemoteFunction") or v:IsA("UnreliableRemoteEvent"))
end

local function sortedKeys(t: { [string]: any }): { string }
	local out = {}
	for k in t do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

local function gcScan()
	add("--- getgc scan (read-only) ---")
	if not env.getgc then
		add("getgc unavailable in this executor, skipped")
		add("")
		return
	end
	local ok, objs = pcall(env.getgc, true)
	if not ok then
		add("getgc failed: " .. tostring(objs))
		add("")
		return
	end

	local remotes: { [string]: number } = {}
	local remoteUsers: { [string]: { [string]: boolean } } = {}
	local candidates: { [string]: string } = {} -- constant string -> script that fires remotes with it
	local questStrings: { [string]: boolean } = {}
	local questTables: { string } = {}

	local function noteRemote(r: Instance, owner: string?)
		local path = r:GetFullName()
		remotes[path] = (remotes[path] or 0) + 1
		if owner then
			remoteUsers[path] = remoteUsers[path] or {}
			remoteUsers[path][owner] = true
		end
	end

	local scanned = 0
	for _, v in objs do
		scanned += 1
		if scanned % 3000 == 0 then
			task.wait() -- keep the client responsive
		end
		local t = type(v)
		if OURS[v] then
			-- our own settings / adapter / tester tables
		elseif t == "table" then
			pcall(function()
				local hits, n = 0, 0
				for k, val in next, v do -- next: no metamethods triggered
					n += 1
					if n > 200 then
						break
					end
					if isRemote(val) then
						noteRemote(val)
					elseif isRemote(k) then
						noteRemote(k)
					end
					if type(val) == "string" and looksQuesty(val) then
						questStrings[val] = true
						hits += 1
					end
					if type(k) == "string" and looksQuesty(k) then
						hits += 1
					end
				end
				if hits >= 2 and #questTables < 40 then
					table.insert(questTables, ser(v))
				end
			end)
		elseif t == "function" then
			pcall(function()
				if env.iscclosure and env.iscclosure(v) then
					return
				end
				local owner = debug.info(v, "s")
				if MY_SOURCE and owner == MY_SOURCE then
					return -- one of our own closures; its constants are our strings, not the game's
				end
				if env.getupvalues then
					for _, up in env.getupvalues(v) do
						if isRemote(up) then
							noteRemote(up, owner)
						end
					end
				end
				if env.getconstants then
					local consts = env.getconstants(v)
					local fires = false
					for _, c in consts do
						if c == "FireServer" or c == "InvokeServer" then
							fires = true
							break
						end
					end
					for _, c in consts do
						if type(c) == "string" then
							if looksQuesty(c) then
								questStrings[c] = true
							end
							if fires and #c > 2 and #c < 40 and c ~= "FireServer" and c ~= "InvokeServer" then
								candidates[c] = owner
							end
						end
					end
				end
			end)
		end
	end

	add(("scanned %d gc objects"):format(scanned))
	add("")
	add("Remotes held by game code (tables/upvalues), with the scripts that hold them:")
	local remoteNames = sortedKeys(remotes)
	for _, path in remoteNames do
		local users = remoteUsers[path] and table.concat(sortedKeys(remoteUsers[path]), ", ") or "table reference"
		add(("  %s  x%d  <- %s"):format(path, remotes[path], users))
	end
	if #remoteNames == 0 then
		add("  (none found)")
	end
	add("")
	add("String constants in functions that call FireServer/InvokeServer (candidate remote names / args):")
	local cnames = sortedKeys(candidates)
	for i, c in cnames do
		if i > 80 then
			add("  ...")
			break
		end
		add(("  %q  in %s"):format(c, tostring(candidates[c])))
	end
	if #cnames == 0 then
		add("  (none found)")
	end
	add("")
	add("Quest-looking strings:")
	local qnames = sortedKeys(questStrings)
	data.questStrings = qnames
	data.gcRemotes = remoteNames
	for c, owner in candidates do
		data.candidates[c] = tostring(owner)
	end
	for i, q in qnames do
		if i > 60 then
			add("  ...")
			break
		end
		add("  " .. q)
	end
	if #qnames == 0 then
		add("  (none found)")
	end
	add("")
	add("Tables that look like quest data:")
	for _, s in questTables do
		add("  " .. s)
	end
	if #questTables == 0 then
		add("  (none found)")
	end
	add("")
end

-- ===== Phase 1: static scan =====
add("=== ACScan report ===")
add(("PlaceId=%d GameId=%d CreatorId=%d (%s)"):format(game.PlaceId, game.GameId, game.CreatorId, tostring(game.CreatorType)))
add("")

add("--- Remotes (ReplicatedStorage) ---")
local remoteCount = 0
for _, d in ReplicatedStorage:GetDescendants() do
	if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("UnreliableRemoteEvent") then
		add(("%s  %s"):format(d.ClassName, d:GetFullName()))
		table.insert(data.remotes, { name = d.Name, path = d:GetFullName(), class = d.ClassName })
		remoteCount += 1
	end
end
add(("(%d remotes)"):format(remoteCount))
add("")

add("--- Player: leaderstats / attributes / values ---")
local ls = player:FindFirstChild("leaderstats")
if ls then
	for _, v in ls:GetChildren() do
		add(("leaderstat %s = %s"):format(v.Name, v:IsA("ValueBase") and tostring((v :: any).Value) or v.ClassName))
	end
end
for k, v in player:GetAttributes() do
	add(("player attribute %s = %s"):format(k, ser(v)))
end
for _, d in player:GetDescendants() do
	if d:IsA("ValueBase") and not (ls and d:IsDescendantOf(ls)) then
		add(("value %s = %s"):format(d:GetFullName(), tostring((d :: any).Value)))
	end
end
add("")

add("--- Character attributes / tools ---")
local char = player.Character
if char then
	for k, v in char:GetAttributes() do
		add(("character attribute %s = %s"):format(k, ser(v)))
	end
	for _, t in char:GetChildren() do
		if t:IsA("Tool") then
			add("equipped tool: " .. t.Name)
		end
	end
end
for _, t in player.Backpack:GetChildren() do
	add(("backpack %s: %s"):format(t.ClassName, t.Name))
end
add("")

add("--- Enemies (non-player models with a Humanoid) ---")
local enemyNames: { [string]: number } = {}
for _, d in workspace:GetDescendants() do
	if d:IsA("Model") and d:FindFirstChildOfClass("Humanoid") and not Players:GetPlayerFromCharacter(d) then
		enemyNames[d.Name] = (enemyNames[d.Name] or 0) + 1
	end
end
for name, n in enemyNames do
	add(("%s x%d"):format(name, n))
	data.enemies[name] = n
end
add("")

add("--- Likely loot / chests / pickups (by name or ProximityPrompt) ---")
local seen: { [string]: number } = {}
for _, d in workspace:GetDescendants() do
	if d:IsA("ProximityPrompt") then
		local key = ("Prompt on %s (action=%q, object=%q)"):format(d.Parent and d.Parent.Name or "?", d.ActionText, d.ObjectText)
		seen[key] = (seen[key] or 0) + 1
	elseif d:IsA("Model") or d:IsA("BasePart") then
		local n = d.Name:lower()
		if n:find("chest") or n:find("drop") or n:find("loot") or n:find("coin") or n:find("orb") or n:find("pickup") then
			local key = d.ClassName .. " " .. d.Name
			seen[key] = (seen[key] or 0) + 1
		end
	end
end
for key, n in seen do
	add(("%s x%d"):format(key, n))
end
add("")

add("--- Quest / stat / shop UI text (PlayerGui buttons and labels with useful words) ---")
local uiSeen: { [string]: boolean } = {}
for _, d in player.PlayerGui:GetDescendants() do
	if (d:IsA("TextButton") or d:IsA("TextLabel")) and d.Text ~= "" and #d.Text < 40 then
		local t = d.Text:lower()
		if t:find("quest") or t:find("stat") or t:find("point") or t:find("sell") or t:find("upgrade")
			or t:find("strength") or t:find("defense") or t:find("accept") or t:find("claim") then
			local line = ("%s  %q  (%s)"):format(d.ClassName, d.Text, d:GetFullName())
			if not uiSeen[line] then
				uiSeen[line] = true
				add(line)
			end
		end
	end
end
add("")

add("--- Executor capabilities ---")
for _, fn in { "hookmetamethod", "getnamecallmethod", "newcclosure", "writefile", "readfile", "isfile",
	"fireproximityprompt", "firetouchinterest", "setclipboard", "gethui", "getgc",
	"getupvalues", "getconstants", "iscclosure" } do
	add(("%s: %s"):format(fn, env[fn] and "yes" or "no"))
end
add("")
gcScan()
flush("Full report")
applyScanData()

-- Recording your own remote calls used to happen here as a fixed 60-second window. It is now a
-- toggle on the Remotes tab instead: a quest cycle does not fit in 60 seconds, and captures
-- need to accumulate across sessions.
print("[ACScan] Scan done. To capture remote argument formats, use Remotes > Record remote calls.")

end

local runTests, testApi = setupTester()
claim(testApi.CONFIG)
claim(ADAPT)

-- ===== SETTINGS (defaults) =====
local S = {
	-- combat
	AutoFarm = false, BossFarm = false, KillAura = false, AuraRadius = 25,
	FastAttack = false, AttackSpeedMult = 3, BaseAttackInterval = 0.5,
	Hitbox = false, HitboxSize = 20,
	AutoParry = false, ParryRange = 15,
	AutoSkills = false, SkillKeys = "Z,X,C", SkillInterval = 2,
	AutoEquip = false, WeaponName = "",
	-- targeting
	Targets = "", BossNames = "Boss", TargetPriority = "nearest", -- nearest | lowest | highest | weakest
	-- never engaged even when they classify as an enemy (training dummies, townsfolk, mounts)
	ExcludeNames = "Civilian,statue,Horse,Dummy,Trainer,Trainee",
	AttackRange = 12, -- don't swing from further than this (a miss is a wasted, flaggable action)
	LeashRange = 120, -- give up on the current target once it gets this far away
	-- quests
	AutoQuest = false, QuestName = "", SideQuests = false, SideQuestName = "", QuestActionSeconds = 30,
	-- stats
	AutoStats = false, StatPriority = "Strength,Defense", PointReserve = 0,
	-- movement
	InstantTravel = false, TweenSpeed = 80, TweenSpeedVar = 0.15, TweenCurve = 0.6, TweenCurveMinDist = 12, FarmHeight = 0,
	Noclip = false, Flight = false, FlightSpeed = 60,
	-- loot
	AutoLoot = false, LootNames = "Drop,Loot", AutoChests = false, ChestNames = "Chest",
	AutoPickups = false, CollectRadius = 30, TravelToLoot = false,
	AutoSell = false, SellNames = "",
	-- visuals / utility
	ESP = false, ESPEnemies = true, ESPBosses = true, ESPNpcs = true, ESPLoot = true, ESPPrompts = true, ESPPlayers = true,
	ESPDistance = true, ESPMaxDist = 300,
	ESPRefresh = 0.5,       -- seconds between ESP refreshes (adornments update in place)
	ESPMaxHighlights = 30,  -- Roblox stops drawing Highlights past ~31; text labels still show
	UIScale = 1, UIOpacity = 0,
	Fullbright = false, AntiIdle = true,
	Humanize = true, HumanizeStrength = 0.15, Breaks = false, SmartFarm = true,
	ReactionMin = 0.25, ReactionMax = 0.75, FightDistance = 4,
	RetreatBelow = 0.35, ResumeAbove = 0.7,
	BreakMin = 20, BreakMax = 90, BreakEveryMin = 600, BreakEveryMax = 1320,
	LootDelay = 0.7, LootRange = 8,
	Speed = false, SpeedMult = 1.5, SpeedRamp = 4, FlightSmoothing = 3,
	ScanInterval = 1, -- seconds between world scans (raise on big maps if the client stutters)
	DebugState = false, Recovery = true, RecoverDelay = 3, MaxMinutes = 0, MaxActions = 0, -- 0 = unlimited
}
claim(S)

local counts: { [string]: number } = {}
local totalActions = 0
local startTime = os.clock()

local function bump(feature: string)
	counts[feature] = (counts[feature] or 0) + 1
	totalActions += 1
end

local function split(str: string): { string }
	local out = {}
	for part in string.gmatch(str, "[^,]+") do
		table.insert(out, (part:gsub("^%s+", ""):gsub("%s+$", "")))
	end
	return out
end

local function matches(name: string, list: { string }): boolean
	if #list == 0 then
		return true
	end
	local lower = name:lower()
	for _, n in list do
		if lower:find(n:lower(), 1, true) then
			return true
		end
	end
	return false
end

-- Resolves a remote by dotted path ("Folder.Sub.Event") or bare name (recursive search).
-- Misses are cached too: a bare-name miss costs a full recursive walk of ReplicatedStorage, and
-- without this the combat loop paid for that walk on every single frame.
local remoteCache: { [string]: Instance } = {}
local remoteMiss: { [string]: number } = {}
local REMOTE_RETRY = 5 -- seconds before re-searching for a name that wasn't found

local function remote(name: string): Instance?
	if name == "" then
		return nil
	end
	local hit = remoteCache[name]
	if hit and hit.Parent then
		return hit
	end
	remoteCache[name] = nil
	local missedAt = remoteMiss[name]
	if missedAt and os.clock() - missedAt < REMOTE_RETRY then
		return nil
	end
	local cur: Instance? = ReplicatedStorage
	for part in name:gmatch("[^%.]+") do
		cur = cur and cur:FindFirstChild(part)
	end
	local found = cur or ReplicatedStorage:FindFirstChild(name, true)
	if found then
		remoteCache[name] = found
		remoteMiss[name] = nil
		return found
	end
	remoteMiss[name] = os.clock()
	return nil
end

-- Fires a RemoteEvent, or invokes a RemoteFunction. This game routes a lot through
-- SignalFunction (a RemoteFunction), so event-only firing silently dropped those calls.
-- InvokeServer yields and can block forever if the server never replies, so it runs detached.
local function fire(name: string, ...): boolean
	local r = remote(name)
	if not r then
		return false
	end
	if r:IsA("RemoteEvent") or r:IsA("UnreliableRemoteEvent") then
		local ok = pcall(function(...)
			(r :: RemoteEvent):FireServer(...)
		end, ...)
		return ok
	elseif r:IsA("RemoteFunction") then
		task.spawn(function(...)
			pcall(function(...)
				(r :: RemoteFunction):InvokeServer(...)
			end, ...)
		end, ...)
		return true
	end
	return false
end

local function getRoot(): BasePart?
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getHum(): Humanoid?
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

-- ===== SCANNING (cached once per second) =====
local enemies: { Model } = {}
local lootItems: { Instance } = {}
local chestItems: { Instance } = {}
local pickupItems: { BasePart } = {}
local npcClassCount: { [string]: number } = {}
local otherNpcs: { Model } = {}
local promptItems: { ProximityPrompt } = {}
local scanCost = 0 -- ms spent in the last world scan, shown in the menu diagnostics

local function scan()
	local e, l, c, p, pr = {}, {}, {}, {}, {}
	table.clear(npcClassCount)
	local o: { Model } = {}
	local targets = split(S.Targets)
	local excluded = split(S.ExcludeNames)
	local lootN, chestN = split(S.LootNames), split(S.ChestNames)
	-- items are also collected when only the ESP wants to label them
	local wantLoot = S.AutoLoot or (S.ESP and S.ESPLoot)
	local wantChests = S.AutoChests or (S.ESP and S.ESPLoot)
	local wantPickups = S.AutoPickups or (S.ESP and S.ESPLoot)
	local wantPrompts = S.ESP and S.ESPPrompts
	for _, d in workspace:GetDescendants() do
		if d:IsA("Model") then
			local hum = d:FindFirstChildOfClass("Humanoid")
			if hum and not Players:GetPlayerFromCharacter(d) then
				local cls = GameState.classifyNPC(d)
				npcClassCount[cls] = (npcClassCount[cls] or 0) + 1
				-- combat only ever sees enemies; quest givers, merchants, guards etc. are skipped.
				-- ExcludeNames additionally drops things that classify as hostile but shouldn't be
				-- hit (townsfolk, training dummies, mounts) - attacking those is both useless and
				-- an obvious tell.
				local skip = #excluded > 0 and matches(d.Name, excluded)
				if cls == "enemy" and hum.Health > 0 and not skip and matches(d.Name, targets) then
					table.insert(e, d)
				elseif cls ~= "enemy" or skip then
					table.insert(o, d)
				end
			elseif not hum then
				if wantLoot and matches(d.Name, lootN) then
					table.insert(l, d)
				end
				if wantChests and matches(d.Name, chestN) then
					table.insert(c, d)
				end
			end
		elseif d:IsA("BasePart") then
			if wantLoot and matches(d.Name, lootN) and not d.Parent:IsA("Model") then
				table.insert(l, d)
			end
			if wantChests and matches(d.Name, chestN) and not d.Parent:IsA("Model") then
				table.insert(c, d)
			end
			if wantPickups and d:FindFirstChildOfClass("TouchTransmitter") then
				table.insert(p, d)
			end
		elseif wantPrompts and d:IsA("ProximityPrompt") then
			table.insert(pr, d)
		end
	end
	enemies, lootItems, chestItems, pickupItems, otherNpcs, promptItems = e, l, c, p, o, pr
end

local function rootOf(m: Instance): BasePart?
	if m:IsA("BasePart") then
		return m
	end
	if m:IsA("Model") then
		return m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

-- Target stickiness: a real player commits to one enemy until it dies or gets away. Re-picking
-- every frame makes two equidistant enemies flip-flop, so nothing ever actually dies - and
-- constant target switching is itself a strong automation signal.
local stickyTarget: Model? = nil

local function targetScore(m: Model, hum: Humanoid, r: BasePart, root: BasePart): number
	local mode = S.TargetPriority:lower()
	if mode == "lowest" then
		return hum.Health
	elseif mode == "highest" then
		return -hum.Health
	elseif mode == "weakest" then -- lowest absolute HP, then nearest as a tie-break
		return hum.Health * 1000 + (r.Position - root.Position).Magnitude
	end
	return (r.Position - root.Position).Magnitude -- "nearest" (default)
end

local function alive(m: Model?): (Humanoid?, BasePart?)
	if not (m and m.Parent) then
		return nil, nil
	end
	local hum = m:FindFirstChildOfClass("Humanoid")
	local r = rootOf(m)
	if hum and hum.Health > 0 and r then
		return hum, r
	end
	return nil, nil
end

local function pickTarget(bossOnly: boolean): Model?
	local root = getRoot()
	if not root then
		return nil
	end
	local bossN = split(S.BossNames)
	-- keep the current target while it is alive and still in range
	local sHum, sRoot = alive(stickyTarget)
	if sHum and sRoot and table.find(enemies, stickyTarget) then
		if (sRoot.Position - root.Position).Magnitude <= S.LeashRange
			and (not bossOnly or matches((stickyTarget :: Model).Name, bossN)) then
			return stickyTarget
		end
	end
	local best, bestScore = nil, math.huge
	for _, m in enemies do
		local hum, r = alive(m)
		if hum and r and (not bossOnly or matches(m.Name, bossN)) then
			local score = targetScore(m, hum, r, root)
			if score < bestScore then
				best, bestScore = m, score
			end
		end
	end
	stickyTarget = best
	return best
end

-- ===== HUMANIZATION =====
-- Real players are irregular: variable timing, curved paths, reaction delays.
-- These helpers add that, so tests exercise behavioural detection, not just
-- "is the value above a hard cap".
local rng = Random.new()
local lastCollect = 0

local function gauss(): number -- Box-Muller
	return math.sqrt(-2 * math.log(1 - rng:NextNumber())) * math.cos(2 * math.pi * rng:NextNumber())
end

local function human(base: number): number
	if not S.Humanize then
		return base
	end
	return math.max(base * 0.4, base * (1 + gauss() * S.HumanizeStrength))
end

-- ===== ACTIONS =====
-- Builds a CFrame at `pos` facing `lookAt` (flattened to the XZ plane, so the character stays
-- upright). Falls back to `fallback`'s rotation when there is nothing meaningful to face,
-- which matters because writing CFrame.new(pos) would silently drop all orientation.
local function facing(pos: Vector3, lookAt: Vector3?, fallback: CFrame): CFrame
	if lookAt then
		local flat = Vector3.new(lookAt.X - pos.X, 0, lookAt.Z - pos.Z)
		if flat.Magnitude > 0.05 then
			return CFrame.lookAt(pos, pos + flat.Unit)
		end
	end
	return CFrame.new(pos) * (fallback - fallback.Position) -- keep current rotation
end

-- `lookAt` keeps the character oriented at a point (normally the enemy) independently of the
-- direction of travel. Combat relies on this: the game's attack call carries no target, so the
-- server resolves hits from where the character is facing.
local function moveToward(goal: Vector3, dt: number, lookAt: Vector3?)
	local root = getRoot()
	if not root then
		return
	end
	if S.InstantTravel then
		root.CFrame = facing(goal, lookAt, root.CFrame)
	else
		local delta = goal - root.Position
		local speed = S.TweenSpeed
		local lateral = Vector3.zero
		if S.Humanize then
			-- smoothly varying speed and a gently curving path, never constant-velocity in a line
			local t = os.clock()
			local v = S.TweenSpeedVar
			speed = speed * math.max(0.1, 1 - v + v * math.sin(t * 1.3) + 0.3 * v * math.noise(t, 0.5))
			if delta.Magnitude > S.TweenCurveMinDist then
				lateral = delta.Unit:Cross(Vector3.yAxis) * math.sin(t * 0.9) * S.TweenCurve * dt * speed
			end
		end
		local step = speed * dt
		local pos = delta.Magnitude <= step and goal or root.Position + delta.Unit * step + lateral
		-- face the explicit target if given, else the direction of travel, else keep facing
		root.CFrame = facing(pos, lookAt or (delta.Magnitude > 0.1 and goal or nil), root.CFrame)
	end
	root.AssemblyLinearVelocity = Vector3.zero
end

-- Turns to face a target without moving (used when already in range).
local function faceTarget(at: Vector3)
	local root = getRoot()
	if root then
		root.CFrame = facing(root.Position, at, root.CFrame)
		root.AssemblyLinearVelocity = Vector3.zero
	end
end

-- Three ways to swing, tried in order, so the client works whether the game is remote-driven,
-- Tool-driven, or reads M1 in a local script. `attackMode` reports which one actually fired so
-- the menu can show it instead of leaving you guessing why nothing is dying.
local attackMode = "none"

local function attack(enemy: Model)
	if ADAPT.AttackRemote ~= "" then
		local args = ADAPT.BuildAttackArgs(enemy) :: any
		if fire(ADAPT.AttackRemote, table.unpack(args, 1, args.n or #args)) then
			attackMode = "remote"
			bump("attack")
			return
		end
	end
	local char = player.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if tool then
		tool:Activate()
		attackMode = "tool"
		bump("attack")
		return
	end
	-- Games that read M1 in a client combat script (no Tool, no known remote): click like a player.
	local cam = workspace.CurrentCamera
	if cam and pcall(function()
		local vim = game:GetService("VirtualInputManager")
		local c = cam.ViewportSize / 2
		vim:SendMouseButtonEvent(c.X, c.Y, 0, true, game, 0)
		vim:SendMouseButtonEvent(c.X, c.Y, 0, false, game, 0)
	end) then
		attackMode = "click"
		bump("attack")
		return
	end
	attackMode = "none"
end

local function collect(obj: Instance, feature: string, dt: number)
	local root, part = getRoot(), rootOf(obj)
	if not (root and part) then
		return
	end
	local dist = (part.Position - root.Position).Magnitude
	if dist > S.CollectRadius then
		return
	end
	if S.TravelToLoot and dist > 6 then
		moveToward(part.Position, dt)
	end
	if S.Humanize then
		-- one pickup at a time, spaced irregularly, and only when actually close
		if dist > S.LootRange or os.clock() - lastCollect < human(S.LootDelay) then
			return
		end
		lastCollect = os.clock()
	end
	local prompt = obj:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt and env.fireproximityprompt then
		env.fireproximityprompt(prompt)
		bump(feature)
	elseif env.firetouchinterest then
		env.firetouchinterest(root, part, 0)
		env.firetouchinterest(root, part, 1)
		bump(feature)
	end
end

-- ===== FEATURE STATE =====
local timers: { [string]: number } = {}
local function due(key: string, interval: number): boolean
	local now = os.clock()
	if now - (timers[key] or 0) >= interval then
		timers[key] = now
		return true
	end
	return false
end

-- like due(), but the gap after each firing is re-rolled so timing is never metronomic
local nextGap: { [string]: number } = {}
local function dueH(key: string, interval: number): boolean
	local now = os.clock()
	if now - (timers[key] or 0) >= (nextGap[key] or interval) then
		timers[key] = now
		nextGap[key] = human(interval)
		return true
	end
	return false
end

local origHitbox: { [BasePart]: Vector3 } = {}
local function restoreHitboxes()
	for part, size in origHitbox do
		if part.Parent then
			part.Size = size
			part.Transparency = 1
		end
	end
	table.clear(origHitbox)
end

local espFolder = Instance.new("Folder")
espFolder.Name = "ACMenuESP"
-- Pooled ESP adornments, keyed by the thing being labelled, so refreshes update in place.
type EspEntry = { bb: BillboardGui, label: TextLabel, hl: Highlight? }
local espPool: { [Instance]: EspEntry } = {}
local espSeen: { [Instance]: boolean } = {}
local espHighlights = 0

local function clearESP()
	for _, entry in espPool do
		entry.bb:Destroy()
		if entry.hl then
			entry.hl:Destroy()
		end
	end
	table.clear(espPool)
	table.clear(espSeen)
	espHighlights = 0
end
local flightBV: BodyVelocity? = nil
local lastFarmTarget: Model? = nil
local engageAt = 0
local lowHP = false
local breakUntil: number? = nil
local nextBreak = os.clock() + 600
local baseSpeed: number? = nil

-- Cleanup handlers registered by features that change world/character state. Switching a feature
-- off has to undo it: a half-reverted hitbox or a still-flying BodyVelocity silently poisons
-- every test that runs afterwards.
local cleanups: { () -> () } = {}
local function registerCleanup(fn: () -> ())
	table.insert(cleanups, fn)
end

local function runCleanups()
	for _, fn in cleanups do
		pcall(fn)
	end
end

local function stopAll()
	for k, v in S do
		local keep = k == "AntiIdle" or k == "Recovery" or k == "Humanize" or k == "SmartFarm"
			or (k:sub(1, 3) == "ESP" and k ~= "ESP") -- ESP filters stay as configured
		if v == true and not keep then
			S[k] = false
		end
	end
	stickyTarget = nil
	lastFarmTarget = nil
	runCleanups()
end
registerCleanup(restoreHitboxes)

-- ===== QUEST LOOP =====
-- FindNPC -> GoToNPC -> Accept -> Objective -> Act (locate + perform) -> detect
-- completion -> Return -> Claim -> next quest -> repeat
local Q = { state = "Check", idx = 1, npc = nil :: Instance?, obj = nil :: { kind: string, target: string }?,
	saved = nil :: { [string]: any }?, since = os.clock(), acting = false, name = "", kills = 0 }
local QUEST_KEYS = { "Targets", "AutoLoot", "LootNames", "TravelToLoot", "CollectRadius" }

local function setState(s: string)
	Q.state = s
	Q.since = os.clock()
	print("[ACMenu] quest state: " .. s)
end

local function questRestore()
	if Q.saved then
		for k, v in Q.saved do
			S[k] = v
		end
		Q.saved = nil
	end
	Q.acting = false
end

local function nextQuestName(): string?
	local list = {}
	if S.QuestName ~= "" then
		table.insert(list, S.QuestName)
	end
	if S.SideQuests and S.SideQuestName ~= "" then
		table.insert(list, S.SideQuestName)
	end
	if #list == 0 then
		-- Nothing configured: if a quest is already active, work that one. This lets auto-quest
		-- run with no setup at all as long as you have accepted something by hand.
		local marker = GameState.questMarkers().objective
		if marker then
			return marker
		end
		return nil
	end
	Q.idx = (Q.idx - 1) % #list + 1
	return list[Q.idx]
end

-- Finds the NPC for a quest, in descending order of confidence:
--   1. the name ADAPT.QuestNPCName gives, if it yields a non-empty name
--   2. an NPC the game itself is tracking in markergui (these are the ones with quest markers)
--   3. any NPC that classifies as a quest giver
local function findNPC(questName: string): Instance?
	local want: { string } = {}
	local named = ADAPT.QuestNPCName(questName)
	if named and named ~= "" then
		table.insert(want, named)
	end
	local marked = GameState.questMarkers().npcs
	local byMarker: Instance? = nil
	local fallback: Instance? = nil
	for _, d in workspace:GetDescendants() do
		if (d:IsA("Model") or d:IsA("BasePart")) and rootOf(d) and not Players:GetPlayerFromCharacter(d) then
			-- #want == 0 would make matches() return true for everything, so guard it
			if #want > 0 and matches(d.Name, want) then
				return d
			elseif not byMarker and #marked > 0 and matches(d.Name, marked) then
				byMarker = d
			elseif not fallback and d:IsA("Model") and d:FindFirstChildOfClass("Humanoid")
				and GameState.classifyNPC(d) == "quest" then
				fallback = d
			end
		end
	end
	return byMarker or fallback
end

local function interact(npc: Instance)
	local prompt = npc:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt and env.fireproximityprompt then
		env.fireproximityprompt(prompt)
	end
end

local function questStep(root: BasePart, dt: number)
	if not S.AutoQuest then
		if Q.saved or Q.state ~= "Check" then
			questRestore()
			setState("Check")
		end
		return
	end
	local elapsed = os.clock() - Q.since

	if Q.state == "Check" then
		-- Check current quest: resume one that's already active instead of re-accepting.
		local name = nextQuestName()
		if not name then
			return
		end
		Q.name = name
		if GameState.questProgress() then
			if ADAPT.IsQuestComplete(name) == true then
				Q.npc = findNPC(name)
				setState(Q.npc and "Return" or "FindNPC")
			else
				setState("Objective")
			end
		else
			setState("FindNPC")
		end

	elseif Q.state == "FindNPC" then
		local name = nextQuestName()
		if not name then
			return
		end
		Q.name = name
		if not due("questFind", 0.5) then
			return -- the NPC search walks the workspace, so don't run it every frame
		end
		Q.npc = findNPC(name)
		if Q.npc then
			setState("GoToNPC")
		elseif due("questWarn", 5) then
			warn("[ACMenu] Quest NPC not found: " .. ADAPT.QuestNPCName(name))
		end

	elseif Q.state == "GoToNPC" or Q.state == "Return" then
		local part = Q.npc and Q.npc.Parent and rootOf(Q.npc)
		if not part then
			setState("FindNPC")
			return
		end
		if (part.Position - root.Position).Magnitude > 7 then
			moveToward(part.Position + Vector3.new(0, 0, 4), dt)
		else
			setState(Q.state == "GoToNPC" and "Accept" or "Claim")
		end

	elseif Q.state == "Accept" then
		interact(Q.npc :: Instance)
		fire(ADAPT.AcceptQuestRemote, Q.name)
		bump("questAccept")
		setState("Objective")

	elseif Q.state == "Objective" then
		if elapsed < 0.7 then
			return -- let the server register the accept before reading the objective
		end
		local obj = ADAPT.GetObjective(Q.name)
		Q.obj = obj
		Q.kills = 0
		Q.saved = {}
		for _, k in QUEST_KEYS do
			Q.saved[k] = S[k]
		end
		if obj.kind == "collect" then
			S.AutoLoot, S.LootNames, S.TravelToLoot, S.CollectRadius = true, obj.target, true, 500
		else
			S.Targets = obj.target
		end
		Q.acting = obj.kind ~= "collect"
		setState("Act")

	elseif Q.state == "Act" then
		-- locate + perform: the main loop finds the target, moves and fights while
		-- Q.acting is set. Here we re-check the objective (quests can change stage)
		-- and progress, and either keep fighting or head back to claim.
		if due("questRecheck", 2) then
			local obj = ADAPT.GetObjective(Q.name)
			if Q.obj and (obj.kind ~= Q.obj.kind or obj.target ~= Q.obj.target) then
				Q.obj = obj
				if obj.kind == "collect" then
					S.AutoLoot, S.LootNames, S.TravelToLoot, S.CollectRadius = true, obj.target, true, 500
					Q.acting = false
				else
					S.AutoLoot = Q.saved and Q.saved.AutoLoot or false
					S.Targets = obj.target
					Q.acting = true
				end
			end
		end
		if not due("questCheck", 0.5) then
			return -- reading quest UI text is expensive, twice a second is plenty
		end
		local done = ADAPT.IsQuestComplete(Q.name)
		local needed = Q.obj and Q.obj.needed
		if done == nil and needed and Q.obj.kind == "kill" then
			-- no visible counter: fall back to our own kill tally ("Defeat 10" -> 10 kills)
			done = (Q.kills >= needed) or nil
		end
		if done == true or (done == nil and elapsed >= S.QuestActionSeconds) then
			questRestore()
			bump("questObjectiveDone")
			Q.npc = Q.npc or findNPC(Q.name) -- resumed quests never located the NPC
			setState(Q.npc and "Return" or "FindNPC")
		end

	elseif Q.state == "Claim" then
		if not Q.claimed then
			Q.claimed = true
			interact(Q.npc :: Instance)
			fire(ADAPT.CompleteQuestRemote, Q.name)
			bump("questClaim")
			Q.idx += 1
		elseif elapsed > 1 then
			Q.claimed = false
			setState("Check")
		end
	end
end

-- ===== MAIN LOOP =====
local function tick(dt: number, root: BasePart, hum: Humanoid)
	-- session limits
	if (S.MaxMinutes > 0 and os.clock() - startTime > S.MaxMinutes * 60)
		or (S.MaxActions > 0 and totalActions >= S.MaxActions) then
		if S.AutoFarm or S.KillAura or S.AutoLoot or S.AutoChests then
			warn("[ACMenu] Session limit reached, automation stopped")
			stopAll()
		end
	end

	-- humanized breaks: idle for a while every 10-22 minutes, like a person stepping away
	if S.Humanize and S.Breaks then
		local now = os.clock()
		if not breakUntil and now >= nextBreak then
			breakUntil = now + S.BreakMin + rng:NextNumber() * math.max(0, S.BreakMax - S.BreakMin)
			print(("[ACMenu] taking a break for %ds"):format(breakUntil - now))
		end
		if breakUntil then
			if now < breakUntil then
				return
			end
			breakUntil = nil
			nextBreak = now + S.BreakEveryMin + rng:NextNumber() * math.max(0, S.BreakEveryMax - S.BreakEveryMin)
		end
	end

	-- The world scan walks every descendant of workspace, which is the single most expensive
	-- thing this client does. Skip it entirely when no feature actually consumes the results.
	local needScan = S.AutoFarm or S.BossFarm or S.KillAura or S.AutoSkills or S.AutoParry
		or S.Hitbox or S.AutoLoot or S.AutoChests or S.AutoPickups or S.ESP or S.AutoQuest or Q.acting
	if needScan and due("scan", math.max(0.1, S.ScanInterval)) then
		local t0 = os.clock()
		scan()
		scanCost = (os.clock() - t0) * 1000
	elseif not needScan and #enemies > 0 then
		table.clear(enemies)
		table.clear(lootItems)
		table.clear(chestItems)
		table.clear(pickupItems)
		table.clear(otherNpcs)
		table.clear(promptItems)
	end

	-- speed: ramped a few studs/sec instead of jumping, so there's no single-frame spike
	if S.Speed then
		baseSpeed = baseSpeed or hum.WalkSpeed
		local target = baseSpeed * S.SpeedMult
		hum.WalkSpeed = S.Humanize and (hum.WalkSpeed + math.clamp(target - hum.WalkSpeed, -S.SpeedRamp * dt, S.SpeedRamp * dt)) or target
	elseif baseSpeed then
		hum.WalkSpeed = baseSpeed
		baseSpeed = nil
	end


	-- weapon equip
	if S.AutoEquip and due("equip", 1) and not hum.Parent:FindFirstChildOfClass("Tool") then
		for _, t in player.Backpack:GetChildren() do
			if t:IsA("Tool") and (S.WeaponName == "" or t.Name:lower():find(S.WeaponName:lower(), 1, true)) then
				hum:EquipTool(t)
				bump("equip")
				break
			end
		end
	end

	-- hitbox expander
	if S.Hitbox then
		for _, m in enemies do
			local r = m:FindFirstChild("HumanoidRootPart") :: BasePart?
			if r then
				origHitbox[r] = origHitbox[r] or r.Size
				r.Size = Vector3.one * S.HitboxSize
				r.Transparency = 0.7
				r.CanCollide = false
			end
		end
	elseif next(origHitbox) then
		restoreHitboxes()
	end

	-- combat target selection
	local interval = S.BaseAttackInterval / (S.FastAttack and math.max(S.AttackSpeedMult, 0.01) or 1)
	local farmTarget: Model? = nil
	if S.BossFarm then
		farmTarget = pickTarget(true)
	end
	if not farmTarget and (S.AutoFarm or Q.acting) then
		farmTarget = pickTarget(false)
	end

	-- smart farm: back off at low HP and resume once recovered, like a player would
	if S.SmartFarm then
		if hum.Health < hum.MaxHealth * S.RetreatBelow then
			lowHP = true
		elseif hum.Health > hum.MaxHealth * S.ResumeAbove then
			lowHP = false
		end
		if lowHP then
			farmTarget = nil
		end
	end

	-- kill tally: the previous target counts as a kill once it dies or disappears
	if lastFarmTarget and lastFarmTarget ~= farmTarget then
		local h = lastFarmTarget:FindFirstChildOfClass("Humanoid")
		if not lastFarmTarget.Parent or not h or h.Health <= 0 then
			Q.kills += 1
			bump("kill")
		end
	end
	if farmTarget ~= lastFarmTarget then
		-- reaction delay before engaging a new target
		engageAt = os.clock() + (S.Humanize and (S.ReactionMin + rng:NextNumber() * math.max(0, S.ReactionMax - S.ReactionMin)) or 0)
	end
	lastFarmTarget = farmTarget

	if farmTarget and os.clock() >= engageAt then
		local r = rootOf(farmTarget)
		if r then
			-- approach from our own side: FightDistance studs out, FarmHeight studs up
			local away = root.Position - r.Position
			local flat = Vector3.new(away.X, 0, away.Z)
			local spot = r.Position + (flat.Magnitude > 0.1 and flat.Unit or Vector3.zAxis) * S.FightDistance
			local goal = Vector3.new(spot.X, r.Position.Y + S.FarmHeight, spot.Z)
			-- always face the enemy: the attack call carries no target, so the server
			-- decides what was hit from facing and range
			if (root.Position - goal).Magnitude > 0.5 then
				moveToward(goal, dt, r.Position)
			else
				faceTarget(r.Position)
			end
			-- Range is checked BEFORE dueH: dueH consumes its timer when it returns true, so
			-- testing it first would silently eat swings while still closing the distance.
			if (r.Position - root.Position).Magnitude <= S.AttackRange and dueH("farmAttack", interval) then
				attack(farmTarget)
				bump("farm")
			end
		end
	end

	-- kill aura
	if S.KillAura and dueH("aura", interval) then
		for _, m in enemies do
			local r = rootOf(m)
			if r and (r.Position - root.Position).Magnitude <= S.AuraRadius then
				if S.Humanize then
					-- one target per swing, and turn to it first: a swing that lands on something
					-- behind you is exactly the tell a server-side facing check looks for
					faceTarget(r.Position)
					attack(m)
					bump("aura")
					break
				end
				attack(m)
				bump("aura")
			end
		end
	end

	-- auto skills
	if S.AutoSkills and dueH("skills", S.SkillInterval) and #enemies > 0 then
		local keys = split(S.SkillKeys)
		if S.Humanize and #keys > 1 then
			keys = { keys[rng:NextInteger(1, #keys)] } -- one skill at a time, in varying order
		end
		for _, key in keys do
			if ADAPT.SkillRemote ~= "" then
				fire(ADAPT.SkillRemote, key)
			else
				local vim = game:GetService("VirtualInputManager")
				local kc = Enum.KeyCode[key:upper()]
				if kc then
					vim:SendKeyEvent(true, kc, false, game)
					vim:SendKeyEvent(false, kc, false, game)
				end
			end
			bump("skill")
		end
	end

	-- auto parry: fires when a nearby enemy starts playing a new animation
	if S.AutoParry then
		for _, m in enemies do
			local r = rootOf(m)
			local animator = m:FindFirstChildWhichIsA("Animator", true)
			if r and animator and (r.Position - root.Position).Magnitude <= S.ParryRange then
				for _, track in animator:GetPlayingAnimationTracks() do
					if track.TimePosition < 0.15 and due("parry" .. m.Name, 0.4) then
						fire(ADAPT.ParryRemote)
						bump("parry")
					end
				end
			end
		end
	end

	-- quests
	questStep(root, dt) -- every frame so quest travel is smooth, not 0.2s hops

	-- auto stats: spends points into the first priority stat, keeping the reserve
	if S.AutoStats and ADAPT.StatRemote ~= "" and due("stats", 1) then
		local spendable = ADAPT.GetStatPoints() - S.PointReserve
		local priorities = split(S.StatPriority)
		if spendable > 0 and #priorities > 0 then
			local stat = priorities[(counts.stat or 0) % #priorities + 1]
			fire(ADAPT.StatRemote, stat, 1)
			bump("stat")
		end
	end

	-- collection
	if S.AutoLoot then
		for _, o in lootItems do
			if o.Parent then
				collect(o, "loot", dt)
			end
		end
	end
	if S.AutoChests then
		for _, o in chestItems do
			if o.Parent then
				collect(o, "chest", dt)
			end
		end
	end
	if S.AutoPickups then
		for _, o in pickupItems do
			if o.Parent then
				collect(o, "pickup", dt)
			end
		end
	end
	if S.AutoSell and ADAPT.SellRemote ~= "" and due("sell", 3) then
		local names = split(S.SellNames)
		for _, t in player.Backpack:GetChildren() do
			if #names > 0 and matches(t.Name, names) then
				fire(ADAPT.SellRemote, t.Name)
				bump("sell")
			end
		end
	end

	-- flight
	if S.Flight then
		if not flightBV or not flightBV.Parent then
			flightBV = Instance.new("BodyVelocity")
			flightBV.MaxForce = Vector3.new(1e6, 1e6, 1e6)
			flightBV.Parent = root
		end
		local cam = workspace.CurrentCamera
		local dir = Vector3.zero
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += cam.CFrame.LookVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= cam.CFrame.LookVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= cam.CFrame.RightVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += cam.CFrame.RightVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
		local want = dir.Magnitude > 0 and dir.Unit * S.FlightSpeed or Vector3.zero
		-- humanized flight accelerates and decelerates instead of snapping to full speed
		flightBV.Velocity = S.Humanize and flightBV.Velocity:Lerp(want, math.min(1, dt * S.FlightSmoothing)) or want
		if due("flightCount", 1) then
			bump("flight")
		end
	elseif flightBV then
		flightBV:Destroy()
		flightBV = nil
	end

	-- ESP
	if S.ESP then
		espFolder.Parent = workspace.CurrentCamera
		if due("esp", S.ESPRefresh) then
			local bossN = split(S.BossNames)
			table.clear(espSeen)
			-- Adornments are pooled and updated in place. Rebuilding them every refresh (the old
			-- behaviour) created and destroyed hundreds of instances per second on a populated
			-- map, which churned the GC and made every label visibly flicker.
			local function mark(target: Instance, color: Color3, label: string, highlight: boolean)
				local r = rootOf(target)
				if not r then
					return
				end
				local dist = (r.Position - root.Position).Magnitude
				if S.ESPMaxDist > 0 and dist > S.ESPMaxDist then
					return
				end
				espSeen[target] = true
				local entry = espPool[target]
				if not entry then
					local bb = Instance.new("BillboardGui")
					bb.AlwaysOnTop = true
					bb.Size = UDim2.fromOffset(220, 18)
					bb.StudsOffset = Vector3.new(0, 4, 0)
					local tl = Instance.new("TextLabel")
					tl.Size = UDim2.fromScale(1, 1)
					tl.BackgroundTransparency = 1
					tl.TextStrokeTransparency = 0.4
					tl.Font = Enum.Font.GothamBold
					tl.TextSize = 12
					tl.Parent = bb
					bb.Parent = espFolder
					entry = { bb = bb, label = tl, hl = nil }
					espPool[target] = entry
				end
				entry.bb.Adornee = r
				entry.label.Text = S.ESPDistance and ("%s [%dm]"):format(label, dist) or label
				entry.label.TextColor3 = color
				-- Roblox renders a limited number of Highlights (~31); past that they silently
				-- stop drawing, so they go to the nearest things and text carries the rest.
				local wantHl = highlight and espHighlights < S.ESPMaxHighlights
				if wantHl and not entry.hl then
					local h = Instance.new("Highlight")
					h.Adornee = target
					h.Parent = espFolder
					entry.hl = h
				elseif not wantHl and entry.hl then
					entry.hl:Destroy()
					entry.hl = nil
				end
				if entry.hl then
					entry.hl.FillColor = color
					entry.hl.OutlineColor = color
					espHighlights += 1
				end
			end
			espHighlights = 0
			for _, m in enemies do
				local hp = m:FindFirstChildOfClass("Humanoid")
				local hpText = hp and (" %d/%d"):format(hp.Health, hp.MaxHealth) or ""
				if #bossN > 0 and matches(m.Name, bossN) then
					if S.ESPBosses then
						mark(m, Color3.fromRGB(255, 160, 40), "BOSS " .. m.Name .. hpText, true)
					end
				elseif S.ESPEnemies then
					mark(m, Color3.fromRGB(255, 60, 60), m.Name .. hpText, true)
				end
			end
			if S.ESPNpcs then
				local classColors = {
					quest = Color3.fromRGB(255, 230, 80), merchant = Color3.fromRGB(80, 230, 130),
					blacksmith = Color3.fromRGB(180, 180, 200), guard = Color3.fromRGB(100, 140, 255),
				}
				for _, n in otherNpcs do
					local cls = GameState.classifyNPC(n)
					mark(n, classColors[cls] or Color3.fromRGB(150, 150, 150), ("%s [%s]"):format(n.Name, cls), true)
				end
			end
			if S.ESPLoot then
				for _, o in lootItems do
					mark(o, Color3.fromRGB(120, 255, 200), "Loot: " .. o.Name, false)
				end
				for _, o in chestItems do
					mark(o, Color3.fromRGB(255, 210, 90), "Chest: " .. o.Name, false)
				end
				for _, o in pickupItems do
					mark(o, Color3.fromRGB(150, 220, 255), "Pickup: " .. o.Name, false)
				end
			end
			if S.ESPPrompts then
				for _, pr in promptItems do
					local holder = pr.Parent
					local part = holder and (holder:IsA("Attachment") and holder.Parent or holder)
					if part and part:IsA("BasePart") and pr.Enabled then
						-- NPC prompts are already labelled above by their model
						local model = part:FindFirstAncestorOfClass("Model")
						if not (model and model:FindFirstChildOfClass("Humanoid")) then
							local text = (pr.ActionText .. " " .. pr.ObjectText):match("^%s*(.-)%s*$")
							mark(part, Color3.fromRGB(255, 190, 255), "[E] " .. (text ~= "" and text or part.Name), false)
						end
					end
				end
			end
			if S.ESPPlayers then
				for _, p in Players:GetPlayers() do
					if p ~= player and p.Character then
						local h = p.Character:FindFirstChildOfClass("Humanoid")
						mark(p.Character, Color3.fromRGB(60, 160, 255), h and ("%s %d/%d"):format(p.Name, h.Health, h.MaxHealth) or p.Name, true)
					end
				end
			end
			-- sweep: drop adornments for anything that died, despawned or went out of range
			for target, entry in espPool do
				if not espSeen[target] then
					entry.bb:Destroy()
					if entry.hl then
						entry.hl:Destroy()
					end
					espPool[target] = nil
				end
			end
		end
	else
		if next(espPool) then
			clearESP()
		end
		espFolder.Parent = nil
	end
end

-- The tick is wrapped so a single failing feature (usually an instance destroyed mid-frame)
-- cannot abort every feature after it, which previously happened on every frame once anything
-- started erroring. Errors are reported at most once every few seconds instead of 60x/second.
RunService.Heartbeat:Connect(function(dt)
	if revoked then
		return
	end
	local root, hum = getRoot(), getHum()
	if not (root and hum) or hum.Health <= 0 then
		return
	end
	local ok, err = pcall(tick, dt, root, hum)
	if not ok and due("tickError", 3) then
		warn("[AC] main loop error (features continue): " .. tostring(err))
	end
end)

-- Noclip runs on Stepped so it lands before physics. Only parts that were actually colliding are
-- touched, and they are restored when it is switched off - previously the character stayed
-- non-solid until the next respawn, which quietly contaminated every later movement test.
local noclipped: { [BasePart]: boolean } = {}
local function restoreNoclip()
	for part in noclipped do
		if part.Parent then
			part.CanCollide = true
		end
	end
	table.clear(noclipped)
end

RunService.Stepped:Connect(function()
	if revoked then
		return
	end
	if S.Noclip then
		local char = player.Character
		if char then
			for _, p in char:GetDescendants() do
				if p:IsA("BasePart") and p.CanCollide then
					noclipped[p] = true
					p.CanCollide = false
				end
			end
		end
	elseif next(noclipped) then
		restoreNoclip()
	end
end)

-- Fullbright, with the original lighting captured once so it can be put back.
local origLighting: { [string]: any }? = nil
local function restoreLighting()
	if origLighting then
		for k, v in origLighting do
			pcall(function()
				(Lighting :: any)[k] = v
			end)
		end
		origLighting = nil
	end
end

task.spawn(function()
	while task.wait(1) do
		if revoked then
			break
		end
		if S.Fullbright then
			if not origLighting then
				origLighting = {
					Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime,
					FogEnd = Lighting.FogEnd, GlobalShadows = Lighting.GlobalShadows,
					Ambient = Lighting.Ambient,
				}
			end
			Lighting.Brightness = 2
			Lighting.ClockTime = 14
			Lighting.FogEnd = 1e6
			Lighting.GlobalShadows = false
			Lighting.Ambient = Color3.new(1, 1, 1)
		elseif origLighting then
			restoreLighting()
		end
	end
end)

registerCleanup(restoreNoclip)
registerCleanup(restoreLighting)
registerCleanup(function()
	if flightBV then
		flightBV:Destroy()
		flightBV = nil
	end
end)
registerCleanup(function()
	espFolder:ClearAllChildren()
	espFolder.Parent = nil
end)
registerCleanup(function()
	local hum = getHum()
	if hum and baseSpeed then
		hum.WalkSpeed = baseSpeed
	end
	baseSpeed = nil
end)

-- Revoking test mode must leave the character exactly as it was found.
table.insert(teardown, function()
	stopAll()
	runCleanups()
end)

-- anti-idle
player.Idled:Connect(function()
	if S.AntiIdle then
		local vu = game:GetService("VirtualUser")
		vu:CaptureController()
		vu:ClickButton2(Vector2.zero)
		bump("antiidle")
	end
end)

-- recovery: after respawn, wait, then features resume on their own since every
-- loop reads the live character; we only need to re-equip and reset state.
player.CharacterAdded:Connect(function()
	if S.Recovery then
		bump("recovery")
		task.wait(S.RecoverDelay)
		-- The old character took its BodyVelocity and WalkSpeed with it; keeping the stale
		-- baseSpeed would later "restore" the new character to the wrong value.
		flightBV = nil
		baseSpeed = nil
		table.clear(noclipped)
		table.clear(timers)
		print("[ACMenu] Respawned, automation resumed")
	end
end)

-- ===== SAVED CONFIGS =====
-- Saves the feature settings, the per-game remote hookups (ADAPT) and the tester parameters.
-- Previously only S was persisted, so the remote names and every test threshold were lost on
-- reload - the settings that take the longest to work out.
local CONFIG_FILE = "ACMenu_config.json"

-- Only plain scalars round-trip through JSON; ADAPT also holds functions, which are skipped.
local function scalarsOf(t: { [string]: any }): { [string]: any }
	local out = {}
	for k, v in t do
		local ty = typeof(v)
		if ty == "string" or ty == "number" or ty == "boolean" then
			out[k] = v
		end
	end
	return out
end

local function applyScalars(into: { [string]: any }, from: any)
	if type(from) ~= "table" then
		return
	end
	for k, v in from do
		if into[k] ~= nil and typeof(into[k]) == typeof(v) then
			into[k] = v
		end
	end
end

local function saveConfig()
	if not env.writefile then
		warn("[ACMenu] writefile unavailable (needs an executor)")
		return
	end
	local ok, err = pcall(function()
		env.writefile(CONFIG_FILE, HttpService:JSONEncode({
			version = 2,
			settings = scalarsOf(S),
			adapt = scalarsOf(ADAPT),
			tester = scalarsOf(testApi.CONFIG),
			-- kept separately: scalarsOf drops tables, and this list is worth persisting
			remoteNames = testApi.CONFIG.RemoteNames,
		}))
	end)
	print(ok and "[ACMenu] Config saved (settings + hookups + test parameters)"
		or ("[ACMenu] Config save failed: " .. tostring(err)))
end

local function loadConfig(refresh: () -> ())
	if not (env.isfile and env.isfile(CONFIG_FILE)) then
		warn("[ACMenu] No saved config found")
		return
	end
	local ok, data = pcall(function()
		return HttpService:JSONDecode(env.readfile(CONFIG_FILE))
	end)
	if not (ok and type(data) == "table") then
		warn("[ACMenu] Saved config unreadable, ignoring")
		return
	end
	if data.version == nil then
		applyScalars(S, data) -- v1 files were a bare settings table
	else
		applyScalars(S, data.settings)
		applyScalars(ADAPT, data.adapt)
		applyScalars(testApi.CONFIG, data.tester)
		if type(data.remoteNames) == "table" then
			local names = {}
			for _, n in data.remoteNames do
				if type(n) == "string" then
					table.insert(names, n)
				end
			end
			testApi.CONFIG.RemoteNames = names
		end
	end
	refresh()
	print("[ACMenu] Config loaded")
end

-- ===== MENU =====
local function buildMenu()
	local C = {
		bg = Color3.fromRGB(24, 24, 30),
		side = Color3.fromRGB(30, 30, 38),
		bar = Color3.fromRGB(40, 40, 52),
		row = Color3.fromRGB(38, 38, 48),
		field = Color3.fromRGB(55, 55, 70),
		accent = Color3.fromRGB(70, 60, 120),
		text = Color3.fromRGB(230, 230, 230),
		dim = Color3.fromRGB(150, 150, 165),
		good = Color3.fromRGB(110, 255, 140),
		bad = Color3.fromRGB(255, 110, 110),
		warn = Color3.fromRGB(255, 210, 110),
	}

	local function mk(class: string, props: { [string]: any }, parent: Instance?): any
		local inst = Instance.new(class)
		for k, v in props do
			inst[k] = v
		end
		inst.Parent = parent
		return inst
	end

	local function button(parent: Instance, text: string, pos: UDim2, size: UDim2, cb: () -> ()): TextButton
		local b = mk("TextButton", {
			Position = pos, Size = size, BackgroundColor3 = C.accent, BorderSizePixel = 0,
			TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 12, Text = text,
		}, parent)
		b.MouseButton1Click:Connect(cb)
		return b
	end

	local function scroller(parent: Instance, pos: UDim2, size: UDim2): ScrollingFrame
		local sf = mk("ScrollingFrame", {
			Position = pos, Size = size, BackgroundTransparency = 1, BorderSizePixel = 0,
			CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 5,
		}, parent)
		mk("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, sf)
		mk("UIPadding", {
			PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
		}, sf)
		return sf
	end

	local function textRow(parent: Instance, h: number, text: string, color: Color3?, order: number?): TextLabel
		return mk("TextLabel", {
			Size = UDim2.new(1, 0, 0, h), BackgroundColor3 = C.row, BorderSizePixel = 0, LayoutOrder = order or 0,
			Text = text, TextColor3 = color or C.text, Font = Enum.Font.Gotham, TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
		}, parent)
	end

	-- ===== window =====
	local gui = mk("ScreenGui", { Name = "ACMenu", ResetOnSpawn = false }, (env.gethui and env.gethui()) or player:WaitForChild("PlayerGui"))
	local frame = mk("Frame", {
		Size = UDim2.fromOffset(740, 500), Position = UDim2.fromOffset(20, 60),
		BackgroundColor3 = C.bg, BorderSizePixel = 0, Active = true,
	}, gui)

	local header = mk("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = C.bar, BorderSizePixel = 0 }, frame)

	-- Dragging by the header. GuiObject.Draggable is deprecated, and it also let the window be
	-- pulled fully off-screen with no way back; this keeps a strip of the title bar reachable.
	local function makeDraggable(handle: GuiObject, target: GuiObject)
		local dragging, startPos, startMouse = false, Vector2.zero, Vector2.zero
		local function clamp(x: number, y: number): UDim2
			local cam = workspace.CurrentCamera
			local view = cam and cam.ViewportSize or Vector2.new(1920, 1080)
			local w, h = target.AbsoluteSize.X, target.AbsoluteSize.Y
			return UDim2.fromOffset(
				math.clamp(x, -w + 80, view.X - 80),
				math.clamp(y, 0, math.max(0, view.Y - math.min(h, 30)))
			)
		end
		handle.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				startPos = Vector2.new(target.Position.X.Offset, target.Position.Y.Offset)
				startMouse = Vector2.new(input.Position.X, input.Position.Y)
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch) then
				local d = Vector2.new(input.Position.X, input.Position.Y) - startMouse
				target.Position = clamp(startPos.X + d.X, startPos.Y + d.Y)
			end
		end)
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
	end
	makeDraggable(header, frame)
	mk("TextLabel", {
		Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0.5, 0, 1, 0), BackgroundTransparency = 1,
		Text = "AC Test Lab  (RightShift hides)", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold,
		TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left,
	}, header)
	mk("TextLabel", {
		Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(0.5, -70, 1, 0), BackgroundTransparency = 1,
		Text = ("● Test mode: %s"):format(RunService:IsStudio() and "Studio" or "private server"),
		TextColor3 = C.good, Font = Enum.Font.GothamBold, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right,
	}, header)

	local sidebar = mk("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 30), Size = UDim2.new(0, 130, 1, -54), BackgroundColor3 = C.side, BorderSizePixel = 0,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 3,
	}, frame)
	mk("UIListLayout", { Padding = UDim.new(0, 2) }, sidebar)
	mk("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }, sidebar)
	local content = mk("Frame", { Position = UDim2.fromOffset(130, 30), Size = UDim2.new(1, -130, 1, -54), BackgroundTransparency = 1 }, frame)

	local statusBar = mk("Frame", { Position = UDim2.new(0, 0, 1, -24), Size = UDim2.new(1, 0, 0, 24), BackgroundColor3 = C.bar, BorderSizePixel = 0 }, frame)
	local statusLbl = mk("TextLabel", {
		Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0.5, -10, 1, 0), BackgroundTransparency = 1,
		Text = "Ready", TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
	}, statusBar)
	local stats = mk("TextLabel", {
		Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(0.5, -10, 1, 0), BackgroundTransparency = 1,
		TextColor3 = C.dim, Font = Enum.Font.Code, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd,
	}, statusBar)

	-- close (hide) and minimize; a small "AC" tab reopens the menu, RightShift also toggles it
	local reopen = mk("TextButton", {
		Size = UDim2.fromOffset(40, 24), Position = UDim2.fromOffset(20, 60), BackgroundColor3 = C.accent, BorderSizePixel = 0,
		Text = "AC", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 13, Visible = false,
		Active = true,
	}, gui)
	makeDraggable(reopen, reopen)
	local function setOpen(open: boolean)
		frame.Visible = open
		reopen.Visible = not open
	end
	reopen.MouseButton1Click:Connect(function()
		setOpen(true)
	end)
	local minimized = false
	local fullSize = frame.Size
	local minBtn = mk("TextButton", {
		Position = UDim2.new(1, -60, 0, 3), Size = UDim2.fromOffset(24, 24), BackgroundColor3 = C.field, BorderSizePixel = 0,
		Text = "–", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 16,
	}, header)
	local closeBtn = mk("TextButton", {
		Position = UDim2.new(1, -30, 0, 3), Size = UDim2.fromOffset(24, 24), BackgroundColor3 = Color3.fromRGB(150, 60, 60), BorderSizePixel = 0,
		Text = "X", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 13,
	}, header)
	minBtn.MouseButton1Click:Connect(function()
		minimized = not minimized
		sidebar.Visible = not minimized
		content.Visible = not minimized
		statusBar.Visible = not minimized
		frame.Size = minimized and UDim2.new(fullSize.X.Scale, fullSize.X.Offset, 0, 30) or fullSize
		minBtn.Text = minimized and "+" or "–"
	end)
	closeBtn.MouseButton1Click:Connect(function()
		setOpen(false)
	end)

	-- ===== tabs =====
	local pages: { [string]: Frame } = {}
	local tabButtons: { [string]: TextButton } = {}
	local function showTab(name: string)
		for n, p in pages do
			p.Visible = n == name
			tabButtons[n].BackgroundColor3 = n == name and C.accent or C.side
		end
	end
	local function addTab(name: string, text: string): Frame
		local p = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, content)
		pages[name] = p
		local b = mk("TextButton", {
			Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = C.side, BorderSizePixel = 0, Text = text,
			TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
		}, sidebar)
		mk("UIPadding", { PaddingLeft = UDim.new(0, 8) }, b)
		b.MouseButton1Click:Connect(function()
			showTab(name)
		end)
		tabButtons[name] = b
		return p
	end

	local pHome = addTab("Home", "🏠 Home")
	local pCombat = addTab("Combat", "⚔ Combat")
	local pQuests = addTab("Quests", "📜 Quests")
	local pBosses = addTab("Bosses", "👑 Bosses")
	local pLoot = addTab("Loot", "🎁 Loot")
	local pEsp = addTab("ESP", "👁 ESP")
	local pMoveset = addTab("Movement", "🏃 Movement")
	local pSet = addTab("Settings", "⚙ Settings")
	-- anti-cheat testing tabs
	local pTests = addTab("Tests", "🧪 Tests")
	local pMove = addTab("MoveTests", "🏃 Move tests")
	local pAuto = addTab("Automation", "🤖 Automation")
	local pDet = addTab("Detections", "🛰 Detections")
	local pRes = addTab("Results", "📊 Results")
	local pRem = addTab("Remotes", "🔌 Remotes")

	local function setStatus(text: string)
		statusLbl.Text = text
	end

	-- ===== results / export =====
	local runCaught, runTotal, sessionFlags = 0, 0, 0
	local function updateSummary()
		setStatus(("Last run: %d/%d caught • flags this session: %d"):format(runCaught, runTotal, sessionFlags))
	end

	local function exportResults()
		local out = {}
		for _, r in testApi.results do
			table.insert(out, { test = r.key, name = r.name, detected = r.detected, note = r.note })
		end
		local json = HttpService:JSONEncode(out)
		if env.writefile then
			pcall(env.writefile, "ACResults.json", json)
		end
		if env.setclipboard then
			pcall(env.setclipboard, json)
		end
		print("[ACTest] results JSON: " .. json)
		setStatus(("Exported %d results (output%s%s)"):format(#out, env.writefile and ", ACResults.json" or "", env.setclipboard and ", clipboard" or ""))
	end

	local function actionRow(parent: Instance, defs: { { string | (() -> ()) } }, order: number?): Frame
		local holder = mk("Frame", { Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, LayoutOrder = order or 0 }, parent)
		local n = #defs
		for i, d in defs do
			button(holder, d[1] :: string, UDim2.new((i - 1) / n, 2, 0, 0), UDim2.new(1 / n, -4, 1, 0), d[2] :: () -> ())
		end
		return holder
	end

	-- ===== test rows (badges update from testApi.listeners) =====
	local badges: { [string]: TextLabel } = {}
	local toggleButtons: { [string]: TextButton } = {}
	local pendingToggle = ""
	local function testRow(parent: Instance, key: string, label: string, canToggle: boolean?)
		local r = mk("Frame", { Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = C.row, BorderSizePixel = 0 }, parent)
		mk("TextLabel", {
			Position = UDim2.fromOffset(6, 0), Size = UDim2.new(canToggle and 0.28 or 0.34, -6, 1, 0), BackgroundTransparency = 1, Text = label,
			TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, r)
		local badgeX = 0.5
		if canToggle then
			button(r, "Run", UDim2.fromScale(0.29, 0.1), UDim2.new(0.1, 0, 0.8, 0), function()
				task.spawn(runTests, key)
			end)
			toggleButtons[key] = button(r, "Toggle", UDim2.fromScale(0.4, 0.1), UDim2.new(0.13, 0, 0.8, 0), function()
				if not testApi.isBusy() then
					pendingToggle = key
				end
				testApi.toggle(key)
			end)
			badgeX = 0.55
		else
			button(r, "Run", UDim2.fromScale(0.35, 0.1), UDim2.new(0.12, 0, 0.8, 0), function()
				task.spawn(runTests, key)
			end)
		end
		badges[key] = mk("TextLabel", {
			Position = UDim2.fromScale(badgeX, 0), Size = UDim2.fromScale(1 - badgeX, 1), BackgroundTransparency = 1, Text = "not run",
			TextColor3 = C.dim, Font = Enum.Font.Code, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, r)
	end

	-- Tests tab
	local tList = scroller(pTests, UDim2.new(), UDim2.new(1, 0, 1, -36))
	textRow(tList, 20, "Basic exploit simulations", C.dim)
	for _, t in {
		{ "speed", "WalkSpeed hack" }, { "jump", "JumpPower hack" }, { "teleport", "Teleport hack" },
		{ "fly", "Fly (BodyVelocity)" }, { "noclip", "Noclip" }, { "health", "Health / MaxHealth" },
	} do
		testRow(tList, t[1], t[2])
	end
	actionRow(pTests, {
		{ "Run all", function() task.spawn(runTests, "all") end },
		{ "Export results", exportResults },
	}, 0).Position = UDim2.new(0, 6, 1, -32)

	-- Movement tab
	local mList = scroller(pMove, UDim2.new(), UDim2.new(1, 0, 1, 0))
	local capsRow = textRow(mList, 34, "Subtle movement near your thresholds.", C.dim)
	-- Read the live thresholds the server publishes, so this never drifts out of date when
	-- AntiCheatServer's CONFIG is tuned.
	local function refreshCaps()
		local parts = {}
		for _, k in { "MaxWalkSpeed", "MaxSpeedStuds", "MaxTeleport", "MaxAirRise" } do
			local v = ReplicatedStorage:GetAttribute("ACLimit_" .. k)
			if v ~= nil then
				table.insert(parts, ("%s %s"):format(k:gsub("^Max", ""), tostring(v)))
			end
		end
		capsRow.Text = #parts > 0
			and ("Subtle movement near your thresholds. Your published caps: " .. table.concat(parts, ", "))
			or "Subtle movement near your thresholds. Your anti-cheat has not published any caps - "
				.. "call Bridge.setLimits{...} in ACTestBridge to show them here."
	end
	refreshCaps()
	task.spawn(function()
		task.wait(3) -- attributes may arrive after the menu builds
		pcall(refreshCaps)
	end)
	for _, t in { { "human_speed", "Humanized speed" }, { "human_hops", "Short-hop teleport" }, { "human_fly", "Slow burst fly" } } do
		testRow(mList, t[1], t[2], true)
	end
	textRow(mList, 20, "Parameters", C.dim)
	local function numRow(parent: Instance, label: string, tbl: { [string]: any }, key: string)
		local holder = mk("Frame", { Size = UDim2.new(1, 0, 0, 24), BackgroundColor3 = C.row, BorderSizePixel = 0 }, parent)
		mk("TextLabel", {
			Position = UDim2.fromOffset(6, 0), Size = UDim2.new(0.55, -6, 1, 0), BackgroundTransparency = 1, Text = label,
			TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
		}, holder)
		local box = mk("TextBox", {
			Position = UDim2.fromScale(0.55, 0), Size = UDim2.fromScale(0.45, 1), BackgroundColor3 = C.field, ClearTextOnFocus = false,
			Text = tostring(tbl[key]), TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Gotham, TextSize = 12,
		}, holder)
		box.FocusLost:Connect(function()
			local n = tonumber(box.Text)
			if n then
				tbl[key] = n
			end
			box.Text = tostring(tbl[key])
		end)
	end
	for _, p in {
		{ "Duration per test (s)", "HumanDuration" }, { "Speed (studs/s)", "HumanSpeed" }, { "Hop size (studs)", "HopStuds" },
		{ "Max rise (studs)", "HumanRiseMax" }, { "Rise rate (studs/s)", "HumanRiseRate" },
	} do
		numRow(mList, p[1], testApi.CONFIG, p[2])
	end

	-- Automation tab: repeated, perfectly regular behaviour, run until the server flags it
	local aList = scroller(pAuto, UDim2.new(), UDim2.new(1, 0, 1, 0))
	textRow(aList, 46, "Repeats an identical action. Toggle keeps it running until you turn it off, with a live attempt/flag counter. Run stops at the first flag or at Max attempts. Not part of Run all.", C.dim)
	testRow(aList, "auto_path", "Identical patrol lap", true)
	testRow(aList, "auto_remote", "Fixed-interval remote", true)
	textRow(aList, 20, "Parameters", C.dim)
	for _, p in {
		{ "Max attempts", "AutoAttempts" }, { "Remote interval (s)", "AutoInterval" },
		{ "Patrol distance (studs)", "PatrolStuds" }, { "Patrol speed (studs/s)", "PatrolSpeed" },
	} do
		numRow(aList, p[1], testApi.CONFIG, p[2])
	end
	textRow(aList, 20, "Remote for the fixed-interval test (full path)", C.dim)
	local autoBox = mk("TextBox", {
		Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = C.field, ClearTextOnFocus = false,
		PlaceholderText = "Folder.Sub.RemoteName", Text = testApi.CONFIG.AutoRemote,
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Gotham, TextSize = 12,
	}, aList)
	autoBox.FocusLost:Connect(function()
		testApi.CONFIG.AutoRemote = autoBox.Text:match("^%s*(.-)%s*$")
	end)

	-- Detections tab
	local detList = scroller(pDet, UDim2.new(), UDim2.new(1, 0, 1, 0))
	local detStatus = textRow(detList, 20, "Server flags (admins only)", C.dim, -1e9)
	local detCount = 0
	local function addDetection(who: string, reason: string, strikes: number, maxStrikes: number)
		detCount += 1
		sessionFlags += 1
		local l = textRow(detList, 20, ("%s  %s  %s (%d/%d)"):format(os.date("%H:%M:%S"), who, reason, strikes, maxStrikes), nil, -detCount)
		l.Font = Enum.Font.Code
		if strikes >= maxStrikes then
			l.BackgroundColor3 = Color3.fromRGB(120, 40, 40)
		end
		print(("[ACDetect] %s: %s (%d/%d)"):format(who, reason, strikes, maxStrikes))
		updateSummary()
	end
	task.spawn(function()
		local flags = ReplicatedStorage:WaitForChild("ACFlags", 15)
		if flags and flags:IsA("RemoteEvent") then
			flags.OnClientEvent:Connect(addDetection)
		else
			detStatus.Text = "Server script not found (no ACFlags remote)"
			detStatus.TextColor3 = C.bad
		end
	end)

	-- Results tab
	local rList = scroller(pRes, UDim2.new(), UDim2.new(1, 0, 1, -36))
	textRow(rList, 20, "History of every test run this session", C.dim, -1e9)
	actionRow(pRes, {
		{ "Export results", exportResults },
		{ "Clear", function()
			for _, c in rList:GetChildren() do
				if c:IsA("TextLabel") and c.LayoutOrder > -1e9 then
					c:Destroy()
				end
			end
			table.clear(testApi.results)
			runCaught, runTotal = 0, 0
			updateSummary()
		end },
	}, 0).Position = UDim2.new(0, 6, 1, -32)

	local resCount = 0
	testApi.listeners.onResult[#testApi.listeners.onResult + 1] = function(entry)
		local b = badges[entry.key]
		if b then
			b.Text = ("%s  %s"):format(entry.detected and "● CAUGHT" or "○ MISSED", entry.note)
			b.TextColor3 = entry.detected and C.good or C.bad
		end
		runTotal += 1
		if entry.detected then
			runCaught += 1
		end
		resCount += 1
		local l = textRow(rList, 20, ("%s  %-26s %s  %s"):format(os.date("%H:%M:%S"), entry.name, entry.detected and "CAUGHT" or "MISSED", entry.note), nil, -resCount)
		l.Font = Enum.Font.Code
		l.TextSize = 11
		if not entry.detected then
			l.BackgroundColor3 = Color3.fromRGB(110, 40, 40)
		end
		updateSummary()
	end
	local wasBusy = false
	testApi.listeners.onStart[#testApi.listeners.onStart + 1] = function(key)
		if key == "" then
			wasBusy = false
			pendingToggle = ""
			for _, b in toggleButtons do
				b.Text = "Toggle"
				b.BackgroundColor3 = C.accent
			end
			updateSummary()
			return
		end
		if not wasBusy then
			wasBusy = true
			runCaught, runTotal = 0, 0
		end
		if badges[key] then
			badges[key].Text = "running..."
			badges[key].TextColor3 = C.warn
		end
		if toggleButtons[key] and pendingToggle == key then
			toggleButtons[key].Text = "Stop"
			toggleButtons[key].BackgroundColor3 = Color3.fromRGB(150, 60, 60)
		end
		setStatus("Running: " .. key)
	end
	-- live counters while a toggle is on
	testApi.listeners.onProgress[#testApi.listeners.onProgress + 1] = function(key, text)
		if badges[key] then
			badges[key].Text = text
			badges[key].TextColor3 = C.warn
		end
		setStatus(("ON: %s — %s"):format(key, text))
	end

	-- Remotes tab
	local remList = scroller(pRem, UDim2.new(), UDim2.new(1, 0, 1, 0))

	-- ---- recorder: capture the argument format of calls YOUR actions produce ----
	textRow(remList, 62, "Record remote calls: turn it on, then do the thing by hand (accept a quest, "
		.. "hand one in, sell something). No time limit - leave it on across a whole quest. Captures "
		.. "accumulate across sessions, so the accept and the turn-in can be recorded days apart.", C.dim)
	local recBtn = mk("TextButton", {
		Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = C.accent, BorderSizePixel = 0,
		Text = "Start recording", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 13,
	}, remList)
	local recStatus = textRow(remList, 20, "not recording", C.dim)
	local recList = textRow(remList, 150, "(nothing captured yet)")
	recList.Font = Enum.Font.Code
	recList.TextSize = 11
	recList.TextYAlignment = Enum.TextYAlignment.Top

	local function refreshRecorder()
		recBtn.Text = Recorder.on and "Stop recording" or "Start recording"
		recBtn.BackgroundColor3 = Recorder.on and Color3.fromRGB(150, 60, 60) or C.accent
		recStatus.Text = ("%s  -  %d call(s) seen this session"):format(
			Recorder.on and "RECORDING" or "not recording", Recorder.total)
		recStatus.TextColor3 = Recorder.on and C.warn or C.dim
		-- compact live view: one line per selector, busiest first
		local rows = {}
		for name, entry in Recorder.captures do
			local short = name:match("[^%.]+$") or name
			local sels = {}
			for sel in entry.variants do
				table.insert(sels, sel)
			end
			table.sort(sels, function(a, b)
				return entry.variants[a].count > entry.variants[b].count
			end)
			for _, sel in sels do
				table.insert(rows, ("%-22s %-26s x%d"):format(short, sel, entry.variants[sel].count))
			end
		end
		table.sort(rows)
		recList.Text = #rows > 0 and table.concat(rows, "\n") or "(nothing captured yet)"
	end
	Recorder.onChange = refreshRecorder

	recBtn.MouseButton1Click:Connect(function()
		local msg = Recorder.setOn(not Recorder.on)
		if msg ~= "recording" and msg ~= "stopped" then
			recStatus.Text = msg -- e.g. executor has no hookmetamethod
			recStatus.TextColor3 = C.bad
		end
	end)

	actionRow(remList, {
		{ "Print / copy captures", function()
			local text = Recorder.report()
			print(text)
			if env.setclipboard then
				pcall(env.setclipboard, text)
			end
			Recorder.save()
			recStatus.Text = "captures printed to output" .. (env.setclipboard and " and copied" or "")
		end },
		{ "Clear captures", function()
			table.clear(Recorder.captures)
			Recorder.total = 0
			Recorder.save()
			refreshRecorder()
		end },
	})
	refreshRecorder()

	-- ---- fuzzer ----
	textRow(remList, 34, "Remote names to fuzz (comma-separated, RemoteEvents under ReplicatedStorage). Sends odd payloads and a 500-call spam.", C.dim)
	local remBox = mk("TextBox", {
		Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = C.field, ClearTextOnFocus = false, PlaceholderText = "RemoteA, RemoteB",
		Text = table.concat(testApi.CONFIG.RemoteNames, ", "), TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Gotham, TextSize = 12,
	}, remList)
	remBox.FocusLost:Connect(function()
		local names = {}
		for n in remBox.Text:gmatch("[^,]+") do
			local trimmed = n:match("^%s*(.-)%s*$")
			if trimmed ~= "" then
				table.insert(names, trimmed)
			end
		end
		testApi.CONFIG.RemoteNames = names
	end)
	testRow(remList, "remotes", "Remote fuzz + spam")

	-- ===== GAME TABS (Home / Combat / Quests / Bosses / Loot / ESP / Movement / Settings) =====
	local refreshers: { () -> () } = {}
	local function refreshAll()
		for _, f in refreshers do
			f()
		end
	end

	local function sectionHeader(parent: Instance, text: string)
		local h = textRow(parent, 22, text, Color3.new(1, 1, 1))
		h.BackgroundColor3 = C.accent
		h.Font = Enum.Font.GothamBold
		h.TextSize = 13
	end

	-- One row per setting: booleans are toggle buttons, everything else is a text box.
	-- `tbl` defaults to S; pass ADAPT for the game-hookup remote names.
	local function settingRow(parent: Instance, key: string, label: string, tbl: { [string]: any }?)
		local t = tbl or S
		if typeof(t[key]) == "boolean" then
			local b = mk("TextButton", {
				Size = UDim2.new(1, 0, 0, 24), BackgroundColor3 = C.row, BorderSizePixel = 0, Font = Enum.Font.Gotham, TextSize = 13,
			}, parent)
			local function refresh()
				b.Text = ("%s: %s"):format(label, t[key] and "ON" or "OFF")
				b.TextColor3 = t[key] and C.good or C.text
			end
			b.MouseButton1Click:Connect(function()
				t[key] = not t[key]
				refresh()
			end)
			table.insert(refreshers, refresh)
			refresh()
		else
			local holder = mk("Frame", { Size = UDim2.new(1, 0, 0, 24), BackgroundColor3 = C.row, BorderSizePixel = 0 }, parent)
			mk("TextLabel", {
				Position = UDim2.fromOffset(6, 0), Size = UDim2.new(0.55, -6, 1, 0), BackgroundTransparency = 1, Text = label,
				TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, holder)
			local box = mk("TextBox", {
				Position = UDim2.fromScale(0.55, 0), Size = UDim2.fromScale(0.45, 1), BackgroundColor3 = C.field,
				ClearTextOnFocus = false, TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Gotham, TextSize = 12,
			}, holder)
			local isNum = typeof(t[key]) == "number"
			local function refresh()
				box.Text = tostring(t[key])
			end
			box.FocusLost:Connect(function()
				if isNum then
					local n = tonumber(box.Text)
					if n then
						t[key] = n
					end
				else
					t[key] = box.Text
				end
				refresh()
			end)
			table.insert(refreshers, refresh)
			refresh()
		end
	end

	-- defs: { "Header text" } for a section header, { key, label } for a setting, { key, label, ADAPT } for a hookup field
	local function buildPage(page: Instance, defs: { { any } }): ScrollingFrame
		local list = scroller(page, UDim2.new(), UDim2.new(1, 0, 1, 0))
		for _, d in defs do
			if #d == 1 then
				sectionHeader(list, d[1])
			else
				settingRow(list, d[1], d[2], d[3])
			end
		end
		return list
	end

	-- Home: live status plus the basic start/stop controls
	local homeList = scroller(pHome, UDim2.new(), UDim2.new(1, 0, 1, 0))
	sectionHeader(homeList, "Current status")
	local homeStatus = textRow(homeList, 22, "Status: -")
	local homeTarget = textRow(homeList, 22, "Target: -")
	local homeQuest = textRow(homeList, 34, "Quest: -")
	local homeSession = textRow(homeList, 22, "Session: -")
	sectionHeader(homeList, "Controls")
	actionRow(homeList, {
		{ "Start farming", function()
			S.AutoFarm = true
			refreshAll()
		end },
		{ "Stop all", function()
			stopAll()
			refreshAll()
		end },
	})
	for _, d in {
		{ "AutoFarm", "Auto farm / attack" }, { "AutoQuest", "Auto quests" }, { "AutoLoot", "Auto loot" },
		{ "KillAura", "Kill aura" }, { "ESP", "ESP" },
	} do
		settingRow(homeList, d[1], d[2])
	end
	sectionHeader(homeList, "Diagnostics")
	local homeDiag = textRow(homeList, 62, "-")
	homeDiag.Font = Enum.Font.Code
	homeDiag.TextSize = 11

	buildPage(pCombat, {
		{ "Attack" },
		{ "AutoFarm", "Auto attack / farm" }, { "KillAura", "Kill aura" }, { "AuraRadius", "Aura radius" },
		{ "FastAttack", "Faster attacks" }, { "AttackSpeedMult", "Attack speed x" }, { "BaseAttackInterval", "Base attack interval (s)" },
		{ "Hitbox", "Adjustable hitboxes" }, { "HitboxSize", "Hitbox size" },
		{ "Abilities and skills" },
		{ "AutoSkills", "Auto skills" }, { "SkillKeys", "Skill keys (Z,X,C)" }, { "SkillInterval", "Skill interval (s)" },
		{ "AutoParry", "Auto parry" }, { "ParryRange", "Parry range" },
		{ "AutoEquip", "Weapon equip" }, { "WeaponName", "Weapon name" },
		{ "Target selection" },
		{ "Targets", "Targets (names, comma)" }, { "ExcludeNames", "Never attack (names, comma)" },
		{ "TargetPriority", "Priority: nearest/lowest/highest/weakest" }, { "LeashRange", "Drop target beyond (studs)" },
		{ "Attack preferences" },
		{ "FightDistance", "Fight distance (studs)" }, { "AttackRange", "Max swing range (studs)" },
		{ "FarmHeight", "Farm height (offset Y)" },
		{ "SmartFarm", "Retreat at low HP" }, { "RetreatBelow", "Retreat below HP (0-1)" }, { "ResumeAbove", "Resume above HP (0-1)" },
		{ "ReactionMin", "Reaction delay min (s)" }, { "ReactionMax", "Reaction delay max (s)" },
		{ "Game hookup (blank = click M1 / press keys)" },
		{ "AttackRemote", "Attack remote", ADAPT }, { "SkillRemote", "Skill remote", ADAPT }, { "ParryRemote", "Parry remote", ADAPT },
	})

	local questList = buildPage(pQuests, {
		{ "Quest acceptance and progression" },
		{ "AutoQuest", "Auto quests" }, { "QuestName", "Quest name" }, { "QuestActionSeconds", "Fallback timer (s)" },
		{ "Quest priorities" },
		{ "SideQuests", "Side quests" }, { "SideQuestName", "Side quest name" },
		{ "Stat points" },
		{ "AutoStats", "Auto stats" }, { "StatPriority", "Stat priorities" }, { "PointReserve", "Point reserve" },
		{ "Game hookup (blank = walk to NPC and use its prompt)" },
		{ "AcceptQuestRemote", "Accept quest remote", ADAPT }, { "CompleteQuestRemote", "Complete quest remote", ADAPT },
		{ "StatRemote", "Stat remote", ADAPT },
	})
	sectionHeader(questList, "Live quest state (what the loop can actually see)")
	local questDiag = textRow(questList, 78, "-")
	questDiag.Font = Enum.Font.Code
	questDiag.TextSize = 11

	buildPage(pBosses, {
		{ "Boss selection" },
		{ "BossFarm", "Boss farming" }, { "BossNames", "Boss names (comma)" },
		{ "Boss prioritization" },
		{ "TargetPriority", "Priority: nearest / lowest" }, { "SmartFarm", "Retreat at low HP" },
		{ "RetreatBelow", "Retreat below HP (0-1)" }, { "ResumeAbove", "Resume above HP (0-1)" },
		{ "Respawn handling" },
		{ "Recovery", "Resume after respawn" }, { "RecoverDelay", "Recover delay (s)" },
	})

	buildPage(pLoot, {
		{ "Auto-loot" },
		{ "AutoLoot", "Auto loot" }, { "LootNames", "Item filter (names, comma)" },
		{ "AutoPickups", "Auto pickups" }, { "TravelToLoot", "Travel to loot" },
		{ "CollectRadius", "Collect radius" }, { "LootRange", "Loot range (studs)" }, { "LootDelay", "Loot delay (s)" },
		{ "Chest collection" },
		{ "AutoChests", "Auto chests" }, { "ChestNames", "Chest names (comma)" },
		{ "Auto-sell" },
		{ "AutoSell", "Auto sell" }, { "SellNames", "Sell names (comma)" }, { "SellRemote", "Sell remote", ADAPT },
	})

	buildPage(pEsp, {
		{ "ESP (labels everything it finds, with distance)" },
		{ "ESP", "ESP master switch" },
		{ "NPC, boss and enemy info" },
		{ "ESPEnemies", "Enemies (name + HP)" }, { "ESPBosses", "Bosses (name + HP)" }, { "ESPNpcs", "NPCs (name + class)" },
		{ "Items and interactables" },
		{ "ESPLoot", "Loot, chests, pickups (uses Loot tab filters)" }, { "ESPPrompts", "Interactables ([E] prompts)" },
		{ "Players" },
		{ "ESPPlayers", "Other players (name + HP)" },
		{ "Distance and range" },
		{ "ESPDistance", "Show distance" }, { "ESPMaxDist", "Max distance (0 = unlimited)" },
	})

	buildPage(pMoveset, {
		{ "Travel" },
		{ "InstantTravel", "Instant travel (off = tween)" }, { "TweenSpeed", "Tween speed" }, { "TweenSpeedVar", "Tween speed variation" },
		{ "TweenCurve", "Tween path curve" }, { "TweenCurveMinDist", "Curve only beyond (studs)" },
		{ "Speed" },
		{ "Speed", "Speed" }, { "SpeedMult", "Speed multiplier" }, { "SpeedRamp", "Speed ramp (studs/s per s)" },
		{ "Flight and noclip" },
		{ "Flight", "Flight" }, { "FlightSpeed", "Flight speed" }, { "FlightSmoothing", "Flight smoothing" }, { "Noclip", "Noclip" },
	})

	local setList = buildPage(pSet, {
		{ "Session limits" },
		{ "MaxMinutes", "Session limit (minutes, 0 = none)" }, { "MaxActions", "Session limit (actions, 0 = none)" },
		{ "Recovery behavior" },
		{ "Recovery", "Resume after respawn" }, { "RecoverDelay", "Recover delay (s)" },
		{ "UI customization" },
		{ "UIScale", "Menu scale (0.6 - 1.6)" }, { "UIOpacity", "Menu transparency (0 - 0.8)" },
		{ "Behaviour" },
		{ "Humanize", "Humanize behaviour" }, { "HumanizeStrength", "Humanize strength (0-1)" },
		{ "Breaks", "Random breaks" }, { "BreakMin", "Break min (s)" }, { "BreakMax", "Break max (s)" },
		{ "BreakEveryMin", "Break every min (s)" }, { "BreakEveryMax", "Break every max (s)" },
		{ "AntiIdle", "Anti-idle" }, { "Fullbright", "Lighting controls" }, { "DebugState", "Print reconstructed state" },
	})
	local saveRow = actionRow(setList, {
		{ "Scan game", function() task.spawn(runScanner) end },
		{ "Save config", saveConfig },
		{ "Load config", function() loadConfig(refreshAll) end },
		{ "Stop all", function()
			stopAll()
			refreshAll()
		end },
		{ "Reset stats", function()
			table.clear(counts)
			totalActions = 0
			startTime = os.clock()
		end },
	})
	saveRow.LayoutOrder = -1 -- pin to the top of the Settings list

	-- menu scale / opacity (UI customization)
	local uiScale = mk("UIScale", {}, frame)
	local function applyUI()
		uiScale.Scale = math.clamp(S.UIScale, 0.6, 1.6)
		frame.BackgroundTransparency = math.clamp(S.UIOpacity, 0, 0.8)
	end

	local function fmtTime(sec: number): string
		sec = math.floor(sec)
		return ("%02d:%02d:%02d"):format(sec // 3600, (sec // 60) % 60, sec % 60)
	end

	local function updateHome()
		local root, hum = getRoot(), getHum()
		local st
		if not (root and hum) or hum.Health <= 0 then
			st = "Dead / no character"
		elseif breakUntil then
			st = "On a break"
		elseif S.SmartFarm and lowHP then
			st = "Retreating (low HP)"
		elseif Q.acting then
			st = "Quest: " .. Q.state
		elseif S.AutoFarm or S.BossFarm or S.KillAura then
			st = "Farming"
		else
			st = "Idle"
		end
		homeStatus.Text = "Status: " .. st
		local tgt = lastFarmTarget
		local th = tgt and tgt:FindFirstChildOfClass("Humanoid")
		homeTarget.Text = tgt and tgt.Parent and ("Target: %s%s"):format(tgt.Name, th and (" %d/%d"):format(th.Health, th.MaxHealth) or "") or "Target: none"
		local p = GameState.questProgress()
		local qname = Q.name ~= "" and Q.name or S.QuestName
		homeQuest.Text = ("Quest: %s\n%s"):format(
			qname ~= "" and qname or "none",
			p and ("%s %s  %s/%s"):format(p.kind, p.target, tostring(p.current or "?"), tostring(p.needed or "?")) or "no objective detected"
		)
		homeSession.Text = ("Session: %s   actions: %d   kills: %d"):format(fmtTime(os.clock() - startTime), totalActions, Q.kills)

		-- Diagnostics answer the usual "it's on but nothing is happening" question directly:
		-- what the scan found, which attack path is live, and whether the remote resolves.
		local remoteState = "not set"
		if ADAPT.AttackRemote ~= "" then
			local r = remote(ADAPT.AttackRemote)
			remoteState = r and ("resolved (" .. r.ClassName .. ")") or "NOT FOUND"
		end
		-- Quest diagnostics: each line is a prerequisite the loop needs, so a "-" or NOT FOUND
		-- tells you exactly which step is missing rather than leaving it stuck silently.
		local mk = GameState.questMarkers()
		local function questRemoteState(path: string): string
			if path == "" then
				return "not set - record one (see Settings > Scan game)"
			end
			local r = remote(path)
			return r and ("ok (" .. r.ClassName .. ")") or "NOT FOUND"
		end
		questDiag.Text = table.concat({
			("state: %s   acting: %s   kills: %d"):format(Q.state, tostring(Q.acting), Q.kills),
			("marker objective: %s"):format(mk.objective or "- (no active quest marker)"),
			("marker NPCs: %s"):format(#mk.npcs > 0 and table.concat(mk.npcs, ", ") or "-"),
			("parsed: %s"):format(p and ("%s %q %s/%s"):format(p.kind, p.target, tostring(p.current or "?"), tostring(p.needed or "?")) or "-"),
			("accept remote:   %s"):format(questRemoteState(ADAPT.AcceptQuestRemote)),
			("complete remote: %s"):format(questRemoteState(ADAPT.CompleteQuestRemote)),
		}, "\n")

		local dist = tgt and rootOf(tgt)
		homeDiag.Text = table.concat({
			("enemies:%d  npcs:%d  loot:%d  scan:%.1fms"):format(#enemies, #otherNpcs, #lootItems, scanCost),
			("attack via: %s   remote: %s"):format(attackMode, remoteState),
			("target dist: %s  (swing range %d)"):format(
				dist and ("%.1f"):format((dist.Position - (getRoot() or dist).Position).Magnitude) or "-", S.AttackRange),
		}, "\n")
	end

	showTab("Home")
	updateSummary()

	task.spawn(function()
		while task.wait(0.5) do
			local parts = {}
			for k, v in counts do
				table.insert(parts, k .. ":" .. v)
			end
			stats.Text = ("actions %d | %s"):format(totalActions, table.concat(parts, " "))
			applyUI()
			pcall(updateHome)
			if S.DebugState and due("debugState", 3) then
				local p = GameState.questProgress()
				local cls = {}
				for k, n in npcClassCount do
					table.insert(cls, k .. "=" .. n)
				end
				print("[ACMenu] npcs: " .. (#cls > 0 and table.concat(cls, " ") or "none"))
				print(("[ACMenu] state: statPoints=%d | quest=%s | complete=%s"):format(
					GameState.statPoints(),
					p and ("%s %q %s/%s"):format(p.kind, p.target, tostring(p.current), tostring(p.needed)) or "none found",
					tostring(GameState.questComplete())
				))
			end
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.RightShift then
			setOpen(not frame.Visible)
		end
	end)

	print("[ACMenu] Loaded.")
end

buildMenu()
