package = "alma.nvim"
version = "scm-1"

source = {
  url = "git+file://.",
}

description = {
  summary = "Native Neovim frontend for Alma local runtime",
  detailed = [[
alma.nvim maps one Alma thread to one Neovim buffer, uses WebSocket for fast
events/submission, and REST for final message truth.
]],
  homepage = "https://example.invalid/alma.nvim",
  license = "MIT",
}

dependencies = {
  "lua >= 5.1",
}

build = {
  type = "builtin",
  modules = {
    ["alma"] = "lua/alma/init.lua",
    ["alma.buffers"] = "lua/alma/buffers.lua",
    ["alma.catalog"] = "lua/alma/catalog.lua",
    ["alma.commands"] = "lua/alma/commands.lua",
    ["alma.completion.blink"] = "lua/alma/completion/blink.lua",
    ["alma.config"] = "lua/alma/config.lua",
    ["alma.core"] = "lua/alma/core.lua",
    ["alma.effects"] = "lua/alma/effects.lua",
    ["alma.events"] = "lua/alma/events.lua",
    ["alma.health"] = "lua/alma/health.lua",
    ["alma.parser"] = "lua/alma/parser.lua",
    ["alma.pickers"] = "lua/alma/pickers.lua",
    ["alma.rest"] = "lua/alma/rest.lua",
    ["alma.state"] = "lua/alma/state.lua",
    ["alma.ui.detail"] = "lua/alma/ui/detail.lua",
    ["alma.ui.metadata"] = "lua/alma/ui/metadata.lua",
    ["alma.ui.render"] = "lua/alma/ui/render.lua",
    ["alma.ui.tokens"] = "lua/alma/ui/tokens.lua",
    ["alma.ui.window"] = "lua/alma/ui/window.lua",
    ["alma.util"] = "lua/alma/util.lua",
    ["alma.ws"] = "lua/alma/ws.lua",
  },
  copy_directories = {
    "doc",
    "plugin",
    "scripts",
  },
}
