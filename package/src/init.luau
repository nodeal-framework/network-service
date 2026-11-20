--[[
    © 2026 Nodeal Package. All rights reserved.

    This source code is open-source and free for modification and use in your projects.
    However, you may not sell, sublicense, or distribute this framework (or 
    any rebranded version of it) as a standalone product.

    Any public use or redistribution of this module requires this header 
    to remain intact in the source code. For the complete license terms, 
    please visit: https://www.nodeal.dev/license
]]

local __=_G() local NetworkService = {}

--// Services //--
local RunService = game:GetService("RunService")
local BufferizeService = game:GetService("BufferizeService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Private //--
local DefaultProtocol = BufferizeService.new({
	Timestamp = buffer.number.f64
})

local offset = --[[e1]]123456789--[[/e1]]

local client = RunService:IsClient()
local server = RunService:IsServer()

local context = client and "Client" or "Server"

local syncEvent

local lastSyncOffset
local ignoreHeader = false

local hasInitialized = false

local pendingRemoteHandlers = {}
local remotes = {
	RemoteEvent = {},
	RemoteFunction = {},
	UnreliableRemoteEvent = {}
}

--// Private Functions //--
local function _generate_checksum(packet: buffer): buffer
	local size = buffer.len(packet)
	local checksum = offset % 256

	for i = 0, size - 1 do
		checksum = (checksum + buffer.readu8(packet, i)) % 256
	end

	local res = buffer.create(1)
	buffer.writeu8(res, 0, checksum)
	return res
end

local function _verify_checksum(checksum: buffer, packet: buffer): boolean
	if type(checksum) ~= "buffer" or type(packet) ~= "buffer" then return false end

	local size = buffer.len(packet)
	local calculated = offset % 256

	for i = 0, size - 1 do
		calculated = (calculated + buffer.readu8(packet, i)) % 256
	end

	return buffer.readu8(checksum, 0) == calculated
end

local function _encode_packet(self, ...: any?): (buffer, buffer)
	local header = {}

	header.Timestamp = ignoreHeader and 0 or NetworkService:GetSyncedTime()

	local packet = (self.Interface or DefaultProtocol):Bufferize(header, ...)
	local checksum = _generate_checksum(packet)

	return checksum, packet
end

local function _decode_packet(self, ...: any?): ...any?
	local player: Player?, checksum: buffer, packet: buffer

	if client then
		checksum, packet = ...
	else
		player, checksum, packet = ...
	end

	if not _verify_checksum(checksum, packet) then
		print("Hummm, thats sus...")
		return nil
	end

	local decoded = table.pack((self.Interface or DefaultProtocol):Debufferize(packet))

	local header = decoded[1]

	if client then
		if header.Timestamp and lastSyncOffset then
			local delta = header.Timestamp - os.clock()

			if math.abs(delta) > math.abs(lastSyncOffset) then
				lastSyncOffset = delta
			end
		end
	else
		header.Player = player
	end

	return decoded
end

local function _handle_remote_registration(remote: RemoteEvent | RemoteFunction | UnreliableRemoteEvent)
	if not remotes[remote.ClassName] then return end
	remotes[remote.ClassName][remote.Name] = remote

	local name = remote.Name
	remote.Name = ""

	remote.Parent = game.NetworkClient

	local handlers = pendingRemoteHandlers[name]
	if not handlers then return end

	local originalCount = #handlers
	local keepCount = 0

	for i = 1, originalCount do
		local datas = handlers[i]

		if datas[1] == remote.ClassName then
			if remote.ClassName == "RemoteFunction" then
				remote[`On{context}Invoke`] = datas[2]
			else
				remote[`On{context}Event`]:Connect(datas[2])
			end
		else
			keepCount += 1
			handlers[keepCount] = datas
		end
	end

	for i = keepCount + 1, originalCount do
		handlers[i] = nil
	end

	if keepCount == 0 then
		pendingRemoteHandlers[name] = nil
	end
end

local function _get_instance(classname: string, name: string): (RemoteEvent | RemoteFunction)?
	local category = remotes[classname]

	local remote = category[name]

	if not remote and server then
		remote = Instance.new(classname)
		remote.Name = name
		remote.Parent = ReplicatedStorage

		category[name] = remote
	end

	return remote
end

--// Types //--
export type PacketHeader = {
	Timestamp: number,
	Player: Player?,
}

-- Network --
local Network = {}
Network.__index = Network
Network.__type = "Network"

--[=[
	Set the interface of the network.
]=]
function Network:SetInterface(interface: any?, ...): Network
	if not interface then
		self.Interface = nil
		return
	end

	if typeof(interface) ~= ("BufferDescriptor") then
		interface = BufferizeService.new(interface, ...)
	end

	self.Interface = BufferizeService.merge(DefaultProtocol, interface)

	return self
end

--[=[
	Sends given datas to the network via UDP.
]=]
function Network:Emit(...: any?): ()
	local remote = _get_instance("UnreliableRemoteEvent", self.Name) :: UnreliableRemoteEvent
	if not remote then return end

	if client then
		local checksum, packet = _encode_packet(self, ...)
		remote:FireServer(checksum, packet)
	else
		local target = select(1, ...)
		local checksum, packet = _encode_packet(self, select(2, ...))

		if typeof(target) == "Instance" and target:IsA("Player") then
			remote:FireClient(target, checksum, packet)
		elseif type(target) == "table" then
			for _, player: Player in target do
				if typeof(player) == "Instance" and player:IsA("Player") then
					remote:FireClient(player, checksum, packet)
				end
			end
		else
			warn(`Invalid argument #1 to 'Fire' for '{self.Name}' (Player or table expected, got {typeof(target)})`)
		end
	end
end

--[=[
	Sends given datas to the network via TCP.
]=]
function Network:Fire(...: any?): ()
	local remote = _get_instance("RemoteEvent", self.Name) :: RemoteEvent
	if not remote then return end

	if client then
		local checksum, packet = _encode_packet(self, ...)
		remote:FireServer(checksum, packet)
	else
		local target = select(1, ...)
		local checksum, packet = _encode_packet(self, select(2, ...))

		if typeof(target) == "Instance" and target:IsA("Player") then
			remote:FireClient(target, checksum, packet)
		elseif type(target) == "table" then
			for _, player: Player in target do
				if typeof(player) == "Instance" and player:IsA("Player") then
					remote:FireClient(player, checksum, packet)
				end
			end
		else
			warn(`Invalid argument #1 to 'Fire' for '{self.Name}' (Player or table expected, got {typeof(target)})`)
		end
	end
end

--[=[
	Invokes a network call and returns the result.
	
	@yield
]=]
function Network:Invoke(...: any?): any?
	local remote = _get_instance("RemoteFunction", self.Name) :: RemoteFunction
	if not remote then return end

	if client then
		local checksum, packet = _encode_packet(self, ...)
		return remote:InvokeServer(checksum, packet)
	else
		local target = select(1, ...)

		if typeof(target) == "Instance" and target:IsA("Player") then
			local checksum, packet = _encode_packet(self, select(2, ...))
			return remote:InvokeClient(target, checksum, packet)
		else
			warn(`Invalid argument #1 to 'Invoke' for '{self.Name}' (Player expected, got {typeof(target)})`)
		end
	end

	return nil
end

---

--[=[
	Registers a function to be called when network datas are received via UDP.
]=]
function Network:OnEmit(callback: (header: PacketHeader, ...any?) -> ()): ()
	local remote = _get_instance("UnreliableRemoteEvent", self.Name) :: UnreliableRemoteEvent

	local middleware = function(...): ()
		local decoded = _decode_packet(self, ...)

		if not decoded then
			warn("The received packet is invalid.")
			return 
		end

		callback(table.unpack(decoded, 1, decoded.n))
	end

	if remote then
		remote[`On{context}Event`]:Connect(middleware)
	else
		pendingRemoteHandlers[self.Name] = pendingRemoteHandlers[self.Name] or {}

		table.insert(pendingRemoteHandlers[self.Name], {"UnreliableRemoteEvent", middleware})
	end
end

game:RegisterDecorator("OnEmit", function(_, func: (header: PacketHeader, ...any?) -> (), name: string): (header: PacketHeader, ...any?) -> ()
	NetworkService:GetNetwork(name):OnEmit(func)
	return func
end)

--[=[
	Registers a function to be called when network datas are received via TCP.
]=]
function Network:OnEvent(callback: (header: PacketHeader, ...any?) -> ()): ()
	local remote = _get_instance("RemoteEvent", self.Name) :: RemoteEvent

	local middleware = function(...): ()
		local decoded = _decode_packet(self, ...)

		if not decoded then
			warn("The received packet is invalid.")
			return 
		end

		callback(table.unpack(decoded, 1, decoded.n))
	end

	if remote then
		remote[`On{context}Event`]:Connect(middleware)
	else
		pendingRemoteHandlers[self.Name] = pendingRemoteHandlers[self.Name] or {}

		table.insert(pendingRemoteHandlers[self.Name], {"RemoteEvent", middleware})
	end
end

game:RegisterDecorator("OnEvent", function(_, func: (header: PacketHeader, ...any?) -> (...any?), name: string): (header: PacketHeader, ...any?) -> (...any?)
	NetworkService:GetNetwork(name):OnEvent(func)
	return func
end)

--[=[
	Registers a function to handle network invocations and return results.
]=]
function Network:OnInvoke(callback: (header: PacketHeader, ...any) -> (...any)): ()
	local remote = _get_instance("RemoteFunction", self.Name) :: RemoteFunction

	local middleware = function(...: any): ...any
		local decoded = _decode_packet(self, ...)

		if not decoded then
			warn("The received packet is invalid.")
			return nil
		end

		return callback(table.unpack(decoded, 1, decoded.n))
	end

	if remote then
		remote[`On{context}Invoke`] = middleware
	else
		pendingRemoteHandlers[self.Name] = pendingRemoteHandlers[self.Name] or {}

		table.insert(pendingRemoteHandlers[self.Name], {"RemoteFunction", middleware})
	end
end

game:RegisterDecorator("OnInvoke", function(_, func: (header: PacketHeader, ...any?) -> (...any?), name: string): (header: PacketHeader, ...any?) -> (...any?)
	NetworkService:GetNetwork(name):OnInvoke(func)
	return func
end)

--[=[
	Disconnects all handlers for the network instance.
]=]
function Network:Destroy(): ()
	for _, storage in remotes do
		if not storage[self.Name] then continue end

		storage[self.Name]:Destroy()
		storage[self.Name] = nil
	end

	setmetatable(self, {})
end

--// Public //--
local instances = {}

--[=[
	Creates a new network instance with the given name.
	
	@typecheck
]=]
function NetworkService:RegisterNetwork(name: string): Network
	local self = setmetatable({} :: any, Network)

	self.Name = name

	instances[self.Name] = self
	return self
end

--[=[
	Returns an existing network interface by name or creates a new one.
	
	@typecheck
]=]
function NetworkService:GetNetwork(name: string): Network
	return instances[name] or NetworkService:RegisterNetwork(name)
end

--[=[
	Waits until the next synchronization step based on the given duration.
	
	@yield
]=]
function NetworkService:WaitForSyncStep(durration: number): number
	local timestamp = NetworkService:GetSyncedTime()
	local targetTick = math.ceil(timestamp / durration) * durration

	repeat
		task.wait()
	until NetworkService:GetSyncedTime() >= targetTick

	return NetworkService:GetSyncedTime() - timestamp
end

--[=[
	Returns the current synchronized networks time.
]=]
function NetworkService:GetSyncedTime(): number
	if not hasInitialized then
		repeat task.wait() until hasInitialized
	end

	local result

	if client then
		if not lastSyncOffset then
			ignoreHeader = true
			lastSyncOffset = syncEvent:Invoke() - os.clock()
			ignoreHeader = false
		end

		result = os.clock() + lastSyncOffset
	else
		result = os.clock()
	end

	return result
end

--[=[
	Set the networking session checksum offset.
]=]
function NetworkService:IncrementOffset(increment: number): ()
	NetworkService.IncrementOffset = function() end
	offset += increment
end

--[=[
	@hidden
	@async
]=]
function NetworkService.Init(): ()
	syncEvent = NetworkService:GetNetwork("<<<Nodeal>>>")

	if client then
		ReplicatedStorage.ChildAdded:Connect(_handle_remote_registration)

		for _, remote: RemoteEvent | RemoteFunction | UnreliableRemoteEvent in ReplicatedStorage:GetChildren() do
			_handle_remote_registration(remote)
		end
	else
		syncEvent:OnInvoke(function()
			return NetworkService:GetSyncedTime()
		end)
	end

	hasInitialized = true
end

game:RegisterService("NetworkService", NetworkService)

--[=[
	Provides a structured interface for client-server communication in Roblox using RemoteEvents and RemoteFunctions.
]=]
return __(NetworkService)