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
      typescript-language-server
      marksman    # Markdown

      # Formatters/Linters (for none-ls)
      stylua
      prettier
      black
      ncdu
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
      require("nvim-treesitter").setup {
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

      local ncdu = Terminal:new({ cmd = "ncdu", hidden = true })
      function _NCDU_TOGGLE()
        ncdu:toggle()
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

      -- LSP Config (Neovim 0.11+)
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

      -- Set global configuration for all servers
      vim.lsp.config['*'] = {
        on_attach = on_attach,
        capabilities = capabilities,
      }

      -- Enable servers
      local servers = { 'nil_ls', 'pyright', 'lua_ls', 'ts_ls' }
      for _, lsp in ipairs(servers) do
        vim.lsp.enable(lsp)
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
      require("luasnip.loaders.from_vscode").lazy_load()
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
      wk.add({
        { "<leader>f", "<cmd>Telescope find_files<cr>", desc = "Find File" },
        { "<leader>e", "<cmd>NvimTreeToggle<cr>", desc = "Explorer" },
        { "<leader>w", "<cmd>w<cr>", desc = "Save" },
        { "<leader>q", "<cmd>q<cr>", desc = "Quit" },
        { "<leader>h", "<cmd>nohlsearch<cr>", desc = "No Highlight" },
        { "<leader>p", "<cmd>Telescope projects<cr>", desc = "Projects" },
        
        -- Buffers
        { "<leader>b", group = "Buffers" },
        { "<leader>bj", "<cmd>BufferLinePick<cr>", desc = "Jump" },
        { "<leader>bf", "<cmd>Telescope buffers<cr>", desc = "Find" },
        { "<leader>bb", "<cmd>BufferLineCyclePrev<cr>", desc = "Previous" },
        { "<leader>bn", "<cmd>BufferLineCycleNext<cr>", desc = "Next" },
        { "<leader>be", "<cmd>BufferLinePickClose<cr>", desc = "Pick Close" },
        
        -- Git
        { "<leader>g", group = "Git" },
        { "<leader>gj", function() require('gitsigns').next_hunk() end, desc = "Next Hunk" },
        { "<leader>gk", function() require('gitsigns').prev_hunk() end, desc = "Prev Hunk" },
        { "<leader>gl", function() require('gitsigns').blame_line() end, desc = "Blame" },
        { "<leader>gp", function() require('gitsigns').preview_hunk() end, desc = "Preview Hunk" },
        { "<leader>gr", function() require('gitsigns').reset_hunk() end, desc = "Reset Hunk" },
        { "<leader>gR", function() require('gitsigns').reset_buffer() end, desc = "Reset Buffer" },
        { "<leader>gs", function() require('gitsigns').stage_hunk() end, desc = "Stage Hunk" },
        { "<leader>gu", function() require('gitsigns').undo_stage_hunk() end, desc = "Undo Stage Hunk" },
        { "<leader>go", "<cmd>Telescope git_status<cr>", desc = "Open changed file" },
        { "<leader>gb", "<cmd>Telescope git_branches<cr>", desc = "Checkout branch" },
        { "<leader>gc", "<cmd>Telescope git_commits<cr>", desc = "Checkout commit" },
        
        -- LSP
        { "<leader>l", group = "LSP" },
        { "<leader>la", "<cmd>lua vim.lsp.buf.code_action()<cr>", desc = "Code Action" },
        { "<leader>ld", "<cmd>Telescope diagnostics bufnr=0<cr>", desc = "Document Diagnostics" },
        { "<leader>lw", "<cmd>Telescope diagnostics<cr>", desc = "Workspace Diagnostics" },
        { "<leader>lf", "<cmd>lua vim.lsp.buf.format({ async = true })<cr>", desc = "Format" },
        { "<leader>li", "<cmd>LspInfo<cr>", desc = "Info" },
        { "<leader>lj", "<cmd>lua vim.diagnostic.goto_next()<cr>", desc = "Next Diagnostic" },
        { "<leader>lk", "<cmd>lua vim.diagnostic.goto_prev()<cr>", desc = "Prev Diagnostic" },
        { "<leader>ll", "<cmd>lua vim.lsp.codelens.run()<cr>", desc = "CodeLens Action" },
        { "<leader>lq", "<cmd>lua vim.diagnostic.setloclist()<cr>", desc = "Quickfix" },
        { "<leader>lr", "<cmd>lua vim.lsp.buf.rename()<cr>", desc = "Rename" },
        { "<leader>ls", "<cmd>Telescope lsp_document_symbols<cr>", desc = "Document Symbols" },
        { "<leader>lS", "<cmd>Telescope lsp_dynamic_workspace_symbols<cr>", desc = "Workspace Symbols" },
        
        -- Search
        { "<leader>s", group = "Search" },
        { "<leader>sb", "<cmd>Telescope git_branches<cr>", desc = "Checkout branch" },
        { "<leader>sc", "<cmd>Telescope colorscheme<cr>", desc = "Colorscheme" },
        { "<leader>sh", "<cmd>Telescope help_tags<cr>", desc = "Find Help" },
        { "<leader>sM", "<cmd>Telescope man_pages<cr>", desc = "Man Pages" },
        { "<leader>sr", "<cmd>Telescope oldfiles<cr>", desc = "Open Recent File" },
        { "<leader>sR", "<cmd>Telescope registers<cr>", desc = "Registers" },
        { "<leader>st", "<cmd>Telescope live_grep<cr>", desc = "Text" },
        { "<leader>sk", "<cmd>Telescope keymaps<cr>", desc = "Keymaps" },
        { "<leader>sC", "<cmd>Telescope commands<cr>", desc = "Commands" },
        { "<leader>sp", function() require('telescope.builtin').colorscheme({enable_preview = true}) end, desc = "Colorscheme with Preview" },
        
        -- Terminal
        { "<leader>t", group = "Terminal" },
        { "<leader>tn", "<cmd>lua _NODE_TOGGLE()<cr>", desc = "Node" },
        { "<leader>tu", "<cmd>lua _NCDU_TOGGLE()<cr>", desc = "NCDU" },
        { "<leader>tt", "<cmd>lua _HTOP_TOGGLE()<cr>", desc = "Htop" },
        { "<leader>tp", "<cmd>lua _PYTHON_TOGGLE()<cr>", desc = "Python" },
        { "<leader>tf", "<cmd>ToggleTerm direction=float<cr>", desc = "Float" },
        { "<leader>th", "<cmd>ToggleTerm direction=horizontal<cr>", desc = "Horizontal" },
        { "<leader>tv", "<cmd>ToggleTerm direction=vertical<cr>", desc = "Vertical" },
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
