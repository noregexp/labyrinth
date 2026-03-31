--[[---------------------------------------------------------------------------------------------------------------------------
    ______                        _   __           _                 
   /_  __/__  ____ _____ ___     / | / /___  _  __(_)___  __  _______
    / / / _ \/ __ `/ __ `__ \   /  |/ / __ \| |/_/ / __ \/ / / / ___/
   / / /  __/ /_/ / / / / / /  / /|  / /_/ />  </ / /_/ / /_/ (__  ) 
  /_/  \___/\__,_/_/ /_/ /_/  /_/ |_/\____/_/|_/_/\____/\__,_/____/  

  Made by reggie | RegSec script refiner

---------------------------------------------------------------------------------------------------------------------------]]--

-- helpers
local function splitLines(src: string): {string}
    local lines = {}
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end
    return lines
end

local function joinLines(lines: {string}): string
    return table.concat(lines, "\n")
end

local function leadingWS(line: string): string
    return line:match("^(%s*)") or ""
end

local function indentWidth(ws: string): number
    local n = 0
    for ch in ws:gmatch(".") do
        if ch == "\t" then
            n = n + 4
        else
            n = n + 1
        end
    end
    return n
end

local function isBlank(line: string): boolean
    return line:match("^%s*$") ~= nil
end

local function isComment(line: string): boolean
    return line:match("^%s*%-%-") ~= nil
end

local function stripLineComment(line: string): string
    local code = line:match("^(.-)%s*%-%-[^%[].*$") or line
    return code
end

-------------------------------------------------------------------------------------------------------------------------------

-- remove trailing whitespace
local function removeTrailingWhitespace(lines: {string}): {string}
    local out = {}
    for _, line in ipairs(lines) do
        table.insert(out, (line:gsub("%s+$", "")))
    end
    return out
end

-------------------------------------------------------------------------------------------------------------------------------

