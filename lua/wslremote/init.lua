-- このフォルダの中のモジュールを相対的に読み込む（置き場所・フォルダ名に依存しない）
local base = (...):gsub("%.init$", "")

local config = require(base .. ".config")
local P = require(base .. ".path")
local rpc = require(base .. ".rpc")
local buffer = require(base .. ".buffer")

local M = {}

local function notify_err(err)
  vim.notify(tostring(err), vim.log.levels.ERROR)
end

function M.setup(opts)
  config.setup(opts)
  M._register_autocmds()
  M._register_commands()
end

-- Telescope ピッカー（telescope は呼ばれたときに初めて読み込む）
function M.find_files(opts)
  require(base .. ".telescope").find_files(opts)
end
function M.live_grep(opts)
  require(base .. ".telescope").live_grep(opts)
end
function M.grep_string(opts)
  require(base .. ".telescope").grep_string(opts)
end

local commands_registered = false
function M._register_commands()
  if commands_registered then
    return
  end
  commands_registered = true

  local function hosts()
    return vim.tbl_keys(rpc.connections())
  end
  local cmd = vim.api.nvim_create_user_command

  cmd("WslOpen", function(o)
    M.open(o.args, o.mods)
  end, { nargs = "?", desc = "WSL のパスを開く（例: Ubuntu:~/project）" })

  cmd("WslTerm", function(o)
    M.term(o.mods)
  end, { nargs = 0, desc = "現在の WSL ディレクトリでシェルを開く" })

  cmd("WslDisconnect", function(o)
    local targets = o.args ~= "" and { o.args } or hosts()
    for _, h in ipairs(targets) do
      rpc.disconnect(h)
    end
  end, { nargs = "?", complete = hosts, desc = "WSL エージェントを切断" })

  cmd("WslInfo", function()
    M.info()
  end, { nargs = 0 })

  cmd("WslFiles", function()
    M.find_files()
  end, { nargs = 0, desc = "WSL: ファイル検索" })

  cmd("WslGrep", function()
    M.live_grep()
  end, { nargs = 0, desc = "WSL: live grep" })
end

local registered = false
function M._register_autocmds()
  if registered then
    return
  end
  registered = true
  local group = vim.api.nvim_create_augroup("wslremote", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = P.prefix .. "*",
    callback = function(ev)
      local ok, err = pcall(buffer.read, ev.buf, ev.match)
      if not ok then
        notify_err(err)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = P.prefix .. "*",
    callback = function(ev)
      local ok, err = pcall(buffer.write, ev.buf, ev.match)
      if not ok then
        notify_err(err)
      end
    end,
  })
end

--- "Ubuntu:~/project" / "~/project" / "/etc" / "Ubuntu:" を host, 絶対パスに解決
function M.resolve(spec)
  spec = spec or ""
  if P.is_remote(spec) then
    return P.parse(spec)
  end
  local host, path = spec:match("^([%w%._%-]+):(.*)$")
  if not host then
    host, path = config.get().default_host, spec
  end
  local home = rpc.connect(host).home
  if path == "" or path == "~" then
    path = home
  elseif path:sub(1, 2) == "~/" then
    path = home .. path:sub(2)
  elseif path:sub(1, 1) ~= "/" then
    path = home .. "/" .. path
  end
  return host, path
end

--- 現在のバッファ/タブから「今いるリモートの場所」を返す
--- 戻り値: host, dir（ディレクトリの絶対パス）
function M.current_location(buf)
  buf = buf or 0
  local name = vim.api.nvim_buf_get_name(buf)
  if P.is_remote(name) then
    local host, path = P.parse(name)
    local d = vim.b[buf].wslremote
    if d and d.dir then
      return host, path
    end
    return host, P.parent(path)
  end
  local root = vim.t.wslremote_root
  if root then
    return P.parse(root)
  end
  return nil
end

--- Telescope などの検索起点。タブのルート > マーカー探索 > 現在のディレクトリ
function M.current_root(buf)
  local host, dir = M.current_location(buf)
  if not host then
    return nil
  end
  local troot = vim.t.wslremote_root
  if troot then
    local th, tp = P.parse(troot)
    if th == host and P.relative(dir, tp) then
      return host, tp
    end
  end
  local ok, root = pcall(rpc.request, host, "root", dir, config.get().root_markers)
  if ok and root then
    return host, root
  end
  return host, dir
end

--- :WslOpen
function M.open(spec, mods)
  local ok, host, path = pcall(M.resolve, spec)
  if not ok then
    return notify_err(host)
  end
  local st_ok, st = pcall(rpc.request, host, "stat", path)
  if not st_ok then
    return notify_err(st)
  end
  if mods and mods ~= "" then
    vim.cmd(mods .. " split") -- :tab なら新しいタブ、:vert なら縦分割
  end
  if st and st.type == "directory" then
    vim.t.wslremote_root = P.make(host, path)
  end
  vim.cmd.edit(vim.fn.fnameescape(P.make(host, path)))
end

--- :WslTerm（mods で :tab / :vert などを指定可能）
function M.term(mods)
  local host, dir = M.current_location()
  if not host then
    host, dir = config.get().default_host, "~"
  end
  local cmd = config.get().term_cmd(host, dir)
  if mods and mods ~= "" then
    vim.cmd(mods .. " new")
  else
    vim.cmd.enew()
  end
  if vim.fn.has("nvim-0.11") == 1 then
    vim.fn.jobstart(cmd, { term = true })
  else
    vim.fn.termopen(cmd)
  end
  vim.cmd.startinsert()
end

function M.info()
  local lines = {}
  for host, c in pairs(rpc.connections()) do
    lines[#lines + 1] = ("%s: chan=%d nvim=%s home=%s"):format(host, c.chan, c.version, c.home)
  end
  if #lines == 0 then
    lines = { "wslremote: 接続なし" }
  end
  if vim.t.wslremote_root then
    lines[#lines + 1] = "tab root: " .. vim.t.wslremote_root
  end
  vim.notify(table.concat(lines, "\n"))
end

return M
