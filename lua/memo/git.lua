-- 管理フォルダ（個人）と shared/（共有）を、それぞれの git リポジトリと同期する
local config = require("memo.config")

local M = {}

-- GIT_TERMINAL_PROMPT=0: 認証が必要でも入力待ちで固まらずに失敗させる
local ENV = { GIT_TERMINAL_PROMPT = "0" }

-- steps: { function(next, fail) ... } を順番に実行
local function chain(steps, done)
  local i = 0
  local function next_step()
    i = i + 1
    local step = steps[i]
    if not step then
      return done(true)
    end
    step(next_step, function(msg)
      done(false, msg)
    end)
  end
  next_step()
end

local function refresh_ui()
  vim.cmd("silent! checktime")
  pcall(function()
    require("memo.sidebar").refresh()
  end)
end

---------------------------------------------------------------------------
-- リポジトリ 1 つぶんの同期
---------------------------------------------------------------------------
local Repo = {}
Repo.__index = Repo

--- @param spec table { label, dir = fn, opts = fn, before_commit = fn|nil }
local function new_repo(spec)
  return setmetatable({
    spec = spec,
    state = {
      running = false, -- 同期中
      pending = false, -- 同期中に次の同期を頼まれた
      pending_manual = false,
      pulled_once = false, -- このセッションで一度 pull したか
      conflict = false, -- 競合で止まっている（自動同期を休む）
      timer = nil,
      last_sync = 0,
    },
  }, Repo)
end

function Repo:dir()
  return self.spec.dir()
end

function Repo:opts()
  return self.spec.opts()
end

function Repo:notify(msg, level)
  local prefix = self.spec.label ~= "" and (self.spec.label .. ": ") or ""
  vim.notify("memo: " .. prefix .. msg, level or vim.log.levels.INFO)
end

function Repo:is_repo()
  return vim.uv.fs_stat(self:dir() .. "/.git") ~= nil
end

function Repo:cmd(args)
  -- core.quotepath=false: 日本語のファイル名をエスケープしない
  return vim.list_extend({ "git", "-c", "core.quotepath=false", "-C", self:dir() }, args)
end

