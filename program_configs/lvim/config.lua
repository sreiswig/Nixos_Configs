-- Read the docs: https://www.lunarvim.org/docs/configuration
-- Example configs: https://github.com/LunarVim/starter.lvim
-- Video Tutorials: https://www.youtube.com/watch?v=sFA9kX-Ud_c&list=PLhoH5vyxr6QqGu0i7tt_XoVK9v-KvZ3m6
-- Forum: https://www.reddit.com/r/lunarvim/
-- Discord: https://discord.com/invite/Xb9B4Ny
--
lvim.transparent_window = true

lvim.plugins = {
 {
  'mfussenegger/nvim-dap-python',
  'nvim-neotest/neotest',
  'nvim-neotest/neotest-python',
  'Julian/lean.nvim',
  event = { 'BufReadPre *.lean', 'BufNewFile *.lean' },

  dependencies = {
    'neovim/nvim-lspconfig',
    'nvim-lua/plenary.nvim',
    -- you also will likely want nvim-cmp or some completion engine
  },

  -- see details below for full configuration options
  opts = {
    lsp = {},
    mappings = true,
  }
 },
}
