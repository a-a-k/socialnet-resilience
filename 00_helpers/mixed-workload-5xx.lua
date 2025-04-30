-- mixed-workload-5xx.lua
-- exactly the same requests as the original script
-- but prints ONLY 5xx responses, so we can grep it later.

wrk.method = "GET"
wrk.headers["Content-Type"] = "application/json"

local counter_5xx = 0

-- reused generate_request() from the original file ----------------
local rnd = math.random
local function mk_id() return rnd(1, 100000) end

function request()
  local n = rnd(1, 5)
  if     n == 1 then return "GET",  "/wrk2-api/post/id/"..mk_id().."/", ""
  elseif n == 2 then return "GET",  "/wrk2-api/user-timeline?user_id="..mk_id().."&limit=10&start=0", ""
  elseif n == 3 then return "GET",  "/wrk2-api/home-timeline?user_id="..mk_id().."&limit=10&start=0", ""
  elseif n == 4 then return "GET",  "/wrk2-api/user?id="..mk_id(), ""
  else              return "GET",  "/wrk2-api/url-shorten?url=http://example.com/"..mk_id(), ""
  end
end

---------------------------------------------------------------------
function response(status, headers, body)
  if status >= 500 then counter_5xx = counter_5xx + 1 end
end

function done(summary, latency, requests)
  io.write(string.format("5xx_responses: %d\n", counter_5xx))
end
