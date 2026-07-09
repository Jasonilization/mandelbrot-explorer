# Mandelbrot Explorer

A fast, local, GPU-accelerated Mandelbrot Set explorer built with Python + PyQt6.
Google-Maps-style pan/zoom, hybrid float32 -> float64 -> arbitrary-precision
(perturbation theory) rendering, smooth coloring, tile caching, and a live
palette editor. No internet dependency at runtime.

## Requirements

- Python 3.12 (Homebrew: `brew install python@3.12`)
- macOS with OpenGL support (also runs on Windows/Linux; GPU path falls back
  to a multithreaded CPU renderer if no OpenGL context is available)

## Setup

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python main.py
```

## Status

Under active development. See `.claude/plans/` history for the design plan,
or ask Claude Code to continue the build.
