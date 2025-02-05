const std = @import("std");
const capy = @import("capy");
pub usingnamespace capy.cross_platform;

var opacity = capy.DataWrapper(f32).of(0);

fn startAnimation(button: *capy.Button_Impl) !void {
    // Ensure the current animation is done before starting another
    if (!opacity.hasAnimation()) {
        if (opacity.get() == 0) { // if hidden
            // Show the label in 1000ms
            opacity.animate(capy.Easings.In, 1, 1000);
            button.setLabel("Hide");
        } else {
            // Hide the label in 1000ms
            opacity.animate(capy.Easings.Out, 0, 1000);
            button.setLabel("Show");
        }
    }
}

pub fn main() !void {
    try capy.backend.init();

    var window = try capy.Window.init();
    const imageData = try capy.ImageData.fromFile(capy.internal.lasting_allocator, "ziglogo.png");

    try window.set(capy.Column(.{}, .{capy.Row(.{}, .{
        capy.Expanded((try capy.Row(.{}, .{
            capy.Expanded(capy.Label(.{ .text = "Hello Zig" })),
            capy.Image(.{ .data = imageData }),
        }))
            .bindOpacity(&opacity)),
        capy.Button(.{ .label = "Show", .onclick = startAnimation }),
    })}));

    window.resize(800, 450);
    window.show();
    capy.runEventLoop();
}
