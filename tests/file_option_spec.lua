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
  local function cleanup()
    vim.fn.jobstart = original_jobstart
    vim.fn.jobstop = original_jobstop
  end

  return callbacks, buffer, cleanup
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

local callbacks, buffer, cleanup_streaming = run_streaming_command()
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

print("file option tests passed")
