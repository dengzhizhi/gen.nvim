local function reload_gen()
  package.loaded["gen"] = nil
  package.loaded["gen.init"] = nil
  package.loaded["gen.prompts"] = nil
  return require("gen")
end

local function assert_truthy(value, message)
  if not value then
    error(message or "expected truthy value")
  end
end

local function assert_falsy(value, message)
  if value then
    error(message or "expected falsy value")
  end
end

local function assert_eq(expected, actual, message)
  if expected ~= actual then
    error(message or string.format("expected %s, got %s", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_contains(value, pattern, message)
  if not string.find(value, pattern, 1, true) then
    error(message or string.format("expected %q to contain %q", value, pattern))
  end
end

local function run_exec(file_option, prompt)
  local gen = reload_gen()
  local captured_cmd

  gen.run_command = function(cmd, _)
    captured_cmd = cmd
  end

  vim.o.swapfile = false
  vim.o.shada = ""
  vim.cmd("enew")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "print('hello')" })

  local options = {
    prompt = prompt or "Summarize:\n$text",
    command = function()
      return "curl -X POST http://localhost:11434/api/chat -d $body"
    end,
    model = "test-model",
    init = function() end,
    display_mode = "float",
  }

  if file_option ~= "__unset__" then
    options.file = file_option
  end

  gen.exec(options)

  assert_truthy(captured_cmd, "expected command to be captured")

  local temp_path = captured_cmd:match("@([^'\"%s]+)")
  return captured_cmd, temp_path
end

local function cleanup_tempfile(path)
  if path and vim.loop.fs_stat(path) then
    os.remove(path)
  end
end

local function make_large_prompt(target_bytes)
  return string.rep("a", target_bytes)
end

local function run_streaming_command()
  local gen = reload_gen()
  local callbacks
  local original_jobstart = vim.fn.jobstart
  local original_jobstop = vim.fn.jobstop

  vim.fn.jobstart = function(_, job_opts)
    callbacks = job_opts
    return 99
  end
  vim.fn.jobstop = function() end

  vim.o.swapfile = false
  vim.o.shada = ""
  vim.cmd("enew")

  gen.run_command("fake command", {
    debug = false,
    display_mode = "float",
    hidden = false,
    json_response = true,
    model = "test-model",
    no_auto_close = false,
    replace = false,
    result_filetype = "markdown",
    show_model = false,
    show_prompt = false,
    win_config = {},
  })

  local buffer = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local function cleanup()
    vim.fn.jobstart = original_jobstart
    vim.fn.jobstop = original_jobstop
  end

  return callbacks, buffer, win, cleanup
end

local function run_streaming_command_with_win_open_hook(display_mode, after_open)
  local original_defer_fn = vim.defer_fn
  local scheduled_callbacks = {}

  vim.defer_fn = function(fn, delay)
    table.insert(scheduled_callbacks, { fn = fn, delay = delay })
    return #scheduled_callbacks
  end

  local gen = reload_gen()
  local callbacks
  local original_jobstart = vim.fn.jobstart
  local original_jobstop = vim.fn.jobstop

  vim.fn.jobstart = function(_, job_opts)
    callbacks = job_opts
    return 99
  end
  vim.fn.jobstop = function() end

  vim.o.swapfile = false
  vim.o.shada = ""
  vim.cmd("enew")

  local hook_calls = {}
  local options = {
    debug = false,
    display_mode = display_mode,
    hidden = false,
    json_response = true,
    model = "test-model",
    no_auto_close = false,
    replace = false,
    result_filetype = "markdown",
    show_model = false,
    show_prompt = false,
    win_config = {},
    win_open_hook = function(win_id, bufnr, opts)
      table.insert(hook_calls, {
        win_id = win_id,
        bufnr = bufnr,
        opts = opts,
      })
    end,
    win_open_hook_delay = 450,
  }

  gen.run_command("fake command", options)

  local buffer = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  if after_open then
    after_open(buffer, win, options)
  end

  local function cleanup()
    vim.fn.jobstart = original_jobstart
    vim.fn.jobstop = original_jobstop
    vim.defer_fn = original_defer_fn
  end

  return callbacks, buffer, win, hook_calls, scheduled_callbacks, options, cleanup
end

