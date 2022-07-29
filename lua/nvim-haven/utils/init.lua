local M = {}

function string:ends_with(suffix)
  return suffix == "" or self:sub(-(#suffix)) == suffix
end

function string:split(sep)
  sep = sep or ":"
  local fields = {}
  local pattern = string.format("([^%s]+)", sep)
  _ =
    self:gsub(
    pattern,
    function(c)
      fields[#fields + 1] = c
    end
  )
  return fields
end

function string:starts_with(prefix)
  return self:sub(1, #prefix) == prefix
end

function table.reverse(self)
  local n = #self
  local i = 1
  while i < n do
    self[i], self[n] = self[n], self[i]
    i = i + 1
    n = n - 1
  end
  return self
end

function M.iff(b, l, r)
  if b then
    return l
  end

  return r
end

M.is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
M.directory_sep = M.iff(M.is_windows, "\\\\", "/")
M.not_directory_sep = M.iff(M.is_windows, "/", "\\\\")

function M.create_path(...)
  local Path = require "plenary.path"
  local ret =
    Path:new({...}):absolute():gsub(M.not_directory_sep, M.directory_sep):gsub(
    M.directory_sep .. M.directory_sep,
    M.directory_sep
  )
  return ret
end

return M
