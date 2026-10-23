--!strict
-- Place this Script in ServerScriptService.
-- It starts DogeService after the public ModuleScript and server implementation are installed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DogeService = require(ReplicatedStorage:WaitForChild("DogeService"))

DogeService:Start()
print("[DogeService] Started.")
