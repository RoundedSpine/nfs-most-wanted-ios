"""Validate real CMake cache formats used by disabled SDL dependent options."""
import importlib.util
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location("ios_backend_runner", Path(__file__).parents[1] / "tools/test.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


@pytest.mark.parametrize("dependent_type", ["BOOL", "INTERNAL"])
def test_disabled_dependent_option_does_not_require_bool_cache_type(dependent_type):
    runner.verify_ios_sdl_cache("SDL_VULKAN:BOOL=OFF\n"
                                "SDL_RENDER_VULKAN:%s=OFF\n" % dependent_type)


@pytest.mark.parametrize("cache", [
    "SDL_VULKAN:BOOL=ON\nSDL_RENDER_VULKAN:INTERNAL=OFF\n",
    "SDL_VULKAN:BOOL=OFF\nSDL_RENDER_VULKAN:BOOL=ON\n",
    "SDL_VULKAN:BOOL=OFF\n",
    "# SDL_VULKAN:BOOL=OFF\nSDL_RENDER_VULKAN:BOOL=OFF\n",
])
def test_enabled_or_missing_vulkan_settings_are_rejected(cache):
    with pytest.raises(RuntimeError, match="must be disabled"):
        runner.verify_ios_sdl_cache(cache)
