-- チェックボックスの切り替え
local store = require("memo.store")

local M = {}

-- "- [ ] a" ⇔ "- [x] a"、"- a" → "- [ ] a"、"a" → "- [ ] a"
function M.toggle_line(line)
  local pre, mark = line:match(store.TASK_PAT)
  if pre then
    local new = mark == " " and "x" or " "
    return pre .. "[" .. new .. "]" .. line:sub(#pre + 4)
  end
  local bullet = line:match("^(%s*[-*+]%s+)")
  if bullet then
    return bullet .. "[ ] " .. line:sub(#bullet + 1)
  end
  if line:match("^%s*$") then
    return line
  end
  local indent, rest = line:match("^(%s*)(.*)$")
  return indent .. "- [ ] " .. rest
end

function M.toggle_range(buf, l1, l2)
  if l1 > l2 then
    l1, l2 = l2, l1
  end
  local lines = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
  for i, l in ipairs(lines) do
    lines[i] = M.toggle_line(l)
  end
  vim.api.nvim_buf_set_lines(buf, l1 - 1, l2, false, lines)
end

function M.toggle_current()
  local l = vim.api.nvim_win_get_cursor(0)[1]
  M.toggle_range(0, l, l)
end

function M.toggle_visual()
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  M.toggle_range(0, a, b)
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "n", false)
end

-- ファイル上の 1 行を切り替える（Telescope の ToDo 項目ピッカー用）
function M.toggle_in_file(path, lnum)
  local buf = store.find_buf(store.normalize(path))
  if buf and vim.api.nvim_buf_is_loaded(buf) then
    local was_modified = vim.bo[buf].modified
    M.toggle_range(buf, lnum, lnum)
    if not was_modified then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
    end
    return
  end
  local lines = vim.fn.readfile(path)
  if lines[lnum] then
    lines[lnum] = M.toggle_line(lines[lnum])
    vim.fn.writefile(lines, path)
    require("memo.git").schedule()
  end
end

function M.attach(buf)
  local key = require("memo.config").options.checkbox_key
  if not key or key == "" then
    return
  end
  vim.keymap.set("n", key, M.toggle_current, { buffer = buf, desc = "memo: チェックボックス切り替え" })
  vim.keymap.set("x", key, M.toggle_visual, { buffer = buf, desc = "memo: チェックボックス切り替え" })
end

return M