-- tab indentation
local function normaliseIndentation(lines: {string}): {string}
    -- if every indented line already starts with a tab, do nothing
    local hasSpaceIndent = false
    for _, line in ipairs(lines) do
        if line:match("^ ") then
            hasSpaceIndent = true
            break
        end
    end
    if not hasSpaceIndent then
        return lines
    end

    -- convert all leading whitespace to tabs (4 spaces = 1 tab)
    local out = {}
    for _, line in ipairs(lines) do
        local ws = leadingWS(line)
        local rest = line:sub(#ws + 1)
        local width = indentWidth(ws) -- total spaces equivalent
        local tabCount = math.ceil(width / 4) -- round up so nothing is lost
        local newWS = string.rep("\t", tabCount)
        table.insert(out, newWS .. rest)
    end
    return out
end

-------------------------------------------------------------------------------------------------------------------------------

-- scopy pyramid management
local function removeScopePyramids(lines: {string}): {string}
    -- mark indices of 'do' lines that are bare scope openers
    local function isBareDoLine(line: string): boolean
        local code = stripLineComment(line):match("^%s*(.-)%s*$") or ""
        return code == "do"
    end

    -- returns the line index of the matching end, or nil
    local function findMatchingEnd(startIdx: number): number?
        local depth = 0
        for i = startIdx, #lines do
            local code = stripLineComment(lines[i]):match("^%s*(.-)%s*$") or ""
            -- keywords that open a new block
            if code:match("^do$") or code:match("^do ") or
               code:match(" do$") or code:match(" do ") or
               code:match("^if ") or code:match("^elseif ") or
               code:match("^while ") or code:match("^for ") or
               code:match("^repeat$") or code:match("^repeat ") or
               code:match("^function ") or code:match("function%(") then
                depth += 1
            end
            if code == "end" or code:match("^end%-%-") or code:match("^end ") then
                depth -= 1
                if depth == 0 then
                    return i
                end
            end
            -- 'until' closes a repeat block
            if code:match("^until ") or code:match("^until$") then
                depth -= 1
                if depth == 0 then
                    return i -- wont be 'end' but the block is closed
                end
            end
        end
        return nil
    end

    -- collect all bare 'do' indices and their matching ends. remove when the block contains no `break`, 'continue', 'goto', 'return', or labels and if no 'local' variable declared inside is referenced after the end line
    local removals: {[number]: boolean} = {}

    local i = 1
    while i <= #lines do
        if isBareDoLine(lines[i]) then
            local endIdx = findMatchingEnd(i)
            if endIdx then
                -- check for control flow inside the block
                local hasControlFlow = false
                local innerLocals: {string} = {}
                for j = i + 1, endIdx - 1 do
                    local code = lines[j]
                    if code:match("%f[%a]break%f[%A]") or
                       code:match("%f[%a]continue%f[%A]") or
                       code:match("%f[%a]goto%f[%A]") or
                       code:match("%f[%a]return%f[%A]") or
                       code:match("^%s*::%w+::") then
                        hasControlFlow = true
                        break
                    end
                    -- collect declared names
                    for name in code:gmatch("local%s+([%a_][%w_,%s]-)%s*[=%n]") do
                        for n in name:gmatch("[%a_][%w_]*") do
                            table.insert(innerLocals, n)
                        end
                    end
                end

                if not hasControlFlow then
                    -- check if any inner local is referenced after endIdx
                    local escapesScope = false
                    for _, name in ipairs(innerLocals) do
                        for j = endIdx + 1, #lines do
                            if lines[j]:match("%f[%a]" .. name .. "%f[%A]") then
                                escapesScope = true
                                break
                            end
                        end
                        if escapesScope then break end
                    end

                    if not escapesScope then
                        removals[i] = true
                        removals[endIdx] = true
                    end
                end
            end
        end
        i += 1
    end

    -- rebuild without removed lines and de-indent the block contents
    local out = {}
    -- for proper de-indent, know the indent of removed 'do' lines
    local doIndents: {[number]: number} = {}
    for idx in pairs(removals) do
        local ws = leadingWS(lines[idx])
        doIndents[idx] = #ws
    end

    -- build a set of (startDo -> endDo) ranges for de-indenting inner lines
    local ranges: {{number}} = {}
    local doStack: {number} = {}
    for idx = 1, #lines do
        if removals[idx] then
            if lines[idx]:match("^%s*do%s*$") or lines[idx]:match("^%s*do%-%-") then
                table.insert(doStack, idx)
            else
                -- This is an 'end' line
                local startDo = table.remove(doStack)
                if startDo then
                    table.insert(ranges, {startDo, idx})
                end
            end
        end
    end

    -- for each line, determine if its inside a removed do..end range
    local function getDeindent(lineIdx: number): number
        local amount = 0
        for _, r in ipairs(ranges) do
            if lineIdx > r[1] and lineIdx < r[2] then
                amount += 1 -- one tab level per removed do..end
            end
        end
        return amount
    end

    for idx, line in ipairs(lines) do
        if not removals[idx] then
            local deindent = getDeindent(idx)
            if deindent > 0 then
                local ws = leadingWS(line)
                local rest = line:sub(#ws + 1)
                -- whitespace may be tabs or spaces. convert to tab count then subtract
                local tabCount = math.max(0, math.ceil(indentWidth(ws) / 4) - deindent)
                table.insert(out, string.rep("\t", tabCount) .. rest)
            else
                table.insert(out, line)
            end
        end
    end

    return out
end

-------------------------------------------------------------------------------------------------------------------------------

-- remove unused variables
local function removeUnusedLocals(lines: {string}): {string}
    local source = joinLines(lines)

    -- collect all 'local <name>' declarations with their line numbers
    type DeclInfo = {names: {string}, lineIdx: number, rawLine: string}
    local decls: {DeclInfo} = {}

    for i, line in ipairs(lines) do
        if isComment(line) then continue end
        -- match 'local name1, name2, etc...'
        local nameList = line:match("^%s*local%s+([%a_][%w_%s,]*)[=%s\n]")
                      or line:match("^%s*local%s+([%a_][%w_%s,]*)$")
        if nameList then
            local names = {}
            for n in nameList:gmatch("[%a_][%w_]*") do
                -- skip luau keywords that can follow 'local'
                if n ~= "function" then
                    table.insert(names, n)
                end
            end
            if #names > 0 then
                table.insert(decls, {names = names, lineIdx = i, rawLine = line})
            end
        end
    end

    -- for each declared name, check if it appears anywhere other than its own declaration line
    local removeLine: {[number]: boolean} = {}

    for _, decl in ipairs(decls) do
        local allUnused = true
        for _, name in ipairs(decl.names) do
            -- search every line except the declaration line itself
            local used = false
            for i, line in ipairs(lines) do
                if i == decl.lineIdx then continue end
                if isComment(line) then continue end
                if line:match("%f[%a]" .. name .. "%f[%A]") then
                    used = true
                    break
                end
            end
            if used then
                allUnused = false
                break
            end
        end
        if allUnused then
            removeLine[decl.lineIdx] = true
        end
    end

    local out = {}
    for i, line in ipairs(lines) do
        if not removeLine[i] then
            table.insert(out, line)
        end
    end
    return out
end

-------------------------------------------------------------------------------------------------------------------------------

-- double 'if' statement merging
local function mergeDoubleIfs(lines: {string}): {string}
    local function trimCode(line: string): string
        return (stripLineComment(line):match("^%s*(.-)%s*$") or "")
    end

    local function getIfCondition(line: string): string?
        return line:match("^%s*if%s+(.+)%s+then%s*$")
    end

    -- find the line index of the 'end' that closes the block starting at 'startLine' (which is an 'if ...' line)
    local function findBlockEnd(startIdx: number): number?
        local depth = 0
        for i = startIdx, #lines do
            local code = trimCode(lines[i])
            if code:match("^if ") or code:match("^while ") or
               code:match("^for ") or code:match(" do$") or
               code:match("^do$") or code:match("^repeat") or
               code:match("^function ") then
                depth += 1
            end
            if code == "end" then
                depth -= 1
                if depth == 0 then return i end
            end
        end
        return nil
    end

    local skip: {[number]: boolean} = {}
    local merges: {[number]: {outerCond: string, innerCond: string,
                              outerEnd: number, innerEnd: number}} = {}

    local i = 1
    while i <= #lines do
        if skip[i] then i += 1; continue end

        local outerCond = getIfCondition(lines[i])
        if outerCond then
            local outerEnd = findBlockEnd(i)
            if outerEnd then
                -- find first non-blank body line
                local firstBodyIdx: number? = nil
                for j = i + 1, outerEnd - 1 do
                    if not isBlank(lines[j]) and not isComment(lines[j]) then
                        firstBodyIdx = j
                        break
                    end
                end

                if firstBodyIdx then
                    local innerCond = getIfCondition(lines[firstBodyIdx])
                    if innerCond then
                        local innerEnd = findBlockEnd(firstBodyIdx)
                        if innerEnd and innerEnd == outerEnd - 1 then
                            -- check theres no else / elseif in outer or inner block
                            local hasElse = false
                            for j = i + 1, outerEnd - 1 do
                                local code = trimCode(lines[j])
                                if (code:match("^else$") or code:match("^elseif ")) and
                                   j ~= firstBodyIdx then
                                    hasElse = true; break
                                end
                            end
                            for j = firstBodyIdx + 1, innerEnd - 1 do
                                local code = trimCode(lines[j])
                                if code:match("^else$") or code:match("^elseif ") then
                                    hasElse = true; break
                                end
                            end

                            if not hasElse then
                                merges[i] = {
                                    outerCond = outerCond,
                                    innerCond = innerCond,
                                    outerEnd  = outerEnd,
                                    innerEnd  = innerEnd,
                                }
                                skip[firstBodyIdx] = true
                                skip[innerEnd]     = true
                                skip[outerEnd]     = true
                            end
                        end
                    end
                end
            end
        end
        i += 1
    end

    if next(merges) == nil then return lines end

    local out = {}
    i = 1
    while i <= #lines do
        local m = merges[i]
        if m then
            -- emit merged if line with de-indented body.
            local indentStr = leadingWS(lines[i])
            table.insert(out, indentStr .. "if " .. m.outerCond .. " and " .. m.innerCond .. " then")
            -- de-indent body lines (between firstBodyIdx+1 and innerEnd-1) and find firstBodyIdx again.
            local firstBodyIdx = 0
            for j = i + 1, m.outerEnd - 1 do
                if not isBlank(lines[j]) and not isComment(lines[j]) then
                    firstBodyIdx = j; break
                end
            end
            for j = firstBodyIdx + 1, m.innerEnd - 1 do
                local ws = leadingWS(lines[j])
                local rest = lines[j]:sub(#ws + 1)
                local tabCount = math.max(0, math.ceil(indentWidth(ws) / 4) - 1)
                table.insert(out, string.rep("\t", tabCount) .. rest)
            end
            table.insert(out, indentStr .. "end")
            i = m.outerEnd + 1
        elseif skip[i] then
            i += 1
        else
            table.insert(out, lines[i])
            i += 1
        end
    end
    return out
end

-------------------------------------------------------------------------------------------------------------------------------

-- variable shadowing detection
local function annotateShadowing(lines: {string}): {string}
    type Scope = {[string]: number} -- name -> line where declared
    local scopeStack: {Scope} = {{}} -- start with one global scope

    local annotations: {[number]: string} = {}

    local function currentScope(): Scope
        return scopeStack[#scopeStack]
    end

    local function isDeclaredInOuterScope(name: string): (boolean, number)
        for depth = #scopeStack - 1, 1, -1 do
            if scopeStack[depth][name] then
                return true, scopeStack[depth][name]
            end
        end
        return false, 0
    end

    local function pushScope()
        table.insert(scopeStack, {})
    end

    local function popScope()
        if #scopeStack > 1 then
            table.remove(scopeStack)
        end
    end

    -- tiny tokeniser for scope depth tracking
    local blockOpeners = {
        ["^%s*if%s"] = false, -- 'if' opens a block but pairs with 'end'
        ["^%s*for%s"] = false,
        ["^%s*while%s"] = false,
        ["^%s*do%s*$"] = false,
        ["^%s*do%-%-"] = false,
        ["^%s*function%s"] = false,
        ["^%s*local%s+function%s"] = false,
        ["=[%s]*function%("] = false, -- anonymous function assigned
    }

    for i, line in ipairs(lines) do
        if isComment(line) then continue end
        local code = line

        -- check for scope-opening patterns
        local opensScope = false
        for pat in pairs(blockOpeners) do
            if code:match(pat) then
                opensScope = true; break
            end
        end

        -- 'end' and `'ntil' close a scope
        local stripped = code:match("^%s*(.-)%s*$") or ""
        if stripped == "end" or stripped:match("^end%-%-") or
           stripped:match("^end%s") or stripped:match("^until") then
            popScope()
        end

        if opensScope then
            pushScope()
        end

        -- detect local declarations
        local nameList = code:match("^%s*local%s+([%a_][%w_%s,]*)[=%s\n]")
                      or code:match("^%s*local%s+([%a_][%w_%s,]*)$")
        if nameList then
            for name in nameList:gmatch("[%a_][%w_]*") do
                if name ~= "function" then
                    local shadowed, outerLine = isDeclaredInOuterScope(name)
                    if shadowed then
                        local indent = leadingWS(line)
                        annotations[i] = indent .. "-- shadow warning: `" .. name
                            .. "` shadows an outer variable declared at line "
                            .. outerLine .. "."
                    end
                    currentScope()[name] = i
                end
            end
        end
    end

    if next(annotations) == nil then return lines end

    local out = {}
    for i, line in ipairs(lines) do
        if annotations[i] then
            table.insert(out, annotations[i])
        end
        table.insert(out, line)
    end
    return out
end

-------------------------------------------------------------------------------------------------------------------------------

-- main
local function fixScript(source: string): string
    local lines = splitLines(source)

    lines = removeTrailingWhitespace(lines)
    lines = normaliseIndentation(lines)
    lines = removeScopePyramids(lines)
    lines = removeUnusedLocals(lines)
    lines = mergeDoubleIfs(lines)
    lines = annotateShadowing(lines)

    -- strip any trailing blank lines at eof
    while #lines > 0 and isBlank(lines[#lines]) do
        table.remove(lines)
    end

    setclipboard(joinLines(lines))
    return joinLines(lines)
end

--[[---------------------------------------------------------------------------------------------------------------------------

-- testing
local testSource = [[
local unusedVar = 42   
local anotherUnused = "hello"   

local function greet(name)   
    local greeting = "Hi"  -- 4-space indent
        print(greeting .. ", " .. name)  -- 8-space indent
    do
        do
            print("nested pyramid")
        end
    end
end

if true then
    if someCondition then
        print("double if")
    end
end

local x = 10
do
    local x = 20  -- shadow
    print(x)
end

greet("World")
]]

---------------------------------------------------------------------------------------------------------------------------]]--

if getgenv().RegSec.fixthis then
    return fixScript(getgenv().RegSec.fixthis)
else
    return fixScript
end

-------------------------------------------------------------------------------------------------------------------------------
