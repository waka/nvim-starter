-- タブごとにバッファを分ける（mini.tabline などと組み合わせて使う）
--
-- タブを切り替えるたびに、他のタブで開いたバッファを「一覧に出さない」状態にする。
-- タブラインの描画は mini.tabline に任せるので、表示も :bnext も Telescope の
-- バッファ一覧（<leader><leader>）も、今のタブの分だけになる。
--
-- キー:
--   <S-l> / <S-h>  このタブのバッファで次 / 前へ（:bnext / :bprevious）
--   <leader>bd     このタブから外す（他のタブで使っていなければバッファも閉じる）
--
-- タブを閉じたとき、そのタブにしかなかったバッファは閉じる（未保存のものは今のタブへ移す）。

local api = vim.api

local lists = {} -- tabpage handle -> { bufnr, ... }
local managed = {} -- 管理しているバッファ（どこかのタブに属している）
local switching = false -- 自分で buflisted を切り替えている最中

local function is_file_buf(buf)
  if not api.nvim_buf_is_valid(buf) then
    return false
  end
  local bt = vim.bo[buf].buftype
  return bt == "" or bt == "acwrite" -- 普通のファイルと wsl:// のファイル
end

local function list_of(tab)
  tab = (tab == nil or tab == 0) and api.nvim_get_current_tabpage() or tab
  lists[tab] = lists[tab] or {}
  return lists[tab]
end

local function add(buf, tab)
  if not is_file_buf(buf) then
    return
  end
  local list = list_of(tab)
  if not vim.tbl_contains(list, buf) then
    table.insert(list, buf)
  end
  managed[buf] = true
end

local function remove_everywhere(buf)
  for tab, list in pairs(lists) do
    lists[tab] = vim.tbl_filter(function(b)
      return b ~= buf
    end, list)
  end
  managed[buf] = nil
end

local function set_listed(buf, listed)
  if api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted ~= listed then
    switching = true
    pcall(api.nvim_set_option_value, "buflisted", listed, { buf = buf })
    switching = false
  end
end

--- 今のタブのバッファだけを一覧に出す
local function apply()
  local current = {}
  for _, b in ipairs(list_of(0)) do
    current[b] = true
  end
  for buf in pairs(managed) do
    if not api.nvim_buf_is_valid(buf) then
      remove_everywhere(buf)
    else
      set_listed(buf, current[buf] == true)
    end
  end
end

---------------------------------------------------------------------------
-- 自動コマンド
---------------------------------------------------------------------------

local group = api.nvim_create_augroup("tabscope", { clear = true })

-- 開いたバッファを今のタブに記録する。
-- neo-tree などは「一覧に出さないバッファ」として作ってから開くので、ここで一覧に出す
api.nvim_create_autocmd("BufEnter", {
  group = group,
  callback = function(ev)
    if is_file_buf(ev.buf) then
      add(ev.buf)
      vim.schedule(function()
        if api.nvim_buf_is_valid(ev.buf) and vim.tbl_contains(list_of(0), ev.buf) then
          set_listed(ev.buf, true)
        end
      end)
    end
  end,
})

-- タブに入ったら、そのタブのウィンドウに表示中のバッファも記録してから切り替える
local function adopt_windows()
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    add(api.nvim_win_get_buf(win))
  end
end

-- タブを離れるとき、まだどのタブにも属していない「一覧に出ているファイル」は
-- 離れるタブのものにする（起動直後など、どこかで記録が漏れても新しいタブへ持ち込まない）
api.nvim_create_autocmd("TabLeave", {
  group = group,
  callback = function()
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if not managed[buf] and vim.bo[buf].buflisted then
        add(buf)
      end
    end
  end,
})

local fresh = {}
api.nvim_create_autocmd("TabNew", {
  group = group,
  callback = function()
    fresh[api.nvim_get_current_tabpage()] = true
  end,
})

api.nvim_create_autocmd("TabEnter", {
  group = group,
  callback = function()
    local tab = api.nvim_get_current_tabpage()
    if fresh[tab] then
      -- :tab split した直後に別のファイルを開く（:tab WslOpen など）ことがあるので、
      -- 新しいタブは一拍おいてから表示中のバッファを記録する
      fresh[tab] = nil
      apply()
      vim.schedule(function()
        if api.nvim_get_current_tabpage() == tab then
          adopt_windows()
          apply()
        end
      end)
    else
      adopt_windows()
      apply()
    end
  end,
})

-- :bdelete などでユーザーが閉じたバッファは、全タブから外す
api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = group,
  callback = function(ev)
    if not switching then
      remove_everywhere(ev.buf)
    end
  end,
})

-- タブを閉じたとき、そのタブにしかなかったバッファを片付ける
api.nvim_create_autocmd("TabClosed", {
  group = group,
  callback = function()
    local alive = {}
    for _, t in ipairs(api.nvim_list_tabpages()) do
      alive[t] = true
    end
    local orphans = {}
    for tab, list in pairs(lists) do
      if not alive[tab] then
        vim.list_extend(orphans, list)
        lists[tab] = nil
      end
    end
    vim.schedule(function()
      for _, buf in ipairs(orphans) do
        local still_used = false
        for _, list in pairs(lists) do
          if vim.tbl_contains(list, buf) then
            still_used = true
          end
        end
        if not still_used and api.nvim_buf_is_valid(buf) then
          if vim.bo[buf].modified or vim.fn.bufwinid(buf) ~= -1 then
            add(buf) -- 未保存・表示中のものは今のタブへ
          else
            remove_everywhere(buf)
            pcall(vim.cmd.bdelete, buf)
          end
        end
      end
      apply()
    end)
  end,
})

-- 起動時に引数で開いたファイルなどは、最初のタブのものにする
api.nvim_create_autocmd("VimEnter", {
  group = group,
  callback = function()
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if vim.bo[buf].buflisted then
        add(buf)
      end
    end
  end,
})

---------------------------------------------------------------------------
-- キー
---------------------------------------------------------------------------

vim.keymap.set("n", "<S-l>", "<cmd>bnext<cr>", { desc = "Next buffer in tab" })
vim.keymap.set("n", "<S-h>", "<cmd>bprevious<cr>", { desc = "Previous buffer in tab" })

vim.keymap.set("n", "<leader>bd", function()
  local cur = api.nvim_get_current_buf()
  if vim.bo[cur].modified then
    return vim.notify("保存していない変更があります", vim.log.levels.WARN)
  end
  local list = list_of(0)
  local idx = 1
  for i, b in ipairs(list) do
    if b == cur then
      idx = i
    end
  end
  local rest = vim.tbl_filter(function(b)
    return b ~= cur and api.nvim_buf_is_valid(b)
  end, list)

  -- 先に別のバッファへ移る
  if #rest > 0 then
    api.nvim_set_current_buf(rest[math.min(idx, #rest)])
  else
    vim.cmd.enew()
  end
  lists[api.nvim_get_current_tabpage()] = vim.tbl_filter(function(b)
    return b ~= cur
  end, list_of(0))

  local used_elsewhere = false
  for _, l in pairs(lists) do
    if vim.tbl_contains(l, cur) then
      used_elsewhere = true
    end
  end
  if used_elsewhere or vim.fn.win_findbuf(cur)[1] ~= nil then
    set_listed(cur, false)
  else
    remove_everywhere(cur)
    pcall(vim.cmd.bdelete, cur)
  end
end, { desc = "[B]uffer [D]elete from tab" })

return {}
