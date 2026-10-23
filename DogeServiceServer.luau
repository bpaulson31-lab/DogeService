--!strict
-- DogeService server implementation.
-- Place this ModuleScript in ServerScriptService and name it "DogeServiceServer".
-- DogeService owns the real data. Never allow a client to write arbitrary profile paths.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local DogeService = {
	Config = {
		StoreName = "DogeService_v1",
		AutosaveSeconds = 60,
		SessionLeaseSeconds = 180,
		LoadAttempts = 30,
		LoadRetrySeconds = 2,
		SaveRetries = 3,
		MaxProfileBytes = 3_800_000, -- Leave room below Roblox's per-value DataStore limit.
	},
	Template = {
		SchemaVersion = 1,
		CreatedAt = 0,
		LastJoinedAt = 0,
		Currency = {
			Coins = 0,
			Gems = 0,
		},
		Stats = {
			Level = 1,
			XP = 0,
			TotalPlaytime = 0,
		},
		Inventory = {}, -- Example: { Apple = 5, Sword = 1 }
		Equipped = {},
		Settings = {
			Music = true,
			SoundEffects = true,
		},
	},
}

local Store: GlobalDataStore? = nil
local Profiles: {[number]: any} = {}
local LoadingPlayers: {[number]: Player} = {}
local SnapshotRemote: RemoteFunction? = nil
local UpdatedRemote: RemoteEvent? = nil
local Started = false
local ShuttingDown = false
local SnapshotRequestTimes: {[number]: number} = {}

local function deepCopy(value: any, seen: {[any]: any}?): any
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] then
		return seen[value]
	end
	local result = {}
	seen[value] = result
	for key, child in pairs(value) do
		result[deepCopy(key, seen)] = deepCopy(child, seen)
	end
	return result
end

