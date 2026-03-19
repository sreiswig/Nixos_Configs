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
      nvim-web-devicons
      
      # UI Enhancements (LunarVim style)
      lualine-nvim
      bufferline-nvim
      alpha-nvim
      gitsigns-nvim
      toggleterm-nvim
      project-nvim
      none-ls-nvim
      
      # User specific plugins
      nvim-dap
      nvim-dap-python
      neotest
      neotest-python
      lean-nvim
      mini-nvim
      catppuccin-nvim
    ];

    extraPackages = with pkgs; [
      fd          # for telescope
      ripgrep     # for telescope live grep
      tree-sitter # for treesitter
      nodejs      # for node provider
      lean4       # for lean.nvim (provides lake)
      python3Packages.pynvim # for python provider
      
      # LSP Servers
      nil         # Nix
      pyright     # Python
      lua-language-server
      nodePackages.typescript-language-server
      marksman    # Markdown
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
      vim.opt.clipboard = "unnamedplus"
      vim.opt.mouse = "a"
      vim.opt.ignorecase = true
      vim.opt.smartcase = true
      vim.opt.shiftwidth = 2
      vim.opt.tabstop = 2
      vim.opt.expandtab = true
      
      -- Catppuccin Theme
      require("catppuccin").setup({
          flavour = "mocha",
          transparent_background = true,
          integrations = {
              cmp = true,
              gitsigns = true,
              nvimtree = true,
              treesitter = true,
              bufferline = true,
              telescope = { enabled = true },
              lsp_trouble = true,
              which_key = true,
              mini = {
                  enabled = true,
                  indentscope_color = "",
              },
          },
      })
      vim.cmd.colorscheme "catppuccin"

      -- Initialize core plugins
      require("which-key").setup {}
      require("nvim-tree").setup {
        filters = { dotfiles = false },
        view = { width = 30 }
      }
      require("telescope").setup {
        defaults = {
          file_ignore_patterns = { "node_modules", ".git" },
        }
      }
      require("nvim-treesitter.configs").setup {
        highlight = { enable = true },
        indent = { enable = true },
      }
      
      -- Lualine
      require('lualine').setup {
        options = { theme = 'catppuccin' }
      }

      -- Bufferline
      require("bufferline").setup {
        options = {
          separator_style = "thin",
          offsets = { { filetype = "NvimTree", text = "File Explorer", text_align = "left" } },
        }
      }

      -- Gitsigns
      require('gitsigns').setup()

      -- Toggleterm
      require("toggleterm").setup{
        size = 20,
        open_mapping = [[<c-\>]],
        hide_numbers = true,
        shade_terminals = true,
        direction = 'float',
        float_opts = { border = 'curved' }
      }

      local Terminal  = require('toggleterm.terminal').Terminal
      local node = Terminal:new({ cmd = "node", hidden = true })
      function _NODE_TOGGLE()
        node:toggle()
      end

      local python = Terminal:new({ cmd = "python3", hidden = true })
      function _PYTHON_TOGGLE()
        python:toggle()
      end

      local htop = Terminal:new({ cmd = "htop", hidden = true })
      function _HTOP_TOGGLE()
        htop:toggle()
      end

      -- Alpha (Dashboard)
      local alpha = require("alpha")
      local dashboard = require("alpha.themes.dashboard")
      dashboard.section.header.val = {
        [[                               __                ]],
        [[  ___     ___    ___   __  __ /\_\    ___ ___    ]],
        [[ / _ `\  / __`\ / __`\/\ \/\ \\/\ \  / __` __`\  ]],
        [[/\ \/\ \/\  __//\ \_\ \ \ \_/ |\ \ \/\ \/\ \/\ \ ]],
        [[\ \_\ \_\ \____\ \____/\ \___/  \ \_\ \_\ \_\ \_\]],
        [[ \/_/\/_/\/____/\/___/  \/__/    \/_/\/_/\/_/\/_/]],
      }
      alpha.setup(dashboard.config)

      -- Project
      require("project_nvim").setup {}
      require('telescope').load_extension('projects')

      -- LSP Config
      local lspconfig = require('lspconfig')
      local capabilities = require('cmp_nvim_lsp').default_capabilities()

      local on_attach = function(client, bufnr)
        local function buf_set_keymap(...) vim.api.nvim_buf_set_keymap(bufnr, ...) end
        local opts = { noremap=true, silent=true }
        buf_set_keymap('n', 'gD', '<Cmd>lua vim.lsp.buf.declaration()<CR>', opts)
        buf_set_keymap('n', 'gd', '<Cmd>lua vim.lsp.buf.definition()<CR>', opts)
        buf_set_keymap('n', 'K', '<Cmd>lua vim.lsp.buf.hover()<CR>', opts)
        buf_set_keymap('n', 'gi', '<cmd>lua vim.lsp.buf.implementation()<cr>', opts)
        buf_set_keymap('n', '<C-k>', '<cmd>lua vim.lsp.buf.signature_help()<cr>', opts)
        buf_set_keymap('n', 'gr', '<cmd>lua vim.lsp.buf.references()<cr>', opts)
      end

      local servers = { 'nil_ls', 'pyright', 'lua_ls', 'tsserver' }
      for _, lsp in ipairs(servers) do
        lspconfig[lsp].setup {
          on_attach = on_attach,
          capabilities = capabilities,
        }
      end

      -- None-ls (Formatting/Linting)
      local null_ls = require("null-ls")
      null_ls.setup({
          sources = {
              null_ls.builtins.formatting.stylua,
              null_ls.builtins.formatting.prettier,
              null_ls.builtins.formatting.black,
          },
      })

      -- Completion
      local cmp = require'cmp'
      cmp.setup({
        snippet = {
          expand = function(args)
            require('luasnip').lsp_expand(args.body)
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ['<C-b>'] = cmp.mapping.scroll_docs(-4),
          ['<C-f>'] = cmp.mapping.scroll_docs(4),
          ['<C-Space>'] = cmp.mapping.complete(),
          ['<C-e>'] = cmp.mapping.abort(),
          ['<CR>'] = cmp.mapping.confirm({ select = true }),
        }),
        sources = cmp.config.sources({
          { name = 'nvim_lsp' },
          { name = 'luasnip' },
        }, {
          { name = 'buffer' },
        })
      })

      -- Keybindings (LunarVim style)
      local wk = require("which-key")
      wk.register({
        ["<leader>f"] = { "<cmd>Telescope find_files<cr>", "Find File" },
        ["<leader>e"] = { "<cmd>NvimTreeToggle<cr>", "Explorer" },
        ["<leader>w"] = { "<cmd>w<cr>", "Save" },
        ["<leader>q"] = { "<cmd>q<cr>", "Quit" },
        ["<leader>h"] = { "<cmd>nohlsearch<cr>", "No Highlight" },
        ["<leader>b"] = {
          name = "Buffers",
          j = { "<cmd>BufferLinePick<cr>", "Jump" },
          f = { "<cmd>Telescope buffers<cr>", "Find" },
          b = { "<cmd>BufferLineCyclePrev<cr>", "Previous" },
          n = { "<cmd>BufferLineCycleNext<cr>", "Next" },
          e = { "<cmd>BufferLinePickClose<cr>", "Pick Close" },
        },
        ["<leader>g"] = {
          name = "Git",
          j = { "<cmd>lua require 'gitsigns'.next_hunk()<cr>", "Next Hunk" },
          k = { "<cmd>lua require 'gitsigns'.prev_hunk()<cr>", "Prev Hunk" },
          l = { "<cmd>lua require 'gitsigns'.blame_line()<cr>", "Blame" },
          p = { "<cmd>lua require 'gitsigns'.preview_hunk()<cr>", "Preview Hunk" },
          r = { "<cmd>lua require 'gitsigns'.reset_hunk()<cr>", "Reset Hunk" },
          R = { "<cmd>lua require 'gitsigns'.reset_buffer()<cr>", "Reset Buffer" },
          s = { "<cmd>lua require 'gitsigns'.stage_hunk()<cr>", "Stage Hunk" },
          u = { "<cmd>lua require 'gitsigns'.undo_stage_hunk()<cr>", "Undo Stage Hunk" },
          o = { "<cmd>Telescope git_status<cr>", "Open changed file" },
          b = { "<cmd>Telescope git_branches<cr>", "Checkout branch" },
          c = { "<cmd>Telescope git_commits<cr>", "Checkout commit" },
        },
        ["<leader>l"] = {
          name = "LSP",
          a = { "<cmd>lua vim.lsp.buf.code_action()<cr>", "Code Action" },
          d = { "<cmd>Telescope lsp_document_diagnostics<cr>", "Document Diagnostics" },
          w = { "<cmd>Telescope lsp_workspace_diagnostics<cr>", "Workspace Diagnostics" },
          f = { "<cmd>lua vim.lsp.buf.format({ async = true })<cr>", "Format" },
          i = { "<cmd>LspInfo<cr>", "Info" },
          I = { "<cmd>LspInstallInfo<cr>", "Installer Info" },
          j = { "<cmd>lua vim.diagnostic.goto_next()<cr>", "Next Diagnostic" },
          k = { "<cmd>lua vim.diagnostic.goto_prev()<cr>", "Prev Diagnostic" },
          l = { "<cmd>lua vim.lsp.codelens.run()<cr>", "CodeLens Action" },
          q = { "<cmd>lua vim.diagnostic.setloclist()<cr>", "Quickfix" },
          r = { "<cmd>lua vim.lsp.buf.rename()<cr>", "Rename" },
          s = { "<cmd>Telescope lsp_document_symbols<cr>", "Document Symbols" },
          S = { "<cmd>Telescope lsp_dynamic_workspace_symbols<cr>", "Workspace Symbols" },
        },
        ["<leader>s"] = {
          name = "Search",
          b = { "<cmd>Telescope git_branches<cr>", "Checkout branch" },
          c = { "<cmd>Telescope colorscheme<cr>", "Colorscheme" },
          h = { "<cmd>Telescope help_tags<cr>", "Find Help" },
          M = { "<cmd>Telescope man_pages<cr>", "Man Pages" },
          r = { "<cmd>Telescope oldfiles<cr>", "Open Recent File" },
          R = { "<cmd>Telescope registers<cr>", "Registers" },
          t = { "<cmd>Telescope live_grep<cr>", "Text" },
          k = { "<cmd>Telescope keymaps<cr>", "Keymaps" },
          C = { "<cmd>Telescope commands<cr>", "Commands" },
          p = { "<cmd>lua require('telescope.builtin').colorscheme({enable_preview = true})<cr>", "Colorscheme with Preview" },
        },
        ["<leader>t"] = {
          name = "Terminal",
          n = { "<cmd>lua _NODE_TOGGLE()<cr>", "Node" },
          u = { "<cmd>lua _NCDU_TOGGLE()<cr>", "NCDU" },
          t = { "<cmd>lua _HTOP_TOGGLE()<cr>", "Htop" },
          p = { "<cmd>lua _PYTHON_TOGGLE()<cr>", "Python" },
          f = { "<cmd>ToggleTerm direction=float<cr>", "Float" },
          h = { "<cmd>ToggleTerm direction=horizontal<cr>", "Horizontal" },
          v = { "<cmd>ToggleTerm direction=vertical<cr>", "Vertical" },
        },
        ["<leader>p"] = { "<cmd>Telescope projects<cr>", "Projects" },
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
