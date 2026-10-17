-- メモ間リンク [[タイトル]] / [[タイトル#見出し]] / [[タイトル|表示名]]
local config = require("memo.config")
local store = require("memo.store")

local M = {}

local ns = vim.api.nvim_create_namespace("memo_link")
vim.api.nvim_set_hl(0, "MemoLink", { link = "Underlined", default = true })

local function opts()
  return config.options.link
end

--- "タイトル#見出し|表示名" → タイトル, 見出し
function M.parse(inner)
  local target = inner:match("^([^|]*)") or inner
  local title, heading = target:match("^(.-)#(.*)$")
  if not title then
    title = target
  end
  title = vim.trim(title)
  heading = heading and vim.trim(heading) or nil
  if heading == "" then
    heading = nil
  end
  return title, heading
end

--- 行の中のリンクをすべて返す { s, e, kind, value }（s, e は 1 始まりのバイト位置）
function M.find_all(line)
  local res = {}
  local init = 1
  while true do
    local s, e, inner = line:find("%[%[(.-)%]%]", init)
    if not s then
      break
    end
    table.insert(res, { s = s, e = e, kind = "wiki", value = inner })
    init = e + 1
  end
  init = 1
  while true do
    local s, e, target = line:find("%[[^%]]-%]%(([^)%s]+)%)", init)
    if not s then
      break
    end
    table.insert(res, { s = s, e = e, kind = "md", value = target })
    init = e + 1
  end
  init = 1
  while true do
    local s, e, url = line:find("(https?://[^%s%)%]>\"']+)", init)
    if not s then
      break
    end
    table.insert(res, { s = s, e = e, kind = "url", value = url })
    init = e + 1
  end
  return res
end

function M.at_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
  col = col + 1
  -- 重なっていたら一番内側（短い）ものを選ぶ
  local best
  for _, l in ipairs(M.find_all(line)) do
    if col >= l.s and col <= l.e and (not best or (l.e - l.s) < (best.e - best.s)) then
      best = l
    end
  end
  return best
end

local function jump_heading(heading)
  if not heading then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i, l in ipairs(lines) do
    local h = l:match("^#+%s+(.-)%s*$")
    if h and h == heading then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      vim.cmd("normal! zz")
      return
    end
  end
  vim.notify(("memo: 見出し「%s」が見つかりません"):format(heading), vim.log.levels.WARN)
end

--- タイトルのメモを開く（なければ作る）
function M.open_title(title, heading)
  local from_shared = store.is_shared_path(vim.api.nvim_buf_get_name(0))
  -- 今いる側（個人 / 共有）を先に探し、なければもう一方
  local candidates = { store.path_for(title) }
  if store.shared_enabled() then
    local sp = store.path_for(title, store.shared_dir())
    if from_shared then
      table.insert(candidates, 1, sp)
    else
      table.insert(candidates, sp)
    end
  end
  local path
  for _, p in ipairs(candidates) do
    if store.exists(p) then
      path = p
      break
    end
  end
  if path then
    vim.cmd.edit(vim.fn.fnameescape(path))
  elseif opts().create_missing then
    -- 共有メモからのリンクなら共有に作る（ほかの人も開けるように）
    require("memo").new("memo", title, { shared = from_shared })
  else
    vim.notify(("memo: 「%s」はまだありません"):format(title), vim.log.levels.WARN)
    return
  end
  jump_heading(heading)
end

--- カーソル位置のリンクを辿る。リンクがなければ false
function M.follow()
  local l = M.at_cursor()
  if not l then
    return false
  end
  if l.kind == "url" then
    vim.ui.open(l.value)
  elseif l.kind == "md" then
    local target = l.value
    if target:match("^https?://") then
      vim.ui.open(target)
      return true
    end
    local file, heading = target:match("^(.-)#(.*)$")
    file = file or target
    file = file:gsub("%%(%x%x)", function(h)
      return string.char(tonumber(h, 16))
    end)
    if file == "" then
      jump_heading(heading)
      return true
    end
    local path = file:match("^[/~]") and file or (store.dir() .. "/" .. file)
    vim.cmd.edit(vim.fn.fnameescape(vim.fn.expand(path)))
    jump_heading(heading)
  else
    local title, heading = M.parse(l.value)
    if title == "" then
      jump_heading(heading)
    else
      M.open_title(title, heading)
    end
  end
  return true
end

---------------------------------------------------------------------------
-- 挿入
---------------------------------------------------------------------------

--- カーソル位置に [[title]] を入れて挿入モードに戻る
local function insert_at(win, buf, row, col, text, insert_mode)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  vim.api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { text })
  local newcol = col + #text
  local len = #(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or "")
  if insert_mode then
    vim.api.nvim_win_set_cursor(0, { row, newcol })
    if newcol >= len then
      vim.cmd("startinsert!")
    else
      vim.cmd("startinsert")
    end
  else
    vim.api.nvim_win_set_cursor(0, { row, math.max(newcol - 1, 0) })
  end
end

--- リンク先を選んで挿入する
--- @param insert_mode boolean 挿入モードから呼ばれたか
function M.insert(insert_mode)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  if not insert_mode then
    -- ノーマルモードではカーソルの後ろに入れる
    local len = #(vim.api.nvim_get_current_line())
    col = math.min(col + 1, len)
  end
  local self = store.normalize(vim.api.nvim_buf_get_name(buf))
  require("memo.telescope").pick_title({
    exclude = self,
    on_select = function(title)
      vim.schedule(function()
        insert_at(win, buf, row, col, "[[" .. title .. "]]", insert_mode)
      end)
    end,
    on_cancel = function()
      vim.schedule(function()
        if insert_mode then
          -- 何も選ばなければ打った [[ をそのまま入れる
          insert_at(win, buf, row, col, "[[", true)
        end
      end)
    end,
  })
end

---------------------------------------------------------------------------
-- バックリンク
---------------------------------------------------------------------------

function M.current_title(buf)
  buf = buf or 0
  local meta = store.parse_frontmatter(vim.api.nvim_buf_get_lines(buf, 0, 40, false))
  return meta.title or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t:r")
end

local function links_to(line, title)
  for _, l in ipairs(M.find_all(line)) do
    if l.kind == "wiki" and M.parse(l.value) == title then
      return true
    end
  end
  return false
end

--- title にリンクしている行 { path, title, lnum, text }
function M.collect_backlinks(title)
  local rows = {}
  local all = store.list_all(true)
  for _, kind in ipairs({ "memo", "todo" }) do
    for _, item in ipairs(all[kind]) do
      if item.title ~= title then
        for lnum = item.body_start, #item.lines do
          local line = item.lines[lnum]
          if links_to(line, title) then
            table.insert(rows, { path = item.path, title = item.title, lnum = lnum, text = vim.trim(line) })
          end
        end
      end
    end
  end
  return rows
end

function M.backlinks()
  local path = store.normalize(vim.api.nvim_buf_get_name(0))
  if not store.is_memo_path(path) then
    vim.notify("memo: メモを開いてから実行してください", vim.log.levels.WARN)
    return
  end
  local title = M.current_title(0)
  local rows = M.collect_backlinks(title)
  if #rows == 0 then
    vim.notify(("memo: 「%s」へのリンクはありません"):format(title))
    return
  end
  require("memo.telescope").locations(("「%s」へのリンク"):format(title), rows)
end

---------------------------------------------------------------------------
-- リネーム時: 他のメモの [[旧タイトル]] を書き換える
---------------------------------------------------------------------------
local function replace_in_line(line, old, new)
  local changed = false
  local out = line:gsub("%[%[(.-)%]%]", function(inner)
    local target = inner:match("^([^|]*)")
    local rest = inner:sub(#target + 1)
    local title, heading = target:match("^(.-)#(.*)$")
    if not title then
      title = target
    end
    if vim.trim(title) ~= old then
      return nil
    end
    changed = true
    return "[[" .. new .. (heading and ("#" .. heading) or "") .. rest .. "]]"
  end)
  return out, changed
end

--- @return number 書き換えたファイル数
function M.rename_links(old, new, skip_path)
  if not opts().update_on_rename or old == new then
    return 0
  end
  local count = 0
  local skipped = {}
  for _, kind in ipairs({ "memo", "todo" }) do
    for _, item in ipairs(store.list(kind, true)) do
      if item.path ~= skip_path then
        local buf = store.find_buf(item.path)
        local loaded = buf and vim.api.nvim_buf_is_loaded(buf)
        local lines = loaded and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or item.lines
        local any = false
        for i, l in ipairs(lines) do
          local out, changed = replace_in_line(l, old, new)
          if changed then
            lines[i] = out
            any = true
          end
        end
        if any then
          if loaded then
            local was_modified = vim.bo[buf].modified
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            if not was_modified then
              vim.api.nvim_buf_call(buf, function()
                vim.cmd("silent noautocmd write")
              end)
            else
              table.insert(skipped, item.title)
            end
          else
            vim.fn.writefile(lines, item.path)
          end
          count = count + 1
        end
      end
    end
  end
  if count > 0 then
    local msg = ("memo: %d 件のメモのリンクを「%s」に書き換えました"):format(count, new)
    if #skipped > 0 then
      msg = msg .. ("（未保存の %s は保存してください）"):format(table.concat(skipped, ", "))
    end
    vim.notify(msg)
    require("memo.git").schedule()
  end
  return count
end

---------------------------------------------------------------------------
-- ハイライトとキー
---------------------------------------------------------------------------
function M.highlight(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for _, l in ipairs(M.find_all(line)) do
      if l.kind == "wiki" then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, l.s - 1, { end_col = l.e, hl_group = "MemoLink" })
      end
    end
  end
end

function M.attach(buf)
  local o = opts()
  if o.follow_key then
    vim.keymap.set("n", o.follow_key, function()
      if not M.follow() then
        -- リンクの上でなければ本来のキーの動作
        vim.api.nvim_feedkeys(vim.keycode(o.follow_key), "n", false)
      end
    end, { buffer = buf, desc = "memo: リンクを開く" })
  end
  if o.insert_key then
    vim.keymap.set("i", o.insert_key, function()
      M.insert(true)
    end, { buffer = buf, desc = "memo: リンクを挿入" })
  end
  M.highlight(buf)
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave", "BufWinEnter" }, {
    buffer = buf,
    group = vim.api.nvim_create_augroup("memo.link." .. buf, { clear = true }),
    callback = function()
      M.highlight(buf)
    end,
  })
end

return M
