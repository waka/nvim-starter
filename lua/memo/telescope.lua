-- Telescope ピッカー
local config = require("memo.config")
local store = require("memo.store")

local M = {}

local LABEL = { memo = "Memo", todo = "ToDo" }

local function deps()
  local ok = pcall(require, "telescope")
  if not ok then
    vim.notify("memo: telescope.nvim が見つかりません", vim.log.levels.ERROR)
    return nil
  end
  return {
    pickers = require("telescope.pickers"),
    finders = require("telescope.finders"),
    conf = require("telescope.config").values,
    actions = require("telescope.actions"),
    action_state = require("telescope.actions.state"),
    entry_display = require("telescope.pickers.entry_display"),
  }
end

-- 何も入力していないときに並び順（更新日時順）を崩さない
local function keep_order()
  return false
end

local function map_key(map, name, fn, prompt_bufnr)
  local keys = config.options.picker.keys[name]
  if not keys then
    return
  end
  for _, mode in ipairs({ "n", "i" }) do
    local lhs = keys[mode]
    if lhs then
      map(mode, lhs, fn, { nowait = true })
      -- 単独キー g を使うと既定の gg（先頭へ）と前方一致して待たされるので外す
      if mode == "n" and lhs == "g" and prompt_bufnr then
        vim.schedule(function()
          pcall(vim.keymap.del, "n", "gg", { buffer = prompt_bufnr })
        end)
      end
    end
  end
end

local function selected_entries(t, prompt_bufnr)
  local picker = t.action_state.get_current_picker(prompt_bufnr)
  local sel = picker:get_multi_selection()
  if #sel == 0 then
    sel = { t.action_state.get_selected_entry() }
  end
  return picker, sel
end

local function refresh_sidebar()
  require("memo.sidebar").refresh()
end

