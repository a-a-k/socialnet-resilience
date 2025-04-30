-- mixed-workload-5xx.lua
-- identical request mix to the upstream script,
-- but prints ONLY the count of HTTP 5xx responses.

wrk.method  = "GET"
wrk.headers["Content-Type"] = "application/json"

local rnd      = math.random
local counter5 = 0

local function id() return rnd(1, 100000) end

local function fmt(path) return wrk.format("GET", path) end

function request()
  local n = rnd(1, 5)
  if     n == 1 then return fmt("/wrk2-api/post/id/"..id().."/")
  elseif n == 2 then return fmt("/wrk2-api/user-timeline?user_id="..id().."&limit=10&start=0")
  elseif n == 3 then return fmt("/wrk2-api/home-timeline?user_id="..id().."&limit=10&start=0")
  elseif n == 4 then return fmt("/wrk2-api/user?id="..id())
  else              return fmt("/wrk2-api/url-shorten?url=http://example.com/"..id())
  end
end

function response(status, _, _)
  if status >= 500 then counter5 = counter5 + 1 end
end

function done()
  io.write(string.format("5xx_responses: %d\n", counter5))
end
