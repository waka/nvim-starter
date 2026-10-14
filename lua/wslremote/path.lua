-- wsl://<distro>/<absolute path> 形式の名前を扱う
local M = {}

M.scheme = "wsl"
M.prefix = "wsl://"

function M.is_remote(name)
  return type(name) == "string" and name:sub(1, #M.prefix) == M.prefix
end

--- "wsl://Ubuntu/home/you/x.lua" -> "Ubuntu", "/home/you/x.lua"
function M.parse(name)
  if not M.is_remote(name) then
    return nil
  end
  -- Windows でバッファ名の区切りが \ になっていても受け付ける
  local rest = name:sub(#M.prefix + 1):gsub("\\", "/")
  local host, path = rest:match("^([^/]+)(/.*)$")
  if not host then
    host, path = rest, "/"
  end
  path = path:gsub("//+", "/")
  return host, path
end

function M.make(host, path)
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  return M.prefix .. host .. path
end

function M.join(dir, name)
  if dir:sub(-1) == "/" then
    return dir .. name
  end
  return dir .. "/" .. name
end

function M.parent(path)
  local p = path:gsub("/+$", "")
  local parent = p:match("^(.*)/[^/]*$")
  if not parent or parent == "" then
    return "/"
  end
  return parent
end

function M.basename(path)
  return (path:gsub("/+$", ""):match("([^/]*)$"))
end

--- dir 配下なら相対パスを返す
function M.relative(path, dir)
  dir = dir:gsub("/+$", "")
  if path == dir then
    return "."
  end
  if path:sub(1, #dir + 1) == dir .. "/" then
    return path:sub(#dir + 2)
  end
  return nil
end

return M
