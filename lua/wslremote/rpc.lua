-- このフォルダの中のモジュールを相対的に読み込む（置き場所・フォルダ名に依存しない）
local base = (...):match("^(.*)%.[^.]+$")

-- WSL 側エージェントとの通信
local config = require(base .. ".config")

local M = {}

local conns = {} -- host -> { chan, home, version }
local pending = {} -- id -> { host, cb }
local streams = {} -- id -> { host, on_stdout, on_stderr, on_exit }
local next_id = 0

local function new_id()
  next_id = next_id + 1
  return next_id
end

-- このモジュール自身の名前（エージェントからのコールバック先）
local self_name = base .. ".rpc"

-- agent.lua はこのファイルと同じフォルダにある
local agent_src
local function get_agent_src()
  if not agent_src then
    local here = debug.getinfo(1, "S").source:sub(2)
    local file = vim.fs.joinpath(vim.fs.dirname(here), "agent.lua")
    assert(vim.uv.fs_stat(file), "wslremote: agent.lua が見つかりません: " .. file)
    agent_src = table.concat(vim.fn.readfile(file, "b"), "\n")
  end
  return agent_src
end

local function fail_host(host, msg)
  for id, p in pairs(pending) do
    if p.host == host then
      pending[id] = nil
      pcall(p.cb, nil, msg)
    end
  end
  for id, s in pairs(streams) do
    if s.host == host then
      streams[id] = nil
      if s.on_stderr then
        pcall(s.on_stderr, msg)
      end
      if s.on_exit then
        pcall(s.on_exit, -1)
      end
    end
  end
end

--- 接続（未接続なら起動）して接続情報を返す
function M.connect(host)
  local c = conns[host]
  if c then
    return c
  end

  local opts = config.get()
  local cmd = opts.cmd(host, opts.remote_nvim)
  local stderr = {}
  local ok, chan = pcall(vim.fn.jobstart, cmd, {
    rpc = true,
    on_stderr = function(_, data)
      vim.list_extend(stderr, data)
    end,
    on_exit = function(_, code)
      if conns[host] then
        conns[host] = nil
        if vim.v.exiting ~= vim.NIL then
          return
        end
        vim.schedule(function()
          vim.notify(("wslremote: %s との接続が切れました (exit %d)"):format(host, code), vim.log.levels.WARN)
        end)
      end
      fail_host(host, "connection closed")
    end,
  })
  if not ok or chan <= 0 then
    error(("wslremote: エージェントを起動できません: %s (%s)"):format(table.concat(cmd, " "), tostring(chan)), 0)
  end

  -- 0.6 以前は --embed --headless でも UI の接続を待って止まってしまうので先に弾く
  -- （nvim_get_api_info は UI 接続前でも応答する）
  local api_ok, api = pcall(vim.rpcrequest, chan, "nvim_get_api_info")
  if api_ok then
    local v = api[2].version
    if v.major == 0 and v.minor < 7 then
      pcall(vim.fn.jobstop, chan)
      error(
        ("wslremote: WSL 側の Neovim が古すぎます (%d.%d.%d)。0.7 以上が必要です"):format(v.major, v.minor, v.patch),
        0
      )
    end
  end

  local src = get_agent_src()
  local init_ok, info = pcall(
    vim.rpcrequest,
    chan,
    "nvim_exec_lua",
    "local src, cb = ...; _G.WslAgent = assert(loadstring(src, '=wslremote-agent'))(); return _G.WslAgent.init(cb)",
    { src, self_name }
  )
  if not init_ok then
    pcall(vim.fn.jobstop, chan)
    local detail = table.concat(stderr, "\n")
    error(("wslremote: %s のエージェント初期化に失敗しました: %s %s"):format(host, tostring(info), detail), 0)
  end

  c = { chan = chan, home = info.home, version = info.version }
  conns[host] = c
  return c
end

function M.disconnect(host)
  local c = conns[host]
  if c then
    conns[host] = nil
    pcall(vim.fn.jobstop, c.chan)
    fail_host(host, "disconnected")
  end
end

function M.connections()
  return conns
end

--- 同期呼び出し。失敗したら error を投げる
function M.request(host, fn, ...)
  local c = M.connect(host)
  local res = vim.rpcrequest(c.chan, "nvim_exec_lua", "return WslAgent.call(...)", { fn, { ... } })
  if not res.ok then
    error(("wslremote: %s(%s): %s"):format(fn, host, res.err), 0)
  end
  return res.value
end

--- 非同期呼び出し。cb(value, err)
function M.request_async(host, fn, args, cb)
  local ok, c = pcall(M.connect, host)
  if not ok then
    vim.schedule(function()
      cb(nil, c)
    end)
    return
  end
  local id = new_id()
  pending[id] = { host = host, cb = cb }
  vim.rpcnotify(c.chan, "nvim_exec_lua", "WslAgent.call_async(...)", { id, fn, args or {} })
end

--- WSL 側でプロセスを起動し、出力をストリーミングで受け取る
--- handlers: { on_stdout(data), on_stderr(data), on_exit(code) }
--- 戻り値: { kill = function() }
function M.spawn(host, cmd, cwd, handlers)
  local c = M.connect(host)
  local id = new_id()
  streams[id] = vim.tbl_extend("force", { host = host }, handlers or {})
  vim.rpcnotify(c.chan, "nvim_exec_lua", "WslAgent.spawn(...)", { id, cmd, cwd })
  return {
    id = id,
    kill = function()
      if streams[id] then
        streams[id] = nil
        local cc = conns[host]
        if cc then
          vim.rpcnotify(cc.chan, "nvim_exec_lua", "WslAgent.kill(...)", { id })
        end
      end
    end,
  }
end

---------------------------------------------------------------------------
-- エージェントから呼ばれる（rpcnotify -> nvim_exec_lua）
---------------------------------------------------------------------------

function M._on_reply(id, res)
  local p = pending[id]
  if not p then
    return
  end
  pending[id] = nil
  if res.ok then
    p.cb(res.value, nil)
  else
    p.cb(nil, res.err)
  end
end

function M._on_stream(id, kind, data)
  local s = streams[id]
  if not s then
    return
  end
  if kind == "exit" then
    streams[id] = nil
    if s.on_exit then
      s.on_exit(data)
    end
  elseif kind == "stdout" and s.on_stdout then
    s.on_stdout(data)
  elseif kind == "stderr" and s.on_stderr then
    s.on_stderr(data)
  end
end

return M
