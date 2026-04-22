local M = {}

local MEMBER_NODES = {
  method_declaration      = "method",
  property_declaration    = "property",
  field_declaration       = "field",
  event_field_declaration = "event field",
  event_declaration       = "event",
  constructor_declaration = "constructor",
  destructor_declaration  = "destructor",
  operator_declaration    = "operator",
  indexer_declaration     = "indexer",
  delegate_declaration    = "delegate",
  class_declaration       = "nested class",
  struct_declaration      = "nested struct",
  interface_declaration   = "nested interface",
  enum_declaration        = "nested enum",
  record_declaration      = "nested record",
}

local TYPE_CONTAINERS = {
  class_declaration        = true,
  struct_declaration       = true,
  record_declaration       = true,
  record_struct_declaration = true,
}

local CLASS_KEYWORDS = {
  class_declaration        = "class",
  struct_declaration       = "struct",
  record_declaration       = "record",
  record_struct_declaration = "record struct",
}

-- ── helpers ──────────────────────────────────────────────────────────────────

local function parse(bufnr)
  local p = vim.treesitter.get_parser(bufnr, "c_sharp", { error = false })
  if not p then return nil end
  local trees = p:parse()
  return trees and trees[1]
end

local function node_at(tree, row, col)
  return tree:root():named_descendant_for_range(row, col, row, col)
end

local function ts_text(node, bufnr)
  return vim.treesitter.get_node_text(node, bufnr)
end

-- field_declaration nests the name two levels deep; everything else has an
-- identifier as a direct child.
local function get_member_name(node, bufnr)
  local nt = node:type()
  if nt == "field_declaration" or nt == "event_field_declaration" then
    for child in node:iter_children() do
      if child:type() == "variable_declaration" then
        for c in child:iter_children() do
          if c:type() == "variable_declarator" then
            for cc in c:iter_children() do
              if cc:type() == "identifier" then
                return ts_text(cc, bufnr)
              end
            end
          end
        end
      end
    end
  end
  for child in node:iter_children() do
    if child:type() == "identifier" then
      return ts_text(child, bufnr)
    end
  end
  return nt:gsub("_declaration", "")
end

local function get_member_display(node, bufnr)
  local name = get_member_name(node, bufnr)
  local kind = MEMBER_NODES[node:type()] or node:type()
  if kind == "method" or kind == "constructor" or kind == "destructor" or kind == "operator" then
    return name .. "()"
  end
  return name
end

-- ── tree queries ─────────────────────────────────────────────────────────────

-- Returns the member node that is a DIRECT child of a declaration_list and
-- contains the given position. nil when cursor is not on a member header.
local function find_member_at_cursor(bufnr, pos)
  local tree = parse(bufnr)
  if not tree then return nil end
  local node = node_at(tree, pos[1], pos[2])
  while node do
    local parent = node:parent()
    if parent and parent:type() == "declaration_list" and MEMBER_NODES[node:type()] then
      return node
    end
    node = node:parent()
  end
  return nil
end

local function find_enclosing_class(bufnr, pos)
  local tree = parse(bufnr)
  if not tree then return nil end
  local node = node_at(tree, pos[1], pos[2])
  while node do
    if TYPE_CONTAINERS[node:type()] then return node end
    node = node:parent()
  end
  return nil
end

local function get_all_members(class_node, bufnr)
  local members = {}
  for child in class_node:iter_children() do
    if child:type() == "declaration_list" then
      for member in child:iter_children() do
        if MEMBER_NODES[member:type()] then
          table.insert(members, {
            node    = member,
            name    = get_member_name(member, bufnr),
            display = get_member_display(member, bufnr),
            kind    = MEMBER_NODES[member:type()],
          })
        end
      end
      break
    end
  end
  return members
end

-- Returns (namespace_name, is_file_scoped).
local function get_namespace_info(bufnr)
  local tree = parse(bufnr)
  if not tree then return nil, false end
  for child in tree:root():iter_children() do
    local t = child:type()
    if t == "namespace_declaration" or t == "file_scoped_namespace_declaration" then
      for c in child:iter_children() do
        local ct = c:type()
        if ct == "identifier" or ct == "qualified_name" then
          return ts_text(c, bufnr), t == "file_scoped_namespace_declaration"
        end
      end
    end
  end
  return nil, false
end

