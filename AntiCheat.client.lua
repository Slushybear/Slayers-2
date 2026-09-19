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

-- ===== SAFETY LOCK (same rules as AntiCheatTester) =====
local ALLOWED_PLACE_IDS = { 136406881576517 } -- matched against PlaceId and GameId
local OWNED_GROUP_IDS = {}

local function isMyGame()
	if game.CreatorType == Enum.CreatorType.User then
		return game.CreatorId == player.UserId
	end
	return table.find(OWNED_GROUP_IDS, game.CreatorId) ~= nil
end

if not (RunService:IsStudio() or table.find(ALLOWED_PLACE_IDS, game.PlaceId)
	or table.find(ALLOWED_PLACE_IDS, game.GameId) or isMyGame()) then
	warn(("[ACMenu] Not your game, refusing to run. PlaceId=%d GameId=%d"):format(game.PlaceId, game.GameId))
	return
end

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
	RemoteNames = {} :: { string },
	-- How long to wait after each test for the server to react (seconds).
	ReactWindow = 4,
	SpeedValue = 100,
	JumpPowerValue = 200,
	TeleportDistance = 500,
	FlyHeight = 80,
}

local results: { { name: string, detected: boolean, note: string } } = {}

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

	table.insert(results, { name = name, detected = detected, note = note })
	log(("%s -> %s (%s)"):format(name, detected and "CAUGHT" or "MISSED", note))
	if not detected then
		-- put things back so the next test starts clean
		pcall(function()
			hum.WalkSpeed = 16
			hum.JumpPower = 50
		end)
	end
	player.CharacterAdded:Wait() -- fresh character between tests
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

tests.remotes = function()
	if #CONFIG.RemoteNames == 0 then
		log("Remote fuzz skipped: add names to CONFIG.RemoteNames")
		return
	end
	local payloads: { any } = {
		nil, 0, -1, math.huge, -math.huge, 0 / 0, 1e308, "", string.rep("A", 100000),
		{}, { {} }, true, Vector3.new(math.huge, 0, 0), workspace, player,
	}
	for _, remoteName in CONFIG.RemoteNames do
		local remote = ReplicatedStorage:FindFirstChild(remoteName, true)
		if remote and remote:IsA("RemoteEvent") then
			log("Fuzzing remote: " .. remoteName)
			for i = 1, 15 do
				pcall(function()
					(remote :: RemoteEvent):FireServer(payloads[i])
				end)
			end
			log("Spamming remote: " .. remoteName)
			for _ = 1, 500 do
				pcall(function()
					(remote :: RemoteEvent):FireServer()
				end)
			end
			task.wait(1)
			log("Remote done (check server output for errors / rate-limit hits): " .. remoteName)
		else
			log("Remote not found or not a RemoteEvent: " .. remoteName)
		end
	end
end

local function printReport()
	log("===== REPORT =====")
	for _, r in results do
		log(("%-28s %s  %s"):format(r.name, r.detected and "CAUGHT" or "MISSED", r.note))
	end
end

local function run(cmd: string)
	if cmd == "all" then
		for _, name in { "speed", "jump", "teleport", "fly", "noclip", "health" } do
			tests[name]()
		end
		tests.remotes()
		printReport()
	elseif tests[cmd] then
		tests[cmd]()
		printReport()
	else
		log("Unknown test. Options: all, speed, jump, teleport, fly, noclip, health, remotes")
	end
end

local function handle(text: string)
	local cmd = text:match("^/ac%s+(%w+)")
	if cmd then
		task.spawn(run, cmd:lower())
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

log("Ready. Type /ac all  (or speed, jump, teleport, fly, noclip, health, remotes)")

if CONFIG.AutoRun then
	task.spawn(run, "all")
end

	return run
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

local oldNamecall
oldNamecall = env.hookmetamethod(game, "__namecall", (env.newcclosure or function(f) return f end)(function(self, ...)
	local method = env.getnamecallmethod()
	if recording and (method == "FireServer" or method == "InvokeServer") and typeof(self) == "Instance" then
		local args = table.pack(...)
		local parts = {}
		for i = 1, args.n do
			table.insert(parts, ser(args[i]))
		end
		local sig = self:GetFullName() .. "(" .. table.concat(parts, ", ") .. ")"
		local key = self:GetFullName()
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
	return oldNamecall(self, ...)
end))

