local function add(path)
  path = vim.fn.expand(path)
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.runtimepath:prepend(path)
  end
end

add("~/.local/share/nvim/lazy/plenary.nvim")
add("~/.local/share/nvim/lazy/nvim-treesitter")
add("~/Development/ai-projects/nvim-dotnet-refactoring")
