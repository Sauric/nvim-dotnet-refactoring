local M = {}

-- ── LSP symbol kinds ─────────────────────────────────────────────────────────

local SK = vim.lsp.protocol.SymbolKind

local KIND_LABEL = {
  [SK.Method]      = "method",
  [SK.Property]    = "property",
  [SK.Field]       = "field",
  [SK.Constant]    = "constant",
  [SK.Constructor] = "constructor",
  [SK.Event]       = "event",
  [SK.Operator]    = "operator",
  [SK.Class]       = "nested class",
  [SK.Struct]      = "nested struct",
  [SK.Interface]   = "nested interface",
  [SK.Enum]        = "nested enum",
}

local CONTAINER_KINDS = { [SK.Class] = true, [SK.Struct] = true }

-- ── LSP fetch ────────────────────────────────────────────────────────────────

local function get_document_symbols(bufnr, timeout_ms)
  local params  = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local results = vim.lsp.buf_request_sync(
    bufnr, "textDocument/documentSymbol", params, timeout_ms or 2000
  )
  if not results then return nil end
  for _, resp in pairs(results) do
    if resp.result and #resp.result > 0 then return resp.result end
  end
  return nil
end

-- ── range helpers (pure — no side effects, easy to test) ─────────────────────

-- LSP ranges are 0-indexed {start={line,character}, end={line,character}}.
local function pos_in_range(pos, range)
  local sl, sc = range.start.line, range.start.character
  local el, ec = range["end"].line, range["end"].character
  local row, col = pos[1], pos[2]
  if row < sl or row > el then return false end
  if row == sl and col < sc then return false end
  if row == el and col > ec then return false end
  return true
end

-- Walks the symbol tree recursively; returns the first Class/Struct whose
-- range contains pos.
-- Recurse into children before accepting the parent so the innermost
-- (most specific) class is returned when classes are nested.
local function find_class_by_cursor(symbols, pos)
  for _, sym in ipairs(symbols) do
    if sym.children then
      local found = find_class_by_cursor(sym.children, pos)
      if found then return found end
    end
    if CONTAINER_KINDS[sym.kind] and pos_in_range(pos, sym.range) then
      return sym
    end
  end
end

-- Returns the direct child of class_sym whose range contains pos, or nil.
local function find_member_by_cursor(class_sym, pos)
  for _, child in ipairs(class_sym.children or {}) do
    if KIND_LABEL[child.kind] and pos_in_range(pos, child.range) then
      return child
    end
  end
end

-- ── symbol → member struct ───────────────────────────────────────────────────

local function symbol_to_member(sym)
  local kind = KIND_LABEL[sym.kind] or "member"
  -- Roslyn includes the full signature in sym.name, e.g. "Multiply(int, int) : int".
  -- Strip everything from the first "(" or ":" so the filename stays clean.
  local name = (sym.name:match("^([%w_]+)") or sym.name):gsub("%s+$", "")
  return { symbol = sym, name = name, display = sym.name, kind = kind }
end

-- ── file context (buffer line scan — no Treesitter needed) ───────────────────

-- Returns usings (list of strings), namespace (string|nil), is_file_scoped (bool).
local function get_file_context(bufnr)
  local lines                          = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local usings, namespace, is_file_scoped = {}, nil, false
  for _, line in ipairs(lines) do
    if line:match("^using ") then
      usings[#usings + 1] = line
    elseif line:match("^namespace ") then
      namespace      = line:match("^namespace%s+([%w%.]+)")
      is_file_scoped = line:match(";%s*$") ~= nil
    end
  end
  return usings, namespace, is_file_scoped
end

-- ── extraction helpers ───────────────────────────────────────────────────────

local function get_class_modifiers(bufnr, class_sym)
  local row  = class_sym.range.start.line
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local mods = {}
  for _, kw in ipairs({ "public", "internal", "protected", "private",
                        "abstract", "sealed", "static" }) do
    if line:match("%f[%w]" .. kw .. "%f[%W]") then
      mods[#mods + 1] = kw
    end
  end
  return table.concat(mods, " ")
end

local function make_class_partial(bufnr, class_sym)
  local row  = class_sym.range.start.line
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line or line:match("%f[%w]partial%f[%W]") then return end
  -- Try compound keywords before their components so "record struct" is not
  -- split into two separate substitutions.
  local patterns = {
    "(%f[%w])(record%s+struct%f[%W])",
    "(%f[%w])(record%s+class%f[%W])",
    "(%f[%w])(record%f[%W])",
    "(%f[%w])(struct%f[%W])",
    "(%f[%w])(class%f[%W])",
  }
  for _, pat in ipairs(patterns) do
    local new_line, n = line:gsub(pat, "%1partial %2", 1)
    if n > 0 then
      vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { new_line })
      return
    end
  end
end

local function remove_members(bufnr, members)
  local sorted = vim.tbl_map(function(m) return m end, members)
  table.sort(sorted, function(a, b)
    return a.symbol.range.start.line > b.symbol.range.start.line
  end)
  local total = vim.api.nvim_buf_line_count(bufnr)
  for _, m in ipairs(sorted) do
    local sr      = m.symbol.range.start.line
    local er      = m.symbol.range["end"].line
    local end_row = er + 1
    while end_row < total do
      local nxt = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1]
      if nxt and nxt:match("^%s*$") then end_row = end_row + 1 else break end
    end
    vim.api.nvim_buf_set_lines(bufnr, sr, end_row, false, {})
    total = total - (end_row - sr)
  end
