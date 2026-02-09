pub const LoadState = struct {
    active: bool = false,
    request_id: u32 = 0,
    net_done: bool = false,
    renderer_done: bool = false,
};

