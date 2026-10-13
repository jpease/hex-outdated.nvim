-- Minimal `_G.vim` stand-in for specs that run without Neovim.
local M = {}

--- Replace `_G.vim` with a fake: synchronous `schedule`, `notify` that records
--- messages in `fake.notified`, `log.levels`, plus every field of `fields`.
--- Returns the fake and a function restoring the previous `_G.vim`.
function M.install(fields)
	local previous = rawget(_G, "vim")
	local fake = {
		notified = {},
		log = { levels = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 } },
		schedule = function(fn)
			fn()
		end,
	}
	fake.notify = function(msg)
		fake.notified[#fake.notified + 1] = msg
	end
	for k, v in pairs(fields or {}) do
		fake[k] = v
	end
	_G.vim = fake
	return fake, function()
		_G.vim = previous
	end
end

return M
