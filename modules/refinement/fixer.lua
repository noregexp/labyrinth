-------------------------------------------------------------------------------------------------------------------------------

--- Split a string into a table of lines (keeps empty lines).
local function splitLines(src: string): {string}
    local lines = {}
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end
    return lines
end

--- Join a table of lines back into a single string.
local function joinLines(lines: {string}): string
    return table.concat(lines, "\n")
end

--- Return the leading whitespace of a line as a string.
local function leadingWS(line: string): string
    return line:match("^(%s*)") or ""
end

--- Count how many spaces a mixed-indent string represents (tab = 4 spaces).
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

--- Return true when a line is blank or pure whitespace.
local function isBlank(line: string): boolean
    return line:match("^%s*$") ~= nil
end

--- Return true when a line (stripped) starts with `--`.
local function isComment(line: string): boolean
    return line:match("^%s*%-%-") ~= nil
end

--- Strip a line-level comment and return the code portion.
--- Simple heuristic: finds ` --` not inside a string literal.
local function stripLineComment(line: string): string
    -- Very conservative: only strip bare `--` not preceded by `[` (long comments)
    local code = line:match("^(.-)%s*%-%-[^%[].*$") or line
    return code
end

-- ════════════════════════════════════════════════════════════
--  Pass 1 – Trailing whitespace
-- ════════════════════════════════════════════════════════════

local function removeTrailingWhitespace(lines: {string}): {string}
    local out = {}
    for _, line in ipairs(lines) do
        table.insert(out, (line:gsub("%s+$", "")))
    end
    return out
end

-- ════════════════════════════════════════════════════════════
--  Pass 2 – Normalise indentation (mixed tabs+spaces → spaces)
-- ════════════════════════════════════════════════════════════

local function normaliseIndentation(lines: {string}): {string}
    -- Detect dominant style: count lines that start with a tab vs lines that
    -- start with spaces. Whichever wins becomes the canonical style.
    local tabLines, spaceLines = 0, 0
    for _, line in ipairs(lines) do
        if line:match("^\t") then
            tabLines += 1
        elseif line:match("^ ") then
            spaceLines += 1
        end
    end

    -- If the file is already purely one style, do nothing.
    if tabLines == 0 or spaceLines == 0 then
        return lines
    end

    -- Mixed file → convert everything to 4-space indentation.
    local out = {}
    for _, line in ipairs(lines) do
        local ws = leadingWS(line)
        local rest = line:sub(#ws + 1)
        local width = indentWidth(ws)
        local newWS = string.rep(" ", width)
        table.insert(out, newWS .. rest)
    end
    return out
end

-------------------------------------------------------------------------------------------------------------------------------

-- remove bare scope pyramids (do ... end)
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

    -- collect all bare-do indices and their matching ends
    local removals: {[number]: boolean} = {}

    local i = 1
    while i <= #lines do
        if isBareDoLine(lines[i]) then
            local endIdx = findMatchingEnd(i)
            if endIdx then
                -- check for control-flow inside the block
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
    -- for proper de-indent, we need to know the indent of removed do lines
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
                -- this is an 'end' line
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
                amount += 4 -- one level
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
                local newWidth = math.max(0, #ws - deindent)
                table.insert(out, string.rep(" ", newWidth) .. rest)
            else
                table.insert(out, line)
            end
        end
    end

    return out
end

-------------------------------------------------------------------------------------------------------------------------------

-- remove unused local variables
local function removeUnusedLocals(lines: {string}): {string}
    local source = joinLines(lines)

    -- collect all 'local <names>' declarations with their line numbers
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

-- merge double 'if' statemts
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
    local merges: {[number]: {outerCond: string, innerCond: string, outerEnd: number, innerEnd: number}} = {}

    local i = 1
    while i <= #lines do
        if skip[i] then i += 1; continue end

        local outerCond = getIfCondition(lines[i])
        if outerCond then
            local outerEnd = findBlockEnd(i)
            if outerEnd then
                -- the body is lines[i + 1 .. outerEnd-1]
                -- it must consist of exactly one inner 'if' (and its body + end)
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
                            -- check theres no else / elseif in outer OR inner block
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
            -- emit merged if line with de-indented body
            local indentStr = leadingWS(lines[i])
            table.insert(out, indentStr .. "if " .. m.outerCond .. " and " .. m.innerCond .. " then")
            -- de-indent body lines (between firstBodyIdx + 1 and innerEnd - 1)
            -- find firstBodyIdx again
            local firstBodyIdx = 0
            for j = i + 1, m.outerEnd - 1 do
                if not isBlank(lines[j]) and not isComment(lines[j]) then
                    firstBodyIdx = j; break
                end
            end
            for j = firstBodyIdx + 1, m.innerEnd - 1 do
                local ws = leadingWS(lines[j])
                local rest = lines[j]:sub(#ws + 1)
                local newWidth = math.max(0, #ws - 4)
                table.insert(out, string.rep(" ", newWidth) .. rest)
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

local function annotateShadowing(lines: {string}): {string}
    -- we track scopes as a stack of name sets
    -- blocks opened by: if / then, for, while, do, function, repeat
    -- blocks closed by: end, until
  
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

        -- check for scope opening patterns
        local opensScope = false
        for pat in pairs(blockOpeners) do
            if code:match(pat) then
                opensScope = true; break
            end
        end

        -- 'end' and 'until' close a scope
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
                        annotations[i] = indent .. "-- SHADOW WARNING: `" .. name
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

--- runs all fix passes on 'source' and returns the cleaned source.
local function fixScript(source: string): string
    local lines = splitLines(source)

    lines = removeTrailingWhitespace(lines)
    lines = normaliseIndentation(lines)
    lines = removeScopePyramids(lines)
    lines = removeUnusedLocals(lines)
    lines = mergeDoubleIfs(lines)
    lines = annotateShadowing(lines)

    -- final pass: strip any trailing blank lines at EOF.
    while #lines > 0 and isBlank(lines[#lines]) do
        table.remove(lines)
    end

    return joinLines(lines)
end

--[[---------------------------------------------------------------------------------------------------------------------------

local testSource = [[
local unusedVar = 42   
local anotherUnused = "hello"   

local function greet(name)   
	local greeting = "Hi"  -- tab indent
    print(greeting .. ", " .. name)  -- space indent
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

print("=== FIXED SCRIPT ===")
print(fixScript(testSource))

---------------------------------------------------------------------------------------------------------------------------]]--

return fixScript
