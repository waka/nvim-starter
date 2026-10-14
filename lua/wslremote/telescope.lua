-- このフォルダの中のモジュールを相対的に読み込む（置き場所・フォルダ名に依存しない）
local base = (...):match("^(.*)%.[^.]+$")

-- Telescope ピッカー（WSL 側で fd / rg を実行し、結果をストリーミング表示）
local async = require("plenary.async")
local pickers = require("telescope.pickers")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local action_set = require("telescope.actions.set")
local action_state = require("telescope.actions.state")
local actions = require("telescope.actions")
local putils = require("telescope.previewers.utils")

local wsl = require(base)
local config = require(base .. ".config")
local rpc = require(base .. ".rpc")
local P = require(base .. ".path")
local buffer = require(base .. ".buffer")

local M = {}

local PREVIEW_MAX_BYTES = 512 * 1024

---------------------------------------------------------------------------
-- リモートジョブ → 結果リスト（複数のコルーチンから待てる）
---------------------------------------------------------------------------

local function start_job(host, cmd, cwd, entry_maker)
  local st = { results = {}, done = false, waiters = {}, stderr = "" }

  local function wake()
    local ws = st.waiters
    st.waiters = {}
    for _, cb in ipairs(ws) do
      cb()
    end
  end
  st.wait = async.wrap(function(cb)
    table.insert(st.waiters, cb)
  end, 1)

  local partial = ""
  local count = 0
  local function add(line)
    line = line:gsub("\r$", "")
    if line == "" then
      return
    end
    local e = entry_maker(line)
    if e then
      count = count + 1
      e.index = count
      st.results[count] = e
    end
  end

  st.handle = rpc.spawn(host, cmd, cwd, {
    on_stdout = function(data)
      local lines = vim.split(partial .. data, "\n", { plain = true })
      partial = table.remove(lines)
      for _, l in ipairs(lines) do
        add(l)
      end
      wake()
    end,
    on_stderr = function(data)
      st.stderr = st.stderr .. data
    end,
    on_exit = function(code)
      add(partial)
      partial = ""
      st.done, st.code = true, code
      -- rg は「該当なし」で 1 を返すので、2 以上（と起動失敗）だけ報告
      if (code == -1 or code >= 2) and st.stderr ~= "" and not st.killed then
        vim.notify("wslremote: " .. vim.trim(st.stderr), vim.log.levels.WARN)
      end
      wake()
    end,
  })

  function st.stop()
    if not st.done then
      st.killed = true
      st.handle.kill()
      st.done = true
      wake()
    end
  end

  return st
end

local function consume(st, process_result, process_complete)
  local i = 0
  while true do
    while i < #st.results do
      i = i + 1
      if process_result(st.results[i]) then
        return
      end
      if i % 1000 == 0 then
        async.util.scheduler()
      end
    end
    if st.done then
      break
    end
    st.wait()
  end
  process_complete()
end

--- 一度だけ実行して結果をキャッシュ（find_files 用）
local function oneshot_finder(host, cmd, cwd, entry_maker)
  local st
  return setmetatable({
    close = function()
      if st then
        st.stop()
      end
    end,
  }, {
    __call = function(_, _, process_result, process_complete)
      if not st then
        st = start_job(host, cmd, cwd, entry_maker)
      end
      consume(st, process_result, process_complete)
    end,
  })
end

--- プロンプトが変わるたびに実行し直す（live_grep 用）
local function live_finder(host, command_generator, cwd, entry_maker)
  local st
  return setmetatable({
    close = function()
      if st then
        st.stop()
      end
    end,
  }, {
    __call = function(_, prompt, process_result, process_complete)
      if st then
        st.stop()
        st = nil
      end
      local cmd = command_generator(prompt)
      if not cmd then
        return process_complete()
      end
      st = start_job(host, cmd, cwd, entry_maker)
      consume(st, process_result, process_complete)
    end,
  })
end

---------------------------------------------------------------------------
-- エントリ
---------------------------------------------------------------------------

local devicons_ok, devicons = pcall(require, "nvim-web-devicons")

