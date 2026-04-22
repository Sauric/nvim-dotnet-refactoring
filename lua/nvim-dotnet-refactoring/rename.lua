local M = {}

local TYPE_NODES = {
  class_declaration = true,
  struct_declaration = true,
  interface_declaration = true,
  enum_declaration = true,
  record_declaration = true,
  record_struct_declaration = true,
}

-- Entering one of these means the cursor is inside a body, not a type header.
local BODY_NODES = {
  block = true,
  accessor_list = true,
}

local uv = vim.uv or vim.loop

-- When bufnr+pos are given (0-indexed), queries the parsed tree directly so
-- the function works without a window or attached language tree (e.g. in tests).
-- In normal use, omit both and it falls back to vim.treesitter.get_node().
local function find_type_node_at_cursor(bufnr, pos)
  local node
  if bufnr and pos then
    local parser = vim.treesitter.get_parser(bufnr, "c_sharp", { error = false })
    if not parser then return end
    local tree = parser:parse()[1]
    if not tree then return end
    node = tree:root():named_descendant_for_range(pos[1], pos[2], pos[1], pos[2])
  else
    node = vim.treesitter.get_node()
  end
  while node do
    if BODY_NODES[node:type()] then
      return nil
    end
    if TYPE_NODES[node:type()] then
      return node
    end
    node = node:parent()
  end
end

local function get_identifier(node, bufnr)
  bufnr = bufnr or 0
  for child in node:iter_children() do
    if child:type() == "identifier" then
      return vim.treesitter.get_node_text(child, bufnr)
    end
  end
end

-- "MyClass.partial.cs" -> "MyClass"
local function file_stem(filename)
  return (filename or vim.fn.expand("%:t")):match("^([^.]+)")
end

local function do_rename_file(old_name, new_name)
  local old_path = vim.fn.expand("%:p")
  local dir = vim.fn.fnamemodify(old_path, ":h")
  local filename = vim.fn.expand("%:t")
  local new_filename = filename:gsub("^" .. vim.pesc(old_name), new_name, 1)
  local new_path = dir .. "/" .. new_filename

  local ok = uv.fs_rename(old_path, new_path)
  if not ok then
    vim.notify("[nvim-dotnet] Failed to rename file", vim.log.levels.ERROR)
    return
  end

  local old_bufnr = vim.fn.bufnr(old_path)
  vim.cmd("keepalt edit " .. vim.fn.fnameescape(new_path))
  if old_bufnr ~= -1 and old_bufnr ~= vim.fn.bufnr(new_path) then
    vim.api.nvim_buf_delete(old_bufnr, { force = true })
  end

  vim.notify(string.format("[nvim-dotnet] %s → %s", filename, new_filename))
end

local function apply_rename(new_name, old_name, will_rename_file)
  local client = vim.lsp.get_clients({ bufnr = 0, method = "textDocument/rename" })[1]
  if not client then
    vim.notify("[nvim-dotnet] No LSP client supports rename", vim.log.levels.WARN)
    return
  end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.newName = new_name

  client.request("textDocument/rename", params, function(err, result)
    if err then
      vim.notify("[nvim-dotnet] Rename failed: " .. (err.message or "unknown"), vim.log.levels.ERROR)
      return
    end
    if result then
      vim.lsp.util.apply_workspace_edit(result, client.offset_encoding)
    end
    if will_rename_file then
      -- defer so buffer writes from workspace edit settle first
      vim.schedule(function()
        do_rename_file(old_name, new_name)
      end)
    end
  end, 0)
end

M.rename = function()
  if vim.bo.filetype ~= "cs" then
    vim.lsp.buf.rename()
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local type_node = find_type_node_at_cursor()
  local old_name = type_node and get_identifier(type_node, bufnr)
  local stem = file_stem()
  local will_rename_file = old_name ~= nil and old_name == stem
  local default = old_name or vim.fn.expand("<cword>")

  local prompt = will_rename_file
    and string.format("Rename '%s' (+ file): ", default)
    or string.format("Rename '%s': ", default)

  vim.ui.input({ prompt = prompt, default = default }, function(new_name)
    if not new_name or new_name == "" or new_name == default then
      return
    end
    apply_rename(new_name, old_name, will_rename_file)
  end)
end

M._internals = {
  file_stem = file_stem,
  get_identifier = get_identifier,
  find_type_node_at_cursor = find_type_node_at_cursor,
  do_rename_file = do_rename_file,
}

return M
