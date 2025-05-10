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

-- This table will store references to all active thread objects.
-- It needs to be global or accessible to the done() function.
threads = {}

-- This table will store the status code tables for each thread.
-- We use the thread object itself as the key.
local per_thread_status_data = {}

-- setup() is called once for each thread.
-- The 'thread' argument here is the userdata object for the current thread.
setup = function(thread)
  -- Create a new, empty table to hold status codes for THIS thread.
  -- Store it in our per_thread_status_data table, using the thread object as the key.
  per_thread_status_data[thread] = {}

  -- Add this thread object to our list of all threads.
  -- This allows us to iterate over all threads in the done() function.
  table.insert(threads, thread)
end

-- response() is called for each HTTP response received.
response = function(status, headers, body)
  -- 'wrk.thread' is a reference to the current thread's userdata object.
  -- We use it to look up this thread's dedicated status code table.
  local current_thread_codes = per_thread_status_data[wrk.thread]

  -- It's crucial that wrk.thread here is one of the thread objects
  -- for which setup() was called.
  if current_thread_codes then
    current_thread_codes[status] = (current_thread_codes[status] or 0) + 1
  else
    -- This would indicate an issue, e.g., response() called for a thread
    -- not seen in setup(). Should not typically happen.
    print("PANIC: No status_codes table for current thread in response()!")
  end
end

-- done() is called once after all requests are complete.
done = function(summary, latency, requests)
  print("=== Status Code Summary (wrk2 Lua) ===")
  local aggregated_codes = {}

  -- Iterate through all the thread objects we stored earlier.
  for _, thread_instance in ipairs(threads) do
    -- Get the status code table for this specific thread_instance.
    local thread_specific_codes = per_thread_status_data[thread_instance]
    if thread_specific_codes then
      for code, count in pairs(thread_specific_codes) do
        aggregated_codes[code] = (aggregated_codes[code] or 0) + count
      end
    end
  end

  -- Print the final aggregated results.
  if next(aggregated_codes) == nil then
    print("No status codes were recorded.")
  else
    for code, count in pairs(aggregated_codes) do
      print("Status " .. code .. ": " .. count)
    end
  end
  print("=== End Status Code Summary ===")
end
