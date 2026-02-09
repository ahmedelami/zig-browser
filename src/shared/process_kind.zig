pub const ProcessKind = enum(u8) {
    browser = 1,
    net = 2,
    renderer = 3,
    gpu = 4,

    pub fn label(self: ProcessKind) []const u8 {
        return switch (self) {
            .browser => "browser",
            .net => "net",
            .renderer => "renderer",
            .gpu => "gpu",
        };
    }
};
