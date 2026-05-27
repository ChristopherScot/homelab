
-- These pods are REMOTE (kubectl exec, inside tmux, viewed in Ghostty on a Mac).
-- Copy/paste between the Mac and nvim is done ENTIRELY with the terminal:
--   * Cmd-C copies the terminal selection (hold Shift while dragging to select
--     past tmux mouse mode) -> Mac clipboard.
--   * Cmd-V bracketed-pastes the Mac clipboard into nvim (insert mode).
-- Neither uses OSC 52, so neither triggers macOS's "an application is attempting
-- to read from the clipboard" prompt.
--
-- That prompt was caused by nvim *reading* the system clipboard over OSC 52:
-- neovim 0.12 auto-enables an OSC 52 provider from terminal capability detection
-- (not just $SSH_TTY, and invisible in g:clipboard), and yanky.nvim syncs that
-- clipboard on FocusGained -> a read on every click into nvim.
--
-- Fix: keep yy/p on the internal register (clipboard = "") and fully NEUTER the
-- system-clipboard provider with a no-op g.clipboard so the +/* registers never
-- emit an OSC 52 read or write. yanky's sync is also disabled in
-- lua/plugins/clipboard.lua as belt-and-suspenders.
vim.opt.clipboard = ""

vim.g.clipboard = {
  name = "noop",
  copy = { ["+"] = function() end, ["*"] = function() end },
  paste = {
    ["+"] = function() return { {}, "v" } end,
    ["*"] = function() return { {}, "v" } end,
  },
}
