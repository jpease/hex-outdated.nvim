-- Minimal, isolated Neovim config for recording the demo GIF.
-- Loads only this plugin from the repo root (run vhs from the repo root).
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.o.termguicolors = true
-- VHS recordings should not be interrupted by user-local stale swap files.
vim.o.updatecount = 0
vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.laststatus = 0
-- Dark editor theme to match the Catppuccin Macchiato terminal theme in demo.tape.
vim.o.background = "dark"
vim.cmd.colorscheme("habamax")

require("hex-outdated").setup({})
