"""Unit tests for Antigravity CLI statusline script."""

import importlib.machinery
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal, Protocol, cast

import pytest

# Derive repository-managed executable path relative to test file
REPO_ROOT = Path(__file__).resolve().parents[1]
STATUSLINE_PATH = REPO_ROOT / "statusline"

# Type Aliases
CtxColor = Literal["green", "yellow", "orange3", "red"]
QuotaColor = Literal["green", "yellow", "red"]


# Protocol definitions for typed module interface
class ModelInfoProtocol(Protocol):
    raw_model: str
    base_model: str
    effort: str


class WorkspaceInfoProtocol(Protocol):
    cwd: Path
    display_cwd: str
    repo_name: str
    workspace_name: str | None
    git_root: Path | None
    project_dir: Path | None


class ContextWindowProtocol(Protocol):
    in_tokens: int
    out_tokens: int
    used_pct: float
    capacity: int


class ContextWindowInfoProtocol(Protocol):
    in_tokens_str: str
    out_tokens_str: str
    capacity_str: str
    used_pct: float
    color: CtxColor


class QuotaBucketProtocol(Protocol):
    remaining_fraction: float
    reset_time: str | None
    reset_in_seconds: float | None


class QuotaBucketInfoProtocol(Protocol):
    used_pct: float
    reset_time_short: str
    reset_time_day: str
    color: QuotaColor
    remaining_fraction: float


class AgentPayloadProtocol(Protocol):
    model: ModelInfoProtocol
    agent_state: str
    workspace: WorkspaceInfoProtocol
    context: ContextWindowProtocol
    q5h: QuotaBucketProtocol | None
    qwk: QuotaBucketProtocol | None


class StatuslineViewProtocol(Protocol):
    model_str: str
    agent_state: str
    state_style: str
    repo_branch: str
    display_cwd: str
    context: ContextWindowInfoProtocol
    q5h: QuotaBucketInfoProtocol | None
    qwk: QuotaBucketInfoProtocol | None


class StatuslineModule(Protocol):
    ModelInfo: type[ModelInfoProtocol]
    WorkspaceInfo: type[WorkspaceInfoProtocol]
    ContextWindow: type[ContextWindowProtocol]
    ContextWindowInfo: type[ContextWindowInfoProtocol]
    QuotaBucket: type[QuotaBucketProtocol]
    QuotaBucketInfo: type[QuotaBucketInfoProtocol]
    AgentPayload: type[AgentPayloadProtocol]
    StatuslineView: type[StatuslineViewProtocol]

    def format_tokens(self, n: int | float) -> str: ...
    def format_ctx_size(self, size: int | float) -> str: ...
    def format_pct(self, usage_pct: float) -> str: ...
    def get_git_branch(self, cwd: Path) -> str: ...
    def format_reset_time_short(
        self, iso_str: str | None, reset_in_sec: float | None, now: datetime
    ) -> str: ...
    def format_reset_time_with_day(
        self, iso_str: str | None, reset_in_sec: float | None, now: datetime
    ) -> str: ...
    def get_ctx_color(self, used_pct: float) -> CtxColor: ...
    def get_quota_rate_color(
        self, quota_bucket: QuotaBucketProtocol | None, total_window_sec: float, now: datetime
    ) -> QuotaColor: ...
    def write_text_atomic(self, path: Path, content: str) -> None: ...
    def parse_payload(self, raw_json: str, now: datetime) -> AgentPayloadProtocol | None: ...
    def build_statusline_view(
        self, payload: AgentPayloadProtocol, now: datetime
    ) -> StatuslineViewProtocol: ...
    def main(self, argv: Sequence[str] | None = None) -> int: ...


# Dynamically load the extensionless executable source
assert STATUSLINE_PATH.is_file(), f"Managed executable missing at {STATUSLINE_PATH}"
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("statusline", str(STATUSLINE_PATH))
spec = importlib.util.spec_from_loader("statusline", loader)
assert spec is not None
raw_mod = importlib.util.module_from_spec(spec)
sys.modules["statusline"] = raw_mod
loader.exec_module(raw_mod)
statusline: StatuslineModule = cast(StatuslineModule, raw_mod)


