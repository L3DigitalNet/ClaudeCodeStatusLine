#!/usr/bin/env python3
import sys
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone
import humanize
from rich.console import Console
from rich.text import Text


def format_tokens(n: float | int | None) -> str:
    """Formats token count rounded to nearest .1k (e.g. 1.2k, 3.4k, 42.2k) or .1M if >= 1,000,000."""
    n = float(n or 0)
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    return f"{n / 1_000:.1f}k"


def format_ctx_size(size: float | int | None) -> str:
    """Formats context window capacity rounded to 1M, 200k, etc."""
    size = int(size or 0)
    if size >= 1_000_000:
        m = round(size / 1_000_000)
        return f"{m}M"
    elif size >= 1_000:
        k = round(size / 1_000)
        return f"{k}k"
    return str(size)


def format_pct(usage_pct: float) -> str:
    """Formats usage percentage cleanly:
    - 0.0% -> 0%
    - 0.0% < usage < 1.0% -> <1%
    - >= 1.0% -> rounded integer %
    """
    if usage_pct <= 0.0:
        return "0%"
    elif usage_pct < 1.0:
        return "<1%"
    else:
        return f"{round(usage_pct)}%"


def get_git_branch(cwd: str) -> str:
    """Returns current git branch for cwd, or empty string if not in git repo."""
    if not cwd or not os.path.isdir(cwd):
        return ""
    try:
        res = subprocess.run(
            ["git", "-C", cwd, "symbolic-ref", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=0.5,
        )
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
        res2 = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=0.5,
        )
        branch = res2.stdout.strip()
        return "" if branch == "HEAD" else branch
    except Exception:
        return ""


def format_reset_time(iso_str: str | None, reset_in_sec: int | float | None = None, include_day: bool = False) -> str:
    """Formats reset timestamp as 'HH:MM' or 'Ddd@HH:MM' in local time."""
    dt = None
    if iso_str:
        try:
            dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        except Exception:
            pass
    if dt is None and reset_in_sec is not None:
        try:
            dt = datetime.fromtimestamp(time.time() + float(reset_in_sec), tz=timezone.utc)
        except Exception:
            pass
    if dt:
        local_dt = dt.astimezone()
        t_str = local_dt.strftime("%H:%M")
        if include_day:
            day = local_dt.strftime("%a").capitalize()
            return f"{day}@{t_str}"
        return t_str
    return ""


def get_ctx_color(used_pct: float) -> str:
    """Returns color based on Context Used %:
    0-30%: green, 30-60%: yellow, 60-80%: orange3, 80-100%: red.
    """
    if used_pct <= 30.0:
        return "green"
    elif used_pct <= 60.0:
        return "yellow"
    elif used_pct <= 80.0:
        return "orange3"
    else:
        return "red"


def get_quota_rate_color(quota_obj: dict | None, total_window_sec: float) -> str:
    """Calculates cumulative usage pacing relative to target budget at elapsed time t:
    - Ideal rate = 100% / total_window_hours
    - Target budget at elapsed time t = ideal_rate * elapsed_hours
    - Yellow threshold = Target budget * 1.333333 (+33% ahead of target)
    - Actual usage <= Target: green
    - Target < Actual usage <= Yellow threshold: yellow
    - Actual usage > Yellow threshold: red
    """
    if not quota_obj:
        return "green"

    rem_frac = float(quota_obj.get("remaining_fraction", 1.0))
    usage_pct = (1.0 - rem_frac) * 100.0

    reset_sec = quota_obj.get("reset_in_seconds")
    if reset_sec is None and quota_obj.get("reset_time"):
        try:
            dt = datetime.fromisoformat(quota_obj["reset_time"].replace("Z", "+00:00"))
            reset_sec = max(0.0, (dt - datetime.now(timezone.utc)).total_seconds())
        except Exception:
            pass

    if reset_sec is None or reset_sec > total_window_sec:
        reset_sec = total_window_sec

    elapsed_sec = max(1.0, total_window_sec - float(reset_sec))
    elapsed_hours = elapsed_sec / 3600.0
    total_window_hours = total_window_sec / 3600.0

    ideal_rate = 100.0 / total_window_hours
    target_usage = ideal_rate * elapsed_hours
    yellow_thresh = target_usage * (4.0 / 3.0)

    if usage_pct <= target_usage:
        return "green"
    elif usage_pct <= yellow_thresh:
        return "yellow"
    else:
        return "red"


