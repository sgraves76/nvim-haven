local action_state = require("telescope.actions.state")
local actions = require("telescope.actions")
local conf = require("telescope.config").values
local finders = require("telescope.finders")
local global_state = require("telescope.state")
local pfiletype = require("plenary.filetype")
local pickers = require("telescope.pickers")
local previewers = require("telescope.previewers")
local putils = require("telescope.previewers.utils")
local utils = require("nvim-haven.utils")

local ns_previewer = vim.api.nvim_create_namespace("telescope.previewers")

local M = {}

local active_saves = {}
local changed_lookup = {}
local directory_sep = utils.iff(utils.is_windows, "\\", "/")
local haven_config = {
  enabled = true,
  exclusions = {
    function(path, _)
      if utils.is_windows then
        return path:lower():starts_with((vim.fn.eval("$VIMRUNTIME") .. directory_sep):lower())
      end
      return path:starts_with(vim.fn.eval("$VIMRUNTIME") .. directory_sep)
    end,
    function(path, _)
      if utils.is_windows then
        return path:lower():starts_with((vim.fn.stdpath("data") .. directory_sep):lower())
      end
      return path:starts_with(vim.fn.stdpath("data") .. directory_sep)
    end,
    function(path, _)
      if utils.is_windows then
        return path:lower():starts_with(
          (utils.create_path(vim.fn.eval("$XDG_CONFIG_HOME"), "coc") .. directory_sep):lower()
        )
      end
      return path:starts_with(
        utils.create_path(vim.fn.eval("$XDG_CONFIG_HOME"), "coc") .. directory_sep
      )
    end,
    function(path, _)
      if utils.is_windows then
        return path:lower():ends_with(
          (directory_sep .. ".git" .. directory_sep .. "COMMIT_EDITMSG"):lower()
        )
      end
      return path:ends_with(directory_sep .. ".git" .. directory_sep .. "COMMIT_EDITMSG")
    end,
    function(path, config)
      if utils.is_windows then
        return path:lower():starts_with((config.haven_path .. directory_sep):lower())
      end
      return path:starts_with(config.haven_path .. directory_sep)
    end
  },
  haven_path = utils.create_path(vim.fn.stdpath("data"), "nvim-haven"),
  inclusions = {},
  max_history_count = 200,
  save_timeout = 10000
}
local line_ending = utils.iff(utils.is_windows, "\r\n", "\n")

local print_message = function(...)
  print("nvim-haven", ...)
end

local diff_strings = function(a, b)
  return vim.diff(a, b, {algorithm = "minimal"})
end

local encode = function(str)
  return str:gsub("\r?\n", "\r\n"):gsub(
    "([^%w%-%.%_%~ ])",
    function(c)
      return string.format("%%%02X", string.byte(c))
    end
  ):gsub(" ", "+")
end

local create_save_file = function(buf_info)
  return utils.create_path(haven_config.haven_path, encode(buf_info.name) .. ".save")
end

local save_change_file = function(buf_info, lines, save_file)
  print_message("save_changed_file", buf_info.name)
  active_saves[save_file] = nil

  local file, err = io.open(save_file, "a")
  if file == nil then
    print_message(err)
    return
  end

  local file_entry =
    vim.json.encode(
    {
      date = os.time(),
      ft = pfiletype.detect(buf_info.name, {}),
      lines = lines
    }
  )
  _, err = file:write(file_entry .. line_ending)
  if err ~= nil then
    print_message(err)
  end
  file:close()
end

local save_change_file_entries = function(buf_info, entries, save_file)
  print_message("save_changed_file", buf_info.name)
  active_saves[save_file] = nil

  local file, err = io.open(save_file, "w+")
  if file == nil then
    print_message(err)
    return
  end

  for _, entry in pairs(entries) do
    _, err = file:write(vim.json.encode(entry) .. line_ending)
    if err ~= nil then
      print_message(err)
    end
  end
  file:close()
end