end

local CLASS_KW = { class_declaration = "class", struct_declaration = "struct",
                   record_declaration = "record", record_struct_declaration = "record struct" }

local function build_partial_content(class_sym, class_name, members, bufnr)
  local usings, ns, is_file_scoped = get_file_context(bufnr)

  -- Infer keyword from the class declaration line
  local class_row  = class_sym.range.start.line
  local class_line = vim.api.nvim_buf_get_lines(bufnr, class_row, class_row + 1, false)[1] or ""
  local kw = class_line:match("%f[%w](record%s+struct)%f[%W]")
          or class_line:match("%f[%w](record)%f[%W]")
          or class_line:match("%f[%w](struct)%f[%W]")
          or "class"

  local function class_decl(indent)
    return indent .. "partial " .. kw .. " " .. class_name
  end

  local member_lines = {}
  for i, m in ipairs(members) do
    local sr = m.symbol.range.start.line
    local er = m.symbol.range["end"].line
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, sr, er + 1, false)) do
      member_lines[#member_lines + 1] = l
    end
    if i < #members then member_lines[#member_lines + 1] = "" end
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

-- ── dialog ───────────────────────────────────────────────────────────────────

local function show_dialog(members, cursor_idx, class_name, dir, on_confirm)
  local selected = {}
  selected[cursor_idx or 1] = true
  local current       = cursor_idx or 1
  local custom_fname  = nil
  local HEADER        = 2

  local function suggested_filename()
    for i, m in ipairs(members) do
      if selected[i] then return class_name .. "." .. m.name .. ".cs" end
    end
    return class_name .. ".Partial.cs"
  end

  local function get_filename() return custom_fname or suggested_filename() end

  local function build_lines()
    local lines = { "  Extract to partial class", "" }
    for i, m in ipairs(members) do
      local check = selected[i] and "[x]" or "[ ]"
      lines[#lines + 1] = string.format("  %s  %-36s %s", check, m.display, m.kind)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  File: " .. get_filename()
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Space toggle · e edit file · Enter confirm · Esc cancel"
    return lines
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  local ui     = vim.api.nvim_list_uis()[1]
  local width  = 65
  local height = #members + 7
  local win    = vim.api.nvim_open_win(buf, true, {
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
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  local o = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "<Esc>",   close, o)
  vim.keymap.set("n", "q",       close, o)
  vim.keymap.set("n", "j",       function() if current < #members then current = current + 1; refresh() end end, o)
  vim.keymap.set("n", "<Down>",  function() if current < #members then current = current + 1; refresh() end end, o)
  vim.keymap.set("n", "k",       function() if current > 1 then current = current - 1; refresh() end end, o)
  vim.keymap.set("n", "<Up>",    function() if current > 1 then current = current - 1; refresh() end end, o)

  vim.keymap.set("n", "<Space>", function()
    selected[current] = not selected[current]
    refresh()
  end, o)

  vim.keymap.set("n", "e", function()
    vim.ui.input({ prompt = "File name: ", default = get_filename() }, function(input)
      if input and input ~= "" then
        custom_fname = input
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

local function do_extract(bufnr, class_sym, sel, full_path, fname)
  local content = build_partial_content(class_sym, class_sym.name, sel, bufnr)
  vim.fn.writefile(content, full_path)
  make_class_partial(bufnr, class_sym)
  remove_members(bufnr, sel)
  vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
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

  local symbols = get_document_symbols(bufnr)
  if not symbols then
    vim.notify("[nvim-dotnet] LSP not ready — no document symbols", vim.log.levels.WARN)
    return
  end

  local class_sym = find_class_by_cursor(symbols, pos)
  if not class_sym then
    vim.notify("[nvim-dotnet] Cursor is not inside a class", vim.log.levels.WARN)
    return
  end

  local members = vim.tbl_map(symbol_to_member,
    vim.tbl_filter(function(s) return KIND_LABEL[s.kind] ~= nil end,
      class_sym.children or {}))

  if #members == 0 then
    vim.notify("[nvim-dotnet] No extractable members found", vim.log.levels.WARN)
    return
  end

  local cursor_sym = find_member_by_cursor(class_sym, pos)
  local cursor_idx = 1
  if cursor_sym then
    for i, m in ipairs(members) do
      if m.symbol == cursor_sym then cursor_idx = i; break end
    end
  end

  local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h")

  show_dialog(members, cursor_idx, class_sym.name, dir, function(sel, full_path, fname)
    if vim.fn.filereadable(full_path) == 1 then
      vim.ui.select({ "Overwrite", "Cancel" }, { prompt = fname .. " already exists:" },
        function(choice)
          if choice == "Overwrite" then do_extract(bufnr, class_sym, sel, full_path, fname) end
        end)
    else
      do_extract(bufnr, class_sym, sel, full_path, fname)
    end
  end)
end

M._internals = {
  pos_in_range          = pos_in_range,
  find_class_by_cursor  = find_class_by_cursor,
  find_member_by_cursor = find_member_by_cursor,
  symbol_to_member      = symbol_to_member,
  get_file_context      = get_file_context,
  get_class_modifiers   = get_class_modifiers,
  make_class_partial    = make_class_partial,
  remove_members        = remove_members,
  build_partial_content = build_partial_content,
  KIND_LABEL            = KIND_LABEL,
  SK                    = SK,
}

return M
