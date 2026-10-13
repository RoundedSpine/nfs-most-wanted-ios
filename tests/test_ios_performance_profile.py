"""Source-contract checks for independent iOS instrumentation and haptics build options.

Run: python3 -m pytest -q tests/test_ios_performance_profile.py
These checks do not replace an on-device FPS comparison or an iOS compile.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text()


def test_workflow_has_independent_build_profile_and_haptics():
    workflow = source(".github/workflows/ios.yml")
    assert "build_profile:" in workflow
    assert "disable_device_core_haptics:" in workflow
    assert "NFSMW_PERFORMANCE_BUILD=1" in workflow
    assert "NFSMW_DISABLE_DEVICE_CORE_HAPTICS=1" in workflow
    assert "CXXFLAGS=${CXXFLAGS:-} -DNFSMW_DISABLE_DEVICE_CORE_HAPTICS=1" in workflow
    assert "OBJCXXFLAGS=${OBJCXXFLAGS:-} -DNFSMW_DISABLE_DEVICE_CORE_HAPTICS=1" in workflow
    assert "build_profile=${BUILD_PROFILE:-diagnostic}" in workflow


def test_hot_path_file_logging_is_compiled_out():
    d3d = source("kit/host/gpu/d3d9_host.cpp")
    assert d3d.count("#if defined(__APPLE__) && TARGET_OS_IPHONE && !NFSMW_PERFORMANCE_BUILD") >= 3
    assert 'ios_cpu_trace("present_enter", frame);' in d3d
    assert 'ios_cpu_trace("present_exit", frame);' in d3d
    assert 'ios_gpu_trace("texture_define"' in d3d


def test_opt_in_traces_cannot_activate_in_performance_profile():
    file_io = source("kit/platform/os_posix.cpp")
    metal = source("kit/host/gpu/metal/metal_device.mm")
    d3d_metal = source("kit/host/gpu/metal/d3d9_metal.mm")
    assert "#if defined(__APPLE__) && TARGET_OS_IPHONE && !NFSMW_PERFORMANCE_BUILD" in file_io
    assert 'diagnostics_ = !NFSMW_PERFORMANCE_BUILD && diagnostics && !strcmp(diagnostics, "1");' in metal
    assert 'if (!NFSMW_PERFORMANCE_BUILD && trace && !strcmp(trace, "1")) {' in d3d_metal


def test_crash_monitor_remains_installed():
    ui = source("kit/host/sdl/platform_ui_ios.mm")
    assert "sigaction(signo, &action, nullptr);" in ui
    assert "#if !NFSMW_PERFORMANCE_BUILD" in ui
    assert "void ios_start_crash_monitor()" in ui