local function icon_display(rel, rest)
  rest = rest or ""
  if not devicons_ok then
    return rel .. rest
  end
  local name = P.basename(rel)
  local icon, hl = devicons.get_icon(name, name:match("%.([^.]+)$"), { default = true })
  icon = icon or " "
  return icon .. " " .. rel .. rest, { { { 0, #icon }, hl } }
end

local function file_entry_maker(host, cwd)
  return function(line)
    local rel = line:gsub("^%./", "")
    local abs = rel:sub(1, 1) == "/" and rel or P.join(cwd, rel)
    local name = P.make(host, abs)
    return {
      value = rel,
      ordinal = rel,
      display = function()
        return icon_display(rel)
      end,
      filename = name,
      path = name,
      wsl_host = host,
      wsl_path = abs,
    }
  end
end

local function grep_entry_maker(host, cwd)
  return function(line)
    local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    if not file then
      return nil
    end
    file = file:gsub("^%./", "")
    local abs = file:sub(1, 1) == "/" and file or P.join(cwd, file)
    local name = P.make(host, abs)
    lnum, col = tonumber(lnum), tonumber(col)
    return {
      value = line,
      ordinal = file .. ":" .. text,
      display = function()
        return icon_display(file, (":%d:%d: %s"):format(lnum, col, vim.trim(text)))
      end,
      filename = name,
      path = name,
      lnum = lnum,
      col = col,
      text = text,
      wsl_host = host,
      wsl_path = abs,
    }
  end
end

---------------------------------------------------------------------------
-- プレビュー（WSL 側から非同期で読む）
---------------------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("wslremote_preview")

local function jump(self, bufnr, entry)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not entry.lnum then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, entry.lnum - 1, 0, {
    line_hl_group = "TelescopePreviewLine",
  })
  pcall(vim.api.nvim_win_set_cursor, self.state.winid, { entry.lnum, 0 })
  pcall(vim.api.nvim_win_call, self.state.winid, function()
    vim.cmd("normal! zz")
  end)
end

local function make_previewer(opts)
  return previewers.new_buffer_previewer({
    title = "WSL Preview",
    get_buffer_by_name = function(_, entry)
      return entry.filename
    end,
    define_preview = function(self, entry)
      local bufnr = self.state.bufnr
      if self.state.bufname == entry.filename then
        return jump(self, bufnr, entry)
      end
      local token = {}
      self.state.wsl_token = token
      putils.set_preview_message(bufnr, self.state.winid, "Loading...")
      rpc.request_async(entry.wsl_host, "preview", { entry.wsl_path, PREVIEW_MAX_BYTES }, function(r, err)
        if not self.state or self.state.wsl_token ~= token or not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        if err then
          return putils.set_preview_message(bufnr, self.state.winid, err)
        end
        if r.binary then
          return putils.set_preview_message(bufnr, self.state.winid, "Binary file")
        end
        local lines = buffer.decode(r.data)
        if r.truncated then
          lines[#lines + 1] = "-- (truncated) --"
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        local ft = vim.filetype.match({ filename = entry.wsl_path, contents = lines })
        if ft then
          putils.highlighter(bufnr, ft, opts)
        end
        jump(self, bufnr, entry)
      end)
    end,
  })
end

---------------------------------------------------------------------------
-- 共通
---------------------------------------------------------------------------

-- Telescope 標準の edit は Path:normalize() を通すので、Windows で wsl:// が
-- 崩れないよう自前で開く
local function attach_mappings()
  action_set.edit:replace(function(prompt_bufnr, command)
    local entry = action_state.get_selected_entry()
    if not entry then
      return
    end
    actions.close(prompt_bufnr)
    if vim.api.nvim_buf_get_name(0) ~= entry.filename or command ~= "edit" then
      vim.cmd(command .. " " .. vim.fn.fnameescape(entry.filename))
    end
    if entry.lnum then
      pcall(vim.api.nvim_win_set_cursor, 0, { entry.lnum, math.max((entry.col or 1) - 1, 0) })
      vim.cmd("normal! zz")
    end
  end)
  return true
end

--- opts.cwd: "wsl://Ubuntu/path" / "Ubuntu:~/path" / nil（現在地から自動）
local function resolve_cwd(opts)
  if opts.cwd then
    return wsl.resolve(opts.cwd)
  end
  local host, root = wsl.current_root()
  if not host then
    error("wslremote: WSL のバッファ上で実行するか、先に :WslOpen してください", 0)
  end
  return host, root
end

local function guard(fn)
  return function(opts)
    local ok, err = pcall(fn, opts or {})
    if not ok then
      vim.notify(tostring(err), vim.log.levels.ERROR)
    end
  end
end

---------------------------------------------------------------------------
-- ピッカー
---------------------------------------------------------------------------

M.find_files = guard(function(opts)
  local host, cwd = resolve_cwd(opts)
  local cmd = opts.find_command or config.get().find_command or rpc.request(host, "files_cmd")
  pickers
    .new(opts, {
      prompt_title = ("WSL Files (%s:%s)"):format(host, cwd),
      finder = oneshot_finder(host, cmd, cwd, file_entry_maker(host, cwd)),
      sorter = conf.file_sorter(opts),
      previewer = make_previewer(opts),
      attach_mappings = attach_mappings,
    })
    :find()
end)

M.live_grep = guard(function(opts)
  local host, cwd = resolve_cwd(opts)
  local base = opts.grep_command or config.get().grep_command
  local function gen(prompt)
    if not prompt or prompt == "" then
      return nil
    end
    local cmd = vim.deepcopy(base)
    vim.list_extend(cmd, { "--", prompt })
    return cmd
  end
  pickers
    .new(opts, {
      prompt_title = ("WSL Live Grep (%s:%s)"):format(host, cwd),
      finder = live_finder(host, gen, cwd, grep_entry_maker(host, cwd)),
      sorter = require("telescope.sorters").highlighter_only(opts),
      previewer = make_previewer(opts),
      attach_mappings = attach_mappings,
    })
    :find()
end)

M.grep_string = guard(function(opts)
  local host, cwd = resolve_cwd(opts)
  local word = opts.search or vim.fn.expand("<cword>")
  if word == "" then
    return
  end
  local cmd = vim.deepcopy(opts.grep_command or config.get().grep_command)
  vim.list_extend(cmd, { "--fixed-strings", "--", word })
  pickers
    .new(opts, {
      prompt_title = ("WSL Grep: %s"):format(word),
      finder = oneshot_finder(host, cmd, cwd, grep_entry_maker(host, cwd)),
      sorter = conf.generic_sorter(opts),
      previewer = make_previewer(opts),
      attach_mappings = attach_mappings,
    })
    :find()
end)

return M
