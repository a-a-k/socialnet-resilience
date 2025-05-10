print(">>> [Lua] mixed-workload-5xx.lua loaded <<<")

local socket = require("socket")
local time = socket.gettime()*1000
math.randomseed(time)
math.random(); math.random(); math.random()

local charset = {'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', 'a', 's',
'd', 'f', 'g', 'h', 'j', 'k', 'l', 'z', 'x', 'c', 'v', 'b', 'n', 'm', 'Q',
'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', 'A', 'S', 'D', 'F', 'G', 'H',
'J', 'K', 'L', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '1', '2', '3', '4', '5',
'6', '7', '8', '9', '0'}

local decset = {'1', '2', '3', '4', '5', '6', '7', '8', '9', '0'}

-- load env vars
local max_user_index = tonumber(os.getenv("max_user_index")) or 962

local function stringRandom(length)
  if length > 0 then
    return stringRandom(length - 1) .. charset[math.random(1, #charset)]
  else
    return ""
  end
end

local function decRandom(length)
  if length > 0 then
    return decRandom(length - 1) .. decset[math.random(1, #decset)]
  else
    return ""
  end
end

local function compose_post()
  local user_index = math.random(0, max_user_index - 1)
  local username = "username_" .. tostring(user_index)
  local user_id = tostring(user_index)
  local text = stringRandom(256)
  local num_user_mentions = math.random(0, 5)
  local num_urls = math.random(0, 5)
  local num_media = math.random(0, 4)
  local media_ids = '['
  local media_types = '['

  for i = 0, num_user_mentions, 1 do
    local user_mention_id
    while (true) do
      user_mention_id = math.random(0, max_user_index - 1)
      if user_index ~= user_mention_id then
        break
      end
    end
    text = text .. " @username_" .. tostring(user_mention_id)
  end

  for i = 0, num_urls, 1 do
    text = text .. " http://" .. stringRandom(64)
  end

  for i = 0, num_media, 1 do
    local media_id = decRandom(18)
    media_ids = media_ids .. "\"" .. media_id .. "\"," 
    media_types = media_types .. "\"png\"," 
  end

  media_ids = media_ids:sub(1, #media_ids - 1) .. "]"
  media_types = media_types:sub(1, #media_types - 1) .. "]"

  local method = "POST"
  local path = "http://localhost:8080/wrk2-api/post/compose"
  local headers = {}
  local body
  headers["Content-Type"] = "application/x-www-form-urlencoded"
  if num_media then
    body = "username=" .. username .. "&user_id=" .. user_id ..
           "&text=" .. text .. "&media_ids=" .. media_ids ..
           "&media_types=" .. media_types .. "&post_type=0"
  else
    body = "username=" .. username .. "&user_id=" .. user_id ..
           "&text=" .. text .. "&media_ids=" .. "&post_type=0"
  end

  return wrk.format(method, path, headers, body)
end

local function read_user_timeline()
  local user_id = tostring(math.random(0, max_user_index - 1))
  local start = tostring(math.random(0, 100))
  local stop = tostring(start + 10)

  local args = "user_id=" .. user_id .. "&start=" .. start .. "&stop=" .. stop
  local method = "GET"
  local headers = {}
  headers["Content-Type"] = "application/x-www-form-urlencoded"
  local path = "http://localhost:8080/wrk2-api/user-timeline/read?" .. args
  return wrk.format(method, path, headers, nil)
end

local function read_home_timeline()
  local user_id = tostring(math.random(0, max_user_index - 1))
  local start = tostring(math.random(0, 100))
  local stop = tostring(start + 10)
  
  local args = "user_id=" .. user_id .. "&start=" .. start .. "&stop=" .. stop
  local method = "GET"
  local headers = {}
  headers["Content-Type"] = "application/x-www-form-urlencoded"
  local path = "http://localhost:8080/wrk2-api/home-timeline/read?" .. args
  return wrk.format(method, path, headers, nil)
end

request = function()
  cur_time = math.floor(socket.gettime())
  local read_home_timeline_ratio = 0.60
  local read_user_timeline_ratio = 0.30
  local compose_post_ratio = 0.10
  
  local coin = math.random()
  if coin < read_home_timeline_ratio then
    return read_home_timeline()
  elseif coin < read_home_timeline_ratio + read_user_timeline_ratio then
    return read_user_timeline()
  else
    return compose_post()
  end
end

-- Initialize status code tracking with a thread-local approach
local thread_local = {}

-- Make sure we have a global table for thread data
-- Even if wrk.thread changes between setup() and response()
if _G.thread_data == nil then
  _G.thread_data = {}
end

-- setup() is called once for each thread
setup = function(thread)
  -- Create a new table for this thread's status codes
  thread_local[thread:get_id()] = {}
  
  -- Store the thread ID in the thread's environment
  thread:set("id", thread:get_id())
  
  -- Store in global table too for backup
  _G.thread_data[thread:get_id()] = {}
end

-- response() is called for each HTTP response received
response = function(status, headers, body)
  -- Get the current thread's ID (should be available in thread environment)
  local thread_id = wrk.thread:get("id")
  
  -- Try to use the thread-local table first
  local codes_table = thread_local[thread_id]
  
  -- If that fails, try the global backup
  if not codes_table then
    codes_table = _G.thread_data[thread_id]
    
    -- If we still don't have a table, create a new one
    if not codes_table then
      _G.thread_data[thread_id] = {}
      codes_table = _G.thread_data[thread_id]
    end
  end
  
  -- Now increment the counter for this status code
  codes_table[status] = (codes_table[status] or 0) + 1
end

-- done() is called once after all requests are complete
done = function(summary, latency, requests)
  print("=== Status Code Summary (wrk2 Lua) ===")
  local aggregated_codes = {}

  -- Combine counts from all threads (from both local and global sources)
  -- First from thread_local
  for _, codes in pairs(thread_local) do
    for code, count in pairs(codes) do
      aggregated_codes[code] = (aggregated_codes[code] or 0) + count
    end
  end
  
  -- Then from global backup
  for _, codes in pairs(_G.thread_data) do
    for code, count in pairs(codes) do
      aggregated_codes[code] = (aggregated_codes[code] or 0) + count
    end
  end

  -- Print the aggregated results
  if next(aggregated_codes) == nil then
    print("No status codes were recorded.")
  else
    for code, count in pairs(aggregated_codes) do
      print("Status " .. code .. ": " .. count)
    end
  end
  print("=== End Status Code Summary ===")
end
