-- ファイルの読み書き・frontmatter・一覧
local config = require("memo.config")

local M = {}

-- "- [ ] foo" / "* [x] foo" など。1: 先頭部分, 2: チェック記号
M.TASK_PAT = "^(%s*[-*+]%s+)%[([ xX])%]"

function M.dir()
  return config.options.dir
end

function M.ensure_dir()
  vim.fn.mkdir(M.dir(), "p")
end

-- タイトル → ファイル名（パスに使えない文字だけ置き換える）
function M.sanitize(title)
  local s = vim.trim(title):gsub('[/\\:%*%?"<>|%c]', "_")
  return s
end

--- 共有フォルダ（管理フォルダの中の shared/）
function M.shared_enabled()
  return config.options.shared and config.options.shared.enabled
end

function M.shared_dir()
  return M.dir() .. "/" .. config.options.shared.dir
end

--- @param dir string|nil 省略時は個人の管理フォルダ
function M.path_for(title, dir)
  return (dir or M.dir()) .. "/" .. M.sanitize(title) .. ".md"
end

function M.normalize(path)
  if not path or path == "" then
    return path
  end
  return vim.fn.resolve(vim.fs.normalize(vim.fn.fnamemodify(path, ":p")))
end

function M.is_memo_path(path)
  if not path or path == "" or not path:match("%.md$") then
    return false
  end
  local d = vim.fs.dirname(M.normalize(path))
  return d == M.dir() or (M.shared_enabled() and d == M.shared_dir())
end

function M.is_shared_path(path)
  if not path or path == "" or not M.shared_enabled() then
    return false
  end
  return vim.fs.dirname(M.normalize(path)) == M.shared_dir()
end

function M.exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function quote(s)
  local q = s:gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. q .. '"'
end

local function unquote(v)
  if v:match('^".*"$') then
    local s = v:sub(2, -2):gsub("\\(.)", "%1")
    return s
  elseif v:match("^'.*'$") then
    local s = v:sub(2, -2):gsub("''", "'")
    return s
  end
  return v
end

-- @return meta table, body_start (本文の最初の行番号)
function M.parse_frontmatter(lines)
  local first = lines[1] and lines[1]:gsub("\r$", "")
  if first ~= "---" then
    return {}, 1
  end
  local meta = {}
  for i = 2, #lines do
    local line = lines[i]:gsub("\r$", "")
    if line == "---" or line == "..." then
      return meta, i + 1
    end
    local key, val = line:match("^([%w_-]+)%s*:%s*(.-)%s*$")
    if key then
      meta[key] = unquote(val)
    end
  end
  return {}, 1
end

function M.read_lines(path)
  -- io.open は Windows で UTF-8（日本語）のパスを開けないので readfile を使う
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  return lines
end

