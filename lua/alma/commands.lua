local M = {}

local alma_subcommands = {
  open = true,
  toggle = true,
  float = true,
  sidebar = true,
}

local function current_thread_id()
  local thread = require("alma.state").thread_for_buf(0)
  return thread and thread.id or nil
end

function M.setup()
  vim.api.nvim_create_user_command("Alma", function(opts)
    local subcommand = opts.fargs[1] or "open"
    if subcommand == "" then
      subcommand = "open"
    end
    if not alma_subcommands[subcommand] then
      error("Unknown Alma subcommand: " .. tostring(subcommand))
    end
    local thread_id = opts.fargs[2]
    require("alma")[subcommand]({ thread_id = thread_id })
  end, {
    nargs = "*",
    complete = function(arg_lead, cmdline)
      local args = vim.split(cmdline, "%s+", { trimempty = true })
      if #args <= 2 then
        local matches = {}
        for name, _ in pairs(alma_subcommands) do
          if name:find(arg_lead, 1, true) == 1 then
            table.insert(matches, name)
          end
        end
        table.sort(matches)
        return matches
      end
      return {}
    end,
    desc = "Open, toggle, or choose an Alma chat window layout",
  })

  vim.api.nvim_create_user_command("AlmaHealth", function()
    require("alma.health").command()
  end, { desc = "Check Alma API and alma.nvim runtime health" })

  vim.api.nvim_create_user_command("AlmaThreadOpen", function(opts)
    require("alma").open_thread(opts.args)
  end, {
    nargs = 1,
    complete = function()
      return {}
    end,
    desc = "Open an Alma thread buffer",
  })

  vim.api.nvim_create_user_command("AlmaThreadRefresh", function()
    local thread_id = current_thread_id()
    if thread_id then
      require("alma.effects").refresh(thread_id)
    end
  end, { desc = "Refetch current Alma thread" })

  vim.api.nvim_create_user_command("AlmaSubmit", function(opts)
    require("alma.buffers").submit_current(opts.args)
  end, {
    nargs = "*",
    desc = "Submit prompt text from the current Alma buffer",
  })

  vim.api.nvim_create_user_command("AlmaStop", function()
    local thread_id = current_thread_id()
    if thread_id then
      require("alma.effects").stop(thread_id)
    end
  end, { desc = "Stop current Alma generation" })

  vim.api.nvim_create_user_command("AlmaThreads", function()
    require("alma.pickers").threads()
  end, { desc = "Pick an Alma thread" })

  vim.api.nvim_create_user_command("AlmaProjects", function()
    require("alma.pickers").projects()
  end, { desc = "Pick an Alma project/workspace" })

  vim.api.nvim_create_user_command("AlmaModels", function()
    require("alma.pickers").models()
  end, { desc = "Pick Alma model/reasoning defaults" })

  vim.api.nvim_create_user_command("AlmaTools", function()
    require("alma.pickers").tools()
  end, { desc = "Pick Alma tools" })

  vim.api.nvim_create_user_command("AlmaSkills", function()
    require("alma.pickers").skills()
  end, { desc = "Pick Alma skills" })

  vim.api.nvim_create_user_command("AlmaMCPServers", function()
    require("alma.pickers").mcp_servers()
  end, { desc = "Pick Alma MCP servers" })

  vim.api.nvim_create_user_command("AlmaBuffers", function()
    require("alma.pickers").buffers()
  end, { desc = "Pick open Alma buffers" })

  vim.api.nvim_create_user_command("AlmaEvents", function()
    require("alma.pickers").events()
  end, { desc = "Pick Alma WS/debug events" })

  vim.api.nvim_create_user_command("AlmaToolDetails", function()
    require("alma.ui.detail").open_under_cursor()
  end, { desc = "Open detail buffer for Alma block under cursor" })

  vim.api.nvim_create_user_command("AlmaQuickfix", function()
    require("alma.ui.detail").quickfix_thread()
  end, { desc = "Populate quickfix from current Alma thread" })

  vim.api.nvim_create_user_command("AlmaBlockQuickfix", function()
    require("alma.ui.detail").quickfix_under_cursor()
  end, { desc = "Populate quickfix from Alma block under cursor" })

  vim.api.nvim_create_user_command("AlmaDiff", function()
    require("alma.ui.detail").diff_under_cursor()
  end, { desc = "Open diff preview for Alma block under cursor" })
end

return M
