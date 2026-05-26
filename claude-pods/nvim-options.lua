-- LazyVim user options (loaded after defaults). These pods are REMOTE
-- (ssh -> kubectl exec), so clipboard sync goes over OSC 52.
--
-- We DO want yanks in pod-nvim to reach the Mac clipboard. The repeated macOS
-- "an application is attempting to read from the clipboard" modal comes from
-- clipboard *reads* (OSC 52 paste/register sync) — macOS prompts per read.
-- Fix: OSC 52 for COPY only, and a no-op paste (returns empty) so nvim never
-- issues a clipboard *read* back over the wire. You still paste via normal
-- terminal paste (Cmd-V), which doesn't prompt. Yank (y) -> Mac clipboard works.
local function osc52_copy(lines)
  return require("vim.ui.clipboard.osc52").copy("+")(lines)
end
vim.opt.clipboard = "unnamedplus"
vim.g.clipboard = {
  name = "osc52-copy-only",
  copy = { ["+"] = osc52_copy, ["*"] = osc52_copy },
  -- no-op paste: never read the system clipboard (avoids the macOS modal)
  paste = { ["+"] = function() return { {}, "v" } end, ["*"] = function() return { {}, "v" } end },
}
