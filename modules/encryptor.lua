--[[---------------------------------------------------------------------------------------------------------------------------
    ______                        _   __           _                 
   /_  __/__  ____ _____ ___     / | / /___  _  __(_)___  __  _______
    / / / _ \/ __ `/ __ `__ \   /  |/ / __ \| |/_/ / __ \/ / / / ___/
   / / /  __/ /_/ / / / / / /  / /|  / /_/ />  </ / /_/ / /_/ (__  ) 
  /_/  \___/\__,_/_/ /_/ /_/  /_/ |_/\____/_/|_/_/\____/\__,_/____/  

  Made by reggie | Encryptor

---------------------------------------------------------------------------------------------------------------------------]]--

local EncryptionModule = {}

-------------------------------------------------------------------------------------------------------------------------------

local function stringToBytes(str)
	local bytes = {}
	for i = 1, #str do
		bytes[i] = string.byte(str, i)
	end
	return bytes
end

local function bytesToString(bytes)
	local chars = {}
	for i, b in ipairs(bytes) do
		chars[i] = string.char(b)
	end
	return table.concat(chars)
end

-------------------------------------------------------------------------------------------------------------------------------

function EncryptionModule.caesarEncrypt(text, shift)
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

function EncryptionModule.caesarDecrypt(text, shift)
	return EncryptionModule.caesarEncrypt(text, 26 - (shift % 26))
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

function EncryptionModule.keywordEncrypt(text, keyword)
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

function EncryptionModule.keywordDecrypt(text, keyword)
	local keyAlpha = buildKeywordAlphabet(keyword)
	local reverseMap = {}
	for i, c in ipairs(keyAlpha) do
		reverseMap[c] = string.char(64 + i)
		reverseMap[c:lower()] = string.char(96 + i)
	end
	local result = {}
	for i = 1, #text do
		local c = text:sub(i, i)
		result[i] = reverseMap[c] or c
	end
	return table.concat(result)
end

--[[---------------------------------------------------------------------------------------------------------------------------

function EncryptionModule.toHex(text)
	local result = {}
	for i = 1, #text do
		result[i] = string.format("%02x", string.byte(text, i))
	end
	return table.concat(result)
end

function EncryptionModule.fromHex(hex)
	local result = {}
	for i = 1, #hex, 2 do
		local byte = tonumber(hex:sub(i, i+1), 16)
		if byte then
			table.insert(result, string.char(byte))
		end
	end
	return table.concat(result)
end

---------------------------------------------------------------------------------------------------------------------------]]--

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function EncryptionModule.toBase64(text)
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

function EncryptionModule.fromBase64(b64)
	local lookup = {}
	for i = 1, #B64_CHARS do
		lookup[B64_CHARS:sub(i,i)] = i - 1
	end

	local result = {}
	local i = 1
	while i <= #b64 do
		local c1 = lookup[b64:sub(i,i)] or 0
		local c2 = lookup[b64:sub(i+1,i+1)] or 0
		local c3 = lookup[b64:sub(i+2,i+2)]
		local c4 = lookup[b64:sub(i+3,i+3)]

		local b1 = c1 * 4 + math.floor(c2 / 16)
		table.insert(result, string.char(b1))

		if b64:sub(i+2,i+2) ~= "=" and c3 then
			local b2 = (c2 % 16) * 16 + math.floor(c3 / 4)
			table.insert(result, string.char(b2))
		end

		if b64:sub(i+3,i+3) ~= "=" and c4 then
			local b3 = (c3 % 4) * 64 + c4
			table.insert(result, string.char(b3))
		end

		i = i + 4
	end

	return table.concat(result)
end

-------------------------------------------------------------------------------------------------------------------------------

function EncryptionModule.encrypt(plaintext, keyword, caesarShift)
	local step1 = EncryptionModule.keywordEncrypt(plaintext, keyword)
	local step2 = EncryptionModule.caesarEncrypt(step1, caesarShift)
	local step3 = EncryptionModule.toBase64(step2)
  
	return step3
end

function EncryptionModule.decrypt(ciphertext, keyword, caesarShift)
	local step1 = EncryptionModule.fromBase64(ciphertext)
	local step2 = EncryptionModule.caesarDecrypt(step1, caesarShift)
	local step3 = EncryptionModule.keywordDecrypt(step2, keyword)
  
	return step3
end

-------------------------------------------------------------------------------------------------------------------------------

return EncryptionModule

-------------------------------------------------------------------------------------------------------------------------------
