-- :Claude タブのルートフォルダで Claude Code を開く
--
-- タブごとに 1 つのセッションを持つ。ルートは次の順で決める:
--   1. :WslOpen で開いたタブ（vim.t.wslremote_root）… WSL 側で claude を起動
--   2. それ以外 … タブのカレントディレクトリ（:tcd / :Project で設定したもの）
--
-- :Claude          開く / 隠す
-- :Claude {文章}   文章を送る（起動していなければ起動する）

local api = vim.api

local opts = {
  size = 0.4, -- 右に開くときの幅（画面に対する割合）
  hide_key = '<C-q>',
  -- WSL 側で起動するコマンド。--exec ではログインシェルの PATH が効かないので bash -lic 経由にする
  wsl_cmd = function(host, dir)
    return { 'wsl.exe', '-d', host, '--cd', dir, '--', 'bash', '-lic', 'exec claude' }
  end,
}

local sessions = {} -- tabpage handle -> { buf, job, win, root }

local function session()
  local s = sessions[api.nvim_get_current_tabpage()]
  if s and s.job and api.nvim_buf_is_valid(s.buf) then
    return s
  end
end

local function win_valid(s)
  return s.win ~= nil and api.nvim_win_is_valid(s.win) and api.nvim_win_get_tabpage(s.win) == api.nvim_get_current_tabpage()
end

--- 今のタブのルートと起動コマンドを返す
local function resolve()
  local troot = vim.t.wslremote_root
  if troot then
    local host, dir = require('wslremote.path').parse(troot)
    return troot, opts.wsl_cmd(host, dir), nil
  end
  local dir = vim.fn.getcwd(-1, 0)
  local cmd = { 'claude' }
  -- npm 版（claude.cmd）なら cmd.exe 経由で起動
  local exe = vim.fn.exepath 'claude'
  if exe:lower():match '%.cmd$' or exe:lower():match '%.bat$' then
    cmd = { 'cmd.exe', '/c', 'claude' }
  end
  return dir, cmd, dir
end

local function open_win(s)
  vim.cmd 'botright vsplit'
  s.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(s.win, s.buf)
  api.nvim_win_set_width(s.win, math.floor(vim.o.columns * opts.size))
  local wo = vim.wo[s.win][0]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.statuscolumn = ''
  wo.spell = false
  wo.winfixwidth = true
end

local function hide()
  local s = session()
  if not s or not win_valid(s) then
    return
  end
  -- 最後のウィンドウなら閉じられないので、空のバッファに切り替える
  if #api.nvim_tabpage_list_wins(0) == 1 then
    api.nvim_win_set_buf(s.win, api.nvim_create_buf(true, false))
  else
    api.nvim_win_close(s.win, false)
  end
  s.win = nil
end

local function start(prompt)
  local root, cmd, cwd = resolve()
  if not cwd and vim.fn.executable 'wsl.exe' ~= 1 then
    return vim.notify('wsl.exe が見つかりません', vim.log.levels.ERROR)
  end
  if cwd and vim.fn.executable(cmd[#cmd]) ~= 1 then
    return vim.notify('claude が見つかりません。Claude Code をインストールしてください', vim.log.levels.ERROR)
  end
  if prompt and prompt ~= '' then
    if cwd then
      table.insert(cmd, prompt)
    else
      -- bash -lic 'exec claude' の後ろに付けた引数は $1 以降として渡す
      cmd[#cmd] = 'exec claude "$@"'
      vim.list_extend(cmd, { 'claude', prompt })
    end
  end

  local tab = api.nvim_get_current_tabpage()
  local s = { buf = api.nvim_create_buf(false, false), root = root }
  vim.bo[s.buf].bufhidden = 'hide'
  sessions[tab] = s
  open_win(s)

  -- 会話を Neovim のターミナルの履歴に流す（スクロール・/ 検索・コピーが効く）。WSL にも WSLENV で渡す
  local wslenv = vim.env.WSLENV
  local job
  api.nvim_buf_call(s.buf, function()
    job = vim.fn.jobstart(cmd, {
      term = true,
      cwd = cwd,
      env = {
        CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN = '1',
        WSLENV = (wslenv and wslenv ~= '' and wslenv .. ':' or '') .. 'CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN',
      },
      on_exit = function()
        vim.schedule(function()
          s.job = nil
          if sessions[tab] == s then
            sessions[tab] = nil
          end
          if s.win and api.nvim_win_is_valid(s.win) then
            if #api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(s.win)) == 1 then
              api.nvim_win_set_buf(s.win, api.nvim_create_buf(true, false))
            else
              pcall(api.nvim_win_close, s.win, true)
            end
          end
          if api.nvim_buf_is_valid(s.buf) then
            pcall(api.nvim_buf_delete, s.buf, { force = true })
          end
        end)
      end,
    })
  end)
  if not job or job <= 0 then
    vim.notify('Claude Code を起動できませんでした', vim.log.levels.ERROR)
    hide()
    sessions[tab] = nil
    return
  end
  s.job = job
  pcall(function()
    vim.bo[s.buf].scrollback = 100000
  end)
  pcall(api.nvim_buf_set_name, s.buf, ('claude://%d/%s'):format(tab, root))

  -- kickstart の <Esc><Esc>（ターミナルモードを抜ける）に取られないよう、Esc はそのまま Claude に渡す
  vim.keymap.set('t', '<Esc>', '<Esc>', { buffer = s.buf, nowait = true, desc = 'Claude に Esc を送る' })
  vim.keymap.set({ 't', 'n' }, opts.hide_key, hide, { buffer = s.buf, desc = 'Claude を隠す' })
  vim.keymap.set('n', 'q', hide, { buffer = s.buf, nowait = true, desc = 'Claude を隠す' })
  vim.cmd 'startinsert'
end

local function show()
  local s = session()
  if not s then
    return start()
  end
  if win_valid(s) then
    api.nvim_set_current_win(s.win)
  else
    open_win(s)
  end
  vim.cmd 'startinsert'
end

local function send(text)
  local s = session()
  if not s then
    return start(text)
  end
  show()
  vim.fn.chansend(s.job, text)
  -- 貼り付けと区別されるよう、少し待ってから Enter を送る
  vim.defer_fn(function()
    if s.job then
      vim.fn.chansend(s.job, '\r')
    end
  end, 100)
end

api.nvim_create_user_command('Claude', function(o)
  if vim.trim(o.args) ~= '' then
    return send(o.args)
  end
  local s = session()
  if s and win_valid(s) then
    hide()
  else
    show()
  end
end, { nargs = '*', desc = 'タブのルートフォルダで Claude Code を開閉。文章を付けるとそれを送る' })

-- タブを閉じたら、そのタブのセッションも終了する
api.nvim_create_autocmd('TabClosed', {
  group = api.nvim_create_augroup('custom-claude', { clear = true }),
  callback = function()
    local alive = {}
    for _, t in ipairs(api.nvim_list_tabpages()) do
      alive[t] = true
    end
    for tab, s in pairs(sessions) do
      if not alive[tab] then
        sessions[tab] = nil
        if s.job then
          vim.fn.jobstop(s.job)
        end
      end
    end
  end,
})

return {}