local read_change_file = function(buf_info, save_file)
  local file, err = io.open(save_file, "r")
  if file == nil then
    return nil, err
  end

  local save_data
  save_data, err = file:read("a")
  if err ~= nil then
    return nil, err
  end
  file:close()

  local entries = vim.json.decode("[" .. table.concat(save_data:split(line_ending), ",") .. "]")
  if #entries > haven_config.max_history_count then
    while #entries > haven_config.max_history_count do
      table.remove(entries, 1)
    end
    save_change_file_entries(buf_info, entries, save_file)
  end

  return entries
end

local process_file_changed = function(buf_info)
  local save_file = create_save_file(buf_info)
  local changed_data = changed_lookup[save_file]
  local immediate = vim.fn.filereadable(save_file) == 0
  if
    not immediate and
      (changed_data == nil or (buf_info.changed == 0 and changed_data.changed == 0) or
        buf_info.changedtick == changed_data.changedtick)
   then
    changed_lookup[save_file] = {changed = buf_info.changed, changedtick = buf_info.changedtick}
    return
  end

  if active_saves[save_file] ~= nil then
    active_saves[save_file].timer:stop()
    active_saves[save_file] = nil
  end

  changed_lookup[save_file] = {changed = buf_info.changed, changedtick = buf_info.changedtick}

  local lines = vim.api.nvim_buf_get_lines(buf_info.bufnr, 0, -1, true)

  local entries, _ = read_change_file(buf_info, save_file)
  if entries ~= nil then
    if
      diff_strings(
        table.concat(entries[#entries].lines, line_ending),
        table.concat(lines, line_ending)
      ):len() == 0
     then
      return
    end
    entries = nil
  end

  local saved = false
  local do_save = function()
    if not saved then
      saved = true
      save_change_file(buf_info, lines, save_file)
    end
  end

  if immediate then
    do_save()
  else
    active_saves[save_file] = {
      timer = vim.defer_fn(do_save, haven_config.save_timeout),
      do_save = do_save
    }
  end
end

local check_requirements = function()
  if vim.o.modifiable ~= 0 and vim.o.buftype ~= "nofile" then
    local buf_info = vim.fn.getbufinfo(vim.fn.bufname())
    if buf_info ~= nil and #buf_info > 0 then
      buf_info = buf_info[1]
      if buf_info.name:len() ~= 0 and vim.fn.filereadable(buf_info.name) ~= 0 then
        if changed_lookup[create_save_file(buf_info)] == nil then
          for _, is_included in pairs(haven_config.inclusions) do
            if is_included(buf_info.name, haven_config) then
              return true, buf_info
            end
          end

          for _, is_excluded in pairs(haven_config.exclusions) do
            if is_excluded(buf_info.name, haven_config) then
              return false
            end
          end
        end
        return true, buf_info
      end
    end
  end
  return false
end

local handle_buffer_changed = function()
  local ok, buf_info = check_requirements()
  if ok and buf_info ~= nil then
    process_file_changed(buf_info)
  end
end

local handle_vim_leave = function()
  for _, active in pairs(active_saves) do
    active.timer:stop()
    active.do_save()
  end
  active_saves = {}
  changed_lookup = {}
end

local setup_autocmds = function()
  local group_id = vim.api.nvim_create_augroup("nvim-haven-internal", {clear = true})
  if haven_config.enabled then
    vim.api.nvim_create_autocmd(
      "BufEnter",
      {
        group = group_id,
        pattern = "*",
        callback = handle_buffer_changed
      }
    )
    vim.api.nvim_create_autocmd(
      "InsertLeave",
      {
        group = group_id,
        pattern = "*",
        callback = handle_buffer_changed
      }
    )
    vim.api.nvim_create_autocmd(
      "TextChanged",
      {
        group = group_id,
        pattern = "*",
        callback = handle_buffer_changed
      }
    )
    vim.api.nvim_create_autocmd(
      "VimLeave",
      {
        group = group_id,
        pattern = "*",
        callback = handle_vim_leave
      }
    )
  else
    vim.api.nvim_del_augroup_by_id(group_id)
  end
end

local apply_diff_to_lines = function(diff, source_lines)
  local diff_lines = diff:split(line_ending)
  local changes = {}
  local current_diff

  for _, line in pairs(diff_lines) do
    if line:len() > 0 then
      if line:starts_with("@@") and line:ends_with("@@") then
        local diff_range = line:sub(3, -1):sub(1, -3):split(" ")[1]:split(",")
        if #diff_range == 1 then
          table.insert(diff_range, "1")
        end

        local diff_start = math.abs(tonumber(diff_range[1], 10))
        local diff_count = tonumber(diff_range[2], 10)
        if diff_count == 0 then
          diff_start = diff_start + 1
        end

        current_diff = {
          diff = {line},
          next = diff_start + diff_count,
          start = diff_start
        }
        table.insert(changes, current_diff)
      elseif current_diff ~= nil then
        table.insert(current_diff.diff, line)
      end
    else
      current_diff = nil
    end
  end

  local actual_line = 1
  local buffer_lines = {}
  local diff_rows = {}
  local source_line = 1
  for _, change in pairs(changes) do
    while source_line < change.start do
      table.insert(buffer_lines, source_lines[source_line])
      actual_line = actual_line + 1
      source_line = source_line + 1
    end

    table.insert(diff_rows, actual_line)
    for _, change_diff_lines in pairs(change.diff) do
      table.insert(buffer_lines, change_diff_lines)
      actual_line = actual_line + 1
    end

    source_line = change.next
  end

  while source_line <= #source_lines do
    table.insert(buffer_lines, source_lines[source_line])
    actual_line = actual_line + 1
    source_line = source_line + 1
  end

  return buffer_lines, diff_rows
end

local show_picker = function(entries)
  global_state.set_global_key("selected_entry", nil)

  local jump_state

  local jump_to_line = function(self, bufnr, lnum)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_previewer, 0, -1)
    if lnum and lnum > 0 then
      pcall(
        vim.api.nvim_buf_add_highlight,
        bufnr,
        ns_previewer,
        "TelescopePreviewLine",
        lnum - 1,
        0,
        -1
      )
      pcall(vim.api.nvim_win_set_cursor, self.state.winid, {lnum, 0})
      vim.api.nvim_buf_call(
        bufnr,
        function()
          vim.cmd "norm! zz"
        end
      )
    end
  end

  local do_forward_jump = function()
    if jump_state ~= nil and #jump_state.diff_rows > 0 then
      jump_state.cur =
        utils.iff(
        (jump_state.cur + 1) <= #jump_state.diff_rows,
        jump_state.cur + 1,
        #jump_state.diff_rows
      )
      jump_to_line(
        jump_state.self,
        jump_state.self.state.bufnr,
        jump_state.diff_rows[jump_state.cur]
      )
    end
  end

  local do_reverse_jump = function()
    if jump_state ~= nil and #jump_state.diff_rows > 0 then
      jump_state.cur = utils.iff((jump_state.cur - 1) > 0, jump_state.cur - 1, 1)
      jump_to_line(
        jump_state.self,
        jump_state.self.state.bufnr,
        jump_state.diff_rows[jump_state.cur]
      )
    end
  end

  pickers.new(
    {},
    {
      prompt_title = "File History",
      previewer = previewers.new_buffer_previewer(
        {
          define_preview = function(self, entry)
            jump_state = nil
            if entry.index < #entries then
              local previous_lines = entries[entry.index + 1].lines
              local buffer_lines, diff_rows =
                apply_diff_to_lines(
                diff_strings(
                  table.concat(previous_lines, line_ending),
                  table.concat(entry.value.lines, line_ending)
                ),
                previous_lines
              )
              previous_lines = nil

              vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, buffer_lines)
              putils.regex_highlighter(self.state.bufnr, "diff")

              jump_state = {self = self, cur = 0, diff_rows = diff_rows}
              vim.schedule(
                function()
                  do_forward_jump()
                end
              )
            else
              vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, entry.value.lines)
              putils.highlighter(self.state.bufnr, entry.value.ft, {})
            end
          end
        }
      ),
      sorter = conf.generic_sorter({}),
      finder = finders.new_table(
        {
          results = entries,
          entry_maker = function(item)
            return {
              value = item,
              ordinal = tostring(item.date),
              display = os.date("%m-%d-%Y %H:%M:%S", item.date)
            }
          end
        }
      ),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(
          function()
            actions.close(prompt_bufnr)
            local selection = action_state.get_selected_entry()
            if selection ~= nil then
              vim.api.nvim_buf_set_lines(0, 0, -1, false, selection.value.lines)
            end
          end
        )
        map("i", "<c-l>", do_forward_jump)
        map("n", "<c-l>", do_forward_jump)
        map("i", "<c-h>", do_reverse_jump)
        map("n", "<c-h>", do_reverse_jump)
        return true
      end
    }
  ):find()
