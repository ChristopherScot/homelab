-- Belt-and-suspenders for the no-OSC-52 clipboard setup (see lua/config/options.lua).
-- yanky.nvim's default `sync_with_ring = true` reads the system clipboard on
-- FocusGained to keep its ring in sync. On this remote/tmux/Ghostty setup that
-- read becomes an OSC 52 query that pops the macOS "attempting to read from the
-- clipboard" prompt on every click into nvim. We don't route copy/paste through
-- nvim at all (Cmd-C / Cmd-V on the Mac do it), so disable the sync entirely.
return {
  {
    "gbprod/yanky.nvim",
    opts = {
      ring = { sync_with_numbered_registers = false },
      system_clipboard = { sync_with_ring = false },
    },
  },
}
