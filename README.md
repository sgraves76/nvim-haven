# nvim-haven

Local file history save and restore for Neovim (requires `nvim-telescope`)

### Global functions

```lua
  -- Remove history for files that no longer exist
  _G.Nvim_Haven_Clean = M.clean

  -- Disable nvim-haven
  _G.Nvim_Haven_Disable = M.disable

  -- Enable nvim-haven
  _G.Nvim_Haven_Enable = M.enable

  -- Display history in telescope
  _G.Nvim_Haven_History = M.history
```

### Example

> Example utilizes my custom Neovim distribution `darcula`  
> This is not publicly available yet, but should be self-explanatory nonetheless :)  

```lua
local M = {
  disabled = false
}

M.keymaps = function() {
  local km = require("darcula.utils.keymap")
  km.nmap(
    km.leader "fy",
    require("nvim-haven").history,
    {remap = true, silent = true}
  )
  km.nmap(
    km.leader "ch",
    require("nvim-haven").clean,
    {remap = true, silent = true}
  )
}

M.lua_add_library = function(library_list)
  table.insert(library_list, "nvim-haven")
end

M.plug = function(Plug)
  Plug "sgraves76/nvim-haven"
end

M.setup = function()
  local plugins = require("nvim-goodies.plugins")
  if not plugins.check_requires("nvim-haven") then
    return
  end

  require("nvim-goodies.string")
  local gos = require("nvim-goodies.os")

  require("nvim-haven").setup(
    {
      exclusions = {
        function(path, _)
          local tmp = vim.env.TEMP or vim.env.TMP
          if tmp ~= nil and tmp:len() > 0 then
            if gos.is_windows then
              return path:lower():starts_with(tmp:lower())
            end

            return path:starts_with(tmp)
          end
          return false
        end
      },
      inclusions = {
        function(path, _)
          local dest =
            require("nvim-goodies.path").create_path(
            vim.fn.stdpath("data"),
            "plugged",
            "telescope-coc.nvim"
          )
          if gos.is_windows then
            return path:lower():starts_with(dest:lower())
          end

          return path:starts_with(dest)
        end
      }
    }
  )
end

return M
```