def main() -> None:
    try:
        raw_input = sys.stdin.read()
        if not raw_input.strip():
            sys.exit(0)
        data = json.loads(raw_input)
        try:
            with open(os.path.expanduser("~/.gemini/antigravity-cli/last_payload.json"), "w") as f:
                f.write(raw_input)
        except Exception:
            pass
    except Exception:
        sys.exit(0)

    console = Console(force_terminal=True, color_system="truecolor")

    # --- Row 1 Data ---
    # 1. Model & Effort
    model_obj = data.get("model", {})
    raw_model = model_obj.get("display_name") or model_obj.get("id") or "Gemini 3.6 Flash"
    base_model = re.sub(r"\s*\((Low|Medium|High)\)$", "", raw_model, flags=re.IGNORECASE).strip()
    effort = model_obj.get("effort") or ""
    if not effort:
        match = re.search(r"\((Low|Medium|High)\)$", raw_model, re.IGNORECASE)
        if match:
            effort = match.group(1).lower()

    if effort:
        model_str = f"{base_model} ({effort.lower()})"
    else:
        model_str = base_model

    # 2. Agent State
    state = data.get("agent_state", "idle")
    state_colors = {
        "idle": "bold green",
        "thinking": "bold yellow",
        "running": "bold cyan",
        "tool_use": "bold magenta",
        "waiting": "bold orange3",
        "error": "bold red",
    }
    state_style = state_colors.get(state.lower(), "bold green")

    # 3. <repo_name>@<branch>
    cwd = data.get("cwd") or "."
    ws = data.get("workspace", {})
    repo_name = ws.get("workspace_name") or os.path.basename(ws.get("git_root") or ws.get("project_dir") or os.path.abspath(cwd))
    branch = get_git_branch(cwd)
    repo_branch = f"{repo_name}@{branch}" if branch else repo_name

    # 4. CWD
    home = os.path.expanduser("~")
    abs_cwd = os.path.abspath(cwd)
    display_cwd = abs_cwd.replace(home, "~") if abs_cwd.startswith(home) else abs_cwd

    # Assemble Row 1
    row1 = Text()
    row1.append(model_str, style="bold cyan")
    row1.append(" | ", style="dim white")
    row1.append(f"{state}", style=state_style)
    row1.append(" | ", style="dim white")
    row1.append(repo_branch, style="bold magenta")
    row1.append(" | ", style="dim white")
    row1.append(display_cwd, style="bold blue")

    # --- Row 2 Data ---
    ctx = data.get("context_window", {})
    in_tokens = format_tokens(ctx.get("total_input_tokens", 0))
    out_tokens = format_tokens(ctx.get("total_output_tokens", 0))

    rem_pct = ctx.get("remaining_percentage")
    if rem_pct is None and "used_percentage" in ctx:
        used_pct = float(ctx["used_percentage"])
    elif rem_pct is not None:
        used_pct = 100.0 - float(rem_pct)
    else:
        used_pct = 0.0

    ctx_size = format_ctx_size(ctx.get("context_window_size", 1048576))
    ctx_str = f"{format_pct(used_pct)} {ctx_size}"
    ctx_color = get_ctx_color(used_pct)

    quotas = data.get("quota", {})
    # Select 5h quota bucket with highest usage (min remaining_fraction)
    q5h_obj = None
    for k, v in quotas.items():
        if "5h" in k.lower() and isinstance(v, dict):
            if q5h_obj is None or float(v.get("remaining_fraction", 1.0)) < float(q5h_obj.get("remaining_fraction", 1.0)):
                q5h_obj = v

    q5h_rem_frac = float(q5h_obj.get("remaining_fraction", 1.0)) if q5h_obj else 1.0
    q5h_used_pct = (1.0 - q5h_rem_frac) * 100.0
    q5h_str = f"5h: {format_pct(q5h_used_pct)}"
    if q5h_obj:
        reset_time_str = format_reset_time(q5h_obj.get("reset_time"), q5h_obj.get("reset_in_seconds"), include_day=False)
        if reset_time_str:
            q5h_str += f" @{reset_time_str}"
    q5h_color = get_quota_rate_color(q5h_obj, 5.0 * 3600.0)

    # Select weekly quota bucket with highest usage (min remaining_fraction)
    qwk_obj = None
    for k, v in quotas.items():
        if ("weekly" in k.lower() or "wk" in k.lower()) and isinstance(v, dict):
            if qwk_obj is None or float(v.get("remaining_fraction", 1.0)) < float(qwk_obj.get("remaining_fraction", 1.0)):
                qwk_obj = v

    qwk_rem_frac = float(qwk_obj.get("remaining_fraction", 1.0)) if qwk_obj else 1.0
    qwk_used_pct = (1.0 - qwk_rem_frac) * 100.0
    qwk_str = f"Wk: {format_pct(qwk_used_pct)}"
    if qwk_obj:
        reset_day_time = format_reset_time(qwk_obj.get("reset_time"), qwk_obj.get("reset_in_seconds"), include_day=True)
        if reset_day_time:
            qwk_str += f" {reset_day_time}"
    qwk_color = get_quota_rate_color(qwk_obj, 7.0 * 86400.0)

    # Assemble Row 2
    row2 = Text()
    row2.append(f"In: {in_tokens}", style="cyan")
    row2.append(" | ", style="dim white")
    row2.append(f"Out: {out_tokens}", style="cyan")
    row2.append(" | ", style="dim white")
    row2.append(f"Ctx: {ctx_str}", style=ctx_color)
    row2.append(" | ", style="dim white")
    row2.append(q5h_str, style=q5h_color)
    row2.append(" | ", style="dim white")
    row2.append(qwk_str, style=qwk_color)

    console.print(row1, soft_wrap=True)
    console.print(row2, soft_wrap=True)


if __name__ == "__main__":
    main()