print(("[ACScan] RECORDING for %d seconds. Now do these BY HAND in your game: attack, use skills, parry, accept and complete a quest, spend a stat point, sell an item, pick up loot."):format(RECORD_SECONDS))
task.wait(RECORD_SECONDS)
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

local runTests = setupTester()

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
	ESP = false, Fullbright = false, AntiIdle = true,
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
		remoteCache[name] = ReplicatedStorage:FindFirstChild(name, true)
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

local function scan()
	local e, l, c, p = {}, {}, {}, {}
	table.clear(npcClassCount)
	local o: { Model } = {}
	local targets = split(S.Targets)
	local lootN, chestN = split(S.LootNames), split(S.ChestNames)
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
				if S.AutoLoot and matches(d.Name, lootN) then
					table.insert(l, d)
				end
				if S.AutoChests and matches(d.Name, chestN) then
					table.insert(c, d)
				end
			end
		elseif d:IsA("BasePart") then
			if S.AutoLoot and matches(d.Name, lootN) and not d.Parent:IsA("Model") then
				table.insert(l, d)
			end
			if S.AutoChests and matches(d.Name, chestN) and not d.Parent:IsA("Model") then
				table.insert(c, d)
			end
			if S.AutoPickups and d:FindFirstChildOfClass("TouchTransmitter") then
				table.insert(p, d)
			end
		end
	end
	enemies, lootItems, chestItems, pickupItems, otherNpcs = e, l, c, p, o
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
		if v == true and k ~= "AntiIdle" and k ~= "Recovery" and k ~= "Humanize" and k ~= "SmartFarm" then
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
			local function mark(m: Model, color: Color3, label: string)
				local h = Instance.new("Highlight")
				h.Adornee = m
				h.FillColor = color
				h.Parent = espFolder
				local r = rootOf(m)
				if r then
					local bb = Instance.new("BillboardGui")
					bb.Adornee = r
					bb.AlwaysOnTop = true
					bb.Size = UDim2.fromOffset(180, 18)
					bb.StudsOffset = Vector3.new(0, 4, 0)
					local tl = Instance.new("TextLabel")
					tl.Size = UDim2.fromScale(1, 1)
					tl.BackgroundTransparency = 1
					tl.TextColor3 = color
					tl.TextStrokeTransparency = 0.4
					tl.Font = Enum.Font.GothamBold
					tl.TextSize = 12
					tl.Text = label
					tl.Parent = bb
					bb.Parent = espFolder
				end
			end
			for _, m in enemies do
				local hp = m:FindFirstChildOfClass("Humanoid")
				local hpText = hp and (" %d/%d"):format(hp.Health, hp.MaxHealth) or ""
				if #bossN > 0 and matches(m.Name, bossN) then
					mark(m, Color3.fromRGB(255, 160, 40), "BOSS " .. m.Name .. hpText)
				else
					mark(m, Color3.fromRGB(255, 60, 60), m.Name .. hpText)
				end
			end
			local classColors = {
				quest = Color3.fromRGB(255, 230, 80), merchant = Color3.fromRGB(80, 230, 130),
				blacksmith = Color3.fromRGB(180, 180, 200), guard = Color3.fromRGB(100, 140, 255),
			}
			for _, n in otherNpcs do
				local cls = GameState.classifyNPC(n)
				mark(n, classColors[cls] or Color3.fromRGB(150, 150, 150), ("%s [%s]"):format(n.Name, cls))
			end
			for _, p in Players:GetPlayers() do
				if p ~= player and p.Character then
					local h = Instance.new("Highlight")
					h.Adornee = p.Character
					h.FillColor = Color3.fromRGB(60, 160, 255)
					h.Parent = espFolder
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
local schema = {
	{ "Combat" },
	{ "AutoFarm", "Auto farm" }, { "BossFarm", "Boss farming" }, { "KillAura", "Kill aura" },
	{ "AuraRadius", "Aura radius" }, { "FastAttack", "Faster attacks" }, { "AttackSpeedMult", "Attack speed x" },
	{ "BaseAttackInterval", "Base attack interval" }, { "Hitbox", "Adjustable hitboxes" }, { "HitboxSize", "Hitbox size" },
	{ "AutoParry", "Auto parry" }, { "ParryRange", "Parry range" }, { "AutoSkills", "Auto skills" },
	{ "SkillKeys", "Skill keys (Z,X,C)" }, { "SkillInterval", "Skill interval" },
	{ "AutoEquip", "Weapon equip" }, { "WeaponName", "Weapon name" },
	{ "Targeting" },
	{ "Targets", "Targets (names, comma)" }, { "BossNames", "Boss names" }, { "TargetPriority", "Priority: nearest/lowest" },
	{ "Quests" },
	{ "AutoQuest", "Auto quests" }, { "QuestName", "Quest name" }, { "SideQuests", "Side quests" }, { "SideQuestName", "Side quest name" },
	{ "QuestActionSeconds", "Quest fallback timer (s)" },
	{ "Stats" },
	{ "AutoStats", "Auto stats" }, { "StatPriority", "Stat priorities" }, { "PointReserve", "Point reserve" },
	{ "Movement" },
	{ "InstantTravel", "Instant travel (off = tween)" }, { "TweenSpeed", "Tween speed" }, { "FarmHeight", "Farm height (fight offset Y)" },
	{ "TweenSpeedVar", "Tween speed variation" }, { "TweenCurve", "Tween path curve" },
	{ "TweenCurveMinDist", "Curve only beyond (studs)" },
	{ "Noclip", "Noclip" }, { "Flight", "Flight" }, { "FlightSpeed", "Flight speed" },
	{ "Loot" },
	{ "AutoLoot", "Auto loot" }, { "LootNames", "Loot names" }, { "AutoChests", "Auto chests" }, { "ChestNames", "Chest names" },
	{ "AutoPickups", "Auto pickups" }, { "CollectRadius", "Collect radius" }, { "TravelToLoot", "Travel to loot" },
	{ "AutoSell", "Auto sell" }, { "SellNames", "Sell names" },
	{ "Utility" },
	{ "ESP", "ESP" }, { "Fullbright", "Lighting controls" }, { "AntiIdle", "Anti-idle" },
	{ "Humanize", "Humanize behaviour" }, { "HumanizeStrength", "Humanize strength (0-1)" },
	{ "Breaks", "Random breaks" }, { "SmartFarm", "Smart farm (retreat at low HP)" },
	{ "Speed", "Speed" }, { "SpeedMult", "Speed multiplier" }, { "SpeedRamp", "Speed ramp (studs/s per s)" },
	{ "Tuning" },
	{ "ReactionMin", "Reaction delay min (s)" }, { "ReactionMax", "Reaction delay max (s)" },
	{ "FightDistance", "Fight distance (studs)" }, { "RetreatBelow", "Retreat below HP (0-1)" },
	{ "ResumeAbove", "Resume above HP (0-1)" }, { "LootDelay", "Loot delay (s)" }, { "LootRange", "Loot range (studs)" },
	{ "BreakMin", "Break min (s)" }, { "BreakMax", "Break max (s)" },
	{ "BreakEveryMin", "Break every min (s)" }, { "BreakEveryMax", "Break every max (s)" },
	{ "FlightSmoothing", "Flight smoothing" },
	{ "DebugState", "Print reconstructed state" },
	{ "Recovery", "Recovery" }, { "RecoverDelay", "Recover delay" },
	{ "MaxMinutes", "Session limit (minutes)" }, { "MaxActions", "Session limit (actions)" },
}

