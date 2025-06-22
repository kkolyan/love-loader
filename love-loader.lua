require "love.filesystem"
require "love.image"
require "love.audio"
require "love.sound"

local loader = {
  _VERSION     = 'love-loader v2.0.3',
  _DESCRIPTION = 'Threaded resource loading for LÖVE',
  _URL         = 'https://github.com/kikito/love-loader',
  _LICENSE     = [[
    MIT LICENSE

    Copyright (c) 2014 Enrique García Cota, Tanner Rogalsky

    Permission is hereby granted, free of charge, to any person obtaining a
    copy of this software and associated documentation files (the
    "Software"), to deal in the Software without restriction, including
    without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to
    the following conditions:

    The above copyright notice and this permission notice shall be included
    in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
    IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
    CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
    TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
    SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
  ]]
}

local resourceKinds = {
  image = {
    requestKey  = "imagePath",
    resourceKey = "imageData",
    constructor = function (path)
      if love.image.isCompressed(path) then
        return love.image.newCompressedData(path)
      else
        return love.image.newImageData(path)
      end
    end,
    --[[postProcess = function(data)
      return love.graphics.newImage(data)
    end]]
    
    -- FIX from 3freamengine developer
     postProcess = function(data)
		local img = love.graphics.newImage(data)
		img:setWrap("repeat", "repeat")
		img:setFilter("nearest")
		return img
    end
   --/ 
    
  },
  staticSource = {
    requestKey  = "staticPath",
    resourceKey = "staticSource",
    constructor = function(path)
      return love.audio.newSource(path, "static")
    end
  },
  font = {
    requestKey  = "fontPath",
    resourceKey = "fontData",
    constructor = function(path)
      -- we don't use love.filesystem.newFileData directly here because there
      -- are actually two arguments passed to this constructor which in turn
      -- invokes the wrong love.filesystem.newFileData overload
      return love.filesystem.newFileData(path)
    end,
    postProcess = function(data, resource)
      local path, size = unpack(resource.requestParams)
      return love.graphics.newFont(data, size)
    end
  },
  BMFont = {
    requestKey  = "fontBMPath",
    resourceKey = "fontBMData",
    constructor = function(path)
      return love.filesystem.newFileData(path)
    end,
    postProcess = function(data, resource)
      local imagePath, glyphsPath  = unpack(resource.requestParams)
      local glyphs = love.filesystem.newFileData(glyphsPath)
      return love.graphics.newFont(glyphs,data)
    end
  },
  streamSource = {
    requestKey  = "streamPath",
    resourceKey = "streamSource",
    constructor = function(path)
      return love.audio.newSource(path, "stream")
    end
  },
  soundData = {
    requestKey  = "soundDataPathOrDecoder",
    resourceKey = "soundData",
    constructor = love.sound.newSoundData
  },
  imageData = {
    requestKey  = "imageDataPath",
    resourceKey = "rawImageData",
    constructor = love.image.newImageData
  },
  compressedData = {
    requestKey  = "compressedDataPath",
    resourceKey = "rawCompressedData",
    constructor = love.image.newCompressedData
  }
}

local CHANNEL_PREFIX = "loader_"

-- on my data multithreading doesn't give any benefits. the key of speed is async communication between main and loader threads.
local THREAD_COUNT = 1

local loaded, thisThreadId = ...
if loaded == true then
  local done = false

  local doneChannel = love.thread.getChannel(CHANNEL_PREFIX  .. thisThreadId .. "_is_done")

  while not done do

    for kindName,kind in pairs(resourceKinds) do
      local requestQueue = love.thread.getChannel(CHANNEL_PREFIX .. kind.requestKey)
      local task = requestQueue:pop()

      if task then
        local requestParams = task.requestParams
        --print("["..thisThreadId.."] Loading "..kindName.."( "..table.concat(requestParams, ", ").." )")
        local resource = kind.constructor(unpack(requestParams))
        --print("["..thisThreadId.."] Loaded!!! "..kindName.."( "..table.concat(requestParams, ", ").." )")
        local producer = love.thread.getChannel(CHANNEL_PREFIX .. kind.resourceKey)
        producer:push({
          result = resource,
        -- it's state is not thread-safe, so don't access - just pass back in result
          resourceBeingLoaded = task.resourceBeingLoaded
        })
      end
    end

    done = doneChannel:pop()
  end