# --- TC-T1: Gate & Source Authority Tests ---


def test_loader_path_authority() -> None:
    """TC-T1-001: Loader resolves repository-managed executable, not live copy."""
    assert STATUSLINE_PATH.is_file()
    assert STATUSLINE_PATH.is_absolute()
    live_path = Path.home() / ".gemini/antigravity-cli/statusline"
    assert live_path != STATUSLINE_PATH


def test_pyright_typing_surface() -> None:
    """TC-T1-002: Module functions are accessible through typed surface."""
    assert callable(statusline.format_tokens)
    assert callable(statusline.parse_payload)
    assert callable(statusline.build_statusline_view)
    assert callable(statusline.main)


# --- TC-T2: Boundary, Domain & Presentation Tests ---


@pytest.mark.parametrize(
    "raw_input",
    [
        pytest.param("", id="empty_string"),
        pytest.param("   \n\t  ", id="whitespace_only"),
        pytest.param("{invalid_json", id="malformed_json"),
        pytest.param("[1, 2, 3]", id="json_array"),
        pytest.param('"just a string"', id="json_scalar_string"),
        pytest.param("12345", id="json_scalar_number"),
        pytest.param("true", id="json_scalar_boolean"),
        pytest.param("null", id="json_null"),
    ],
)
def test_parse_payload_invalid_inputs(raw_input: str) -> None:
    """TC-T2-001: Invalid payloads return None."""
    now = datetime.now(UTC)
    assert statusline.parse_payload(raw_input, now) is None


@pytest.mark.parametrize(
    ("input_val", "expected_tokens", "expected_capacity"),
    [
        pytest.param(15000, 15000, 15000, id="valid_int"),
        pytest.param(15000.0, 15000, 15000, id="integral_float"),
        pytest.param("15000", 15000, 15000, id="numeric_string"),
        pytest.param(True, 0, 1048576, id="boolean_true_rejected"),
        pytest.param(False, 0, 1048576, id="boolean_false_rejected"),
        pytest.param(-100, 0, 1048576, id="negative_number_default"),
        pytest.param("", 0, 1048576, id="empty_string_default"),
        pytest.param("invalid", 0, 1048576, id="invalid_string_default"),
        pytest.param(float("nan"), 0, 1048576, id="nan_default"),
        pytest.param(float("inf"), 0, 1048576, id="inf_default"),
    ],
)
def test_numeric_token_and_capacity_boundary(
    input_val: object, expected_tokens: int, expected_capacity: int
) -> None:
    """TC-T2-002: Numeric fields reject booleans and non-finite values."""
    now = datetime.now(UTC)
    payload_json = f"""
    {{
        "context_window": {{
            "total_input_tokens": {json.dumps(input_val)},
            "context_window_size": {json.dumps(input_val)}
        }}
    }}
    """
    payload = statusline.parse_payload(payload_json, now)
    assert payload is not None
    assert payload.context.in_tokens == expected_tokens
    assert payload.context.capacity == expected_capacity


@pytest.mark.parametrize(
    ("used_pct", "expected_str", "expected_color"),
    [
        pytest.param(0.0, "0%", "green", id="exact_0_pct"),
        pytest.param(0.5, "<1%", "green", id="sub_1_pct"),
        pytest.param(30.0, "30%", "green", id="boundary_30_pct"),
        pytest.param(45.0, "45%", "yellow", id="mid_yellow_45_pct"),
        pytest.param(60.0, "60%", "yellow", id="boundary_60_pct"),
        pytest.param(75.0, "75%", "orange3", id="mid_orange_75_pct"),
        pytest.param(80.0, "80%", "orange3", id="boundary_80_pct"),
        pytest.param(95.0, "95%", "red", id="red_95_pct"),
        pytest.param(100.0, "100%", "red", id="exact_100_pct"),
    ],
)
def test_percentage_formatting_and_colors(
    used_pct: float, expected_str: str, expected_color: CtxColor
) -> None:
    """TC-T2-003: Percentage formatting and color thresholds."""
    assert statusline.format_pct(used_pct) == expected_str
    assert statusline.get_ctx_color(used_pct) == expected_color