local function capture_cmds_while(fn)
  local original_cmd = vim.cmd
  local commands = {}

  vim.cmd = function(command)
    if type(command) == "string" then
      table.insert(commands, command)
    end
    return original_cmd(command)
  end

  local ok, result_a, result_b, result_c = pcall(fn)
  vim.cmd = original_cmd

  if not ok then
    error(result_a)
  end

  return commands, result_a, result_b, result_c
end

local function with_cwd(cwd, fn)
  local original_cwd = vim.fn.getcwd()
  local project_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  vim.cmd("set rtp+=" .. vim.fn.fnameescape(project_root))
  vim.cmd("cd " .. vim.fn.fnameescape(cwd))

  local ok, result_a, result_b, result_c = pcall(fn)
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))

  if not ok then
    error(result_a)
  end

  return result_a, result_b, result_c
end

local function capture_notifications_while(fn)
  local original_notify = vim.notify
  local notifications = {}

  vim.notify = function(message, level)
    table.insert(notifications, { message = message, level = level })
  end

  local ok, result_a, result_b, result_c = pcall(fn)
  vim.notify = original_notify

  if not ok then
    error(result_a)
  end

  return notifications, result_a, result_b, result_c
end

local function delete_named_gen_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local tail = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
      if tail == "gen.nvim" or tail:match("^gen%.nvim %[%d+%]$") then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end
end

