--[[---------------------------------------------------------------------------------------------------------------------------
    ______                        _   __       _                   
   /_  __/__  ____ _____ ___     / | / /___  _  __(_)___  __  _______
    / / / _ \/ __ `/ __ `__ \   /  |/ / __ \| |/_/ / __ \/ / / / ___/
   / / /  __/ /_/ / / / / / /  / /|  / /_/ />  </ / /_/ / /_/ (__  ) 
  /_/  \___/\__,_/_/ /_/ /_/  /_/ |_/\____/_/|_/_/\____/\__,_/____/  

  Made by reggie | RegSec Script variable lowercaser

---------------------------------------------------------------------------------------------------------------------------]]--

-- lexer
type Token = {
	kind : string,
	value : string,
	pos   : number,
}

local KEYWORDS = {
	["and"]=1,["break"]=1,["continue"]=1,["do"]=1,["else"]=1,
	["elseif"]=1,["end"]=1,["false"]=1,["for"]=1,["function"]=1,
	["if"]=1,["in"]=1,["local"]=1,["nil"]=1,["not"]=1,["or"]=1,
	["repeat"]=1,["return"]=1,["then"]=1,["true"]=1,["until"]=1,
	["while"]=1,["export"]=1,["type"]=1,
}

local function lex(src: string): {Token}
	local tokens: {Token} = {}
	local i = 1
	local n = #src

	local function peek(off: number?): string
		return src:sub(i + (off or 0), i + (off or 0))
	end

	local function advance(count: number?)
		i += (count or 1)
	end

	local function addTok(kind: string, value: string, startPos: number)
		table.insert(tokens, { kind = kind, value = value, pos = startPos })
	end

	while i <= n do
		local startPos = i
		local ch = peek()

		-- long comments
		if ch == "[" and (peek(1) == "[" or peek(1) == "=") then
			local eqCount = 0
			local j = i + 1
			while src:sub(j, j) == "=" do
				eqCount += 1
				j += 1
			end
			if src:sub(j, j) == "[" then
				local closePattern = "]" .. string.rep("=", eqCount) .. "]"
				local closeStart = src:find(closePattern, j + 1, true)
				if closeStart then
					local raw = src:sub(i, closeStart + #closePattern - 1)
					addTok("string", raw, startPos)
					i = closeStart + #closePattern
				else
					addTok("string", src:sub(i), startPos)
					i = n + 1
				end
				continue
			end
		end

		-- short comments
		if ch == "-" and peek(1) == "-" then
			-- check for long comment
			local j = i + 2
			local eqCount = 0
			while src:sub(j, j) == "=" do
				eqCount += 1
				j += 1
			end
			if src:sub(j, j) == "[" then
				local closePattern = "]" .. string.rep("=", eqCount) .. "]"
				local closeStart = src:find(closePattern, j + 1, true)
				if closeStart then
					local raw = src:sub(i, closeStart + #closePattern - 1)
					addTok("comment", raw, startPos)
					i = closeStart + #closePattern
				else
					addTok("comment", src:sub(i), startPos)
					i = n + 1
				end
			else
				-- line comment
				local eol = src:find("\n", i, true)
				if eol then
					addTok("comment", src:sub(i, eol - 1), startPos)
					i = eol
				else
					addTok("comment", src:sub(i), startPos)
					i = n + 1
				end
			end
			continue
		end

		-- quoted string
		if ch == '"' or ch == "'" then
			local q = ch
			advance()
			while i <= n do
				local c = peek()
				if c == "\\" then
					advance(2)
				elseif c == q then
					advance()
					break
				else
					advance()
				end
			end
			addTok("string", src:sub(startPos, i - 1), startPos)
			continue
		end

		-- number
		if ch:match("%d") or (ch == "." and peek(1):match("%d")) then
			local _, endPos = src:find("^%d*%.?%d*[eE]?[+-]?%d*", i)
			if not endPos or endPos < i then endPos = i end
			-- hex
			if ch == "0" and (peek(1) == "x" or peek(1) == "X") then
				local _, hEnd = src:find("^0[xX][%x_]+", i)
				if hEnd then endPos = hEnd end
			end
			addTok("number", src:sub(i, endPos), startPos)
			i = endPos + 1
			continue
		end

		-- identifier or keyword
		if ch:match("[%a_]") then
			local _, endPos = src:find("^[%a_][%w_]*", i)
			endPos = endPos or i
			local word = src:sub(i, endPos)
			if KEYWORDS[word] then
				addTok("keyword", word, startPos)
			else
				addTok("ident", word, startPos)
			end
			i = endPos + 1
			continue
		end

		-- whitespace
		if ch:match("%s") then
			local _, endPos = src:find("^%s+", i)
			endPos = endPos or i
			addTok("ws", src:sub(i, endPos), startPos)
			i = endPos + 1
			continue
		end

		-- others
		local op3 = src:sub(i, i + 2)
		local op2 = src:sub(i, i + 1)
		local multiOps = {
			["..."] = true, ["..="] = true,
			["=="] = true, ["~="] = true, ["<="] = true, [">="] = true,
			["->"] = true, ["::"] = true, ["//"] = true,
		}
		if multiOps[op3] then
			addTok("op", op3, startPos); advance(3)
		elseif multiOps[op2] then
			addTok("op", op2, startPos); advance(2)
		else
			addTok("op", ch, startPos); advance()
		end
	end

	return tokens
end

-------------------------------------------------------------------------------------------------------------------------------

-- scope analyzing
local function collectDeclaredNames(tokens: {Token}): {[string]: string}
	local declared: {[string]: boolean} = {}

	local n = #tokens
	local i = 1

	-- skip whitespace tokens for lookahead purposes
	local function skipWS(from: number): number
		local j = from
		while j <= n and tokens[j].kind == "ws" do
			j += 1
		end
		return j
	end

	local function tok(off: number?): Token?
		local j = skipWS(i + (off or 0))
		-- off = 0 means current non-ws token which needs proper handling
		return tokens[j]
	end

	-- advance i past the next non-ws token, return that token
	local function consume(): Token?
		i = skipWS(i)
		if i > n then return nil end
		local t = tokens[i]
		i += 1
		return t
	end

	-- peek at the k-th non-whitespace token from current position (1-based)
	local function peekNW(k: number): Token?
		local j = i
		local count = 0
		while j <= n do
			if tokens[j].kind ~= "ws" then
				count += 1
				if count == k then return tokens[j] end
			end
			j += 1
		end
		return nil
	end

	-- register a name as declared
	local function declare(name: string)
		if name and name ~= "" and not KEYWORDS[name] then
			declared[name] = true
		end
	end

	-- parse a comma-separated name list (stops at non-ident / non-comma)
	local function parseNameList()
		while true do
			local t = peekNW(1)
			if not t or t.kind ~= "ident" then break end
			consume(); declare(t.value)
			local comma = peekNW(1)
			if not comma or comma.value ~= "," then break end
			consume() -- eat comma
		end
	end

	while i <= n do
		i = skipWS(i)
		if i > n then break end
		local t = tokens[i]

		if t.kind == "keyword" then
			-- local
			if t.value == "local" then
				consume() -- eat 'local'
				local next = peekNW(1)
				if next and next.kind == "keyword" and next.value == "function" then
					consume() -- eat 'function'
					local name = peekNW(1)
					if name and name.kind == "ident" then
						consume(); declare(name.value)
					end
				else
					parseNameList()
				end

			-- function
			elseif t.value == "function" then
				consume() -- eat 'function'
				-- could be funcName / tbl.funcName or tbl:funcName
				local name = peekNW(1)
				if name and name.kind == "ident" then
					consume()
					-- check for '.name' or ':name' chains and declare only last
					while true do
						local sep = peekNW(1)
						if sep and (sep.value == "." or sep.value == ":") then
							consume() -- eat '.' or ':'
							local seg = peekNW(1)
							if seg and seg.kind == "ident" then
								consume()
								name = seg
							else
								break
							end
						else
							break
						end
					end
					declare(name.value)
				end

			-- for
			elseif t.value == "for" then
				consume() -- eat 'for'
				parseNameList()

			else
				consume()
			end

		else
			consume()
		end
	end

	-- build rename map, only rename if lowercase differs from original
	local renameMap: {[string]: string} = {}
	for name in pairs(declared) do
		local lower = name:lower()
		if lower ~= name then
			renameMap[name] = lower
		end
	end
	return renameMap
end

-------------------------------------------------------------------------------------------------------------------------------

-- rewriting
local function rewrite(tokens: {Token}, renameMap: {[string]: string}): string
	local out = {}
	local prevSignificant: Token? = nil  -- last non-ws token

	for _, t in ipairs(tokens) do
		local value = t.value

		if t.kind == "ident" then
			-- dont rename if preceded by '.' or ':' (property / method access)
			local prev = prevSignificant
			local isAccess = prev and (prev.value == "." or prev.value == ":")
			if not isAccess and renameMap[value] then
				value = renameMap[value]
			end
			prevSignificant = t
		elseif t.kind ~= "ws" then
			prevSignificant = t
		end

		table.insert(out, value)
	end

	return table.concat(out)
end

-------------------------------------------------------------------------------------------------------------------------------

-- main
local function lowercaseIds(source: string): string
	local tokens	= lex(source)
	local renameMap = collectDeclaredNames(tokens)

	setclipboard(rewrite(tokens, renameMap))
	return rewrite(tokens, renameMap)
end

--[[---------------------------------------------------------------------------------------------------------------------------

-- testing
local testSource = [[
local MyValue = 10
local AnotherValue = 20

local function SayHello(PlayerName)
	local Greeting = "Hello, " .. PlayerName
	print(Greeting)
end

function DoSomething(ValueA, ValueB)
	local Result = ValueA + ValueB
	return Result
end

for Index, Item in ipairs({1, 2, 3}) do
	print(Index, Item)
end

SayHello("World")
DoSomething(MyValue, AnotherValue)
]]

---------------------------------------------------------------------------------------------------------------------------]]--

if getgenv().lowercasethis then
	return lowercaseIds(getgenv().lowercasethis)
else
	return lowercaseIds
end

-------------------------------------------------------------------------------------------------------------------------------