def test_percentage_precedence() -> None:
    """TC-T2-004: Valid remaining percentage wins; invalid remaining falls through."""
    now = datetime.now(UTC)

    # Valid remaining_percentage wins (100 - 80 = 20% used)
    raw1 = '{"context_window": {"remaining_percentage": 80.0, "used_percentage": 50.0}}'
    p1 = statusline.parse_payload(raw1, now)
    assert p1 is not None
    assert p1.context.used_pct == 20.0

    # Invalid remaining_percentage falls through to valid used_percentage
    raw2 = '{"context_window": {"remaining_percentage": "invalid", "used_percentage": 35.0}}'
    p2 = statusline.parse_payload(raw2, now)
    assert p2 is not None
    assert p2.context.used_pct == 35.0

    # Both invalid yields 0.0%
    raw3 = '{"context_window": {"remaining_percentage": "bad", "used_percentage": true}}'
    p3 = statusline.parse_payload(raw3, now)
    assert p3 is not None
    assert p3.context.used_pct == 0.0


def test_domain_presentation_separation() -> None:
    """TC-T2-005: parse_payload returns domain models; build_statusline_view creates presentation models."""
    now = datetime.now(UTC)
    raw_payload = """
    {
        "agent_state": "thinking",
        "model": {"display_name": "Gemini 3.6 Pro (High)", "effort": "high"},
        "cwd": "/tmp",
        "context_window": {
            "total_input_tokens": 15000,
            "total_output_tokens": 2000,
            "context_window_size": 1048576,
            "used_percentage": 25.0
        },
        "quota": {
            "5h_bucket": {"remaining_fraction": 0.8, "reset_in_seconds": 3600}
        }
    }
    """
    payload = statusline.parse_payload(raw_payload, now)
    assert payload is not None
    # Verify domain model structure (no formatted token strings or color attributes on payload.context)
    assert payload.context.in_tokens == 15000
    assert payload.context.out_tokens == 2000
    assert payload.context.used_pct == 25.0
    assert not hasattr(payload.context, "in_tokens_str")
    assert not hasattr(payload.context, "color")

    # Build view and verify presentation model structure
    view = statusline.build_statusline_view(payload, now)
    assert view.model_str == "Gemini 3.6 Pro (high)"
    assert view.context.in_tokens_str == "15.0k"
    assert view.context.out_tokens_str == "2.0k"
    assert view.context.capacity_str == "1M"
    assert view.context.color == "green"
    assert view.q5h is not None
    assert view.q5h.used_pct == 20.0
    assert view.q5h.color == "green"


def test_quota_bucket_selection() -> None:
    """TC-T2-006: Quota selection chooses valid lowest-remaining candidate and ignores malformed ones."""
    now = datetime.now(UTC)
    raw = """
    {
        "quota": {
            "5h_bucket_1": {"remaining_fraction": 0.9, "reset_in_seconds": 3600},
            "5h_bucket_2": {"remaining_fraction": 0.4, "reset_in_seconds": 1800},
            "5h_bucket_invalid": {"remaining_fraction": "bad_fraction"},
            "5h_bucket_bool": {"remaining_fraction": true}
        }
    }
    """
    payload = statusline.parse_payload(raw, now)
    assert payload is not None
    assert payload.q5h is not None
    # Lowest valid remaining_fraction is 0.4
    assert payload.q5h.remaining_fraction == 0.4


# --- TC-T3: Git Subprocess Contract Tests ---


def test_git_branch_normal_repo(tmp_path: Path) -> None:
    """TC-T3-001: Temporary Git repository on a named branch returns that branch."""
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "-C", str(repo), "init", "-b", "feature-test"], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "config",
            "user.email",
            "168346341+chrisdpurcell@users.noreply.github.com",
        ],
        check=True,
    )
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test User"], check=True)
    (repo / "file.txt").write_text("hello", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "--no-verify", "-m", "init"], check=True)

    branch = statusline.get_git_branch(repo)
    assert branch == "feature-test"


