"""Build and qualify bundled host artifacts using the caller's signed registry."""
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parent.parent
BUILDER = "wotex-tracker-builder:elixir-1.18.4-otp-27.3.4.15"
IMAGE = "wotex-tracker:0.1.0-linux-arm64-local"
BUILDER_BASE = "hexpm/elixir@sha256:473f77ee88977dc8cc5d05fb91080a308be86be3fc27d50aef9a837d07c8268b"
RUNTIME_BASE = "debian@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171"


def command(args, *, env=None, cwd=None, timeout=600):
    result = subprocess.run(args, env=env, cwd=cwd, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"artifact command {args[:3]} failed:\n{result.stdout[-16000:]}")
    return result.stdout


def source_copy(destination):
    destination.mkdir()
    source = ROOT / "hosts/app"
    selected = [source / name for name in ("mix.exs", "mix.lock", "README.md", "LICENSE", "NOTICE", "lib", "config", "priv", "rel", "bin")]
    for path in selected:
        if path.is_dir():
            shutil.copytree(path, destination / path.name, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        else:
            shutil.copy2(path, destination / path.name)
    digest = hashlib.sha256()
    for path in sorted(destination.rglob("*")):
        if path.is_file():
            digest.update(str(path.relative_to(destination)).encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def clean_path(workspace):
    directory = workspace / "client-bin"
    directory.mkdir()
    (directory / "python3").symlink_to(Path(sys.executable).resolve())
    return str(directory) + os.pathsep + "/usr/bin:/bin:/usr/sbin:/sbin"


def native(workspace, registry, url, env, mix_run):
    source = workspace / "native-host"
    digest = source_copy(source)
    build_env = {**env, "HEX_HOME": str(workspace / "native-host-hex")}
    mix_run(["mix", "hex.repo", "set", "hexpm", "--url", url, "--public-key", str(registry / "public_key")], ROOT, build_env)
    print("Host native: resolving ordinary production artifacts and assembling bundled ERTS", flush=True)
    for args in (["mix", "deps.get", "--only", "prod"], ["mix", "compile", "--warnings-as-errors"],
                 ["mix", "release", "wotex_tracker"]):
        mix_run(args, source, build_env)
    release = source / "_build/prod/rel/wotex_tracker"
    fixtures = workspace / "native-fixtures"
    probe_env = {**env, "PATH": clean_path(workspace), "PYTHONDONTWRITEBYTECODE": "1"}
    print("Host native: black-box HTTP/SSE, signal/restart, crash recovery and full storage", flush=True)
    output = command([str(ROOT / "_build/openapi-venv/bin/python"), str(ROOT / "scripts/release_probe.py"),
                      str(release), str(fixtures)], env=probe_env, timeout=90)
    if "RELEASE_PROBE_PASS" not in output:
        raise RuntimeError("native bundled release probe did not pass")
    print(output.strip(), flush=True)
    artifact = source / "_build/prod/wotex_tracker-0.1.0.tar.gz"
    return {"source_sha256": digest, "platform": platform.platform(), "result": json.loads((fixtures / "result.json").read_text()),
            "archive_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest()}, artifact


def linux(workspace, registry, env):
    build = workspace / "linux-build"
    build.mkdir()
    digest = source_copy(build / "host")
    shutil.copytree(registry, build / "registry")
    verification = build / "verification"
    verification.mkdir()
    for name in ("release_probe.py", "http_consumer.py", "requirements-openapi.txt"):
        shutil.copy2(ROOT / "scripts" / name, verification / name)
    container = "wtr-build-" + uuid.uuid4().hex
    probe = "wtr-probe-" + uuid.uuid4().hex
    volume = "wtr-fixtures-" + uuid.uuid4().hex
    print("Host Linux ARM64: building pinned toolchain image", flush=True)
    command(["docker", "build", "--platform", "linux/arm64", "-f", str(ROOT / "hosts/app/Dockerfile.builder"),
             "-t", BUILDER, str(ROOT / "hosts/app")])
    command(["docker", "run", "-d", "--name", container, "--platform", "linux/arm64",
             "-v", str(build) + ":/build", "-e", "HEX_HOME=/build/hex-home", BUILDER, "sleep", "infinity"])
    try:
        docker = ["docker", "exec", container]
        command([*docker, "python3", "-m", "venv", "--copies", "/build/verification/venv"])
        command([*docker, "/build/verification/venv/bin/pip", "install", "--disable-pip-version-check",
                 "-r", "/build/verification/requirements-openapi.txt"])
        command(["docker", "exec", "-d", container, "python3", "-m", "http.server", "8765", "--bind", "127.0.0.1",
                 "--directory", "/build/registry"])
        command([*docker, "mix", "hex.repo", "set", "hexpm", "--url", "http://127.0.0.1:8765",
                 "--public-key", "/build/registry/public_key"])
        print("Host Linux ARM64: compiling immutable artifacts and bundled release", flush=True)
        for args in (["mix", "deps.get", "--only", "prod"], ["mix", "compile", "--warnings-as-errors"],
                     ["mix", "release", "wotex_tracker"]):
            command([*docker, *args])
        packages = command([*docker, "dpkg-query", "-W", "gcc", "libc6", "libssl3", "python3", "make"])
        compiler = command([*docker, "gcc", "--version"]).splitlines()[0]
        builder_id = command(["docker", "image", "inspect", BUILDER, "--format", "{{.Id}}"]).strip()
        context = build / "runtime-image"
        context.mkdir()
        shutil.copytree(build / "host/_build/prod/rel/wotex_tracker", context / "release")
        print("Host Linux ARM64: packaging runtime without Elixir, Mix or compiler", flush=True)
        command(["docker", "build", "--platform", "linux/arm64", "-f", str(ROOT / "hosts/app/Dockerfile"),
                 "-t", IMAGE, str(context)])
        image_id = command(["docker", "image", "inspect", IMAGE, "--format", "{{.Id}}"]).strip()
        command(["docker", "volume", "create", volume])
        command(["docker", "run", "--rm", "--user", "0:0", "--entrypoint", "python3", "-v", volume + ":/fixtures", IMAGE,
                 "-c", "import os; os.chown('/fixtures',10001,10001); os.chmod('/fixtures',0o700)"])
        print("Host Linux ARM64: read-only container, non-root black-box release lifecycle probe", flush=True)
        output = command(["docker", "run", "--name", probe, "--network", "none", "--read-only", "--platform", "linux/arm64",
            "--tmpfs", "/tmp:rw,nosuid,nodev,mode=1777", "-v", volume + ":/fixtures",
            "-v", str(verification) + ":/verification:ro", "-e", "PYTHONDONTWRITEBYTECODE=1",
            "--entrypoint", "/verification/venv/bin/python", IMAGE, "/verification/release_probe.py",
            "/opt/wotex", "/fixtures", "--readonly-directory", "/var/lib/wotex"], timeout=120)
        if "RELEASE_PROBE_PASS" not in output:
            raise RuntimeError("Linux bundled release probe did not pass")
        print(output.strip(), flush=True)
        command(["docker", "cp", probe + ":/fixtures/result.json", str(build / "result.json")])
        result = json.loads((build / "result.json").read_text())
        if not result["external_compiler_absent"]:
            raise RuntimeError("runtime image unexpectedly contains a compiler")
        artifact = build / "host/_build/prod/wotex_tracker-0.1.0.tar.gz"
        return {"source_sha256": digest, "base_builder": BUILDER_BASE, "base_runtime": RUNTIME_BASE,
                "builder_image_id": builder_id, "image_id": image_id, "image_tag": IMAGE,
                "compiler": compiler, "builder_packages": packages.splitlines(), "result": result,
                "archive_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest()}, artifact
    finally:
        for target in (probe, container):
            subprocess.run(["docker", "rm", "-f", target], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["docker", "volume", "rm", volume], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def verify_host(workspace, registry, url, env, mix_run):
    workspace = workspace.resolve()
    destination = ROOT / "_build/releases"
    destination.mkdir(parents=True, exist_ok=True)
    native_result, native_archive = native(workspace, registry, url, env, mix_run)
    shutil.copy2(native_archive, destination / "wotex_tracker-0.1.0-darwin-arm64.tar.gz")
    linux_result, linux_archive = linux(workspace, registry, env)
    if native_result["source_sha256"] != linux_result["source_sha256"]:
        raise RuntimeError("host source changed between platform builds")
    shutil.copy2(linux_archive, destination / "wotex_tracker-0.1.0-linux-arm64.tar.gz")
    return {"darwin-arm64": native_result, "linux-arm64": linux_result, "published": False}
