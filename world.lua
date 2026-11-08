persisted("spill", 1793989984, "local x = 99\
")
persisted("spill", 1793990018, "function greet()\
  say(\"Hello\")\
end\
")
persisted("spill", 1793990100, "old_say = say\
function say(...)\
  old_say(...)\
  old_say(\"(I think)\")\
end\
")
persisted("spill", 1793990232, "local _tmp = say\
function say() error(\"Not available directly\") end\
function dictate(...) return _tmp(...) end\
")
