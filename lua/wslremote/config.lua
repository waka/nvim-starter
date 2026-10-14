local M = {}

M.defaults = {
  -- :WslOpen でディストロ名を省略したときに使うもの
  default_host = "Ubuntu",

  -- WSL 側で実行する nvim のパス。--exec で起動するのでログインシェルの PATH は効かない。
  -- ~/.local/bin などに入れている場合はフルパスで指定する。
  remote_nvim = "nvim",

  -- エージェント（headless nvim）を起動するコマンド
  cmd = function(host, remote_nvim)
    return { "wsl.exe", "-d", host, "--exec", remote_nvim, "--embed", "--headless", "--clean" }
  end,

  -- :WslTerm で起動するコマンド
  term_cmd = function(host, cwd)
    return { "wsl.exe", "-d", host, "--cd", cwd }
  end,

  -- Telescope の検索起点（プロジェクトルート）を決めるマーカー
  root_markers = { ".git" },

  -- nil なら WSL 側で fd / fdfind / rg / find から自動選択
  find_command = nil,

  grep_command = { "rg", "--vimgrep", "--smart-case", "--color=never", "--hidden", "--glob", "!.git" },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

function M.get()
  return M.options
end

return M
