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
local dfpwmUrl=rawBase..".dfpwm"
local pcmUrl=rawBase..".pcm8"
local metaUrl=rawBase..".meta"

local function readAll(url)
  local request=internet.request(url,nil,{["user-agent"]="OpenComputers"})
  local chunks={}
  local checked=false
  for chunk in request do
    if not checked then
      local code,msg=request.response()
      assert(code and code>=200 and code<300,"HTTP "..tostring(code).." "..tostring(msg))
      checked=true
    end
    chunks[#chunks+1]=chunk
  end
  if not checked then
    local code,msg=request.response()
    assert(code and code>=200 and code<300,"HTTP "..tostring(code).." "..tostring(msg))
  end
  return table.concat(chunks)
end

print("Reading metadata...")
local metaText=readAll(metaUrl)
local rate=tonumber(metaText:match("rate=(%d+)"))
local totalSamples=tonumber(metaText:match("samples=(%d+)"))
assert(rate and totalSamples,"Invalid metadata")

local targetSamples=seconds and math.min(totalSamples,math.floor(seconds*rate)) or totalSamples
local targetBytes=math.ceil(targetSamples/8)
assert(targetBytes<=tape.getSize(),"Tape too small: need "..targetBytes.." bytes")

local started=computer.uptime()
local lastDraw=0
local written=0
local floor=math.floor

local function draw(label)
  local elapsed=math.max(computer.uptime()-started,0.001)
  local progress=math.min(written/targetBytes,1)
  local width=16
  local fill=floor(progress*width)
  local speed=(written/1024)/elapsed
  local eta=speed>0 and math.max(0,(targetBytes-written)/1024/speed) or 0
  local text=string.format("[%s%s] %3d%% %.1f KB/s ETA %.0fs",string.rep("#",fill),string.rep("-",width-fill),floor(progress*100),speed,eta)
  local _,y=term.getCursor()
  local screenWidth=component.gpu.getResolution()
  term.setCursor(1,y)
  io.write(text:sub(1,screenWidth-1)..string.rep(" ",math.max(0,screenWidth-#text-1)))
end

local function saveMeta()
  local config={rate=rate,bytes=written,source=source}
  local file=assert(io.open("/etc/tape.meta","w"))
  file:write(serialization.serialize(config))
  file:close()
end

local function streamDfpwm()
  local request=internet.request(dfpwmUrl,nil,{["user-agent"]="OpenComputers"})
  local checked=false

  for chunk in request do
    if not checked then
      local code,msg=request.response()
      checked=true
      if not code or code<200 or code>=300 then
        return false,code,msg
      end
    end

    local remaining=targetBytes-written
    if remaining<=0 then break end
    if #chunk>remaining then chunk=chunk:sub(1,remaining) end
    tape.write(chunk)
    written=written+#chunk

    if computer.uptime()-lastDraw>=0.5 then
      draw("fast")
      lastDraw=computer.uptime()
    end

    if written>=targetBytes then break end
  end

  if not checked then
    local code,msg=request.response()
    if not code or code<200 or code>=300 then return false,code,msg end
  end

  return written>=targetBytes
end

local function convertPcm()
  local response=0
  local level=0
  local lastBit=false
  local sampleCount=0
  local pack=0
  local packBits=0
  local output={}
  local outputCount=0
  local byte=string.byte
  local char=string.char
  local unpack=table.unpack

  local function flush()
    if outputCount>0 then
      tape.write(char(unpack(output,1,outputCount)))
      written=written+outputCount
      output={}
      outputCount=0
    end
  end

  local function push(value)
    outputCount=outputCount+1
    output[outputCount]=value
    if outputCount>=256 then flush() end
  end

  local request=internet.request(pcmUrl,nil,{["user-agent"]="OpenComputers"})
  local checked=false
  local finished=false

  for chunk in request do
    if not checked then
      local code,msg=request.response()
      assert(code and code>=200 and code<300,"HTTP "..tostring(code).." "..tostring(msg))
      checked=true
    end

    for i=1,#chunk do
      if sampleCount>=targetSamples then finished=true break end

      local sample=byte(chunk,i)
      if sample>=128 then sample=sample-256 end
      local bit=sample>level or (sample==level and level==127)
      pack=bit and floor(pack/2)+128 or floor(pack/2)

      local target=bit and 127 or -128
      local nextLevel=level+floor((response*(target-level)+128)/256)
      if nextLevel==level and level~=target then nextLevel=nextLevel+(bit and 1 or -1) end

      local responseTarget,delta
      if bit==lastBit then responseTarget,delta=255,7 else responseTarget,delta=0,20 end
      local nextResponse=response+floor((delta*(responseTarget-response)+128)/256)
      if nextResponse==response and response~=responseTarget then
        nextResponse=nextResponse+(responseTarget==255 and 1 or -1)
      end

      response,level,lastBit=nextResponse,nextLevel,bit
      packBits=packBits+1
      sampleCount=sampleCount+1

      if packBits==8 then
        push(pack)
        pack=0
        packBits=0
      end
    end

    if computer.uptime()-lastDraw>=0.5 then
      draw("lua")
      lastDraw=computer.uptime()
    end
    if finished or sampleCount>=targetSamples then break end
  end

  if packBits>0 then
    while packBits<8 do
      local bit=0>level
      pack=bit and floor(pack/2)+128 or floor(pack/2)
      local target=bit and 127 or -128
      local nextLevel=level+floor((response*(target-level)+128)/256)
      if nextLevel==level and level~=target then nextLevel=nextLevel+(bit and 1 or -1) end
      local responseTarget,delta
      if bit==lastBit then responseTarget,delta=255,7 else responseTarget,delta=0,20 end
      local nextResponse=response+floor((delta*(responseTarget-response)+128)/256)
      if nextResponse==response and response~=responseTarget then
        nextResponse=nextResponse+(responseTarget==255 and 1 or -1)
      end
      response,level,lastBit=nextResponse,nextLevel,bit
      packBits=packBits+1
    end
    push(pack)
  end

  flush()
  return written>=targetBytes
end

tape.stop()
tape.seek(-tape.getPosition())
print("Downloading cached DFPWM...")

local ok,code,msg=streamDfpwm()
if not ok then
  written=0
  started=computer.uptime()
  lastDraw=0
  print("Fast cache unavailable (HTTP "..tostring(code).."). Using Lua converter...")
  assert(convertPcm(),"Conversion ended before target length")
end

draw()
io.write("\n")
tape.seek(-tape.getPosition())
saveMeta()
print("Done: "..written.." bytes, "..string.format("%.2f",targetSamples/rate).." s")
