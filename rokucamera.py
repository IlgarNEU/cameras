#!/usr/bin/env python3

import subprocess
import os
import time
import logging
from datetime import datetime

# ── Configuration ─────────────────────────────────────────────────────────────
RTSP_URL       = "rtsp://192.168.33.253:8554/s-tvfeed-7"
OUTPUT_DIR     = os.path.expanduser("~/Desktop/recordings/roku")
OUTPUT_LOG_DIR     = os.path.expanduser("~/Desktop/recording_logs")

SEGMENT_HOURS  = 1                  # Recording duration per file (hours)
RETRY_DELAY    = 5                  # Seconds to wait before retrying on failure
FFMPEG_TIMEOUT = 10_000_000         # Microseconds (10s) — stream freeze timeout
# ──────────────────────────────────────────────────────────────────────────────

SEGMENT_SECONDS = SEGMENT_HOURS * 3600

# Set up logging to both console and file
os.makedirs(OUTPUT_DIR, exist_ok=True)
os.makedirs(OUTPUT_LOG_DIR, exist_ok=True)

log_path = os.path.join(OUTPUT_DIR, f"rokurecorder_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s — %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(log_path),
    ]
)
log = logging.getLogger(__name__)


def make_filename() -> str:
    """Generate a unique timestamped output filename."""
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    return os.path.join(OUTPUT_DIR, f"rokustream_{ts}.mkv")


def record_segment(filepath: str) -> bool:
    """
    Run ffmpeg for one segment (up to SEGMENT_SECONDS).
    Returns True if ffmpeg exited cleanly (segment complete or graceful stop),
    False if it failed to connect or crashed immediately.
    """
    cmd = [
        "ffmpeg",
        "-rtsp_transport", "tcp",
        "-timeout", str(FFMPEG_TIMEOUT),
        "-i", RTSP_URL,
        "-c", "copy",
        "-t", str(SEGMENT_SECONDS),  # Stop after 1 hour
        filepath,
        "-y",           # Overwrite if somehow the file exists
        "-loglevel", "warning",
        "-stats",
    ]

    log.info(f"Starting segment: {os.path.basename(filepath)}")
    start_time = time.time()

    try:
        process = subprocess.run(cmd)
        elapsed = time.time() - start_time

        if elapsed < 10:
            # Exited in under 10 seconds — likely failed to connect
            log.warning(f"ffmpeg exited too quickly ({elapsed:.1f}s) — stream likely unreachable.")
            # Remove empty/tiny file
            if os.path.exists(filepath) and os.path.getsize(filepath) < 1024:
                os.remove(filepath)
                log.info("Removed empty file.")
            return False
        else:
            size_mb = os.path.getsize(filepath) / (1024 * 1024) if os.path.exists(filepath) else 0
            log.info(f"Segment saved: {os.path.basename(filepath)} ({size_mb:.1f} MB, {elapsed:.0f}s)")
            return True

    except FileNotFoundError:
        log.error("ffmpeg not found. Please install it: brew install ffmpeg")
        raise
    except KeyboardInterrupt:
        log.info("Interrupted by user.")
        raise


def main():
    log.info("=" * 60)
    log.info(f"RTSP Recorder started")
    log.info(f"Stream  : {RTSP_URL}")
    log.info(f"Output  : {OUTPUT_DIR}")
    log.info(f"Segment : {SEGMENT_HOURS} hour(s)")
    log.info("=" * 60)
    log.info("Press Ctrl+C to stop.")

    segment_number = 1

    try:
        while True:
            filepath = make_filename()
            log.info(f"── Segment #{segment_number} ──────────────────────────────────")

            success = False
            attempt = 1

            # Keep retrying until we get at least a partial recording
            while not success:
                if attempt > 1:
                    log.info(f"Retry attempt #{attempt} in {RETRY_DELAY}s...")
                    time.sleep(RETRY_DELAY)
                try:
                    success = record_segment(filepath)
                except KeyboardInterrupt:
                    log.info("Stopped.")
                    return
                attempt += 1

            segment_number += 1

    except KeyboardInterrupt:
        log.info("Recorder stopped by user.")


if __name__ == "__main__":
    main()


#nohup python3 record_stream.py &
#pkill -f record_stream.py && pkill ffmpeg