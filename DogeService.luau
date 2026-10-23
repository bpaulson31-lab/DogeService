--!strict
-- DogeService public facade.
-- Place this ModuleScript in ReplicatedStorage and name it "DogeService".
-- Server callers receive the server implementation; clients receive a read-only API.

local RunService = game:GetService("RunService")

if RunService:IsServer() then
	local ServerScriptService = game:GetService("ServerScriptService")
	return require(ServerScriptService:WaitForChild("DogeServiceServer"))
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = ReplicatedStorage:WaitForChild("DogeServiceRemotes")
local GetSnapshotRemote = Remotes:WaitForChild("GetSnapshot") :: RemoteFunction
local ProfileUpdatedRemote = Remotes:WaitForChild("ProfileUpdated") :: RemoteEvent

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
	if #parts == 0 or #parts > 16 then
		return nil
	end
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

local function readPath(root: any, path: any): any
	local parts = parsePath(path)
	if not parts then return nil end
	local value = root
	for _, part in ipairs(parts) do
		if type(value) ~= "table" then return nil end
		value = value[part]
		if value == nil then return nil end
	end
	return value
end

local Client = {}
local currentSnapshot: any = nil
local profileChanged = Instance.new("BindableEvent")
Client.ProfileUpdated = profileChanged.Event

local function acceptSnapshot(snapshot: any)
	if type(snapshot) ~= "table" then
		return
	end
	if snapshot.Closed == true then
		currentSnapshot = nil
		profileChanged:Fire(nil)
		return
	end
	if type(snapshot.Data) ~= "table" then
		return
	end
	currentSnapshot = deepCopy(snapshot)
	profileChanged:Fire(deepCopy(currentSnapshot))
end

ProfileUpdatedRemote.OnClientEvent:Connect(acceptSnapshot)

function Client:GetProfile(forceRefresh: boolean?): any
	if forceRefresh == true or currentSnapshot == nil then
		local ok, result = pcall(function()
			return GetSnapshotRemote:InvokeServer()
		end)
		if ok then
			acceptSnapshot(result)
		else
			warn("[DogeService] Could not retrieve profile snapshot:", result)
		end
	end
	return currentSnapshot and deepCopy(currentSnapshot) or nil
end

function Client:WaitForProfile(timeoutSeconds: number?): (any, string?)
	local timeout = if type(timeoutSeconds) == "number" then math.max(timeoutSeconds, 0) else 15
	local deadline = os.clock() + timeout
	repeat
		local snapshot = self:GetProfile(true)
		if snapshot then
			return snapshot, nil
		end
		task.wait(0.25)
	until os.clock() >= deadline
	return nil, "Timed out waiting for DogeService profile data."
end

function Client:GetValue(path: any, defaultValue: any?, forceRefresh: boolean?): any
	local snapshot = self:GetProfile(forceRefresh)
	if not snapshot then
		return deepCopy(defaultValue)
	end
	local value = readPath(snapshot.Data, path)
	if value == nil then
		return deepCopy(defaultValue)
	end
	return deepCopy(value)
end

function Client:GetInventory(forceRefresh: boolean?): {[any]: any}
	local inventory = self:GetValue("Inventory", {}, forceRefresh)
	return if type(inventory) == "table" then inventory else {}
end

function Client:GetName(forceRefresh: boolean?): string?
	local snapshot = self:GetProfile(forceRefresh)
	return if snapshot then snapshot.Name else nil
end

function Client:GetUserId(forceRefresh: boolean?): number?
	local snapshot = self:GetProfile(forceRefresh)
	return if snapshot then snapshot.UserId else nil
end

function Client:IsLoaded(): boolean
	return currentSnapshot ~= nil
end

-- Clients intentionally cannot change persistent profile data.
function Client:SetValue(_path: any, _value: any): (boolean, string)
	return false, "DogeService is read-only on the client. Change profile data in a server Script."
end

function Client:Increment(_path: any, _amount: number?): (boolean, string)
	return false, "DogeService is read-only on the client. Change profile data in a server Script."
end

function Client:AddItem(_itemId: string, _quantity: number?): (boolean, string)
	return false, "DogeService is read-only on the client. Change profile data in a server Script."
end

function Client:RemoveItem(_itemId: string, _quantity: number?): (boolean, string)
	return false, "DogeService is read-only on the client. Change profile data in a server Script."
end

return Client
