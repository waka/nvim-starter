# wslremote（kickstart.nvim 用・平置き版）

Windows の Neovim から WSL2 のファイルを、操作感はローカルのまま編集するためのモジュールです。
ファイル操作と fd / rg による検索は、WSL 側の headless Neovim（エージェント）で実行します。

## 置き方

```
%LOCALAPPDATA%\nvim\lua\custom\wslremote\
  agent.lua  buffer.lua  config.lua  init.lua  path.lua  rpc.lua  telescope.lua
```

フォルダ名や置き場所は自由です（中のモジュールは相対的に読み込みます）。
`lua/custom/wslremote/` に置いたら `require("custom.wslremote")`、`lua/wslremote/` なら `require("wslremote")` で読み込みます。

## 設定（kickstart の init.lua の末尾に追記）

```lua
local wsl = require("custom.wslremote")
wsl.setup({
  default_host = "Ubuntu", -- `wsl -l` のディストロ名
  remote_nvim = "nvim",    -- WSL 側で見つからなければフルパス（例: /home/you/.local/bin/nvim）
})
vim.keymap.set("n", "<leader>wf", wsl.find_files, { desc = "[W]SL [F]iles" })
vim.keymap.set("n", "<leader>wg", wsl.live_grep, { desc = "[W]SL [G]rep" })
vim.keymap.set("n", "<leader>ww", wsl.grep_string, { desc = "[W]SL current [W]ord" })
vim.keymap.set("n", "<leader>wt", "<cmd>tab WslTerm<cr>", { desc = "[W]SL [T]erminal" })
```

## コマンド

| コマンド | 内容 |
|---|---|
| `:WslOpen Ubuntu:~/project` | ディレクトリを開き、タブのルートに設定（ディストロ省略可） |
| `:e wsl://Ubuntu/etc/hosts` | 直接開く |
| `:WslFiles` / `:WslGrep` | Telescope でファイル検索 / live grep |
| `:WslTerm` | 今の WSL ディレクトリでシェル（`:tab WslTerm` など可） |
| `:WslInfo` / `:WslDisconnect` | 接続状況 / 切断 |

ディレクトリバッファでは `<CR>` で開く、`-` で親へ、`R` で再読み込みです。

## 事前チェック（PowerShell）

```powershell
wsl -d Ubuntu --exec nvim --version
```

WSL 側に `rg` が必要です。`fd`（`fdfind`）があればファイル一覧が速くなります。