local function close_result_view(buffer, win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    pcall(vim.api.nvim_buf_delete, buffer, { force = true })
  end
end

local default_cmd = select(1, run_exec("__unset__"))
assert_falsy(default_cmd:match("@"), "default file option should inline the JSON body")

local false_cmd = select(1, run_exec(false))
assert_falsy(false_cmd:match("@"), "file=false should inline the JSON body")

local true_cmd, true_temp = run_exec(true)
assert_truthy(true_cmd:match("@"), "file=true should write the JSON body to a temp file")
assert_truthy(true_temp and vim.loop.fs_stat(true_temp), "expected temp file to exist for file=true")
cleanup_tempfile(true_temp)

local auto_small_cmd = select(1, run_exec("auto", "short body"))
assert_falsy(auto_small_cmd:match("@"), "file='auto' should inline small JSON bodies")

local auto_large_prompt = make_large_prompt(820 * 1024)
local auto_large_cmd, auto_large_temp = run_exec("auto", auto_large_prompt)
assert_truthy(auto_large_cmd:match("@"), "file='auto' should use a temp file for large JSON bodies")
assert_truthy(auto_large_temp and vim.loop.fs_stat(auto_large_temp), "expected temp file to exist for large auto payload")
cleanup_tempfile(auto_large_temp)

local callbacks, buffer, _, cleanup_streaming = run_streaming_command()
assert_truthy(callbacks and callbacks.on_stdout and callbacks.on_exit, "expected streaming callbacks to be captured")

local initial_text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
assert_contains(initial_text, "--- streaming ---", "expected streaming indicator while the job is running")

callbacks.on_stdout(nil, { [[{"message":{"content":"Hi"},"done":false}]] }, nil)
local streaming_text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
assert_contains(streaming_text, "Hi", "expected streamed content to be written to the buffer")
assert_contains(streaming_text, "--- streaming ---", "expected streaming indicator to remain visible during streaming")

callbacks.on_exit(nil, 0)
local completed_text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
assert_falsy(string.find(completed_text, "--- streaming ---", 1, true), "expected streaming indicator to be removed on exit")
assert_contains(completed_text, "Hi", "expected streamed content to remain after exit")

cleanup_streaming()

for _, display_mode in ipairs({ "float", "horizontal-split", "vertical-split", "no-split" }) do
  local _, hook_buffer, hook_win, hook_calls, scheduled_callbacks, options, cleanup_hook_test =
      run_streaming_command_with_win_open_hook(display_mode)
  assert_truthy(vim.api.nvim_buf_is_valid(hook_buffer), "expected hook test buffer to be valid")
  assert_truthy(vim.api.nvim_win_is_valid(hook_win), "expected hook test window to be valid")
  assert_eq(1, #scheduled_callbacks,
            string.format("expected one delayed win_open_hook in %s mode", display_mode))
  assert_eq(options.win_open_hook_delay, scheduled_callbacks[1].delay,
            string.format("expected configured win_open_hook_delay in %s mode", display_mode))
  assert_eq(0, #hook_calls,
            string.format("expected hook not to run before the scheduled callback in %s mode", display_mode))
  scheduled_callbacks[1].fn()
  assert_eq(1, #hook_calls,
            string.format("expected win_open_hook to run once in %s mode", display_mode))
  assert_eq(hook_win, hook_calls[1].win_id,
            string.format("expected win_open_hook win_id in %s mode", display_mode))
  assert_eq(hook_buffer, hook_calls[1].bufnr,
            string.format("expected win_open_hook bufnr in %s mode", display_mode))
  assert_eq(options, hook_calls[1].opts,
            string.format("expected win_open_hook opts in %s mode", display_mode))
  close_result_view(hook_buffer, hook_win)
  cleanup_hook_test()
end

local _, stale_buffer, stale_win, stale_hook_calls, stale_scheduled_callbacks, _, cleanup_stale_hook =
    run_streaming_command_with_win_open_hook("float", function()
      vim.cmd("enew")
    end)
assert_truthy(vim.api.nvim_buf_is_valid(stale_buffer), "expected stale hook buffer to be valid before replacement")
assert_truthy(vim.api.nvim_win_is_valid(stale_win), "expected stale hook window to be valid before replacement")
assert_eq(1, #stale_scheduled_callbacks, "expected stale hook callback to be scheduled")
stale_scheduled_callbacks[1].fn()
assert_eq(0, #stale_hook_calls, "expected stale win_open_hook to be skipped")
close_result_view(stale_buffer, stale_win)
cleanup_stale_hook()

delete_named_gen_buffers()
local vertical_cmds, vertical_buffer, vertical_win, cleanup_vertical_split =
    capture_cmds_while(function()
      local _, hook_buffer, hook_win, _, _, _, cleanup_hook_test =
          run_streaming_command_with_win_open_hook("vertical-split")
      return hook_buffer, hook_win, cleanup_hook_test
    end)
assert_truthy(vim.api.nvim_buf_is_valid(vertical_buffer), "expected vertical split buffer to be valid")
assert_truthy(vim.api.nvim_win_is_valid(vertical_win), "expected vertical split window to be valid")
assert_falsy(vim.tbl_contains(vertical_cmds, "vnew gen.nvim"),
             "expected vertical split to avoid opening gen.nvim as a path")
assert_eq("gen.nvim", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vertical_buffer), ":t"),
          "expected vertical split buffer name to stay gen.nvim")
assert_eq("nofile", vim.api.nvim_get_option_value("buftype", { buf = vertical_buffer }),
          "expected vertical split result buffer to stay scratch-backed")
close_result_view(vertical_buffer, vertical_win)
cleanup_vertical_split()

local project_root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
local parent_dir = vim.fn.fnamemodify(project_root, ":h")
delete_named_gen_buffers()
local cwd_buffer, cwd_win, cleanup_cwd_split = with_cwd(parent_dir, function()
  local _, hook_buffer, hook_win, _, _, _, cleanup_hook_test =
      run_streaming_command_with_win_open_hook("vertical-split")
  return hook_buffer, hook_win, cleanup_hook_test
end)
assert_truthy(vim.api.nvim_buf_is_valid(cwd_buffer), "expected cwd regression buffer to be valid")
assert_truthy(vim.api.nvim_win_is_valid(cwd_win), "expected cwd regression window to be valid")
assert_eq("gen.nvim", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(cwd_buffer), ":t"),
          "expected cwd regression buffer name to stay gen.nvim")
assert_eq("nofile", vim.api.nvim_get_option_value("buftype", { buf = cwd_buffer }),
          "expected cwd regression buffer to stay scratch-backed")
close_result_view(cwd_buffer, cwd_win)
cleanup_cwd_split()

delete_named_gen_buffers()
local name_collision_notifications, collision_buffer, _, cleanup_collision_split =
    capture_notifications_while(function()
      local existing = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(existing, "gen.nvim")

      local _, hook_buffer, hook_win, _, _, _, cleanup_hook_test =
          run_streaming_command_with_win_open_hook("vertical-split")

      vim.api.nvim_buf_delete(existing, { force = true })
      return hook_buffer, hook_win, cleanup_hook_test
    end)
assert_truthy(vim.api.nvim_buf_is_valid(collision_buffer), "expected collision buffer to be valid")
assert_truthy(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(collision_buffer), ":t") ~= "",
              "expected collision buffer to receive a fallback name")
assert_truthy(#name_collision_notifications > 0, "expected collision rename to notify")
close_result_view(collision_buffer)
cleanup_collision_split()

print("file option tests passed")
