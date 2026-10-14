-- このフォルダの中のモジュールを相対的に読み込む（置き場所・フォルダ名に依存しない）
local base = (...):match("^(.*)%.[^.]+$")

-- wsl:// バッファの読み書きとディレクトリ表示
local P = require(base .. ".path")
local rpc = require(base .. ".rpc")

local M = {}

local function echo(msg, hl)
  vim.api.nvim_echo({ { msg, hl } }, false, {})
end

--- 生データ -> 行配列 / fileformat / eol
function M.decode(data)
  if data == "" then
    return { "" }, "unix", true
  end
  local eol = data:sub(-1) == "\n"
  if eol then
    data = data:sub(1, -2)
  end
  local lines = vim.split(data, "\n", { plain = true })
  -- 全行が \r で終わっていれば dos 扱い
  local dos = true
  local last = eol and #lines or #lines - 1
  if last < 1 then
    dos = #lines > 0 and lines[1]:sub(-1) == "\r"
  else
    for i = 1, last do
      if lines[i]:sub(-1) ~= "\r" then
        dos = false
        break
      end
    end
  end
  if dos then
    for i, l in ipairs(lines) do
      if l:sub(-1) == "\r" then
        lines[i] = l:sub(1, -2)
      end
    end
  end
  return lines, dos and "dos" or "unix", eol
end

--- 行配列 -> 生データ（Vim の 'eol' / 'fixeol' の挙動に合わせる）
function M.encode(lines, ff, add_eol)
  if #lines == 1 and lines[1] == "" then
    return ""
  end
  local nl = ff == "dos" and "\r\n" or "\n"
  local data = table.concat(lines, nl)
  if add_eol then
    data = data .. nl
  end
  return data
end

local function set_lines(buf, lines)
  local ul = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = ul
end

---------------------------------------------------------------------------
-- ファイル
---------------------------------------------------------------------------

function M.read(buf, name)
  local host, path = P.parse(name)
  local st = rpc.request(host, "stat", path)
  if st and st.type == "directory" then
    return M.render_dir(buf, host, path)
  end

  local r = rpc.request(host, "read", path)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false

  if not r.exists then
    set_lines(buf, { "" })
    vim.bo[buf].modified = false
    echo(('"%s" [New]'):format(name))
  else
    local lines, ff, eol = M.decode(r.data)
    set_lines(buf, lines)
    vim.bo[buf].fileformat = ff
    vim.bo[buf].eol = eol
    vim.bo[buf].modified = false
    echo(('"%s" %dL, %dB'):format(name, #lines, #r.data))
  end

  vim.b[buf].wslremote = { host = host, path = path }
  local ft = vim.filetype.match({ filename = path, buf = buf })
  if ft then
    vim.bo[buf].filetype = ft
  end
  vim.api.nvim_exec_autocmds("User", { pattern = "WslRemoteRead", data = { buf = buf, host = host, path = path } })
end

function M.write(buf, name)
  local host, path = P.parse(name)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local add_eol = vim.bo[buf].eol or (vim.bo[buf].fixeol and not vim.bo[buf].binary)
  local data = M.encode(lines, vim.bo[buf].fileformat, add_eol)
  rpc.request(host, "write", path, data)

  if name == vim.api.nvim_buf_get_name(buf) then
    vim.bo[buf].modified = false
    vim.bo[buf].eol = add_eol and true or false
  end
  echo(('"%s" %dL, %dB written'):format(name, #lines, #data))
  vim.api.nvim_exec_autocmds("User", { pattern = "WslRemoteWrite", data = { buf = buf, host = host, path = path } })
end

---------------------------------------------------------------------------
-- ディレクトリ（簡易ファイラ。neo-tree source を作るまでのつなぎ）
---------------------------------------------------------------------------

local function dir_entry_under_cursor(buf)
  local d = vim.b[buf].wslremote
  local line = vim.api.nvim_get_current_line()
  if line == "" then
    return nil
  end
  if line == "../" then
    return P.make(d.host, P.parent(d.path))
  end
  return P.make(d.host, P.join(d.path, line))
end

function M.render_dir(buf, host, path)
  local entries = rpc.request(host, "scandir", path)
  local lines = { "../" }
  for _, e in ipairs(entries) do
    lines[#lines + 1] = e.name .. (e.type == "directory" and "/" or "")
  end

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false -- ディレクトリ一覧はタブラインやバッファ一覧に出さない
  set_lines(buf, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.b[buf].wslremote = { host = host, path = path, dir = true }
  vim.bo[buf].filetype = "wslremote_dir"

  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[syntax clear | syntax match Directory /^.*\/$/]])
  end)

  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map("<CR>", function()
    local target = dir_entry_under_cursor(buf)
    if target then
      vim.cmd.edit(vim.fn.fnameescape(target))
    end
  end, "Open")
  map("-", function()
    vim.cmd.edit(vim.fn.fnameescape(P.make(host, P.parent(path))))
  end, "Parent directory")
  map("R", function()
    M.render_dir(buf, host, path)
  end, "Refresh")
end

return M
