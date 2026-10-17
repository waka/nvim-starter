local config = require("memo.config")
local store = require("memo.store")
local sidebar = require("memo.sidebar")
local git = require("memo.git")

local M = {}

local LABEL = { memo = "Memo", todo = "ToDo" }

local function open(path, cursor_to_end)
  sidebar.leave()
  vim.cmd.edit(vim.fn.fnameescape(path))
  if cursor_to_end then
    local last = vim.api.nvim_buf_line_count(0)
    local len = #vim.api.nvim_buf_get_lines(0, last - 1, last, false)[1]
    vim.api.nvim_win_set_cursor(0, { last, len })
  end
end

--- 新規作成（同名があれば開くだけ）
--- @param o table|nil { shared = true } で共有に作る
function M.new(kind, title, o)
  local path, created, existing = store.create(kind, title, o)
  if not path then
    vim.notify("memo: タイトルを入力してください", vim.log.levels.WARN)
    return
  end
  if not created and existing and existing ~= kind then
    vim.notify(("memo: 同名の %s があるので、それを開きます"):format(LABEL[existing]), vim.log.levels.WARN)
  end
  open(path, created)
  sidebar.refresh()
  return path
end

local function new_with_prompt(kind, title)
  if title and vim.trim(title) ~= "" then
    return M.new(kind, title)
  end
  vim.ui.input({ prompt = LABEL[kind] .. " タイトル: " }, function(input)
    if input and vim.trim(input) ~= "" then
      M.new(kind, input)
    end
  end)
end

--- 個人 ⇔ 共有 を移す
function M.move(path, to_shared)
  if to_shared and not git.shared:is_repo() then
    vim.notify("memo: 先に :MTSync init-shared <URL> で共有リポジトリを設定してください", vim.log.levels.WARN)
    return
  end
  local title = vim.fn.fnamemodify(path, ":t:r")
  local msg = to_shared and ("「%s」を共有に移動しますか？共有している全員から見えるようになります"):format(title)
    or ("「%s」を共有から外して個人のメモに戻しますか？ほかの人の手元からは消えます"):format(title)
  if not require("memo.util").confirm(msg) then
    return
  end
  local dest, err = store.move(path, to_shared)
  if not dest then
    vim.notify("memo: " .. err, vim.log.levels.ERROR)
    return
  end
  vim.notify(("memo: 「%s」を%sしました"):format(title, to_shared and "共有に移動" or "個人のメモに戻"))
  sidebar.refresh()
  return dest
end

--- 今のバッファのメモを共有に移す / 戻す
local function move_current()
  local path = store.normalize(vim.api.nvim_buf_get_name(0))
  if not store.is_memo_path(path) then
    vim.notify("memo: メモを開いてから実行してください", vim.log.levels.WARN)
    return
  end
  M.move(path, not store.is_shared_path(path))
end

--- 今日のメモを開く / 作る
function M.daily()
  return M.new("memo", os.date(config.options.daily_format))
end

function M.list(kind)
  sidebar.leave()
  require("memo.telescope").list(kind)
end

function M.lines(kind)
  sidebar.leave()
  require("memo.telescope").lines(kind)
end

M.toggle_sidebar = sidebar.toggle

local function command(kind, subs)
  return function(args)
    git.pull_once()
    local sub = args.fargs[1]
    if not sub then
      return M.list(kind)
    end
    local rest = table.concat(vim.list_slice(args.fargs, 2), " ")
    if sub == "n" then
      return new_with_prompt(kind, rest)
    elseif sub == "g" then
      return M.lines(kind)
    elseif sub == "d" and kind == "memo" then
      return M.daily()
    elseif sub == "l" then
      return require("memo.link").insert(false)
    elseif sub == "b" then
      return require("memo.link").backlinks()
    elseif sub == "s" then
      return move_current()
    end
    vim.notify(("memo: 使い方 :%s [%s] [タイトル]"):format(LABEL[kind] == "Memo" and "Memo" or "Todo", table.concat(subs, "|")), vim.log.levels.ERROR)
  end
end

local function complete(subs)
  return function(arglead, cmdline)
    if #vim.split(vim.trim(cmdline), "%s+") > (arglead == "" and 1 or 2) then
      return {}
    end
    return vim.tbl_filter(function(s)
      return vim.startswith(s, arglead)
    end, subs)
  end
end

function M.setup(opts)
  config.setup(opts)

  local memo_subs, todo_subs = { "n", "d", "g", "l", "b", "s" }, { "n", "g", "l", "b", "s" }
  vim.api.nvim_create_user_command("Memo", command("memo", memo_subs), {
    nargs = "*",
    complete = complete(memo_subs),
    desc = "メモ一覧 / n タイトル: 新規 / d: 今日のメモ / g: 本文検索 / l: リンク挿入 / b: バックリンク / s: 共有に移動・戻す",
  })
  vim.api.nvim_create_user_command("Todo", command("todo", todo_subs), {
    nargs = "*",
    complete = complete(todo_subs),
    desc = "ToDo 一覧 / n タイトル: 新規 / g: 未完了項目",
  })
  vim.api.nvim_create_user_command("MT", function()
    git.pull_once()
    sidebar.toggle()
  end, { desc = "メモ / ToDo 一覧ペインを開閉" })
  vim.api.nvim_create_user_command("MTClaude", function(args)
    require("memo.claude").command(args.args)
  end, { nargs = "*", desc = "管理フォルダで Claude Code を開閉 / 文章を付けるとそれを送る" })
  vim.api.nvim_create_user_command("MTSync", function(args)
    if args.fargs[1] == "init" then
      return git.init(args.fargs[2])
    elseif args.fargs[1] == "init-shared" then
      return git.init_shared(args.fargs[2])
    end
    git.sync(true)
  end, {
    nargs = "*",
    complete = function(_, cmdline)
      return #vim.split(vim.trim(cmdline), "%s+") <= 1 and { "init", "init-shared" } or {}
    end,
    desc = "メモを git リモートと同期 / init <URL>: 個人 / init-shared <URL>: 共有",
  })

  local group = vim.api.nvim_create_augroup("memo.nvim", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if store.is_memo_path(ev.match) then
        require("memo.checkbox").attach(ev.buf)
        require("memo.link").attach(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if not store.is_memo_path(ev.match) then
        return
      end
      if config.options.sync_filename then
        store.sync_filename(ev.buf)
      end
      sidebar.refresh()
      git.schedule(vim.api.nvim_buf_get_name(ev.buf))
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      git.on_focus()
    end,
  })
  git.start_poll()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      git.on_exit()
    end,
  })
end

return M