end

M.setup = function(config)
  if config == nil then
    config = {}
  end

  if config.exclusions ~= nil then
    for _, e in pairs(config.exclusions) do
      if type(e) ~= "function" then
        print_message(
          "'exlcusions' contains an entry that is not a function. Skipping all exclusions until this is corrected:"
        )
        utils.dump_table(e)
        break
      end
      table.insert(haven_config.exclusions, e)
    end
  end
  haven_config.enabled = vim.F.if_nil(config.enabled, haven_config.enabled)
  haven_config.haven_path = vim.F.if_nil(config.haven_path, haven_config.haven_path)

  if config.inclusions ~= nil then
    for _, e in pairs(config.inclusions) do
      if type(e) ~= "function" then
        print_message(
          "'inclusions' contains an entry that is not a function. Skipping this inclusion until it is corrected:"
        )
        utils.dump_table(e)
      end
      table.insert(haven_config.inclusions, e)
    end
  end

  haven_config.max_history_count =
    vim.F.if_nil(config.max_history_count, haven_config.max_history_count)
  if haven_config.max_history_count < 10 then
    print_message("'max_history_count' too low: " .. haven_config.max_history_count)
    haven_config.max_history_count = 100
    print_message("reset 'max_history_count': " .. haven_config.max_history_count)
  elseif haven_config.max_history_count > 500 then
    print_message("'max_history_count' too high: " .. haven_config.max_history_count)
    haven_config.max_history_count = 500
    print_message("reset 'max_history_count': " .. haven_config.max_history_count)
  end

  haven_config.save_timeout = vim.F.if_nil(config.save_timeout, haven_config.save_timeout)
  if haven_config.save_timeout < 135 then
    print_message("'save_timeout' too low: " .. haven_config.save_timeout)
    haven_config.save_timeout = 135
    print_message("reset 'save_timeout': " .. haven_config.save_timeout)
  elseif haven_config.save_timeout > 10000 then
    print_message("'save_timeout' too high: " .. haven_config.save_timeout)
    haven_config.save_timeout = 10000
    print_message("reset 'save_timeout': " .. haven_config.save_timeout)
  end

  if vim.fn.mkdir(haven_config.haven_path, "p") == 0 then
    print_message("directory create failed: " .. haven_config.haven_path)
    haven_config.enabled = false
    return
  end

  if vim.fn.isdirectory(haven_config.haven_path) == 0 then
    print_message("directory not found: " .. haven_config.haven_path)
    haven_config.enabled = false
    return
  end

  setup_autocmds()
end

M.disable = function()
  if haven_config.enabled then
    haven_config.enabled = false
    setup_autocmds()
  end
end

M.enable = function()
  if not haven_config.enabled then
    haven_config.enabled = true
    handle_buffer_changed()
    setup_autocmds()
  end
end

M.history = function(bufname)
  bufname = vim.F.if_nil(bufname, vim.fn.bufname())
  local buf_info = vim.fn.getbufinfo(bufname)
  if buf_info ~= nil and #buf_info > 0 then
    buf_info = buf_info[1]
    local save_file = create_save_file(buf_info)
    if vim.fn.filereadable(save_file) ~= 0 then
      local entries, err = read_change_file(buf_info, save_file)
      if entries == nil then
        print_message(err)
        return
      end

      show_picker(table.reverse(entries))
    end
  end
end

_G.Nvim_Haven_Disable = M.disable
_G.Nvim_Haven_Enable = M.enable
_G.Nvim_Haven_History = M.history

return M
