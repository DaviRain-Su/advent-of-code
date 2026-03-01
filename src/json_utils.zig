const std = @import("std");
const ErrorReport = @import("errors.zig").ErrorReport;

pub const Json = struct {
    pub fn field(diag: *ErrorReport, obj: std.json.ObjectMap, key: []const u8) !std.json.Value {
        return obj.get(key) orelse {
            try diag.setf(.json, "Missing JSON field '{s}'", .{key});
            return error.MissingField;
        };
    }

    pub fn asString(diag: *ErrorReport, value: std.json.Value, path: []const u8) ![]const u8 {
        if (value != .string) {
            try diag.setf(.json, "Expected JSON string for '{s}'", .{path});
            return error.InvalidType;
        }
        return value.string;
    }

    pub fn asArray(diag: *ErrorReport, value: std.json.Value, path: []const u8) !std.json.Array {
        if (value != .array) {
            try diag.setf(.json, "Expected JSON array for '{s}'", .{path});
            return error.InvalidType;
        }
        return value.array;
    }

    pub fn asObject(diag: *ErrorReport, value: std.json.Value, path: []const u8) !std.json.ObjectMap {
        if (value != .object) {
            try diag.setf(.json, "Expected JSON object for '{s}'", .{path});
            return error.InvalidType;
        }
        return value.object;
    }
};
