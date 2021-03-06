const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("ircbot", "src/main.zig");
    // exe.force_pic = true;
    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("curl");
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tst = b.addTest("src/test.zig");
    tst.linkSystemLibrary("c");
    tst.linkSystemLibrary("curl");

    const tst_step = b.step("test", "Test the app");
    tst_step.dependOn(&tst.step);
}
