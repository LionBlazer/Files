local component=require("component")
local internet=require("internet")
local term=require("term")
local computer=require("computer")
local serialization=require("serialization")

local args={...}
local source=assert(args[1],"Usage: tapeimport.lua <github-mp3-url> [seconds]")
local seconds=args[2] and assert(tonumber(args[2]),"Seconds must be a number") or nil
assert(not seconds or seconds>0,"Seconds must be greater than zero")
assert(component.isAvailable("tape_drive"),"Tape Drive not found")

local tape=component.tape_drive
assert(tape.isReady(),"Tape not found")

local function parseGithub(url)
  url=url:gsub("[?#].*$","")
  local owner,repo,ref,path=url:match("^https://github%.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$")
  if not owner then
    owner,repo,ref,path=url:match("^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.+)$")
  end
  assert(owner and repo and ref and path,"Only GitHub blob/raw URLs are supported")
  return owner,repo,ref,path
end

local owner,repo,ref,path=parseGithub(source)
local rawBase="https://raw.githubusercontent.com/"..owner.."/"..repo.."/"..ref.."/"..path
local pcmUrl=rawBase..".pcm8"
local metaUrl=rawBase..".meta"

local function readAll(url)
  local request=internet.request(url,nil,{["user-agent"]="OpenComputers"})
  local chunks={}
  for chunk in request do chunks[#chunks+1]=chunk end
  local code,msg=request.response()
  assert(code and code>=200 and code<300,"HTTP "..tostring(code).." "..tostring(msg))
  return table.concat(chunks)
end

print("Reading metadata...")
local metaText=readAll(metaUrl)
local rate=tonumber(metaText:match("rate=(%d+)"))
local totalSamples=tonumber(metaText:match("samples=(%d+)"))
assert(rate and totalSamples,"Invalid metadata")

local targetSamples=seconds and math.min(totalSamples,math.floor(seconds*rate)) or totalSamples
local targetBytes=math.ceil(targetSamples/8)
local tapeSize=tape.getSize()
assert(targetBytes<=tapeSize,"Tape too small: need "..targetBytes.." bytes")

local response=0
local level=0
local lastBit=false
local sampleCount=0
local written=0
local pack=0
local packBits=0
local started=computer.uptime()
local lastDraw=0

local function update(bit)
  local target=bit and 127 or -128
  local nextLevel=level+math.floor((response*(target-level)+128)/256)
  if nextLevel==level and level~=target then nextLevel=nextLevel+(bit and 1 or -1) end
  local responseTarget,delta
  if bit==lastBit then responseTarget,delta=255,7 else responseTarget,delta=0,20 end
  local nextResponse=response+math.floor((delta*(responseTarget-response)+128)/256)
  if nextResponse==response and response~=responseTarget then
    nextResponse=nextResponse+(responseTarget==255 and 1 or -1)
  end
  response,level,lastBit=nextResponse,nextLevel,bit
end

local function writePacked()
  tape.write(string.char(pack))
  written=written+1
  pack=0
  packBits=0
end

local function draw()
  local elapsed=math.max(computer.uptime()-started,0.001)
  local progress=math.min(sampleCount/targetSamples,1)
  local width=16
  local fill=math.floor(progress*width)
  local text=string.format("[%s%s] %3d%% %.1f KB/s",string.rep("#",fill),string.rep("-",width-fill),math.floor(progress*100),(written/1024)/elapsed)
  local _,y=term.getCursor()
  local screenWidth=component.gpu.getResolution()
  term.setCursor(1,y)
  io.write(text..string.rep(" ",math.max(0,screenWidth-#text-1)))
end

tape.stop()
tape.seek(-tape.getPosition())
print("Streaming and converting...")

local request=internet.request(pcmUrl,nil,{["user-agent"]="OpenComputers"})
for chunk in request do
  for i=1,#chunk do
    if sampleCount>=targetSamples then break end
    local sample=chunk:byte(i)
    if sample>=128 then sample=sample-256 end
    local bit=sample>level or (sample==level and level==127)
    pack=bit and math.floor(pack/2)+128 or math.floor(pack/2)
    update(bit)
    packBits=packBits+1
    sampleCount=sampleCount+1
    if packBits==8 then writePacked() end
  end
  if computer.uptime()-lastDraw>=0.2 then draw();lastDraw=computer.uptime() end
  if sampleCount>=targetSamples then break end
end

local code,msg=request.response()
assert(code and code>=200 and code<300,"HTTP "..tostring(code).." "..tostring(msg))
if packBits>0 then
  while packBits<8 do
    local bit=0>level
    pack=bit and math.floor(pack/2)+128 or math.floor(pack/2)
    update(bit)
    packBits=packBits+1
  end
  writePacked()
end

draw()
io.write("\n")
tape.seek(-tape.getPosition())

local config={rate=rate,bytes=written,source=source}
local file=assert(io.open("/etc/tape.meta","w"))
file:write(serialization.serialize(config))
file:close()

print("Done: "..written.." bytes, "..string.format("%.2f",sampleCount/rate).." s")
