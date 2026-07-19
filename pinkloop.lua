local component=require("component")
local event=require("event")
local keyboard=require("keyboard")

local tape=component.tape_drive
local args={...}
local volume=tonumber(args[1]) or 0.8
local trackEnd=1181250

assert(tape.isReady(),"Tape not found")
assert(volume>=0 and volume<=1,"Volume must be between 0 and 1")
assert(tape.setSpeed(1.8310546875),"Failed to set tape speed")
tape.setVolume(volume)

local function restart()
  tape.stop()
  local position=tape.getPosition()
  if position~=0 then
    tape.seek(-position)
  end
  assert(tape.play(),"Failed to play tape")
end

restart()
print("Pink loop started. Volume: "..volume)
print("Press Q or Esc to stop cleanly. Ctrl+Alt+C force quits.")

while true do
  if tape.getPosition()>=trackEnd or tape.isEnd() or tape.getState()~="PLAYING" then
    restart()
  end

  local name,_,_,code=event.pull(0.05)
  if name=="key_down" and (code==keyboard.keys.q or code==keyboard.keys.esc) then
    break
  end
end

tape.stop()
print("Stopped.")
