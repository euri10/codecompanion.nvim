local h = require("tests.helpers")
local adapter

local new_set = MiniTest.new_set
T = new_set()

T["DeepSeek ACP adapter"] = new_set({
  hooks = {
    pre_case = function()
      adapter = require("codecompanion.adapters").resolve("deepseek_acp")
    end,
  },
})

T["DeepSeek ACP adapter"]["resolves with the CodeWhale ACP command"] = function()
  h.eq("deepseek_acp", adapter.name)
  h.eq("DeepSeek ACP", adapter.formatted_name)
  h.eq("acp", adapter.type)
  h.eq({ "codewhale", "serve", "--acp" }, adapter.commands.default)
  h.eq(false, adapter.opts.vision)
  h.eq("DEEPSEEK_API_KEY", adapter.env.DEEPSEEK_API_KEY)
end

T["DeepSeek ACP adapter"]["only sends fresh user messages to the LLM"] = function()
  local messages = {
    {
      _meta = {
        sent = true,
      },
      content = "Summarize this file",
      role = "user",
    },
    {
      _meta = {},
      content = "Already handled",
      role = "llm",
    },
    {
      _meta = {},
      content = "Focus on the public API",
      role = "user",
    },
  }

  local output = {
    {
      text = "Focus on the public API",
      type = "text",
    },
  }

  h.eq(output, adapter.handlers.form_messages(adapter, messages))
end

return T
