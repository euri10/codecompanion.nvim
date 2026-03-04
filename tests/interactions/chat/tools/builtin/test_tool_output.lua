local h = require("tests.helpers")

local expect = MiniTest.expect
local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        _G.chat, _G.tools = h.setup_chat_buffer()
      ]])
    end,
    post_case = function()
      child.lua([[
        _G.chat = nil
        _G.tools = nil
        _G.tool = nil
      ]])
    end,
    post_once = child.stop,
  },
})

T["Tool output"] = new_set()

---The tool call that's used in the tests
---@param c MiniTest.child
---@return nil
function tool_call(c)
  c.lua([[
    _G.tool = {
      name = "weather",
      function_call = {
        _index = 0,
        ["function"] = {
          arguments = '{"location": "London", "units": "celsius"}',
          name = "weather",
        },
        id = "call_RJU6xfk0OzQF3Gg9cOFS5RY7",
        type = "function",
      },
    }
  ]])
end

---The tool call that's used in the tests
---@param c MiniTest.child
---@param message string The message to add to the chat buffer
---@return nil
local function set_buffer_contents(c, message)
  c.lua(string.format(
    [[
    local user_message = "%s"

    _G.chat:add_message({
      role = "user",
      content = user_message,
    })
    _G.chat:add_buf_message({
      role = "user",
      content = user_message,
    })

  ]],
    message
  ))
end

---Enabling folding in the chat buffer for tool output.
---@param c MiniTest.child
---@return nil
local function enable_folds(c)
  c.lua([[
    _G.chat, _G.tools = h.setup_chat_buffer({
      interactions = {
        chat = {
          tools = {
            opts = {
              folds = {
                enabled = true,
              }
            }
          }
        }
      }
    })
  ]])
end

