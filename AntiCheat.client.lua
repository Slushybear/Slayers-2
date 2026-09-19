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

-- ===== GAME STATE RECONSTRUCTION =====
-- The server is authoritative, but it replicates a lot to the client: objects,
-- attributes, ValueBases, and UI text. This layer rebuilds useful game info
-- (stat points, quest objective, quest progress) from those sources, so the
-- automation needs no hardcoded per-game hooks. Whatever it can reconstruct here
-- is also information an exploiter can read, which is the point of testing it.
local GameState = {}

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
function GameState.questProgress(): { kind: string, target: string, current: number?, needed: number?, text: string }?
	local texts = GameState.uiTexts()
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

-- ===== ADAPTER: wire these to YOUR game =====
-- Remotes are looked up by name anywhere under ReplicatedStorage. Leave "" to skip.
local ADAPT = {
	AttackRemote = "",      -- fired as AttackRemote:FireServer(unpack(BuildAttackArgs(enemy)))
	ParryRemote = "",
	SkillRemote = "",       -- if "", skills are sent as key presses instead
	StatRemote = "",        -- fired as StatRemote:FireServer(statName, amount)
	SellRemote = "",        -- fired as SellRemote:FireServer(itemName)
	AcceptQuestRemote = "",
	CompleteQuestRemote = "",
	-- Quest loop hooks. All optional; defaults are guesses until you fill them in.
	-- Name of the NPC model that gives/claims a quest.
	QuestNPCName = function(questName: string): string
		return questName
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
	BuildAttackArgs = function(enemy: Model): { any }
		return { enemy }
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
	local t0 = os.clock()
	local isCont = continuous
	local lastProgress = 0
	while player.Character == startChar and hum.Health > 0 do
		local elapsed = os.clock() - t0
		if isCont then
			if stopRequested then
				break
			end
		elseif elapsed >= duration then
			break
		end
		local dt = RunService.Heartbeat:Wait()
		step(root, dt, elapsed)
		if isCont and os.clock() - lastProgress > 0.5 then
			lastProgress = os.clock()
			progress(("ON %ds • %d flag(s)"):format(elapsed, flagCount))
		end
	end
	task.wait(CONFIG.ReactWindow)

	local reset = player.Character ~= startChar or hum.Health <= 0
	local detected = flagCount > 0 or reset
	local note = ("%d flag(s) over %ds%s"):format(flagCount, os.clock() - t0, reset and ", character reset" or "")
	record(name, detected, note)
	log(("%s -> %s (%s)"):format(name, detected and "CAUGHT" or "MISSED", note))
	if reset then
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
	local isCont = continuous
	while player.Character == char and hum.Health > 0 do
		if isCont then
			if stopRequested then
				break
			end
		elseif n >= CONFIG.AutoAttempts or firstAt then
			break
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
	local reset = player.Character ~= char or hum.Health <= 0
	if not firstAt and flagCount > 0 then
		firstAt = n
	end
	local detected = firstAt ~= nil or reset
	local note = firstAt and ("first flag after %d attempt(s), %d flag(s) total"):format(firstAt, flagCount)
		or ("no flag after %d attempts"):format(n)
	record(name, detected, note .. (reset and ", character reset" or ""))
	log(("%s -> %s (%s)"):format(name, detected and "CAUGHT" or "MISSED", note))
	if reset then
		player.CharacterAdded:Wait()
	end
end

-- Constant-speed A->B->A patrol on the exact same line every lap.
tests.auto_path = function()
	local _, _, root0 = getChar()
	local a = root0.Position
	local b = a + Vector3.new(CONFIG.PatrolStuds, 0, 0)
	local function glide(root: BasePart, from: Vector3, to: Vector3)
		local dur = (to - from).Magnitude / CONFIG.PatrolSpeed
		local t = 0
		local rot = root.CFrame - root.CFrame.Position
		while t < dur do
			t += RunService.Heartbeat:Wait()
			root.CFrame = CFrame.new(from:Lerp(to, math.min(t / dur, 1))) * rot
		end
	end
	runRepeatTest("Automation: identical patrol lap", function()
		glide(root0, a, b)
		glide(root0, b, a)
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
local scannerRan = false
local function runScanner()
	if scannerRan then
		warn("[ACScan] already ran this session; re-execute the script to scan again")
		return
	end
	scannerRan = true
	local RECORD_SECONDS = 60
-- ===== helpers =====
local lines: { string } = {}
-- Structured copy of the findings, saved as ACScanData.json for AntiCheatMenu to load.
local data = { remotes = {}, enemies = {}, gcRemotes = {}, candidates = {}, questStrings = {}, recorded = {} }
local function add(s: string)
	table.insert(lines, s)
end

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
		if t == "table" then
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
flush("Phase 1")
applyScanData()

-- ===== Phase 2: record your manual remote calls =====
if not (env.hookmetamethod and env.getnamecallmethod) then
	warn("[ACScan] hookmetamethod unavailable here, skipping record phase. Phase 1 report is complete.")
	return
end

local recording = true
local logged: { [string]: { count: number, sample: string } } = {}

local totalCalls = 0
local function logCall(self: any, ...)
	local args = table.pack(...)
	local parts = {}
	for i = 1, args.n do
		table.insert(parts, ser(args[i]))
	end
	local key = self:GetFullName()
	local sig = key .. "(" .. table.concat(parts, ", ") .. ")"
	totalCalls += 1
	local entry = logged[key]
	if not entry then
		logged[key] = { count = 1, sample = sig }
	else
		entry.count += 1
		-- keep up to one extra differing sample so argument variation is visible
		if entry.sample ~= sig and not entry.sample:find("\n", 1, true) then
			entry.sample ..= "\n      alt: " .. sig
		end
	end
end

local wrap = env.newcclosure or function(f) return f end

-- Hook 1: method-style calls (remote:FireServer(...)) go through __namecall.
local oldNamecall
oldNamecall = env.hookmetamethod(game, "__namecall", wrap(function(self, ...)
	local method = env.getnamecallmethod()
	if recording and (method == "FireServer" or method == "InvokeServer") and typeof(self) == "Instance" then
		pcall(logCall, self, ...)
	end
	return oldNamecall(self, ...)
end))

-- Hook 2: code that caches the function or calls remote.FireServer(remote, ...) never touches __namecall,
-- so also hook the functions themselves when the executor supports it.
local hookedFns: { string } = {}
if env.hookfunction then
	for _, spec in { { "RemoteEvent", "FireServer" }, { "RemoteFunction", "InvokeServer" }, { "UnreliableRemoteEvent", "FireServer" } } do
		local ok = pcall(function()
			local probe = Instance.new(spec[1])
			local orig
			orig = env.hookfunction(probe[spec[2]], wrap(function(self, ...)
				if recording and typeof(self) == "Instance" then
					pcall(logCall, self, ...)
				end
				return orig(self, ...)
			end))
			probe:Destroy()
		end)
		if ok then
			table.insert(hookedFns, spec[1] .. "." .. spec[2])
		end
	end
end
print(("[ACScan] hooks: __namecall%s"):format(#hookedFns > 0 and (" + " .. table.concat(hookedFns, ", ")) or (env.hookfunction and " (hookfunction failed)" or " only (no hookfunction in this executor)")))

print(("[ACScan] RECORDING for %d seconds. Now do these BY HAND in your game: attack, use skills, parry, accept and complete a quest, spend a stat point, sell an item, pick up loot."):format(RECORD_SECONDS))
-- progress every 10s so you can tell whether the hook is seeing anything
for elapsed = 10, RECORD_SECONDS, 10 do
	task.wait(10)
	print(("[ACScan] %ds left, %d remote call(s) seen so far"):format(RECORD_SECONDS - elapsed, totalCalls))
end
recording = false

add("--- Recorded outgoing remote calls (what YOU triggered manually) ---")
local any = false
for name, entry in logged do
	any = true
	data.recorded[name] = { count = entry.count, sample = entry.sample }
	add(("%s  x%d\n      e.g. %s"):format(name, entry.count, entry.sample))
end
if not any then
	add("(nothing recorded, hook may not have fired)")
end
add("")
flush("Full report")
applyScanData()

end

local runTests, testApi = setupTester()

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
	Targets = "", BossNames = "Boss", TargetPriority = "nearest", -- nearest | lowest
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
	UIScale = 1, UIOpacity = 0,
	Fullbright = false, AntiIdle = true,
	Humanize = true, HumanizeStrength = 0.15, Breaks = false, SmartFarm = true,
	ReactionMin = 0.25, ReactionMax = 0.75, FightDistance = 4,
	RetreatBelow = 0.35, ResumeAbove = 0.7,
	BreakMin = 20, BreakMax = 90, BreakEveryMin = 600, BreakEveryMax = 1320,
	LootDelay = 0.7, LootRange = 8,
	Speed = false, SpeedMult = 1.5, SpeedRamp = 4, FlightSmoothing = 3,
	DebugState = false, Recovery = true, RecoverDelay = 3, MaxMinutes = 0, MaxActions = 0, -- 0 = unlimited
}

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

local remoteCache: { [string]: Instance? } = {}
local function remote(name: string): Instance?
	if name == "" then
		return nil
	end
	if not remoteCache[name] or not (remoteCache[name] :: Instance).Parent then
		-- accepts a bare name (searched recursively) or a dotted path under ReplicatedStorage
		local cur: Instance? = ReplicatedStorage
		for part in name:gmatch("[^%.]+") do
			cur = cur and cur:FindFirstChild(part)
		end
		remoteCache[name] = cur or ReplicatedStorage:FindFirstChild(name, true)
	end
	return remoteCache[name]
end

local function fire(name: string, ...)
	local r = remote(name)
	if r and r:IsA("RemoteEvent") then
		r:FireServer(...)
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

local function scan()
	local e, l, c, p, pr = {}, {}, {}, {}, {}
	table.clear(npcClassCount)
	local o: { Model } = {}
	local targets = split(S.Targets)
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
				-- combat only ever sees enemies; quest givers, merchants, guards etc. are skipped
				if cls == "enemy" and hum.Health > 0 and matches(d.Name, targets) then
					table.insert(e, d)
				elseif cls ~= "enemy" then
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

local function pickTarget(bossOnly: boolean): Model?
	local root = getRoot()
	if not root then
		return nil
	end
	local bossN = split(S.BossNames)
	local best, bestScore = nil, math.huge
	for _, m in enemies do
		local hum = m:FindFirstChildOfClass("Humanoid")
		local r = rootOf(m)
		if hum and hum.Health > 0 and r and (not bossOnly or matches(m.Name, bossN)) then
			local score = S.TargetPriority == "lowest" and hum.Health or (r.Position - root.Position).Magnitude
			if score < bestScore then
				best, bestScore = m, score
			end
		end
	end
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
local function moveToward(goal: Vector3, dt: number)
	local root = getRoot()
	if not root then
		return
	end
	if S.InstantTravel then
		root.CFrame = CFrame.new(goal)
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
		local flat = Vector3.new(delta.X, 0, delta.Z)
		root.CFrame = flat.Magnitude > 0.1 and CFrame.lookAt(pos, pos + flat) or CFrame.new(pos)
	end
	root.AssemblyLinearVelocity = Vector3.zero
end

local function attack(enemy: Model)
	if ADAPT.AttackRemote ~= "" then
		local r = remote(ADAPT.AttackRemote)
		if r and r:IsA("RemoteEvent") then
			r:FireServer(table.unpack(ADAPT.BuildAttackArgs(enemy)))
			bump("attack")
			return
		end
	end
	local tool = player.Character and player.Character:FindFirstChildOfClass("Tool")
	if tool then
		tool:Activate()
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
		bump("attack")
	end
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
local flightBV: BodyVelocity? = nil
local lastFarmTarget: Model? = nil
local engageAt = 0
local lowHP = false
local breakUntil: number? = nil
local nextBreak = os.clock() + 600
local baseSpeed: number? = nil

local function stopAll()
	for k, v in S do
		local keep = k == "AntiIdle" or k == "Recovery" or k == "Humanize" or k == "SmartFarm"
			or (k:sub(1, 3) == "ESP" and k ~= "ESP") -- ESP filters stay as configured
		if v == true and not keep then
			S[k] = false
		end
	end
end

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
		return nil
	end
	Q.idx = (Q.idx - 1) % #list + 1
	return list[Q.idx]
end

local function findNPC(questName: string): Instance?
	local want = { ADAPT.QuestNPCName(questName) }
	local fallback: Instance? = nil
	for _, d in workspace:GetDescendants() do
		if (d:IsA("Model") or d:IsA("BasePart")) and rootOf(d) and not Players:GetPlayerFromCharacter(d) then
			if matches(d.Name, want) then
				return d
			elseif not fallback and d:IsA("Model") and d:FindFirstChildOfClass("Humanoid")
				and GameState.classifyNPC(d) == "quest" then
				fallback = d -- any recognised quest giver if the named one isn't around
			end
		end
	end
	return fallback
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
			return setState("FindNPC")
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
RunService.Heartbeat:Connect(function(dt)
	local root, hum = getRoot(), getHum()
	if not (root and hum) or hum.Health <= 0 then
		return
	end

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

	if due("scan", 1) then
		scan()
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
			moveToward(Vector3.new(spot.X, r.Position.Y + S.FarmHeight, spot.Z), dt)
			if dueH("farmAttack", interval) then
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
				attack(m)
				bump("aura")
				if S.Humanize then
					break -- one target per swing; hitting several in one frame is a giveaway
				end
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
		if due("esp", 1) then
			espFolder:ClearAllChildren()
			local bossN = split(S.BossNames)
			-- label anything: a Highlight (optional, Roblox renders at most ~31) plus a name/distance tag
			local function mark(target: Instance, color: Color3, label: string, highlight: boolean)
				local r = rootOf(target)
				local dist = r and (r.Position - root.Position).Magnitude
				if dist and S.ESPMaxDist > 0 and dist > S.ESPMaxDist then
					return
				end
				if highlight then
					local h = Instance.new("Highlight")
					h.Adornee = target
					h.FillColor = color
					h.Parent = espFolder
				end
				if r then
					local bb = Instance.new("BillboardGui")
					bb.Adornee = r
					bb.AlwaysOnTop = true
					bb.Size = UDim2.fromOffset(200, 18)
					bb.StudsOffset = Vector3.new(0, 4, 0)
					local tl = Instance.new("TextLabel")
					tl.Size = UDim2.fromScale(1, 1)
					tl.BackgroundTransparency = 1
					tl.TextColor3 = color
					tl.TextStrokeTransparency = 0.4
					tl.Font = Enum.Font.GothamBold
					tl.TextSize = 12
					tl.Text = (S.ESPDistance and dist) and ("%s [%dm]"):format(label, dist) or label
					tl.Parent = bb
					bb.Parent = espFolder
				end
			end
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
		end
	else
		espFolder.Parent = nil
	end
end)

-- noclip runs on Stepped so it lands before physics
RunService.Stepped:Connect(function()
	if S.Noclip and player.Character then
		for _, p in player.Character:GetDescendants() do
			if p:IsA("BasePart") then
				p.CanCollide = false
			end
		end
	end
end)

-- fullbright
task.spawn(function()
	while task.wait(1) do
		if S.Fullbright then
			Lighting.Brightness = 2
			Lighting.ClockTime = 14
			Lighting.FogEnd = 1e6
			Lighting.GlobalShadows = false
			Lighting.Ambient = Color3.new(1, 1, 1)
		end
	end
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
		flightBV = nil
		table.clear(timers)
		print("[ACMenu] Respawned, automation resumed")
	end
end)

-- ===== SAVED CONFIGS =====
local CONFIG_FILE = "ACMenu_config.json"
local function saveConfig()
	if env.writefile then
		env.writefile(CONFIG_FILE, HttpService:JSONEncode(S))
		print("[ACMenu] Config saved")
	else
		warn("[ACMenu] writefile unavailable (needs an executor)")
	end
end
local function loadConfig(refresh: () -> ())
	if env.isfile and env.isfile(CONFIG_FILE) then
		local ok, data = pcall(function()
			return HttpService:JSONDecode(env.readfile(CONFIG_FILE))
		end)
		if ok then
			for k, v in data do
				if S[k] ~= nil and typeof(S[k]) == typeof(v) then
					S[k] = v
				end
			end
			refresh()
			print("[ACMenu] Config loaded")
		end
	else
		warn("[ACMenu] No saved config found")
	end
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
		BackgroundColor3 = C.bg, BorderSizePixel = 0, Active = true, Draggable = true,
	}, gui)

	local header = mk("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = C.bar, BorderSizePixel = 0 }, frame)
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
		Active = true, Draggable = true,
	}, gui)
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
	textRow(mList, 34, "Subtle movement near your thresholds. Server caps (AntiCheatServer CONFIG): speed 40 studs/s, air rise 12, teleport 60.", C.dim)
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
		{ "Targets", "Targets (names, comma)" }, { "TargetPriority", "Priority: nearest / lowest" },
		{ "Attack preferences" },
		{ "FightDistance", "Fight distance (studs)" }, { "FarmHeight", "Farm height (offset Y)" },
		{ "SmartFarm", "Retreat at low HP" }, { "RetreatBelow", "Retreat below HP (0-1)" }, { "ResumeAbove", "Resume above HP (0-1)" },
		{ "ReactionMin", "Reaction delay min (s)" }, { "ReactionMax", "Reaction delay max (s)" },
		{ "Game hookup (blank = click M1 / press keys)" },
		{ "AttackRemote", "Attack remote", ADAPT }, { "SkillRemote", "Skill remote", ADAPT }, { "ParryRemote", "Parry remote", ADAPT },
	})

	buildPage(pQuests, {
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
		{ "Stop all", function() stopAll() refreshAll() end },
		{ "Reset stats", function() table.clear(counts) totalActions = 0 startTime = os.clock() end },
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
