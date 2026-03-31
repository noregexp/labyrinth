# info

**script refinement modules** made by **me**

these modules can be used to protect your scripts (though i cant solidify that case as dedicated people can crack them) or refine / beautify them, removing useless and redundant sections in your code

# loadstrings

refiner
```lua
getgenv().fixthis = [[
print("hi world")
]]

loadstring(game:HttpGet("https://raw.githubusercontent.com/noregexp/labyrinth/refs/heads/main/modules/refinement/fixer.lua"))()
```

encryptor
```lua
getgenv().encryptthis = [[
print("hi world")
]]

loadstring(game:HttpGet("https://raw.githubusercontent.com/noregexp/labyrinth/refs/heads/main/modules/protection/encryptor.lua"))()
```

decryptor
```lua
getgenv().decryptthis = [[
print("hi world")
]]

loadstring(game:HttpGet("https://raw.githubusercontent.com/noregexp/labyrinth/refs/heads/main/modules/protection/decryptor.lua"))()
```