T["Tool output"]["first call creates one message"] = function()
  tool_call(child)
  local output = child.lua([[
    local chat = _G.chat

    chat:add_tool_output(_G.tool, "Hello!")

    -- return how many chat.messages and that message's content
    return {
      count = #chat.messages,
      content = chat.messages[#chat.messages].content,
    }
  ]])

  h.eq(output.count, 2)
  h.eq(output.content, "Hello!")
end

T["Tool output"]["second call appends to same message"] = function()
  tool_call(child)
  local output = child.lua([[
    local chat = _G.chat

    -- first insert
    chat:add_tool_output(_G.tool, "Hello!")
    -- second insert with same id => should append
    chat:add_tool_output(_G.tool, "Again!")

    return {
      count = #chat.messages,
      content = chat.messages[#chat.messages].content,
    }
  ]])

  h.eq(output.count, 2)
  h.eq(output.content, "Hello!\n\nAgain!")
end

T["Tool output"]["is displayed and formatted in the chat buffer"] = function()
  set_buffer_contents(child, "Can you tell me the weather in London?")
  tool_call(child)
  child.lua([[
    h.make_tool_call(_G.chat, _G.tool, "**Weather Tool**: Ran successfully:\nTemperature: 20°C\nCondition: Sunny\nPrecipitation: 0%", {
      llm_initial_response = "I've found some awesome weather data for you:",
      llm_final_response = "Let me know if you need anything else!",
    })
  ]])

  expect.reference_screenshot(child.get_screenshot())
end

T["Tool output"]["Folds"] = new_set()

T["Tool output"]["Folds"]["can be folded"] = function()
  enable_folds(child)
  set_buffer_contents(child, "Can you tell me the weather in London?")
  tool_call(child)
  child.lua([[
    --require("tests.log")
    h.make_tool_call(_G.chat, _G.tool, "**Weather Tool**: Ran successfully:\nTemperature: 20°C\nCondition: Sunny\nPrecipitation: 0%", {
      llm_initial_response = "I've found some awesome weather data for you:",
      llm_final_response = "\nLet me know if you need anything else!",
    })
  ]])

  expect.reference_screenshot(child.get_screenshot())
end

T["Tool output"]["Folds"]["does not fold single line output but applies extmarks"] = function()
  enable_folds(child)
  set_buffer_contents(child, "Can you tell me the weather in London?")
  tool_call(child)
  child.lua([[
    --require("tests.log")
     h.make_tool_call(_G.chat, _G.tool, "**Weather Tool**: Ran successfully", {
       llm_initial_response = "I've found some awesome weather data for you:",
     })
   ]])

  expect.reference_screenshot(child.get_screenshot())
end

T["Tool output"]["Folds"]["highlight"] = new_set()

---Helper that writes a tool message into a chat buffer with folds enabled and returns
---the fold summary entry for the first tool fold in the buffer.
---@param c MiniTest.child
---@param tool_output string Content passed to add_tool_output
---@param status string|nil Optional status passed as opts.status
---@return table { summary: table|nil, chunks: table[] }
local function get_fold_highlight(c, tool_output, status)
  enable_folds(c)
  set_buffer_contents(c, "What is the weather?")
  tool_call(c)

  local result = c.lua(string.format(
    [[
      local output = %q
      local status = %s
      local opts = status ~= nil and { status = status } or nil

      _G.chat:add_tool_output(_G.tool, output, nil, opts)

      -- Wait for the scheduled fold creation
      vim.wait(200, function() return false end)

      local bufnr = _G.chat.bufnr
      local Folds = require("codecompanion.interactions.chat.ui.folds")
      local summaries = Folds.fold_summaries[bufnr] or {}

      -- Find the first tool fold (fold_summaries[bufnr] is keyed by 0-based line number)
      local summary = nil
      for _, v in pairs(summaries) do
        if type(v) == "table" and v.type == "tool" then
          summary = v
          break
        end
      end

      -- Get the highlight chunks for this fold
      local chunks = {}
      if summary then
        chunks = Folds._format_fold_text(summary.content, "tool", { status = summary.status })
      end

      return { summary = summary, chunks = chunks }
    ]],
    tool_output,
    status ~= nil and string.format("%q", status) or "nil"
  ))

  return result
end

T["Tool output"]["Folds"]["highlight"]["success status uses green highlight group"] = function()
  local result = get_fold_highlight(child, "Created file `foo.lua`\nline two\nline three", "success")

  h.eq(result.summary ~= nil, true, "Expected a fold summary entry")
  h.eq(result.summary.status, "success")
  -- The icon chunk and text chunk should both use the success highlight groups
  h.eq(result.chunks[1][2], "CodeCompanionChatToolSuccessIcon")
  h.eq(result.chunks[2][2], "CodeCompanionChatToolSuccess")
end

T["Tool output"]["Folds"]["highlight"]["error status uses red highlight group"] = function()
  local result = get_fold_highlight(child, "Something went wrong\nline two\nline three", "error")

  h.eq(result.summary ~= nil, true, "Expected a fold summary entry")
  h.eq(result.summary.status, "error")
  h.eq(result.chunks[1][2], "CodeCompanionChatToolFailureIcon")
  h.eq(result.chunks[2][2], "CodeCompanionChatToolFailure")
end

T["Tool output"]["Folds"]["highlight"]["cancelled status uses red highlight group"] = function()
  local result = get_fold_highlight(child, "The user declined\nline two\nline three", "cancelled")

  h.eq(result.summary ~= nil, true, "Expected a fold summary entry")
  h.eq(result.summary.status, "cancelled")
  h.eq(result.chunks[1][2], "CodeCompanionChatToolFailureIcon")
  h.eq(result.chunks[2][2], "CodeCompanionChatToolFailure")
end

T["Tool output"]["Folds"]["highlight"]["success status overrides failure word in content"] = function()
  -- Content contains "error" which would trigger red via failure_words if status were absent
  local result = get_fold_highlight(child, "Handled error_handler.lua successfully\nline two\nline three", "success")

  h.eq(result.summary ~= nil, true, "Expected a fold summary entry")
  h.eq(result.summary.status, "success")
  -- Must be green despite the word "error" appearing in content
  h.eq(result.chunks[1][2], "CodeCompanionChatToolSuccessIcon")
  h.eq(result.chunks[2][2], "CodeCompanionChatToolSuccess")
end

T["Tool output"]["Folds"]["highlight"]["no status falls back to failure_words scan for errors"] = function()
  -- No status provided; content contains a failure word => should still be red (backward compat)
  local result = get_fold_highlight(child, "failed to run\nline two\nline three", nil)

  h.eq(result.summary ~= nil, true, "Expected a fold summary entry")
  h.eq(result.summary.status, nil)
  h.eq(result.chunks[1][2], "CodeCompanionChatToolFailureIcon")
  h.eq(result.chunks[2][2], "CodeCompanionChatToolFailure")
end

T["Tool output"]["Folds"]["highlight"]["no status falls back to failure_words scan for success"] = function()
  -- No status provided; content has no failure words => should be green
  local result = get_fold_highlight(child, "All done\nline two\nline three", nil)

  h.eq(result.summary ~= nil, true, "Expected a fold summary entry")
  h.eq(result.summary.status, nil)
  h.eq(result.chunks[1][2], "CodeCompanionChatToolSuccessIcon")
  h.eq(result.chunks[2][2], "CodeCompanionChatToolSuccess")
end

return T