def test_git_branch_detached_head(tmp_path: Path) -> None:
    """TC-T3-002: Detached HEAD returns empty string."""
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "-C", str(repo), "init", "-b", "main"], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "config",
            "user.email",
            "168346341+chrisdpurcell@users.noreply.github.com",
        ],
        check=True,
    )
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test User"], check=True)
    (repo / "file.txt").write_text("hello", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "--no-verify", "-m", "init"], check=True)
    subprocess.run(["git", "-C", str(repo), "checkout", "--detach"], check=True)

    branch = statusline.get_git_branch(repo)
    assert branch == ""


def test_git_branch_fallback(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """TC-T3-003: Failed symbolic-ref followed by successful rev-parse returns fallback branch."""

    def mock_run(
        cmd: Sequence[str], capture_output: bool, text: bool, timeout: float, check: bool
    ) -> subprocess.CompletedProcess[str]:
        if "symbolic-ref" in cmd:
            return subprocess.CompletedProcess(
                cmd, 1, stdout="", stderr="fatal: not a symbolic ref"
            )
        if "rev-parse" in cmd:
            return subprocess.CompletedProcess(cmd, 0, stdout="fallback-branch\n", stderr="")
        return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="")

    monkeypatch.setattr(subprocess, "run", mock_run)
    branch = statusline.get_git_branch(tmp_path)
    assert branch == "fallback-branch"


