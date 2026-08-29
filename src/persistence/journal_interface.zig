const std = @import("std");
const Storage = @import("../storage/interface.zig");
const object = @import("../object.zig");

const JournalPersistence = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Error = error{
    OutOfMemory,
    UnableToRecordWrite,
    UnableToLoad,
    UnableToRewrite,
    RewriteAlreadyInProgress,
    FailedToOpenDir,
    FailedToReadManifest,
    FailedToWriteManifest,
    FailedToOpenManifest,
    FailedToOpenIncrFile,
    FailedToOpenBase,
    FailedBufferAppend,
};

pub const WriteEvent = union(enum) {
    put: struct { db_index: u32, key: []const u8, value: object.Object, options: Storage.PutOptions },
    remove: struct { db_index: u32, key: []const u8 },
};

pub const VTable = struct {
    onWrite: *const fn (*anyopaque, WriteEvent) Error!void,
    flush: *const fn (*anyopaque, i64) Error!void,
    bgRewrite: *const fn (*anyopaque) Error!void,
    finishRewrite: *const fn (*anyopaque, bool) Error!void,
    close: *const fn (*anyopaque) Error!void,
};

pub fn onWrite(self: JournalPersistence, event: WriteEvent) Error!void {
    return self.vtable.onWrite(self.ptr, event);
}

pub fn flush(self: JournalPersistence, now_ms: i64) Error!void {
    return self.vtable.flush(self.ptr, now_ms);
}

pub fn bgRewrite(self: JournalPersistence) Error!void {
    return self.vtable.bgRewrite(self.ptr);
}

pub fn finishRewrite(self: JournalPersistence, child_succeeded: bool) Error!void {
    return self.vtable.finishRewrite(self.ptr, child_succeeded);
}

pub fn close(self: JournalPersistence) Error!void {
    return self.vtable.close(self.ptr);
}
