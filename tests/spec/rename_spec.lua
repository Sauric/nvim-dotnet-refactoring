local rename = require("nvim-dotnet-refactoring.rename")
local h = rename._internals

local SK = vim.lsp.protocol.SymbolKind

-- ── helpers ──────────────────────────────────────────────────────────────────

-- name_sc: optional column where the name token starts (defaults to sc).
-- Needed when leading modifiers push the name right of the declaration start.
local function make_sym(name, kind, sl, sc, el, ec, name_sc_or_children, maybe_children)
  local name_sc, children
  if type(name_sc_or_children) == "number" then
    name_sc  = name_sc_or_children
    children = maybe_children or {}
  else
    name_sc  = sc
    children = name_sc_or_children or {}
  end
  return {
    name           = name,
    kind           = kind,
    range          = { start = { line = sl, character = sc }, ["end"] = { line = el, character = ec } },
    selectionRange = { start = { line = sl, character = name_sc }, ["end"] = { line = sl, character = name_sc + #name } },
    children       = children,
  }
end

-- ---------------------------------------------------------------------------
-- file_stem
-- ---------------------------------------------------------------------------
describe("file_stem", function()
  it("extracts stem from a plain .cs file", function()
    assert.equals("MyClass", h.file_stem("MyClass.cs"))
  end)

  it("extracts only the first segment from a compound name", function()
    assert.equals("MyClass", h.file_stem("MyClass.partial.cs"))
  end)

  it("handles interface naming convention", function()
    assert.equals("IMyService", h.file_stem("IMyService.cs"))
  end)

  it("handles a three-segment compound name", function()
    assert.equals("OrderService", h.file_stem("OrderService.queries.generated.cs"))
  end)

  it("returns the whole string when there is no dot", function()
    assert.equals("MyClass", h.file_stem("MyClass"))
  end)
end)

-- ---------------------------------------------------------------------------
-- find_type_by_cursor
-- ---------------------------------------------------------------------------
describe("find_type_by_cursor", function()
  -- public class OrderService  (line 0; "OrderService" starts at col 13)
  -- {                          (line 1)
  --   public void DoWork() {   (line 2)
  --     var x = 1;             (line 3)
  --   }                        (line 4)
  -- }                          (line 5)
  local class_sym = make_sym("OrderService", SK.Class, 0, 0, 5, 1, 13, {
    make_sym("DoWork", SK.Method, 2, 2, 4, 3),
  })
  local symbols = { class_sym }

  it("finds a class when cursor is on its name", function()
    -- selectionRange for "OrderService" is col 13..24; cursor at col 15
    local sym = h.find_type_by_cursor(symbols, { 0, 15 })
    assert.is_not_nil(sym)
    assert.equals("OrderService", sym.name)
  end)

  it("finds a struct when cursor is on its name", function()
    local struct_sym = make_sym("Point", SK.Struct, 0, 0, 3, 1)
    local sym = h.find_type_by_cursor({ struct_sym }, { 0, 2 })
    assert.is_not_nil(sym)
    assert.equals("Point", sym.name)
  end)

  it("finds an interface when cursor is on its name", function()
    local iface_sym = make_sym("IRepository", SK.Interface, 0, 0, 2, 1)
    local sym = h.find_type_by_cursor({ iface_sym }, { 0, 5 })
    assert.is_not_nil(sym)
    assert.equals("IRepository", sym.name)
  end)

  it("finds an enum when cursor is on its name", function()
    local enum_sym = make_sym("Status", SK.Enum, 0, 0, 3, 1)
    local sym = h.find_type_by_cursor({ enum_sym }, { 0, 3 })
    assert.is_not_nil(sym)
    assert.equals("Status", sym.name)
  end)

  it("returns nil when cursor is inside a method body", function()
    -- row 3, col 4 = "var x = 1;" — not on any type's selectionRange
    local sym = h.find_type_by_cursor(symbols, { 3, 4 })
    assert.is_nil(sym)
  end)

  it("returns nil when cursor is on the 'class' keyword, not the name", function()
    -- selectionRange for "OrderService" is col 13..24; col 7 is on 'class' keyword
    local sym = h.find_type_by_cursor(symbols, { 0, 7 })
    assert.is_nil(sym)
  end)

  it("finds a nested type by recursing into children", function()
    local inner = make_sym("Inner", SK.Class, 2, 2, 4, 3)
    local outer = make_sym("Outer", SK.Class, 0, 0, 6, 1, { inner })
    local sym = h.find_type_by_cursor({ outer }, { 2, 4 })
    assert.is_not_nil(sym)
    assert.equals("Inner", sym.name)
  end)

  it("returns nil for an empty symbol list", function()
    assert.is_nil(h.find_type_by_cursor({}, { 0, 0 }))
  end)

  it("matches cursor on the very first character of the name (left boundary)", function()
    -- selectionRange for "OrderService" is col 13..24; col 13 is first char
    local sym = h.find_type_by_cursor(symbols, { 0, 13 })
    assert.is_not_nil(sym)
    assert.equals("OrderService", sym.name)
  end)

  it("matches cursor on the very last character of the name (right boundary)", function()
    -- "OrderService" is 12 chars; last char is at col 13+11=24
    local sym = h.find_type_by_cursor(symbols, { 0, 24 })
    assert.is_not_nil(sym)
    assert.equals("OrderService", sym.name)
  end)

  it("returns nil when cursor is past the end of the name", function()
    -- selectionRange end.character = 13+12 = 25; pos_in_range is inclusive on ec,
    -- so col 25 is the last accepted position. Col 26 is the first that misses.
    assert.is_nil(h.find_type_by_cursor(symbols, { 0, 26 }))
  end)

  it("finds the correct type when two sibling types share the same file", function()
    local cls1 = make_sym("Alpha", SK.Class,     0, 0, 4, 1, 13)
    local cls2 = make_sym("Beta",  SK.Interface, 6, 0, 9, 1, 17)
    -- cursor on "Beta"'s selectionRange
    local sym = h.find_type_by_cursor({ cls1, cls2 }, { 6, 18 })
    assert.is_not_nil(sym)
    assert.equals("Beta", sym.name)
  end)

  it("finds a type nested inside a namespace symbol", function()
    -- Roslyn wraps top-level types in a Namespace symbol (SK.Namespace = 3)
    local inner_cls = make_sym("MyService", SK.Class, 2, 0, 8, 1, 7)
    local ns_sym    = {
      name = "MyApp", kind = SK.Namespace or 3,
      range          = { start = { line = 0, character = 0 }, ["end"] = { line = 10, character = 0 } },
      selectionRange = { start = { line = 0, character = 10 }, ["end"] = { line = 0, character = 15 } },
      children       = { inner_cls },
    }
    local sym = h.find_type_by_cursor({ ns_sym }, { 2, 9 })
    assert.is_not_nil(sym)
    assert.equals("MyService", sym.name)
  end)
end)

-- ---------------------------------------------------------------------------
-- do_rename_file
-- ---------------------------------------------------------------------------
describe("do_rename_file", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  local function open_tmp_file(filename, content)
    local path = tmp .. "/" .. filename
    vim.fn.writefile({ content }, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    return path
  end

  it("renames a simple .cs file on disk and updates the buffer", function()
    local old_path = open_tmp_file("MyClass.cs", "public class MyClass {}")
    h.do_rename_file("MyClass", "OrderService")
    assert.equals(1, vim.fn.filereadable(tmp .. "/OrderService.cs"))
    assert.equals(0, vim.fn.filereadable(old_path))
    assert.equals("OrderService.cs", vim.fn.expand("%:t"))
  end)

  it("preserves middle segments of compound filenames", function()
    local old_path = open_tmp_file("MyClass.partial.cs", "public partial class MyClass {}")
    h.do_rename_file("MyClass", "OrderService")
    assert.equals(1, vim.fn.filereadable(tmp .. "/OrderService.partial.cs"))
    assert.equals(0, vim.fn.filereadable(old_path))
  end)

  it("does not touch unrelated files in the same directory", function()
    open_tmp_file("OtherClass.cs", "public class OtherClass {}")
    open_tmp_file("MyClass.cs", "public class MyClass {}")
    h.do_rename_file("MyClass", "NewName")
    assert.equals(1, vim.fn.filereadable(tmp .. "/OtherClass.cs"))
  end)

  it("renames all compound variants that share the same stem", function()
    -- Renaming MyClass.cs while MyClass.Queries.cs and MyClass.Commands.cs
    -- also exist. The function only renames the CURRENT buffer's file; the
    -- other compound files are left for the user to rename separately.
    open_tmp_file("MyClass.Queries.cs",  "public partial class MyClass {}")
    open_tmp_file("MyClass.Commands.cs", "public partial class MyClass {}")
    local old_path = open_tmp_file("MyClass.cs", "public partial class MyClass {}")
    h.do_rename_file("MyClass", "OrderService")
    -- only the active buffer's file was renamed
    assert.equals(1, vim.fn.filereadable(tmp .. "/OrderService.cs"))
    assert.equals(0, vim.fn.filereadable(old_path))
    -- sibling partial files are untouched
    assert.equals(1, vim.fn.filereadable(tmp .. "/MyClass.Queries.cs"))
    assert.equals(1, vim.fn.filereadable(tmp .. "/MyClass.Commands.cs"))
  end)
end)
