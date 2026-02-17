#!/usr/bin/env python3
"""Convert cloud-init.yaml to an equivalent bash script (for Lightsail).

Lightsail only accepts shell scripts as user-data, not cloud-init YAML.
This script reads cloud-init.yaml and generates a bash script that
performs the same setup.

Usage: python3 cloud-init-to-bash.py cloud-init.yaml [user] > output.sh
"""
import sys


def parse_cloud_init(path):
    """Parse cloud-init.yaml into structured sections."""
    with open(path) as f:
        text = f.read()
    lines = text.split("\n")

    sections = {
        "packages": [],
        "write_files": [],
        "runcmd": [],
        "ssh_pwauth": True,
    }

    i = 0
    while i < len(lines):
        line = lines[i]

        # ssh_pwauth
        if line.startswith("ssh_pwauth:"):
            sections["ssh_pwauth"] = "true" in line
            i += 1
            continue

        # packages (top-level key, items indented 2 spaces)
        if line == "packages:":
            i += 1
            while i < len(lines) and (lines[i].startswith("  ") or lines[i].strip() == ""):
                s = lines[i].strip()
                if s.startswith("- "):
                    sections["packages"].append(s[2:].strip())
                i += 1
            continue

        # write_files (top-level key)
        if line == "write_files:":
            i += 1
            while i < len(lines):
                s = lines[i].strip()
                # Stop at next top-level key
                if lines[i] and not lines[i][0].isspace() and not s.startswith("#"):
                    break
                # Skip comments and blank lines between entries
                if s == "" or s.startswith("#"):
                    i += 1
                    continue
                # Start of a file entry
                if s.startswith("- path:"):
                    entry = {
                        "path": s.split("path:", 1)[1].strip(),
                        "owner": "root:root",
                        "permissions": "0644",
                        "content": "",
                    }
                    i += 1
                    # Read entry fields (indented by 4+ spaces)
                    while i < len(lines):
                        fl = lines[i]
                        fs = fl.strip()
                        # Next entry or end of section
                        if fs.startswith("- path:") or (fl and not fl[0].isspace() and fs and not fs.startswith("#")):
                            break
                        if fs.startswith("owner:"):
                            entry["owner"] = fs.split("owner:", 1)[1].strip()
                            i += 1
                        elif fs.startswith("permissions:"):
                            entry["permissions"] = fs.split("permissions:", 1)[1].strip().strip('"')
                            i += 1
                        elif fs.startswith("content:"):
                            # Multi-line content block (content: |)
                            i += 1
                            content_lines = []
                            # Find the indentation of the first content line
                            content_indent = None
                            while i < len(lines):
                                cl = lines[i]
                                cs = cl.strip()
                                # Detect indentation from first non-empty content line
                                if content_indent is None and cs:
                                    content_indent = len(cl) - len(cl.lstrip())
                                # Content line: has enough indentation
                                if content_indent and cl.startswith(" " * content_indent) and len(cl) > 0:
                                    content_lines.append(cl[content_indent:])
                                    i += 1
                                elif cl.strip() == "":
                                    # Blank line: check if content continues
                                    if i + 1 < len(lines) and content_indent and lines[i + 1].startswith(" " * content_indent):
                                        content_lines.append("")
                                        i += 1
                                    else:
                                        break
                                else:
                                    break
                            entry["content"] = "\n".join(content_lines).rstrip()
                        else:
                            i += 1
                    sections["write_files"].append(entry)
                    continue
                i += 1
            continue

        # runcmd (top-level key)
        if line == "runcmd:":
            i += 1
            while i < len(lines) and (lines[i].startswith("  ") or lines[i].strip() == ""):
                s = lines[i].strip()
                if s.startswith("# "):
                    i += 1
                    continue
                if s.startswith("- "):
                    cmd = s[2:]
                    # Handle quoted commands
                    if cmd.startswith("'") and cmd.endswith("'"):
                        cmd = cmd[1:-1]
                    sections["runcmd"].append(cmd)
                i += 1
            continue

        i += 1

    return sections


def generate_bash(sections, user="ubuntu"):
    """Generate a bash script from parsed cloud-init sections."""
    home = f"/home/{user}" if user != "root" else "/root"
    out = []

    out.append("#!/bin/bash")
    out.append("set -x")
    out.append("export DEBIAN_FRONTEND=noninteractive")
    out.append("")

    # Packages
    if sections["packages"]:
        out.append("# System packages")
        out.append("apt-get update -y")
        out.append("apt-get upgrade -y")
        out.append(f"apt-get install -y {' '.join(sections['packages'])}")
        out.append("")

    # Write files (skip sshd config -- handled separately below)
    for entry in sections["write_files"]:
        path = entry["path"]
        if "sshd_config" in path:
            continue  # Handled by ssh_pwauth section
        # Substitute user paths
        if user != "ubuntu":
            path = path.replace("/home/ubuntu", home)
        owner = entry["owner"].replace("ubuntu", user) if user != "ubuntu" else entry["owner"]
        perms = entry["permissions"]
        content = entry["content"]
        if user != "ubuntu":
            content = content.replace("/home/ubuntu", home)

        # Ensure parent directory exists
        parent = "/".join(path.split("/")[:-1])
        if parent:
            out.append(f"mkdir -p {parent}")
        out.append(f"cat > {path} << 'FILEEOF'")
        out.append(content)
        out.append("FILEEOF")
        out.append(f"chmod {perms} {path}")
        out.append(f"chown {owner} {path}")
        out.append("")

    # SSH hardening
    if not sections["ssh_pwauth"]:
        out.append("# SSH hardening")
        out.append("cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'SSHCONF'")
        out.append("PasswordAuthentication no")
        out.append("KbdInteractiveAuthentication no")
        out.append("PubkeyAuthentication yes")
        out.append("PermitRootLogin prohibit-password")
        out.append("SSHCONF")
        out.append("")

    # runcmd
    if sections["runcmd"]:
        out.append("# Run commands")
        for cmd in sections["runcmd"]:
            if user != "ubuntu":
                cmd = (cmd
                       .replace("ubuntu:ubuntu", f"{user}:{user}")
                       .replace("/home/ubuntu", home)
                       .replace("chsh -s /usr/bin/zsh ubuntu", f"chsh -s /usr/bin/zsh {user}")
                       .replace("chown -R ubuntu:ubuntu", f"chown -R {user}:{user}")
                       .replace("su - ubuntu", f"su - {user}"))
            out.append(cmd)
        out.append("")

    return "\n".join(out)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} cloud-init.yaml [user]", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    user = sys.argv[2] if len(sys.argv) > 2 else "ubuntu"

    sections = parse_cloud_init(path)
    print(generate_bash(sections, user))
