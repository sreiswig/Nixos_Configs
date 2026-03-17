{ config, pkgs, ... }:

let
  netcoredbg = "${pkgs.netcoredbg}/bin/netcoredbg";
in
{
  # 1. (Legacy) Consistent LunarVim Configuration for all hosts
  # Note: lvim is deprecated and removed from nixpkgs.
  # xdg.configFile."lvim/config.lua".text = ''
  #   -- Read the docs: https://www.lunarvim.org/docs/configuration
  #   -- Example configs: https://github.com/LunarVim/starter.lvim
  #   
  #   local dap = require('dap')
  #
  #   lvim.transparent_window = true
  #   lvim.format_on_save.enabled = true
  #   lvim.builtin.indentlines.active = false
  #
  #   lvim.plugins = {
  #     {
  #       'mfussenegger/nvim-dap-python',
  #       'nvim-neotest/neotest',
  #       'nvim-neotest/neotest-python',
  #       'Julian/lean.nvim',
  #       event = { 'BufReadPre *.lean', 'BufNewFile *.lean' },
  #
  #       dependencies = {
  #         'neovim/nvim-lspconfig',
  #         'nvim-lua/plenary.nvim',
  #       },
  #
  #       opts = {
  #         lsp = {},
  #         mappings = true,
  #       }
  #     },
  #   }
  #
  #   dap.adapters.coreclr = {
  #     type = 'executable',
  #     command = '${netcoredbg}',
  #     args = { '--interpreter=vscode' }
  #   }
  #
  #   dap.configurations.cs = {
  #     {
  #       type = "coreclr",
  #       name = "launch - netcoredbg",
  #       request = "launch",
  #       program = function()
  #         return vim.fn.input('Path to dll', vim.fn.getcwd() .. '/bin/Debug/', 'file')
  #       end,
  #     },
  #   }
  #
  #   require('dap-python').setup()
  # '';

  # 2. Bare Neovim Configuration mimicking LunarVim
  programs.neovim = {
    enable = true;
    defaultEditor = true; # Set as main editor
    viAlias = true;
    vimAlias = true;
    
    plugins = with pkgs.vimPlugins; [
      # Core "IDE" plugins (mimicking lvim base)
      nvim-lspconfig
      nvim-cmp
      cmp-nvim-lsp
      luasnip
      cmp_luasnip
      friendly-snippets
      nvim-treesitter.withAllGrammars
      telescope-nvim
      plenary-nvim
      which-key-nvim
      nvim-tree-lua
      nvim-web-devicons # Added for better icons
      
      # User specific plugins
      nvim-dap
      nvim-dap-python
      neotest
      neotest-python
      lean-nvim
      mini-nvim # Added for mini.icons and more
    ];

    extraPackages = with pkgs; [
      fd          # for telescope
      tree-sitter # for treesitter
      nodejs      # for node provider
      lean4       # for lean.nvim (provides lake)
      python3Packages.pynvim # for python provider
    ];

    withPython3 = true;
    withNodeJs = true;
    withRuby = true;
    withPerl = true;

    extraLuaPackages = ps: [ ps.jsregexp ];

    initLua = ''
      -- Set Leader Key
      vim.g.mapleader = " "
      vim.g.maplocalleader = " "

      -- Basic Settings
      vim.opt.termguicolors = true
      vim.opt.number = true
      vim.opt.relativenumber = true
      
      -- Transparent Window (User request)
      vim.api.nvim_set_hl(0, "Normal", { bg = "none" })
      vim.api.nvim_set_hl(0, "NormalFloat", { bg = "none" })

      -- Initialize core plugins
      require("which-key").setup {}
      require("nvim-tree").setup {}
      require("telescope").setup {}
      require("nvim-treesitter").setup {
        highlight = { enable = true },
      }

      -- Basic Keybindings (mimicking lvim)
      local wk = require("which-key")
      wk.register({
        f = { "<cmd>Telescope find_files<cr>", "Find File" },
        e = { "<cmd>NvimTreeToggle<cr>", "Explorer" },
        w = { "<cmd>w<cr>", "Save" },
        q = { "<cmd>q<cr>", "Quit" },
      }, { prefix = "<leader>" })

      -- Format on save (User request)
      vim.api.nvim_create_autocmd("BufWritePre", {
        callback = function()
          vim.lsp.buf.format()
        end,
      })

      -- DAP Setup
      local dap = require('dap')
      
      dap.adapters.coreclr = {
        type = 'executable',
        command = '${netcoredbg}',
        args = { '--interpreter=vscode' }
      }

      dap.configurations.cs = {
        {
          type = "coreclr",
          name = "launch - netcoredbg",
          request = "launch",
          program = function()
            return vim.fn.input('Path to dll', vim.fn.getcwd() .. '/bin/Debug/', 'file')
          end,
        },
      }

      -- Python DAP
      -- Note: requires debugpy to be in path or configured. 
      -- using standard setup
      require('dap-python').setup()

      -- Neotest
      require("neotest").setup({
        adapters = {
          require("neotest-python"),
        },
      })
      
      -- Lean
      require('lean').setup{
        lsp = {},
        mappings = true,
      }
    '';
  };
}
