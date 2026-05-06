if vim.g.loaded_alma_nvim == 1 then
  return
end
vim.g.loaded_alma_nvim = 1

require("alma").setup()