local gui = Instance.new("ScreenGui")
gui.Name = "ACMenu"
gui.ResetOnSpawn = false
gui.Parent = (env.gethui and env.gethui()) or player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(330, 460)
frame.Position = UDim2.fromOffset(20, 60)
frame.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
frame.Active = true
frame.Draggable = true
frame.Parent = gui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 28)
title.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Text = "Anti-cheat test menu (RightShift hides)"
title.Parent = frame

local list = Instance.new("ScrollingFrame")
list.Position = UDim2.fromOffset(0, 28)
list.Size = UDim2.new(1, 0, 1, -118)
list.BackgroundTransparency = 1
list.CanvasSize = UDim2.new()
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.ScrollBarThickness = 5
list.Parent = frame
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 3)
layout.Parent = list

local refreshers: { () -> () } = {}
local function refreshAll()
	for _, f in refreshers do
		f()
	end
end
local function styled(inst: GuiObject, h: number)
	inst.Size = UDim2.new(1, -8, 0, h)
	inst.BackgroundColor3 = Color3.fromRGB(38, 38, 48)
	inst.BorderSizePixel = 0
	inst.Parent = list
end

for _, row in schema do
	local key, label = row[1], row[2]
	if not label then
		local h = Instance.new("TextLabel")
		styled(h, 22)
		h.BackgroundColor3 = Color3.fromRGB(70, 60, 120)
		h.Text = key
		h.TextColor3 = Color3.new(1, 1, 1)
		h.Font = Enum.Font.GothamBold
		h.TextSize = 13
	elseif typeof(S[key]) == "boolean" then
		local b = Instance.new("TextButton")
		styled(b, 24)
		b.Font = Enum.Font.Gotham
		b.TextSize = 13
		local function refresh()
			b.Text = ("%s: %s"):format(label, S[key] and "ON" or "OFF")
			b.TextColor3 = S[key] and Color3.fromRGB(110, 255, 140) or Color3.fromRGB(230, 230, 230)
		end
		b.MouseButton1Click:Connect(function()
			S[key] = not S[key]
			refresh()
		end)
		table.insert(refreshers, refresh)
		refresh()
	else
		local holder = Instance.new("Frame")
		styled(holder, 24)
		local l = Instance.new("TextLabel")
		l.Size = UDim2.new(0.55, 0, 1, 0)
		l.BackgroundTransparency = 1
		l.Text = label
		l.TextColor3 = Color3.fromRGB(210, 210, 210)
		l.Font = Enum.Font.Gotham
		l.TextSize = 12
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Parent = holder
		local box = Instance.new("TextBox")
		box.Position = UDim2.fromScale(0.55, 0)
		box.Size = UDim2.fromScale(0.45, 1)
		box.BackgroundColor3 = Color3.fromRGB(55, 55, 70)
		box.TextColor3 = Color3.new(1, 1, 1)
		box.ClearTextOnFocus = false
		box.Font = Enum.Font.Gotham
		box.TextSize = 12
		box.Parent = holder
		local isNum = typeof(S[key]) == "number"
		local function refresh()
			box.Text = tostring(S[key])
		end
		box.FocusLost:Connect(function()
			if isNum then
				local n = tonumber(box.Text)
				if n then
					S[key] = n
				end
			else
				S[key] = box.Text
			end
			refresh()
		end)
		table.insert(refreshers, refresh)
		refresh()
	end
