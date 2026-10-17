-- :MT 左側のメモ / デイリー / ToDo 一覧ペイン
local config = require("memo.config")
local store = require("memo.store")

local M = {}

local ns = vim.api.nvim_create_namespace("memo_sidebar")
local LABEL = { memo = "Memo", daily = "Daily", todo = "ToDo", shared = "共有" }
local WEEKDAY = { "日", "月", "火", "水", "木", "金", "土" }

-- section -> buf, buf -> { [lnum] = item }
local bufs = {}
local line_items = {}
-- Memo の段の中の Daily フォルダを開いているか（nil = 設定の初期値）
local daily_expanded = nil
local FOLDER = { folder = "daily" }

local function sections()
  local res = {}
  LABEL.shared = config.options.shared.label
  for _, s in ipairs(config.options.sidebar.sections) do
    if LABEL[s] and (s ~= "shared" or store.shared_enabled()) then
      table.insert(res, s)
    end
  end
  return res
end

local function valid(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function section_of(buf)
  for s, b in pairs(bufs) do
    if b == buf then
      return s
    end
  end
end

function M.is_sidebar_win(win)
  return section_of(vim.api.nvim_win_get_buf(win or 0)) ~= nil
end

-- 現在のタブで一覧を表示しているウィンドウ（上から順）
local function sidebar_wins()
  local res = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if M.is_sidebar_win(w) then
      table.insert(res, w)
    end
  end
  table.sort(res, function(a, b)
    return vim.api.nvim_win_get_position(a)[1] < vim.api.nvim_win_get_position(b)[1]
  end)
  return res
end

local function is_normal_win(w)
  return vim.api.nvim_win_get_config(w).relative == "" and not M.is_sidebar_win(w)
end

-- ファイルを開く先のウィンドウ（なければ右側に作る）
function M.main_win()
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if prev ~= 0 and is_normal_win(prev) and vim.bo[vim.api.nvim_win_get_buf(prev)].buftype == "" then
    return prev
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_normal_win(w) and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "" then
      return w
    end
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_normal_win(w) then
      return w
    end
  end
  vim.cmd("botright vnew")
  local w = vim.api.nvim_get_current_win()
  for _, sw in ipairs(sidebar_wins()) do
    vim.api.nvim_win_set_width(sw, config.options.sidebar.width)
  end
  return w
end

-- サイドバーにいたら本体ウィンドウへ移る
function M.leave()
  if M.is_sidebar_win(0) then
    vim.api.nvim_set_current_win(M.main_win())
  end
end

local function current_item()
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return line_items[buf] and line_items[buf][lnum]
end

local function open_item()
  local item = current_item()
  if not item then
    return
  end
  if item.folder then
    M.toggle_daily()
    return
  end
  vim.api.nvim_set_current_win(M.main_win())
  vim.cmd.edit(vim.fn.fnameescape(item.path))
end

local function delete_item()
  local item = current_item()
  if not item or item.folder then
    return
  end
  local msg = item.shared and ("「%s」を削除しますか？共有している全員の手元から消えます"):format(item.title)
    or ("「%s」を削除しますか？"):format(item.title)
  if require("memo.util").confirm(msg) then
    store.delete(item.path)
    M.refresh()
  end
end

local function new_item()
  local section = section_of(vim.api.nvim_get_current_buf())
  local item = current_item()
  if section == "daily" or (item and (item.folder or item.date)) then
    -- デイリーの段 / Daily フォルダの上では今日のメモを開く / 作る
    require("memo").daily()
    return
  end
  if section == "shared" then
    return M.new_shared("memo")
  end
  vim.ui.input({ prompt = LABEL[section] .. " タイトル: " }, function(title)
    if title and vim.trim(title) ~= "" then
      require("memo").new(section, title)
    end
  end)
end

function M.new_shared(kind)
  local label = kind == "todo" and "共有 ToDo" or "共有メモ"
  vim.ui.input({ prompt = label .. " タイトル: " }, function(title)
    if title and vim.trim(title) ~= "" then
      require("memo").new(kind, title, { shared = true })
    end
  end)
end

-- 個人 ⇔ 共有 を移す
local function move_item()
  local item = current_item()
  if not item or item.folder then
    return
  end
  require("memo").move(item.path, not item.shared)
end

-- 次の段へ（一番下なら一番上へ）
local function jump_next()
  local wins = sidebar_wins()
  local cur = vim.api.nvim_get_current_win()
  for i, w in ipairs(wins) do
    if w == cur then
      vim.api.nvim_set_current_win(wins[i % #wins + 1])
      return
    end
  end
end

local function get_buf(section)
  if valid(bufs[section]) then
    return bufs[section]
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "memo://" .. section)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "memo-sidebar"
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "memo: " .. desc })
  end
  map("<CR>", open_item, "開く")
  map("o", open_item, "開く")
  map("d", delete_item, "削除")
  map("n", new_item, section == "daily" and "今日のメモ" or "新規作成")
  if section == "shared" then
    map("t", function()
      M.new_shared("todo")
    end, "共有 ToDo を作る")
    map("s", move_item, "個人に戻す")
  else
    map("s", move_item, "共有に移動")
  end
  map("R", M.refresh, "再読み込み")
  map("<Tab>", jump_next, "次の段へ")
  map("q", M.close, "閉じる")
  bufs[section] = buf
  return buf
end

local function daily_label(item)
  local wd = WEEKDAY[tonumber(os.date("%w", item.date)) + 1]
  return ("%s (%s)"):format(item.title, wd)
end

