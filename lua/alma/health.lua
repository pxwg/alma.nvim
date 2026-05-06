local rest = require("alma.rest")
local util = require("alma.util")

local M = {}

local function report_line(ok, label, detail)
  return {
    ok = ok,
    text = (ok and "OK " or "WARN ") .. label .. (detail and (": " .. detail) or ""),
  }
end

function M.report(callback)
  local lines = {
    report_line(util.version_at_least(0, 12, 0), "Neovim >= 0.12.0", vim.inspect(vim.version())),
    report_line(vim.fn.executable("curl") == 1, "curl executable", vim.fn.exepath("curl")),
  }
  rest.health(function(data, err)
    if data then
      table.insert(lines, report_line(true, "Alma API", vim.inspect(data)))
    else
      table.insert(lines, report_line(false, "Alma API", tostring(err)))
    end
    callback(lines)
  end)
end

function M.command()
  M.report(function(lines)
    local level = vim.log.levels.INFO
    for _, line in ipairs(lines) do
      if not line.ok then
        level = vim.log.levels.WARN
      end
    end
    util.notify(table.concat(vim.tbl_map(function(line)
      return line.text
    end, lines), "\n"), level)
  end)
end

function M.check()
  vim.health.start("alma.nvim")
  if util.version_at_least(0, 12, 0) then
    vim.health.ok("Neovim version is >= 0.12.0")
  else
    vim.health.error("alma.nvim requires Neovim >= 0.12.0")
  end
  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl found: " .. vim.fn.exepath("curl"))
  else
    vim.health.error("curl is required for Alma REST requests")
  end
end

return M
