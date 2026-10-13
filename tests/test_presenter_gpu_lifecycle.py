"""Regression simulation of the presenter/overlay GPU lifetime contract.

Run with: python3 -m pytest -q tests/test_presenter_gpu_lifecycle.py
This is a lifecycle model and source-contract test, not a Metal/iOS runtime test.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRESENTER = (ROOT / "kit/host/present_thread.cpp").read_text()
OVERLAY = (ROOT / "kit/host/controls/overlay.cpp").read_text()
PERFORMANCE = (ROOT / "kit/host/performance_overlay.cpp").read_text()
PERFORMANCE_HEADER = (ROOT / "kit/host/performance_overlay.h").read_text()


class SimulatedDevice:
    def __init__(self):
        self.alive = True
        self.textures = set()
        self.destroyed = []

    def create(self, texture):
        assert self.alive
        self.textures.add(texture)

    def destroy(self, texture):
        assert self.alive, "GPU resource destroyed after device lifetime"
        assert texture in self.textures, "double free or wrong device"
        self.textures.remove(texture)
        self.destroyed.append(texture)


class SimulatedOverlay:
    def __init__(self):
        self.device = None
        self.textures = []

    def draw(self, device, texture):
        if self.device is not device:
            self.shutdown()
            self.device = device
        device.create(texture)
        self.textures.append(texture)

    def shutdown(self):
        if self.device:
            for texture in self.textures:
                self.device.destroy(texture)
        self.textures.clear()
        self.device = None


class SimulatedPresenter:
    def __init__(self, device):
        self.device = device
        self.overlay = SimulatedOverlay()
        self.stopped = False

    def draw(self, texture):
        assert not self.stopped
        self.overlay.draw(self.device, texture)

    def stop(self):
        if self.stopped:
            return
        self.stopped = True
        self.overlay.shutdown()

    def replace_device(self, device):
        if not self.stopped and self.device is not device:
            raise RuntimeError("device replacement requires presenter shutdown")
        self.device = device


def test_repeated_shutdown_and_restart_simulation():
    for cycle in range(100):
        old = SimulatedDevice()
        presenter = SimulatedPresenter(old)
        for n in range(5):
            presenter.draw((cycle, n))
        presenter.stop()
        presenter.stop()
        assert not old.textures
        assert len(old.destroyed) == 5
        old.alive = False
        new = SimulatedDevice()
        presenter.replace_device(new)
        next_presenter = SimulatedPresenter(new)
        next_presenter.draw(("next", cycle))
        next_presenter.stop()
        assert not new.textures
        new.alive = False


def test_live_device_replacement_rejected_simulation():
    presenter = SimulatedPresenter(SimulatedDevice())
    presenter.draw("texture")
    try:
        presenter.replace_device(SimulatedDevice())
    except RuntimeError:
        pass
    else:
        raise AssertionError("live device replacement was accepted")
    presenter.stop()


def test_source_cleanup_precedes_swapchain_destruction():
    stop = PRESENTER.split('extern "C" void host_present_stop()', 1)[1]
    assert stop.index("s->controls_overlay.shutdown();") < stop.index("s->device->destroy(s->chain);")
    assert stop.index("s->worker.join();") < stop.index("s->controls_overlay.shutdown();")
    assert stop.index("s->pending_commands == 0") < stop.index("s->controls_overlay.shutdown();")


def test_source_overlay_shutdown_clears_device_pointer():
    shutdown = OVERLAY.split("void Overlay::shutdown()", 1)[1].split("void Overlay::release()", 1)[0]
    assert shutdown.index("release();") < shutdown.index("device_ = nullptr;")


def test_source_rejects_live_device_replacement():
    setter = PRESENTER.split("void host_present_set_device(gpu::Device *device)", 1)[1].split(
        "gpu::Device *host_present_device()", 1
    )[0]
    assert "s->device != device" in setter
    assert "abort();" in setter
    assert setter.index("abort();") < setter.index("g_device = device;")


def test_performance_overlay_shutdown_before_device_teardown():
    stop = PRESENTER.split('extern "C" void host_present_stop()', 1)[1].split("void host_present_drop_current()", 1)[0]
    assert stop.index("s->worker.join();") < stop.index("s->performance_overlay.shutdown();")
    assert stop.index("s->pending_commands == 0") < stop.index("s->performance_overlay.shutdown();")
    assert stop.index("s->performance_overlay.shutdown();") < stop.index("s->device->destroy(s->chain);")


def test_performance_overlay_shutdown_is_idempotent_by_source_contract():
    assert "void shutdown();" in PERFORMANCE_HEADER
    destructor = PERFORMANCE.split("PerformanceOverlay::~PerformanceOverlay()", 1)[1].split("// Rasterize", 1)[0]
    assert "shutdown();" in destructor
    cleanup = destructor.split("void PerformanceOverlay::shutdown()", 1)[1]
    assert cleanup.index("device_->destroy(texture_);") < cleanup.index("texture_ = {};")
    assert cleanup.index("texture_ = {};") < cleanup.index("device_ = nullptr;")
    assert "texture_h_ = 0;" in cleanup
    assert "refreshed_ = -1;" in cleanup
    assert "last_mode_ = 0;" in cleanup
    assert "last_render_ = 0;" in cleanup


def test_performance_overlay_repeated_shutdown_simulation():
    for cycle in range(100):
        device = SimulatedDevice()
        overlay = SimulatedOverlay()
        overlay.draw(device, ("performance", cycle))
        overlay.shutdown()
        overlay.shutdown()
        assert device.destroyed == [("performance", cycle)]
        device.alive = False
        replacement = SimulatedDevice()
        overlay.draw(replacement, ("performance-next", cycle))
        overlay.shutdown()
        assert replacement.destroyed == [("performance-next", cycle)]
