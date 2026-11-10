-- Test upvalues in vehicle Lua
local vc = controller and controller.getController("vehicleController")
print("=== TESTING VC UPVALUES ===")
if not vc then
  print("VC is NIL!")
else
  print("VC found:", tostring(vc))
  for _, funcName in ipairs({"reset", "init", "updateGFX", "shiftToGearIndex"}) do
    local f = vc[funcName]
    print("Checking func:", funcName, tostring(f))
    if type(f) == "function" then
      local i = 1
      while true do
        local name, val = debug.getupvalue(f, i)
        if not name then break end
        print(string.format("  upvalue %d: %s (%s)", i, tostring(name), type(val)))
        if name == "sharedFunctions" and type(val) == "table" then
          print("  -> FOUND sharedFunctions table with keys:")
          for k, _ in pairs(val) do
            print("     " .. tostring(k))
          end
        end
        i = i + 1
      end
    end
  end
end
print("=== END TESTING VC UPVALUES ===")