function M.count_tasks(lines, from)
  local done, total = 0, 0
  for i = from or 1, #lines do
    local pre, mark = lines[i]:match(M.TASK_PAT)
    -- 中身が空の "- [ ] " は数えない（新規作成直後のテンプレート）
    if mark and lines[i]:sub(#pre + 4):match("%S") then
      total = total + 1
      if mark ~= " " then
        done = done + 1
      end
    end
  end
  return done, total
end

-- @param keep_lines boolean 行データも返すか
function M.read(path, keep_lines)
  local lines = M.read_lines(path)
  if not lines then
    return nil
  end
  local meta, body_start = M.parse_frontmatter(lines)
  local stat = vim.uv.fs_stat(path)
  local item = {
    path = path,
    title = meta.title or vim.fn.fnamemodify(path, ":t:r"),
    type = meta.type == "todo" and "todo" or "memo",
    created = meta.created,
    mtime = stat and stat.mtime.sec or 0,
    body_start = body_start,
  }
  item.done, item.total = M.count_tasks(lines, body_start)
  if keep_lines then
    item.lines = lines
  end
  return item
end

local function is_complete(item)
  return item.total > 0 and item.done == item.total
end

local function sort(kind, items)
  table.sort(items, function(a, b)
    if kind == "todo" then
      local ca, cb = is_complete(a), is_complete(b)
      if ca ~= cb then
        return not ca -- 未完了が先
      end
    end
    if a.mtime ~= b.mtime then
      return a.mtime > b.mtime
    end
    return a.title < b.title
  end)
  return items
end

M.is_complete = is_complete

-- 個人と共有の両方を返す。共有のものは item.shared = true
-- @return { memo = {...}, todo = {...} }
function M.list_all(keep_lines)
  local res = { memo = {}, todo = {} }
  local ignore = {}
  for _, n in ipairs(config.options.ignore or {}) do
    ignore[n] = true
  end
  local dirs = { { M.dir(), false } }
  if M.shared_enabled() then
    table.insert(dirs, { M.shared_dir(), true })
  end
  for _, d in ipairs(dirs) do
    local dir, shared = d[1], d[2]
    if M.exists(dir) then
      for name, t in vim.fs.dir(dir) do
        if (t == "file" or t == "link") and name:match("%.md$") and not ignore[name] then
          local item = M.read(dir .. "/" .. name, keep_lines)
          if item then
            item.shared = shared
            table.insert(res[item.type], item)
          end
        end
      end
    end
  end
  sort("memo", res.memo)
  sort("todo", res.todo)
  return res
end

-- daily_format（例 "%Y-%m-%d"）をパターンに変換してキャッシュ
local daily_cache = {}
local function daily_matcher()
  local fmt = config.options.daily_format
  if daily_cache.fmt ~= fmt then
    local order, pat = {}, "^"
    local i = 1
    while i <= #fmt do
      local c = fmt:sub(i, i)
      if c == "%" and i < #fmt then
        local d = fmt:sub(i + 1, i + 1)
        if d == "Y" then
          pat = pat .. "(%d%d%d%d)"
          table.insert(order, "year")
        elseif d == "m" or d == "d" or d == "H" or d == "M" or d == "S" then
          pat = pat .. "(%d%d)"
          table.insert(order, ({ m = "month", d = "day", H = "hour", M = "min", S = "sec" })[d])
        elseif d == "y" then
          pat = pat .. "(%d%d)"
          table.insert(order, "year2")
        else
          pat = pat .. ".-" -- %a %b など名前系は何でも許す
        end
        i = i + 2
      else
        pat = pat .. vim.pesc(c)
        i = i + 1
      end
    end
    daily_cache = { fmt = fmt, pat = pat .. "$", order = order }
  end
  return daily_cache
end

-- タイトルがデイリーメモ形式なら、その日の 0 時の時刻（os.time）を返す
function M.daily_time(title)
  local m = daily_matcher()
  local caps = { title:match(m.pat) }
  if #caps == 0 or #caps ~= #m.order then
    return nil
  end
  local t = { year = 1970, month = 1, day = 1, hour = 0 }
  for i, key in ipairs(m.order) do
    local n = tonumber(caps[i])
    if key == "year2" then
      t.year = 2000 + n
    elseif key ~= "hour" and key ~= "min" and key ~= "sec" then
      t[key] = n
    end
  end
  if t.month < 1 or t.month > 12 or t.day < 1 or t.day > 31 then
    return nil
  end
  return os.time(t)
end

-- メモをデイリー / それ以外に分ける。デイリーは日付の新しい順
function M.split_daily(memos)
  local daily, others = {}, {}
  for _, item in ipairs(memos) do
    local t = M.daily_time(item.title)
    if t then
      item.date = t
      table.insert(daily, item)
    else
      table.insert(others, item)
    end
  end
  table.sort(daily, function(a, b)
    return a.date > b.date
  end)
  return daily, others
end

function M.list(kind, keep_lines)
  return M.list_all(keep_lines)[kind]
end

-- 新規作成。既にあれば作らない
-- @return path, created(boolean), existing_type
-- @param o table|nil { shared = true } で共有フォルダに作る
function M.create(kind, title, o)
  title = vim.trim(title or "")
  if title == "" then
    return nil, false
  end
  local dir = (o and o.shared) and M.shared_dir() or M.dir()
  vim.fn.mkdir(dir, "p")
  local path = M.path_for(title, dir)
  if M.exists(path) then
    local item = M.read(path)
    return path, false, item and item.type
  end
  local lines = {
    "---",
    "title: " .. quote(title),
    "type: " .. kind,
    "created: " .. os.date(config.options.created_format),
    "---",
    "",
    kind == "todo" and "- [ ] " or "",
  }
  vim.fn.writefile(lines, path)
  require("memo.git").schedule(path)
  return path, true
end

local function find_buf(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and M.normalize(vim.api.nvim_buf_get_name(b)) == path then
      return b
    end
  end
end
M.find_buf = find_buf

function M.delete(path)
  path = M.normalize(path)
  local buf = find_buf(path)
  if buf then
    -- 表示中のウィンドウは閉じずに別バッファへ切り替える
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.api.nvim_win_call(win, function()
        local alt = vim.fn.bufnr("#")
        if alt > 0 and alt ~= buf and vim.fn.buflisted(alt) == 1 then
          vim.api.nvim_win_set_buf(win, alt)
        else
          vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
        end
      end)
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  -- os.remove も Windows では日本語のパスを扱えない
  local ok = vim.uv.fs_unlink(path)
  require("memo.git").schedule(path)
  return ok
end

--- 個人 ⇔ 共有 のあいだでファイルを移す
--- @return string|nil 新しいパス, string|nil エラー
function M.move(path, to_shared)
  path = M.normalize(path)
  local dir = to_shared and M.shared_dir() or M.dir()
  local dest = dir .. "/" .. vim.fn.fnamemodify(path, ":t")
  if dest == path then
    return nil, "すでに移動先にあります"
  end
  if M.exists(dest) then
    return nil, ("移動先に同じ名前の %s があります"):format(vim.fn.fnamemodify(dest, ":t"))
  end
  vim.fn.mkdir(dir, "p")
  local buf = find_buf(path)
  if buf and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent noautocmd write")
    end)
  end
  local ok, err = vim.uv.fs_rename(path, dest)
  if not ok then
    -- 別ドライブなどで rename できなければコピーして消す
    if vim.fn.writefile(vim.fn.readfile(path), dest) ~= 0 then
      return nil, tostring(err)
    end
    vim.uv.fs_unlink(path)
  end
  if buf then
    vim.api.nvim_buf_set_name(buf, dest)
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent! noautocmd write!")
    end)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= buf and M.normalize(vim.api.nvim_buf_get_name(b)) == path then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end
  local git = require("memo.git")
  git.schedule(path)
  git.schedule(dest)
  return dest
