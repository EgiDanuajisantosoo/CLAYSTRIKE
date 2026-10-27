--!strict
--[[
	RateLimiter.luau
	Authoritative per-player and per-remote rate limiter.
	Task: CLAY-002 (Define Remote Contracts & Shared Config)

	Enforces network request limits using a server-managed token bucket algorithm.
	Rules and thresholds are read centrally from GameConfig.NetworkRateLimits.
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
local playerBuckets: { [Player]: { [string]: Bucket } } = {}

-- Initialize rate tracking for a player
local function getOrCreateBucket(player: Player, remoteName: string): Bucket?
	local rule = GameConfig.NetworkRateLimits[remoteName]
	if not rule then
		return nil
	end

	if not playerBuckets[player] then
		playerBuckets[player] = {}
	end

	local playerRecord = playerBuckets[player]
	if not playerRecord[remoteName] then
		local maxTokens = rule.maxPerSecond + rule.burstAllowance
		playerRecord[remoteName] = {
			tokens = maxTokens,
			lastTimestamp = os.clock(),
			maxTokens = maxTokens,
			refillRate = rule.maxPerSecond,
		}
	end

	return playerRecord[remoteName]
end

--[[
	Checks and consumes a rate limit token for a player request.
	Returns (true, nil) if allowed, or (false, reason) if blocked.
]]
function RateLimiter.CheckRateLimit(player: Player, remoteName: string): (boolean, string?)
	local bucket = getOrCreateBucket(player, remoteName)
	if not bucket then
		-- No rule defined for this remote; permit by default
		return true, nil
	end

	local now = os.clock()
	local elapsed = math.max(0, now - bucket.lastTimestamp)
	bucket.lastTimestamp = now

	-- Refill tokens based on elapsed time
	bucket.tokens = math.min(bucket.maxTokens, bucket.tokens + (elapsed * bucket.refillRate))

	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true, nil
	else
		return false, string.format("Rate limit exceeded for remote '%s'. Tokens remaining: %.2f", remoteName, bucket.tokens)
	end
end

-- Clean up player data upon leaving to prevent memory leaks
Players.PlayerRemoving:Connect(function(player: Player)
	playerBuckets[player] = nil
end)

return RateLimiter