end

local bar = Instance.new("Frame")
bar.Position = UDim2.new(0, 0, 1, -90)
bar.Size = UDim2.new(1, 0, 0, 90)
bar.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
bar.Parent = frame

local stats = Instance.new("TextLabel")
stats.Size = UDim2.new(1, 0, 0, 28)
stats.BackgroundTransparency = 1
stats.TextColor3 = Color3.fromRGB(200, 200, 200)
stats.Font = Enum.Font.Code
stats.TextSize = 11
stats.Parent = bar

local function barButton(text: string, x: number, cb: () -> (), row: number?)
	local b = Instance.new("TextButton")
	b.Position = UDim2.new(x, 4, 0, 30 + ((row or 0) * 30))
	b.Size = UDim2.new(0.25, -8, 0, 26)
	b.BackgroundColor3 = Color3.fromRGB(70, 60, 120)
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 12
	b.Text = text
	b.Parent = bar
	b.MouseButton1Click:Connect(cb)
end
barButton("Save", 0, saveConfig)
barButton("Load", 0.25, function() loadConfig(refreshAll) end)
barButton("Stop all", 0.5, function() stopAll() refreshAll() end)
barButton("Reset stats", 0.75, function() table.clear(counts) totalActions = 0 startTime = os.clock() end)
barButton("Scan game", 0, function()
	task.spawn(runScanner)
end, 1)
barButton("Run tests", 0.25, function()
	task.spawn(runTests, "all")
end, 1)

task.spawn(function()
	while task.wait(0.5) do
		local parts = {}
		for k, v in counts do
			table.insert(parts, k .. ":" .. v)
		end
		stats.Text = ("actions %d | %s"):format(totalActions, table.concat(parts, " "))
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
		frame.Visible = not frame.Visible
	end
end)

print("[ACMenu] Loaded. Wire the ADAPT section to your game's remotes, then toggle features.")