-- 非同期で git を実行。cb(ok, stdout, stderr) はメインループで呼ばれる
function Repo:run(args, cb)
  local ok, err = pcall(vim.system, self:cmd(args), { text = true, env = ENV }, function(res)
    vim.schedule(function()
      cb(res.code == 0, vim.trim(res.stdout or ""), vim.trim(res.stderr or ""))
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(false, "", "git を実行できません: " .. tostring(err))
    end)
  end
end

-- 同期実行（終了時・競合処理用）
function Repo:run_wait(args, timeout)
  local ok, obj = pcall(vim.system, self:cmd(args), { text = true, env = ENV })
  if not ok then
    return false, "", ""
  end
  local res = obj:wait(timeout)
  return res.code == 0, res.stdout or "", vim.trim(res.stderr or "")
end

function Repo:commit_message()
  return os.date(self:opts().commit_message)
end

-- 変更があれば add + commit
function Repo:step_commit()
  return function(next, fail)
    if self.spec.before_commit then
      self.spec.before_commit()
    end
    self:run({ "status", "--porcelain" }, function(ok, out, err)
      if not ok then
        return fail(err)
      end
      if out == "" then
        return next()
      end
      self:run({ "add", "-A" }, function(ok2, _, err2)
        if not ok2 then
          return fail(err2)
        end
        self:run({ "commit", "-q", "-m", self:commit_message() }, function(ok3, out3, err3)
          if not ok3 then
            return fail(err3 ~= "" and err3 or out3)
          end
          next()
        end)
      end)
    end)
  end
end

--- 競合したファイルの自分の版を「タイトル (競合 日時)」として別ファイルに残す
--- @param saved table { [relpath] = 自分の版の内容 }
--- @return string[] 作ったコピーのタイトル
function Repo:write_conflict_copies(saved)
  local store = require("memo.store")
  local made = {}
  for rel, content in pairs(saved) do
    local path = self:dir() .. "/" .. rel
    local current = store.exists(path) and table.concat(vim.fn.readfile(path), "\n") or nil
    local mine = content:gsub("\n$", "")
    if current ~= mine then
      local lines = vim.split(mine, "\n", { plain = true })
      local meta = store.parse_frontmatter(lines)
      local base = meta.title or vim.fn.fnamemodify(rel, ":t:r")
      local title = ("%s (競合 %s)"):format(base, os.date("%m-%d %H:%M"))
      local replaced = false
      for i = 2, math.min(#lines, 40) do
        if lines[i] == "---" then
          break
        end
        if lines[i]:match("^title%s*:") then
          lines[i] = ('title: "%s"'):format(title:gsub('"', '\\"'))
          replaced = true
          break
        end
      end
      if not replaced then
        table.insert(lines, 1, "---")
        table.insert(lines, 2, ('title: "%s"'):format(title))
        table.insert(lines, 3, "---")
      end
      local dest = store.path_for(title, self:dir())
      local n = 2
      while store.exists(dest) do
        dest = store.path_for(("%s %d"):format(title, n), self:dir())
        n = n + 1
      end
      vim.fn.writefile(lines, dest)
      table.insert(made, title)
    end
  end
  return made
end

--- pull --rebase。競合したら conflict 設定に従う
function Repo:step_pull(ctx)
  return function(next, fail)
    if not ctx.has_upstream then
      return next()
    end
    self:run({ "pull", "--rebase", "--autostash", "-q" }, function(ok, out, err)
      if ok then
        return next()
      end
      self:run({ "diff", "--name-only", "--diff-filter=U" }, function(_, files)
        self:run({ "rebase", "--abort" }, function()
          if files == "" then
            return fail("pull に失敗しました\n" .. (err ~= "" and err or out))
          end
          local list = vim.split(files, "\n", { trimempty = true })
          local function stop()
            self.state.conflict = true
            fail(("競合しました: %s\n手元の内容はそのままです。ターミナルで解決してから :MTSync を実行してください（それまで自動同期は止めます）")
              :format(table.concat(list, ", ")))
          end
          if self:opts().conflict ~= "copy" then
            return stop()
          end
          -- 自分の版を控えてから、競合した箇所は相手の版で取り込む
          local saved = {}
          for _, rel in ipairs(list) do
            local okshow, content = self:run_wait({ "show", "HEAD:" .. rel }, 5000)
            if okshow then
              saved[rel] = content
            end
          end
          self:run({ "pull", "--rebase", "--autostash", "-q", "-X", "ours" }, function(ok2)
            if not ok2 then
              return self:run({ "rebase", "--abort" }, stop)
            end
            ctx.conflict_copies = self:write_conflict_copies(saved)
            self:step_commit()(next, fail)
          end)
        end)
      end)
    end)
  end
end

--- commit → pull --rebase → push
--- @param manual boolean :MTSync から呼ばれたか（結果を必ず通知する）
function Repo:sync(manual)
  if not self:is_repo() then
    if manual and not self.spec.quiet_if_missing then
      self:notify(("%s は git リポジトリではありません。:MTSync init <URL> で設定できます"):format(self:dir()), vim.log.levels.WARN)
    end
    return
  end
  local st = self.state
  if st.running then
    st.pending = true
    st.pending_manual = st.pending_manual or manual
    return
  end
  if st.conflict and not manual then
    return
  end
  st.running = true
  st.pulled_once = true
  st.last_sync = vim.uv.now()
  local ctx = {}

  chain({
    self:step_commit(),
    function(next)
      self:run({ "remote" }, function(_, out)
        ctx.has_remote = out ~= ""
        next()
      end)
    end,
    function(next)
      if not ctx.has_remote then
        return next()
      end
      self:run({ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, function(ok)
        ctx.has_upstream = ok
        next()
      end)
    end,
    function(next)
      self:run({ "rev-parse", "HEAD" }, function(_, out)
        ctx.before = out
        next()
      end)
    end,
    self:step_pull(ctx),
    function(next, fail)
      if not ctx.has_remote then
        return next()
      end
      local args = ctx.has_upstream and { "push", "-q" } or { "push", "-q", "-u", "origin", "HEAD" }
      self:run(args, function(ok, out, err)
        if not ok then
          return fail("push に失敗しました\n" .. (err ~= "" and err or out))
        end
        next()
      end)
    end,
  }, function(ok, msg)
    self:run({ "rev-parse", "HEAD" }, function(_, after)
      local function finish(changed)
        st.running = false
        if ok then
          st.conflict = false
          if changed and #changed > 0 then
            refresh_ui()
          end
          if ctx.conflict_copies and #ctx.conflict_copies > 0 then
            self:notify(("同時に編集されたので、相手の版を採用し、自分の版を %s として残しました")
              :format(table.concat(vim.tbl_map(function(t)
                return "「" .. t .. "」"
              end, ctx.conflict_copies), "、")), vim.log.levels.WARN)
          end
          if manual then
            self:notify(ctx.has_remote and "同期しました" or "commit しました（リモートが未設定です）")
          elseif changed and #changed > 0 and self:opts().notify_pull then
            local names = vim.tbl_map(function(f)
              return "「" .. vim.fn.fnamemodify(f, ":t:r") .. "」"
            end, vim.list_slice(changed, 1, 3))
            local more = #changed > 3 and ("ほか %d 件"):format(#changed - 3) or ""
            self:notify(("リモートの変更を取り込みました: %s%s"):format(table.concat(names, "、"), more))
          end
        else
          self:notify(msg or "同期に失敗しました", vim.log.levels.ERROR)
        end
        if st.pending then
          local m = st.pending_manual
          st.pending, st.pending_manual = false, false
          self:sync(m)
        end
      end
      if ok and ctx.before and ctx.before ~= "" and after ~= ctx.before then
        -- 取り込んだ（相手が変えた）ファイル
        self:run({ "diff", "--name-only", ctx.before, after, "--", "*.md" }, function(_, files)
          finish(vim.split(files, "\n", { trimempty = true }))
        end)
      else
        finish({})
      end
    end)
  end)
end

--- 変更があったときに呼ぶ。少し待ってから同期する
function Repo:schedule()
  if not self:opts().auto or not self:is_repo() then
    return
  end
  local st = self.state
  if not st.timer then
    st.timer = vim.uv.new_timer()
  end
  st.timer:stop()
  st.timer:start(self:opts().delay * 1000, 0, vim.schedule_wrap(function()
    self:sync(false)
  end))
end

--- セッションで最初に一覧などを開いたときに一度だけ同期
function Repo:pull_once()
  local o = self:opts()
  if self.state.pulled_once or not o.auto or not o.pull_on_open or not self:is_repo() then
    return
  end
  self:sync(false)
end

--- Neovim 終了時: 未送信の変更を commit して push（待ち時間に上限あり）
function Repo:on_exit()
  local o = self:opts()
  if not o.auto or not o.push_on_exit or not self:is_repo() then
    return
  end
  if self.state.timer then
    self.state.timer:stop()
  end
  if self.spec.before_commit then
    self.spec.before_commit()
  end
  local ok, out = self:run_wait({ "status", "--porcelain" }, 3000)
  if ok and vim.trim(out) ~= "" then
    self:run_wait({ "add", "-A" }, 3000)
    self:run_wait({ "commit", "-q", "-m", self:commit_message() }, 3000)
  end
  local _, remotes = self:run_wait({ "remote" }, 3000)
  if vim.trim(remotes) == "" then
    return
  end
  -- 送っていない commit があるときだけ push
  local has_up = self:run_wait({ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, 3000)
  if has_up then
    local _, ahead = self:run_wait({ "rev-list", "--count", "@{u}..HEAD" }, 3000)
    if vim.trim(ahead) == "0" then
      return
    end
  end
  self:run_wait(has_up and { "push", "-q" } or { "push", "-q", "-u", "origin", "HEAD" }, o.exit_timeout * 1000)
end

--- フォルダをリモートリポジトリにつなぐ（リモートに中身があれば取り込む）
function Repo:init(url, done_cb)
  if not url or url == "" then
    self:notify("リポジトリの URL を指定してください", vim.log.levels.ERROR)
    return
  end
  if self.state.running then
    self:notify("同期中です。少し待ってからもう一度実行してください", vim.log.levels.WARN)
    return
  end
  vim.fn.mkdir(self:dir(), "p")
  self.state.running = true
  local branch
  self:notify("リポジトリを設定しています…")

  chain({
    function(next, fail)
      if self:is_repo() then
        return next()
      end
      self:run({ "init", "-q", "-b", "main" }, function(ok, _, err)
        if not ok then
          return fail(err)
        end
        next()
      end)
    end,
    function(next, fail)
      self:run({ "remote", "get-url", "origin" }, function(exists)
        local args = exists and { "remote", "set-url", "origin", url } or { "remote", "add", "origin", url }
        self:run(args, function(ok, _, err)
          if not ok then
            return fail(err)
          end
          next()
        end)
      end)
    end,
    function(next, fail)
      self:step_commit()(next, function(err)
        fail("commit できません。git config --global user.name / user.email を設定してください\n" .. err)
      end)
    end,
    function(next)
      self:run({ "symbolic-ref", "--short", "HEAD" }, function(_, out)
        branch = out ~= "" and out or "main"
        next()
      end)
    end,
    function(next, fail)
      self:run({ "fetch", "-q", "origin" }, function(ok, _, err)
        if not ok then
          return fail("リモートに接続できません。URL と認証（一度ターミナルで git push できるか）を確認してください\n" .. err)
        end
        next()
      end)
    end,
    function(next, fail)
      self:run({ "rev-parse", "--verify", "-q", "origin/" .. branch }, function(exists)
        if not exists then
          return next()
        end
        -- まだ何も commit していなければ、リモートの内容をそのまま使う
        self:run({ "rev-parse", "--verify", "-q", "HEAD" }, function(has_head)
          local args = has_head
              and { "pull", "-q", "--no-rebase", "--allow-unrelated-histories", "--no-edit", "origin", branch }
            or { "reset", "-q", "--hard", "origin/" .. branch }
          self:run(args, function(ok, out, err)
            if not ok then
              return fail("リモートの内容と競合しました。ターミナルで解決してください\n" .. (err ~= "" and err or out))
            end
            next()
          end)
        end)
      end)
    end,
    function(next, fail)
      -- フォルダもリモートも空なら、push できるよう最初の commit を作る
      self:run({ "rev-parse", "--verify", "-q", "HEAD" }, function(has_head)
        if has_head then
          return next()
        end
        self:run({ "commit", "-q", "--allow-empty", "-m", "memo: init" }, function(ok, out, err)
          if not ok then
            return fail("commit できません。git config --global user.name / user.email を設定してください\n" .. (err ~= "" and err or out))
          end
          next()
        end)
      end)
    end,
    function(next, fail)
      self:run({ "push", "-q", "-u", "origin", branch }, function(ok, out, err)
        if not ok then
          return fail("push に失敗しました\n" .. (err ~= "" and err or out))
        end
        next()
      end)
    end,
  }, function(ok, msg)
    self.state.running = false
    self.state.pulled_once = true
    if ok then
      self.state.conflict = false
      refresh_ui()
      self:notify(("%s を %s と同期しました"):format(self:dir(), url))
      if done_cb then
        done_cb()
      end
    else
      self:notify(msg, vim.log.levels.ERROR)
    end
  end)
end

---------------------------------------------------------------------------
-- 個人と共有の 2 つのリポジトリ
---------------------------------------------------------------------------
local function shared_enabled()
  return require("memo.store").shared_enabled()
end

--- 個人のリポジトリに shared/ が入らないよう .gitignore に書く
local function ensure_ignore()
  if not shared_enabled() then
    return
  end
  local path = config.options.dir .. "/.gitignore"
  local entry = config.options.shared.dir .. "/"
  local lines = vim.uv.fs_stat(path) and vim.fn.readfile(path) or {}
  for _, l in ipairs(lines) do
    if vim.trim(l) == entry or vim.trim(l) == "/" .. entry then
      return
    end
  end
  table.insert(lines, entry)
  vim.fn.writefile(lines, path)
end
M.ensure_ignore = ensure_ignore

M.main = new_repo({
  label = "",
  dir = function()
    return config.options.dir
  end,
  opts = function()
    return config.options.sync
  end,
  before_commit = ensure_ignore,
})

M.shared = new_repo({
  label = "共有",
  quiet_if_missing = true,
  dir = function()
    return require("memo.store").shared_dir()
  end,
  opts = function()
    return config.options.shared.sync
  end,
})

function M.repos()
  local r = { M.main }
  if shared_enabled() then
    table.insert(r, M.shared)
  end
  return r
end

function M.repo_for(path)
  if path and require("memo.store").is_shared_path(path) then
    return M.shared
  end
  return M.main
end

function M.is_repo()
  return M.main:is_repo()
end

--- 変更のあったファイルのリポジトリを同期予約（path なしなら両方）
function M.schedule(path)
  if path then
    return M.repo_for(path):schedule()
  end
  for _, r in ipairs(M.repos()) do
    r:schedule()
  end
end

function M.sync(manual)
  for _, r in ipairs(M.repos()) do
    r:sync(manual)
  end
end

function M.pull_once()
  for _, r in ipairs(M.repos()) do
    r:pull_once()
  end
end

function M.on_exit()
  for _, r in ipairs(M.repos()) do
    r:on_exit()
  end
end

function M.init(url)
  M.main:init(url)
end

function M.init_shared(url)
  if not shared_enabled() then
    vim.notify("memo: shared.enabled が false です", vim.log.levels.WARN)
    return
  end
  ensure_ignore()
  M.shared:init(url, function()
    M.start_poll()
    -- 個人のリポジトリにも .gitignore の変更を反映
    M.main:schedule()
  end)
end

--- 共有リポジトリを定期的に同期（ほかの人の変更を取り込む）
local poll_timer
function M.start_poll()
  if not shared_enabled() then
    return
  end
  local interval = config.options.shared.sync.poll
  if not interval or interval <= 0 then
    return
  end
  if not poll_timer then
    poll_timer = vim.uv.new_timer()
  end
  poll_timer:stop()
  poll_timer:start(interval * 1000, interval * 1000, vim.schedule_wrap(function()
    if M.shared:is_repo() and not M.shared.state.running then
      M.shared:sync(false)
    end
  end))
end

--- Neovim に戻ってきたとき（30 秒以上たっていれば）共有を同期
function M.on_focus()
  if not shared_enabled() or not M.shared:is_repo() then
    return
  end
  if vim.uv.now() - M.shared.state.last_sync > 30000 then
    M.shared:sync(false)
  end
end

-- テスト用
function M._state()
  return M.main.state
end

return M