local function isFiniteNumber(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

-- DataStores only support serializable primitive values and tables. This also
-- rejects cycles, mixed dictionary/array tables, sparse arrays and metatables.
local function isSerializable(value: any, seen: {[any]: boolean}?, depth: number?): (boolean, string?)
	local currentDepth = depth or 0
	if currentDepth > 32 then
		return false, "Data nesting exceeds 32 levels."
	end
	local valueType = type(value)
	if valueType == "nil" then
		return false, "nil cannot be stored as a value."
	elseif valueType == "boolean" then
		return true, nil
	elseif valueType == "string" then
		if #value > 200_000 then return false, "A string is too long." end
		return true, nil
	elseif valueType == "number" then
		return isFiniteNumber(value), if isFiniteNumber(value) then nil else "Numbers must be finite."
	elseif valueType ~= "table" then
		return false, "Unsupported data type: " .. valueType
	end

	if getmetatable(value) ~= nil then
		return false, "Tables with metatables cannot be saved."
	end
	seen = seen or {}
	if seen[value] then
		return false, "Cyclic tables cannot be saved."
	end
	seen[value] = true

	local keyMode: string? = nil
	local numericCount = 0
	local maxIndex = 0
	for key, child in pairs(value) do
		local keyType = type(key)
		local thisMode: string
		if keyType == "string" then
			if #key > 200 then
				seen[value] = nil
				return false, "A table key is too long."
			end
			thisMode = "dictionary"
		elseif keyType == "number" and isFiniteNumber(key) and key >= 1 and key % 1 == 0 then
			thisMode = "array"
			numericCount += 1
			maxIndex = math.max(maxIndex, key)
		else
			seen[value] = nil
			return false, "Table keys must be strings or positive integer array indices."
		end
		if keyMode ~= nil and keyMode ~= thisMode then
			seen[value] = nil
			return false, "Do not mix string keys and numeric array indices in one table."
		end
		keyMode = thisMode
		local childOK, childError = isSerializable(child, seen, currentDepth + 1)
		if not childOK then
			seen[value] = nil
			return false, childError
		end
	end
	seen[value] = nil
	if keyMode == "array" and maxIndex ~= numericCount then
		return false, "Numeric arrays must be contiguous and start at index 1."
	end
	return true, nil
end

local function validateData(data: any): (boolean, string?, string?)
	local serializable, serializableError = isSerializable(data)
	if not serializable then
		return false, serializableError, nil
	end
	local encodeOK, encoded = pcall(function()
		return HttpService:JSONEncode(data)
	end)
	if not encodeOK or type(encoded) ~= "string" then
		return false, "JSON serialization failed.", nil
	end
	if #encoded > DogeService.Config.MaxProfileBytes then
		return false, "Profile data is too large for the configured safety limit.", nil
	end
	return true, nil, encoded
end

local function reconcile(data: {[any]: any}, template: {[any]: any})
	for key, defaultValue in pairs(template) do
		local current = data[key]
		if current == nil then
			data[key] = deepCopy(defaultValue)
		elseif type(defaultValue) == "table" and type(current) == "table" then
			reconcile(current, defaultValue)
		elseif type(current) ~= type(defaultValue) then
			data[key] = deepCopy(defaultValue)
		end
	end
end

local function parsePath(path: any): {any}?
	local parts = {}
	if type(path) == "string" then
		if path == "" or path:sub(1, 1) == "." or path:sub(-1) == "." or path:find("..", 1, true) then
			return nil
		end
		for part in string.gmatch(path, "[^%.]+") do
			table.insert(parts, part)
		end
	elseif type(path) == "table" then
		for _, part in ipairs(path) do
			table.insert(parts, part)
		end
	else
		return nil
	end
	if #parts == 0 or #parts > 16 then return nil end
	for _, part in ipairs(parts) do
		if type(part) == "string" then
			if part == "" then return nil end
		elseif type(part) == "number" then
			if part < 1 or part % 1 ~= 0 then return nil end
		else
			return nil
		end
	end
	return parts
end

local function readRawPath(root: any, path: any): any
	local parts = parsePath(path)
	if not parts then return nil end
	local current = root
	for _, part in ipairs(parts) do
		if type(current) ~= "table" then return nil end
		current = current[part]
		if current == nil then return nil end
	end
	return current
end

local function getRemoteFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild("DogeServiceRemotes")
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then existing:Destroy() end
	local folder = Instance.new("Folder")
	folder.Name = "DogeServiceRemotes"
	folder.Parent = ReplicatedStorage
	return folder
end

local function getOrCreateRemote(parent: Instance, name: string, className: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	if existing then existing:Destroy() end
	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function clearProfile(profile: any)
	if Profiles[profile.UserId] == profile then
		Profiles[profile.UserId] = nil
	end
end

local function publish(profile: any, force: boolean?)
	if not UpdatedRemote or not profile.Player or profile.Player.Parent ~= Players then
		return
	end
	local _, _, encoded = validateData(profile.Data)
	if not encoded then
		return
	end
	if force ~= true and encoded == profile._lastPublishedJson then
		return
	end
	profile._lastPublishedJson = encoded
	UpdatedRemote:FireClient(profile.Player, profile:Snapshot())
end

local function invalidateProfile(profile: any, message: string)
	profile._active = false
	profile._releasing = false
	profile._pendingRelease = false
	clearProfile(profile)
	warn("[DogeService] Profile session lost for user " .. tostring(profile.UserId) .. ": " .. message)
	if UpdatedRemote and profile.Player and profile.Player.Parent == Players then
		UpdatedRemote:FireClient(profile.Player, { Closed = true, UserId = profile.UserId })
		profile.Player:Kick("Your data session ended unexpectedly. Please rejoin so your progress can be loaded safely.")
	end
end

local ProfileMethods = {}
ProfileMethods.__index = ProfileMethods

function ProfileMethods:IsActive(): boolean
	return self._active == true and self._releasing ~= true
end

function ProfileMethods:GetName(): string
	if self.Player and self.Player.Parent == Players then
		return self.Player.Name
	end
	return self.Name
end

function ProfileMethods:GetUserId(): number
	return self.UserId
end

function ProfileMethods:Snapshot(): {[string]: any}
	return {
		Name = self:GetName(),
		UserId = self.UserId,
		Data = deepCopy(self.Data),
		LoadedAt = self.LoadedAt,
		IsActive = self._active,
	}
end

function ProfileMethods:Get(path: any, defaultValue: any?): any
	local value = readRawPath(self.Data, path)
	if value == nil then return deepCopy(defaultValue) end
	return deepCopy(value)
end

function ProfileMethods:GetValue(path: any, defaultValue: any?): any
	return self:Get(path, defaultValue)
end

function ProfileMethods:GetInventory(): {[any]: any}
	local inventory = self:Get("Inventory", {})
	return if type(inventory) == "table" then inventory else {}
end

function ProfileMethods:Sync(): (boolean, string?)
	if not self:IsActive() then return false, "Profile is not active." end
	local ok, err = validateData(self.Data)
	if not ok then return false, err end
	publish(self, false)
	return true, nil
end

function ProfileMethods:Set(path: any, value: any): (boolean, any)
	if not self:IsActive() then return false, "Profile is not active." end
	local parts = parsePath(path)
	if not parts then return false, "Invalid data path." end
	if value ~= nil then
		local valueOK, valueError = isSerializable(value)
		if not valueOK then return false, valueError end
	end

	local backup = deepCopy(self.Data)
	local current = self.Data
	for index = 1, #parts - 1 do
		local part = parts[index]
		if current[part] == nil then
			current[part] = {}
		elseif type(current[part]) ~= "table" then
			self.Data = backup
			return false, "A parent path is not a table."
		end
		current = current[part]
	end
	local leaf = parts[#parts]
	current[leaf] = if value == nil then nil else deepCopy(value)

	local dataOK, dataError = validateData(self.Data)
	if not dataOK then
		self.Data = backup
		return false, dataError
	end
	publish(self, false)
	return true, deepCopy(readRawPath(self.Data, path))
end

function ProfileMethods:Increment(path: any, amount: number?): (boolean, any)
	if not self:IsActive() then return false, "Profile is not active." end
	local delta = if amount == nil then 1 else amount
	if type(delta) ~= "number" or not isFiniteNumber(delta) then
		return false, "Increment amount must be a finite number."
	end
	local current = readRawPath(self.Data, path)
	if current == nil then current = 0 end
	if type(current) ~= "number" or not isFiniteNumber(current) then
		return false, "The selected value is not a number."
	end
	local newValue = current + delta
	if not isFiniteNumber(newValue) then return false, "Increment would produce an invalid number." end
	local success, result = self:Set(path, newValue)
	if not success then return false, result end
	return true, newValue
end

local function validItemRequest(itemId: any, quantity: any): (boolean, string?)
	if type(itemId) ~= "string" or itemId == "" or #itemId > 100 then
		return false, "Item ID must be a non-empty string up to 100 characters."
	end
	if type(quantity) ~= "number" or not isFiniteNumber(quantity) or quantity < 1 or quantity % 1 ~= 0 then
		return false, "Quantity must be a positive integer."
	end
	if quantity > 1_000_000 then return false, "Quantity is too large." end
	return true, nil
end

function ProfileMethods:AddItem(itemId: string, quantity: number?): (boolean, any)
	if not self:IsActive() then return false, "Profile is not active." end
	local count = if quantity == nil then 1 else quantity
	local requestOK, requestError = validItemRequest(itemId, count)
	if not requestOK then return false, requestError end
	if type(self.Data.Inventory) ~= "table" then return false, "Inventory data is invalid." end
	local current = self.Data.Inventory[itemId] or 0
	if type(current) ~= "number" or current < 0 or current % 1 ~= 0 then
		return false, "This inventory entry is invalid."
	end
	local backup = deepCopy(self.Data)
	self.Data.Inventory[itemId] = current + count
	local dataOK, dataError = validateData(self.Data)
	if not dataOK then
		self.Data = backup
		return false, dataError
	end
	publish(self, false)
	return true, self.Data.Inventory[itemId]
end

function ProfileMethods:RemoveItem(itemId: string, quantity: number?): (boolean, any)
	if not self:IsActive() then return false, "Profile is not active." end
	local count = if quantity == nil then 1 else quantity
	local requestOK, requestError = validItemRequest(itemId, count)
	if not requestOK then return false, requestError end
	if type(self.Data.Inventory) ~= "table" then return false, "Inventory data is invalid." end
	local current = self.Data.Inventory[itemId] or 0
	if type(current) ~= "number" or current < count then
		return false, "Not enough of this item."
	end
	local backup = deepCopy(self.Data)
	local remaining = current - count
	if remaining == 0 then
		self.Data.Inventory[itemId] = nil
	else
		self.Data.Inventory[itemId] = remaining
	end
	local dataOK, dataError = validateData(self.Data)
	if not dataOK then
		self.Data = backup
		return false, dataError
	end
	publish(self, false)
	return true, remaining
end

function ProfileMethods:HasItem(itemId: string, quantity: number?): boolean
	local count = if quantity == nil then 1 else quantity
	if type(itemId) ~= "string" or type(count) ~= "number" then return false end
	local inventory = self.Data.Inventory
	return type(inventory) == "table" and type(inventory[itemId]) == "number" and inventory[itemId] >= count
end

local function saveProfile(profile: any, releaseSession: boolean): (boolean, string?)
	while profile._saving do
		task.wait(0.05)
	end
	if not profile._active then return false, "Profile is inactive." end
	if profile._releasing and not releaseSession then return false, "Profile is releasing." end
	if not Store then return false, "DataStore has not been initialized." end

	profile._saving = true
	local snapshot = deepCopy(profile.Data)
	local valid, validationError = validateData(snapshot)
	if not valid then
		profile._saving = false
		return false, validationError
	end

	local lastError = "Unknown save error."
	for attempt = 1, DogeService.Config.SaveRetries do
		local ownsSession = false
		local lockLost = false
		local result: any = nil
		local ok, err = pcall(function()
			result = (Store :: GlobalDataStore):UpdateAsync("Player_" .. tostring(profile.UserId), function(oldValue)
				ownsSession = false
				lockLost = false
				if type(oldValue) ~= "table" or type(oldValue.Meta) ~= "table" or type(oldValue.Meta.Session) ~= "table" then
					lockLost = true
					return oldValue
				end
				if oldValue.Meta.Session.Token ~= profile._token then
					lockLost = true
					return oldValue
				end
				ownsSession = true
				local updated = deepCopy(oldValue)
				updated.Data = snapshot
				updated.Meta = type(updated.Meta) == "table" and updated.Meta or {}
				updated.Meta.Version = 1
				if releaseSession then
					updated.Meta.Session = nil
				else
					updated.Meta.Session = {
						Token = profile._token,
						JobId = game.JobId,
						PlaceId = game.PlaceId,
						ExpiresAt = os.time() + DogeService.Config.SessionLeaseSeconds,
					}
				end
				return updated
			end)
		end)

		if ok and ownsSession and type(result) == "table" then
			if releaseSession then
				if type(result.Meta) == "table" and result.Meta.Session == nil then
					profile._lastSavedAt = os.time()
					profile._saving = false
					return true, nil
				end
			elseif type(result.Meta) == "table" and type(result.Meta.Session) == "table" and result.Meta.Session.Token == profile._token then
				profile._lastSavedAt = os.time()
				profile._saving = false
				publish(profile, false)
				return true, nil
			end
		end

		if lockLost then
			profile._saving = false
			invalidateProfile(profile, "this server no longer owns the stored session lock")
			return false, "SessionLockLost"
		end
		if not ok then
			lastError = tostring(err)
		else
			lastError = "The DataStore did not confirm ownership of the session lock."
		end
		if attempt < DogeService.Config.SaveRetries then
			task.wait(math.min(2 ^ attempt, 8))
		end
	end
	profile._saving = false
	return false, lastError
end

function ProfileMethods:Save(): (boolean, string?)
	return saveProfile(self, false)
end

function ProfileMethods:Release(): (boolean, string?)
	if not self._active then return true, nil end
	self._releasing = true
	local success, reason = saveProfile(self, true)
	if success then
		self._active = false
		self._releasing = false
		self._pendingRelease = false
		clearProfile(self)
		return true, nil
	end
	if self._active then
		self._releasing = false
		self._pendingRelease = true
	end
	return false, reason
end

function DogeService:GetProfile(player: Player): any
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return nil end
	local profile = Profiles[player.UserId]
	if profile and profile.Player == player and profile._active then
		return profile
	end
	return nil
end

function DogeService:WaitForProfile(player: Player, timeoutSeconds: number?): (any, string?)
	local timeout = if type(timeoutSeconds) == "number" then math.max(timeoutSeconds, 0) else 15
	local deadline = os.clock() + timeout
	repeat
		local profile = self:GetProfile(player)
		if profile then return profile, nil end
		if player.Parent ~= Players then return nil, "Player left before profile loaded." end
		task.wait(0.1)
	until os.clock() >= deadline
	return nil, "Timed out waiting for profile."
end

function DogeService:GetValue(player: Player, path: any, defaultValue: any?): any
	local profile = self:GetProfile(player)
	return if profile then profile:Get(path, defaultValue) else deepCopy(defaultValue)
end

function DogeService:SetValue(player: Player, path: any, value: any): (boolean, any)
	local profile = self:GetProfile(player)
	if not profile then return false, "Profile is not loaded." end
	return profile:Set(path, value)
end

function DogeService:Increment(player: Player, path: any, amount: number?): (boolean, any)
	local profile = self:GetProfile(player)
	if not profile then return false, "Profile is not loaded." end
	return profile:Increment(path, amount)
end

function DogeService:GetInventory(player: Player): {[any]: any}
	local profile = self:GetProfile(player)
	return if profile then profile:GetInventory() else {}
end

function DogeService:AddItem(player: Player, itemId: string, quantity: number?): (boolean, any)
	local profile = self:GetProfile(player)
	if not profile then return false, "Profile is not loaded." end
	return profile:AddItem(itemId, quantity)
end

function DogeService:RemoveItem(player: Player, itemId: string, quantity: number?): (boolean, any)
	local profile = self:GetProfile(player)
	if not profile then return false, "Profile is not loaded." end
	return profile:RemoveItem(itemId, quantity)
end

local function loadProfile(player: Player)
	local userId = player.UserId
	local existingLoad = LoadingPlayers[userId]
	if existingLoad and existingLoad.Parent == Players then return end
	LoadingPlayers[userId] = player

	local validTemplate, templateError = validateData(DogeService.Template)
	if not validTemplate then
		warn("[DogeService] Invalid template:", templateError)
		if player.Parent == Players then player:Kick("Player data configuration is invalid. Please try again later.") end
		if LoadingPlayers[userId] == player then LoadingPlayers[userId] = nil end
		return
	end

	local key = "Player_" .. tostring(userId)
	local token = HttpService:GenerateGUID(false)
	local session = {
		Token = token,
		JobId = game.JobId,
		PlaceId = game.PlaceId,
		ExpiresAt = os.time() + DogeService.Config.SessionLeaseSeconds,
	}
	local loadedRecord: any = nil
	local lastError = "No data returned."
	local gotProfile = false
	local recordWasInvalid = false

	for attempt = 1, DogeService.Config.LoadAttempts do
		if player.Parent ~= Players then break end
		local lockBusy = false
		local acquired = false
		local invalidRecord = false
		local result: any = nil
		local ok, err = pcall(function()
			result = (Store :: GlobalDataStore):UpdateAsync(key, function(oldValue)
				lockBusy = false
				acquired = false
				invalidRecord = false
				local record
				if oldValue == nil then
					record = { Data = deepCopy(DogeService.Template), Meta = { Version = 1 } }
				elseif type(oldValue) == "table" and type(oldValue.Data) == "table" then
					record = deepCopy(oldValue)
				else
					invalidRecord = true
					return nil
				end
				record.Meta = if type(record.Meta) == "table" then record.Meta else {}
				local oldSession = record.Meta.Session
				if type(oldSession) == "table"
					and type(oldSession.ExpiresAt) == "number"
					and oldSession.ExpiresAt > os.time()
					and oldSession.Token ~= token then
					lockBusy = true
					return nil
				end
				reconcile(record.Data, DogeService.Template)
				if record.Data.CreatedAt == 0 then record.Data.CreatedAt = os.time() end
				if record.Data.LastJoinedAt ~= nil then record.Data.LastJoinedAt = os.time() end
				record.Data.SchemaVersion = DogeService.Template.SchemaVersion or 1
				local dataOK = validateData(record.Data)
				if not dataOK then
					invalidRecord = true
					return nil
				end
				record.Meta.Version = 1
				record.Meta.Session = deepCopy(session)
				acquired = true
				return record
			end)
		end)

		if ok and acquired and type(result) == "table" and type(result.Meta) == "table"
			and type(result.Meta.Session) == "table" and result.Meta.Session.Token == token then
			loadedRecord = result
			gotProfile = true
			break
		end
		if invalidRecord then
			recordWasInvalid = true
			lastError = "Stored profile record is malformed; refusing to overwrite it."
			break
		end
		if not ok then
			lastError = tostring(err)
			warn("[DogeService] Load attempt " .. tostring(attempt) .. " failed for " .. tostring(userId) .. ": " .. lastError)
			task.wait(math.min(DogeService.Config.LoadRetrySeconds * (2 ^ math.min(attempt - 1, 3)), 8))
		elseif lockBusy then
			lastError = "Profile is active on another server."
			task.wait(DogeService.Config.LoadRetrySeconds)
		else
			lastError = "DataStore did not grant the profile session."
			task.wait(DogeService.Config.LoadRetrySeconds)
		end
	end

	if not gotProfile or not loadedRecord then
		if LoadingPlayers[userId] == player then LoadingPlayers[userId] = nil end
		if player.Parent == Players then
			warn("[DogeService] Could not load " .. player.Name .. " (" .. tostring(userId) .. "): " .. lastError)
			local reason = if recordWasInvalid then "Your saved data could not be read safely. Please contact the game developer." else "Your data could not be loaded safely. Please rejoin in a moment."
			player:Kick(reason)
		end
		return
	end

	local profile = setmetatable({
		Player = player,
		Name = player.Name,
		UserId = userId,
		Data = loadedRecord.Data,
		LoadedAt = os.time(),
		_key = key,
		_token = token,
		_active = true,
		_releasing = false,
		_pendingRelease = false,
		_saving = false,
		_lastSavedAt = os.time(),
		_lastPublishedJson = nil,
	}, ProfileMethods)

	if LoadingPlayers[userId] == player then LoadingPlayers[userId] = nil end
	if player.Parent ~= Players then
		profile:Release()
		return
	end

	local currentProfile = Profiles[userId]
	if currentProfile and currentProfile ~= profile and currentProfile._active then
		-- Defensive path for an unexpected duplicate load in the same server.
		profile:Release()
		return
	end
	Profiles[userId] = profile
	publish(profile, true)

	task.spawn(function()
		while profile._active and not ShuttingDown do
			task.wait(DogeService.Config.AutosaveSeconds + math.random(0, 10))
				if not profile._active or ShuttingDown then break end
				local success, saveError
				if profile._pendingRelease then
					success, saveError = profile:Release()
				else
					success, saveError = profile:Save()
				end
				if not success and saveError ~= "SessionLockLost" then
					warn("[DogeService] Autosave failed for " .. tostring(userId) .. ": " .. tostring(saveError))
				end
		end
	end)
end

local function onPlayerRemoving(player: Player)
	local profile = DogeService:GetProfile(player)
	if profile then
		local success, err = profile:Release()
		if not success and err ~= "SessionLockLost" then
			warn("[DogeService] Release deferred for " .. player.Name .. ": " .. tostring(err))
		end
	end
	SnapshotRequestTimes[player.UserId] = nil
end

local function onShutdown()
	ShuttingDown = true
	local pending = {}
	for _, profile in pairs(Profiles) do
		table.insert(pending, profile)
	end
	local completed = 0
	for _, profile in ipairs(pending) do
		task.spawn(function()
			local success, err = profile:Release()
			if not success and err ~= "SessionLockLost" then
				warn("[DogeService] Shutdown save failed for " .. tostring(profile.UserId) .. ": " .. tostring(err))
			end
			completed += 1
		end)
	end
	local deadline = os.clock() + 25
	while completed < #pending and os.clock() < deadline do
		task.wait(0.1)
	end
end

function DogeService:Start(): boolean
	if not RunService:IsServer() then
		error("DogeService:Start() may only be called on the server.")
	end
	if Started then return true end
	if type(self.Config.StoreName) ~= "string" or self.Config.StoreName == "" then
		error("DogeService.Config.StoreName must be a non-empty string.")
	end
	Store = DataStoreService:GetDataStore(self.Config.StoreName)
	local folder = getRemoteFolder()
	SnapshotRemote = getOrCreateRemote(folder, "GetSnapshot", "RemoteFunction") :: RemoteFunction
	UpdatedRemote = getOrCreateRemote(folder, "ProfileUpdated", "RemoteEvent") :: RemoteEvent

	SnapshotRemote.OnServerInvoke = function(player: Player)
		-- This remote only returns the caller's own profile; it never accepts a target user ID.
		local now = os.clock()
		local last = SnapshotRequestTimes[player.UserId] or 0
		if now - last < 0.15 then return nil end
		SnapshotRequestTimes[player.UserId] = now
		local profile = DogeService:GetProfile(player)
		return if profile then profile:Snapshot() else nil
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(loadProfile, player)
	end)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(loadProfile, player)
	end
	game:BindToClose(onShutdown)
	Started = true
	return true
end

return DogeService
