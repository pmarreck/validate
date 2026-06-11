-- Tiny HTML helpers for the site generator. Rendering stays pure: these
-- functions map strings to strings, no I/O.

local M = {}

local ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }

function M.esc(s)
	return (tostring(s):gsub('[&<>"\']', ESC))
end

-- Escape for embedding inside a <script> JSON/string context: also break
-- "</script" sequences.
function M.js_str(s)
	local v = tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("</", "<\\/")
	return '"' .. v .. '"'
end

return M
