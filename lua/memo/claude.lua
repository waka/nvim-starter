-- :MTClaude 管理フォルダで Claude Code を開く
local config = require("memo.config")

local M = {}

local state = {
  buf = nil, -- ターミナルバッファ
  win = nil, -- 表示中のウィンドウ
  job = nil, -- ジョブ ID
  watcher = nil, -- フォルダ監視
  debounce = nil,
}

local function opts()
  return config.options.claude
end

local function running()
  return state.job ~= nil and state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

local function win_valid()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

---------------------------------------------------------------------------
-- Claude に渡すメモの書式ルール（起動のたびに生成）
---------------------------------------------------------------------------
function M.system_prompt()
  local o = config.options
  local example_daily = os.date(o.daily_format)
  return table.concat({
    "# メモ管理フォルダでの作業ルール",
    "",
    "あなたは Neovim のメモプラグイン memo.nvim の管理フォルダで動いています。",
    "ユーザーはメモや ToDo を書かせたり、メモの内容について質問したりします。",
    "",
    "## ファイルの形式",
    "- すべて Markdown（.md）で、このフォルダの直下に置く。サブフォルダは作らない",
    "- ファイル名はタイトルそのまま（例: `買い物.md`）。ただし / \\ : * ? \" < > | は _ に置き換える",
    "- 先頭に frontmatter を付ける。title はファイル名（拡張子なし）と同じにする",
    "",
    "メモ:",
    "```markdown",
    "---",
    'title: "会議メモ"',
    "type: memo",
    "created: " .. os.date(o.created_format),
    "---",
    "",
    "本文",
    "```",
    "",
    "ToDo（type: todo。項目はチェックボックスの箇条書き）:",
    "```markdown",
    "---",
    'title: "引っ越し"',
    "type: todo",
    "created: " .. os.date(o.created_format),
    "---",
    "",
    "- [ ] 電気の手続き",
    "- [x] ガスの手続き",
    "```",
    "",
    ("- デイリーメモはタイトルが日付のメモ（今日なら `%s.md`、type: memo）"):format(example_daily),
    "- created は作成日時。既存ファイルの title / type / created は、頼まれない限り変えない",
    "- ToDo を完了にするときは `- [ ]` を `- [x]` に変える。項目は消さない",
    "- 新しく作る前に、同じ名前のファイルがないか確認する。あれば追記する",
    "",
    "## メモ間のリンク",
    "- 他のメモへのリンクは `[[タイトル]]` と書く（見出しへは `[[タイトル#見出し]]`、表示名を変えるなら `[[タイトル|表示名]]`）",
    "- 関連するメモがあれば、積極的にリンクを張る",
    "",
    "## 質問に答えるとき",
    "- `[[タイトル]]` のリンクも辿って関連するメモを読む",
    "- このフォルダのメモを検索して読み、根拠にしたファイル名を添えて答える",
    "",
    "## してはいけないこと",
    "- git の操作（commit / push / pull など）。同期はエディタ側が自動で行う",
    "- .git フォルダの中を触ること",
    "",
    ("今日の日付: %s (%s)"):format(os.date("%Y-%m-%d"), ({ "日", "月", "火", "水", "木", "金", "土" })[tonumber(os.date("%w")) + 1]),
  }, "\n")
end

local function prompt_file()
  local path = vim.fn.stdpath("cache") .. "/memo-nvim-claude-prompt.md"
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(M.system_prompt(), "\n"), path)
  return path
end

---------------------------------------------------------------------------
-- 管理フォルダの監視（Claude が書き換えたら一覧・バッファ・同期に反映）
---------------------------------------------------------------------------
local function on_change()
  vim.cmd("silent! checktime")
  pcall(function()
    require("memo.sidebar").refresh()
  end)
  require("memo.git").schedule()
end

local function start_watch()
  if state.watcher then
    return
  end
  local w = vim.uv.new_fs_event()
  if not w then
    return
  end
  state.debounce = vim.uv.new_timer()
  local ok = w:start(config.options.dir, {}, function(err, filename)
    if err or not filename or not filename:match("%.md$") then
      return
    end
    state.debounce:stop()
    state.debounce:start(300, 0, vim.schedule_wrap(on_change))
  end)
  if ok then
    state.watcher = w
  else
    w:close()
  end
end

local function stop_watch()
  if state.watcher then
    state.watcher:stop()
    state.watcher:close()
    state.watcher = nil
  end
  if state.debounce then
    state.debounce:stop()
    state.debounce:close()
    state.debounce = nil
  end
end

---------------------------------------------------------------------------
-- ウィンドウ
---------------------------------------------------------------------------
local function open_win()
  local layout = opts().layout
  if layout == "float" then
    local w = math.floor(vim.o.columns * opts().float_size)
    local h = math.floor((vim.o.lines - 2) * opts().float_size)
    state.win = vim.api.nvim_open_win(state.buf, true, {
      relative = "editor",
      width = w,
      height = h,
      col = math.floor((vim.o.columns - w) / 2),
      row = math.floor((vim.o.lines - 2 - h) / 2),
      border = "rounded",
      title = " Claude ",
      title_pos = "center",
    })
  elseif layout == "bottom" then
    vim.cmd("botright split")
    state.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.win, state.buf)
    vim.api.nvim_win_set_height(state.win, math.floor(vim.o.lines * opts().size))
  else -- right
    vim.cmd("botright vsplit")
    state.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.win, state.buf)
    vim.api.nvim_win_set_width(state.win, math.floor(vim.o.columns * opts().size))
  end
  local wo = vim.wo[state.win][0]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.statuscolumn = ""
  wo.spell = false
  wo.winfixwidth = layout == "right"
  wo.winfixheight = layout == "bottom"
