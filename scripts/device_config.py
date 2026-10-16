#!/usr/bin/env python3
"""First-boot Wi-Fi credential setup for prebuilt (base-image) cards.

Reads device-config.json from the ZIMDATA volume, writes the root-only
NetworkManager AP profile, then deletes the plaintext file. When no config is
present and no AP profile exists yet, it generates a random password and leaves
wifi-credentials.txt in the ZIMDATA root (operator cards).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import sys
from pathlib import Path

CONFIG_NAME = "device-config.json"
CREDENTIALS_NAME = "wifi-credentials.txt"
AP_PROFILE_NAME = "pi-kiwix-ap.nmconnection"
# No look-alike characters, so a typed-in fallback password is hard to get wrong.
PASSWORD_ALPHABET = "abcdefghjkmnpqrstuvwxyzACDEFGHJKLMNPQRTUVWXYZ2346789"


class DeviceConfigError(Exception):
    pass


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def validate_ssid(ssid: object) -> str:
    if not isinstance(ssid, str) or not ssid:
        raise DeviceConfigError("ap.ssid must be a non-empty string")
    if len(ssid.encode("utf-8")) > 32:
        raise DeviceConfigError("ap.ssid must be at most 32 bytes")
    if any(ord(c) < 32 or ord(c) == 127 for c in ssid):
        raise DeviceConfigError("ap.ssid must not contain control characters")
    return ssid


def validate_password(password: object) -> str:
    if not isinstance(password, str) or not 8 <= len(password) <= 63:
        raise DeviceConfigError("ap.password must be 8-63 characters")
    if not all(32 <= ord(c) < 127 for c in password):
        raise DeviceConfigError("ap.password must be printable ASCII")
    return password


def validate_country(code: object) -> str:
    if not isinstance(code, str) or not re.fullmatch(r"[A-Z]{2}", code):
        raise DeviceConfigError("country code must be two uppercase letters")
    return code


def load_device_config(path: Path) -> dict[str, str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise DeviceConfigError(f"{path.name} is not readable JSON: {exc}") from exc
    ap = data.get("ap") if isinstance(data, dict) else None
    if not isinstance(ap, dict):
        raise DeviceConfigError("device-config.json must contain an 'ap' object")
    result = {"ssid": validate_ssid(ap.get("ssid")), "password": validate_password(ap.get("password"))}
    if ap.get("countryCode") is not None:
        result["country"] = validate_country(ap["countryCode"])
    return result


def render_ap_profile(ssid: str, password: str, address: str, country: str) -> str:
    return (
        "[connection]\n"
        "id=pi-kiwix-ap\n"
        "type=wifi\n"
        "autoconnect=true\n"
        "\n"
        "[wifi]\n"
        "mode=ap\n"
        f"ssid={ssid}\n"
        "band=bg\n"
        f"country={country}\n"
        "\n"
        "[wifi-security]\n"
        "key-mgmt=wpa-psk\n"
        f"psk={password}\n"
        "\n"
        "[ipv4]\n"
        "method=shared\n"
        f"address1={address}\n"
        "\n"
        "[ipv6]\n"
        "method=ignore\n"
    )


def write_private(path: Path, content: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)
    try:
        os.chmod(tmp, mode)
    except OSError:
        pass
    os.replace(tmp, path)


def generate_password(length: int = 16) -> str:
    return "".join(secrets.choice(PASSWORD_ALPHABET) for _ in range(length))


def apply(zim_dir: Path, env_file: Path, nm_dir: Path, zim_mounted: bool) -> str:
    """Returns one of: configured, generated, unchanged."""
    env = read_env(env_file)
    address = env.get("AP_ADDRESS") or "10.42.0.1/24"
    if "/" not in address:
        address += "/24"
    default_country = validate_country(env.get("AP_COUNTRY_CODE") or "NL")
    default_ssid = env.get("AP_SSID") or "emergency-web-pi"
    profile_path = nm_dir / AP_PROFILE_NAME
    config_path = zim_dir / CONFIG_NAME

    if zim_mounted and config_path.is_file():
        cfg = load_device_config(config_path)
        write_private(
            profile_path,
            render_ap_profile(cfg["ssid"], cfg["password"], address, cfg.get("country", default_country)),
            0o600,
        )
        config_path.unlink()
        return "configured"

    if profile_path.is_file():
        return "unchanged"

    password = generate_password()
    ssid = validate_ssid(default_ssid)
    write_private(profile_path, render_ap_profile(ssid, password, address, default_country), 0o600)
    if zim_mounted:
        write_private(
            zim_dir / CREDENTIALS_NAME,
            f"Emergency Web Pi Wi-Fi\nSSID: {ssid}\nPassword: {password}\n",
            0o644,
        )
    return "generated"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zim-dir", default="/var/lib/pi-kiwix-zimdata")
    parser.add_argument("--env-file", default="/opt/emergency-web-pi/.env")
    parser.add_argument("--nm-dir", default="/etc/NetworkManager/system-connections")
    args = parser.parse_args(argv)

    zim_dir = Path(args.zim_dir)
    try:
        outcome = apply(zim_dir, Path(args.env_file), Path(args.nm_dir), os.path.ismount(zim_dir))
    except DeviceConfigError as exc:
        # A bad config must not leave the card without a usable AP: fall back to a generated password.
        print(f"[device-config] invalid device config: {exc}", file=sys.stderr)
        bad = zim_dir / CONFIG_NAME
        try:
            bad.unlink()
        except OSError:
            pass
        outcome = apply(zim_dir, Path(args.env_file), Path(args.nm_dir), os.path.ismount(zim_dir))
    print(f"[device-config] {outcome}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