def test_git_branch_failures(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """TC-T3-004: Failed fallback, timeout, and missing Git executable return empty string."""

    # Timeout
    def mock_timeout(*args: object, **kwargs: object) -> None:
        raise subprocess.TimeoutExpired("git", 0.5)

    monkeypatch.setattr(subprocess, "run", mock_timeout)
    assert statusline.get_git_branch(tmp_path) == ""

    # Missing executable
    def mock_missing(*args: object, **kwargs: object) -> None:
        raise FileNotFoundError("git binary missing")

    monkeypatch.setattr(subprocess, "run", mock_missing)
    assert statusline.get_git_branch(tmp_path) == ""


# --- TC-T4: Filesystem & Cache Failure Boundary Tests ---


def test_write_text_atomic_preserves_mode(tmp_path: Path) -> None:
    """TC-T4-001: Atomic write preserves content and existing destination mode."""
    target_file = tmp_path / "test_output.json"
    target_file.write_text("initial content\n", encoding="utf-8")
    target_file.chmod(0o755)

    new_content = '{"key": "value"}\n'
    statusline.write_text_atomic(target_file, new_content)

    assert target_file.read_text(encoding="utf-8") == new_content
    file_mode = stat.S_IMODE(target_file.stat().st_mode)
    assert file_mode == 0o755


def test_write_text_atomic_cleanup_on_failure(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """TC-T4-002: Replacement failure removes staged file and re-raises original OSError."""
    target_file = tmp_path / "target.json"

    def mock_replace(src: object, dst: object) -> None:
        raise OSError("Disk failure during replace")

    monkeypatch.setattr(os, "replace", mock_replace)

    with pytest.raises(OSError, match="Disk failure"):
        statusline.write_text_atomic(target_file, "data")

    # Staged temporary files in directory should be cleaned up
    remaining = [p for p in tmp_path.iterdir() if p != target_file]
    assert len(remaining) == 0


def test_main_cache_oserror_suppression(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """TC-T4-003: Cache OSError does not change valid rendered stdout or zero exit code."""

    def mock_write_fail(path: Path, content: str) -> None:
        raise PermissionError("Cache directory read-only")

    monkeypatch.setattr(statusline, "write_text_atomic", mock_write_fail)

    sample_payload = '{"agent_state": "idle", "model": {"display_name": "Gemini 3.6 Flash"}}'
    monkeypatch.setattr("sys.stdin", sys.stdin)
    monkeypatch.setattr("sys.stdin.read", lambda: sample_payload)

    exit_code = statusline.main()
    assert exit_code == 0

    captured = capsys.readouterr()
    assert "Gemini 3.6 Flash" in captured.out
    assert "idle" in captured.out


def test_main_cache_control_flow_propagation(monkeypatch: pytest.MonkeyPatch) -> None:
    """TC-T4-004: KeyboardInterrupt from cache path propagates through entrypoint."""

    def mock_write_interrupt(path: Path, content: str) -> None:
        raise KeyboardInterrupt("Interrupted")

    monkeypatch.setattr(statusline, "write_text_atomic", mock_write_interrupt)

    sample_payload = '{"agent_state": "idle"}'
    monkeypatch.setattr("sys.stdin.read", lambda: sample_payload)

    with pytest.raises(KeyboardInterrupt):
        statusline.main()


# --- TC-T5: CLI & End-to-End Rendering Tests ---


def test_main_empty_and_malformed_cli_input(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """TC-T5-001: Empty and malformed CLI input exit zero with no stdout."""
    monkeypatch.setattr("sys.stdin.read", lambda: "   ")
    assert statusline.main() == 0
    assert capsys.readouterr().out == ""

    monkeypatch.setattr("sys.stdin.read", lambda: "invalid json")
    assert statusline.main() == 0
    assert capsys.readouterr().out == ""


def test_main_valid_payload_stdout_and_cache(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """TC-T5-002: Fixed valid payload exits zero, prints 2 non-empty rows, caches input."""
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: fake_home)

    payload_bytes = '{"agent_state": "running", "model": {"display_name": "Gemini 3.6 Flash"}}'
    monkeypatch.setattr("sys.stdin.read", lambda: payload_bytes)

    assert statusline.main() == 0

    out = capsys.readouterr().out
    lines = [line for line in out.splitlines() if line.strip()]
    assert len(lines) == 2

    cache_file = fake_home / ".gemini/antigravity-cli/last_payload.json"
    assert cache_file.is_file()
    assert cache_file.read_text(encoding="utf-8") == payload_bytes


def test_main_ansi_stripped_labels(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """TC-T5-003: ANSI-stripped output preserves all required labels."""
    raw_json = """
    {
        "agent_state": "idle",
        "model": {"display_name": "Gemini 3.6 Flash (High)", "effort": "high"},
        "cwd": "/tmp",
        "workspace": {"workspace_name": "test-repo"},
        "context_window": {
            "total_input_tokens": 15000,
            "total_output_tokens": 2000,
            "context_window_size": 1048576,
            "used_percentage": 25.0
        },
        "quota": {
            "5h_bucket": {"remaining_fraction": 0.8, "reset_in_seconds": 3600},
            "weekly_bucket": {"remaining_fraction": 0.9, "reset_in_seconds": 86400}
        }
    }
    """
    monkeypatch.setattr("sys.stdin.read", lambda: raw_json)
    statusline.main()

    raw_output = capsys.readouterr().out
    ansi_escape = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
    clean_text = ansi_escape.sub("", raw_output)

    assert "Gemini 3.6 Flash (high)" in clean_text
    assert "idle" in clean_text
    assert "test-repo" in clean_text
    assert "In: 15.0k" in clean_text
    assert "Out: 2.0k" in clean_text
    assert "Ctx: 25% 1M" in clean_text
    assert "5h: 20%" in clean_text
    assert "Wk: 10%" in clean_text


def test_direct_shebang_execution(tmp_path: Path) -> None:
    """TC-T5-004: Direct shebang invocation of managed source succeeds under constrained runtime."""
    isolated_home = tmp_path / "iso_home"
    isolated_home.mkdir()

    test_payload = '{"agent_state": "idle", "model": {"display_name": "Gemini 3.6 Flash"}}'

    env = {
        "HOME": str(isolated_home),
        "PATH": "/usr/bin:/bin",
        "LANG": "C.UTF-8",
    }

    res = subprocess.run(
        [str(STATUSLINE_PATH)],
        input=test_payload,
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )

    assert res.returncode == 0
    assert res.stderr == ""
    lines = [line for line in res.stdout.splitlines() if line.strip()]
    assert len(lines) == 2