end

function M.hide()
  if win_valid() then
    -- 最後のウィンドウなら閉じられないので、空のバッファに切り替える
    if #vim.api.nvim_tabpage_list_wins(0) == 1 then
      vim.api.nvim_win_set_buf(state.win, vim.api.nvim_create_buf(true, false))
    else
      vim.api.nvim_win_close(state.win, false)
    end
  end
  state.win = nil
end

function M.show()
  if not running() then
    return M.start()
  end
  if not win_valid() then
    open_win()
  else
    vim.api.nvim_set_current_win(state.win)
  end
  vim.cmd("startinsert")
end

local function set_keymaps(buf)
  local keys = opts().keys
  -- kickstart などの <Esc><Esc>（ターミナルモードを抜ける）に Esc を取られないよう、
  -- Esc はそのまま Claude に渡す（Esc: 中断 / Esc Esc: 巻き戻し）
  if keys.pass_esc then
    vim.keymap.set("t", "<Esc>", "<Esc>", { buffer = buf, nowait = true, desc = "memo: Claude に Esc を送る" })
  end
  if keys.hide then
    vim.keymap.set({ "t", "n" }, keys.hide, M.hide, { buffer = buf, desc = "memo: Claude を隠す" })
  end
  vim.keymap.set("n", "q", M.hide, { buffer = buf, nowait = true, desc = "memo: Claude を隠す" })
end

---------------------------------------------------------------------------
-- 起動
---------------------------------------------------------------------------
local function build_cmd(prompt)
  local o = opts()
  local cmd = type(o.cmd) == "table" and vim.deepcopy(o.cmd) or { o.cmd }
  -- Windows で npm 版（claude.cmd）を使っている場合は cmd.exe 経由で起動
  if vim.fn.has("win32") == 1 then
    local exe = vim.fn.exepath(cmd[1])
    if exe:lower():match("%.cmd$") or exe:lower():match("%.bat$") then
      table.insert(cmd, 1, "/c")
      table.insert(cmd, 1, "cmd.exe")
    end
  end
  if o.continue then
    table.insert(cmd, "--continue")
  end
  vim.list_extend(cmd, { "--append-system-prompt-file", prompt_file() })
  vim.list_extend(cmd, o.args or {})
  if prompt and prompt ~= "" then
    table.insert(cmd, prompt)
  end
  return cmd
end

function M.start(prompt)
  local o = opts()
  local first = type(o.cmd) == "table" and o.cmd[1] or o.cmd
  if vim.fn.executable(first) ~= 1 then
    vim.notify(("memo: %s が見つかりません。Claude Code をインストールしてください"):format(first), vim.log.levels.ERROR)
    return
  end
  vim.fn.mkdir(config.options.dir, "p")
  require("memo.sidebar").leave()

  state.buf = vim.api.nvim_create_buf(false, false)
  vim.bo[state.buf].bufhidden = "hide"
  open_win()

  local cmd = build_cmd(prompt)
  local job_opts = {
    cwd = config.options.dir,
    on_exit = function()
      vim.schedule(function()
        local buf = state.buf
        state.job = nil
        stop_watch()
        M.hide()
        if buf and vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        state.buf = nil
        on_change()
      end)
    end,
  }
  -- クラシック表示: 会話を Neovim のターミナルの履歴に流す（ホイール・/ 検索・コピーが効く）。
  -- フルスクリーン表示は画面を丸ごと描き直すため履歴に残らず、Neovim 内ではスクロールできないことがある
  if o.renderer ~= "fullscreen" then
    job_opts.env = { CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN = "1" }
  end
  local job
  vim.api.nvim_buf_call(state.buf, function()
    if vim.fn.has("nvim-0.11") == 1 then
      job_opts.term = true
      job = vim.fn.jobstart(cmd, job_opts)
    else
      job = vim.fn.termopen(cmd, job_opts)
    end
  end)
  if not job or job <= 0 then
    vim.notify("memo: Claude Code を起動できませんでした", vim.log.levels.ERROR)
    M.hide()
    state.buf = nil
    return
  end
  state.job = job
  -- 遡れる行数（Neovim の上限は 100000）
  pcall(function()
    vim.bo[state.buf].scrollback = o.scrollback
  end)
  pcall(vim.api.nvim_buf_set_name, state.buf, "memo://claude")
  set_keymaps(state.buf)
  start_watch()
  vim.cmd("startinsert")
end

--- 起動中のセッションに文章を送る
function M.send(text)
  if not running() then
    return M.start(text)
  end
  M.show()
  vim.fn.chansend(state.job, text)
  -- 貼り付けと区別されるよう、少し待ってから Enter を送る
  vim.defer_fn(function()
    if state.job then
      vim.fn.chansend(state.job, "\r")
    end
  end, 100)
end

--- :MTClaude [文章]
function M.command(text)
  require("memo.git").pull_once()
  if text and vim.trim(text) ~= "" then
    return M.send(text)
  end
  if running() and win_valid() then
    M.hide()
  else
    M.show()
  end
end

function M.stop()
  if state.job then
    vim.fn.jobstop(state.job)
  end
end

-- テスト用
function M._state()
  return state
end

return M
