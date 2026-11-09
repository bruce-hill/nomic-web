
local MAX_OUTPUT = 64 * 1024

local Buffer = {}
Buffer.__index = Buffer

function Buffer.new()
    return setmetatable({parts={}, size=0}, Buffer)
end

function Buffer:write(text)
    if self.size < MAX_OUTPUT then
        self.parts[#self.parts + 1] = text
        self.size = self.size + #text
    end
end

function Buffer:flush()
    local text = table.concat(self.parts)
    self.parts, self.size = {}, 0
    return (string.gsub(text, "\n$", ""))
end

return Buffer
