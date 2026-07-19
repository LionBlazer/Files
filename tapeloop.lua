local component=require("component")
local event=require("event")
local keyboard=require("keyboard")
local serialization=require("serialization")

local args={...}
local volume=tonumber(args[1]) or 0.8
assert(volume>=0 and volume<=1,"Volume must be between 0 and 1")
assert(component.isAvailable("tape_drive"),"Tape Drive not found")

local tape=component.tape_drive
assert(tape.isReady(),"Tape not found")

local file=assert(io.open("/etc/tape.meta","r"),"Run tapeimport.lua first")
local config=assert(serialization.unserialize(file:read("*a")),"Invalid /etc/tape.meta")
file:close()

local rate=assert(tonumber(config.rate),"Missing rate")
local trackBytes=assert(tonumber(config.bytes),"Missing byte count")
local speed=rate/32768
assert(speed>=0.25 and speed<=2,"Unsupported tape speed: "..speed)
assert(tape.setSpeed(speed),"Failed to set tape speed")
tape.setVolume(volume)

local function restart()
  tape.stop()
  local position=tape.getPosition()
  if position~=0 then tape.seek(-position) end
  assert(tape.play(),"Failed to play tape")
end

restart()
print("Loop started. Volume: "..volume)
print("Press Q to stop cleanly. Ctrl+Alt+C force quits.")

while true do
  if tape.getPosition()>=trackBytes or tape.isEnd() or tape.getState()~="PLAYING" then
    restart()
  end
  local name,_,_,code=event.pull(0.05)
  if name=="key_down" and code==keyboard.keys.q then break end
end

tape.stop()
print("Stopped.")
