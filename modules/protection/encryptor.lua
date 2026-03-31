--[[---------------------------------------------------------------------------------------------------------------------------
    ______                        _   __           _                 
   /_  __/__  ____ _____ ___     / | / /___  _  __(_)___  __  _______
    / / / _ \/ __ `/ __ `__ \   /  |/ / __ \| |/_/ / __ \/ / / / ___/
   / / /  __/ /_/ / / / / / /  / /|  / /_/ />  </ / /_/ / /_/ (__  ) 
  /_/  \___/\__,_/_/ /_/ /_/  /_/ |_/\____/_/|_/_/\____/\__,_/____/  

  Made by reggie | RegSec Script Encryptor

---------------------------------------------------------------------------------------------------------------------------]]--

local Encryptor = {}

-------------------------------------------------------------------------------------------------------------------------------

local function stringToBytes(str)
	local bytes = {}
	for i = 1, #str do
		bytes[i] = string.byte(str, i)
	end
	return bytes
end

-------------------------------------------------------------------------------------------------------------------------------

function Encryptor.caesarEncrypt(text, shift)
	shift = shift % 26
	local result = {}
	for i = 1, #text do
		local b = string.byte(text, i)
		if b >= 65 and b <= 90 then
			result[i] = string.char((b - 65 + shift) % 26 + 65)
		elseif b >= 97 and b <= 122 then
			result[i] = string.char((b - 97 + shift) % 26 + 97)
		else
			result[i] = string.char(b)
		end
	end
	return table.concat(result)
end

-------------------------------------------------------------------------------------------------------------------------------

local function buildKeywordAlphabet(keyword)
	keyword = keyword:upper():gsub("[^A-Z]", "")
	local seen = {}
	local keyAlpha = {}

	for i = 1, #keyword do
		local c = keyword:sub(i, i)
		if not seen[c] then
			seen[c] = true
			table.insert(keyAlpha, c)
		end
	end

	for b = 65, 90 do
		local c = string.char(b)
		if not seen[c] then
			table.insert(keyAlpha, c)
		end
	end

	return keyAlpha
end

function Encryptor.keywordEncrypt(text, keyword)
	local keyAlpha = buildKeywordAlphabet(keyword)
	local result = {}
	for i = 1, #text do
		local b = string.byte(text, i)
		local isUpper = b >= 65 and b <= 90
		local isLower = b >= 97 and b <= 122
		if isUpper then
			result[i] = keyAlpha[b - 64]
		elseif isLower then
			result[i] = keyAlpha[b - 96]:lower()
		else
			result[i] = string.char(b)
		end
	end
	return table.concat(result)
end

--[[---------------------------------------------------------------------------------------------------------------------------

function Encryptor.toHex(text)
	local result = {}
	for i = 1, #text do
		result[i] = string.format("%02x", string.byte(text, i))
	end
	return table.concat(result)
end

---------------------------------------------------------------------------------------------------------------------------]]--

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function Encryptor.toBase64(text)
	local result = {}
	local bytes = stringToBytes(text)
	local i = 1

	while i <= #bytes do
		local b1 = bytes[i] or 0
		local b2 = bytes[i+1] or 0
		local b3 = bytes[i+2] or 0

		local n = b1 * 65536 + b2 * 256 + b3

		local c1 = math.floor(n / 262144) % 64 + 1
		local c2 = math.floor(n / 4096) % 64 + 1
		local c3 = math.floor(n / 64) % 64 + 1
		local c4 = n % 64 + 1

		table.insert(result, B64_CHARS:sub(c1, c1))
		table.insert(result, B64_CHARS:sub(c2, c2))

		if bytes[i+1] then
			table.insert(result, B64_CHARS:sub(c3, c3))
		else
			table.insert(result, "=")
		end
		if bytes[i+2] then
			table.insert(result, B64_CHARS:sub(c4, c4))
		else
			table.insert(result, "=")
		end

		i = i + 3
	end

	return table.concat(result)
end

-------------------------------------------------------------------------------------------------------------------------------

function Encryptor.encrypt(plaintext, keyword, caesarShift)
	local step1 = Encryptor.keywordEncrypt(plaintext, keyword)
	local step2 = Encryptor.caesarEncrypt(step1, caesarShift)
	local step3 = Encryptor.toBase64(step2)
  
	return step3
end

-------------------------------------------------------------------------------------------------------------------------------

if getgenv().RegSec.encryptthis then
    return Encryptor.encrypt(getgenv().RegSec.encryptthis)
else
    return Encryptor
end

-------------------------------------------------------------------------------------------------------------------------------