---------------------------------------------------------------------------
-- :Memo / :Todo 一覧
---------------------------------------------------------------------------
function M.list(kind, opts)
  local t = deps()
  if not t then
    return
  end
  opts = opts or {}
  local items = store.list(kind)

  local displayer = t.entry_display.create({
    separator = " ",
    items = { { width = kind == "memo" and 10 or 7 }, { remaining = true } },
  })

  local function make_entry(item)
    return {
      value = item,
      ordinal = item.title,
      filename = item.path,
      path = item.path,
      display = function(e)
        local it = e.value
        if kind == "memo" then
          return displayer({ { os.date("%Y-%m-%d", it.mtime), "TelescopeResultsComment" }, it.title })
        end
        local done = store.is_complete(it)
        return displayer({
          { ("%d/%d"):format(it.done, it.total), done and "TelescopeResultsComment" or "TelescopeResultsNumber" },
          { it.title, done and "TelescopeResultsComment" or nil },
        })
      end,
    }
  end

  t.pickers
    .new(opts, {
      prompt_title = LABEL[kind],
      results_title = vim.fn.fnamemodify(store.dir(), ":~"),
      finder = t.finders.new_table({ results = items, entry_maker = make_entry }),
      sorter = t.conf.generic_sorter(opts),
      previewer = t.conf.file_previewer(opts),
      tiebreak = keep_order,
      attach_mappings = function(prompt_bufnr, map)
        map_key(map, "grep", function()
          t.actions.close(prompt_bufnr)
          M.lines(kind)
        end, prompt_bufnr)
        map_key(map, "delete", function()
          local picker, sel = selected_entries(t, prompt_bufnr)
          if #sel == 0 or not sel[1] then
            return
          end
          local msg = #sel == 1 and ("「%s」を削除しますか？"):format(sel[1].value.title)
            or ("%d 件を削除しますか？"):format(#sel)
          if require("memo.util").confirm(msg) then
            picker:delete_selection(function(e)
              store.delete(e.value.path)
            end)
            refresh_sidebar()
          end
        end)
        map_key(map, "insert", function()
          vim.cmd("startinsert!")
        end)
        return true
      end,
    })
    :find()
end

---------------------------------------------------------------------------
-- 本文の行（メモ） / - [ ] 項目（ToDo）を並べて絞り込み、選ぶとその行へ
---------------------------------------------------------------------------
function M.collect_lines(kind)
  local include_done = config.options.picker.todo_items_include_done
  local res = {}
  for _, item in ipairs(store.list(kind, true)) do
    for lnum = item.body_start, #item.lines do
      local line = item.lines[lnum]:gsub("\r$", "")
      if kind == "memo" then
        if line:match("%S") then
          table.insert(res, { path = item.path, title = item.title, lnum = lnum, text = vim.trim(line) })
        end
      else
        local pre, mark = line:match(store.TASK_PAT)
        if pre and (mark == " " or include_done) and line:sub(#pre + 4):match("%S") then
          table.insert(res, {
            path = item.path,
            title = item.title,
            lnum = lnum,
            text = vim.trim(line:sub(#pre + 4)),
            done = mark ~= " ",
          })
        end
      end
    end
  end
  return res
end

function M.lines(kind, opts)
  local t = deps()
  if not t then
    return
  end
  opts = opts or {}
  local rows = M.collect_lines(kind)

  local displayer = t.entry_display.create({
    separator = " │ ",
    items = { { width = 20 }, { remaining = true } },
  })

  local function make_entry(r)
    return {
      value = r,
      ordinal = r.text,
      filename = r.path,
      path = r.path,
      lnum = r.lnum,
      col = 1,
      display = function(e)
        local v = e.value
        local text = v.text
        if kind == "todo" then
          text = (v.done and "[x] " or "[ ] ") .. text
        end
        return displayer({ { v.title, "TelescopeResultsComment" }, { text, v.done and "TelescopeResultsComment" or nil } })
      end,
    }
  end

  t.pickers
    .new(opts, {
      prompt_title = kind == "memo" and "Memo 本文" or "ToDo 項目",
      finder = t.finders.new_table({ results = rows, entry_maker = make_entry }),
      sorter = t.conf.generic_sorter(opts),
      previewer = t.conf.grep_previewer(opts),
      tiebreak = keep_order,
      attach_mappings = function(prompt_bufnr, map)
        map_key(map, "insert", function()
          vim.cmd("startinsert!")
        end)
        if kind == "todo" then
          map_key(map, "toggle", function()
            local picker, sel = selected_entries(t, prompt_bufnr)
            if not sel[1] then
              return
            end
            local cb = require("memo.checkbox")
            if config.options.picker.todo_items_include_done then
              for _, e in ipairs(sel) do
                cb.toggle_in_file(e.value.path, e.value.lnum)
              end
              vim.notify(("memo: %d 件を切り替えました"):format(#sel))
            else
              -- 完了にしたものは一覧から消す
              picker:delete_selection(function(e)
                cb.toggle_in_file(e.value.path, e.value.lnum)
              end)
            end
            refresh_sidebar()
          end)
        end
        return true
      end,
    })
    :find()
end

---------------------------------------------------------------------------
-- リンク挿入用: メモと ToDo のタイトルから選ぶ
-- <CR>: 選んだタイトル（候補がなければ入力した文字）/ <C-e>: 入力した文字をそのまま使う
---------------------------------------------------------------------------
function M.pick_title(o)
  local t = deps()
  if not t then
    return
  end
  local all = store.list_all()
  local items = {}
  for _, kind in ipairs({ "memo", "todo" }) do
    for _, item in ipairs(all[kind]) do
      if item.path ~= o.exclude then
        table.insert(items, item)
      end
    end
  end
  table.sort(items, function(a, b)
    return a.mtime > b.mtime
  end)

  local displayer = t.entry_display.create({
    separator = " ",
    items = { { width = 4 }, { remaining = true } },
  })
  local done = false
  t.pickers
    .new({}, {
      prompt_title = "リンク先（<C-e>: 入力した名前で新規）",
      finder = t.finders.new_table({
        results = items,
        entry_maker = function(item)
          return {
            value = item,
            ordinal = item.title,
            filename = item.path,
            display = function()
              return displayer({ { item.type == "todo" and "ToDo" or "Memo", "TelescopeResultsComment" }, item.title })
            end,
          }
        end,
      }),
      sorter = t.conf.generic_sorter({}),
      previewer = t.conf.file_previewer({}),
      tiebreak = keep_order,
      attach_mappings = function(prompt_bufnr, map)
        local function finish(title)
          done = true
          t.actions.close(prompt_bufnr)
          if title and vim.trim(title) ~= "" then
            o.on_select(vim.trim(title))
          elseif o.on_cancel then
            o.on_cancel()
          end
        end
        t.actions.select_default:replace(function()
          local entry = t.action_state.get_selected_entry()
          finish(entry and entry.value.title or t.action_state.get_current_line())
        end)
        for _, mode in ipairs({ "i", "n" }) do
          map(mode, "<C-e>", function()
            finish(t.action_state.get_current_line())
          end)
        end
        -- Esc などで閉じたとき
        vim.api.nvim_create_autocmd("BufWipeout", {
          buffer = prompt_bufnr,
          once = true,
          callback = function()
            if not done and o.on_cancel then
              done = true
              o.on_cancel()
            end
          end,
        })
        return true
      end,
    })
    :find()
end

---------------------------------------------------------------------------
-- 行の一覧（バックリンクなど）。選ぶとその行へ
---------------------------------------------------------------------------
function M.locations(title, rows)
  local t = deps()
  if not t then
    return
  end
  local displayer = t.entry_display.create({
    separator = " │ ",
    items = { { width = 20 }, { remaining = true } },
  })
  t.pickers
    .new({}, {
      prompt_title = title,
      finder = t.finders.new_table({
        results = rows,
        entry_maker = function(r)
          return {
            value = r,
            ordinal = r.title .. " " .. r.text,
            filename = r.path,
            path = r.path,
            lnum = r.lnum,
            col = 1,
            display = function()
              return displayer({ { r.title, "TelescopeResultsComment" }, r.text })
            end,
          }
        end,
      }),
      sorter = t.conf.generic_sorter({}),
      previewer = t.conf.grep_previewer({}),
      tiebreak = keep_order,
    })
    :find()
end

return M