else

  local pending = {}
  local callbacks = {}
  local resourceBeingLoadedCount = 0
  local shelf = {}
  local prevShelfId = 0

  local pathToThisFile = (...):gsub("%.", "/") .. ".lua"

  local function shift(t)
    return table.remove(t,1)
  end

  local function newResource(kind, holder, key, ...)
    pending[#pending + 1] = {
      kind = kind, holder = holder, key = key, requestParams = {...}
    }
  end

  local function putToShelf(obj)
    local shelfId = prevShelfId + 1;
    prevShelfId = shelfId
    shelf[shelfId] = obj
    return shelfId
  end

  local function takeFromShelf(id)
    local obj = shelf[id]
    shelf[id] = nil
    return obj
  end

  local function getResourceFromThreadIfAvailable()
    local data, resource
    for name,kind in pairs(resourceKinds) do
      while true do
        local channel = love.thread.getChannel(CHANNEL_PREFIX .. kind.resourceKey)
        data = channel:pop()
        if not data then
          break
        end
        local resourceBeingLoaded = takeFromShelf(data.resourceBeingLoaded)
        --print("Dequeueing "..resourceBeingLoaded.kind.."( "..table.concat(resourceBeingLoaded.requestParams, ", ").." )")
        assert(data.result)
        resource = kind.postProcess and kind.postProcess(data.result, resourceBeingLoaded) or data.result
        resourceBeingLoaded.holder[resourceBeingLoaded.key] = resource
        loader.loadedCount = loader.loadedCount + 1
        callbacks.oneLoaded(resourceBeingLoaded.kind, resourceBeingLoaded.holder, resourceBeingLoaded.key)
        resourceBeingLoadedCount = resourceBeingLoadedCount - 1
      end
    end
  end

  local function requestNewResourceToThread()
    while #pending > 0 do
      local resourceBeingLoaded = shift(pending)
      resourceBeingLoadedCount = resourceBeingLoadedCount + 1
      local requestKey = resourceKinds[resourceBeingLoaded.kind].requestKey
      local channel = love.thread.getChannel(CHANNEL_PREFIX .. requestKey)
      --print("Enqueueing "..resourceBeingLoaded.kind.."( "..table.concat(resourceBeingLoaded.requestParams, ", ").." )")

      channel:push({
        resourceBeingLoaded = putToShelf(resourceBeingLoaded),
        requestParams = resourceBeingLoaded.requestParams
      })
    end
  end

  -----------------------------------------------------

  function loader.newImage(holder, key, path)
    newResource('image', holder, key, path)
  end

  function loader.newFont(holder, key, path, size)
    newResource('font', holder, key, path, size)
  end

  function loader.newBMFont(holder, key, path, glyphsPath)
    newResource('font', holder, key, path, glyphsPath)
  end

  function loader.newSource(holder, key, path, sourceType)
    local kind = (sourceType == 'static' and 'staticSource' or 'streamSource')
    newResource(kind, holder, key, path)
  end

  function loader.newSoundData(holder, key, pathOrDecoder)
    newResource('soundData', holder, key, pathOrDecoder)
  end

  function loader.newImageData(holder, key, path)
    newResource('imageData', holder, key, path)
  end
  
  function loader.newCompressedData(holder, key, path)
    newResource('compressedData', holder, key, path)
  end

  function loader.start(allLoadedCallback, oneLoadedCallback)

    callbacks.allLoaded = allLoadedCallback or function() end
    callbacks.oneLoaded = oneLoadedCallback or function() end

    loader.loadedCount = 0
    loader.resourceCount = #pending
    loader.threadCount = 0
    loader.threads = {}

    for i = 1, THREAD_COUNT, 1 do
      local threadId = tostring(i)
      local thread = love.thread.newThread(pathToThisFile)

      loader.threads[threadId] = thread
      loader.threadCount = loader.threadCount + 1

      thread:start(true, threadId)
    end

  end

  function loader.update()
    if loader.threadCount > 0 then
      for threadId, thread in pairs(loader.threads) do
        local errorMessage = thread:getError()
        assert(not errorMessage, errorMessage)
      end

      requestNewResourceToThread()
      getResourceFromThreadIfAvailable()

      if resourceBeingLoadedCount <= 0 and #pending <= 0 then
        for threadId, thread in pairs(loader.threads) do
          love.thread.getChannel(CHANNEL_PREFIX  .. threadId .. "_is_done"):push(true)
          loader.threads[threadId] = nil
          loader.threadCount = loader.threadCount - 1
        end
        callbacks.allLoaded()
      end
    end
  end

  return loader
end
