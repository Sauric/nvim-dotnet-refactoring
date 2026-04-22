local rename = require("nvim-dotnet-refactoring.rename")
local h = rename._internals

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
end)

-- ---------------------------------------------------------------------------
-- Treesitter-dependent tests — skipped when c_sharp parser is unavailable
-- ---------------------------------------------------------------------------
local function cs_parser_available()
  local ok = pcall(vim.treesitter.language.add, "c_sharp")
  return ok
end

local function make_cs_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(lines, "\n"))
  vim.bo[buf].filetype = "cs"
  vim.treesitter.get_parser(buf, "c_sharp"):parse()
  return buf
end

local function teardown_buf(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

describe("find_type_node_at_cursor + get_identifier", function()
  if not cs_parser_available() then
    pending("c_sharp treesitter parser not installed — skipping")
    return
  end

  -- pos is 0-indexed {row, col} as expected by vim.treesitter.get_node
  it("finds a class declaration and returns its name", function()
    local buf = make_cs_buf("public class OrderService\n{\n}")
    local node = h.find_type_node_at_cursor(buf, { 0, 15 })
    assert.is_not_nil(node)
    assert.equals("class_declaration", node:type())
    assert.equals("OrderService", h.get_identifier(node, buf))
    teardown_buf(buf)
  end)

  it("finds a struct declaration", function()
    local buf = make_cs_buf("public struct Point\n{\n}")
    local node = h.find_type_node_at_cursor(buf, { 0, 15 })
    assert.is_not_nil(node)
    assert.equals("struct_declaration", node:type())
    assert.equals("Point", h.get_identifier(node, buf))
    teardown_buf(buf)
  end)

  it("finds an interface declaration", function()
    local buf = make_cs_buf("public interface IRepository\n{\n}")
    local node = h.find_type_node_at_cursor(buf, { 0, 20 })
    assert.is_not_nil(node)
    assert.equals("interface_declaration", node:type())
    assert.equals("IRepository", h.get_identifier(node, buf))
    teardown_buf(buf)
  end)

  it("finds an enum declaration", function()
    local buf = make_cs_buf("public enum Status\n{\n  Active,\n  Inactive\n}")
    local node = h.find_type_node_at_cursor(buf, { 0, 13 })
    assert.is_not_nil(node)
    assert.equals("enum_declaration", node:type())
    assert.equals("Status", h.get_identifier(node, buf))
    teardown_buf(buf)
  end)

  it("returns nil when cursor is inside a method body", function()
    local code = "public class MyService\n{\n  public void DoWork()\n  {\n    var x = 1;\n  }\n}"
    local buf = make_cs_buf(code)
    local node = h.find_type_node_at_cursor(buf, { 4, 8 }) -- row 4 = "    var x = 1;"
    assert.is_nil(node)
    teardown_buf(buf)
  end)

  it("finds the type node when cursor is on the opening brace", function()
    local buf = make_cs_buf("public class MyService\n{\n}")
    local node = h.find_type_node_at_cursor(buf, { 1, 0 }) -- row 1 = "{"
    assert.is_not_nil(node)
    assert.equals("MyService", h.get_identifier(node, buf))
    teardown_buf(buf)
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
end)
