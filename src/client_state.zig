// For now, simple struct suffice.
// But this could get messy when we have to maintain each client's state
// TODO: Refactor this to decouple from commander and make it generic

const ClientState = @This();

db_index: u32 = 0