local function get_usings(bufnr)
  local tree = parse(bufnr)
  if not tree then return {} end
  local usings = {}
  for child in tree:root():iter_children() do
    if child:type() == "using_directive" then
      usings[#usings + 1] = ts_text(child, bufnr)
    end
  end
  return usings
end

local function get_class_modifiers(class_node, bufnr)
  local mods = {}
  for child in class_node:iter_children() do
    if child:type() == "modifier" then
      mods[#mods + 1] = ts_text(child, bufnr)
    end
  end
  return table.concat(mods, " ")
end

-- ── extraction ───────────────────────────────────────────────────────────────

local function build_partial_content(class_node, class_name, members, bufnr)
  local usings = get_usings(bufnr)
  local ns, is_file_scoped = get_namespace_info(bufnr)
  local mods = get_class_modifiers(class_node, bufnr)
  local kw = CLASS_KEYWORDS[class_node:type()] or "class"

  local function class_decl(extra_indent)
    local parts = {}
    if mods ~= "" then parts[#parts + 1] = mods end
    parts[#parts + 1] = "partial"
    parts[#parts + 1] = kw
    parts[#parts + 1] = class_name
    return extra_indent .. table.concat(parts, " ")
  end

  local member_lines = {}
  for i, m in ipairs(members) do
    local sr = m.node:start()
    local er = m.node:end_()
    local lines = vim.api.nvim_buf_get_lines(bufnr, sr, er + 1, false)
    for _, l in ipairs(lines) do
      member_lines[#member_lines + 1] = l
    end
    if i < #members then
      member_lines[#member_lines + 1] = ""
    end
  end

  local out = {}
  for _, u in ipairs(usings) do out[#out + 1] = u end
  if #usings > 0 then out[#out + 1] = "" end

  if ns then
    if is_file_scoped then
      out[#out + 1] = "namespace " .. ns .. ";"
      out[#out + 1] = ""
      out[#out + 1] = class_decl("")
      out[#out + 1] = "{"
      for _, l in ipairs(member_lines) do out[#out + 1] = l end
      out[#out + 1] = "}"
    else
      out[#out + 1] = "namespace " .. ns
      out[#out + 1] = "{"
      out[#out + 1] = class_decl("    ")
      out[#out + 1] = "    {"
      for _, l in ipairs(member_lines) do out[#out + 1] = l end
      out[#out + 1] = "    }"
      out[#out + 1] = "}"
    end
  else
    out[#out + 1] = class_decl("")
    out[#out + 1] = "{"
    for _, l in ipairs(member_lines) do out[#out + 1] = l end
    out[#out + 1] = "}"
  end

  out[#out + 1] = ""
  return out
end

-- Inserts "partial " before the class/struct/record keyword in the buffer.
local function make_class_partial(bufnr, class_node)
  local CLASS_KWS = { ["class"] = true, ["struct"] = true, ["record"] = true }
  for child in class_node:iter_children() do
    if CLASS_KWS[child:type()] then
      local row, col = child:start()
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
      if line and not line:match("%f[%w]partial%f[%W]") then
        vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, {
          line:sub(1, col) .. "partial " .. line:sub(col + 1),
        })
      end
      return
    end
  end
end

-- Deletes member ranges from the buffer bottom-to-top so earlier positions
-- remain valid. Also eats any immediately following blank lines.
local function remove_members(bufnr, members)
  local sorted = {}
  for _, m in ipairs(members) do sorted[#sorted + 1] = m end
  table.sort(sorted, function(a, b)
    local ar = a.node:start()
    local br = b.node:start()
    return ar > br
  end)

  local total = vim.api.nvim_buf_line_count(bufnr)
  for _, m in ipairs(sorted) do
    local sr = m.node:start()
    local er = m.node:end_()
    local end_row = er + 1
    while end_row < total do
      local next = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1]
      if next and next:match("^%s*$") then
        end_row = end_row + 1
      else
        break
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, sr, end_row, false, {})
    total = total - (end_row - sr)
  end
end

-- ── dialog ───────────────────────────────────────────────────────────────────

local function show_dialog(members, cursor_idx, class_name, dir, on_confirm)
  local selected = {}
  selected[cursor_idx or 1] = true
  local current = cursor_idx or 1
  local custom_filename = nil
  local HEADER = 2  -- header line + blank line

  local function suggested_filename()
    for i, m in ipairs(members) do
      if selected[i] then return class_name .. "." .. m.name .. ".cs" end
    end
    return class_name .. ".Partial.cs"
  end

  local function get_filename() return custom_filename or suggested_filename() end

  local function build_lines()
    local lines = { "  Extract to partial class", "" }
    for i, m in ipairs(members) do
      local check = selected[i] and "[x]" or "[ ]"
      lines[#lines + 1] = string.format("  %s  %-36s %s", check, m.display, m.kind)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  File: " .. get_filename()
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  <Space> toggle · <e> edit file · <CR> confirm · <Esc> cancel"
    return lines
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  local ui = vim.api.nvim_list_uis()[1]
  local width = 65
  local height = #members + 7
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = math.max(0, math.floor((ui.height - height) / 2)),
    col       = math.max(0, math.floor((ui.width - width) / 2)),
    width     = width,
    height    = height,
    style     = "minimal",
    border    = "rounded",
    title     = " Extract to partial ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true

  local function refresh()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, build_lines())
    vim.bo[buf].modifiable = false
    pcall(vim.api.nvim_win_set_cursor, win, { HEADER + current, 0 })
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local o = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "<Esc>", close, o)
  vim.keymap.set("n", "q",     close, o)

  vim.keymap.set("n", "j",      function() if current < #members then current = current + 1; refresh() end end, o)
  vim.keymap.set("n", "<Down>", function() if current < #members then current = current + 1; refresh() end end, o)
  vim.keymap.set("n", "k",      function() if current > 1 then current = current - 1; refresh() end end, o)
  vim.keymap.set("n", "<Up>",   function() if current > 1 then current = current - 1; refresh() end end, o)

  vim.keymap.set("n", "<Space>", function()
    selected[current] = not selected[current]
    refresh()
  end, o)

  vim.keymap.set("n", "e", function()
    vim.ui.input({ prompt = "File name: ", default = get_filename() }, function(input)
      if input and input ~= "" then
        custom_filename = input
        if vim.api.nvim_win_is_valid(win) then refresh() end
      end
    end)
  end, o)

  vim.keymap.set("n", "<CR>", function()
    local sel = {}
    for i, m in ipairs(members) do
      if selected[i] then sel[#sel + 1] = m end
    end
    if #sel == 0 then
      vim.notify("[nvim-dotnet] Select at least one member", vim.log.levels.WARN)
      return
    end
    local fname = get_filename()
    close()
    on_confirm(sel, dir .. "/" .. fname, fname)
  end, o)

  refresh()
end

-- ── public API ───────────────────────────────────────────────────────────────

local function do_extract(bufnr, class_node, sel, full_path, fname)
  local class_name = get_member_name(class_node, bufnr)
  local content    = build_partial_content(class_node, class_name, sel, bufnr)
  vim.fn.writefile(content, full_path)
  make_class_partial(bufnr, class_node)
  remove_members(bufnr, sel)
  vim.cmd("write")
  vim.cmd("vsplit " .. vim.fn.fnameescape(full_path))
  vim.notify(string.format("[nvim-dotnet] Extracted %d member(s) → %s", #sel, fname))
end

M.extract = function()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "cs" then
    vim.notify("[nvim-dotnet] Only works in C# files", vim.log.levels.WARN)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local pos    = { cursor[1] - 1, cursor[2] }

  local class_node = find_enclosing_class(bufnr, pos)
  if not class_node then
    vim.notify("[nvim-dotnet] Cursor is not inside a class", vim.log.levels.WARN)
    return
  end

  local class_name = get_member_name(class_node, bufnr)
  local members    = get_all_members(class_node, bufnr)
  if #members == 0 then
    vim.notify("[nvim-dotnet] No extractable members found", vim.log.levels.WARN)
    return
  end

  local cursor_member = find_member_at_cursor(bufnr, pos)
  local cursor_idx    = 1
  if cursor_member then
    for i, m in ipairs(members) do
      if m.node == cursor_member then cursor_idx = i; break end
    end
  end

  local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h")

  show_dialog(members, cursor_idx, class_name, dir, function(sel, full_path, fname)
    if vim.fn.filereadable(full_path) == 1 then
      vim.ui.select({ "Overwrite", "Cancel" }, { prompt = fname .. " already exists:" }, function(choice)
        if choice == "Overwrite" then do_extract(bufnr, class_node, sel, full_path, fname) end
      end)
    else
      do_extract(bufnr, class_node, sel, full_path, fname)
    end
  end)
end

M._internals = {
  find_member_at_cursor  = find_member_at_cursor,
  find_enclosing_class   = find_enclosing_class,
  get_all_members        = get_all_members,
  get_namespace_info     = get_namespace_info,
  get_usings             = get_usings,
  build_partial_content  = build_partial_content,
  make_class_partial     = make_class_partial,
  remove_members         = remove_members,
  get_member_name        = get_member_name,
}

return M
