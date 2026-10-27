--!strict
--[[
	RateLimiter.luau
	Authoritative per-player and per-remote rate limiter.
	Task: CLAY-002 (Define Remote Contracts & Shared Config)

	Enforces network request limits using a server-managed token bucket algorithm.
	SECURITY POLICY: Fail-closed. Unconfigured remotes are rejected by default.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))

type Bucket = {
	tokens: number,
	lastTimestamp: number,
	maxTokens: number,
	refillRate: number,
}

local RateLimiter = {}
local playerBuckets: { [any]: { [string]: Bucket } } = {}

-- Initialize rate tracking for a player (supports Player instance or string test identifier)
local function getOrCreateBucket(playerKey: any, remoteName: string): (Bucket?, string?)
	local rule = GameConfig.NetworkRateLimits[remoteName]
	if not rule then
		return nil, string.format("Unconfigured rate limit rule for remote '%s'; rejected under fail-closed security policy.", remoteName)
	end

	if not playerBuckets[playerKey] then
		playerBuckets[playerKey] = {}
	end

	local playerRecord = playerBuckets[playerKey]
	if not playerRecord[remoteName] then
		local maxTokens = rule.maxPerSecond + rule.burstAllowance
		playerRecord[remoteName] = {
			tokens = maxTokens,
			lastTimestamp = os.clock(),
			maxTokens = maxTokens,
			refillRate = rule.maxPerSecond,
		}
	end

	return playerRecord[remoteName], nil
end

--[[
	Checks and consumes a rate limit token for a player request.
	Returns (true, nil) if allowed, or (false, reason) if blocked.
	Fail-Closed: If no rate limit rule exists for remoteName, returns false.
]]
function RateLimiter.CheckRateLimit(player: any, remoteName: string): (boolean, string?)
	local bucket, configErr = getOrCreateBucket(player, remoteName)
	if not bucket then
		return false, configErr
	end

	local now = os.clock()
	local elapsed = math.max(0, now - bucket.lastTimestamp)
	bucket.lastTimestamp = now

	-- Refill tokens based on elapsed time up to capacity
	bucket.tokens = math.min(bucket.maxTokens, bucket.tokens + (elapsed * bucket.refillRate))

	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true, nil
	else
		return false, string.format("Rate limit exceeded for remote '%s'. Tokens remaining: %.2f", remoteName, bucket.tokens)
	end
end

-- Manual reset for unit testing
function RateLimiter._ResetPlayer(playerKey: any)
	playerBuckets[playerKey] = nil
end

-- Clean up player data upon leaving to prevent memory leaks
Players.PlayerRemoving:Connect(function(player: Player)
	playerBuckets[player] = nil
end)

return RateLimiter
