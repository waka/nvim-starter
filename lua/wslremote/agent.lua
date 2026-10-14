-- WSL 側の headless Neovim に送り込まれて実行されるエージェント。
-- ローカル側からは nvim_exec_lua 経由で `_G.WslAgent` を呼び出す。
-- このファイルはローカルでは require されない（文字列として転送される）。

local A = {}
local F = {}
local client -- ローカル Neovim との RPC チャネル ID
local callback_module -- ローカル側の rpc モジュール名
local jobs = {}

local uv = vim.uv or vim.loop

-- ローカル側の `require(<rpc モジュール>)[fn](...)` を呼ぶ通知を送る
local function reply(fn, ...)
  if not client then
    return
  end
  vim.rpcnotify(client, "nvim_exec_lua", ("require(%q).%s(...)"):format(callback_module, fn), { ... })
end

---------------------------------------------------------------------------
-- 公開関数（F.*）
---------------------------------------------------------------------------

function F.stat(path)
  local st = uv.fs_stat(path)
  if not st then
    return nil
  end
  return { type = st.type, size = st.size, mtime = st.mtime.sec }
end

function F.read(path)
  local fh, err = io.open(path, "rb")
  if not fh then
    if not uv.fs_stat(path) then
      return { exists = false }
    end
    error(err)
  end
  local data = fh:read("*a")
  fh:close()
  return { exists = true, data = data }
end

-- プレビュー用：先頭 max_bytes だけ読む
function F.preview(path, max_bytes)
  local fh = assert(io.open(path, "rb"))
  local data = fh:read(max_bytes) or ""
  local more = fh:read(1) ~= nil
  fh:close()
  local binary = data:sub(1, 8192):find("%z") ~= nil
  return { data = binary and "" or data, truncated = more, binary = binary }
end

function F.write(path, data)
  local fh = assert(io.open(path, "wb"))
  fh:write(data)
  fh:close()
  return #data
end

function F.scandir(path)
  local handle = assert(uv.fs_scandir(path))
  local entries = {}
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if typ == "link" then
      local st = uv.fs_stat(path .. "/" .. name)
      typ = st and st.type or "link"
    end
    entries[#entries + 1] = { name = name, type = typ }
  end
  table.sort(entries, function(a, b)
    local ad, bd = a.type == "directory", b.type == "directory"
    if ad ~= bd then
      return ad
    end
    return a.name < b.name
  end)
  return entries
end

-- ファイラ用の操作 ---------------------------------------------------------

function F.mkdir(path)
  local cur = ""
  for part in path:gmatch("[^/]+") do
    cur = cur .. "/" .. part
    if not uv.fs_stat(cur) then
      assert(uv.fs_mkdir(cur, 493)) -- 0755
    end
  end
  return true
end

function F.create(path)
  assert(not uv.fs_stat(path), "already exists: " .. path)
  F.mkdir(path:match("^(.*)/[^/]*$") or "/")
  local fh = assert(io.open(path, "wb"))
  fh:close()
  return true
end

function F.delete(path)
  assert(path ~= "/" and path ~= uv.os_homedir(), "refusing to delete " .. path)
  assert(vim.fn.delete(path, "rf") == 0, "delete failed: " .. path)
  return true
end

function F.rename(from, to)
  assert(not uv.fs_stat(to), "already exists: " .. to)
  assert(uv.fs_rename(from, to))
  return true
end

function F.realpath(path)
  return uv.fs_realpath(path)
end

function F.home()
  return uv.os_homedir()
end

-- markers を含む最も近い上位ディレクトリ
-- （古い Neovim でも動くよう vim.fs は使わない）
function F.root(path, markers)
  local dir = path:gsub("/+$", "")
  while true do
    for _, m in ipairs(markers) do
      if uv.fs_stat((dir == "" and "" or dir) .. "/" .. m) then
        return dir == "" and "/" or dir
      end
    end
    if dir == "" then
      return nil
    end
    dir = dir:match("^(.*)/[^/]*$") or ""
  end
end

-- ファイル列挙コマンドを WSL 側で使えるものから選ぶ
function F.files_cmd()
  if vim.fn.executable("fd") == 1 then
    return { "fd", "--type", "f", "--hidden", "--exclude", ".git", "--color", "never" }
  elseif vim.fn.executable("fdfind") == 1 then
    return { "fdfind", "--type", "f", "--hidden", "--exclude", ".git", "--color", "never" }
  elseif vim.fn.executable("rg") == 1 then
    return { "rg", "--files", "--hidden", "--glob", "!.git" }
  end
  return { "find", ".", "-type", "f", "-not", "-path", "*/.git/*" }
end

function F.executable(name)
  return vim.fn.executable(name) == 1
end

---------------------------------------------------------------------------
-- プロセス起動（出力はチャンク単位でストリーミング）
---------------------------------------------------------------------------

-- vim.system は 0.10 以降にしかないので、古い Neovim（apt 版など）でも動く jobstart を使う
local function on_output(id, kind)
  return function(_, data)
    -- data は行のリスト。"\n" でつなぐと受け取ったチャンクがそのまま復元できる。
    -- EOF のときは { "" } が来るので無視する
    if not data or (#data == 1 and data[1] == "") then
      return
    end
    reply("_on_stream", id, kind, table.concat(data, "\n"))
  end
end

function A.spawn(id, cmd, cwd)
  local ok, jid = pcall(vim.fn.jobstart, cmd, {
    cwd = cwd,
    -- stdin がパイプだと rg がディレクトリではなく stdin を検索してしまう
    stdin = "null",
    on_stdout = on_output(id, "stdout"),
    on_stderr = on_output(id, "stderr"),
    on_exit = function(_, code)
      jobs[id] = nil
      reply("_on_stream", id, "exit", code)
    end,
  })
  if not ok or jid <= 0 then
    local msg = not ok and tostring(jid)
      or (jid == -1 and ("command not found: " .. tostring(cmd[1])) or "invalid arguments")
    reply("_on_stream", id, "stderr", msg)
    reply("_on_stream", id, "exit", -1)
    return
  end
  jobs[id] = jid
end

function A.kill(id)
  local jid = jobs[id]
  if jid then
    jobs[id] = nil
    pcall(vim.fn.jobstop, jid)
  end
end

---------------------------------------------------------------------------
-- 呼び出し口
---------------------------------------------------------------------------

function A.init(cb_module)
  callback_module = cb_module
  -- --embed では stdio の RPC チャネルがローカル Neovim とのチャネル
  -- （nvim_get_chan_info(0) は RPC 経由の呼び出しでは空になる）
  for _, ch in ipairs(vim.api.nvim_list_chans()) do
    if ch.mode == "rpc" and ch.stream == "stdio" then
      client = ch.id
      break
    end
  end
  assert(client, "stdio RPC channel not found")
  local v = vim.version()
  return { home = uv.os_homedir(), version = ("%d.%d.%d"):format(v.major, v.minor, v.patch) }
end

-- 同期呼び出し（vim.rpcrequest から）
function A.call(name, args)
  local fn = F[name]
  if not fn then
    return { ok = false, err = "unknown function: " .. tostring(name) }
  end
  local ok, res = pcall(fn, unpack(args or {}))
  if ok then
    return { ok = true, value = res }
  end
  return { ok = false, err = tostring(res) }
end

-- 非同期呼び出し（vim.rpcnotify から。結果は通知で返す）
function A.call_async(id, name, args)
  local res = A.call(name, args)
  reply("_on_reply", id, res)
end

return A