-- @param daily table|nil Memo の段の中にフォルダとして出すデイリーメモ
local function render(section, items, daily)
  local buf = bufs[section]
  if not valid(buf) then
    return
  end
  local lines = { (" %s (%d)"):format(LABEL[section], #items) }
  local map = {}
  local hls = { { 0, 0, -1, "Title" } }
  local today = os.date(config.options.daily_format)

  if daily then
    local icons = config.options.sidebar.icons
    local folder = ("  %s Daily (%d)"):format(daily_expanded and icons.open or icons.closed, #daily)
    table.insert(hls, { #lines, 0, -1, "Directory" })
    table.insert(lines, folder)
    map[#lines] = FOLDER
    if daily_expanded then
      for _, item in ipairs(daily) do
        if item.title == today then
          table.insert(hls, { #lines, 0, -1, "Special" })
        end
        table.insert(lines, "    " .. daily_label(item))
        map[#lines] = item
      end
    end
  end
  for _, item in ipairs(items) do
    local row = #lines
    local text
    if section == "daily" then
      text = "  " .. daily_label(item)
      if item.title == today then
        table.insert(hls, { row, 0, -1, "Special" })
      end
    else
      text = "  " .. item.title
    end
    if item.type == "todo" then
      local prog = (" %d/%d"):format(item.done, item.total)
      if store.is_complete(item) then
        table.insert(hls, { row, 0, -1, "Comment" })
      else
        table.insert(hls, { row, #text, #text + #prog, "Comment" })
      end
      text = text .. prog
    end
    table.insert(lines, text)
    map[#lines] = item
  end
  if #items == 0 and not daily then
    if section == "shared" and not require("memo.git").shared:is_repo() then
      table.insert(lines, "  :MTSync init-shared <URL>")
      table.insert(lines, "  で共有リポジトリを設定")
      table.insert(hls, { 2, 0, -1, "Comment" })
    else
      table.insert(lines, section == "daily" and "  (なし)  n で今日のメモ" or "  (なし)  n で作成")
    end
    table.insert(hls, { 1, 0, -1, "Comment" })
  end

  -- カーソル位置を保持
  local cursors = {}
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    cursors[w] = vim.api.nvim_win_get_cursor(w)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local row, s, e, group = h[1], h[2], h[3], h[4]
    vim.api.nvim_buf_set_extmark(buf, ns, row, s, {
      end_row = e == -1 and row + 1 or row,
      end_col = e == -1 and 0 or e,
      hl_group = group,
      hl_eol = e == -1,
    })
  end
  line_items[buf] = map

  for w, c in pairs(cursors) do
    local row = math.min(math.max(c[1], 2), #lines)
    pcall(vim.api.nvim_win_set_cursor, w, { row, 0 })
  end
end

function M.refresh()
  local any = false
  for _, b in pairs(bufs) do
    any = any or valid(b)
  end
  if not any then
    return
  end
  local all = store.list_all()
  local function personal(list)
    return vim.tbl_filter(function(i)
      return not i.shared
    end, list)
  end
  local shared = vim.tbl_filter(function(i)
    return i.shared
  end, vim.list_extend(vim.list_slice(all.memo), all.todo))
  table.sort(shared, function(a, b)
    if a.mtime ~= b.mtime then
      return a.mtime > b.mtime
    end
    return a.title < b.title
  end)
  local daily, others = store.split_daily(personal(all.memo))
  local data = { todo = personal(all.todo), daily = daily, shared = shared }
  -- デイリーの段を出しているときだけ、メモの段からデイリーを外す
  local separate = vim.tbl_contains(sections(), "daily")
  if daily_expanded == nil then
    daily_expanded = config.options.sidebar.daily_expanded
  end
  data.memo = others
  for section in pairs(LABEL) do
    -- Daily の段がなければ、Memo の段の中にフォルダとして出す
    render(section, data[section], section == "memo" and not separate and daily or nil)
  end
end

function M.toggle_daily()
  daily_expanded = not daily_expanded
  M.refresh()
end

local function set_win_opts(win)
  local wo = vim.wo[win][0]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.statuscolumn = ""
  wo.cursorline = true
  wo.wrap = false
  wo.list = false
  wo.spell = false
  wo.winfixwidth = true
end

function M.is_open()
  return #sidebar_wins() > 0
end

function M.open()
  if M.is_open() then
    return
  end
  local list = sections()
  if #list == 0 then
    return
  end
  local wins = {}
  for i, section in ipairs(list) do
    vim.cmd(i == 1 and "topleft vsplit" or "belowright split")
    local w = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w, get_buf(section))
    set_win_opts(w)
    table.insert(wins, w)
  end
  vim.api.nvim_win_set_width(wins[1], config.options.sidebar.width)

  -- 高さを均等に
  local total = 0
  for _, w in ipairs(wins) do
    total = total + vim.api.nvim_win_get_height(w)
  end
  local each = math.floor(total / #wins)
  for i = 1, #wins - 1 do
    vim.api.nvim_win_set_height(wins[i], each)
  end

  M.refresh()
  for _, w in ipairs(wins) do
    pcall(vim.api.nvim_win_set_cursor, w, { 2, 0 })
  end
  vim.api.nvim_set_current_win(wins[1])
end

function M.close()
  local wins = sidebar_wins()
  if #wins == 0 then
    return
  end
  -- サイドバーしか残らない場合は空のウィンドウを用意してから閉じる
  local others = vim.tbl_filter(is_normal_win, vim.api.nvim_tabpage_list_wins(0))
  if #others == 0 then
    vim.cmd("botright vnew")
  end
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_close(w, true)
    end
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

return M