end

-- 保存時: frontmatter の title とファイル名を揃える
function M.sync_filename(buf)
  local old = M.normalize(vim.api.nvim_buf_get_name(buf))
  if not M.is_memo_path(old) then
    return
  end
  local meta = M.parse_frontmatter(vim.api.nvim_buf_get_lines(buf, 0, 40, false))
  if not meta.title or vim.trim(meta.title) == "" then
    return
  end
  local new = M.path_for(meta.title, vim.fs.dirname(old))
  if new == old then
    return
  end
  if M.exists(new) then
    vim.notify(("memo: %s は既にあるのでファイル名を変更しませんでした"):format(vim.fn.fnamemodify(new, ":t")), vim.log.levels.WARN)
    return
  end
  local ok, err = vim.uv.fs_rename(old, new)
  if not ok then
    vim.notify("memo: リネームに失敗: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.api.nvim_buf_set_name(buf, new)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent! noautocmd write!")
  end)
  -- set_name で残る旧名のバッファを掃除
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= buf and M.normalize(vim.api.nvim_buf_get_name(b)) == old then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  vim.notify(("memo: %s → %s"):format(vim.fn.fnamemodify(old, ":t"), vim.fn.fnamemodify(new, ":t")))
  -- 他のメモの [[旧タイトル]] を書き換える
  require("memo.link").rename_links(vim.fn.fnamemodify(old, ":t:r"), vim.trim(meta.title), new)
end

return M
