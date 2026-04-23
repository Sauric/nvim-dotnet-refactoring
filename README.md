# nvim-dotnet-refactoring

Rider-style refactoring commands for C# in Neovim, powered by the built-in LSP client.

## Features

| Command | Default keymap | Description |
|---|---|---|
| `DotnetRename` | — | Rename a C# type; also renames the file when the filename matches the type name |
| `DotnetExtractToPartial` | — | Extract selected members of a class into a new sibling `ClassName.MemberName.cs` partial-class file |
| `DotnetExtractClass` | — | Extract one or more top-level types (`class`, `record`, `struct`, `interface`, `enum`) from a file into their own `TypeName.cs` files |

## Prerequisites

- **Neovim** ≥ 0.9
- A running **C# LSP** for the open buffer — [OmniSharp](https://github.com/OmniSharp/omnisharp-roslyn) or [roslyn.nvim](https://github.com/seblj/roslyn.nvim) both work. The plugin uses `textDocument/documentSymbol` and `textDocument/rename`.

## Installation

### Using lazy.nvim

```lua
-- ~/.config/nvim/lua/plugins/nvim-dotnet-refactoring.lua
return {
  {
    "your-github-username/nvim-dotnet-refactoring",
    ft   = "cs",
    opts = {},
    keys = {
      { "<leader>cR", "<cmd>DotnetRename<cr>",           ft = "cs", desc = "Rename C# symbol (+ file)" },
      { "<leader>cE", "<cmd>DotnetExtractToPartial<cr>", ft = "cs", desc = "Extract C# member to partial" },
      { "<leader>cx", "<cmd>DotnetExtractClass<cr>",     ft = "cs", desc = "Extract C# type(s) to own file(s)" },
    },
  },
}
```

If you are loading from a **local directory** (e.g. while developing the plugin):

```lua
return {
  {
    dir  = vim.fn.expand("~/path/to/nvim-dotnet-refactoring"),
    name = "nvim-dotnet-refactoring",
    ft   = "cs",
    opts = {},
    keys = {
      { "<leader>cR", "<cmd>DotnetRename<cr>",           ft = "cs", desc = "Rename C# symbol (+ file)" },
      { "<leader>cE", "<cmd>DotnetExtractToPartial<cr>", ft = "cs", desc = "Extract C# member to partial" },
      { "<leader>cx", "<cmd>DotnetExtractClass<cr>",     ft = "cs", desc = "Extract C# type(s) to own file(s)" },
    },
  },
}
```

### Manual installation

Clone the repository into your Neovim runtime path:

```bash
git clone https://github.com/your-github-username/nvim-dotnet-refactoring \
  ~/.local/share/nvim/site/pack/plugins/start/nvim-dotnet-refactoring
```

Then call `setup()` somewhere in your config (e.g. `init.lua`):

```lua
require("nvim-dotnet-refactoring").setup({
  -- optional keymaps
  keymap_rename        = "<leader>cR",
  keymap_extract       = "<leader>cE",
  keymap_extract_class = "<leader>cx",
})
```

If you do not pass keymaps, the three user commands (`DotnetRename`, `DotnetExtractToPartial`, `DotnetExtractClass`) are still registered and can be called directly via `:DotnetRename` etc.

## Configuration

`setup()` accepts an optional table:

```lua
require("nvim-dotnet-refactoring").setup({
  keymap_rename        = nil,  -- e.g. "<leader>cR"
  keymap_extract       = nil,  -- e.g. "<leader>cE"
  keymap_extract_class = nil,  -- e.g. "<leader>cx"
})
```

All keys are optional. Passing `nil` (the default) skips keymap registration for that command.

## Usage

### DotnetRename

Place the cursor on a type name (`class`, `struct`, `record`, `interface`, `enum`) and run the command. A prompt appears pre-filled with the current name. If the filename stem matches the type name, the file is renamed on disk as well.

```
MyService.cs  →  cursor on "MyService"  →  type "OrderService"
result: symbol renamed + file renamed to OrderService.cs
```

For any other symbol (method, property, field, …) the command falls through to the built-in `vim.lsp.buf.rename()`.

### DotnetExtractToPartial

Place the cursor anywhere inside a class body and run the command. A floating dialog lists all extractable members. Use the keyboard to select which members to move:

| Key | Action |
|---|---|
| `j` / `k` | Move cursor |
| `Space` | Toggle selection |
| `e` | Edit the suggested filename |
| `Enter` | Confirm extraction |
| `Esc` / `q` | Cancel |

The selected members are removed from the original file, the class is made `partial`, and a new sibling file `ClassName.MemberName.cs` is created containing a matching `partial class` with those members.

### DotnetExtractClass

Place the cursor anywhere in a `.cs` file that contains multiple top-level types (classes, records, structs, interfaces, enums) and run the command. A floating dialog lists all extractable types:

| Key | Action |
|---|---|
| `j` / `k` | Move cursor |
| `Space` | Toggle selection |
| `Enter` | Confirm extraction |
| `Esc` / `q` | Cancel |

Each selected type is written to its own `TypeName.cs` file in the same directory (with the same `using` directives and namespace), and removed from the original file.

**Example** — `Models.cs` contains `Class1`, `Record1`, `Class2`, `RecordStruct1`. Select `Record1`:

```
before:  Models.cs  (Class1, Record1, Class2, RecordStruct1)
after:   Models.cs  (Class1, Class2, RecordStruct1)
         Record1.cs (Record1)
```

## Running tests

The test suite uses [plenary.nvim](https://github.com/nvim-lua/plenary.nvim). Make sure it is installed at `~/.local/share/nvim/lazy/plenary.nvim` (the default lazy.nvim path), then run:

```bash
make test
```

To use a different Neovim binary:

```bash
make test NVIM=/path/to/nvim
```

Tests run headlessly and do not require a real LSP connection — all LSP-dependent logic is covered through the `_internals` API using in-process buffer fixtures.
