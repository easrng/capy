const zgt = @import("zgt");

pub fn main() !void {
    try zgt.backend.init();

    var window = try zgt.Window.init();
    try window.set(
        zgt.Row(.{}, .{
            zgt.Button(.{ .label = "Tree" }),
            zgt.Expanded(
                zgt.Button(.{ .label = "Main" })
            ),
            zgt.Button(.{ .label = "Misc" })
        })
    );

    window.show();
    window.run();
}