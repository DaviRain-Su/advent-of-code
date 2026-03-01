pub const ToolFunction = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8,
    function: ToolFunction,
};

pub const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
};

pub const ParsedAssistantMessage = struct {
    content: ?[]const u8,
    tool_calls: ?[]const ToolCall,
    reasoning_content: ?[]const u8,
};
